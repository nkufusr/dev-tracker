#!/bin/bash
# devtrack 开始: 记录基线 SHA + 加载 AI 上下文（轻量）
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/snapshot.sh"

dt_require_init
dt_require_jq

# 如果有活跃会话，先自动结束
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

# 1) 轻量基线：只记录 SHA-256（不复制文件），用于结束时对比
dt_info "正在记录文件基线..."
snapshot_manifest_only "$SESSION_DIR/baseline.json"
baseline_count="$(jq '.local_files | length' "$SESSION_DIR/baseline.json")"
dt_info "已记录 $baseline_count 个文件的 SHA-256 基线"

# 2) 会话元数据
cat > "$SESSION_DIR/session.yaml" << EOF
session_id: "$SESSION_ID"
started_at: "$(dt_iso_timestamp)"
ended_at: ""
status: "active"
summary: ""
files_at_start: $baseline_count
files_changed: 0
EOF

# 3) 标记活跃会话
echo "$SESSION_ID" > "$DEVTRACK_DIR/.active_session"

dt_timeline_append "session_start" "会话开始: $SESSION_ID"
dt_yaml_set "$DEVTRACK_STATE" "updated_at" "$(dt_iso_timestamp)"

# 4) 输出 AI 上下文
dt_info ""
"$SCRIPT_DIR/devtrack-context.sh" --stdout-only 2>/dev/null || true

# 5) 上次会话摘要
last_session="$(ls -1r "$DEVTRACK_SESSIONS" 2>/dev/null | grep -v "^${SESSION_ID}$" | head -1 || true)"
if [ -n "$last_session" ] && [ -f "$DEVTRACK_SESSIONS/$last_session/session.yaml" ]; then
    last_summary="$(grep '^summary:' "$DEVTRACK_SESSIONS/$last_session/session.yaml" | sed -E 's/^summary:\s*"?([^"]*)"?$/\1/' || true)"
    if [ -n "$last_summary" ] && [ "$last_summary" != "" ]; then
        echo ""
        echo "--- 上次会话 ($last_session) ---"
        echo "$last_summary"
    fi
fi

# 6) 提示回滚包状态
ROLLBACK_DIR="$DEVTRACK_DIR/rollback"
if [ -d "$ROLLBACK_DIR" ] && [ -f "$ROLLBACK_DIR/manifest.json" ]; then
    rb_time="$(jq -r '.created_at' "$ROLLBACK_DIR/manifest.json")"
    rb_count="$(jq '.local_files | length' "$ROLLBACK_DIR/manifest.json")"
    echo ""
    dt_info "当前回滚包: $rb_time ($rb_count 个文件)"
    dt_info "  如需回滚: devtrack 回滚"
else
    echo ""
    dt_info "暂无回滚包（首次会话结束后自动创建）"
fi

echo ""
dt_info "会话已开始。工作完成后运行: devtrack 结束 \"本次做了什么\""
