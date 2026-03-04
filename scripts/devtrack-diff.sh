#!/bin/bash
# devtrack diff: 对比当前文件与检查点差异
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
用法: devtrack 对比 [检查点] [选项]

对比当前文件状态与检查点的差异。
若未指定检查点，使用最近的一个。

选项:
  --content               显示文件内容差异（不仅仅是变更/未变更）
  -h, --help              显示帮助
EOF
}

checkpoint=""
show_content=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)  usage; exit 0 ;;
        --content)  show_content=1; shift ;;
        -*)         echo "未知选项: $1" >&2; usage >&2; exit 1 ;;
        *)
            if [ -z "$checkpoint" ]; then
                checkpoint="$1"; shift
            else
                echo "多余参数: $1" >&2; usage >&2; exit 1
            fi
            ;;
    esac
done

dt_require_init
dt_require_jq

if [ -z "$checkpoint" ]; then
    checkpoint="$(dt_list_checkpoints | head -1)"
    [ -z "$checkpoint" ] && dt_die "未找到检查点。请先运行 'devtrack 检查点 <标签>' 创建"
fi

resolved="$(dt_find_checkpoint "$checkpoint")"
if [ -z "$resolved" ]; then
    dt_die "未找到检查点: $checkpoint"
fi
checkpoint="$resolved"

CP_DIR="$DEVTRACK_CHECKPOINTS/$checkpoint"
MANIFEST="$CP_DIR/manifest.json"

[ -f "$MANIFEST" ] || dt_die "检查点中未找到 manifest.json: $checkpoint"

echo "=== 对比检查点: $checkpoint ==="
echo ""

echo "--- 本地文件 ---"
jq -r '.local_files[] | "\(.path)|\(.backup_sha256)|\(.backup_rel)"' "$MANIFEST" | while IFS='|' read -r fpath expected_sha backup_rel; do
    if [ ! -f "$fpath" ]; then
        echo "  已删除: $fpath"
        continue
    fi
    current_sha="$(dt_sha256 "$fpath")"
    if [ "$current_sha" = "$expected_sha" ]; then
        echo "  未变更: $fpath"
    else
        echo "  已变更: $fpath"
        if [ "$show_content" -eq 1 ] && [ -f "$CP_DIR/$backup_rel" ]; then
            diff -u "$CP_DIR/$backup_rel" "$fpath" 2>/dev/null | head -30 || true
            echo ""
        fi
    fi
done

remote_count="$(jq '.remote_files | length' "$MANIFEST")"
if [ "$remote_count" -gt 0 ]; then
    echo ""
    echo "--- 远程文件 ---"

    r_host="$(jq -r '.server.host' "$MANIFEST")"
    r_user="$(jq -r '.server.user' "$MANIFEST")"
    r_key="$(jq -r '.server.ssh_key_default' "$MANIFEST")"

    ssh_opts=""
    [ "$r_key" != "null" ] && [ -n "$r_key" ] && ssh_opts="-i $r_key"

    jq -r '.remote_files[] | "\(.path)|\(.backup_sha256)"' "$MANIFEST" | while IFS='|' read -r rpath expected_sha; do
        if [ -n "$r_host" ] && [ "$r_host" != "null" ]; then
            current_sha="$(ssh $ssh_opts "${r_user}@${r_host}" "sha256sum '$rpath' 2>/dev/null | awk '{print \$1}'" 2>/dev/null || echo "UNREACHABLE")"
            if [ "$current_sha" = "UNREACHABLE" ]; then
                echo "  不可达: $rpath"
            elif [ "$current_sha" = "$expected_sha" ]; then
                echo "  未变更: $rpath"
            else
                echo "  已变更: $rpath"
            fi
        else
            echo "  跳过（无远程配置）: $rpath"
        fi
    done
fi

echo ""
echo "=== 对比完成 ==="
