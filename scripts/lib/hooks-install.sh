#!/bin/bash
# 安装/合并 devtrack hooks 到 AI 工具配置文件
# 支持: Claude Code (.claude/settings.json), Cursor (.cursor/hooks.json)

_hooks_our_marker="devtrack hook"

# 生成 devtrack hook JSON 配置块
_hooks_json() {
    cat << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit|Bash|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "devtrack hook post-tool-use",
            "async": true,
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "devtrack hook stop",
            "async": true,
            "timeout": 15
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "devtrack hook user-prompt",
            "async": true,
            "timeout": 5
          }
        ]
      }
    ]
  }
}
EOF
}

# 安装 Claude Code hooks (.claude/settings.json)
install_claude_hooks() {
    local settings_file=".claude/settings.json"

    mkdir -p ".claude"

    # 已安装则跳过
    if [ -f "$settings_file" ] && grep -q "$_hooks_our_marker" "$settings_file" 2>/dev/null; then
        return 0
    fi

    local our_hooks
    our_hooks="$(_hooks_json)"

    if [ ! -f "$settings_file" ] || [ ! -s "$settings_file" ]; then
        echo "$our_hooks" > "$settings_file"
        return 0
    fi

    # 合并到现有文件
    local merged
    merged="$(jq -s --argjson new "$our_hooks" '
        .[0] as $ex |
        $ex + {
            "hooks": {
                "PostToolUse": (($ex.hooks.PostToolUse // []) + $new.hooks.PostToolUse),
                "Stop": (($ex.hooks.Stop // []) + $new.hooks.Stop),
                "UserPromptSubmit": (($ex.hooks.UserPromptSubmit // []) + $new.hooks.UserPromptSubmit)
            }
        }
    ' "$settings_file" /dev/null 2>/dev/null)"

    if [ -n "$merged" ]; then
        echo "$merged" > "$settings_file"
        return 0
    else
        # jq 失败时直接写入（可能原文件格式有问题）
        echo "$our_hooks" > "$settings_file"
        return 0
    fi
}

# 移除 devtrack hooks（devtrack disable 时调用）
remove_claude_hooks() {
    local settings_file=".claude/settings.json"
    [ -f "$settings_file" ] || return 0
    grep -q "$_hooks_our_marker" "$settings_file" 2>/dev/null || return 0

    local cleaned
    cleaned="$(jq '
        .hooks.PostToolUse = [.hooks.PostToolUse[]? | select(.hooks[].command | test("devtrack hook") | not)] |
        .hooks.Stop = [.hooks.Stop[]? | select(.hooks[].command | test("devtrack hook") | not)] |
        .hooks.UserPromptSubmit = [.hooks.UserPromptSubmit[]? | select(.hooks[].command | test("devtrack hook") | not)]
    ' "$settings_file" 2>/dev/null)"

    [ -n "$cleaned" ] && echo "$cleaned" > "$settings_file"
}

# 检查 Claude Code hooks 是否已安装
check_claude_hooks() {
    local settings_file=".claude/settings.json"
    [ -f "$settings_file" ] && grep -q "$_hooks_our_marker" "$settings_file" 2>/dev/null
}
