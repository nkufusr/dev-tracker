#!/bin/bash
# devtrack 回滚: 用回滚包恢复到上次会话开始前的状态
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

dt_require_init

ROLLBACK_DIR="$DEVTRACK_DIR/rollback"

if [ ! -d "$ROLLBACK_DIR" ] || [ ! -f "$ROLLBACK_DIR/rollback.sh" ]; then
    dt_die "没有回滚包。请先运行 'devtrack 开始' 创建。"
fi

mode="--dry-run"
for arg in "$@"; do
    case "$arg" in
        --apply) mode="--apply" ;;
        --dry-run) mode="--dry-run" ;;
        -h|--help|帮助)
            echo "用法: devtrack 回滚 [--dry-run|--apply]"
            echo ""
            echo "用回滚包恢复到上次 'devtrack 开始' 时的状态。"
            echo "默认预演（--dry-run），需 --apply 实际执行。"
            echo ""
            echo "回滚后建议运行验证: $ROLLBACK_DIR/verify.sh"
            exit 0 ;;
    esac
done

# 直接调用回滚包里的独立脚本
exec "$ROLLBACK_DIR/rollback.sh" "$mode"
