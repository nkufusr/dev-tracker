#!/bin/bash
# devtrack context: Generate AI-readable context summary
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
用法: devtrack 上下文 [选项]

生成 AI 可读的当前开发状态摘要。
输出写入 .devtrack/context.md 并打印到标准输出。

选项:
  --brief                 简短摘要（仅任务和焦点）
  --stdout-only           仅打印到标准输出，不更新 context.md
  -h, --help              显示帮助
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

# Read project name
project_name="$(grep -A 2 '^project:' "$DEVTRACK_CONFIG" | grep 'name:' | head -1 | sed -E 's/.*name:\s*"?([^"]*)"?.*/\1/')"
[ -z "$project_name" ] && project_name="$(basename "$PWD")"

now="$(date '+%Y-%m-%d %H:%M')"

# Read state.yaml fields
read_focus_task() {
    grep -A 3 '^current_focus:' "$DEVTRACK_STATE" 2>/dev/null | grep 'task:' | head -1 | sed -E 's/.*task:\s*"?([^"]*)"?.*/\1/'
}
read_focus_status() {
    grep -A 3 '^current_focus:' "$DEVTRACK_STATE" 2>/dev/null | grep 'status:' | head -1 | sed -E 's/.*status:\s*"?([^"]*)"?.*/\1/'
}
read_focus_blocker() {
    grep -A 3 '^current_focus:' "$DEVTRACK_STATE" 2>/dev/null | grep 'blocker:' | head -1 | sed -E 's/.*blocker:\s*"?([^"]*)"?.*/\1/'
}
read_last_checkpoint() {
    dt_yaml_get "$DEVTRACK_STATE" "last_checkpoint" ""
}

# Parse active_tasks block from state.yaml
# Outputs lines like: STATUS|DESCRIPTION|DEPENDS
parse_active_tasks() {
    local in_tasks=0
    local desc="" status="" depends=""
    local flushed=0
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^active_tasks:'; then
            in_tasks=1; continue
        fi
        if [ "$in_tasks" -eq 1 ]; then
            if echo "$line" | grep -qE '^[a-z_]' ; then
                [ -n "$desc" ] && echo "${status}|${desc}|${depends}"
                flushed=1
                break
            fi
            if echo "$line" | grep -qE '^\s+- id:'; then
                [ -n "$desc" ] && echo "${status}|${desc}|${depends}"
                desc=""; status=""; depends=""
                continue
            fi
            if echo "$line" | grep -qE '^\s+description:'; then
                desc="$(echo "$line" | sed -E 's/.*description:\s*"?([^"]*)"?.*/\1/')"
            elif echo "$line" | grep -qE '^\s+status:'; then
                status="$(echo "$line" | sed -E 's/.*status:\s*"?([^"]*)"?.*/\1/')"
            elif echo "$line" | grep -qE '^\s+depends_on:'; then
                depends="$(echo "$line" | sed -E 's/.*depends_on:\s*\[?(.*)\]?.*/\1/' | tr -d '[] ')"
            fi
        fi
    done < "$DEVTRACK_STATE"
    [ "$flushed" -eq 0 ] && [ -n "$desc" ] && echo "${status}|${desc}|${depends}"
}

# Parse decisions block
parse_decisions() {
    local in_decisions=0
    local desc="" date="" rationale=""
    local flushed=0
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^decisions:'; then
            in_decisions=1; continue
        fi
        if [ "$in_decisions" -eq 1 ]; then
            if echo "$line" | grep -qE '^[a-z_]'; then
                [ -n "$desc" ] && echo "${date}|${desc}|${rationale}"
                flushed=1
                break
            fi
            if echo "$line" | grep -qE '^\s+- id:'; then
                [ -n "$desc" ] && echo "${date}|${desc}|${rationale}"
                desc=""; date=""; rationale=""
                continue
            fi
            if echo "$line" | grep -qE '^\s+description:'; then
                desc="$(echo "$line" | sed -E 's/.*description:\s*"?([^"]*)"?.*/\1/')"
            elif echo "$line" | grep -qE '^\s+date:'; then
                date="$(echo "$line" | sed -E 's/.*date:\s*"?([^"]*)"?.*/\1/')"
            elif echo "$line" | grep -qE '^\s+rationale:'; then
                rationale="$(echo "$line" | sed -E 's/.*rationale:\s*"?([^"]*)"?.*/\1/')"
            fi
        fi
    done < "$DEVTRACK_STATE"
    [ "$flushed" -eq 0 ] && [ -n "$desc" ] && echo "${date}|${desc}|${rationale}"
}

# Parse known_risks (simple list)
parse_risks() {
    local in_risks=0
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^known_risks:'; then
            in_risks=1; continue
        fi
        if [ "$in_risks" -eq 1 ]; then
            if echo "$line" | grep -qE '^[a-z]' && ! echo "$line" | grep -qE '^\s'; then
                break
            fi
            if echo "$line" | grep -qE '^\s+- "'; then
                echo "$line" | sed -E 's/^\s+- "?([^"]*)"?$/\1/'
            fi
        fi
    done < "$DEVTRACK_STATE"
}

# Get recent timeline events
recent_events() {
    local count="${1:-5}"
    [ -f "$DEVTRACK_TIMELINE" ] || return 0

    local ts="" type="" desc=""
    local collected=0
    local results=""

    while IFS= read -r line; do
        if echo "$line" | grep -qE '^\s+- timestamp:'; then
            # Flush previous event
            if [ -n "$ts" ] && [ -n "$type" ]; then
                results="- [$type] $desc ($ts)
$results"
                collected=$((collected + 1))
            fi
            ts="$(echo "$line" | sed -E 's/.*timestamp:\s*"?([^"]*)"?.*/\1/')"
            type=""; desc=""
        elif echo "$line" | grep -qE '^\s+type:'; then
            type="$(echo "$line" | sed -E 's/.*type:\s*"?([^"]*)"?.*/\1/')"
        elif echo "$line" | grep -qE '^\s+description:'; then
            desc="$(echo "$line" | sed -E 's/.*description:\s*"?([^"]*)"?.*/\1/')"
        fi
    done < "$DEVTRACK_TIMELINE"

    # Flush last
    if [ -n "$ts" ] && [ -n "$type" ]; then
        results="- [$type] $desc ($ts)
$results"
    fi

    echo "$results" | head -n "$count" | sed '/^$/d' || true
}

# Build the context (disable errexit for compound block since empty grep/sed is ok)
set +e
{
    echo "# $project_name 开发状态 ($now)"
    echo ""

    # 当前焦点
    focus_task="$(read_focus_task)"
    focus_status="$(read_focus_status)"
    focus_blocker="$(read_focus_blocker)"

    if [ -n "$focus_task" ]; then
        echo "## 当前焦点"
        status_tag="$(echo "$focus_status" | tr '[:lower:]' '[:upper:]')"
        if [ -n "$focus_blocker" ]; then
            echo "$focus_task [$status_tag: $focus_blocker]"
        else
            echo "$focus_task [$status_tag]"
        fi
        echo ""
    fi

    # 最近检查点
    last_cp="$(read_last_checkpoint)"
    if [ -n "$last_cp" ]; then
        cp_summary="$DEVTRACK_CHECKPOINTS/$last_cp/summary.md"
        echo "## 最近检查点"
        echo "- ID: \`$last_cp\`"
        if [ -f "$cp_summary" ]; then
            desc_line="$(sed -n '/^## \(描述\|Description\)/,/^##/p' "$cp_summary" | grep -v '^##' | head -3 | sed '/^$/d')"
            [ -n "$desc_line" ] && echo "- $desc_line"
        fi
        echo "- 回滚: \`devtrack 回滚 $last_cp\`"
        echo ""
    fi

    # 活跃任务
    tasks="$(parse_active_tasks)"
    if [ -n "$tasks" ]; then
        echo "## 活跃任务"
        task_num=1
        echo "$tasks" | while IFS='|' read -r status desc depends; do
            status_tag="$(echo "$status" | tr '[:lower:]' '[:upper:]')"
            dep_info=""
            [ -n "$depends" ] && dep_info=" (依赖: $depends)"
            echo "$task_num. [$status_tag] $desc$dep_info"
            task_num=$((task_num + 1))
        done
        echo ""
    fi

    if [ "$brief" -eq 0 ]; then
        # 关键决策
        decisions="$(parse_decisions)"
        if [ -n "$decisions" ]; then
            echo "## 关键决策"
            echo "$decisions" | while IFS='|' read -r date desc rationale; do
                echo "- [$date] $desc"
                [ -n "$rationale" ] && echo "  原因: $rationale"
            done
            echo ""
        fi

        # 已知风险
        risks="$(parse_risks)"
        if [ -n "$risks" ]; then
            echo "## 已知风险"
            echo "$risks" | while IFS= read -r risk; do
                echo "- $risk"
            done
            echo ""
        fi

        # 近期活动
        events="$(recent_events 5)"
        if [ -n "$events" ]; then
            echo "## 近期活动"
            echo "$events"
            echo ""
        fi

        # 可用检查点
        checkpoints="$(dt_list_checkpoints)"
        if [ -n "$checkpoints" ]; then
            echo "## 可用检查点"
            echo "$checkpoints" | head -5 | while IFS= read -r cp; do
                echo "- \`$cp\`"
            done
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
