#!/bin/bash
# devtrack 开始: 全量快照 → 生成回滚包 → 输出 AI 上下文
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
ROLLBACK_DIR="$DEVTRACK_DIR/rollback"

mkdir -p "$SESSION_DIR"

dt_info "=== 开始新会话: $SESSION_ID ==="
dt_info ""

# 1) 删除旧回滚包，创建新的全量回滚包
if [ -d "$ROLLBACK_DIR" ]; then
    dt_info "清除旧回滚包..."
    rm -rf "$ROLLBACK_DIR"
fi

dt_info "正在创建全量回滚包（排除 build 产物）..."
snapshot_create "$ROLLBACK_DIR" "会话 $SESSION_ID 开始前的全量备份"

local_count="$(jq '.local_files | length' "$ROLLBACK_DIR/manifest.json")"
remote_count="$(jq '.remote_files | length' "$ROLLBACK_DIR/manifest.json" 2>/dev/null || echo 0)"
pkg_size="$(du -sh "$ROLLBACK_DIR" 2>/dev/null | awk '{print $1}')"

dt_info "回滚包已就绪:"
dt_info "  本地文件: $local_count 个"
[ "$remote_count" -gt 0 ] && dt_info "  远程文件: $remote_count 个"
dt_info "  包大小: $pkg_size"
dt_info "  位置: $ROLLBACK_DIR/"
dt_info "  独立回滚: $ROLLBACK_DIR/rollback.sh --dry-run"

# 2) 记录会话元数据
cat > "$SESSION_DIR/session.yaml" << EOF
session_id: "$SESSION_ID"
started_at: "$(dt_iso_timestamp)"
ended_at: ""
status: "active"
summary: ""
files_at_start: $local_count
files_changed: 0
EOF

# 3) 标记活跃会话
echo "$SESSION_ID" > "$DEVTRACK_DIR/.active_session"

dt_timeline_append "session_start" "会话开始: $SESSION_ID (全量备份 $local_count 文件, $pkg_size)"
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

echo ""
dt_info "会话已开始，回滚包已就绪。"
dt_info "工作完成后运行: devtrack 结束 \"本次做了什么\""
