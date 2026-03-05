#!/bin/bash
# devtrack 状态: 显示简要状态
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

dt_require_init

echo "=== dev-tracker 状态 ==="
echo ""

# 活跃会话
if [ -f "$DEVTRACK_DIR/.active_session" ]; then
    active="$(cat "$DEVTRACK_DIR/.active_session")"
    echo "当前会话: $active （进行中）"
else
    echo "当前会话: 无"
fi

# 最近会话列表
echo ""
echo "--- 历史会话 ---"
for sid in $(ls -1r "$DEVTRACK_SESSIONS" 2>/dev/null | head -5); do
    [ -f "$DEVTRACK_SESSIONS/$sid/session.yaml" ] || continue
    status="$(grep '^status:' "$DEVTRACK_SESSIONS/$sid/session.yaml" | sed -E 's/^status:\s*"?([^"]*)"?$/\1/')"
    summary="$(grep '^summary:' "$DEVTRACK_SESSIONS/$sid/session.yaml" | sed -E 's/^summary:\s*"?([^"]*)"?$/\1/')"
    changed="$(grep '^files_changed:' "$DEVTRACK_SESSIONS/$sid/session.yaml" | sed -E 's/^files_changed:\s*//')"

    case "$status" in
        active)    tag="进行中" ;;
        completed) tag="已完成" ;;
        *)         tag="$status" ;;
    esac

    if [ -n "$summary" ] && [ "$summary" != "" ]; then
        echo "  $sid [$tag] $summary (${changed:-?}个文件变更)"
    else
        echo "  $sid [$tag]"
    fi
done

total="$(ls -1 "$DEVTRACK_SESSIONS" 2>/dev/null | wc -l)"
echo ""
echo "共 $total 个会话"
