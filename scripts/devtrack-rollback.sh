#!/bin/bash
# devtrack rollback: 恢复到检查点
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
用法: devtrack 回滚 <检查点> [选项]

恢复本地和远程文件到指定检查点的状态。

参数:
  检查点                   检查点名称或部分匹配

选项:
  --dry-run               预览将恢复的内容（默认）
  --apply                 实际执行回滚
  --local-only            跳过远程文件恢复
  --skip-verify           跳过回滚后验证
  --skip-state            不恢复 state.yaml
  -h, --help              显示帮助

安全机制: 默认为 --dry-run 预演模式。必须显式传入 --apply 才会执行。
EOF
}

checkpoint=""
mode="dry-run"
local_only=0
skip_verify=0
skip_state=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)      usage; exit 0 ;;
        --dry-run)      mode="dry-run"; shift ;;
        --apply)        mode="apply"; shift ;;
        --local-only)   local_only=1; shift ;;
        --skip-verify)  skip_verify=1; shift ;;
        --skip-state)   skip_state=1; shift ;;
        -*)             echo "未知选项: $1" >&2; usage >&2; exit 1 ;;
        *)
            if [ -z "$checkpoint" ]; then
                checkpoint="$1"; shift
            else
                echo "多余参数: $1" >&2; usage >&2; exit 1
            fi
            ;;
    esac
done

[ -n "$checkpoint" ] || { echo "错误: 需要提供检查点名称" >&2; usage >&2; exit 1; }

dt_require_init
dt_require_jq

resolved="$(dt_find_checkpoint "$checkpoint")"
if [ -z "$resolved" ]; then
    dt_die "未找到检查点: $checkpoint"
fi
checkpoint="$resolved"

CP_DIR="$DEVTRACK_CHECKPOINTS/$checkpoint"
MANIFEST="$CP_DIR/manifest.json"

[ -f "$MANIFEST" ] || dt_die "检查点中未找到 manifest.json: $CP_DIR"

echo "=== 回滚: $mode ==="
echo "检查点: $checkpoint"
echo ""

# 恢复本地文件
echo "--- 本地文件 ---"
jq -r '.local_files[] | "\(.backup_rel)|\(.path)"' "$MANIFEST" | while IFS='|' read -r backup_rel target; do
    src="$CP_DIR/$backup_rel"
    if [ ! -f "$src" ]; then
        echo "  跳过（备份缺失）: $target"
        continue
    fi
    if [ "$mode" = "dry-run" ]; then
        if [ -f "$target" ]; then
            current_sha="$(dt_sha256 "$target")"
            backup_sha="$(dt_sha256 "$src")"
            if [ "$current_sha" = "$backup_sha" ]; then
                echo "  未变更: $target"
            else
                echo "  将恢复: $target"
            fi
        else
            echo "  将创建: $target"
        fi
    else
        mkdir -p "$(dirname "$target")"
        if cp "$src" "$target"; then
            echo "  已恢复: $target"
        else
            echo "  失败: $target"
        fi
    fi
done

# 恢复远程文件
if [ "$local_only" -eq 0 ]; then
    r_host="$(jq -r '.server.host' "$MANIFEST")"
    r_user="$(jq -r '.server.user' "$MANIFEST")"
    r_key="$(jq -r '.server.ssh_key_default' "$MANIFEST")"

    if [ -n "$r_host" ] && [ "$r_host" != "null" ] && [ "$r_host" != "" ]; then
        echo ""
        echo "--- 远程文件 ($r_host) ---"

        ssh_opts=""
        [ "$r_key" != "null" ] && [ -n "$r_key" ] && ssh_opts="-i $r_key"

        jq -r '.remote_files[] | "\(.backup_rel)|\(.path)"' "$MANIFEST" | while IFS='|' read -r backup_rel target; do
            src="$CP_DIR/$backup_rel"
            if [ ! -f "$src" ]; then
                echo "  跳过（备份缺失）: $target"
                continue
            fi
            if [ "$mode" = "dry-run" ]; then
                echo "  将恢复: $r_host:$target"
            else
                if scp $ssh_opts "$src" "${r_user}@${r_host}:${target}" 2>/dev/null; then
                    echo "  已恢复: $target"
                else
                    echo "  失败: $target"
                fi
            fi
        done

        # 重启服务
        echo ""
        echo "--- 服务 ---"
        jq -r '.services_to_restart[]' "$MANIFEST" 2>/dev/null | while read -r svc; do
            [ -z "$svc" ] && continue
            if [ "$mode" = "dry-run" ]; then
                echo "  将重启: $svc"
            else
                echo "  正在重启: $svc..."
                if ssh $ssh_opts "${r_user}@${r_host}" "sudo systemctl restart $svc" 2>/dev/null; then
                    echo "  已重启: $svc"
                else
                    echo "  重启失败: $svc"
                fi
            fi
        done
    fi
fi

# 恢复 state.yaml
if [ "$skip_state" -eq 0 ] && [ -f "$CP_DIR/state.yaml" ]; then
    echo ""
    echo "--- 开发状态 ---"
    if [ "$mode" = "dry-run" ]; then
        echo "  将恢复: .devtrack/state.yaml（从检查点）"
    else
        cp "$CP_DIR/state.yaml" "$DEVTRACK_STATE"
        dt_yaml_set "$DEVTRACK_STATE" "updated_at" "$(dt_iso_timestamp)"
        echo "  已恢复: .devtrack/state.yaml"
    fi
fi

# 回滚后验证
if [ "$mode" = "apply" ] && [ "$skip_verify" -eq 0 ]; then
    echo ""
    echo "--- 回滚后验证 ---"
    if [ -f "$CP_DIR/verify.sh" ]; then
        "$CP_DIR/verify.sh" || dt_warn "验证报告了问题"
    else
        echo "  （检查点中无 verify.sh）"
    fi
fi

# 更新时间线
if [ "$mode" = "apply" ]; then
    dt_timeline_append "rollback" "已回滚到检查点: $checkpoint"
fi

echo ""
echo "=== 回滚 $mode 完成 ==="

if [ "$mode" = "dry-run" ]; then
    echo ""
    echo "要实际执行此回滚，请运行:"
    echo "  devtrack 回滚 $checkpoint --apply"
fi
