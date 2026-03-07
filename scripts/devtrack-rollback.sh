#!/bin/bash
# devtrack 回滚: 恢复到指定回滚包的状态
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

dt_require_init

# ── 参数解析 ──────────────────────────────────────────────
mode="--dry-run"
slot="rollback"      # 默认最新
verify=1

for arg in "$@"; do
    case "$arg" in
        --apply)       mode="--apply" ;;
        --dry-run)     mode="--dry-run" ;;
        --no-verify)   verify=0 ;;
        --list)
            echo "可用回滚包:"
            for d in "$DEVTRACK_DIR"/rollback "$DEVTRACK_DIR"/rollback.*; do
                [ -f "$d/manifest.json" ] || continue
                ts="$(jq -r '.created_at' "$d/manifest.json")"
                cnt="$(jq '.local_files | length' "$d/manifest.json")"
                sz="$(du -sh "$d" 2>/dev/null | awk '{print $1}')"
                desc="$(jq -r '.description // ""' "$d/manifest.json" | sed 's/^会话 [0-9-]* 结束时的全量备份 — //')"
                name="$(basename "$d")"
                echo "  $name  [$ts | $cnt 文件 | $sz]  $desc"
            done
            exit 0 ;;
        --slot=*)
            n="${arg#--slot=}"
            if [ "$n" = "0" ] || [ -z "$n" ]; then
                slot="rollback"
            else
                slot="rollback.$n"
            fi ;;

        -h|--help|帮助)
            cat <<'EOF'
用法: devtrack 回滚 [选项]

恢复到上次 devtrack 结束 时备份的状态。

选项:
  --dry-run      预演（默认）
  --apply        实际执行回滚
  --list         列出所有可用回滚包
  --slot=N       指定历史回滚包（rollback.1=上上次，rollback.2=更早）
  --no-verify    跳过回滚后验证
  -h, --help     显示帮助

示例:
  devtrack 回滚              预演最新回滚包
  devtrack 回滚 --apply      执行恢复到上次结束的状态
  devtrack 回滚 --list       查看所有可用时间点
  devtrack 回滚 --slot=1     恢复到上上次结束的状态
EOF
            exit 0 ;;
    esac
done

# ── 确认回滚包 ────────────────────────────────────────────
ROLLBACK_PKG="$DEVTRACK_DIR/$slot"

if [ ! -d "$ROLLBACK_PKG" ] || [ ! -f "$ROLLBACK_PKG/manifest.json" ]; then
    dt_die "回滚包不存在: $ROLLBACK_PKG
请先运行 'devtrack 结束' 创建回滚包，或用 'devtrack 回滚 --list' 查看可用包"
fi

MANIFEST="$ROLLBACK_PKG/manifest.json"

echo "=== 回滚 ($mode) ==="
echo "回滚包: $slot"
echo "时间: $(jq -r '.created_at' "$MANIFEST")"
echo "描述: $(jq -r '.description // "无"' "$MANIFEST" | sed 's/^会话 [0-9-]* 结束时的全量备份 — //')"
echo ""

# ── 恢复本地文件 ──────────────────────────────────────────
echo "--- 本地文件 ---"
jq -r '.local_files[] | "\(.backup_rel)|\(.path)"' "$MANIFEST" | while IFS='|' read -r brel target; do
    src="$ROLLBACK_PKG/$brel"
    [ -f "$src" ] || { echo "  跳过(缺失): $target"; continue; }
    if [ "$mode" = "--dry-run" ]; then
        if [ -f "$target" ]; then
            cur="$(sha256sum "$target" | awk '{print $1}')"
            bak="$(sha256sum "$src" | awk '{print $1}')"
            [ "$cur" = "$bak" ] && echo "  未变更: ${target#$(pwd)/}" || echo "  将恢复: ${target#$(pwd)/}"
        else
            echo "  将创建: ${target#$(pwd)/}"
        fi
    else
        mkdir -p "$(dirname "$target")"
        cp "$src" "$target"
        echo "  已恢复: ${target#$(pwd)/}"
    fi
done

# ── P2: 删除本次会话新增的文件 ────────────────────────────
# 新增文件 = 当前存在 但 manifest 里没有记录 的文件
echo ""
echo "--- 新增文件清理 ---"
backed_up_list="$(mktemp)"
jq -r '.local_files[].path' "$MANIFEST" | sort > "$backed_up_list"

root="$(jq -r '.workspace_root' "$MANIFEST")"
cd "$root"

source "$SCRIPT_DIR/lib/snapshot.sh"
new_files_found=0
while IFS= read -r filepath; do
    [ -z "$filepath" ] && continue
    fullpath="$root/${filepath#./}"
    if ! grep -qF "$fullpath" "$backed_up_list" 2>/dev/null; then
        new_files_found=$((new_files_found + 1))
        if [ "$mode" = "--dry-run" ]; then
            echo "  将删除(新增): ${fullpath#$root/}"
        else
            rm -f "$fullpath"
            echo "  已删除(新增): ${fullpath#$root/}"
        fi
    fi
done < <(_snap_collect_all_files)
rm -f "$backed_up_list"
[ "$new_files_found" -eq 0 ] && echo "  无新增文件需要清理"

# ── 远程文件 ──────────────────────────────────────────────
r_host="$(jq -r '.server.host // empty' "$MANIFEST")"
if [ -n "$r_host" ]; then
    r_user="$(jq -r '.server.user' "$MANIFEST")"
    r_key="$(jq -r '.server.ssh_key_default // empty' "$MANIFEST")"
    ssh_opts=""
    [ -n "$r_key" ] && ssh_opts="-i $r_key"

    rc="$(jq '.remote_files | length' "$MANIFEST" 2>/dev/null || echo 0)"
    if [ "$rc" -gt 0 ]; then
        echo ""
        echo "--- 远程文件 ($r_host) ---"
        jq -r '.remote_files[] | "\(.backup_rel)|\(.path)"' "$MANIFEST" | while IFS='|' read -r brel target; do
            src="$ROLLBACK_PKG/$brel"
            [ -f "$src" ] || continue
            if [ "$mode" = "--dry-run" ]; then
                echo "  将恢复: $r_host:$target"
            else
                scp $ssh_opts "$src" "${r_user}@${r_host}:${target}" 2>/dev/null && echo "  已恢复: $target" || echo "  失败: $target"
            fi
        done
        echo ""
        echo "--- 服务 ---"
        jq -r '.services_to_restart[]' "$MANIFEST" 2>/dev/null | while read -r svc; do
            [ -z "$svc" ] && continue
            if [ "$mode" = "--dry-run" ]; then
                echo "  将重启: $svc"
            else
                ssh $ssh_opts "${r_user}@${r_host}" "sudo systemctl restart $svc" 2>/dev/null && echo "  已重启: $svc" || echo "  重启失败: $svc"
            fi
        done
    fi
fi

# ── 恢复 state.yaml ───────────────────────────────────────
if [ -f "$ROLLBACK_PKG/state.yaml" ]; then
    echo ""
    echo "--- 开发状态 ---"
    if [ "$mode" = "--dry-run" ]; then
        echo "  将恢复: state.yaml"
    else
        cp "$ROLLBACK_PKG/state.yaml" "$DEVTRACK_STATE"
        dt_yaml_set "$DEVTRACK_STATE" "updated_at" "$(dt_iso_timestamp)"
        echo "  已恢复: state.yaml"
        dt_timeline_append "rollback" "已回滚到: $slot ($(jq -r '.created_at' "$MANIFEST"))"
    fi
fi

echo ""
echo "=== 回滚 $mode 完成 ==="

if [ "$mode" = "--dry-run" ]; then
    echo ""
    echo "确认无误后执行: devtrack 回滚 --apply"
    exit 0
fi

# ── P3: 回滚后验证 ────────────────────────────────────────
if [ "$verify" -eq 1 ]; then
    BUILD="$(jq -r '.commands.build // empty' "$MANIFEST")"
    TEST="$(jq -r '.commands.test // empty' "$MANIFEST")"
    HEALTH="$(jq -r '.commands.health // empty' "$MANIFEST")"
    has_verify=$(([ -n "$BUILD" ] || [ -n "$TEST" ] || [ -n "$HEALTH" ]) && echo 1 || echo 0)

    if [ "$has_verify" = "1" ]; then
        echo ""
        echo "--- 回滚后验证 ---"
        errors=0
        if [ -n "$BUILD" ]; then
            printf "  构建... "
            if eval "$BUILD" > /dev/null 2>&1; then echo "通过"; else echo "失败"; errors=$((errors+1)); fi
        fi
        if [ -n "$TEST" ]; then
            printf "  测试... "
            if eval "$TEST" > /dev/null 2>&1; then echo "通过"; else echo "失败"; errors=$((errors+1)); fi
        fi
        if [ -n "$HEALTH" ]; then
            printf "  健康... "
            result="$(eval "$HEALTH" 2>/dev/null || echo "失败")"
            echo "$result"
        fi
        if [ "$errors" -gt 0 ]; then
            dt_warn "验证有 $errors 项失败，请检查"
        else
            dt_info "验证通过"
        fi
    fi
fi
