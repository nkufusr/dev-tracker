#!/bin/bash
# dev-tracker 安装脚本
# 用法:
#   本地: bash install.sh
#   远程: bash <(curl -fsSL https://raw.githubusercontent.com/nkufusr/dev-tracker/main/install.sh)
set -e

INSTALL_DIR="${DEVTRACK_INSTALL_DIR:-$HOME/.local/share/dev-tracker}"
REPO_URL="https://github.com/nkufusr/dev-tracker.git"

echo "=== dev-tracker 安装 ==="
echo ""

# 判断是本地运行还是远程 pipe 运行
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
if [ -n "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ]; then
    SOURCE_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
    # 检查是否就在 repo 目录里（有 SKILL.md）
    if [ -f "$SOURCE_DIR/SKILL.md" ]; then
        INSTALL_DIR="$SOURCE_DIR"
        echo ":: 使用本地目录: $INSTALL_DIR"
    fi
fi

# 如果不是本地安装，则从 GitHub clone
if [ ! -f "$INSTALL_DIR/SKILL.md" ]; then
    echo ":: 从 GitHub 下载..."
    if [ -d "$INSTALL_DIR" ]; then
        echo ":: 更新已有安装..."
        cd "$INSTALL_DIR" && git pull --quiet
    else
        git clone --quiet "$REPO_URL" "$INSTALL_DIR"
    fi
    echo ":: 已下载到: $INSTALL_DIR"
fi

echo ""

# 1. devtrack 命令链接到 ~/.local/bin
mkdir -p "$HOME/.local/bin"
ln -sf "$INSTALL_DIR/scripts/devtrack" "$HOME/.local/bin/devtrack"
chmod +x "$INSTALL_DIR/scripts/devtrack" "$INSTALL_DIR/scripts/"*.sh "$INSTALL_DIR/scripts/lib/"*.sh
echo ":: 已安装命令: ~/.local/bin/devtrack"

# 检查 PATH
if ! echo "$PATH" | tr ':' '\n' | grep -q "$HOME/.local/bin"; then
    echo ""
    echo "   注意: ~/.local/bin 不在 PATH 中"
    echo "   请添加到 shell 配置文件 (~/.bashrc 或 ~/.zshrc):"
    echo ""
    echo '   export PATH="$HOME/.local/bin:$PATH"'
    echo ""
fi

# 2. 向各 AI 工具的 skill 目录创建符号链接
AI_SKILL_DIRS=(
    "$HOME/.claude/skills"
    "$HOME/.codex/skills"
    "$HOME/.cursor/skills-cursor"
)

for parent in "${AI_SKILL_DIRS[@]}"; do
    [ -d "$parent" ] || continue
    target="$parent/dev-tracker"

    if [ "$target" = "$INSTALL_DIR" ]; then
        echo ":: 跳过源目录: $target"
        continue
    fi

    if [ -L "$target" ]; then
        existing="$(readlink "$target")"
        if [ "$existing" = "$INSTALL_DIR" ]; then
            echo ":: 已安装: $target"
            continue
        fi
        rm "$target"
    elif [ -d "$target" ]; then
        echo ":: 跳过（已存在目录）: $target"
        continue
    fi

    ln -sf "$INSTALL_DIR" "$target"
    echo ":: 已链接: $target"
done

echo ""
echo "=== 安装完成 ==="
echo ""
echo "使用方法:"
echo "  cd <项目目录>"
echo "  devtrack 初始化 --name <项目名>"
echo "  devtrack 检查点 <标签>"
echo "  devtrack 上下文"
echo ""
echo "运行 'devtrack 帮助' 查看完整命令列表。"
echo "更新: cd $INSTALL_DIR && git pull"
