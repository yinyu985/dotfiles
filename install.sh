#!/usr/bin/env bash
# =============================================================================
# dotfiles 安装脚本: 把仓库内文件软链接到 $HOME 对应位置
#
# 用法:
#   ./install.sh          只安装缺失的目标文件; 已存在的文件跳过 (绝不覆盖)
#   ./install.sh --force  已存在的文件先备份到 ~/.dotfiles-backup-<时间戳> 再替换
# =============================================================================
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$HOME/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"
FORCE="${1:-}"

# 列表格式: "仓库内相对路径" "目标绝对路径"
LINKS=(
  ".zshrc"                   "$HOME/.zshrc"
  ".zprofile"                "$HOME/.zprofile"
  ".p10k.zsh"                "$HOME/.p10k.zsh"
  ".zsh_plugins.txt"         "$HOME/.zsh_plugins.txt"
  ".hammerspoon"             "$HOME/.hammerspoon"
  "config/git/ignore"        "$HOME/.config/git/ignore"
  # 跨工具通用规则。目标可以是任意绝对路径，不限于 $HOME 顶层。
  # pi: agent 目录的 AGENTS.md 是全局入口，与 cwd 无关。
  # Codex: ~/.codex/AGENTS.md 是它的全局入口。
  "agents/AGENTS.md"         "$HOME/.pi/agent/AGENTS.md"
  "agents/AGENTS.md"         "$HOME/.codex/AGENTS.md"
)

link_file() {
  local src="$DOTFILES_DIR/$1"
  local dst="$2"

  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    echo "已链接, 跳过: $dst"
    return
  fi

  if [ -e "$dst" ] || [ -L "$dst" ]; then
    if [ "$FORCE" != "--force" ]; then
      echo "跳过 (已存在, 用 --force 可备份后替换): $dst"
      return
    fi
    mkdir -p "$BACKUP_DIR"
    mv "$dst" "$BACKUP_DIR/"
    echo "备份原文件 -> $BACKUP_DIR/$(basename "$dst")"
  fi

  mkdir -p "$(dirname "$dst")"
  ln -s "$src" "$dst"
  echo "链接: $dst -> $src"
}

for ((i = 0; i < ${#LINKS[@]}; i += 2)); do
  link_file "${LINKS[$i]}" "${LINKS[$i + 1]}"
done

echo ""
echo "完成。"
if [ -d "$BACKUP_DIR" ]; then
  echo "原文件备份在: $BACKUP_DIR"
fi
echo "请新开一个终端窗口使配置生效。"