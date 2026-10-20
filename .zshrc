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
alias p='pi'

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

# Chrome-Agent 启动器（独立 profile + 动态调试端口：显式端口不写 DevToolsActivePort，
# 用 0 让 Chrome 自己挑，MCP 才能靠 --autoConnect 找到它，也永远不会跟 he/ge 撞车）
gac() {
  open -na "Google Chrome" --args \
    --user-data-dir="$HOME/Library/Application Support/Google/Chrome-Agent" \
    --profile-directory="Default" \
    --remote-debugging-port=0 \
    --remote-debugging-address=127.0.0.1 \
    --ignore-certificate-errors \
    --ignore-urlfetcher-cert-requests \
    --no-first-run \
    --no-default-browser-check
}

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

# 模糊查找文件（路径子串匹配，实时遍历，适合记得“路径片段”的场景）
# 用法: ff [目录] 关键词...   目录可省略，默认当前目录
# 多个关键词对整条路径做大小写不敏感的子串匹配（全部命中才输出）；无关键词则列出全部
# 依赖: fd（列文件，自动跳 .gitignore）+ rg（过滤）；默认跳过依赖/构建/系统缓存目录
ff() {
  local dir="$PWD"
  if [ $# -gt 0 ] && [ -d "$1" ]; then
    dir="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
    shift
  fi

  local -a ex=(--exclude node_modules --exclude .git --exclude Library
               --exclude .cache --exclude dist --exclude build
               --exclude .venv --exclude __pycache__ --exclude target)

  # 无关键词：只列文件，交给 fd 的忽略规则
  if [ $# -eq 0 ]; then
    fd -H -t f . "$dir" "${ex[@]}"
    return
  fi

  # 多关键词：每个关键词转义后拼成 .*a.*b.*，rg 一次过滤（全部命中才输出）
  local pat=""
  for kw in "$@"; do
    pat+="${kw//\//\\/}.*"
  done
  fd -H -t f . "$dir" "${ex[@]}" 2>/dev/null | rg -i -- "${pat%.*}"
}

# 快速查找：走 macOS Spotlight 索引，毫秒级，但只匹配“文件名”（不含路径）
# 用法: fff [-d 天数] [目录] 关键词   例: fff helium / fff -d 30 helium / fff ~/Documents 告警
# 需要索引已开启；查不到就先跑一次: sudo mdutil -i on /
fff() {
  local days="" within=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -d) days="$2"; shift 2 ;;
      *) break ;;
    esac
  done

  local dir=""
  if [ $# -gt 1 ] && [ -d "$1" ]; then
    dir="$1"; shift
  fi

  [ -n "$1" ] || { print -r -- "用法: fff [-d 天数] [目录] 关键词" >&2; return 1 }

  [ -n "$days" ] && within=" && kMDItemFSContentChangeDate >= \$time.today(-${days})"
  local q="kMDItemFSName == '*$1*'c${within}"

  if [ -n "$dir" ]; then
    mdfind -onlyin "$dir" "$q"
  else
    mdfind "$q"
  fi
}

# 把文件/文件夹加入「当前仓库」的 .gitignore（从仓库根精确匹配）
# 用法: ig path/to/file ...   必须在 git 仓库内
#
# 本函数只动当前仓库的 .gitignore，写入 /开头的仓库相对路径。
# 全局忽略在 ~/.config/git/ignore（软链接到 dotfiles/config/git/ignore），
# 其中的规则会作用于所有仓库，只应放确实需要全局忽略的类型。
ig() {
  if [ $# -eq 0 ]; then
    print -r -- "用法: ig <文件/文件夹> ..." >&2
    return 1
  fi

  # 定位当前仓库根（git rev-parse 从子目录也能找到）
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    print -r -- "ig: 不在 git 仓库内" >&2
    return 1
  }
  root="$(cd "$root" && pwd -P)" || return 1
  local ignores="$root/.gitignore"
  local item abs rel pattern failed=0

  for item in "$@"; do
    # 转成相对仓库根的路径
    if [ -d "$item" ]; then
      abs="$(cd "$item" 2>/dev/null && pwd -P)"
    elif [ -e "$item" ] || [ -L "$item" ]; then
      abs="$(cd "$(dirname "$item")" 2>/dev/null && pwd -P)/$(basename "$item")"
    else
      print -r -- "ig: 不存在: $item" >&2
      failed=1
      continue
    fi
    case "$abs" in
      "$root"/*) rel="${abs#$root/}" ;;
      *) print -r -- "ig: 不属于当前仓库: $item" >&2; failed=1; continue ;;
    esac
    if [[ "$rel" == *$'\n'* ]]; then
      print -r -- "ig: 文件名含换行，无法写入 .gitignore: $item" >&2
      failed=1
      continue
    fi
    # / 锚定仓库根；文件名中的 glob 字符按字面匹配。
    pattern="/$(print -rn -- "$rel" | sed 's/[][?*\\]/\\&/g; s/ /\\ /g')"
    [ -f "$ignores" ] || touch "$ignores"

    if grep -qxF -- "$pattern" "$ignores"; then
      print -r -- "already ignored: $rel"
    else
      print -r -- "$pattern" >> "$ignores"
      print -r -- "ignored: $rel"
    fi
  done
  return "$failed"
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
# 本地 web 服务统一管理（piweb = pi-web，pui = pi-web-ui，amgr = agent-manager）
#   <name>           确保在跑并给出地址（幂等，只输出 URL → open $(piweb)）
#   <name> start     启动（可跟参数）
#   <name> stop|restart|status|logs
#   pui install      只有想开机自启才用：装 launchd 服务
# 环境变量: PI_WEB_PORT(30141) / PI_UI_PORT(8787) / PI_UI_CWD($HOME)
# ---------------------------------------------------------------------------
# 端口判活必须带 -sTCP:LISTEN，否则浏览器/客户端连上该端口的进程也会被匹配到
_ws_pid() { lsof -ti "tcp:$1" -sTCP:LISTEN 2>/dev/null | head -1 }

# _wsvc <名字> <端口> <日志> <pid文件> [start|stop|restart|status|logs] <启动命令...>
_wsvc() {
  local n=$1 p=$2 l=$3 f=$4; shift 4
  local pid=$(_ws_pid $p)
  case ${1:-start} in
    status)  if [[ -n $pid ]]; then echo "$n 运行中 (pid $pid, http://127.0.0.1:$p)"
             else echo "$n 未运行"; fi ;;
    logs)    tail -n 50 "$l" ;;
    stop)    if [[ -n $pid ]]; then
               echo "Stopping $n (pid $pid)..."; kill $pid 2>/dev/null
               for _ in {1..10}; do kill -0 $pid 2>/dev/null || break; sleep 0.3; done
               kill -9 $pid 2>/dev/null
             else echo "$n 本来就没在跑。"; fi
             rm -f "$f" ;;
    restart) shift; _wsvc "$n" "$p" "$l" "$f" stop && _wsvc "$n" "$p" "$l" "$f" start "$@" ;;
    *)       shift
             if [[ -n $pid ]]; then echo "http://127.0.0.1:$p"; return 0; fi
             mkdir -p "${l:h}" "${f:h}"
             # 子 shell + nohup 双重脱离：关终端窗口也不带跑
             ( nohup "$@" >"$l" 2>&1 & echo $! >"$f" )
             local child=$(cat "$f" 2>/dev/null)
             for _ in {1..40}; do
               pid=$(_ws_pid $p)
               if [[ -n $pid ]]; then echo "$pid" >"$f"; echo "http://127.0.0.1:$p"; return 0; fi
               kill -0 "$child" 2>/dev/null || break   # 子进程自己退了就别干等 20 秒
               sleep 0.5
             done
             echo "$n 启动失败，日志：$l" >&2; tail -20 "$l" >&2; return 1 ;;
  esac
}

# 日志/PID 一律放 ~/.pi（logs/ + run/），不往家目录拉屎
piweb() { local p=${PI_WEB_PORT:-30141}
  _wsvc pi-web "$p" ~/.pi/logs/pi-web.log ~/.pi/run/pi-web.pid "${1:-start}" \
    env "PI_WEB_IDLE_TIMEOUT_MS=${PI_WEB_IDLE_TIMEOUT_MS:-0}" pi-web --no-open "${@:2}" }

pui() { local p=${PI_UI_PORT:-8787}
  if [[ $1 == install ]]; then shift
    pi-web-ui server install --port "$p" --cwd "${PI_UI_CWD:-$HOME}" "$@"; return; fi
  _wsvc pi-web-ui "$p" ~/.pi/logs/pi-web-ui.log ~/.pi/run/pi-web-ui.pid "${1:-start}" \
    pi-web-ui --no-browser --port "$p" --cwd "${PI_UI_CWD:-$HOME}" "${@:2}" }

# agent-manager（~/Documents/agent-manager）：端口写死在 server.js，不能改
# 用法同 piweb：amgr / amgr open / stop / restart / status / logs
# 注意：若按项目 README 装了 launchd 自启，就别再用本函数（会和 KeepAlive 抢端口）
amgr() { local p=9876 d=${AGENT_MANAGER_DIR:-$HOME/Documents/agent-manager}
  [[ -f $d/server.js ]] || { echo "找不到 $d/server.js" >&2; return 1; }
  local l=~/.agent-manager/service.log f=~/.agent-manager/service.pid
  if [[ $1 == open ]]; then
    local url=$(_wsvc agent-manager "$p" "$l" "$f" start node "$d/server.js") || return
    open "$url"; return
  fi
  _wsvc agent-manager "$p" "$l" "$f" "${1:-start}" node "$d/server.js" }

# >>> ai-coding-trace qoder-token-usage >>>
export QODER_EXPOSE_TOKEN_USAGE=1
export QODERCN_EXPOSE_TOKEN_USAGE=1
# <<< ai-coding-trace qoder-token-usage <<<
