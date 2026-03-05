#!/bin/bash
# devtrack 回滚: 恢复到最近一次会话开始前的状态
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

dt_require_init
dt_require_jq

mode="dry-run"
target_session=""

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)     mode="apply"; shift ;;
        --dry-run)   mode="dry-run"; shift ;;
        -h|--help|帮助)
            echo "用法: devtrack 回滚 [--dry-run|--apply]"
            echo ""
            echo "恢复到最近一次会话开始前的状态。"
            echo "默认预演模式（--dry-run），需 --apply 才实际执行。"
            exit 0 ;;
        *)
            if [ -z "$target_session" ]; then
                target_session="$1"; shift
            else
                echo "多余参数: $1" >&2; exit 1
            fi ;;
    esac
done

# 找到要回滚的会话
if [ -n "$target_session" ]; then
    # 指定了会话 ID
    SESSION_DIR="$DEVTRACK_SESSIONS/$target_session"
    [ -d "$SESSION_DIR" ] || {
        found="$(ls -1r "$DEVTRACK_SESSIONS" 2>/dev/null | grep -F "$target_session" | head -1 || true)"
        [ -n "$found" ] && SESSION_DIR="$DEVTRACK_SESSIONS/$found" && target_session="$found"
    }
else
    # 找最近一个有 snapshot-before 的会话
    for sid in $(ls -1r "$DEVTRACK_SESSIONS" 2>/dev/null); do
        if [ -f "$DEVTRACK_SESSIONS/$sid/snapshot-before/manifest.json" ]; then
            target_session="$sid"
            SESSION_DIR="$DEVTRACK_SESSIONS/$sid"
            break
        fi
    done
fi

[ -n "$target_session" ] || dt_die "没有可回滚的会话"
[ -f "$SESSION_DIR/snapshot-before/manifest.json" ] || dt_die "会话 $target_session 没有开始前快照"

MANIFEST="$SESSION_DIR/snapshot-before/manifest.json"
SNAPSHOT_DIR="$SESSION_DIR/snapshot-before"

echo "=== 回滚到会话 $target_session 开始前的状态 ==="
echo "模式: $mode"
echo ""

# 恢复本地文件
echo "--- 本地文件 ---"
jq -r '.local_files[] | "\(.backup_rel)|\(.path)"' "$MANIFEST" | while IFS='|' read -r backup_rel target; do
    src="$SNAPSHOT_DIR/$backup_rel"
    if [ ! -f "$src" ]; then
        echo "  跳过（备份缺失）: $target"
        continue
    fi
    if [ "$mode" = "dry-run" ]; then
        if [ -f "$target" ]; then
            current_sha="$(dt_sha256 "$target")"
            backup_sha="$(dt_sha256 "$src")"
            if [ "$current_sha" = "$backup_sha" ]; then
                echo "  未变更: $(basename "$target")"
            else
                echo "  将恢复: $target"
            fi
        else
            echo "  将创建: $target"
        fi
    else
        mkdir -p "$(dirname "$target")"
        cp "$src" "$target"
        echo "  已恢复: $target"
    fi
done

# 恢复远程文件
r_host="$(jq -r '.server.host // empty' "$MANIFEST" 2>/dev/null || true)"
if [ -n "$r_host" ]; then
    r_user="$(jq -r '.server.user' "$MANIFEST")"
    r_key="$(jq -r '.server.ssh_key_default // empty' "$MANIFEST" 2>/dev/null || true)"
    ssh_opts=""
    [ -n "$r_key" ] && ssh_opts="-i $r_key"

    remote_count="$(jq '.remote_files | length' "$MANIFEST" 2>/dev/null || echo 0)"
    if [ "$remote_count" -gt 0 ]; then
        echo ""
        echo "--- 远程文件 ($r_host) ---"
        jq -r '.remote_files[] | "\(.backup_rel)|\(.path)"' "$MANIFEST" | while IFS='|' read -r backup_rel target; do
            src="$SNAPSHOT_DIR/$backup_rel"
            [ -f "$src" ] || continue
            if [ "$mode" = "dry-run" ]; then
                echo "  将恢复: $r_host:$target"
            else
                scp $ssh_opts "$src" "${r_user}@${r_host}:${target}" 2>/dev/null && \
                    echo "  已恢复: $target" || echo "  失败: $target"
            fi
        done

        echo ""
        echo "--- 服务 ---"
        jq -r '.services_to_restart[]' "$MANIFEST" 2>/dev/null | while read -r svc; do
            [ -z "$svc" ] && continue
            if [ "$mode" = "dry-run" ]; then
                echo "  将重启: $svc"
            else
                ssh $ssh_opts "${r_user}@${r_host}" "sudo systemctl restart $svc" 2>/dev/null && \
                    echo "  已重启: $svc" || echo "  重启失败: $svc"
            fi
        done
    fi
fi

# 恢复 state.yaml
if [ -f "$SNAPSHOT_DIR/state.yaml" ]; then
    echo ""
    echo "--- 开发状态 ---"
    if [ "$mode" = "dry-run" ]; then
        echo "  将恢复: state.yaml"
    else
        cp "$SNAPSHOT_DIR/state.yaml" "$DEVTRACK_STATE"
        dt_yaml_set "$DEVTRACK_STATE" "updated_at" "$(dt_iso_timestamp)"
        echo "  已恢复: state.yaml"
        dt_timeline_append "rollback" "已回滚到会话 $target_session 开始前的状态"
    fi
fi

echo ""
echo "=== 回滚 $mode 完成 ==="

if [ "$mode" = "dry-run" ]; then
    echo ""
    echo "确认无误后执行: devtrack 回滚 --apply"
fi
