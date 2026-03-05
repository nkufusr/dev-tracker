#!/bin/bash
# devtrack 结束: 记录变更 + 保存会话
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

dt_require_init
dt_require_jq

summary="${*:-}"

if [ ! -f "$DEVTRACK_DIR/.active_session" ]; then
    dt_die "没有活跃会话。请先运行 'devtrack 开始'"
fi

SESSION_ID="$(cat "$DEVTRACK_DIR/.active_session")"
SESSION_DIR="$DEVTRACK_SESSIONS/$SESSION_ID"
ROLLBACK_DIR="$DEVTRACK_DIR/rollback"
MANIFEST="$ROLLBACK_DIR/manifest.json"

[ -d "$SESSION_DIR" ] || dt_die "会话目录不存在: $SESSION_DIR"
[ -f "$MANIFEST" ] || dt_die "回滚包不存在，无法对比变更"

dt_info "=== 结束会话: $SESSION_ID ==="
dt_info ""

# 1) 对比当前文件与回滚包中的快照
dt_info "正在对比变更..."

changed_files=""
new_files=""
deleted_files=""
changed_count=0
new_count=0
deleted_count=0

before_tmp="$(mktemp)"
jq -r '.local_files[] | "\(.path)|\(.backup_sha256)"' "$MANIFEST" | sort > "$before_tmp"

# 检查已有文件是否变更
while IFS='|' read -r fpath expected_sha; do
    if [ ! -f "$fpath" ]; then
        deleted_files="${deleted_files}${fpath}\n"
        deleted_count=$((deleted_count + 1))
        continue
    fi
    current_sha="$(sha256sum "$fpath" | awk '{print $1}')"
    if [ "$current_sha" != "$expected_sha" ]; then
        changed_files="${changed_files}${fpath}\n"
        changed_count=$((changed_count + 1))
    fi
done < "$before_tmp"
rm -f "$before_tmp"

total_changes=$((changed_count + new_count + deleted_count))

dt_info "本次会话变更:"
dt_info "  修改: $changed_count 个文件"
[ "$deleted_count" -gt 0 ] && dt_info "  删除: $deleted_count 个文件"

# 2) 自动生成摘要
if [ -z "$summary" ]; then
    if [ "$total_changes" -gt 0 ]; then
        summary="修改了 $changed_count 个文件"
        if [ "$changed_count" -le 5 ] && [ "$changed_count" -gt 0 ]; then
            file_list="$(echo -e "$changed_files" | sed '/^$/d' | sed 's|.*/||' | tr '\n' ', ' | sed 's/,$//')"
            summary="修改了: $file_list"
        fi
    else
        summary="无文件变更"
    fi
fi

# 3) 写变更记录
cat > "$SESSION_DIR/changes.md" << EOF
# 会话变更记录: $SESSION_ID

## 摘要
$summary

## 修改文件 ($changed_count)
EOF
echo -e "$changed_files" | sed '/^$/d' | while IFS= read -r f; do
    echo "- $f" >> "$SESSION_DIR/changes.md"
done

if [ "$deleted_count" -gt 0 ]; then
    echo "" >> "$SESSION_DIR/changes.md"
    echo "## 删除文件 ($deleted_count)" >> "$SESSION_DIR/changes.md"
    echo -e "$deleted_files" | sed '/^$/d' | while IFS= read -r f; do
        echo "- $f" >> "$SESSION_DIR/changes.md"
    done
fi

# 4) 更新会话元数据
tmp="$(mktemp)"
sed -E "s|^ended_at:.*|ended_at: \"$(dt_iso_timestamp)\"|" "$SESSION_DIR/session.yaml" > "$tmp"
sed -i -E "s|^status:.*|status: \"completed\"|" "$tmp"
sed -i -E "s|^summary:.*|summary: \"$summary\"|" "$tmp"
sed -i -E "s|^files_changed:.*|files_changed: $total_changes|" "$tmp"
mv -f "$tmp" "$SESSION_DIR/session.yaml"

# 5) 清除活跃标记
rm -f "$DEVTRACK_DIR/.active_session"

# 6) 更新全局状态
dt_yaml_set "$DEVTRACK_STATE" "updated_at" "$(dt_iso_timestamp)"
dt_yaml_set "$DEVTRACK_STATE" "last_checkpoint" "$SESSION_ID"
dt_timeline_append "session_end" "会话结束: $SESSION_ID - $summary"

# 7) 重新生成 AI 上下文
"$SCRIPT_DIR/devtrack-context.sh" > /dev/null 2>&1 || true
if [ -d ".ccb/history" ]; then
    cp "$DEVTRACK_CONTEXT" ".ccb/history/devtrack-${SESSION_ID}.md" 2>/dev/null || true
fi

dt_info ""
dt_info "会话已结束: $SESSION_ID"
dt_info "摘要: $summary"
dt_info ""
dt_info "回滚包位置: $ROLLBACK_DIR/"
dt_info "  预演: $ROLLBACK_DIR/rollback.sh --dry-run"
dt_info "  执行: $ROLLBACK_DIR/rollback.sh --apply"
dt_info "  验证: $ROLLBACK_DIR/verify.sh"
dt_info "  或直接: devtrack 回滚"
