#!/bin/bash
# devtrack status: 显示当前开发状态
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
用法: devtrack 状态 [选项]

从 .devtrack/state.yaml 读取并显示当前开发状态。

选项:
  --json                  以 JSON 格式输出（需要 jq）
  -h, --help              显示帮助
EOF
}

json_mode=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --json)    json_mode=1; shift ;;
        *)         echo "未知选项: $1" >&2; usage >&2; exit 1 ;;
    esac
done

dt_require_init

if [ ! -f "$DEVTRACK_STATE" ]; then
    dt_info "未找到 state.yaml。请运行 'devtrack 初始化' 创建。"
    exit 0
fi

if [ "$json_mode" -eq 1 ]; then
    dt_require_jq
    python3 -c "
import yaml, json, sys
with open('$DEVTRACK_STATE') as f:
    data = yaml.safe_load(f)
json.dump(data, sys.stdout, indent=2, ensure_ascii=False)
" 2>/dev/null || dt_die "需要 Python3 + PyYAML 才能使用 --json 模式"
    exit 0
fi

echo "=== dev-tracker 状态 ==="
echo ""

updated="$(dt_yaml_get "$DEVTRACK_STATE" "updated_at" "未知")"
echo "最后更新: $updated"

last_cp="$(dt_yaml_get "$DEVTRACK_STATE" "last_checkpoint" "")"
if [ -n "$last_cp" ]; then
    echo "最近检查点: $last_cp"
else
    echo "最近检查点: （无）"
fi
echo ""

# 当前焦点
focus_task="$(grep -A 3 '^current_focus:' "$DEVTRACK_STATE" 2>/dev/null | grep 'task:' | head -1 | sed -E 's/.*task:\s*"?([^"]*)"?.*/\1/' || true)"
focus_status="$(grep -A 3 '^current_focus:' "$DEVTRACK_STATE" 2>/dev/null | grep 'status:' | head -1 | sed -E 's/.*status:\s*"?([^"]*)"?.*/\1/' || true)"
focus_blocker="$(grep -A 3 '^current_focus:' "$DEVTRACK_STATE" 2>/dev/null | grep 'blocker:' | head -1 | sed -E 's/.*blocker:\s*"?([^"]*)"?.*/\1/' || true)"

if [ -n "$focus_task" ]; then
    echo "焦点: $focus_task"
    echo "  状态: $focus_status"
    [ -n "$focus_blocker" ] && echo "  阻塞: $focus_blocker"
    echo ""
fi

# 活跃任务
echo "--- 任务 ---"
in_tasks=0
while IFS= read -r line; do
    if echo "$line" | grep -qE '^active_tasks:'; then
        in_tasks=1; continue
    fi
    if [ "$in_tasks" -eq 1 ]; then
        if echo "$line" | grep -qE '^[a-z_]'; then
            break
        fi
        if echo "$line" | grep -qE '^\s+description:'; then
            desc="$(echo "$line" | sed -E 's/.*description:\s*"?([^"]*)"?.*/\1/')"
        fi
        if echo "$line" | grep -qE '^\s+status:'; then
            status="$(echo "$line" | sed -E 's/.*status:\s*"?([^"]*)"?.*/\1/')"
            status_upper="$(echo "$status" | tr '[:lower:]' '[:upper:]')"
            echo "  [$status_upper] $desc"
        fi
    fi
done < "$DEVTRACK_STATE"
echo ""

# 已知风险
echo "--- 风险 ---"
in_risks=0
while IFS= read -r line; do
    if echo "$line" | grep -qE '^known_risks:'; then
        in_risks=1; continue
    fi
    if [ "$in_risks" -eq 1 ]; then
        if echo "$line" | grep -qE '^[a-z_]'; then
            break
        fi
        if echo "$line" | grep -qE '^\s+- "'; then
            risk="$(echo "$line" | sed -E 's/^\s+- "?([^"]*)"?$/\1/')"
            echo "  ! $risk"
        fi
    fi
done < "$DEVTRACK_STATE"
echo ""

# 检查点概览
echo "--- 检查点 ---"
if [ -d "$DEVTRACK_CHECKPOINTS" ]; then
    count="$(ls -1 "$DEVTRACK_CHECKPOINTS" 2>/dev/null | wc -l)"
    echo "  总计: $count"
    ls -1r "$DEVTRACK_CHECKPOINTS" 2>/dev/null | head -3 | while IFS= read -r cp; do
        echo "  - $cp"
    done
else
    echo "  （无）"
fi
