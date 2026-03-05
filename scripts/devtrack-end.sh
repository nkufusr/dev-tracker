#!/bin/bash
# devtrack 结束: 自动快照变更后状态 + 记录变更
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/snapshot.sh"

dt_require_init
dt_require_jq

summary="${*:-}"

if [ ! -f "$DEVTRACK_DIR/.active_session" ]; then
    dt_die "没有活跃会话。请先运行 'devtrack 开始'"
fi

SESSION_ID="$(cat "$DEVTRACK_DIR/.active_session")"
SESSION_DIR="$DEVTRACK_SESSIONS/$SESSION_ID"

[ -d "$SESSION_DIR" ] || dt_die "会话目录不存在: $SESSION_DIR"

dt_info "=== 结束会话: $SESSION_ID ==="
dt_info ""

# 1) 快照当前文件 → "结束后快照"
dt_info "正在快照当前文件状态..."
snapshot_create "$SESSION_DIR/snapshot-after" "会话结束后快照"
after_count="$(jq '.local_files | length' "$SESSION_DIR/snapshot-after/manifest.json")"
dt_info "已快照 $after_count 个本地文件"

# 2) 对比变更
BEFORE_MANIFEST="$SESSION_DIR/snapshot-before/manifest.json"
AFTER_MANIFEST="$SESSION_DIR/snapshot-after/manifest.json"

changed_files=""
changed_count=0

if [ -f "$BEFORE_MANIFEST" ] && [ -f "$AFTER_MANIFEST" ]; then
    # 找出 SHA 变化的文件
    before_tmp="$(mktemp)"
    after_tmp="$(mktemp)"
    jq -r '.local_files[] | "\(.path)|\(.backup_sha256)"' "$BEFORE_MANIFEST" | sort > "$before_tmp"
    jq -r '.local_files[] | "\(.path)|\(.backup_sha256)"' "$AFTER_MANIFEST" | sort > "$after_tmp"

    # 变更的文件（SHA 不同或新增）
    changed_files="$(comm -13 "$before_tmp" "$after_tmp" | cut -d'|' -f1)"
    # 被删除的文件
    deleted_files="$(comm -23 "$before_tmp" "$after_tmp" | cut -d'|' -f1)"

    rm -f "$before_tmp" "$after_tmp"

    changed_count="$(echo "$changed_files" | grep -c '.' || true)"
    deleted_count="$(echo "$deleted_files" | grep -c '.' || true)"
fi

dt_info ""
dt_info "本次会话变更: $changed_count 个文件修改/新增"
[ "$deleted_count" -gt 0 ] 2>/dev/null && dt_info "  $deleted_count 个文件删除"

# 3) 如果没有提供摘要，自动生成
if [ -z "$summary" ]; then
    if [ "$changed_count" -gt 0 ]; then
        summary="修改了 $changed_count 个文件"
        if [ "$changed_count" -le 5 ]; then
            file_list="$(echo "$changed_files" | sed 's|.*/||' | tr '\n' ', ' | sed 's/,$//')"
            summary="修改了: $file_list"
        fi
    else
        summary="无文件变更"
    fi
fi

# 4) 记录变更详情
cat > "$SESSION_DIR/changes.md" << EOF
# 会话变更记录: $SESSION_ID

## 摘要
$summary

## 变更文件 ($changed_count)
EOF

if [ -n "$changed_files" ]; then
    echo "$changed_files" | while IFS= read -r f; do
        [ -n "$f" ] && echo "- $f" >> "$SESSION_DIR/changes.md"
    done
fi

if [ -n "$deleted_files" ] && [ "$deleted_count" -gt 0 ] 2>/dev/null; then
    echo "" >> "$SESSION_DIR/changes.md"
    echo "## 删除文件 ($deleted_count)" >> "$SESSION_DIR/changes.md"
    echo "$deleted_files" | while IFS= read -r f; do
        [ -n "$f" ] && echo "- $f" >> "$SESSION_DIR/changes.md"
    done
fi

# 5) 更新会话元数据
tmp="$(mktemp)"
sed -E "s|^ended_at:.*|ended_at: \"$(dt_iso_timestamp)\"|" "$SESSION_DIR/session.yaml" > "$tmp"
sed -i -E "s|^status:.*|status: \"completed\"|" "$tmp"
sed -i -E "s|^summary:.*|summary: \"$summary\"|" "$tmp"
sed -i -E "s|^files_changed:.*|files_changed: $changed_count|" "$tmp"
mv -f "$tmp" "$SESSION_DIR/session.yaml"

# 6) 清除活跃标记
rm -f "$DEVTRACK_DIR/.active_session"

# 7) 更新 state.yaml 和 timeline
dt_yaml_set "$DEVTRACK_STATE" "updated_at" "$(dt_iso_timestamp)"
dt_yaml_set "$DEVTRACK_STATE" "last_checkpoint" "$SESSION_ID"
dt_timeline_append "session_end" "会话结束: $SESSION_ID - $summary"

# 8) 重新生成上下文
"$SCRIPT_DIR/devtrack-context.sh" > /dev/null 2>&1 || true

# 同步到 .ccb/history/ (如果存在)
if [ -d ".ccb/history" ]; then
    cp "$DEVTRACK_CONTEXT" ".ccb/history/devtrack-${SESSION_ID}.md" 2>/dev/null || true
fi

dt_info ""
dt_info "会话已结束: $SESSION_ID"
dt_info "摘要: $summary"
dt_info ""
dt_info "如需回滚到本次会话开始前的状态，运行: devtrack 回滚"
