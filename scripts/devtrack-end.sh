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
        rm -f "$DEVTRACK_DIR/.active_session"
        failure_summary="${summary:-devtrack 结束失败}"
        _update_session_meta "failed" "$failure_summary" "$total_changes"
    fi

    exit "$code"
}

trap '_cleanup_devtrack_end' EXIT INT TERM

if [ ! -f "$DEVTRACK_DIR/.active_session" ]; then
    dt_die "没有活跃会话。请先运行 'devtrack 开始'"
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
changed_files=""
deleted_files=""
current_manifest="$(mktemp)"
snapshot_manifest_only "$current_manifest"

if [ -f "$BASELINE" ]; then
    dt_info "正在对比变更..."
    declare -A baseline_sha=()
    declare -A current_sha=()

    while IFS='|' read -r fpath expected_sha; do
        [ -n "$fpath" ] || continue
        baseline_sha["$fpath"]="$expected_sha"
    done < <(jq -r '.local_files[] | "\(.path)|\(.sha256)"' "$BASELINE")

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
    done < <(jq -r '.local_files[] | "\(.path)|\(.sha256)"' "$current_manifest")

    for fpath in "${!baseline_sha[@]}"; do
        if [ -z "${current_sha[$fpath]+x}" ]; then
            deleted_files="${deleted_files}${fpath}\n"
            deleted_count=$((deleted_count + 1))
        fi
    done
fi

total_changes=$((changed_count + deleted_count + added_count))
dt_info "本次会话变更: $changed_count 个文件修改, $deleted_count 个文件删除, $added_count 个文件新增"

# 自动摘要
if [ -z "$summary" ]; then
    if [ "$total_changes" -gt 0 ]; then
        if [ "$changed_count" -le 5 ] && [ "$changed_count" -gt 0 ] && [ "$added_count" -eq 0 ] && [ "$deleted_count" -eq 0 ]; then
            file_list="$(echo -e "$changed_files" | sed '/^$/d' | sed 's|.*/||' | tr '\n' ', ' | sed 's/,$//')"
            summary="修改了: $file_list"
        elif [ "$added_count" -le 5 ] && [ "$added_count" -gt 0 ] && [ "$changed_count" -eq 0 ] && [ "$deleted_count" -eq 0 ]; then
            file_list="$(echo -e "$added_files" | sed '/^$/d' | sed 's|.*/||' | tr '\n' ', ' | sed 's/,$//')"
            summary="新增了: $file_list"
        else
            summary="变更了 $total_changes 个文件"
        fi
    else
        summary="无文件变更"
    fi
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
