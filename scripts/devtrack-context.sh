#!/bin/bash
# devtrack context: 生成 AI 可读的开发状态摘要
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
用法: devtrack 上下文 [选项]

生成 AI 可读的当前开发状态摘要。
输出写入 .devtrack/context.md 并打印到标准输出。

选项:
  --brief        简短模式（只显示上次会话 + 回滚包状态）
  --stdout-only  仅打印到标准输出，不更新 context.md
  -h, --help     显示帮助
EOF
}

brief=0
stdout_only=0
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)     usage; exit 0 ;;
        --brief)       brief=1; shift ;;
        --stdout-only) stdout_only=1; shift ;;
        *)             echo "未知选项: $1" >&2; usage >&2; exit 1 ;;
    esac
done

dt_require_init

project_name="$(grep -A 2 '^project:' "$DEVTRACK_CONFIG" 2>/dev/null | grep 'name:' | head -1 | sed -E 's/.*name:\s*"?([^"]*)"?.*/\1/')"
[ -z "$project_name" ] && project_name="$(basename "$PWD")"
now="$(date '+%Y-%m-%d %H:%M')"

# ── 辅助函数 ──────────────────────────────────────────────

# 读取上次已完成会话
_ctx_last_session() {
    local active=""
    [ -f "$DEVTRACK_DIR/.active_session" ] && active="$(cat "$DEVTRACK_DIR/.active_session")"
    for sid in $(ls -1r "$DEVTRACK_SESSIONS" 2>/dev/null); do
        [ "$sid" = "$active" ] && continue
        local status
        status="$(grep '^status:' "$DEVTRACK_SESSIONS/$sid/session.yaml" 2>/dev/null | sed -E 's/^status:\s*"?([^"]*)"?$/\1/')"
        if [ "$status" = "completed" ]; then
            echo "$sid"
            return
        fi
    done
}

# 读 state.yaml 活跃任务
_ctx_active_tasks() {
    local in_tasks=0 desc="" status="" depends="" flushed=0
    while IFS= read -r line; do
        echo "$line" | grep -qE '^active_tasks:' && { in_tasks=1; continue; }
        [ "$in_tasks" -eq 0 ] && continue
        echo "$line" | grep -qE '^[a-z_]' && { [ -n "$desc" ] && echo "${status}|${desc}|${depends}"; flushed=1; break; }
        echo "$line" | grep -qE '^\s+- id:' && { [ -n "$desc" ] && echo "${status}|${desc}|${depends}"; desc=""; status=""; depends=""; continue; }
        echo "$line" | grep -qE '^\s+description:' && desc="$(echo "$line" | sed -E 's/.*description:\s*"?([^"]*)"?.*/\1/')"
        echo "$line" | grep -qE '^\s+status:' && status="$(echo "$line" | sed -E 's/.*status:\s*"?([^"]*)"?.*/\1/')"
        echo "$line" | grep -qE '^\s+depends_on:' && depends="$(echo "$line" | sed -E 's/.*depends_on:\s*\[?(.*)\]?.*/\1/' | tr -d '[] ')"
    done < "$DEVTRACK_STATE" 2>/dev/null
    [ "$flushed" -eq 0 ] && [ -n "$desc" ] && echo "${status}|${desc}|${depends}"
}

# 读 state.yaml 已知风险
_ctx_risks() {
    local in_risks=0
    while IFS= read -r line; do
        echo "$line" | grep -qE '^known_risks:' && { in_risks=1; continue; }
        [ "$in_risks" -eq 0 ] && continue
        echo "$line" | grep -qE '^[a-z]' && ! echo "$line" | grep -qE '^\s' && break
        echo "$line" | grep -qE '^\s+- ' && echo "$line" | sed -E 's/^\s+- "?([^"]*)"?$/\1/'
    done < "$DEVTRACK_STATE" 2>/dev/null
}

# 读项目文档中的"待完成"章节（自动检测文档文件）
_ctx_project_docs() {
    # 优先用 config.yaml 中指定的文档
    local doc_files=""
    doc_files="$(grep -A 10 '^project_docs:' "$DEVTRACK_CONFIG" 2>/dev/null | grep -E '^\s+- ' | sed -E 's/^\s+- "?([^"]*)"?$/\1/' || true)"

    # 自动检测常见文档
    if [ -z "$doc_files" ]; then
        for candidate in PROGRESS.md README.md docs/PROGRESS.md docs/README.md; do
            [ -f "$candidate" ] && doc_files="$doc_files $candidate"
        done
    fi

    [ -z "$(echo "$doc_files" | tr -d ' ')" ] && return

    for doc in $doc_files; do
        [ -f "$doc" ] || continue
        # 提取待完成/TODO/未完成章节
        local section=""
        section="$(awk '/^## .*[待未][完成]|^## .*TODO|^## .*Pending|^## .*Next/{found=1; next} found && /^## /{exit} found{print}' "$doc" | grep -v '^$' | head -10)"
        if [ -n "$section" ]; then
            echo "### 来自 $doc"
            echo "$section"
            echo ""
        fi
    done
}

# ── 生成上下文 ────────────────────────────────────────────

set +e
{
    echo "# $project_name 开发状态 ($now)"
    echo ""

    # ── 1. 上次会话完成的工作（最重要，放最前） ──
    last_sid="$(_ctx_last_session)"
    if [ -n "$last_sid" ]; then
        last_dir="$DEVTRACK_SESSIONS/$last_sid"
        last_summary="$(grep '^summary:' "$last_dir/session.yaml" 2>/dev/null | sed -E 's/^summary:\s*"?([^"]*)"?$/\1/')"
        last_ended="$(grep '^ended_at:' "$last_dir/session.yaml" 2>/dev/null | sed -E 's/^ended_at:\s*"?([^"]*)"?$/\1/')"
        last_changed="$(grep '^files_changed:' "$last_dir/session.yaml" 2>/dev/null | sed -E 's/^files_changed:\s*//')"

        echo "## 上次会话完成的工作"
        echo "时间: $last_ended | 变更: ${last_changed:-0} 个文件"
        echo "$last_summary"

        # 显示具体变更文件（≤5 个时展开）
        if [ -f "$last_dir/changes.md" ] && [ "${last_changed:-0}" -le 5 ] && [ "${last_changed:-0}" -gt 0 ]; then
            grep '^- /' "$last_dir/changes.md" 2>/dev/null | sed "s|$(pwd)/||" | head -5 | while IFS= read -r f; do
                echo "  $f"
            done
        fi
        echo ""

        # ── 活动时间线（来自 hooks 自动捕获）──
        if [ -f "$last_dir/activity.jsonl" ]; then
            local has_events=0
            # 提取用户提示和文件操作（最多 8 条）
            local timeline=""
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                evt="$(echo "$line" | jq -r '.event // ""' 2>/dev/null)"
                ts_raw="$(echo "$line" | jq -r '.ts // ""' 2>/dev/null)"
                ts_short="${ts_raw#*T}"  # 只取时间部分 HH:MM:SS

                case "$evt" in
                    user_prompt)
                        prompt="$(echo "$line" | jq -r '.prompt // ""' 2>/dev/null | head -c 80)"
                        [ -n "$prompt" ] && timeline="${timeline}- $ts_short [用户] $prompt\n" && has_events=1 ;;
                    write)
                        file="$(echo "$line" | jq -r '.file // ""' 2>/dev/null)"
                        [ -n "$file" ] && timeline="${timeline}- $ts_short 写入: $file\n" && has_events=1 ;;
                    edit)
                        file="$(echo "$line" | jq -r '.file // ""' 2>/dev/null)"
                        [ -n "$file" ] && timeline="${timeline}- $ts_short 编辑: $file\n" && has_events=1 ;;
                    bash)
                        cmd="$(echo "$line" | jq -r '.cmd // ""' 2>/dev/null | head -c 60)"
                        [ -n "$cmd" ] && timeline="${timeline}- $ts_short 执行: $cmd\n" && has_events=1 ;;
                esac
            done < "$last_dir/activity.jsonl"

            if [ "$has_events" -eq 1 ] && [ -n "$timeline" ]; then
                echo "### 操作时间线（自动捕获）"
                echo -e "$timeline" | head -8 | sed '/^$/d'
                echo ""
            fi
        fi

        # ── 对话摘要（来自 transcript 提取）──
        if [ "$brief" -eq 0 ] && [ -f "$last_dir/conversation.md" ] && [ -s "$last_dir/conversation.md" ]; then
            echo "### 上次对话摘要"
            # 只显示前 15 行
            head -15 "$last_dir/conversation.md" | grep -v "^# \|^会话:" | sed '/^$/d' | head -10
            echo ""
        fi
    fi

    # ── 2. 当前回滚包（确认可回滚的基线） ──
    ROLLBACK_DIR="$DEVTRACK_DIR/rollback"
    if [ -f "$ROLLBACK_DIR/manifest.json" ]; then
        rb_time="$(jq -r '.created_at' "$ROLLBACK_DIR/manifest.json")"
        rb_count="$(jq '.local_files | length' "$ROLLBACK_DIR/manifest.json")"
        rb_desc="$(jq -r '.description // empty' "$ROLLBACK_DIR/manifest.json")"
        echo "## 可用回滚包"
        echo "时间: $rb_time | $rb_count 个文件"
        [ -n "$rb_desc" ] && echo "内容: $rb_desc"
        echo "回滚: \`devtrack 回滚 --apply\`"
        echo ""
    fi

    if [ "$brief" -eq 1 ]; then
        # brief 模式到此结束
        true
    else
        # ── 3. 活跃任务（来自 state.yaml，可选维护） ──
        tasks="$(_ctx_active_tasks)"
        if [ -n "$tasks" ]; then
            echo "## 活跃任务"
            num=1
            echo "$tasks" | while IFS='|' read -r status desc depends; do
                tag="$(echo "$status" | tr '[:lower:]' '[:upper:]')"
                dep=""
                [ -n "$depends" ] && dep=" (依赖: $depends)"
                echo "$num. [$tag] $desc$dep"
                num=$((num + 1))
            done
            echo ""
        fi

        # ── 4. 已知风险（来自 state.yaml） ──
        risks="$(_ctx_risks)"
        if [ -n "$risks" ]; then
            echo "## 已知风险"
            echo "$risks" | while IFS= read -r r; do
                echo "- $r"
            done
            echo ""
        fi

        # ── 5. 项目待完成功能（自动从文档提取） ──
        proj_docs="$(_ctx_project_docs)"
        if [ -n "$proj_docs" ]; then
            echo "## 项目待完成功能"
            echo "$proj_docs"
        fi

        # ── 6. 近期会话历史（最近 3 次） ──
        session_history=""
        count=0
        for sid in $(ls -1r "$DEVTRACK_SESSIONS" 2>/dev/null); do
            [ "$count" -ge 3 ] && break
            sfile="$DEVTRACK_SESSIONS/$sid/session.yaml"
            [ -f "$sfile" ] || continue
            s_status="$(grep '^status:' "$sfile" | sed -E 's/^status:\s*"?([^"]*)"?$/\1/')"
            s_summary="$(grep '^summary:' "$sfile" | sed -E 's/^summary:\s*"?([^"]*)"?$/\1/')"
            s_ended="$(grep '^ended_at:' "$sfile" | sed -E 's/^ended_at:\s*"?([^"]*)"?$/\1/')"
            [ -z "$s_summary" ] && continue
            case "$s_status" in
                completed)  tag="完成" ;;
                abandoned)  tag="废弃" ;;
                active)     tag="进行中" ;;
                *)          tag="$s_status" ;;
            esac
            session_history="${session_history}- [$tag] $s_summary (${s_ended:-进行中})\n"
            count=$((count + 1))
        done
        if [ -n "$session_history" ]; then
            echo "## 近期会话"
            echo -e "$session_history" | sed '/^$/d'
            echo ""
        fi
    fi

} > "$DEVTRACK_DIR/.context_tmp.md"
set -e

if [ "$stdout_only" -eq 0 ]; then
    mv "$DEVTRACK_DIR/.context_tmp.md" "$DEVTRACK_CONTEXT"
    cat "$DEVTRACK_CONTEXT"
else
    cat "$DEVTRACK_DIR/.context_tmp.md"
    rm -f "$DEVTRACK_DIR/.context_tmp.md"
fi
