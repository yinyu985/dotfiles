# dotfiles

我的 macOS 开发环境配置，只收录**每台机器通用**的部分。机器相关的身份/密钥信息一律不入库。

## 规矩（改这个仓库前必读）

1. **改的就是仓库本体。** `~/.zshrc`、`~/.zprofile` 等都是软链接到本仓库文件，没有第二份副本。编辑即改动仓库内容，改完要能提交。
2. **`~/.zshrc` 按区块组织，新增内容必须进对应区块，禁止追加到文件末尾。**
   - 别名 → `# 别名` 区（通用别名放 `alias python='python3'` 附近；git 相关进 `# Git 别名`；浏览器相关进 `# 浏览器别名`）
   - 函数 → `# 函数` 区
   - 环境变量 → `# 基础环境变量`
   - 新主题 → 自建区块，用 `# ---` 上下包裹，风格与现有一致
3. **不写废话注释。** 只写信息量非显而易见的注释（例如 `WORDCHARS` 那类说明"为什么"的）。不要写"p = pi，少敲两下键盘"这种把代码翻译一遍的东西。
4. **不要用同名 shell 函数去劫持 CLI 的子命令。** 踩过的坑：`pi() { command pi -p "$@" }` 让 `pi update --extensions` 变成 `pi -p update --extensions`，`update` 被当成提示词，报 `Error: Unknown option: --extensions`。要包装就用别名（`alias p='pi'`）或换个名字。
5. **只收录跨机器通用配置。** `.gitconfig`、hammerspoon 的 `secrets.lua` 等机器相关/密钥文件不入库。
6. **`install.sh` 同步。** 仓库里新增需要链接到 `$HOME` 的文件，必须加进 `install.sh` 的 `LINKS` 数组。
7. **改完验证。** 至少跑 `zsh -n ~/.zshrc` 检查语法；涉及行为改动时用 `zsh -ic '...'` 实测一次再交差。

## 包含内容

| 文件 | 说明 |
|---|---|
| `.zshrc` | zsh 主配置：antidote + p10k + fzf + zoxide + 别名/函数 |
| `.zprofile` | zsh 登录配置（OrbStack 集成） |
| `.p10k.zsh` | powerlevel10k 主题配置 |
| `.zsh_plugins.txt` | antidote 插件清单 |
| `.hammerspoon/` | Hammerspoon 配置（独立子目录，密钥由 `secrets.lua` 的 .gitignore 排除） |
| `config/git/ignore` | git 全局忽略规则 |
| `agents/AGENTS.md` | 跨工具通用规则，链接到 `~/.pi/agent/AGENTS.md` 和 `~/.codex/AGENTS.md` |

**不入库**：`.gitconfig`（每台机器各自维护）、hammerspoon 的 `ocr/remote/secrets.lua`（密钥）、生成/缓存文件。

## 安装（新机器）

```bash
git clone git@github.com:yinyu985/dotfiles.git ~/Documents/dotfiles
cd ~/Documents/dotfiles
./install.sh
```

- 默认**跳过已存在的文件**，绝不覆盖你机器上已有的配置
- 带 `--force` 才会备份（`~/.dotfiles-backup-<时间戳>`）后替换

## 更新

```bash
cd ~/Documents/dotfiles
git add -A && git commit -m "update" && git push
```