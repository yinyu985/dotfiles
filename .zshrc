#!/usr/bin/env zsh
# =============================================================================
# Zsh 配置: antidote + powerlevel10k + fzf + zoxide
# =============================================================================

# ---------------------------------------------------------------------------
# p10k 即时提示符 (必须在最顶部)
# ---------------------------------------------------------------------------
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# ---------------------------------------------------------------------------
# 基础环境变量
# ---------------------------------------------------------------------------
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export LESSHISTFILE=/dev/null
export HOMEBREW_NO_AUTO_UPDATE=true

# Homebrew (内联，避免每次启动调用 brew shellenv 子进程)
export HOMEBREW_PREFIX="/opt/homebrew"
export HOMEBREW_CELLAR="/opt/homebrew/Cellar"
export HOMEBREW_REPOSITORY="/opt/homebrew"
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
fpath[1,0]="/opt/homebrew/share/zsh/site-functions"
[ -z "${MANPATH-}" ] || export MANPATH=":${MANPATH#:}"
export INFOPATH="/opt/homebrew/share/info:${INFOPATH:-}"

# ---------------------------------------------------------------------------
# Zsh Completion
# ---------------------------------------------------------------------------
# 如果 compdef 未定义（Antidote 可能已加载），则初始化补全系统
if ! (( $+functions[compdef] )); then
  autoload -Uz compinit
  compinit -C  # -C 跳过过期检查，更快
fi

# ---------------------------------------------------------------------------
# Antidote 插件管理器
# ---------------------------------------------------------------------------
if [[ -f /opt/homebrew/opt/antidote/share/antidote/antidote.zsh ]]; then
  source /opt/homebrew/opt/antidote/share/antidote/antidote.zsh
elif [[ -f "$HOME/.local/share/antidote/antidote.zsh" ]]; then
  source "$HOME/.local/share/antidote/antidote.zsh"
fi

if (( $+functions[antidote] )) && [[ -f ~/.zsh_plugins.txt ]]; then
  antidote load ~/.zsh_plugins.txt
fi

# ---------------------------------------------------------------------------
# Powerlevel10k 配置 (在 antidote 加载之后)
# ---------------------------------------------------------------------------
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# ---------------------------------------------------------------------------
# Zsh 历史配置
# ---------------------------------------------------------------------------
HISTFILE=~/.zsh_history
HISTSIZE=100000
SAVEHIST=100000

setopt HIST_IGNORE_ALL_DUPS
setopt HIST_SAVE_NO_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_REDUCE_BLANKS
setopt SHARE_HISTORY
setopt INC_APPEND_HISTORY
setopt EXTENDED_HISTORY
setopt AUTO_CD
setopt CORRECT
setopt NO_BEEP

# ---------------------------------------------------------------------------
# Zsh 行为配置
# ---------------------------------------------------------------------------
WORDCHARS=${WORDCHARS//\//}    # 从 WORDCHARS 中移除 /，使 Ctrl+W 删除单词时在 / 处停止
export PROMPT_EOL_MARK=""       # 关闭 zsh 的自动 % 分割

bindkey -e

# 历史子串搜索按键绑定
zmodload -F zsh/terminfo +p:terminfo
bindkey '^[[1;5C' forward-word
bindkey '^[[1;5D' backward-word
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down
bindkey '^P' history-substring-search-up
bindkey '^N' history-substring-search-down

# 自动建议颜色
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=242'

# ---------------------------------------------------------------------------
# Zoxide (智能目录跳转)
# ---------------------------------------------------------------------------
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh)"
fi

# ---------------------------------------------------------------------------
# FZF 配置
# ---------------------------------------------------------------------------
if command -v fzf >/dev/null 2>&1; then
  source <(fzf --zsh)
fi

export FZF_DEFAULT_OPTS="--height 40% --layout=reverse --border"

# ---------------------------------------------------------------------------
# 别名
# ---------------------------------------------------------------------------
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
alias la='ls -alh'
alias l='ls -alh'
alias ll='ls -lh'
alias lh='ls -lh'
alias grep='grep --color=auto'
alias cl='clear && clear && clear'
alias vi='vim'
alias d='diff -u --color=auto'
alias python='python3'

# Git 别名
alias ga='git add'
alias gp='git push'
alias gl='git pull'
alias gs='git status'
alias gr='git restore'
alias gd='git diff --word-diff'
alias gb='git branch'
alias gbr='git branch -r'
alias gba='git branch -a --sort=-committerdate'
alias gco='git checkout'
alias gsh='git show'
alias gsn='git show --name-only'
alias gsd='git show -p'
alias gcb='git checkout -b'
alias glo='git log --oneline --decorate --graph | head -50'
alias gls='git log --stat | head -50'

# 浏览器别名
alias ge='open -na "Google Chrome" --args --ignore-certificate-errors --ignore-urlfetcher-cert-requests --remote-debugging-port=9222'
alias he='open -na "Helium" --args --ignore-certificate-errors --ignore-urlfetcher-cert-requests --remote-debugging-port=9222'
alias fedora='/Applications/OrbStack.app/Contents/MacOS/bin/orb -m fedora'

# ---------------------------------------------------------------------------
# 函数
# ---------------------------------------------------------------------------

# Chrome-Agent 启动器（独立 profile + 9222 端口）
gac() {
  open -na "Google Chrome" --args \
    --user-data-dir="$HOME/Library/Application Support/Google/Chrome-Agent" \
    --profile-directory="Default" \
    --remote-debugging-port=9222 \
    --remote-debugging-address=127.0.0.1 \
    --ignore-certificate-errors \
    --ignore-urlfetcher-cert-requests \
    --no-first-run \
    --no-default-browser-check
}

# pi 启动器
p() { command pi "$@" }
pi() { command pi -p "$@" }
pc() { command pi -p -c "$@" }

# 历史查看
alias h='fc -l -t "%Y-%m-%d %H:%M:%S" -d'
hg() {
  fc -l -t "%Y-%m-%d %H:%M:%S" -d 0 \
    | grep -- "$@" \
    | sed 's/^[[:space:]]*[0-9]\+[[:space:]]*//' \
    | sed 's/\\n//g'  # 过滤掉回车转义符
}

# Base64 解码
j() {
  if [ -z "$1" ]; then
    echo "Usage: j <base64_string>"
    return 1
  fi
  echo "$1" | base64 --decode
}

# Git commit（无参数则交互输入）
gc() {
  if [ -z "$1" ]; then
    read -r "commit_msg?Please enter a commit message: "
    git commit -m "$commit_msg"
  else
    git commit -m "$1"
  fi
}

# fzf 文件查找（支持多关键词）
ff() {
  local dir="."
  if [ $# -gt 0 ] && [ -d "$1" ]; then
    dir="$1"
    shift
  fi
  local fargs=()
  for q in "$@"; do
    fargs+=(-f "$q")
  done
  find "$dir" -type f 2>/dev/null | fzf --exact "${fargs[@]}"
}

# 把文件/文件夹加入 git 全局忽略 (~/.gitignore)
ig() {
  local ignores="$HOME/.gitignore"
  [ -f "$ignores" ] || touch "$ignores"
  if [ $# -eq 0 ]; then
    echo "Usage: ig <file_or_folder> ..." >&2
    return 1
  fi
  for item in "$@"; do
    local name="${item:t}"  # zsh 取 basename
    if grep -qxF "$name" "$ignores"; then
      echo "already ignored: $name"
    else
      echo "$name" >> "$ignores"
      echo "ignored: $name"
    fi
  done
}

# Agent 配置保护（锁/解锁）
gai() { command "$HOME/.local/bin/agent-config-protection" unlock }
suo() { command "$HOME/.local/bin/agent-config-protection" lock }

# ---------------------------------------------------------------------------
# 开发环境
# ---------------------------------------------------------------------------

# Go
export GOPROXY=https://proxy.golang.org,direct
export GOPATH=$HOME/go
export PATH="$GOPATH/bin:$PATH"

# Python
export PATH="$HOME/Library/Python/3.9/bin:$PATH"

# Tailscale CLI
if [[ -d /Applications/Tailscale.app/Contents/MacOS ]]; then
  export PATH="/Applications/Tailscale.app/Contents/MacOS:$PATH"
fi

# 其他 PATH
export PATH="$HOME/.local/bin:$PATH"

# ggcm (python 脚本)
alias ggcm='python3 /usr/local/bin/ggcm'

# ---------------------------------------------------------------------------
# VS Code Shell 集成
# ---------------------------------------------------------------------------
# VS Code shell integration 已禁用 — 它会拖慢 p10k 异步 VCS 重绘约 800ms+
# if [[ "$TERM_PROGRAM" == "vscode" ]]; then
#   . "/Applications/Visual Studio Code.app/.../shellIntegration-rc.zsh"
# fi

# ---------------------------------------------------------------------------
# pi-web 管理：日志/PID 一律放 ~/.pi（logs/ + run/），不再往家目录拉屎
# 用法:
#   piweb            确保在跑（幂等，没跑就启动，跑着就报状态）
#   piweb start      启动（可跟参数，如: piweb start -p 8080）
#   piweb stop       停止
#   piweb restart    重启
#   piweb status     查看状态
# 环境变量: PI_WEB_PORT 可换端口; PI_WEB_IDLE_TIMEOUT_MS 可覆盖闲置退出设置
# ---------------------------------------------------------------------------
piweb() {
  local port="${PI_WEB_PORT:-30141}"
  local log_file="$HOME/.pi/logs/pi-web.log"
  local pid_file="$HOME/.pi/run/pi-web.pid"

  # 用端口占用判断存活（lsof），比 pgrep -f 靠谱——老写法会匹配到无关进程/自己
  local -a rest=("${@:2}")
  local pid=""
  pid=$(lsof -ti tcp:"$port" 2>/dev/null | head -1)

  case "${1:-start}" in
    status)
      if [[ -n "$pid" ]]; then
        echo "pi-web 运行中 (pid $pid, http://127.0.0.1:$port)"
      else
        echo "pi-web 未运行"
      fi
      ;;
    stop)
      if [[ -n "$pid" ]]; then
        echo "Stopping pi-web (pid $pid)..."
        kill "$pid" 2>/dev/null
        for _ in {1..10}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.3; done
        kill -9 "$pid" 2>/dev/null
        rm -f "$pid_file"
        echo "stopped."
      else
        echo "pi-web 本来就没在跑。"
        rm -f "$pid_file"
      fi
      ;;
    restart)
      piweb stop && piweb start "${rest[@]}"
      ;;
    start|*)
      if [[ -n "$pid" ]]; then
        echo "pi-web 已经在运行 (pid $pid, http://127.0.0.1:$port)。"
        return 0
      fi
      mkdir -p "$HOME/.pi/logs" "$HOME/.pi/run"
      echo "Starting pi-web..."
      # 新版默认会话闲置 10 分钟后自动退出，取消之；你自己 export 了就用你的值
      local idle_opt="PI_WEB_IDLE_TIMEOUT_MS=${PI_WEB_IDLE_TIMEOUT_MS:-0}"
      # 子 shell + nohup 双重脱离：关终端窗口也不带跑
      (
        nohup env "$idle_opt" pi-web --no-open "${rest[@]}" >"$log_file" 2>&1 &
        echo $! > "$pid_file" 2>/dev/null
      )
      # 等端口就绪，最多 20 秒
      for _ in {1..40}; do
        if lsof -ti tcp:"$port" >/dev/null 2>&1; then
          echo "$(lsof -ti tcp:"$port" | head -1)" > "$pid_file"
          echo "started — http://127.0.0.1:$port  (日志: $log_file, pid: $(cat "$pid_file"))"
          return 0
        fi
        sleep 0.5
      done
      echo "failed. 日志：$log_file"
      tail -20 "$log_file"
      return 1
      ;;
  esac
}
# >>> ai-coding-trace qoder-token-usage >>>
export QODER_EXPOSE_TOKEN_USAGE=1
export QODERCN_EXPOSE_TOKEN_USAGE=1
# <<< ai-coding-trace qoder-token-usage <<<
