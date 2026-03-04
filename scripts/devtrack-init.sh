#!/bin/bash
# devtrack init: Initialize dev-tracker for a project
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
用法: devtrack 初始化 [选项]

在当前目录初始化 .devtrack/。

选项:
  --name <名称>           项目名称（默认：目录名）
  --remote-host <主机>    远程服务器地址/IP
  --remote-user <用户>    远程 SSH 用户
  --remote-key <路径>     SSH 密钥路径
  --force                 强制重新初始化
  -h, --help              显示帮助
EOF
}

project_name="$(basename "$PWD")"
remote_host=""
remote_user=""
remote_key=""
force=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)       usage; exit 0 ;;
        --name)          project_name="$2"; shift 2 ;;
        --remote-host)   remote_host="$2"; shift 2 ;;
        --remote-user)   remote_user="$2"; shift 2 ;;
        --remote-key)    remote_key="$2"; shift 2 ;;
        --force)         force=1; shift ;;
        *)               echo "未知选项: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ -d "$DEVTRACK_DIR" ] && [ "$force" -eq 0 ]; then
    dt_info ".devtrack/ 已存在。使用 --force 重新初始化。"
    exit 0
fi

dt_info "正在初始化 dev-tracker: $project_name"

mkdir -p "$DEVTRACK_DIR"
mkdir -p "$DEVTRACK_SESSIONS"
mkdir -p "$DEVTRACK_CHECKPOINTS"

# config.yaml
if [ ! -f "$DEVTRACK_CONFIG" ] || [ "$force" -eq 1 ]; then
    cat > "$DEVTRACK_CONFIG" << EOF
project:
  name: "$project_name"
  root: "$PWD"

tracking:
  local_paths:
    - "**/*.kt"
    - "**/*.java"
    - "**/*.py"
    - "**/*.js"
    - "**/*.ts"
    - "**/build.gradle.kts"
    - "**/build.gradle"
    - "**/package.json"
    - "**/requirements.txt"
  ignore_paths:
    - "build/"
    - ".gradle/"
    - "node_modules/"
    - "*.class"
    - ".devtrack/"
EOF

    if [ -n "$remote_host" ]; then
        cat >> "$DEVTRACK_CONFIG" << EOF

remote:
  host: "$remote_host"
  user: "${remote_user:-ubuntu}"
  ssh_key: "$remote_key"
  paths: []
  services: []
EOF
    fi

    cat >> "$DEVTRACK_CONFIG" << 'EOF'

commands:
  build: ""
  test: ""
  health: ""
EOF
    dt_info "已创建 config.yaml（请编辑以自定义追踪路径和构建命令）"
fi

# state.yaml
if [ ! -f "$DEVTRACK_STATE" ] || [ "$force" -eq 1 ]; then
    cat > "$DEVTRACK_STATE" << EOF
updated_at: "$(dt_iso_timestamp)"
last_checkpoint: ""

current_focus:
  task: ""
  status: "idle"
  blocker: ""

active_tasks: []

decisions: []

known_risks: []
EOF
    dt_info "已创建 state.yaml"
fi

# timeline.yaml
if [ ! -f "$DEVTRACK_TIMELINE" ] || [ "$force" -eq 1 ]; then
    cat > "$DEVTRACK_TIMELINE" << EOF
events:
  - timestamp: "$(dt_iso_timestamp)"
    type: "init"
    description: "dev-tracker 已初始化: $project_name"
EOF
    dt_info "已创建 timeline.yaml"
fi

# context.md placeholder
if [ ! -f "$DEVTRACK_CONTEXT" ]; then
    cat > "$DEVTRACK_CONTEXT" << EOF
# $project_name 开发状态

尚无检查点。完成工作后运行 \`devtrack 检查点 <标签>\` 创建快照。
EOF
    dt_info "已创建 context.md"
fi

dt_info "dev-tracker 已初始化于 .devtrack/"
dt_info "后续步骤:"
dt_info "  1. 编辑 .devtrack/config.yaml 设置追踪路径、构建命令、远程服务器"
dt_info "  2. 编辑 .devtrack/state.yaml 设置当前任务和焦点"
dt_info "  3. 运行 'devtrack 检查点 <标签>' 创建第一个快照"
