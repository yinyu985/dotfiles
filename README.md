# dotfiles

我的 macOS 开发环境配置，只收录**每台机器通用**的部分。机器相关的身份/密钥信息一律不入库。

## 包含内容

| 文件 | 说明 |
|---|---|
| `.zshrc` | zsh 主配置：antidote + p10k + fzf + zoxide + 别名/函数 |
| `.zprofile` | zsh 登录配置（OrbStack 集成） |
| `.p10k.zsh` | powerlevel10k 主题配置 |
| `.zsh_plugins.txt` | antidote 插件清单 |
| `.hammerspoon/` | Hammerspoon 配置（独立子目录，密钥由 `secrets.lua` 的 .gitignore 排除） |
| `config/git/ignore` | git 全局忽略规则 |

**不入库**：`.gitconfig`（每台机器各自维护）、hammerspoon 的 `ocr/remote/secrets.lua`（密钥）、生成/缓存文件。

## 安装（新机器）

```bash
git clone git@github.com:yinyu985/dotfiles.git ~/dotfiles
cd ~/dotfiles
./install.sh
```

- 默认**跳过已存在的文件**，绝不覆盖你机器上已有的配置
- 带 `--force` 才会备份（`~/.dotfiles-backup-<时间戳>`）后替换

## 更新

```bash
cd ~/dotfiles
git add -A && git commit -m "update" && git push
```