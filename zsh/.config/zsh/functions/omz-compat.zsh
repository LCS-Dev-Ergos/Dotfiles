#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++++ OMZ COMPAT LAYER +++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Local replacements for simple OMZ plugins/functions moved out of 20-zinit:
#   - copyfile / copypath
#   - colored-man-pages
#   - web-search
#
# Includes compatibility helpers from OMZ (clipboard detection, open_command,
# omz_urlencode) so behavior stays as close as possible.
#
# ============================================================================ #

# On HyDE with HYDE_ZSH_NO_PLUGINS!=1, shell.zsh uses its own plugin set.
if [[ "$HYDE_ENABLED" == "1" ]] && [[ "${HYDE_ZSH_NO_PLUGINS}" != "1" ]]; then
  return 0
fi

# -----------------------------------------------------------------------------
# Clipboard helpers (adapted from OMZ lib/clipboard.zsh)
# -----------------------------------------------------------------------------
detect-clipboard() {
  emulate -L zsh

  if [[ "${OSTYPE}" == darwin* ]] && (( ${+commands[pbcopy]} )) && (( ${+commands[pbpaste]} )); then
    function clipcopy() { cat "${1:-/dev/stdin}" | pbcopy; }
    function clippaste() { pbpaste; }
  elif [[ "${OSTYPE}" == (cygwin|msys)* ]]; then
    function clipcopy() { cat "${1:-/dev/stdin}" > /dev/clipboard; }
    function clippaste() { cat /dev/clipboard; }
  elif (( $+commands[clip.exe] )) && (( $+commands[powershell.exe] )); then
    function clipcopy() { cat "${1:-/dev/stdin}" | clip.exe; }
    function clippaste() { powershell.exe -noprofile -command Get-Clipboard; }
  elif [[ -n "${WAYLAND_DISPLAY:-}" ]] && (( ${+commands[wl-copy]} )) && (( ${+commands[wl-paste]} )); then
    function clipcopy() { cat "${1:-/dev/stdin}" | wl-copy &>/dev/null &|; }
    function clippaste() { wl-paste --no-newline; }
  elif [[ -n "${DISPLAY:-}" ]] && (( ${+commands[xsel]} )); then
    function clipcopy() { cat "${1:-/dev/stdin}" | xsel --clipboard --input; }
    function clippaste() { xsel --clipboard --output; }
  elif [[ -n "${DISPLAY:-}" ]] && (( ${+commands[xclip]} )); then
    function clipcopy() { cat "${1:-/dev/stdin}" | xclip -selection clipboard -in &>/dev/null &|; }
    function clippaste() { xclip -out -selection clipboard; }
  elif (( ${+commands[lemonade]} )); then
    function clipcopy() { cat "${1:-/dev/stdin}" | lemonade copy; }
    function clippaste() { lemonade paste; }
  elif (( ${+commands[doitclient]} )); then
    function clipcopy() { cat "${1:-/dev/stdin}" | doitclient wclip; }
    function clippaste() { doitclient wclip -r; }
  elif (( ${+commands[win32yank]} )); then
    function clipcopy() { cat "${1:-/dev/stdin}" | win32yank -i; }
    function clippaste() { win32yank -o; }
  elif [[ "${OSTYPE}" == linux-android* ]] && (( ${+commands[termux-clipboard-set]} )); then
    function clipcopy() { cat "${1:-/dev/stdin}" | termux-clipboard-set; }
    function clippaste() { termux-clipboard-get; }
  elif [[ -n "${TMUX:-}" ]] && (( ${+commands[tmux]} )); then
    function clipcopy() { tmux load-buffer -w "${1:--}"; }
    function clippaste() { tmux save-buffer -; }
  else
    function _retry_clipboard_detection_or_fail() {
      local clipcmd="$1"
      shift
      if detect-clipboard; then
        "$clipcmd" "$@"
      else
        print "$clipcmd: Platform $OSTYPE not supported or xclip/xsel not installed" >&2
        return 1
      fi
    }
    function clipcopy() { _retry_clipboard_detection_or_fail clipcopy "$@"; }
    function clippaste() { _retry_clipboard_detection_or_fail clippaste "$@"; }
    return 1
  fi
}

clipcopy() {
  unfunction clipcopy clippaste
  detect-clipboard || true
  clipcopy "$@"
}

clippaste() {
  unfunction clipcopy clippaste
  detect-clipboard || true
  clippaste "$@"
}

# -----------------------------------------------------------------------------
# open_command (adapted from OMZ lib/functions.zsh)
# -----------------------------------------------------------------------------
open_command() {
  local open_cmd

  case "$OSTYPE" in
    darwin*) open_cmd='open' ;;
    cygwin*) open_cmd='cygstart' ;;
    linux*)
      [[ "$(uname -r)" != *icrosoft* ]] && open_cmd='nohup xdg-open' || {
        open_cmd='cmd.exe /c start ""'
        [[ -e "$1" ]] && { 1="$(wslpath -w "${1:a}")" || return 1; }
        [[ "$1" = (http|https)://* ]] && {
          1="$(echo "$1" | sed -E 's/([&|()<>^])/^\1/g')" || return 1
        }
      }
      ;;
    msys*) open_cmd='start ""' ;;
    *)
      print "Platform $OSTYPE not supported" >&2
      return 1
      ;;
  esac

  if [[ -n "$BROWSER" && "$1" = (http|https)://* ]]; then
    "$BROWSER" "$@"
    return
  fi

  ${=open_cmd} "$@" &>/dev/null
}

# -----------------------------------------------------------------------------
# omz_urlencode (adapted from OMZ lib/functions.zsh)
# -----------------------------------------------------------------------------
zmodload zsh/langinfo 2>/dev/null || true
omz_urlencode() {
  emulate -L zsh
  setopt norematchpcre

  local -a opts
  zparseopts -D -E -a opts r m P

  local in_str="$*"
  local str="$in_str"
  local spaces_as_plus=""
  [[ -z "${opts[(r)-P]}" ]] && spaces_as_plus=1

  local encoding="${langinfo[CODESET]:-UTF-8}"
  local -a safe_encodings
  safe_encodings=(UTF-8 utf8 US-ASCII)
  if [[ -z "${safe_encodings[(r)$encoding]}" ]]; then
    str="$(echo -E "$str" | iconv -f "$encoding" -t UTF-8)" || {
      print "Error converting string from $encoding to UTF-8" >&2
      return 1
    }
  fi

  local i byte ord LC_ALL=C
  export LC_ALL
  local reserved=';/?:@&=+$,'
  local mark='_.!~*''()-'
  local dont_escape='[A-Za-z0-9'
  [[ -z "${opts[(r)-r]}" ]] && dont_escape+="$reserved"
  [[ -z "${opts[(r)-m]}" ]] && dont_escape+="$mark"
  dont_escape+=']'

  local url_str=""
  for (( i = 1; i <= ${#str}; ++i )); do
    byte="${str[i]}"
    if [[ "$byte" =~ "$dont_escape" ]]; then
      url_str+="$byte"
    else
      if [[ "$byte" == " " && -n "$spaces_as_plus" ]]; then
        url_str+="+"
      elif [[ "$PREFIX" == *com.termux* ]]; then
        url_str+="$byte"
      else
        ord=$(( [##16] #byte ))
        url_str+="%$ord"
      fi
    fi
  done
  print -r -- "$url_str"
}

# -----------------------------------------------------------------------------
# copyfile / copypath (adapted from OMZ plugins)
# -----------------------------------------------------------------------------
copyfile() {
  emulate -L zsh

  if [[ -z "$1" ]]; then
    print "Usage: copyfile <file>"
    return 1
  fi

  if [[ ! -f "$1" ]]; then
    print "Error: '$1' is not a valid file."
    return 1
  fi

  clipcopy "$1"
  print ${(%):-"%B$1%b copied to clipboard."}
}

copypath() {
  emulate -L zsh
  local file="${1:-.}"
  [[ "$file" = /* ]] || file="$PWD/$file"

  print -n "${file:a}" | clipcopy || return 1
  print ${(%):-"%B${file:a}%b copied to clipboard."}
}

# -----------------------------------------------------------------------------
# colored-man-pages (adapted from OMZ plugin)
# -----------------------------------------------------------------------------
typeset -AHg less_termcap
less_termcap[mb]="${fg_bold[red]}"
less_termcap[md]="${fg_bold[red]}"
less_termcap[me]="${reset_color}"
less_termcap[so]="${fg_bold[yellow]}${bg[blue]}"
less_termcap[se]="${reset_color}"
less_termcap[us]="${fg_bold[green]}"
less_termcap[ue]="${reset_color}"

typeset -g __omz_compat_dir="${${(%):-%x}:A:h}"

colored() {
  local -a environment
  local k v
  for k v in "${(@kv)less_termcap}"; do
    environment+=("LESS_TERMCAP_${k}=${v}")
  done

  environment+=(PAGER="${commands[less]:-$PAGER}")
  environment+=(GROFF_NO_SGR=1)

  if [[ "$OSTYPE" == solaris* ]]; then
    environment+=(PATH="${__omz_compat_dir}:$PATH")
  fi

  command env "${environment[@]}" "$@"
}

man() { colored man "$@"; }
dman() { colored dman "$@"; }
debman() { colored debman "$@"; }

# -----------------------------------------------------------------------------
# web_search (adapted from OMZ plugin)
# -----------------------------------------------------------------------------
web_search() {
  emulate -L zsh

  typeset -A urls
  urls=(
    $ZSH_WEB_SEARCH_ENGINES
    google          "https://www.google.com/search?q="
    bing            "https://www.bing.com/search?q="
    brave           "https://search.brave.com/search?q="
    yahoo           "https://search.yahoo.com/search?p="
    duckduckgo      "https://www.duckduckgo.com/?q="
    startpage       "https://www.startpage.com/do/search?q="
    yandex          "https://yandex.ru/yandsearch?text="
    github          "https://github.com/search?q="
    baidu           "https://www.baidu.com/s?wd="
    ecosia          "https://www.ecosia.org/search?q="
    goodreads       "https://www.goodreads.com/search?q="
    qwant           "https://www.qwant.com/?q="
    givero          "https://www.givero.com/search?q="
    stackoverflow   "https://stackoverflow.com/search?q="
    wolframalpha    "https://www.wolframalpha.com/input/?i="
    archive         "https://web.archive.org/web/*/"
    scholar         "https://scholar.google.com/scholar?q="
    ask             "https://www.ask.com/web?q="
    youtube         "https://www.youtube.com/results?search_query="
    deepl           "https://www.deepl.com/translator#auto/auto/"
    dockerhub       "https://hub.docker.com/search?q="
    gems            "https://rubygems.org/search?query="
    npmpkg          "https://www.npmjs.com/search?q="
    packagist       "https://packagist.org/?query="
    gopkg           "https://pkg.go.dev/search?m=package&q="
    chatgpt         "https://chatgpt.com/?q="
    grok            "https://grok.com/?q="
    claudeai        "https://claude.ai/new?q="
    reddit          "https://www.reddit.com/search/?q="
    ppai            "https://www.perplexity.ai/search/new?q="
    rscrate         "https://crates.io/search?q="
    rsdoc           "https://docs.rs/releases/search?query="
  )

  if [[ -z "${urls[$1]}" ]]; then
    print "Search engine '$1' not supported."
    return 1
  fi

  local url
  if (( $# > 1 )); then
    local param="-P"
    [[ "${urls[$1]}" == *\?*= ]] && param=""
    url="${urls[$1]}$(omz_urlencode $param ${(s: :)@[2,-1]})"
  else
    url="${(j://:)${(s:/:)urls[$1]}[1,2]}"
  fi

  open_command "$url"
}

alias bing='web_search bing'
alias brs='web_search brave'
alias google='web_search google'
alias yahoo='web_search yahoo'
alias ddg='web_search duckduckgo'
alias sp='web_search startpage'
alias yandex='web_search yandex'
alias github='web_search github'
alias baidu='web_search baidu'
alias ecosia='web_search ecosia'
alias goodreads='web_search goodreads'
alias qwant='web_search qwant'
alias givero='web_search givero'
alias stackoverflow='web_search stackoverflow'
alias wolframalpha='web_search wolframalpha'
alias archive='web_search archive'
alias scholar='web_search scholar'
alias ask='web_search ask'
alias youtube='web_search youtube'
alias deepl='web_search deepl'
alias dockerhub='web_search dockerhub'
alias gems='web_search gems'
alias npmpkg='web_search npmpkg'
alias packagist='web_search packagist'
alias gopkg='web_search gopkg'
alias chatgpt='web_search chatgpt'
alias grok='web_search grok'
alias claudeai='web_search claudeai'
alias reddit='web_search reddit'
alias ppai='web_search ppai'
alias rscrate='web_search rscrate'
alias rsdoc='web_search rsdoc'

alias wiki='web_search duckduckgo \!w'
alias news='web_search duckduckgo \!n'
alias map='web_search duckduckgo \!m'
alias image='web_search duckduckgo \!i'
alias ducky='web_search duckduckgo \!'

if [[ ${#ZSH_WEB_SEARCH_ENGINES} -gt 0 ]]; then
  typeset -A engines
  engines=($ZSH_WEB_SEARCH_ENGINES)
  typeset key
  for key in ${(k)engines}; do
    alias "$key"="web_search $key"
  done
  unset engines key
fi

# ============================================================================ #
# End of omz-compat.zsh
