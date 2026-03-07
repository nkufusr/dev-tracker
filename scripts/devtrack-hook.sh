#!/bin/bash
# devtrack hook: 处理 Claude Code / Cursor hook 事件
# 调用方式: devtrack hook <event-type>
# 通过 stdin 接收 JSON 事件数据

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# 必须在已初始化的 devtrack 项目中且有活跃会话
[ -d "$DEVTRACK_DIR" ] || exit 0
[ -f "$DEVTRACK_DIR/.active_session" ] || exit 0

SESSION_ID="$(cat "$DEVTRACK_DIR/.active_session")"
SESSION_DIR="$DEVTRACK_SESSIONS/$SESSION_ID"
ACTIVITY_LOG="$SESSION_DIR/activity.jsonl"

mkdir -p "$SESSION_DIR"

event_type="${1:-}"
ts="$(date '+%Y-%m-%dT%H:%M:%S')"

# 读取 stdin（hook 事件 JSON）
input="$(cat 2>/dev/null)"
[ -z "$input" ] && exit 0

case "$event_type" in

    # ── PostToolUse: 记录文件写入/编辑/Bash 命令 ────────────────
    post-tool-use)
        tool_name="$(echo "$input" | jq -r '.tool_name // "unknown"' 2>/dev/null)"

        case "$tool_name" in
            Write|Edit|MultiEdit|NotebookEdit)
                file_path="$(echo "$input" | jq -r '
                    .tool_input.path //
                    .tool_input.file_path //
                    .tool_input.notebook_path // ""
                ' 2>/dev/null)"
                [ -z "$file_path" ] && exit 0

                # 转为相对路径
                rel_path="${file_path#$(pwd)/}"
                rel_path="${rel_path#./}"

                event_label="write"
                [ "$tool_name" = "Edit" ] || [ "$tool_name" = "MultiEdit" ] && event_label="edit"

                echo "{\"ts\":\"$ts\",\"event\":\"$event_label\",\"tool\":\"$tool_name\",\"file\":\"$rel_path\"}" >> "$ACTIVITY_LOG"
                ;;

            Bash)
                cmd="$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)"
                [ -z "$cmd" ] && exit 0
                # 只记录命令的第一行（去掉多余内容），最多 200 字符
                cmd_short="$(echo "$cmd" | head -1 | head -c 200)"
                cmd_escaped="$(echo "$cmd_short" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/ /g')"
                echo "{\"ts\":\"$ts\",\"event\":\"bash\",\"tool\":\"Bash\",\"cmd\":\"$cmd_escaped\"}" >> "$ACTIVITY_LOG"
                ;;
        esac
        ;;

    # ── UserPromptSubmit: 记录用户的输入 ─────────────────────────
    user-prompt)
        prompt="$(echo "$input" | jq -r '.prompt // ""' 2>/dev/null)"
        [ -z "$prompt" ] && exit 0
        # 记录前 300 字符
        prompt_short="$(echo "$prompt" | head -c 300 | tr '\n' ' ')"
        prompt_escaped="$(echo "$prompt_short" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        echo "{\"ts\":\"$ts\",\"event\":\"user_prompt\",\"prompt\":\"$prompt_escaped\"}" >> "$ACTIVITY_LOG"
        # UserPromptSubmit 的 stdout 会传给 Claude，不要输出任何内容
        ;;

    # ── Stop: 捕获完整对话记录 ────────────────────────────────────
    stop)
        transcript_path="$(echo "$input" | jq -r '.transcript_path // ""' 2>/dev/null)"

        echo "{\"ts\":\"$ts\",\"event\":\"stop\",\"transcript\":\"$transcript_path\"}" >> "$ACTIVITY_LOG"

        # 把 transcript 复制到 session 目录保存
        if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
            cp "$transcript_path" "$SESSION_DIR/transcript.jsonl" 2>/dev/null || true

            # 即时生成简明对话摘要
            _generate_conversation_summary "$SESSION_DIR/transcript.jsonl" "$SESSION_DIR/conversation.md"
        fi
        ;;

    *)
        exit 0
        ;;
esac

exit 0

# ── 对话摘要生成函数 ──────────────────────────────────────────────
_generate_conversation_summary() {
    local transcript="$1"
    local output="$2"
    [ -f "$transcript" ] || return 0

    {
        echo "# 对话摘要"
        echo ""
        echo "会话: $SESSION_ID"
        echo ""

        # 提取用户消息和 AI 文字回复
        # transcript.jsonl 格式：每行一个 JSON 消息
        local turn=0
        while IFS= read -r line; do
            [ -z "$line" ] && continue

            role="$(echo "$line" | jq -r '.role // ""' 2>/dev/null)"
            msg_type="$(echo "$line" | jq -r '.type // ""' 2>/dev/null)"

            # 处理 {"role": "user", "content": "..."} 格式
            if [ "$role" = "user" ]; then
                content="$(echo "$line" | jq -r '
                    if (.content | type) == "string" then .content
                    elif (.content | type) == "array" then
                        [.content[] | select(.type == "text") | .text] | join(" ")
                    else "" end
                ' 2>/dev/null | head -c 200)"
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
                ' 2>/dev/null | head -c 300)"
                if [ -n "$content" ]; then
                    echo "**[AI]** $content"
                    echo ""
                fi
            fi

        done < "$transcript"

    } > "$output" 2>/dev/null
}
