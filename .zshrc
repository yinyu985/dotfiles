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
# Powerlevel10k 配置
# ---------------------------------------------------------------------------
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# ---------------------------------------------------------------------------
# 基础环境变量
# ---------------------------------------------------------------------------
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export LESSHISTFILE=/dev/null
export HOMEBREW_NO_AUTO_UPDATE=true

# Homebrew
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

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

# ---------------------------------------------------------------------------
# Zsh 行为配置
# ---------------------------------------------------------------------------
WORDCHARS=${WORDCHARS//\//}

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
alias cp='cp -i'
alias la='ls -alh'
alias lh='ls -lh'
alias grep='grep --color=auto'
alias cl='clear && clear && clear'
alias vi='vim'
alias d='diff -u --color=auto'

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
alias python=python3
p() {
  command pi "$@"
}

pi() {
  command pi -p "$@"
}

pc() {
  command pi -p -c "$@"
}
# ---------------------------------------------------------------------------
# 函数
# ---------------------------------------------------------------------------

# 历史查看
alias h='fc -l -t "%Y-%m-%d %H:%M:%S" -d'
function hg() {
  fc -l -t "%Y-%m-%d %H:%M:%S" -d 0 \
    | grep -- "$@" \
    | sed 's/^[[:space:]]*[0-9]\+[[:space:]]*//' \
    | sed 's/\\n//g'
}

function j() {
  if [ -z "$1" ]; then
    echo "Usage: j <base64_string>"
    return 1
  fi
  echo "$1" | base64 --decode
}

function gc() {
  if [ -z "$1" ]; then
    read -r "commit_msg?Please enter a commit message: "
    git commit -m "$commit_msg"
  else
    git commit -m "$1"
  fi
}

# fzf 文件查找
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

# ---------------------------------------------------------------------------
# 开发环境
# ---------------------------------------------------------------------------

# Python
export PATH="$HOME/Library/Python/3.9/bin:$PATH"

# Tailscale CLI
if [[ -d /Applications/Tailscale.app/Contents/MacOS ]]; then
  export PATH="/Applications/Tailscale.app/Contents/MacOS:$PATH"
fi

# AI API 环境配置
export PROMPT_EOL_MARK="" # 关闭zsh的自动%分割


# 其他 PATH
export PATH="$HOME/.local/bin:$PATH"

# ---------------------------------------------------------------------------
# VS Code Shell 集成
# ---------------------------------------------------------------------------
[[ "$TERM_PROGRAM" == "vscode" ]] && . "$(code --locate-shell-integration-path zsh)"
[[ "$TERM_PROGRAM" == "kiro" ]] && command -v kiro >/dev/null 2>&1 && . "$(kiro --locate-shell-integration-path zsh)"




alias ggcm='python3 /usr/local/bin/ggcm'


# ---- pi-web toggle: start in background / stop ----
piweb() {
  local pidfile="$HOME/.pi-web.pid"
  local logfile="$HOME/.pi-web.log"
  local pid="" i

  # 解析目标端口: -p/--port 参数 > $PORT > 默认 30141
  local port="${PORT:-30141}"
  local -a args; args=("$@")
  for (( i=1; i<=$#args; i++ )); do
    case "${args[$i]}" in
      -p|--port)  port="${args[$i+1]}" ;;
      -p?*|--port=*) port="${${args[$i]}#*=}" ;;
    esac
  done

  # ---- 已在运行? (pidfile → pgrep) ----
  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    pid=$(cat "$pidfile")
  else
    pid=$(pgrep -f 'bin/pi-web(\.js)?$' | head -1)
  fi

  if [[ -n "$pid" ]]; then
    echo "Stopping pi-web (pid $pid)..."
    kill "$pid" 2>/dev/null            # 父进程会负责收掉子进程
    for i in {1..6}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    rm -f "$pidfile"
    echo "pi-web stopped."
    return
  fi

  # ---- 没有 pi-web 进程，但端口被占? (多半是残留的 next-server) ----
  local holder="$(lsof -ti TCP:"$port" -sTCP:LISTEN 2>/dev/null | head -1)"
  if [[ -n "$holder" ]]; then
    local hcmd="$(ps -p "$holder" -o comm= 2>/dev/null)"
    if [[ "$hcmd" == *next* || "$hcmd" == *node* ]]; then
      echo "清理残留进程 $holder ($hcmd)..."
      kill "$holder" 2>/dev/null
      for i in {1..6}; do kill -0 "$holder" 2>/dev/null || break; sleep 0.5; done
      kill -0 "$holder" 2>/dev/null && kill -9 "$holder" 2>/dev/null
    else
      echo "端口 $port 已被占用: pid $holder ($hcmd)"
      echo "请改用其他端口, 如: piweb -p 9000"
      return 1
    fi
  fi

  # ---- 启动 ----
  : > "$logfile"                        # 清空日志，避免读到上次的端口
  nohup pi-web "$@" >> "$logfile" 2>&1 &
  pid=$!
  echo "$pid" > "$pidfile"

  # 等 "Local: http://..." 出现，最多 ~15 秒
  local url=""
  for i in {1..30}; do
    kill -0 "$pid" 2>/dev/null || break
    url=$(grep -oE 'http://[^ ]+' "$logfile" | head -1)
    [[ -n "$url" ]] && break
    sleep 0.5
  done

  if [[ -n "$url" ]]; then
    echo "pi-web started (pid $pid)"
    echo "  → $url"
  elif kill -0 "$pid" 2>/dev/null; then
    echo "pi-web (pid $pid) 还在启动中, 日志: $logfile"
  else
    rm -f "$pidfile"
    echo "pi-web 启动失败, 日志末尾:"
    tail -5 "$logfile" | sed 's/^/  | /'
    return 1
  fi
}
# 用法: piweb           启动(后台); 再敲一次则关闭
#       piweb -p 9000   指定端口
# 完整日志: tail -f ~/.pi-web.log
