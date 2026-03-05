#!/bin/bash
# devtrack 开始: 自动快照当前状态 + 生成 AI 上下文
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/snapshot.sh"

dt_require_init
dt_require_jq

# 如果已有活跃会话，先自动结束
if [ -f "$DEVTRACK_DIR/.active_session" ]; then
    active="$(cat "$DEVTRACK_DIR/.active_session")"
    dt_warn "上一个会话 ($active) 未结束，自动关闭中..."
    "$SCRIPT_DIR/devtrack-end.sh" "自动关闭（被新会话替代）" 2>/dev/null || true
fi

SESSION_ID="$(dt_timestamp)"
SESSION_DIR="$DEVTRACK_SESSIONS/$SESSION_ID"
mkdir -p "$SESSION_DIR"

dt_info "=== 开始新会话: $SESSION_ID ==="
dt_info ""

# 1) 自动快照当前所有文件 → 存为 "开始前快照"
dt_info "正在快照当前文件状态..."
snapshot_create "$SESSION_DIR/snapshot-before" "会话开始前快照"
before_count="$(jq '.local_files | length' "$SESSION_DIR/snapshot-before/manifest.json")"
dt_info "已快照 $before_count 个本地文件"

# 2) 记录会话元数据
cat > "$SESSION_DIR/session.yaml" << EOF
session_id: "$SESSION_ID"
started_at: "$(dt_iso_timestamp)"
ended_at: ""
status: "active"
summary: ""
files_before: $before_count
files_changed: 0
EOF

# 3) 标记活跃会话
echo "$SESSION_ID" > "$DEVTRACK_DIR/.active_session"

dt_timeline_append "session_start" "会话开始: $SESSION_ID"
dt_yaml_set "$DEVTRACK_STATE" "updated_at" "$(dt_iso_timestamp)"

# 4) 生成 AI 上下文并输出
dt_info ""
"$SCRIPT_DIR/devtrack-context.sh" --stdout-only 2>/dev/null || true

# 5) 显示上次会话摘要（如果有）
last_session="$(ls -1r "$DEVTRACK_SESSIONS" 2>/dev/null | grep -v "^${SESSION_ID}$" | head -1 || true)"
if [ -n "$last_session" ] && [ -f "$DEVTRACK_SESSIONS/$last_session/session.yaml" ]; then
    last_summary="$(grep '^summary:' "$DEVTRACK_SESSIONS/$last_session/session.yaml" | sed -E 's/^summary:\s*"?([^"]*)"?$/\1/' || true)"
    if [ -n "$last_summary" ] && [ "$last_summary" != "" ]; then
        echo ""
        echo "--- 上次会话 ($last_session) ---"
        echo "$last_summary"
    fi
fi

echo ""
dt_info "会话已开始。工作完成后运行: devtrack 结束 \"本次做了什么\""
