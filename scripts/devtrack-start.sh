#!/bin/bash
# devtrack 开始: 记录基线 SHA + 加载 AI 上下文（轻量）
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/snapshot.sh"

dt_require_init
dt_require_jq

# 如果有活跃会话，标记为废弃（不触发全量备份，那次会话未完成不值得备份）
if [ -f "$DEVTRACK_DIR/.active_session" ]; then
    abandoned="$(cat "$DEVTRACK_DIR/.active_session")"
    abandoned_dir="$DEVTRACK_SESSIONS/$abandoned"
    dt_warn "上一个会话 ($abandoned) 未正常结束，标记为废弃"
    if [ -f "$abandoned_dir/session.yaml" ]; then
        tmp="$(mktemp)"
        sed -E "s|^status:.*|status: \"abandoned\"|" "$abandoned_dir/session.yaml" > "$tmp"
        sed -i -E "s|^ended_at:.*|ended_at: \"$(dt_iso_timestamp)\"|" "$tmp"
        sed -i -E "s|^summary:.*|summary: \"废弃（新会话覆盖）\"|" "$tmp"
        mv -f "$tmp" "$abandoned_dir/session.yaml"
    fi
    dt_timeline_append "session_abandoned" "会话废弃（未正常结束）: $abandoned"
    rm -f "$DEVTRACK_DIR/.active_session"
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

# 4) 输出 AI 上下文（包含上次会话、回滚包、项目文档）
dt_info ""
"$SCRIPT_DIR/devtrack-context.sh" --stdout-only 2>/dev/null || true

echo ""
dt_info "会话已开始。工作完成后运行: devtrack 结束 \"本次做了什么\""
