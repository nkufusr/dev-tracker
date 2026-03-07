#!/bin/bash
# devtrack 结束: 对比变更 + 创建全量回滚包（替代旧包）
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
ROLLBACK_DIR="$DEVTRACK_DIR/rollback"
BASELINE="$SESSION_DIR/baseline.json"

[ -d "$SESSION_DIR" ] || dt_die "会话目录不存在: $SESSION_DIR"

dt_info "=== 结束会话: $SESSION_ID ==="
dt_info ""

# ──────────────────────────────────────
# 1) 对比变更（用开始时的基线 SHA-256）
# ──────────────────────────────────────
changed_files=""
deleted_files=""
changed_count=0
deleted_count=0

if [ -f "$BASELINE" ]; then
    dt_info "正在对比变更..."
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
    done < <(jq -r '.local_files[] | "\(.path)|\(.sha256)"' "$BASELINE")
fi

total_changes=$((changed_count + deleted_count))
dt_info "本次会话变更: $changed_count 个文件修改, $deleted_count 个文件删除"

# 自动摘要
if [ -z "$summary" ]; then
    if [ "$total_changes" -gt 0 ]; then
        if [ "$changed_count" -le 5 ] && [ "$changed_count" -gt 0 ]; then
            file_list="$(echo -e "$changed_files" | sed '/^$/d' | sed 's|.*/||' | tr '\n' ', ' | sed 's/,$//')"
            summary="修改了: $file_list"
        else
            summary="修改了 $changed_count 个文件"
        fi
    else
        summary="无文件变更"
    fi
fi

# 写变更记录
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
    echo -e "\n## 删除文件 ($deleted_count)" >> "$SESSION_DIR/changes.md"
    echo -e "$deleted_files" | sed '/^$/d' | while IFS= read -r f; do
        echo "- $f" >> "$SESSION_DIR/changes.md"
    done
fi

# ──────────────────────────────────────
# 2) 轮转旧回滚包 + 创建新全量回滚包
# ──────────────────────────────────────
dt_info ""
dt_info "正在创建全量回滚包..."

# 读取保留数量（config: rollback_keep，默认 3）
ROLLBACK_KEEP="$(grep -E '^rollback_keep:' "$DEVTRACK_CONFIG" 2>/dev/null | sed -E 's/rollback_keep:\s*//' | tr -d '"' || true)"
ROLLBACK_KEEP="${ROLLBACK_KEEP:-3}"

# 把当前 rollback/ 轮转到 rollback.1/、rollback.2/ ... rollback.N/
# 先删最旧的
oldest_slot="$DEVTRACK_DIR/rollback.${ROLLBACK_KEEP}"
[ -d "$oldest_slot" ] && rm -rf "$oldest_slot"

# 向后移动各个 slot
i="$((ROLLBACK_KEEP - 1))"
while [ "$i" -ge 1 ]; do
    src="$DEVTRACK_DIR/rollback.$i"
    dst="$DEVTRACK_DIR/rollback.$((i + 1))"
    [ -d "$src" ] && mv "$src" "$dst"
    i="$((i - 1))"
done

# 当前 rollback/ 移到 rollback.1/
[ -d "$ROLLBACK_DIR" ] && mv "$ROLLBACK_DIR" "$DEVTRACK_DIR/rollback.1"

# 创建新的 rollback/
snapshot_create "$ROLLBACK_DIR" "会话 $SESSION_ID 结束时的全量备份 — $summary"

local_count="$(jq '.local_files | length' "$ROLLBACK_DIR/manifest.json")"
remote_count="$(jq '.remote_files | length' "$ROLLBACK_DIR/manifest.json" 2>/dev/null || echo 0)"
pkg_size="$(du -sh "$ROLLBACK_DIR" 2>/dev/null | awk '{print $1}')"

dt_info "回滚包已就绪:"
dt_info "  本地文件: $local_count 个"
[ "$remote_count" -gt 0 ] && dt_info "  远程文件: $remote_count 个"
dt_info "  包大小: $pkg_size"

# 显示历史回滚包
slot_count=0
for i in $(seq 1 "$ROLLBACK_KEEP"); do
    slot="$DEVTRACK_DIR/rollback.$i"
    [ -d "$slot" ] && [ -f "$slot/manifest.json" ] || continue
    slot_desc="$(jq -r '.description // "旧备份"' "$slot/manifest.json" | sed 's/ — .*//')"
    slot_time="$(jq -r '.created_at' "$slot/manifest.json")"
    [ "$slot_count" -eq 0 ] && dt_info "  历史回滚包:"
    dt_info "    rollback.$i: $slot_time"
    slot_count=$((slot_count + 1))
done

# ──────────────────────────────────────
# 3) 更新会话元数据
# ──────────────────────────────────────
tmp="$(mktemp)"
sed -E "s|^ended_at:.*|ended_at: \"$(dt_iso_timestamp)\"|" "$SESSION_DIR/session.yaml" > "$tmp"
sed -i -E "s|^status:.*|status: \"completed\"|" "$tmp"
sed -i -E "s|^summary:.*|summary: \"$summary\"|" "$tmp"
sed -i -E "s|^files_changed:.*|files_changed: $total_changes|" "$tmp"
mv -f "$tmp" "$SESSION_DIR/session.yaml"

# ──────────────────────────────────────
# 4) 收尾
# ──────────────────────────────────────
rm -f "$DEVTRACK_DIR/.active_session"

dt_yaml_set "$DEVTRACK_STATE" "updated_at" "$(dt_iso_timestamp)"
dt_yaml_set "$DEVTRACK_STATE" "last_checkpoint" "$SESSION_ID"
dt_timeline_append "session_end" "会话结束: $SESSION_ID - $summary ($local_count 文件备份, $pkg_size)"

"$SCRIPT_DIR/devtrack-context.sh" > /dev/null 2>&1 || true
if [ -d ".ccb/history" ]; then
    cp "$DEVTRACK_CONTEXT" ".ccb/history/devtrack-${SESSION_ID}.md" 2>/dev/null || true
fi

dt_info ""
dt_info "会话已结束: $SESSION_ID"
dt_info "摘要: $summary"
dt_info ""
dt_info "回滚包代表当前的可用状态。下次出问题时:"
dt_info "  devtrack 回滚            预演"
dt_info "  devtrack 回滚 --apply    执行恢复"
dt_info "  $ROLLBACK_DIR/verify.sh  验证回滚结果"
