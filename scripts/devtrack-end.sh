#!/bin/bash
# devtrack 结束: 对比变更 + 创建全量回滚包（替代旧包）
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/snapshot.sh"

dt_require_init
dt_require_jq

summary="${*:-}"
current_manifest=""
rollback_tmp=""
finish_ok=0
added_files=""
added_count=0
changed_count=0
deleted_count=0
total_changes=0
precomputed_diff=0
backfill_from=""

# 从 transcript.jsonl 提取对话摘要
_extract_conversation() {
    local transcript="$1"
    local output="$2"
    [ -f "$transcript" ] || return 0

    {
        echo "# 对话摘要"
        echo ""
        local turn=0
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            role="$(echo "$line" | jq -r '.role // ""' 2>/dev/null)"
            [ -z "$role" ] && continue

            if [ "$role" = "user" ]; then
                content="$(echo "$line" | jq -r '
                    if (.content | type) == "string" then .content
                    elif (.content | type) == "array" then
                        [.content[] | select(.type == "text") | .text] | join(" ")
                    else "" end
                ' 2>/dev/null | tr '\n' ' ' | head -c 200)"
                if [ -n "$content" ]; then
                    turn=$((turn + 1))
                    echo "**[用户]** $content"
                    echo ""
                fi
            elif [ "$role" = "assistant" ]; then
                content="$(echo "$line" | jq -r '
                    if (.content | type) == "string" then .content
                    elif (.content | type) == "array" then
                        [.content[] | select(.type == "text") | .text] | join(" ")
                    else "" end
                ' 2>/dev/null | tr '\n' ' ' | head -c 300)"
                if [ -n "$content" ]; then
                    echo "**[AI]** $content"
                    echo ""
                fi
            fi
        done < "$transcript"
    } > "$output" 2>/dev/null
}

_update_session_meta() {
    local status="$1"
    local summary_text="$2"
    local changed_total="${3:-0}"
    [ -f "$SESSION_DIR/session.yaml" ] || return 0
    local tmp
    tmp="$(mktemp)"
    sed -E "s|^ended_at:.*|ended_at: \"$(dt_iso_timestamp)\"|" "$SESSION_DIR/session.yaml" > "$tmp"
    sed -i -E "s|^status:.*|status: \"${status}\"|" "$tmp"
    sed -i -E "s|^summary:.*|summary: \"${summary_text}\"|" "$tmp"
    sed -i -E "s|^files_changed:.*|files_changed: ${changed_total}|" "$tmp"
    mv -f "$tmp" "$SESSION_DIR/session.yaml"
}

_cleanup_devtrack_end() {
    local code=$?
    trap - EXIT INT TERM
    [ -n "$current_manifest" ] && rm -f "$current_manifest"
    [ -n "$rollback_tmp" ] && [ -d "$rollback_tmp" ] && rm -rf "$rollback_tmp"

    if [ "$finish_ok" -ne 1 ]; then
        # 保留 .active_session 标记，让下次 'devtrack 结束' 可以重试。
        # session.yaml 标记为 "failed"，恢复逻辑会识别此状态并重新尝试。
        failure_summary="${summary:-devtrack 结束失败（可重试）}"
        _update_session_meta "failed" "$failure_summary" "$total_changes"
    fi

    exit "$code"
}

trap '_cleanup_devtrack_end' EXIT INT TERM

_reset_change_tracking() {
    changed_files=""
    deleted_files=""
    added_files=""
    added_count=0
    changed_count=0
    deleted_count=0
    total_changes=0
}

_compute_manifest_diff() {
    local baseline_file="$1"
    local manifest_file="$2"

    _reset_change_tracking
    [ -f "$baseline_file" ] || return 0

    declare -A baseline_sha=()
    declare -A current_sha=()

    while IFS='|' read -r fpath expected_sha; do
        [ -n "$fpath" ] || continue
        baseline_sha["$fpath"]="$expected_sha"
    done < <(jq -r '.local_files[] | "\(.path)|\(.sha256)"' "$baseline_file")

    while IFS='|' read -r fpath observed_sha; do
        [ -n "$fpath" ] || continue
        current_sha["$fpath"]="$observed_sha"

        if [ -z "${baseline_sha[$fpath]+x}" ]; then
            added_files="${added_files}${fpath}\n"
            added_count=$((added_count + 1))
            continue
        fi

        if [ "${baseline_sha[$fpath]}" != "$observed_sha" ]; then
            changed_files="${changed_files}${fpath}\n"
            changed_count=$((changed_count + 1))
        fi
    done < <(jq -r '.local_files[] | "\(.path)|\(.sha256)"' "$manifest_file")

    for fpath in "${!baseline_sha[@]}"; do
        if [ -z "${current_sha[$fpath]+x}" ]; then
            deleted_files="${deleted_files}${fpath}\n"
            deleted_count=$((deleted_count + 1))
        fi
    done

    total_changes=$((changed_count + deleted_count + added_count))
}

# ── 智能摘要：把变更文件按用途分类，生成简短描述 ──
# 输入: 文件路径列表（绝对路径或项目相对路径）通过 stdin
# 输出: 分类后的"category|file_basename"，每行一个
_classify_files() {
    local project_root="${PROJECT_ROOT:-$PWD}"
    local fpath rel base cat
    while IFS= read -r fpath; do
        [ -z "$fpath" ] && continue
        # 转为相对路径
        rel="${fpath#$project_root/}"
        rel="${rel#./}"
        base="$(basename "$rel")"

        # 跳过明显不重要的文件
        case "$rel" in
            .devtrack/*|.git/*|.claude/*|.cursor/*|.vscode/*|*.lock) continue ;;
        esac

        # 分类规则（路径优先于扩展名）
        case "$rel" in
            # 测试文件（覆盖前后置）
            *test_*.py|*_test.py|*_test.go|*.test.ts|*.test.tsx|*.test.js|*.spec.ts|*.spec.tsx|*.spec.js|tests/*|*/tests/*|test/*|*/test/*)
                cat="测试" ;;
            # API / 路由
            *api/*|*/routes/*|*/handlers/*|*/controllers/*|*/endpoints/*)
                cat="API" ;;
            # 数据模型 / Schema
            *models/*|*/entities/*|*/domain/*)
                cat="模型" ;;
            *schemas/*|*/dto/*|*/types.py|*/types.ts)
                cat="Schema" ;;
            # 服务层
            *services/*|*/usecases/*|*/use_cases/*)
                cat="服务" ;;
            # 前端
            *components/*|*/widgets/*)
                cat="组件" ;;
            *pages/*|*/views/*|*/screens/*)
                cat="页面" ;;
            *stores/*|*/store/*|*/reducers/*|*/slices/*)
                cat="状态" ;;
            *hooks/*) cat="Hook" ;;
            # 数据库迁移
            *migrations/*|*/alembic/versions/*|*.sql)
                cat="迁移" ;;
            # 文档
            *.md|*.rst|*.adoc|docs/*|*/docs/*|README*|CHANGELOG*)
                cat="文档" ;;
            # CI / 部署
            .github/*|.gitlab-ci*|Jenkinsfile*|*/ci/*)
                cat="CI" ;;
            Dockerfile|*Dockerfile*|docker-compose*.yml|docker-compose*.yaml|*.dockerfile)
                cat="部署" ;;
            # 配置 / 构建
            pyproject.toml|setup.py|setup.cfg|requirements*.txt|package.json|tsconfig*.json|vite.config.*|webpack.config.*|Makefile|*.mk)
                cat="构建" ;;
            *.yaml|*.yml|*.toml|*.ini|.env*|*.conf)
                cat="配置" ;;
            # 脚本
            *.sh|scripts/*|*/scripts/*)
                cat="脚本" ;;
            # 按扩展名兜底
            *.py|*.go|*.rs|*.java|*.kt|*.cpp|*.c|*.h|*.ts|*.tsx|*.js|*.jsx|*.vue|*.svelte)
                cat="代码" ;;
            *)  cat="其他" ;;
        esac

        # 输出 category|basename（去除扩展名让标识更短）
        local short="${base%.*}"
        printf '%s|%s\n' "$cat" "$short"
    done
}

# ── 把分类后的"cat|name"按类别合并、限制名字数量 ──
# 输出格式: "API: users, auth | 模型: user (+1) | 测试: +3"
_format_category_summary() {
    local input_tsv="$1"
    [ -s "$input_tsv" ] || { printf ''; return 0; }

    # 排序后按类别 group
    awk -F'|' '
        { cat = $1; name = $2; cnt[cat]++; if (cnt[cat] <= 3) names[cat] = (names[cat] == "" ? name : names[cat] ", " name) }
        END {
            # 按预设优先级输出（API > 模型 > Schema > 服务 > 组件 > 页面 > 测试 > 迁移 > 文档 > 配置 > CI > 部署 > 构建 > 脚本 > 状态 > Hook > 代码 > 其他）
            n = split("API|模型|Schema|服务|组件|页面|测试|状态|Hook|迁移|文档|CI|部署|构建|配置|脚本|代码|其他", order, "|")
            for (i = 1; i <= n; i++) {
                c = order[i]
                if (c in cnt) {
                    extra = cnt[c] - 3
                    if (extra > 0) {
                        printf "%s: %s (+%d)", c, names[c], extra
                    } else {
                        printf "%s: %s", c, names[c]
                    }
                    printf " | "
                }
            }
        }
    ' "$input_tsv" | sed 's/ | $//'
}

# ── git 行数统计（如果当前目录是 git 仓库）──
# 输出形如: "+340/-15"，无 git 时返回空
_git_line_stats() {
    git -C "$PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    local stat
    # 跟踪所有变更（已暂存 + 未暂存）vs HEAD
    stat="$(git -C "$PWD" diff HEAD --shortstat 2>/dev/null)"
    [ -z "$stat" ] && return 0
    # 形如 " 5 files changed, 340 insertions(+), 15 deletions(-)"
    local ins del
    ins="$(printf '%s' "$stat" | grep -oE '[0-9]+ insertion' | grep -oE '^[0-9]+' || echo 0)"
    del="$(printf '%s' "$stat" | grep -oE '[0-9]+ deletion' | grep -oE '^[0-9]+' || echo 0)"
    [ "$ins" = "0" ] && [ "$del" = "0" ] && return 0
    printf '+%s/-%s' "$ins" "$del"
}

# ── 综合：用变更文件 + git 统计生成智能摘要 ──
# 全局变量: changed_files / added_files / deleted_files (带换行的字符串)
# 输出: 单行摘要字符串
_generate_smart_summary() {
    local class_tsv summary_main git_stat
    class_tsv="$(mktemp)"
    {
        echo -e "$changed_files" | sed '/^$/d'
        echo -e "$added_files" | sed '/^$/d'
    } | _classify_files > "$class_tsv"

    summary_main="$(_format_category_summary "$class_tsv")"
    rm -f "$class_tsv"

    # 没归类到任何文件（如全是 .devtrack/ 或被忽略）
    if [ -z "$summary_main" ]; then
        if [ "$total_changes" -gt 0 ]; then
            summary_main="变更 $total_changes 个文件"
        else
            printf '无文件变更'
            return 0
        fi
    fi

    # 操作类型前缀（单一动作时简化）
    local prefix=""
    if [ "$added_count" -gt 0 ] && [ "$changed_count" -eq 0 ] && [ "$deleted_count" -eq 0 ]; then
        prefix="新增 — "
    elif [ "$changed_count" -gt 0 ] && [ "$added_count" -eq 0 ] && [ "$deleted_count" -eq 0 ]; then
        prefix="修改 — "
    elif [ "$deleted_count" -gt 0 ] && [ "$added_count" -eq 0 ] && [ "$changed_count" -eq 0 ]; then
        prefix="删除 — "
    fi

    # git 行数后缀
    git_stat="$(_git_line_stats 2>/dev/null || true)"

    if [ -n "$git_stat" ]; then
        printf '%s%s [%s]' "$prefix" "$summary_main" "$git_stat"
    else
        printf '%s%s' "$prefix" "$summary_main"
    fi
}

_find_latest_completed_session() {
    local dir latest=""
    for dir in $(find "$DEVTRACK_SESSIONS" -mindepth 1 -maxdepth 1 -type d | sort); do
        [ -f "$dir/session.yaml" ] || continue
        if grep -qE '^status:\s*"completed"$' "$dir/session.yaml"; then
            latest="$dir"
        fi
    done

    [ -n "$latest" ] && printf '%s\n' "$latest"
}

# 扫描 sessions/ 找回 active/failed 状态的孤儿会话（标记丢失但会话还在）
# 返回最新的孤儿会话 ID（按时间倒序），找不到返回非零
_find_orphan_session() {
    local dir status session_id
    # 按目录名倒序遍历（目录名即 timestamp）
    for dir in $(find "$DEVTRACK_SESSIONS" -mindepth 1 -maxdepth 1 -type d | sort -r); do
        [ -f "$dir/session.yaml" ] || continue
        [ -f "$dir/baseline.json" ] || continue

        status="$(grep -E '^status:' "$dir/session.yaml" | head -1 | sed -E 's/^status:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')"
        session_id="$(basename "$dir")"

        case "$status" in
            active|failed)
                # 孤儿会话：标记是 active 或 failed 但 .active_session 不存在
                printf '%s\n' "$session_id"
                return 0
                ;;
            completed|abandoned)
                # 遇到正常结束的会话就停止搜索（更早的会话更不可能是孤儿）
                return 1
                ;;
        esac
    done
    return 1
}

_start_backfill_session() {
    local latest_completed_dir latest_completed_id latest_baseline baseline_count answer

    latest_completed_dir="$(_find_latest_completed_session)"
    [ -n "$latest_completed_dir" ] || dt_die "没有活跃会话。请先运行 'devtrack 开始'"

    latest_completed_id="$(basename "$latest_completed_dir")"
    latest_baseline="$latest_completed_dir/baseline.json"
    [ -f "$latest_baseline" ] || dt_die "没有活跃会话。请先运行 'devtrack 开始'"

    current_manifest="$(mktemp)"
    snapshot_manifest_only "$current_manifest"
    _compute_manifest_diff "$latest_baseline" "$current_manifest"

    if [ "$total_changes" -eq 0 ]; then
        dt_die "没有活跃会话。请先运行 'devtrack 开始'"
    fi

    dt_warn "检测到没有活跃会话，但存在可补录的开发变更。"
    dt_info "  最近完成会话: $latest_completed_id"
    dt_info "  检测到变更: $changed_count 个文件修改, $deleted_count 个文件删除, $added_count 个文件新增"
    printf "是否创建补录会话并继续结束? [y/N] " >&2
    if ! IFS= read -r answer; then
        dt_die "已取消补录。请先运行 'devtrack 开始' 后重试"
    fi

    case "$answer" in
        y|Y|yes|YES|Yes)
            ;;
        *)
            dt_die "已取消补录。请先运行 'devtrack 开始' 后重试"
            ;;
    esac

    SESSION_ID="$(dt_new_session_id)"
    SESSION_DIR="$DEVTRACK_SESSIONS/$SESSION_ID"
    mkdir -p "$SESSION_DIR"
    cp "$latest_baseline" "$SESSION_DIR/baseline.json"
    baseline_count="$(jq '.local_files | length' "$SESSION_DIR/baseline.json")"
    backfill_from="$latest_completed_id"

    cat > "$SESSION_DIR/session.yaml" << EOF
session_id: "$SESSION_ID"
started_at: "$(dt_iso_timestamp)"
ended_at: ""
status: "active"
summary: ""
files_at_start: $baseline_count
files_changed: 0
backfill_from: "$backfill_from"
EOF

    echo "$SESSION_ID" > "$DEVTRACK_DIR/.active_session"
    dt_timeline_append "session_start" "补录会话开始: $SESSION_ID (基于最近完成会话 $backfill_from)"
    dt_yaml_set "$DEVTRACK_STATE" "updated_at" "$(dt_iso_timestamp)"
    precomputed_diff=1
}

if [ ! -f "$DEVTRACK_DIR/.active_session" ]; then
    # 优先尝试恢复孤儿会话（标记丢失但 session.yaml 还在的情况，
    # 通常因为上次 'devtrack 结束' 被超时/中断后异常清理导致）
    orphan_id="$(_find_orphan_session 2>/dev/null || true)"
    if [ -n "$orphan_id" ]; then
        orphan_status="$(grep -E '^status:' "$DEVTRACK_SESSIONS/$orphan_id/session.yaml" | head -1 | sed -E 's/^status:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')"
        dt_warn "检测到孤儿会话: $orphan_id (状态: $orphan_status)"
        dt_info "  恢复该会话以继续完成结束流程..."
        echo "$orphan_id" > "$DEVTRACK_DIR/.active_session"
        # 把状态改回 active，让正常的结束流程接管
        if [ "$orphan_status" = "failed" ]; then
            tmp="$(mktemp)"
            sed -E 's|^status:.*|status: "active"|' "$DEVTRACK_SESSIONS/$orphan_id/session.yaml" > "$tmp"
            mv -f "$tmp" "$DEVTRACK_SESSIONS/$orphan_id/session.yaml"
        fi
    else
        _start_backfill_session
    fi
fi

SESSION_ID="$(cat "$DEVTRACK_DIR/.active_session")"
SESSION_DIR="$DEVTRACK_SESSIONS/$SESSION_ID"
ROLLBACK_DIR="$DEVTRACK_DIR/rollback"
BASELINE="$SESSION_DIR/baseline.json"

[ -d "$SESSION_DIR" ] || dt_die "会话目录不存在: $SESSION_DIR"

dt_info "=== 结束会话: $SESSION_ID ==="
dt_info ""

# ──────────────────────────────────────
# 1) 对比变更（基线 + 当前清单）
# ──────────────────────────────────────
if [ -z "$current_manifest" ]; then
    current_manifest="$(mktemp)"
    snapshot_manifest_only "$current_manifest"
fi

dt_info "正在对比变更..."
if [ "$precomputed_diff" -ne 1 ]; then
    _compute_manifest_diff "$BASELINE" "$current_manifest"
fi
dt_info "本次会话变更: $changed_count 个文件修改, $deleted_count 个文件删除, $added_count 个文件新增"

# 自动摘要：用户未提供 → 启发式智能生成
if [ -z "$summary" ]; then
    # 设置 PROJECT_ROOT 给 _classify_files 用
    PROJECT_ROOT="$(grep -E '^\s+root:' "$DEVTRACK_CONFIG" 2>/dev/null | head -1 | sed -E 's/^\s+root:\s*"?([^"]*)"?\s*$/\1/')"
    PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
    summary="$(_generate_smart_summary)"
fi

# 写变更记录
cat > "$SESSION_DIR/changes.md" << EOF
# 会话变更记录: $SESSION_ID

## 摘要
$summary

## 修改文件 ($changed_count)
EOF
echo -e "$changed_files" | sed '/^$/d' | while IFS= read -r f; do
    echo "- $f" >> "$SESSION_DIR/changes.md"
done
if [ "$added_count" -gt 0 ]; then
    echo -e "\n## 新增文件 ($added_count)" >> "$SESSION_DIR/changes.md"
    echo -e "$added_files" | sed '/^$/d' | while IFS= read -r f; do
        echo "- $f" >> "$SESSION_DIR/changes.md"
    done
fi
if [ "$deleted_count" -gt 0 ]; then
    echo -e "\n## 删除文件 ($deleted_count)" >> "$SESSION_DIR/changes.md"
    echo -e "$deleted_files" | sed '/^$/d' | while IFS= read -r f; do
        echo "- $f" >> "$SESSION_DIR/changes.md"
    done
fi

# ──────────────────────────────────────
# 2) 轮转旧回滚包 + 创建新全量回滚包
# ──────────────────────────────────────
dt_info ""
dt_info "正在创建全量回滚包..."

# 读取保留数量（config: rollback_keep，默认 3）
ROLLBACK_KEEP="$(grep -E '^rollback_keep:' "$DEVTRACK_CONFIG" 2>/dev/null | sed -E 's/rollback_keep:\s*//' | tr -d '"' || true)"
ROLLBACK_KEEP="${ROLLBACK_KEEP:-3}"

# 先在临时目录构建新的 rollback，成功后再替换当前有效包
rollback_tmp="$(mktemp -d "$DEVTRACK_DIR/rollback.tmp.XXXXXX")"
snapshot_create_from_manifest "$current_manifest" "$rollback_tmp" "会话 $SESSION_ID 结束时的全量备份 — $summary"
[ -f "$rollback_tmp/manifest.json" ] || dt_die "新回滚包未生成 manifest.json"

# 把当前 rollback/ 轮转到 rollback.1/、rollback.2/ ... rollback.N/
# 先删最旧的
oldest_slot="$DEVTRACK_DIR/rollback.${ROLLBACK_KEEP}"
[ -d "$oldest_slot" ] && rm -rf "$oldest_slot"

# 向后移动各个 slot
i="$((ROLLBACK_KEEP - 1))"
while [ "$i" -ge 1 ]; do
    src="$DEVTRACK_DIR/rollback.$i"
    dst="$DEVTRACK_DIR/rollback.$((i + 1))"
    [ -d "$src" ] && mv "$src" "$dst"
    i="$((i - 1))"
done

# 当前 rollback/ 移到 rollback.1/
[ -d "$ROLLBACK_DIR" ] && mv "$ROLLBACK_DIR" "$DEVTRACK_DIR/rollback.1"

# 提升新包为当前有效 rollback
mv "$rollback_tmp" "$ROLLBACK_DIR"
rollback_tmp=""

local_count="$(jq '.local_files | length' "$ROLLBACK_DIR/manifest.json")"
remote_count="$(jq '.remote_files | length' "$ROLLBACK_DIR/manifest.json" 2>/dev/null || echo 0)"
pkg_size="$(du -sh "$ROLLBACK_DIR" 2>/dev/null | awk '{print $1}')"

dt_info "回滚包已就绪:"
dt_info "  本地文件: $local_count 个"
[ "$remote_count" -gt 0 ] && dt_info "  远程文件: $remote_count 个"
dt_info "  包大小: $pkg_size"

# 显示历史回滚包
slot_count=0
for i in $(seq 1 "$ROLLBACK_KEEP"); do
    slot="$DEVTRACK_DIR/rollback.$i"
    [ -d "$slot" ] && [ -f "$slot/manifest.json" ] || continue
    slot_desc="$(jq -r '.description // "旧备份"' "$slot/manifest.json" | sed 's/ — .*//')"
    slot_time="$(jq -r '.created_at' "$slot/manifest.json")"
    [ "$slot_count" -eq 0 ] && dt_info "  历史回滚包:"
    dt_info "    rollback.$i: $slot_time"
    slot_count=$((slot_count + 1))
done

# ──────────────────────────────────────
# 3) 更新会话元数据
# ──────────────────────────────────────
_update_session_meta "completed" "$summary" "$total_changes"

# ──────────────────────────────────────
# 4) 从 activity log 补充信息（如果 hooks 有捕获）
# ──────────────────────────────────────
ACTIVITY_LOG="$SESSION_DIR/activity.jsonl"
if [ -f "$ACTIVITY_LOG" ]; then
    # 从 activity log 统计实际操作数
    hook_writes="$(jq -r 'select(.event == "write" or .event == "edit")' "$ACTIVITY_LOG" 2>/dev/null | wc -l)"
    hook_cmds="$(jq -r 'select(.event == "bash")' "$ACTIVITY_LOG" 2>/dev/null | wc -l)"
    [ "$hook_writes" -gt 0 ] || [ "$hook_cmds" -gt 0 ] && \
        dt_info "  操作日志: 文件写入/编辑 $hook_writes 次, 命令执行 $hook_cmds 次"

    # 如果 Stop hook 捕获了 transcript，生成对话摘要
    transcript_ref="$(jq -r 'select(.event == "stop") | .transcript' "$ACTIVITY_LOG" 2>/dev/null | tail -1)"
    if [ -n "$transcript_ref" ] && [ -f "$transcript_ref" ] && [ ! -f "$SESSION_DIR/transcript.jsonl" ]; then
        cp "$transcript_ref" "$SESSION_DIR/transcript.jsonl" 2>/dev/null || true
    fi
fi

# 生成对话摘要（如有 transcript）
if [ -f "$SESSION_DIR/transcript.jsonl" ] && [ ! -f "$SESSION_DIR/conversation.md" ]; then
    _extract_conversation "$SESSION_DIR/transcript.jsonl" "$SESSION_DIR/conversation.md"
fi

# ──────────────────────────────────────
# 5) 收尾
# ──────────────────────────────────────
rm -f "$DEVTRACK_DIR/.active_session"

dt_yaml_set "$DEVTRACK_STATE" "updated_at" "$(dt_iso_timestamp)"
dt_yaml_set "$DEVTRACK_STATE" "last_checkpoint" "$SESSION_ID"
dt_timeline_append "session_end" "会话结束: $SESSION_ID - $summary ($local_count 文件备份, $pkg_size)"

"$SCRIPT_DIR/devtrack-context.sh" > /dev/null 2>&1 || true
if [ -d ".ccb/history" ]; then
    cp "$DEVTRACK_CONTEXT" ".ccb/history/devtrack-${SESSION_ID}.md" 2>/dev/null || true
fi

dt_info ""
dt_info "会话已结束: $SESSION_ID"
dt_info "摘要: $summary"
dt_info ""
dt_info "回滚包代表当前的可用状态。下次出问题时:"
dt_info "  devtrack 回滚            预演"
dt_info "  devtrack 回滚 --apply    执行恢复"
dt_info "  $ROLLBACK_DIR/verify.sh  验证回滚结果"

finish_ok=1
