#!/usr/bin/env bash
# 3x-ui_reverse: installer & manager for 3x-ui behind Nginx/Caddy + HTTPS,
# auto-created Reality/XHTTP/MTProto inbounds, users and groups. TUI and CLI.
# Run as root on a CLEAN VPS. Does not support existing panels/web sites.
set -Eeuo pipefail
umask 077

# Release version = the git tag of the commit this file comes from.
VERSION=v2.4.0
# GitHub repository (owner/name) that publishes tagged releases of this script.
# Can also be set from the "Версия" screen or with XR_REPO=owner/name.
DEFAULT_REPO='dohuyanevezuch/3x-ui_reverse'
UPDATE_ASSET=3x-ui_reverse_install.sh

BASE=/opt/3x-ui_reverse
SITE=$BASE/site
STATE=$BASE/state.env
INFO=$BASE/panel.txt
LOG=$BASE/install.log
DB=/etc/x-ui/x-ui.db
CLI=/usr/local/x-ui/x-ui
SELF=/usr/local/sbin/3x-ui_reverse
XUI_INSTALL_URL=https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh
# API helper, its token and the short-lived Xray access log used for "last inbound".
HELPER=$BASE/xr_helper.py
SUPPORTED_OS='Debian 12/13 и Ubuntu 22.04/24.04/26.04'
HELPER_STATE=''   # overrides XR_STATE_DIR before $BASE exists
PDF_FILE=$BASE/panel.pdf         # the same parameters as a styled PDF
NODE_TOKEN=$BASE/node.token     # node-sync API token handed to a master panel
PAIR_ACTIVE=$BASE/pair.active   # pairing files currently published on the stub site
HELPER_ENV=$BASE/helper.env
API_TOKEN=$BASE/api.token
ACCESS_LOG=/var/log/x-ui/3xr-access.log
ACTIVITY_UNIT=3x-ui-reverse-activity
# Sniffing of the VLESS inbounds: route = routeOnly (sniffed domain used only for
# routing decisions); metadata = metadataOnly (http/tls/quic sniffers stay off).
XR_SNIFF=${XR_SNIFF:-route}
# Ports tried first for new inbounds (look like ordinary TLS alt-ports), then random.
INBOUND_PREFERRED_PORTS=(8443 2053 2083 2087 9443 10443)
TAKEN_PORTS=''
UPDATE_REPO=''
# Plain (non-interactive) output uses ANSI colours; dialogs use markup tags.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
  C_BLUE=$'\e[36m'; C_RESET=$'\e[0m'; C_WHITE=$'\e[97m'
  C_DIM=$'\e[90m'; C_BOLD=$'\e[1m'
else
  C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''; C_RESET=''
  C_WHITE=''; C_DIM=''; C_BOLD=''
fi

# ---------------------------------------------------------------- UI layer
# Dialogs are drawn by a small Python program (written to a private runtime
# directory at start):
#   tui — a persistent full-screen curses process; bash sends JSON requests over
#         a FIFO and reads "RC LEN\n<payload>" answers. Mouse, colours, no
#         buttons: Enter confirms, Backspace goes back.
#   cli — the same dialogs as classic numbered text prompts (--cli / XR_UI=cli).
UI_WANT=${XR_UI:-tui}
UI_MODE=''          # tui | cli | '' (non-interactive)
TUI_OK=0            # 1 when dialogs are available (either mode)
UI_DIR=''
UI_PY=''
TUI_PID=''
TUI_REQ=''
TUI_RESP=''
UI_OUT_FD=''
UI_ERR_FD=''
UI_RC=0
UI_VAL=''
FINAL_MSG=''
NOTES=()
PCT=0
UI_ACTIVE=0
UI_PHASE_INDEX=-1
UI_PHASES=()
UI_STATES=()
UI_TITLE=''
JESC=''
JARR=''

# JSON string escaping without subshells (requests can carry hundreds of items).
_jesc(){
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/}
  JESC=$s
}
_jarr(){
  local x sep='' out='['
  for x in "$@"; do _jesc "$x"; out+="$sep\"$JESC\""; sep=,; done
  JARR="$out]"
}
# Markup -> ANSI for text printed straight to the terminal in CLI mode.
mk2ansi(){
  local s=$1
  s=${s//'{green}'/$'\e[32m'}; s=${s//'{red}'/$'\e[31m'}; s=${s//'{yellow}'/$'\e[33m'}
  s=${s//'{accent}'/$'\e[36;1m'}; s=${s//'{cyan}'/$'\e[36m'}; s=${s//'{blue}'/$'\e[34m'}
  s=${s//'{magenta}'/$'\e[35m'}; s=${s//'{dim}'/$'\e[90m'}; s=${s//'{bold}'/$'\e[1m'}
  s=${s//'{white}'/$'\e[97;1m'}; s=${s//'{/}'/$'\e[0m'}
  printf '%s' "$s"
}
ui_tty_print(){ printf '%s\n' "$(mk2ansi "$*")" >/dev/tty 2>/dev/null || printf '%s\n' "$*" >&2; }

ensure_python(){
  command -v python3 >/dev/null 2>&1 && return 0
  [[ $EUID -eq 0 ]] && command -v apt-get >/dev/null 2>&1 || return 1
  printf 'Устанавливаю python3 для интерфейса…\n'
  { DEBIAN_FRONTEND=noninteractive apt-get install -y python3 \
    || { apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y python3; }; } >/dev/null 2>&1
  command -v python3 >/dev/null 2>&1
}
# Starts the curses process and moves the script's own output off the terminal.
tui_start(){
  local lines cols h1 h2 line sink
  lines=$(tput lines 2>/dev/null || echo 24); cols=$(tput cols 2>/dev/null || echo 80)
  [[ $lines =~ ^[0-9]+$ && $cols =~ ^[0-9]+$ ]] || return 1
  ((lines >= 16 && cols >= 60)) || return 1
  python3 -c 'import curses' >/dev/null 2>&1 || return 1
  mkfifo -m 600 "$UI_DIR/req" "$UI_DIR/resp" || return 1
  python3 -I "$UI_PY" serve "$UI_DIR" </dev/tty >/dev/tty 2>>"$UI_DIR/ui.err" &
  TUI_PID=$!
  # Read-write opens never block: they let the UI open its ends, then a
  # handshake proves it is alive before the one-way descriptors are used.
  exec {h1}<>"$UI_DIR/req" {h2}<>"$UI_DIR/resp"
  if ! IFS= read -r -t 10 line <&"$h2" || [[ "$line" != READY ]]; then
    kill "$TUI_PID" 2>/dev/null || :
    exec {h1}>&- {h2}>&-
    TUI_PID=''
    return 1
  fi
  exec {TUI_REQ}>"$UI_DIR/req" {TUI_RESP}<"$UI_DIR/resp"
  exec {h1}>&- {h2}>&-
  # From now on the terminal belongs to the UI process.
  sink=$UI_DIR/ui.log
  [[ -w "$LOG" ]] && sink=$LOG
  exec {UI_OUT_FD}>&1 {UI_ERR_FD}>&2 >>"$sink" 2>&1
  return 0
}
# shellcheck disable=SC2034  # C_RED is kept for call sites added later
ui_markup_colors(){
  C_GREEN='{green}'; C_YELLOW='{yellow}'; C_RED='{red}'; C_BLUE='{accent}'
  C_RESET='{/}'; C_WHITE='{bold}'; C_DIM='{dim}'; C_BOLD='{bold}'
  export XR_MARKUP=1
}
ui_init(){
  [[ -n $UI_MODE ]] && return 0
  [[ -t 0 && -t 1 ]] || return 1
  # Cyrillic and box-drawing glyphs need a UTF-8 locale.
  if [[ "$(locale charmap 2>/dev/null || true)" != UTF-8 ]]; then
    export LC_ALL=C.UTF-8 LANG=C.UTF-8
  fi
  ensure_python || return 1
  UI_DIR=$(mktemp -d "${TMPDIR:-/tmp}/3xr-ui.XXXXXXXX") || return 1
  UI_PY=$UI_DIR/xr_tui.py
  write_ui_program "$UI_PY"
  if [[ "$UI_WANT" != cli ]] && tui_start; then UI_MODE=tui; else UI_MODE=cli; fi
  TUI_OK=1
  ui_markup_colors
}
# Kept for older call sites.
tui_init(){ ui_init; }
ui_shutdown(){
  if [[ $UI_MODE == tui && -n $TUI_PID ]]; then
    ( set +e; trap - ERR; printf '{"cmd":"quit"}\n' >&"$TUI_REQ" ) 2>/dev/null || :
    exec {TUI_REQ}>&- {TUI_RESP}>&- 2>/dev/null || :
    local i
    for ((i=0; i<40; i++)); do kill -0 "$TUI_PID" 2>/dev/null || break; sleep 0.05; done
    kill "$TUI_PID" 2>/dev/null || :
    wait "$TUI_PID" 2>/dev/null || :
    exec 1>&"$UI_OUT_FD" 2>&"$UI_ERR_FD" {UI_OUT_FD}>&- {UI_ERR_FD}>&-
    stty sane 2>/dev/null || :
    TUI_PID=''
  fi
  [[ -z "$UI_DIR" ]] || rm -rf -- "$UI_DIR"
  UI_DIR=''; UI_MODE=''; TUI_OK=0
  [[ -z "$FINAL_MSG" ]] || printf '%s\n' "$FINAL_MSG" >&2
  FINAL_MSG=''
}
# The UI process vanished: continue the session with text dialogs.
ui_lost(){
  if [[ -n "$UI_OUT_FD" ]]; then exec 1>&"$UI_OUT_FD" 2>&"$UI_ERR_FD"; fi
  exec {TUI_REQ}>&- {TUI_RESP}>&- || :
  TUI_PID=''
  UI_MODE=cli
  ui_tty_print '{yellow}⚠ Графический интерфейс завершился, продолжаю в текстовом режиме.{/}'
}
# ui_call JSON — one dialog; result in UI_RC / UI_VAL.
ui_call(){
  local len
  if [[ $UI_MODE == tui ]]; then
    if ( set +e; trap - ERR; printf '%s\n' "$1" >&"$TUI_REQ" ) 2>/dev/null \
       && IFS=' ' read -r UI_RC len <&"$TUI_RESP"; then
      UI_VAL=''
      if ((len > 0)) && ! IFS= read -r -N "$len" UI_VAL <&"$TUI_RESP"; then ui_lost; else return 0; fi
    else
      ui_lost
    fi
  fi
  UI_RC=0
  UI_VAL=$(printf '%s' "$1" | python3 -I "$UI_PY" cli) || UI_RC=$?
}
_ctx(){ _jesc "${DOMAIN:-}"; printf '%s' "$JESC"; }
# TUI_LOGO=1 before a dialog call draws the logo above it (TUI, when it fits).
_logo(){ [[ "${TUI_LOGO:-}" == 1 && $UI_MODE == tui ]] && printf ',"logo":true'; return 0; }
# Start screen with the logo while the next screen is being prepared.
ui_splash(){
  local jt js
  _jesc "${1:-}"; jt=$JESC; _jesc "${2:-загрузка…}"; js=$JESC
  [[ -n "$UI_MODE" ]] && ui_call "{\"cmd\":\"splash\",\"text\":\"$jt\",\"status\":\"$js\"}"
  return 0
}
# Usable text width inside dialogs (tables are formatted to it).
ui_width(){
  local cols
  cols=$(tput cols 2>/dev/null || echo 100)
  [[ $cols =~ ^[0-9]+$ ]] || cols=100
  ((cols > 108)) && cols=108
  printf '%s' $((cols - 8))
}

tui_msg(){
  local jt jx
  _jesc "$1"; jt=$JESC; _jesc "$2"; jx=$JESC
  ui_call "{\"cmd\":\"msg\",\"title\":\"$jt\",\"text\":\"$jx\",\"ok\":\"продолжить\",\"ctx\":\"$(_ctx)\"$(_logo)}"
  return 0
}
# tui_yesno TITLE TEXT [YES] [NO] [yes|no — default choice, «no» by default]
tui_yesno(){
  local jt jx jy jn dn=true
  _jesc "$1"; jt=$JESC; _jesc "$2"; jx=$JESC; _jesc "${3:-Да}"; jy=$JESC; _jesc "${4:-Нет}"; jn=$JESC
  [[ "${5:-no}" == yes ]] && dn=false
  ui_call "{\"cmd\":\"yesno\",\"title\":\"$jt\",\"text\":\"$jx\",\"yes\":\"$jy\",\"no\":\"$jn\",\"defaultno\":$dn,\"ctx\":\"$(_ctx)\"$(_logo)}"
  return "$UI_RC"
}
tui_input(){
  local jt jx jd
  _jesc "$1"; jt=$JESC; _jesc "$2"; jx=$JESC; _jesc "${3:-}"; jd=$JESC
  ui_call "{\"cmd\":\"input\",\"title\":\"$jt\",\"text\":\"$jx\",\"default\":\"$jd\",\"ctx\":\"$(_ctx)\"$(_logo)}"
  ((UI_RC == 0)) || return 1
  printf '%s' "$UI_VAL"
}
# tui_menu TITLE TEXT TAG LABEL [TAG LABEL…] — prints the chosen tag.
# TUI_DEFAULT=TAG preselects an item (otherwise the last choice in this window).
# Tags are never shown in the TUI; a tag starting with # is a section heading.
# A tab inside LABEL splits it into aligned columns.
tui_menu(){
  local jt jx jc
  _jesc "$1"; jt=$JESC; _jesc "$2"; jx=$JESC; shift 2
  _jarr "$@"; _jesc "${TUI_CANCEL:-Назад}"; jc=$JESC; _jesc "${TUI_DEFAULT:-}"
  ui_call "{\"cmd\":\"menu\",\"title\":\"$jt\",\"text\":\"$jx\",\"items\":$JARR,\"cancel\":\"$jc\",\"default\":\"$JESC\",\"ctx\":\"$(_ctx)\"$(_logo)}"
  ((UI_RC == 0)) || return 1
  printf '%s' "$UI_VAL"
}
# tui_checklist / tui_radiolist TITLE TEXT TAG LABEL ON|OFF … — one tag per line.
_tui_list(){
  local kind=$1 jt jx
  _jesc "$2"; jt=$JESC; _jesc "$3"; jx=$JESC; shift 3
  _jarr "$@"
  ui_call "{\"cmd\":\"$kind\",\"title\":\"$jt\",\"text\":\"$jx\",\"items\":$JARR,\"ctx\":\"$(_ctx)\"$(_logo)}"
  ((UI_RC == 0)) || return 1
  printf '%s\n' "$UI_VAL"
}
tui_checklist(){ _tui_list check "$@"; }
tui_radiolist(){ _tui_list radio "$@"; }
# Values registered with copy_item LABEL VALUE are copied to the clipboard by
# a click (or Tab + Enter) in the next text view. TUI_WATCH=FILE TUI_EXPIRES=TS
# keep the view open until the file is read by the web server (UI_RC=3) or
# removed/expired (UI_RC=4); closing it by hand gives UI_RC=0.
TUI_COPY=()
copy_item(){ [[ -n "$2" ]] && TUI_COPY+=("$1" "$2"); return 0; }
tui_textfile(){
  local jt jf extra='' i
  _jesc "$1"; jt=$JESC; _jesc "$2"; jf=$JESC
  if ((${#TUI_COPY[@]})); then
    extra=',"copy":['
    for ((i=0; i+1<${#TUI_COPY[@]}; i+=2)); do
      _jarr "${TUI_COPY[i]}" "${TUI_COPY[i+1]}"
      extra+="${JARR}"; ((i+2 < ${#TUI_COPY[@]})) && extra+=','
    done
    extra+=']'
  fi
  if [[ -n "${TUI_WATCH:-}" ]]; then
    _jesc "$TUI_WATCH"; extra+=",\"watch\":\"$JESC\",\"expires\":${TUI_EXPIRES:-0}"
  fi
  TUI_COPY=()
  ui_call "{\"cmd\":\"text\",\"title\":\"$jt\",\"file\":\"$jf\",\"ctx\":\"$(_ctx)\"$extra$(_logo)}"
  return 0
}
# tui_show TITLE CMD… — run a command and show its output in a scrollable view.
tui_show(){
  local title=$1 tmp; shift
  tmp=$(mktemp "${UI_DIR:-${TMPDIR:-/tmp}}/view.XXXXXXXX")
  "$@" >"$tmp" 2>&1 || :
  [[ -s "$tmp" ]] || printf '(пусто)\n' >"$tmp"
  tui_textfile "$title" "$tmp"
  rm -f -- "$tmp"
}
# Asks the user to type a word (yes / УДАЛИТЬ) for destructive operations.
tui_confirm_word(){
  local title=$1 text=$2 word=$3 answer
  answer=$(tui_input "$title" "$text"$'\n\n'"Для подтверждения введи: {bold}$word{/}") || return 1
  [[ "$answer" == "$word" ]] && return 0
  tui_msg 'Отменено' 'Подтверждение не совпало — ничего не изменено.'
  return 1
}
# Hands the terminal to an external program (editor) and takes it back.
tui_suspend(){ [[ $UI_MODE == tui ]] && ui_call '{"cmd":"suspend"}'; return 0; }
tui_resume(){ [[ $UI_MODE == tui ]] && ui_call '{"cmd":"resume"}'; return 0; }
# Messages produced by an operation are collected and shown once it finishes.
note(){
  if [[ $UI_MODE == tui ]]; then NOTES+=("$*")
  elif [[ $UI_MODE == cli ]]; then ui_tty_print "$*"
  else printf '%s\n' "$*"; fi
}
flush_notes(){
  ((${#NOTES[@]})) || return 0
  local text
  text=$(printf '%s\n' "${NOTES[@]}")
  NOTES=()
  tui_msg "${1:-Результат}" "$text"
}

# Progress of long operations: phases with ✓/spinner/✗ and a progress bar.
ui_redraw(){
  [[ $UI_ACTIVE == 1 && $UI_MODE == tui ]] || return 0
  local jt jp
  _jesc "$UI_TITLE"; jt=$JESC; _jarr "${UI_PHASES[@]}"; jp=$JARR; _jarr "${UI_STATES[@]}"
  ui_call "{\"cmd\":\"gauge\",\"title\":\"$jt\",\"phases\":$jp,\"states\":$JARR,\"pct\":$PCT,\"ctx\":\"$(_ctx)\"}"
}
ui_start(){
  local heading=$1 p; shift
  UI_TITLE=$heading; UI_PHASES=("$@"); UI_STATES=(); PCT=0; UI_PHASE_INDEX=-1
  for p in "$@"; do UI_STATES+=(pending); done
  UI_ACTIVE=1
  if [[ $UI_MODE == tui ]]; then ui_redraw
  elif [[ $UI_MODE == cli ]]; then ui_tty_print "{accent}◆ $heading{/}"
  else printf '◆ %s\n' "$heading"; fi
}
ui_stage(){
  local title=$1 i found=-1
  [[ $UI_ACTIVE == 1 ]] || { [[ $UI_MODE == tui ]] || printf '◌ %s\n' "$title"; return 0; }
  ((UI_PHASE_INDEX >= 0)) && UI_STATES[UI_PHASE_INDEX]='done'
  for i in "${!UI_PHASES[@]}"; do
    if [[ "${UI_PHASES[i]}" == "$title" ]]; then found=$i; break; fi
  done
  if ((found == -1)); then
    # Keep a coherent progress block if an upstream step was renamed.
    for i in "${!UI_PHASES[@]}"; do
      if [[ "${UI_STATES[i]}" == pending ]]; then found=$i; break; fi
    done
    ((found >= 0)) || return 0
    UI_PHASES[found]=$title
  fi
  UI_PHASE_INDEX=$found
  UI_STATES[found]=current
  if [[ $UI_MODE == tui ]]; then ui_redraw
  elif [[ $UI_MODE == cli ]]; then ui_tty_print "  {accent}➜{/} $title"
  else printf '  ➜ %s\n' "$title"; fi
}
ui_stop(){
  [[ $UI_ACTIVE == 1 ]] || return 0
  local result=${1:-complete}
  if ((UI_PHASE_INDEX >= 0)); then
    if [[ $result == complete ]]; then UI_STATES[UI_PHASE_INDEX]='done'; else UI_STATES[UI_PHASE_INDEX]=failed; fi
  fi
  [[ $result == complete ]] && PCT=100
  if [[ $UI_MODE == tui ]]; then
    ui_redraw
    sleep 0.4
  elif [[ $UI_MODE == cli ]]; then
    if [[ $result == complete ]]; then ui_tty_print '  {green}✓ готово{/}'; else ui_tty_print '  {red}✗ прервано{/}'; fi
  fi
  UI_ACTIVE=0
  UI_PHASE_INDEX=-1
}
trap 'declare -F pair_revoke >/dev/null && pair_revoke; ui_shutdown' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

unexpected_failure(){
  local code=$1 line=$2
  trap - ERR
  ui_stop failed
  # A pre-install log lives in the temporary UI dir, which is removed on exit.
  if [[ -n "$UI_DIR" && "$LOG" == "$UI_DIR"/* && -f "$LOG" ]] \
     && cp "$LOG" /root/3x-ui_reverse-install.log 2>/dev/null; then
    LOG=/root/3x-ui_reverse-install.log
  fi
  if [[ $TUI_OK == 1 ]]; then
    tui_msg 'Неожиданная ошибка' "{red}Строка $line, код $code.{/}"$'\n\n'"Журнал диагностики: $LOG"
  fi
  FINAL_MSG="Неожиданная ошибка на строке $line (код $code). Лог: $LOG"
  exit "$code"
}
trap 'unexpected_failure "$?" "$LINENO"' ERR
msg(){ ui_stage "$*"; }
warn(){
  if [[ $UI_MODE == tui ]]; then NOTES+=("⚠ $*")
  elif [[ $UI_MODE == cli ]]; then ui_tty_print "{yellow}⚠ $*{/}"
  else printf '%s⚠ %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; fi
}
die(){
  ui_stop failed
  if [[ $TUI_OK == 1 ]]; then
    local extra=''
    ((${#NOTES[@]})) && extra=$'\n\n'"$(printf '%s\n' "${NOTES[@]}")"
    NOTES=()
    [[ -f "$LOG" ]] && extra+=$'\n\n'"{dim}Журнал: $LOG{/}"
    tui_msg 'Ошибка' "{red}$*{/}$extra"
  fi
  FINAL_MSG="Ошибка: $*"
  [[ -f "$LOG" ]] && FINAL_MSG+=" (лог: $LOG)"
  exit 1
}
progress(){
  PCT=$1
  if [[ $UI_ACTIVE == 1 && $UI_MODE == tui ]]; then ui_redraw
  elif [[ $UI_MODE == '' ]]; then printf '%s  %3d%%%s  %s\n' "$C_BLUE" "$PCT" "$C_RESET" "${2:-}"; fi
}
step(){ progress "$1" "${2:-}"; }
# Commands started while the UI runs must not inherit its FIFOs or the saved
# terminal descriptors (a daemonised child would keep them open forever).
run(){
  if [[ $UI_MODE == tui ]]; then
    "$@" >>"$LOG" 2>&1 {TUI_REQ}>&- {TUI_RESP}>&- {UI_OUT_FD}>&- {UI_ERR_FD}>&-
  else
    "$@" >>"$LOG" 2>&1
  fi
}
rand(){ head -c 72 /dev/urandom | base64 -w0 | tr -dc 'a-zA-Z0-9' | head -c "$1" || true; }
# A port is busy when it is the panel/subscription port, already reserved in this
# run or by an existing inbound (TAKEN_PORTS), or anything listens on it (TCP/UDP).
port_busy(){
  local p=$1
  [[ "$p" == "${PANEL_PORT:-}" || "$p" == "${SUB_PORT:-}" || " ${TAKEN_PORTS:-} " == *" $p "* ]] && return 0
  ss -H -ltn "sport = :$p" | grep -q . && return 0
  ss -H -lun "sport = :$p" | grep -q . && return 0
  return 1
}
newport(){
  local p i
  for ((i=0;i<150;i++)); do
    p=$(shuf -i 15000-59000 -n1)
    if ! port_busy "$p"; then echo "$p"; return; fi
  done
  return 1
}
inbound_port(){
  local p
  for p in "${INBOUND_PREFERRED_PORTS[@]}"; do
    if ! port_busy "$p"; then echo "$p"; return 0; fi
  done
  newport
}
valid_domain(){
  [[ ${#1} -le 253 && "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}
valid_port(){ [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535)); }
valid_panel_port(){ valid_port "$1" || [[ "$1" == 443 ]]; }
valid_path(){ [[ "$1" =~ ^[a-zA-Z0-9_-]{6,64}$ ]]; }

check_environment(){
  [[ $EUID -eq 0 ]] || die 'Запускать нужно от root (sudo bash ...).'
  [[ -d /run/systemd/system ]] || die 'Требуется systemd.'
  [[ -r /etc/os-release ]] || die 'ОС не определена.'
  # Read os-release in a subshell: it defines VERSION, NAME, ID… which would
  # overwrite this script's own VERSION (and break self-install and updates).
  local os_id os_ver
  os_id=$(. /etc/os-release && printf '%s' "${ID:-}")
  os_ver=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
  [[ $os_id == debian || $os_id == ubuntu ]] || die "Поддерживаются только $SUPPORTED_OS."
  case "$os_id:$os_ver" in
    debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) ;;
    *)
      # Releases newer than the tested ones usually work: ask instead of refusing.
      local major=${os_ver%%.*}
      local newer=0
      if [[ "$major" =~ ^[0-9]+$ ]]; then
        if [[ $os_id == debian ]]; then ((major > 13)) && newer=1; else ((major >= 24)) && newer=1; fi
      fi
      if ((newer)); then
        tui_yesno 'Версия ОС' "{yellow}⚠ $os_id $os_ver ещё не проверялась{/} — поддерживаются $SUPPORTED_OS.

Скорее всего, установка пройдёт, но возможны ошибки. Продолжить?" 'Продолжить' 'Отмена' no || exit 0
      else
        die "Неподдерживаемая версия: $os_id ${os_ver:-?}. Поддерживаются $SUPPORTED_OS."
      fi ;;
  esac
  if [[ -e "$STATE" || -e "$DB" || -e /usr/local/x-ui/x-ui ]] || systemctl list-unit-files --no-legend x-ui.service 2>/dev/null | grep -q '^x-ui.service'; then
    die 'Обнаружена существующая 3x-ui / конфигурация. Установка только на чистый VPS.'
  fi
  if [[ -e "$SELF" && "$0" != "$SELF" && ! -e "$STATE" ]]; then die 'Обнаружен старый 3x-ui_reverse без состояния: проверь установку вручную.'; fi
  command -v ss >/dev/null || true
  # Do not change someone else's web services, even if not 80/443.
  if command -v nginx >/dev/null || command -v caddy >/dev/null || [[ -e /etc/nginx/sites-enabled/3x-ui_reverse.conf ]]; then
    die 'Обнаружены Nginx/Caddy. Скрипт требует чистый VPS, чтобы не повредить сайты.'
  fi
  if command -v ss >/dev/null && ss -H -ltn '( sport = :80 or sport = :443 )' | grep -q .; then
    die 'Порты 80 или 443 уже заняты. Останови конфликтующую службу до установки.'
  fi
  if [[ -e "$BASE" ]]; then die "Каталог $BASE уже существует. Проверь его перед установкой."; fi
}

save_state(){
  local tmp; tmp=$(mktemp "$BASE/state.XXXXXXXX")
  {
    printf 'DOMAIN=%q\n' "$DOMAIN"
    printf 'PROXY=%q\n' "$PROXY"
    printf 'PANEL_PORT=%q\n' "$PANEL_PORT"
    printf 'PANEL_PATH=%q\n' "$PANEL_PATH"
    printf 'PANEL_USER=%q\n' "$PANEL_USER"
    printf 'PANEL_PASS=%q\n' "$PANEL_PASS"
    printf 'SUB_PORT=%q\n' "$SUB_PORT"
    printf 'SUB_PATH=%q\n' "$SUB_PATH"
    printf 'JSON_PATH=%q\n' "$JSON_PATH"
    printf 'CLASH_PATH=%q\n' "$CLASH_PATH"
    printf 'PANEL_INSTALLED=%q\n' "${PANEL_INSTALLED:-1}"
    printf 'PROXY_INSTALLED=%q\n' "${PROXY_INSTALLED:-1}"
    printf 'TLS_MODE=%q\n' "${TLS_MODE:-proxy}"
    printf 'UPDATE_REPO=%q\n' "${UPDATE_REPO:-}"
  } > "$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$STATE"
  # Panel port/path may have changed: keep the activity timer's API address current.
  write_helper_env
}
load_state(){
  [[ -r "$STATE" ]] || die "Файл $STATE отсутствует."
  # trusted root-owned, chmod 600 installer file
  [[ $(stat -c %u "$STATE") == 0 && $(stat -c %a "$STATE") == 600 ]] || die "Небезопасные права у $STATE"
  # shellcheck disable=SC1090
  source "$STATE"
  PANEL_INSTALLED=${PANEL_INSTALLED:-1}
  PROXY_INSTALLED=${PROXY_INSTALLED:-1}
  TLS_MODE=${TLS_MODE:-proxy}
  [[ "$PANEL_INSTALLED" =~ ^[01]$ && "$PROXY_INSTALLED" =~ ^[01]$ ]] || die "Некорректные флаги состояния."
  [[ "$TLS_MODE" == proxy || "$TLS_MODE" == direct || "$TLS_MODE" == none ]] || die "Некорректный TLS_MODE."
  valid_domain "$DOMAIN" || die 'Неверный домен в состоянии.'
  [[ $PROXY == caddy || $PROXY == nginx ]] || die 'Неверный тип прокси в состоянии.'
  valid_panel_port "$PANEL_PORT" && valid_port "$SUB_PORT" || die 'Неверный порт в состоянии.'
  for p in "$PANEL_PATH" "$SUB_PATH" "$JSON_PATH" "$CLASH_PATH"; do valid_path "$p" || die 'Неверный путь в состоянии.'; done
  UPDATE_REPO=${UPDATE_REPO:-}
  [[ -z "$UPDATE_REPO" || "$UPDATE_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || UPDATE_REPO=''
}
certdir(){ echo "$BASE/sertificates/$DOMAIN"; }
proxy_conf(){ if [[ "$PROXY" == caddy ]]; then echo "$BASE/Caddyfile"; else echo /etc/nginx/sites-available/3x-ui_reverse.conf; fi; }
write_info(){
  local certs panel_url sub_url json_url clash_url location
  if [[ "${PROXY_INSTALLED:-1}" == 1 ]]; then
    certs=$(certdir)
    location="$(proxy_conf)"
    panel_url="https://$DOMAIN/$PANEL_PATH/"
    sub_url="https://$DOMAIN/$SUB_PATH/CLIENT_SUB_ID"
    json_url="https://$DOMAIN/$JSON_PATH/CLIENT_SUB_ID"
    clash_url="https://$DOMAIN/$CLASH_PATH/CLIENT_SUB_ID"
  elif [[ "${TLS_MODE:-none}" == direct && "${PANEL_INSTALLED:-1}" == 1 ]]; then
    certs="/root/cert/$DOMAIN (acme.sh / 3x-ui)"
    location='Не используется'
    panel_url="https://$DOMAIN/$PANEL_PATH/"
    sub_url="https://$DOMAIN:$SUB_PORT/$SUB_PATH/CLIENT_SUB_ID"
    json_url="https://$DOMAIN:$SUB_PORT/$JSON_PATH/CLIENT_SUB_ID"
    clash_url="https://$DOMAIN:$SUB_PORT/$CLASH_PATH/CLIENT_SUB_ID"
  else
    certs='Не используется'
    location='Прокси удалён'
    panel_url='Панель недоступна'
    sub_url='Подписки недоступны'
    json_url="$sub_url"
    clash_url="$sub_url"
  fi
  cat > "$INFO" <<EOF
3x-ui_reverse — параметры установки
===================================
Домен:                 $DOMAIN
Прокси:                $PROXY (установлен: $PROXY_INSTALLED)
3x-ui:                 установлен: $PANEL_INSTALLED
TLS:                   $TLS_MODE
Панель:                $panel_url
Логин:                 $PANEL_USER
Пароль:                $PANEL_PASS
Порт панели:           $PANEL_PORT

Подписки (вместо CLIENT_SUB_ID укажи Sub ID клиента):
VLESS/общая:           $sub_url
JSON:                  $json_url
Mihomo/Clash:          $clash_url
Порт подписок:         $SUB_PORT

Конфигурация прокси:   $location
Сертификаты:           $certs
Сайт-заглушка:         $SITE/index.html
Логи:                  $LOG
Меню:                  sudo 3x-ui_reverse
Пользователи:          sudo 3x-ui_reverse --users

ВАЖНО: этот файл содержит учётные данные. Храни его конфиденциально (chmod 600).
EOF
  chmod 600 "$INFO"
  # Keep an existing PDF in step with the new parameters (best effort).
  if [[ -f "$PDF_FILE" ]] && declare -F write_pdf >/dev/null; then write_pdf || :; fi
  return 0
}

site_html(){
  install -d -m 755 "$SITE"
  cat > "$SITE/index.html" <<'HTML'
<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>Скоро открытие</title>
<style>
:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;font-family:Inter,system-ui,-apple-system,'Segoe UI',sans-serif;background:#0b1020;color:#e7ebff;overflow:hidden}
body:before{content:'';position:fixed;inset:-30%;background:radial-gradient(circle at 30% 40%,#4555bd55,transparent 38%),radial-gradient(circle at 70% 65%,#12b8a533,transparent 40%);filter:blur(40px);animation:float 14s ease-in-out infinite alternate}
main{position:relative;width:min(90vw,650px);padding:clamp(34px,7vw,70px);background:#ffffff0a;border:1px solid #ffffff26;border-radius:30px;box-shadow:0 30px 90px #0005;text-align:center;backdrop-filter:blur(18px)}
mark{display:inline-block;padding:9px 15px;border-radius:50px;background:#50dac31a;border:1px solid #50dac355;color:#7ce7d2;font-size:12px;letter-spacing:.17em;text-transform:uppercase}
h1{font-size:clamp(37px,7vw,64px);line-height:1.06;letter-spacing:-.055em;margin:30px 0 18px}p{line-height:1.7;color:#b2bdd5;font-size:16px;margin:0 auto;max-width:425px}
footer{margin-top:44px;font-size:12px;color:#7f8ba4}.dot{display:inline-block;width:7px;height:7px;border-radius:50%;background:#63e6c7;margin-right:8px;box-shadow:0 0 20px #63e6c7}
@keyframes float{to{transform:translate(6%,-4%)}}@media(prefers-reduced-motion:reduce){body:before{animation:none}}
</style></head><body><main><mark><span class="dot"></span>В процессе запуска</mark><h1>Скоро здесь<br>что-то появится.</h1><p>Мы готовим новый сервис. Совсем скоро он будет доступен — спасибо за ваше терпение.</p><footer>Спасибо, что заглянули ✦</footer></main></body></html>
HTML
  chmod 644 "$SITE/index.html"
}

write_caddy(){
  local target=${1:-$BASE/Caddyfile}
  cat > "$target" <<EOF
{
    storage file_system $(certdir)
}

$DOMAIN {
    encode zstd gzip
    root * $SITE
    header {
        X-Content-Type-Options nosniff
        Referrer-Policy strict-origin-when-cross-origin
        -Server
    }
EOF
  if [[ "${PANEL_INSTALLED:-1}" == 1 ]]; then
    cat >> "$target" <<EOF
    redir /$PANEL_PATH /$PANEL_PATH/ 308
    @panel path /$PANEL_PATH/*
    handle @panel {
        reverse_proxy 127.0.0.1:$PANEL_PORT
    }
    @subscriptions path /$SUB_PATH/* /$JSON_PATH/* /$CLASH_PATH/*
    handle @subscriptions {
        reverse_proxy 127.0.0.1:$SUB_PORT
    }
EOF
  fi
  cat >> "$target" <<'EOF'
    handle {
        try_files {path} /index.html
        file_server
    }
}
EOF
  chmod 644 "$target"
}

write_nginx(){
  local mode=${1:-full} target=${2:-/etc/nginx/sites-available/3x-ui_reverse.conf}
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  cat > "$target" <<EOF
# Managed by 3x-ui_reverse. Do not edit here; use: 3x-ui_reverse
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ {
        root $SITE;
        default_type text/plain;
        try_files \$uri =404;
    }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
  if [[ "$mode" == full ]]; then
    cat >> "$target" <<EOF
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;
    ssl_certificate $(certdir)/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key $(certdir)/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    root $SITE;
    index index.html;
EOF
    if [[ "${PANEL_INSTALLED:-1}" == 1 ]]; then
      cat >> "$target" <<EOF
    location = /$PANEL_PATH { return 308 /$PANEL_PATH/; }
    location ^~ /$PANEL_PATH/ {
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_pass http://127.0.0.1:$PANEL_PORT;
    }
EOF
    for path in "$SUB_PATH" "$JSON_PATH" "$CLASH_PATH"; do
      cat >> "$target" <<EOF
    location ^~ /$path/ {
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port 443;
        proxy_pass http://127.0.0.1:$SUB_PORT;
    }
EOF
    done
    fi
    cat >> "$target" <<'EOF'
    location / { try_files $uri $uri/ /index.html; }
}
EOF
  fi
  chmod 644 "$target"
}

validate_proxy(){
  if [[ "$PROXY" == caddy ]]; then run caddy validate --config "$BASE/Caddyfile" --adapter caddyfile
  else run nginx -t; fi
}
reload_proxy(){
  if [[ "$PROXY" == caddy ]]; then run systemctl reload caddy || run systemctl restart caddy
  else run systemctl reload nginx || run systemctl restart nginx; fi
}
# Apply subscription config while x-ui is stopped. Only works with the fresh SQLite installation.
# The schema is inspected before changing any data; a backup is kept for diagnosis/recovery.
set_subscriptions(){
  python3 - "$DB" "$DOMAIN" "$SUB_PORT" "$SUB_PATH" "$JSON_PATH" "$CLASH_PATH" <<'PY'
import sqlite3, sys
fn, domain, port, sub, js, clash = sys.argv[1:]
con = sqlite3.connect(fn, timeout=15)
try:
    cols = {r[1] for r in con.execute('PRAGMA table_info(settings)')}
    if not {'key','value'}.issubset(cols):
        raise SystemExit('Unknown 3x-ui SQLite settings schema; manual intervention required')
    updates = {
        'subEnable':'true', 'subListen':'127.0.0.1', 'subPort':port,
        'subPath':f'/{sub}/', 'subDomain':domain,
        'subCertFile':'', 'subKeyFile':'',
        'subURI':f'https://{domain}/{sub}/',
        'subJsonEnable':'true', 'subJsonPath':f'/{js}/',
        'subJsonURI':f'https://{domain}/{js}/',
        'subClashEnable':'true', 'subClashPath':f'/{clash}/',
        'subClashURI':f'https://{domain}/{clash}/',
        'webCertFile':'', 'webKeyFile':'',
    }
    with con:
        for k, v in updates.items():
            row = con.execute('SELECT rowid FROM settings WHERE key=?', (k,)).fetchone()
            if row:
                con.execute('UPDATE settings SET value=? WHERE rowid=?', (v, row[0]))
            else:
                con.execute('INSERT INTO settings (key,value) VALUES (?,?)', (k,v))
finally:
    con.close()
PY
}

# Bring CLI panel settings back in line and bind only localhost.
apply_panel(){
  run "$CLI" setting -port "$PANEL_PORT" -webBasePath "$PANEL_PATH" -listenIP 127.0.0.1
}
# Check the LOCAL address only (column 4). The PEER column of `ss`
# commonly reads 0.0.0.0:* even for a listener bound to 127.0.0.1.
verify_local(){
  local port=$1 local_addr seen=0
  while IFS= read -r local_addr; do
    [[ -n "$local_addr" ]] || continue
    case "$local_addr" in
      "127.0.0.1:$port") seen=1 ;;
      *) printf 'Unsafe listen address on port %s: %s\n' "$port" "$local_addr" >> "$LOG"; return 1 ;;
    esac
  done < <(ss -H -ltn "sport = :$port" | awk '{print $4}')
  (( seen == 1 ))
}
wait_local_stack(){
  local i
  for ((i=0; i<15; i++)); do
    if verify_local "$PANEL_PORT" && verify_local "$SUB_PORT" && verify_panel_http; then
      return 0
    fi
    sleep 1
  done
  return 1
}
verify_panel_http(){
  curl -fsS --max-time 12 -o /dev/null "http://127.0.0.1:$PANEL_PORT/$PANEL_PATH/" 2>>"$LOG"
}
verify_remote(){
  # Probe localhost with DNS-independent SNI. In direct mode the root is not a
  # web site and may legitimately return 404, so check the panel path instead.
  local uri="https://$DOMAIN/"
  if [[ "${TLS_MODE:-proxy}" == direct && "${PROXY_INSTALLED:-1}" == 0 ]]; then
    uri="https://$DOMAIN/$PANEL_PATH/"
  fi
  curl -fsS --max-time 15 --resolve "$DOMAIN:443:127.0.0.1" -o /dev/null "$uri" 2>>"$LOG"
}

update_proxy_safe(){
  local config backup; config=$(proxy_conf); backup="$BASE/backup-proxy.$(date +%Y%m%d-%H%M%S-%N).conf"
  cp -a "$config" "$backup"
  if [[ "$PROXY" == caddy ]]; then write_caddy; else write_nginx full; fi
  if ! validate_proxy; then
    cp -a "$backup" "$config"
    warn "Новый конфиг не прошёл проверку, восстановлен $backup"
    return 1
  fi
  if ! reload_proxy; then
    cp -a "$backup" "$config"
    reload_proxy || true
    return 1
  fi
  return 0
}


rotate_credentials(){
  local before_db before_state
  before_db="$BASE/backup-db-creds.$(date +%Y%m%d-%H%M%S-%N).db"
  before_state="$BASE/backup-state-creds.$(date +%Y%m%d-%H%M%S-%N).env"
  cp -a "$STATE" "$before_state"
  run systemctl stop x-ui
  python3 - "$DB" "$before_db" <<'PYBACK' >>"$LOG" 2>&1
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as src, sqlite3.connect(sys.argv[2]) as dst:
    src.backup(dst)
PYBACK
  if run "$CLI" setting -username "$PANEL_USER" -password "$PANEL_PASS" &&
     run systemctl start x-ui && verify_local "$PANEL_PORT" && verify_panel_http; then
     save_state; write_info
     note 'Новые учётные данные применены.'
  else
     warn 'Проверка после смены пароля не прошла. Возвращаю прежние учётные данные.'
     run systemctl stop x-ui || true
     cp -a "$before_db" "$DB"
     cp -a "$before_state" "$STATE"
     load_state
     run systemctl start x-ui || true
     return 1
  fi
}

# For panel/sub changes, stop service and back up DB. Roll back if validation fails.
transaction_change(){
  local dbbackup previous_state previous_proxy
  dbbackup="$BASE/backup-db.$(date +%Y%m%d-%H%M%S-%N).db"
  previous_state="$BASE/backup-state.$(date +%Y%m%d-%H%M%S-%N).env"
  previous_proxy="$BASE/backup-config.$(date +%Y%m%d-%H%M%S-%N).conf"
  cp -a "$STATE" "$previous_state"
  cp -a "$(proxy_conf)" "$previous_proxy"
  run systemctl stop x-ui
  # SQLite backup including WAL state after process shutdown
  python3 - "$DB" "$dbbackup" <<'PY' >>"$LOG" 2>&1
import sqlite3,sys
src=sqlite3.connect(sys.argv[1]); dst=sqlite3.connect(sys.argv[2]); src.backup(dst); dst.close(); src.close()
PY
  if ! ( apply_panel && set_subscriptions >>"$LOG" 2>&1 && update_proxy_safe ); then
    warn 'Ошибка обновления, возвращаю предыдущую конфигурацию.'
    cp -a "$dbbackup" "$DB"
    cp -a "$previous_proxy" "$(proxy_conf)"
    cp -a "$previous_state" "$STATE"
    load_state
    reload_proxy || true
    run systemctl start x-ui || true
    return 1
  fi
  if ! run systemctl start x-ui || ! verify_local "$PANEL_PORT" || ! verify_local "$SUB_PORT" || ! verify_panel_http; then
    warn '3x-ui не прошла проверку. Выполняю откат.'
    run systemctl stop x-ui || true
    cp -a "$dbbackup" "$DB"
    cp -a "$previous_proxy" "$(proxy_conf)"
    cp -a "$previous_state" "$STATE"
    load_state
    reload_proxy || true
    run systemctl start x-ui || true
    return 1
  fi
  save_state; write_info
  note 'Изменения применены.'
}

setup_renew_timer(){
  # Dedicated paths require a dedicated timer; the distro's default certbot timer
  # cannot see this custom --config-dir.
  cat > /etc/systemd/system/3x-ui-reverse-cert-renew.service <<EOF
[Unit]
Description=Renew 3x-ui_reverse Nginx certificates
[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --non-interactive --config-dir $(certdir) --work-dir $BASE/certbot-work --logs-dir $BASE/certbot-logs --deploy-hook "/usr/bin/systemctl reload nginx"
EOF
  cat > /etc/systemd/system/3x-ui-reverse-cert-renew.timer <<'EOF'
[Unit]
Description=Daily certificate renewal check for 3x-ui_reverse
[Timer]
OnCalendar=*-*-* 04:17:00
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
  run systemctl daemon-reload
  run systemctl enable --now 3x-ui-reverse-cert-renew.timer
}


# The upstream installer briefly starts x-ui. Prevent even this initial start
# from exposing panel/subscription ports on 0.0.0.0. x-ui.service's own package
# drop-in is 10-xui-sandbox; this 20- guard is preserved by upstream upgrades.
prepare_bootstrap_guard(){
  cat > "$BASE/bootstrap-guard.env" <<EOF
DOMAIN=$DOMAIN
SUB_PORT=$SUB_PORT
SUB_PATH=$SUB_PATH
JSON_PATH=$JSON_PATH
CLASH_PATH=$CLASH_PATH
EOF
  chmod 600 "$BASE/bootstrap-guard.env"
  cat > "$BASE/bootstrap-guard.py" <<'PYGUARD'
#!/usr/bin/env python3
import sqlite3
from pathlib import Path
base=Path('/opt/3x-ui_reverse')
options=dict(line.strip().split('=',1) for line in (base/'bootstrap-guard.env').read_text().splitlines())
domain, port = options['DOMAIN'], options['SUB_PORT']
sub, js, clash = options['SUB_PATH'], options['JSON_PATH'], options['CLASH_PATH']
updates={
 'webListen':'127.0.0.1','webCertFile':'','webKeyFile':'',
 'subEnable':'true','subListen':'127.0.0.1','subPort':port,
 'subPath':'/'+sub+'/','subDomain':domain,'subCertFile':'','subKeyFile':'',
 'subURI':f'https://{domain}/{sub}/',
 'subJsonEnable':'true','subJsonPath':'/'+js+'/',
 'subJsonURI':f'https://{domain}/{js}/',
 'subClashEnable':'true','subClashPath':'/'+clash+'/',
 'subClashURI':f'https://{domain}/{clash}/',
}
with sqlite3.connect('/etc/x-ui/x-ui.db',timeout=15) as db:
    cols={r[1] for r in db.execute('PRAGMA table_info(settings)')}
    if not {'key','value'} <= cols:
        raise SystemExit('3x-ui settings schema unexpected; refusing unsafe first launch')
    with db:
        for key, val in updates.items():
            old=db.execute('SELECT rowid FROM settings WHERE key=?',(key,)).fetchone()
            if old:
                db.execute('UPDATE settings SET value=? WHERE rowid=?',(val,old[0]))
            else:
                db.execute('INSERT INTO settings (key,value) VALUES (?,?)',(key,val))
PYGUARD
  chmod 700 "$BASE/bootstrap-guard.py"
  mkdir -p /etc/systemd/system/x-ui.service.d
  cat > /etc/systemd/system/x-ui.service.d/20-reverse-localhost.conf <<EOF
[Service]
ExecStartPre=/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1
ExecStartPre=/usr/bin/python3 $BASE/bootstrap-guard.py
EOF
  chmod 644 /etc/systemd/system/x-ui.service.d/20-reverse-localhost.conf
}
finalize_bootstrap_guard(){
  # Keep a permanent localhost guarantee, but stop applying bootstrap
  # subscription defaults at every panel restart (manager will update them).
  cat > /etc/systemd/system/x-ui.service.d/20-reverse-localhost.conf <<'EOF'
[Service]
ExecStartPre=/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1
EOF
  rm -f "$BASE/bootstrap-guard.py" "$BASE/bootstrap-guard.env"
  run systemctl daemon-reload
}

# Continue the interrupted v1 deployment WITHOUT reinstalling 3x-ui.
repair_incomplete(){
  [[ $EUID -eq 0 ]] || die 'Запусти от root.'
  [[ ! -e "$STATE" ]] || die 'Установка уже завершена. Запусти: sudo 3x-ui_reverse'
  [[ -x "$CLI" && -f "$DB" ]] || die 'Не найдены существующие бинарник или SQLite-база 3x-ui.'
  local boot="$BASE/bootstrap-guard.env" original=/etc/x-ui/install-result.env
  for f in "$boot" "$original"; do
    [[ -f "$f" && ! -L "$f" ]] || die "Нет исходных параметров для восстановления: $f"
    [[ $(stat -c %u "$f") == 0 && $(stat -c %a "$f") == 600 ]] || die "Небезопасные права: $f"
  done
  # Both files are root-owned mode 0600 and were generated by the installers.
  source "$boot"
  source "$original"
  PANEL_PORT=$XUI_PANEL_PORT
  PANEL_PATH=$XUI_WEB_BASE_PATH
  PANEL_USER=$XUI_USERNAME
  PANEL_PASS=$XUI_PASSWORD
  valid_domain "$DOMAIN" || die 'Неверный домен в настройках.'
  valid_port "$PANEL_PORT" && valid_port "$SUB_PORT" && [[ "$PANEL_PORT" != "$SUB_PORT" ]] || die 'Неверные порты.'
  for p in "$PANEL_PATH" "$SUB_PATH" "$JSON_PATH" "$CLASH_PATH"; do valid_path "$p" || die 'Неверный путь.'; done
  if [[ -f "$BASE/Caddyfile" && -L /etc/caddy/Caddyfile && $(readlink -f /etc/caddy/Caddyfile) == "$BASE/Caddyfile" ]]; then
    PROXY=caddy
    grep -Fxq "$DOMAIN {" "$BASE/Caddyfile" || die 'Домен Caddy не совпадает с параметрами установки.'
  elif [[ -f /etc/nginx/sites-available/3x-ui_reverse.conf && -L /etc/nginx/sites-enabled/3x-ui_reverse.conf ]]; then
    PROXY=nginx
    grep -Fq "server_name $DOMAIN;" /etc/nginx/sites-available/3x-ui_reverse.conf || die 'Домен Nginx не совпадает.'
  else
    die 'Не обнаружена конфигурация прокси из незавершённой установки.'
  fi
  touch "$LOG"; chmod 600 "$LOG"
  ui_start "Восстановление • $DOMAIN • $PROXY" \
    'Проверяем сохранённые параметры' \
    'Сохраняем резервную копию базы SQLite' \
    'Задаём привязку 127.0.0.1 и пути подписок' \
    'Обновляем учётные данные и проверяем порты' \
    'Настраиваем прокси и сохраняем параметры'
  msg "Проверяем сохранённые параметры"
  step 5 'Проверяем сохранённые параметры'
  msg 'Сохраняем резервную копию базы SQLite'
  local backup="$BASE/backup-db-repair.$(date +%Y%m%d-%H%M%S-%N).db"
  run systemctl stop x-ui || die 'Не удалось остановить x-ui.'
  python3 - "$DB" "$backup" <<'PYBACK' >>"$LOG" 2>&1
import sqlite3, sys
src=sqlite3.connect(sys.argv[1]); dst=sqlite3.connect(sys.argv[2]); src.backup(dst); dst.close(); src.close()
PYBACK
  chmod 600 "$backup"
  step 28 'Резервная копия готова'
  msg 'Задаём привязку 127.0.0.1 и пути подписок'
  apply_panel || die 'Ошибка настройки панели. x-ui остановлен.'
  set_subscriptions >>"$LOG" 2>&1 || die 'Ошибка настройки подписок. x-ui остановлен.'
  step 55 'Панель и подписки настроены'
  msg 'Обновляем учётные данные и проверяем порты'
  # Credentials were present in the user-shared install.log. Rotate login/password
  # on recovery. An API token printed by upstream must be revoked in 3x-ui UI.
  PANEL_USER="u$(rand 12)"
  PANEL_PASS=$(rand 28)
  run "$CLI" setting -username "$PANEL_USER" -password "$PANEL_PASS" || die 'Ошибка смены учётных данных.'
  finalize_bootstrap_guard
  run systemctl start x-ui || die 'Не удалось запустить x-ui.'
  if ! wait_local_stack; then
    run ss -ltn || true
    run systemctl status --no-pager x-ui || true
    run systemctl stop x-ui || true
    die 'Проверка внутреннего доступа не пройдена, x-ui остановлен. См. install.log.'
  fi
  step 83 'Внутренние порты безопасны'
  msg 'Настраиваем прокси и сохраняем параметры'
  validate_proxy || die 'Конфигурация прокси не прошла проверку.'
  reload_proxy || die 'Ошибка перезагрузки прокси.'
  PANEL_INSTALLED=1; PROXY_INSTALLED=1; TLS_MODE=proxy
  save_state
  write_info
  install_self || warn "Не удалось установить команду $SELF (запусти скрипт из файла или проверь доступ к GitHub)."
  step 100 'Восстановление завершено'
  ui_stop
  if ! verify_remote; then
    warn 'Локальная HTTPS-проверка не прошла; проверь выпуск сертификата и DNS.'
  fi
  warn 'Важно: зайди в настройки 3x-ui и перевыпусти/отзови API-токен из прежнего install.log.'
  warn 'Inbound-ы Reality/XHTTP/MTProto можно создать в меню «Inbound-ы».'
  if [[ $TUI_OK == 1 ]]; then
    tui_show 'Восстановление завершено' show_info_color
    flush_notes 'Обрати внимание'
  else
    show_info_color
  fi
}

install_fresh(){
  first_run_prepare
  local ch want_inbounds=0 want_bbr=0 inbound_text bbr_text
  # Network tuning goes first: it is independent of everything else.
  if bbr_active; then
    bbr_text='Сеть:        BBR + CAKE (уже включены)'
  else
    if TUI_LOGO=1 tui_yesno 'Ускорение сети' "$(bbr_question_text)" 'Да, включить' 'Нет, оставить как есть' yes; then
      want_bbr=1; bbr_text='Сеть:        включить TCP BBR + CAKE'
    else
      bbr_text="Сеть:        без изменений ($(bbr_label))"
    fi
  fi
  ch=$(TUI_LOGO=1 tui_radiolist 'Установка на чистый VPS' \
        'Веб-сервер обслуживает сайт-заглушку, выпускает HTTPS и скрывает за собой панель и подписки.' \
        caddy 'Caddy — автоматический HTTPS' ON \
        nginx 'Nginx + Certbot' OFF) || return 1
  case "$ch" in caddy|nginx) PROXY=$ch;; *) return 1;; esac
  local entered=''
  while :; do
    entered=$(TUI_LOGO=1 tui_input 'Домен' 'Домен, A-запись которого указывает на этот VPS (например, panel.example.com):' "$entered") || return 1
    entered=${entered,,}; entered=${entered%.}
    valid_domain "$entered" && break
    tui_msg 'Неверный домен' 'Введи корректное DNS-имя: не IP-адрес, не URL и без порта.'
  done
  DOMAIN=$entered
  dns_check_screen || return 1
  # The certificate path is only known after the proxy has started.
  PROXY_INSTALLED=1; TLS_MODE=proxy
  if TUI_LOGO=1 tui_yesno 'Inbound-ы' "Создать inbound-ы для подключения клиентов сразу после установки?

Список и настройки выберешь на следующем шаге. Их можно добавить и позже — в меню «Inbound-ы»." \
       'Да, выбрать inbound-ы' 'Нет, только панель' yes; then
    select_inbounds fresh && want_inbounds=1
  fi
  if ((want_inbounds)); then
    inbound_text="Inbound-ы:   $(selected_labels) (+ пользователь user1)"
  else
    inbound_text='Inbound-ы:   не создавать (можно позже в меню «Inbound-ы»)'
  fi
  TUI_LOGO=1 tui_yesno 'Подтверждение' "Домен:       $DOMAIN
Веб-сервер:  $PROXY
$inbound_text
$bbr_text

Будут установлены веб-сервер с сайтом-заглушкой и HTTPS и панель 3x-ui (только на 127.0.0.1).
После установки параметры сохранятся в текстовый файл и в PDF.
Требования: TCP 80/443 доступны извне." 'Установить' 'Отмена' yes || return 1
  install -d -m 755 "$BASE"
  preinstall_commit
  local proxy_install_stage proxy_https_stage inbounds_ok=0 inbound_stage='Inbound-ы не создаются'
  ((want_inbounds)) && inbound_stage="Создаём inbound-ы: $(selected_labels)"
  if [[ $PROXY == caddy ]]; then
    proxy_install_stage='Устанавливаем Caddy'
    proxy_https_stage='Настраиваем Caddy и HTTPS'
  else
    proxy_install_stage='Устанавливаем Nginx и Certbot'
    proxy_https_stage='Настраиваем Nginx и сертификат HTTPS'
  fi
  local -a bbr_stage=()
  ((want_bbr)) && bbr_stage=('Включаем TCP BBR + CAKE')
  ui_start "Установка • $DOMAIN • $PROXY" \
    'Проверяем окружение' \
    "${bbr_stage[@]}" \
    'Подготавливаем компоненты' \
    "$proxy_install_stage" \
    'Создаём страницу-заглушку' \
    "$proxy_https_stage" \
    'Устанавливаем 3x-ui' \
    'Привязываем веб-панель и подписки к 127.0.0.1' \
    "$inbound_stage" \
    'Записываем параметры входа и PDF' \
    'Проверяем доступность HTTPS'
  msg 'Проверяем окружение'
  step 1 'Проверяем окружение'
  if ((want_bbr)); then
    msg 'Включаем TCP BBR + CAKE'
    bbr_enable || :
  fi
  msg 'Подготавливаем компоненты'
  run apt-get update
  step 12 'Обновили списки пакетов'
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl openssl python3 iproute2 coreutils
  # For the PDF with the parameters; not fatal.
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y python3-reportlab fonts-dejavu-core ||
    warn 'Не удалось установить python3-reportlab — PDF не будет создан (можно позже: «PDF с параметрами»).'
  step 18 'Установили базовые пакеты'
  if [[ "$PROXY" == caddy ]]; then
    msg 'Устанавливаем Caddy'
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y caddy
  else
    msg 'Устанавливаем Nginx и Certbot'
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y nginx certbot
  fi
  step 33 'Прокси установлен'
  PANEL_PORT=$(newport) || die 'Не удалось подобрать порт панели.'
  SUB_PORT=$(newport) || die 'Не удалось подобрать порт подписок.'
  PANEL_PATH="panel$(rand 18)"; SUB_PATH="sub$(rand 19)"
  JSON_PATH="json$(rand 19)"; CLASH_PATH="clash$(rand 19)"
  PANEL_USER="u$(rand 12)"; PANEL_PASS=$(rand 28)
  msg 'Создаём страницу-заглушку'
  site_html
  step 43 'Сайт создан'
  msg "$proxy_https_stage"
  mkdir -p "$(certdir)"
  chmod 755 "$BASE/sertificates"
  if [[ "$PROXY" == caddy ]]; then
    # Stock package places a demo Caddyfile; back it up before replacing.
    [[ -f /etc/caddy/Caddyfile && ! -L /etc/caddy/Caddyfile ]] && cp -a /etc/caddy/Caddyfile "$BASE/Caddyfile.package-default"
    write_caddy
    ln -sfn "$BASE/Caddyfile" /etc/caddy/Caddyfile
    chown -R caddy:caddy "$(certdir)"
    chmod 750 "$(certdir)"
    validate_proxy || die 'Ошибка конфигурации Caddy.'
    run systemctl enable --now caddy
    run systemctl restart caddy
  else
    # Only on a fresh nginx install: disable the packaged default site.
    if [[ -L /etc/nginx/sites-enabled/default ]]; then rm -f /etc/nginx/sites-enabled/default; fi
    write_nginx bootstrap
    ln -sfn /etc/nginx/sites-available/3x-ui_reverse.conf /etc/nginx/sites-enabled/3x-ui_reverse.conf
    validate_proxy || die 'Ошибка Nginx (HTTP challenge).'
    run systemctl enable --now nginx
    run systemctl restart nginx
    install -d -m 755 "$SITE/.well-known/acme-challenge"
    run certbot certonly --non-interactive --agree-tos --register-unsafely-without-email \
       --webroot -w "$SITE" -d "$DOMAIN" --cert-name "$DOMAIN" \
       --config-dir "$(certdir)" --work-dir "$BASE/certbot-work" --logs-dir "$BASE/certbot-logs" \
       || die 'Certbot не получил сертификат. Проверь A-запись и доступность порта 80.'
    write_nginx full
    validate_proxy || die 'Ошибка Nginx (HTTPS).'
    reload_proxy || die 'Не удалось перезагрузить Nginx.'
    setup_renew_timer
  fi
  step 60 'Прокси и HTTPS подготовлены'
  msg 'Устанавливаем 3x-ui'
  local installer="$BASE/3x-ui-upstream-install.sh"
  run curl -fsSL --retry 3 -o "$installer" "$XUI_INSTALL_URL" || die 'Не удалось скачать официальный установщик 3x-ui.'
  chmod 700 "$installer"
  # Install the guard before upstream creates/starts its systemd service.
  # It forces BOTH web and subscription listeners to 127.0.0.1 even on first start.
  prepare_bootstrap_guard
  if ! XUI_NONINTERACTIVE=1 XUI_SSL_MODE=none \
      XUI_DB_TYPE=sqlite XUI_PANEL_PORT="$PANEL_PORT" XUI_WEB_BASE_PATH="$PANEL_PATH" \
      XUI_USERNAME="$PANEL_USER" XUI_PASSWORD="$PANEL_PASS" \
      bash "$installer" >>"$LOG" 2>&1; then
    die 'Официальный установщик 3x-ui завершился с ошибкой.'
  fi
  [[ -x "$CLI" && -f "$DB" ]] || die 'Не найден x-ui или база SQLite после установки.'
  PANEL_INSTALLED=1; PROXY_INSTALLED=1; TLS_MODE=proxy
  # Upstream starts the service during installation. Our systemd pre-start
  # guard has already set localhost-only listeners. Stop before changing DB.
  run systemctl stop x-ui || die 'Не удалось остановить x-ui для настройки.'
  step 75 'Панель 3x-ui установлена'
  msg 'Привязываем веб-панель и подписки к 127.0.0.1'
  apply_panel || die 'Не удалось установить параметры веб-панели.'
  set_subscriptions >>"$LOG" 2>&1 || die 'Не удалось установить параметры подписок.'
  finalize_bootstrap_guard
  run systemctl start x-ui || die 'Не удалось запустить x-ui.'
  if ! wait_local_stack; then
    run systemctl stop x-ui || true
    die 'Локальные порты панели/подписок не прошли проверку после настройки. x-ui остановлен.'
  fi
  step 85 'Локальные сервисы проверены'
  msg "$inbound_stage"
  # Not fatal: the panel is already installed and inbounds can be created later.
  if ((want_inbounds)); then
    if setup_inbounds; then
      inbounds_ok=1
      step 93 'Inbound-ы и пользователь user1 созданы'
    else
      warn 'Inbound-ы не созданы. Создай их в меню «Inbound-ы».'
      step 93 'Inbound-ы пропущены'
    fi
  else
    write_helper; write_helper_env
    if ensure_api_token; then
      helper enable-access-log >>"$LOG" 2>&1 || :
      setup_activity_timer || :
    fi
    step 93 'Inbound-ы не создавались'
  fi
  msg 'Записываем параметры входа и PDF'
  save_state; write_info
  write_pdf || warn "PDF с параметрами не создан (подробности в $LOG). Повтори в меню «PDF с параметрами»."
  install_self || warn "Не удалось установить команду $SELF (запусти скрипт из файла или проверь доступ к GitHub)."
  step 98 'Создали команду 3x-ui_reverse'
  msg 'Проверяем доступность HTTPS'
  if verify_remote; then
    step 100 'HTTPS и сайт доступны'
  else
    step 100 'Установка завершена'
    ui_stop failed
    warn 'HTTPS-проверка по localhost не прошла. Проверь DNS, TLS и логи прокси.'
  fi
  ui_stop
  if ((inbounds_ok)); then
    # shellcheck disable=SC2086
    warn "Открой во внешнем файрволе провайдера порты inbound-ов: $(helper ports $CREATED_IDS 2>/dev/null || echo '?')."
  fi
  tui_show 'Установка завершена' install_summary
  flush_notes 'Обрати внимание'
  return 0
}
install_summary(){
  show_info_color
  if helper sub-id user1 >/dev/null 2>&1; then
    printf '  ● ПОЛЬЗОВАТЕЛЬ user1\n'
    print_user_links user1 || :
  fi
  if [[ -f "$PDF_FILE" ]]; then
    printf '\n%s  ● PDF С ПАРАМЕТРАМИ%s\n' "$C_BLUE" "$C_RESET"
    color_value 'Файл' "$PDF_FILE" "$C_GREEN"
    color_value 'Скачать' "$(pdf_download_hint)" "$C_YELLOW"
    copy_item 'команда scp' "$(pdf_download_hint)"
  fi
}


# Colorized CLI overview. panel.txt stays a plain-text machine-readable summary.
color_value(){
  # Bash character count (not UTF-8 byte count) keeps Russian labels aligned,
  # even on minimal VPS configured with LANG=C.
  local LC_CTYPE=C.UTF-8
  local name=$1 value=$2 color=${3:-$C_WHITE} pad
  pad=$((26-${#name}))
  ((pad >= 1)) || pad=1
  printf '  %s%s%s%*s%s%s%s\n' "$C_DIM" "$name" "$C_RESET" "$pad" '' "$color" "$value" "$C_RESET"
}
show_info_color(){
  local panel_url certpath ntoken
  if [[ "${PROXY_INSTALLED:-1}" == 1 ]]; then
    panel_url="https://$DOMAIN/$PANEL_PATH/"
    certpath=$(certdir)
  elif [[ "${TLS_MODE:-none}" == direct && "${PANEL_INSTALLED:-1}" == 1 ]]; then
    panel_url="https://$DOMAIN/$PANEL_PATH/"
    certpath="/root/cert/$DOMAIN"
  else
    panel_url='Недоступна'
    certpath='Нет'
  fi
  printf '\n%s%s  ◆ 3x-ui_reverse — параметры%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
  printf '%s  ───────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
  printf '\n%s  ● САЙТ И HTTPS%s\n' "$C_BLUE" "$C_RESET"
  color_value 'Домен' "https://$DOMAIN" "$C_GREEN"
  color_value 'Прокси' "$PROXY ($([[ ${PROXY_INSTALLED:-1} == 1 ]] && echo установлен || echo удалён))" "$C_WHITE"
  color_value 'TLS' "${TLS_MODE:-proxy}" "$C_WHITE"
  color_value 'TLS-сертификаты' "$certpath" "$C_DIM"
  if [[ "${PROXY_INSTALLED:-1}" == 1 ]]; then color_value 'Конфигурация' "$(proxy_conf)" "$C_DIM"; fi
  printf '\n%s  ● ПАНЕЛЬ 3x-ui%s\n' "$C_BLUE" "$C_RESET"
  color_value 'Статус' "$([[ ${PANEL_INSTALLED:-1} == 1 ]] && echo Установлена || echo Удалена)" "$C_WHITE"
  if [[ "${PANEL_INSTALLED:-1}" == 1 ]]; then
    color_value 'Адрес панели' "$panel_url" "$C_GREEN"
    color_value 'Логин' "$PANEL_USER" "$C_YELLOW"
    color_value 'Пароль' "$PANEL_PASS" "$C_YELLOW"
    color_value 'Порт' "$PANEL_PORT" "$C_DIM"
    if ntoken=$(node_api_token 2>>"$LOG"); then
      if (( 30 + ${#ntoken} > $(ui_width) )); then      # narrow terminal: own line
        color_value 'API-токен узла' ''
        printf '    %s%s%s\n' "$C_YELLOW" "$ntoken" "$C_RESET"
      else
        color_value 'API-токен узла' "$ntoken" "$C_YELLOW"
      fi
      color_value '' 'для подключения этой панели к мастеру как узла' "$C_DIM"
    else
      color_value 'API-токен узла' 'недоступен (служба x-ui остановлена?)' "$C_DIM"
    fi
    copy_item 'адрес панели' "$panel_url"
    copy_item 'логин' "$PANEL_USER"
    copy_item 'пароль' "$PANEL_PASS"
    copy_item 'API-токен узла' "${ntoken:-}"
    printf '\n%s  ● ПОДПИСКИ%s\n' "$C_BLUE" "$C_RESET"
    color_value 'Обычная / VLESS' "/$SUB_PATH/" "$C_YELLOW"
    color_value 'JSON' "/$JSON_PATH/" "$C_YELLOW"
    color_value 'Mihomo / Clash' "/$CLASH_PATH/" "$C_YELLOW"
    if [[ "${PROXY_INSTALLED:-1}" == 1 ]]; then
      color_value 'Порт подписок' "$SUB_PORT (только 127.0.0.1, снаружи — 443)" "$C_DIM"
    else
      color_value 'Порт подписок' "$SUB_PORT" "$C_DIM"
    fi
    copy_item 'путь подписки' "/$SUB_PATH/"
    copy_item 'путь JSON' "/$JSON_PATH/"
    copy_item 'путь Clash' "/$CLASH_PATH/"
  fi
  printf '\n%s  ● ФАЙЛЫ%s\n' "$C_BLUE" "$C_RESET"
  color_value 'Параметры (chmod 600)' "$INFO" "$C_DIM"
  color_value 'Лог' "$LOG" "$C_DIM"
  printf '\n%s  ⚠ Учётные данные не передавай посторонним.%s\n' "$C_YELLOW" "$C_RESET"
  if [[ $UI_MODE == tui ]]; then
    printf '%s  Клик по значению (или Tab → Enter) копирует его в буфер обмена.\n  Если не вставилось — выдели текст мышью с зажатым Shift.%s\n' "$C_DIM" "$C_RESET"
  fi
  printf '\n'
}

status_line(){
  local LC_CTYPE=C.UTF-8
  local label=$1 value=$2 pad
  pad=$((16-${#label})); ((pad >= 1)) || pad=1
  printf '  %s%*s%s\n' "$label" "$pad" '' "$value"
}
service_state(){
  if systemctl is-active --quiet "$1"; then printf '● работает'; else printf '✗ не работает'; fi
}
show_status_color(){
  printf '  ◆ Состояние компонентов\n\n'
  if [[ "${PANEL_INSTALLED:-1}" == 1 ]]; then
    status_line '3x-ui' "$(service_state x-ui)"
    if [[ "${TLS_MODE:-proxy}" == proxy ]]; then
      if verify_local "$PANEL_PORT" && verify_local "$SUB_PORT" && verify_panel_http; then
        status_line 'Безопасность' '✓ панель и подписки только на 127.0.0.1'
      else
        status_line 'Безопасность' '✗ проверка портов не пройдена'
      fi
    else
      status_line 'Режим HTTPS' "● панель на 443; подписки :$SUB_PORT"
    fi
    local rows port proto remark flag
    if rows=$( { ensure_api_token 1 && helper ports-all; } 2>>"$LOG") && [[ -n "$rows" ]]; then
      while read -r port proto remark; do
        [[ -n "$port" ]] || continue
        flag=-ltn; [[ "$proto" == udp ]] && flag=-lun
        if ss -H "$flag" "sport = :$port" | grep -q .; then
          status_line 'Inbound' "✓ $port/$proto  $remark"
        else
          status_line 'Inbound' "✗ $port/$proto не слушается  $remark"
        fi
      done <<< "$rows"
    else
      status_line 'Inbound-ы' '— API 3x-ui недоступен или включённых inbound-ов нет'
    fi
    if systemctl is-active --quiet "$ACTIVITY_UNIT.timer"; then
      status_line 'Активность' '● учёт включён (раз в минуту)'
    else
      status_line 'Активность' '○ учёт выключен'
    fi
  else
    status_line '3x-ui' '○ удалена'
  fi
  if [[ "${PROXY_INSTALLED:-1}" == 1 ]]; then
    status_line "$PROXY" "$(service_state "$PROXY")"
  else
    status_line "$PROXY" '○ удалён'
  fi
  if bbr_active; then status_line 'Сеть' '● TCP BBR + CAKE'
  else status_line 'Сеть' "○ $(bbr_label) (BBR + CAKE — в «Обслуживание»)"; fi
  if [[ "${PROXY_INSTALLED:-1}" == 1 || "${TLS_MODE:-none}" == direct ]]; then
    if verify_remote; then status_line 'Домен' "✓ https://$DOMAIN отвечает"
    else status_line 'Домен' "⚠ https://$DOMAIN не отвечает"; fi
  fi
}

# The scripts in this project install a fresh proxy; preserve any subsequently
# added virtual hosts instead of unconditionally purging system packages.
check_proxy_owned_for_purge(){
  local candidate
  candidate=$(mktemp "$BASE/check-proxy.XXXXXXXX") || return 1
  case "$PROXY" in
    caddy)
      if [[ ! -L /etc/caddy/Caddyfile ]] || [[ $(readlink -f /etc/caddy/Caddyfile) != "$BASE/Caddyfile" ]]; then
        warn 'Caddyfile больше не управляется 3x-ui_reverse.'
        rm -f -- "$candidate"
        return 1
      fi
      write_caddy "$candidate"
      if ! cmp -s "$candidate" "$BASE/Caddyfile"; then
        warn 'Конфигурация Caddy изменена вручную. Чтобы не удалить чужие сайты, удаление остановлено.'
        rm -f -- "$candidate"
        return 1
      fi
      ;;
    nginx)
      if [[ ! -L /etc/nginx/sites-enabled/3x-ui_reverse.conf ]] ||
         [[ $(readlink -f /etc/nginx/sites-enabled/3x-ui_reverse.conf) != /etc/nginx/sites-available/3x-ui_reverse.conf ]]; then
        warn 'Nginx больше не управляется установщиком.'
        rm -f -- "$candidate"
        return 1
      fi
      write_nginx full "$candidate"
      if ! cmp -s "$candidate" /etc/nginx/sites-available/3x-ui_reverse.conf; then
        warn 'Конфигурация Nginx изменена вручную. Полное удаление остановлено.'
        rm -f -- "$candidate"
        return 1
      fi
      if find /etc/nginx/sites-enabled -mindepth 1 -maxdepth 1 ! -name 3x-ui_reverse.conf -print -quit 2>/dev/null | grep -q . \
         || find /etc/nginx/conf.d -maxdepth 1 -type f -name '*.conf' -print -quit 2>/dev/null | grep -q .; then
        warn 'Nginx обслуживает другие сайты. Полное удаление остановлено.'
        rm -f -- "$candidate"
        return 1
      fi
      ;;
    *) rm -f -- "$candidate"; die "Неподдерживаемый прокси: $PROXY" ;;
  esac
  rm -f -- "$candidate"
  return 0
}

remove_manager_command(){
  [[ $EUID -eq 0 ]] || die 'Запусти от root.'
  tui_init || die 'Требуется интерактивный терминал.'
  tui_confirm_word 'Удалить команду' "Будет удалена ТОЛЬКО команда $SELF.
3x-ui, прокси, сертификаты, подписки и данные останутся без изменений." 'УДАЛИТЬ' || return 1
  [[ ! -L "$SELF" ]] || die 'Управляющий скрипт — неожиданная символьная ссылка. Удаление остановлено.'
  rm -f -- "$SELF"
  tui_msg 'Команда удалена' 'Команда 3x-ui_reverse удалена. Сервисы продолжают работать.

Вернуть её: sudo bash 3x-ui_reverse_install.sh --restore-command'
}
restore_manager_command(){
  [[ $EUID -eq 0 ]] || die 'Нужны права root.'
  load_state
  [[ ! -L "$SELF" ]] || die 'Неожиданная ссылка по пути команды; сначала проверь вручную.'
  install_self || die "Не удалось установить $SELF: запусти скрипт из файла (sudo bash 3x-ui_reverse_install.sh --restore-command)."
  write_helper
  printf '%s✓ Управляющая команда восстановлена: %s%s\n' "$C_GREEN" "$SELF" "$C_RESET"
}

uninstall_all(){
  [[ $EUID -eq 0 ]] || die 'Нужны права root.'
  tui_init || die 'Для полного удаления нужен интерактивный терминал.'
  load_state
  if [[ "${PROXY_INSTALLED:-1}" == 1 ]]; then
    if ! check_proxy_owned_for_purge; then
      warn 'Полное удаление остановлено: сначала проверь сторонние конфигурации прокси.'
      return 1
    fi
  fi
  tui_confirm_word 'Полное удаление' "Будут безвозвратно удалены:
 • 3x-ui, Xray, все inbound-ы, пользователи, группы, база SQLite и журналы 3x-ui
 • веб-сервер $PROXY, его настройки, сайт-заглушка и TLS-сертификаты
 • каталог $BASE и команда $SELF
 • настройки 3x-ui для Fail2ban (общие правила Fail2ban сохраняются)

Сделай резервную копию самостоятельно, если данные ещё понадобятся." 'yes' || return 0
  # Fail2ban остаётся установленным: он может использоваться другими сервисами.

  ui_start "Удаление • $DOMAIN • $PROXY" \
    'Останавливаем службы' \
    'Удаляем 3x-ui и системные настройки' \
    "Удаляем $PROXY и его конфигурацию" \
    'Удаляем сертификаты, сайт, параметры и команду'
  msg 'Останавливаем службы'
  run systemctl disable --now x-ui || true
  if [[ "${PROXY_INSTALLED:-1}" == 1 ]]; then run systemctl disable --now "$PROXY" || true; fi
  run systemctl disable --now 3x-ui-reverse-cert-renew.timer || true
  run systemctl disable --now "$ACTIVITY_UNIT.timer" || true
  step 20 'Службы остановлены'

  msg 'Удаляем 3x-ui и системные настройки'
  rm -f /etc/systemd/system/x-ui.service /usr/bin/x-ui /etc/default/x-ui
  rm -rf -- /etc/systemd/system/x-ui.service.d /etc/x-ui /usr/local/x-ui /var/log/x-ui
  rm -f /etc/fail2ban/filter.d/3x-ipl.conf /etc/fail2ban/action.d/3x-ipl.conf
  rm -f /etc/fail2ban/jail.d/3x-ipl.conf /etc/fail2ban/jail.d/3x-ipl-backend.conf
  if systemctl list-unit-files fail2ban.service --no-legend 2>/dev/null | grep -q fail2ban; then
    run systemctl try-restart fail2ban || true
  fi
  step 52 'Удалили панель и Xray'

  msg "Удаляем $PROXY и его конфигурацию"
  if [[ "${PROXY_INSTALLED:-1}" == 0 ]]; then
    : # Уже удалён отдельно.
  elif [[ $PROXY == caddy ]]; then
    rm -f -- /etc/caddy/Caddyfile
    if ! run env DEBIAN_FRONTEND=noninteractive apt-get purge -y caddy; then
      die 'Не удалось удалить пакет Caddy. Проверь журнал; остальное пока сохранено.'
    fi
  else
    rm -f -- /etc/nginx/sites-enabled/3x-ui_reverse.conf /etc/nginx/sites-available/3x-ui_reverse.conf
    if ! run env DEBIAN_FRONTEND=noninteractive apt-get purge -y nginx nginx-common certbot; then
      die 'Не удалось удалить Nginx/Certbot. Проверь журнал; остальное пока сохранено.'
    fi
  fi
  rm -f /etc/systemd/system/3x-ui-reverse-cert-renew.service /etc/systemd/system/3x-ui-reverse-cert-renew.timer
  rm -f "/etc/systemd/system/$ACTIVITY_UNIT.service" "/etc/systemd/system/$ACTIVITY_UNIT.timer"
  if [[ "${TLS_MODE:-proxy}" == direct ]]; then
    if [[ -x /root/.acme.sh/acme.sh ]]; then
      run /root/.acme.sh/acme.sh --remove -d "$DOMAIN" || :
    fi
    rm -rf -- "/root/cert/$DOMAIN"
  fi
  run systemctl daemon-reload || true
  run systemctl reset-failed || true
  step 85 'Прокси и таймеры удалены'

  msg 'Удаляем сертификаты, сайт, параметры и команду'
  [[ ! -L "$SELF" ]] || die "Путь $SELF стал ссылкой: ручная проверка обязательна."
  rm -f -- "$SELF"
  # BASE contains secrets: all backups, certificates, generated installers and logs.
  rm -rf -- "$BASE"
  PCT=100
  ui_redraw
  ui_stop
  tui_msg 'Удаление завершено' 'Полное удаление завершено.

Пакеты общего назначения (curl, python3 и др.) оставлены для других программ.
Исходный скрипт, загруженный вручную в /root, удаляется отдельно.'
  exit 0
}

# ---- Component lifecycle operations (v5) ----
confirm_yes(){
  # $1 — what is about to happen; the user confirms by typing "yes".
  [[ $TUI_OK == 1 ]] || { warn 'Операция требует интерактивного терминала.'; return 1; }
  tui_confirm_word 'Подтверждение' "${1:-Выполнить операцию?}" yes
}
backup_db(){
  [[ -f "$DB" ]] || return 1
  local target=$1
  install -d -m 700 "$(dirname "$target")"
  python3 - "$DB" "$target" <<'PYBACK' >>"$LOG" 2>&1
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as src, sqlite3.connect(sys.argv[2]) as dest:
    src.backup(dest)
PYBACK
  chmod 600 "$target"
}
set_database_values(){
  # Call with key/value pairs. Do not accept keys/values from untrusted inputs.
  python3 - "$DB" "$@" <<'PYSQL' >>"$LOG" 2>&1
import sqlite3, sys
args=sys.argv[2:]
assert len(args)%2 == 0
with sqlite3.connect(sys.argv[1]) as db:
    for k,v in zip(args[::2],args[1::2]):
        row=db.execute('SELECT rowid FROM settings WHERE key=?',(k,)).fetchone()
        if row:
            db.execute('UPDATE settings SET value=? WHERE rowid=?',(v,row[0]))
        else:
            db.execute('INSERT INTO settings (key,value) VALUES (?,?)',(k,v))
PYSQL
}
set_direct_subscriptions(){
  set_database_values \
    subEnable true subListen 0.0.0.0 subPort "$SUB_PORT" \
    subCertFile "/root/cert/$DOMAIN/fullchain.pem" subKeyFile "/root/cert/$DOMAIN/privkey.pem" \
    subURI "https://$DOMAIN:$SUB_PORT/$SUB_PATH/" \
    subJsonURI "https://$DOMAIN:$SUB_PORT/$JSON_PATH/" \
    subClashURI "https://$DOMAIN:$SUB_PORT/$CLASH_PATH/"
}
set_local_guard(){
  mkdir -p /etc/systemd/system/x-ui.service.d
  cat > /etc/systemd/system/x-ui.service.d/20-reverse-localhost.conf <<'EOFGUARD'
[Service]
ExecStartPre=/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1
EOFGUARD
  run systemctl daemon-reload
}
clear_direct_tls(){
  set_database_values webCertFile '' webKeyFile ''
  set_subscriptions >>"$LOG" 2>&1
}
acme_issue_for_panel(){
  # Same acme.sh provider and managed certificate layout as upstream 3x-ui.
  # Ownership is passed to 3x-ui; acme.sh renews them thereafter.
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y socat cron ca-certificates curl || return 1
  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    local installfile="$BASE/acme-upstream-install.sh"
    run curl -fsSL --retry 3 -o "$installfile" https://get.acme.sh || return 1
    run bash "$installfile" || return 1
  fi
  [[ -x /root/.acme.sh/acme.sh ]] || return 1
  run /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt || return 1
  run /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --httpport 80 --server letsencrypt || {
    # Already-issued certificate can be installed without reissuing.
    /root/.acme.sh/acme.sh --list >>"$LOG" 2>&1 || :
  }
  local target="/root/cert/$DOMAIN"
  install -d -m 700 "$target"
  run /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
     --key-file "$target/privkey.pem" --fullchain-file "$target/fullchain.pem" \
     --reloadcmd '/usr/bin/systemctl restart x-ui' || return 1
  [[ -s "$target/privkey.pem" && -s "$target/fullchain.pem" ]] || return 1
  run openssl x509 -in "$target/fullchain.pem" -noout -checkend 86400 || return 1
  run systemctl enable --now cron || :
  return 0
}
remove_proxy_components(){
  # Call only after check_proxy_owned_for_purge succeeded.
  if [[ "$PROXY" == caddy ]]; then
    run systemctl disable --now caddy || return 1
    rm -f /etc/caddy/Caddyfile
    run env DEBIAN_FRONTEND=noninteractive apt-get purge -y caddy || return 1
  else
    run systemctl disable --now nginx || return 1
    rm -f /etc/nginx/sites-enabled/3x-ui_reverse.conf /etc/nginx/sites-available/3x-ui_reverse.conf
    run systemctl disable --now 3x-ui-reverse-cert-renew.timer || :
    rm -f /etc/systemd/system/3x-ui-reverse-cert-renew.service /etc/systemd/system/3x-ui-reverse-cert-renew.timer
    run env DEBIAN_FRONTEND=noninteractive apt-get purge -y nginx nginx-common certbot || return 1
  fi
  run systemctl daemon-reload || :
  # If proxy cert storage is in use by other tools, ownership test guards against
  # config changes; do not remove cert storage while a service is still active.
  rm -rf -- "$(certdir)"
  return 0
}
remove_proxy_only(){
  [[ "${PROXY_INSTALLED:-1}" == 1 ]] || { warn 'Прокси уже удалён.'; return 0; }
  check_proxy_owned_for_purge || { warn 'Обнаружена сторонняя конфигурация, удаление отменено.'; return 1; }
  local convert='n' oldport=$PANEL_PORT backup='' changed=0
  if [[ "${PANEL_INSTALLED:-1}" == 1 ]]; then
    if tui_yesno "Удаление $PROXY" "Без прокси панель и подписки не будут доступны по прежним ссылкам.

Перенести HTTPS на саму 3x-ui (сертификат выпустит acme.sh)?
 • «Перенести» — панель займёт :443, подписки останутся на :$SUB_PORT (этот TCP-порт нужно открыть);
 • «Нет» — панель будет доступна только локально, внешние ссылки перестанут работать." 'Перенести' 'Нет'; then
      convert=y
    fi
  fi
  confirm_yes "Удалить $PROXY и его сертификаты?" || return 0
  ui_start "Удаление прокси • $DOMAIN" \
    'Проверяем конфигурацию и сохраняем настройки' \
    'Подготавливаем переход на прямой HTTPS' \
    'Проверяем доступность панели' \
    "Удаляем $PROXY и сертификаты прокси" \
    'Обновляем сохранённые параметры'
  msg 'Проверяем конфигурацию и сохраняем настройки'
  if [[ "${PANEL_INSTALLED:-1}" == 1 && "$convert" =~ ^[yYдД]$ ]]; then
    backup="$BASE/backup-db-pre-direct.$(date +%Y%m%d-%H%M%S).db"
    run systemctl stop x-ui || { ui_stop failed; warn 'Не удалось остановить x-ui.'; return 1; }
    backup_db "$backup" || { run systemctl start x-ui || :; ui_stop failed; return 1; }
    changed=1
  fi
  step 17 'Настройки сохранены'
  msg 'Подготавливаем переход на прямой HTTPS'
  if ((changed)); then
    # The domain's HTTP-01 endpoint must be temporarily available on port 80.
    run systemctl stop "$PROXY" || { ui_stop failed; return 1; }
    if ss -H -ltn '( sport = :80 or sport = :443 )' | grep -q .; then
      run systemctl start "$PROXY" || :; run systemctl start x-ui || :
      ui_stop failed; warn 'Порты 80/443 заняты посторонним процессом.'; return 1
    fi
    if ! acme_issue_for_panel; then
      run systemctl start "$PROXY" || :; run systemctl start x-ui || :
      ui_stop failed; warn 'Не удалось выпустить сертификат 3x-ui. Исходный прокси возвращён.'; return 1
    fi
    rm -f /etc/systemd/system/x-ui.service.d/20-reverse-localhost.conf
    run systemctl daemon-reload || :
    if ! run "$CLI" setting -port 443 -webBasePath "$PANEL_PATH" -listenIP 0.0.0.0 ||
       ! run "$CLI" cert -webCert "/root/cert/$DOMAIN/fullchain.pem" -webCertKey "/root/cert/$DOMAIN/privkey.pem" ||
       ! set_direct_subscriptions || ! run systemctl restart x-ui; then
      run systemctl stop x-ui || :; cp -a "$backup" "$DB"; PANEL_PORT=$oldport
      set_local_guard; run systemctl start "$PROXY" || :; run systemctl start x-ui || :
      ui_stop failed; warn 'Перенос HTTPS завершился ошибкой. Восстановлена база и прежний прокси.'; return 1
    fi
    if ! curl -fsS --max-time 15 --resolve "$DOMAIN:443:127.0.0.1" -o /dev/null "https://$DOMAIN/$PANEL_PATH/" || ! ss -H -ltn "sport = :$SUB_PORT" | awk '{print $4}' | grep -Eq "(0\\.0\\.0\\.0|\\[::\\]):$SUB_PORT$"; then
      run systemctl stop x-ui || :; cp -a "$backup" "$DB"; PANEL_PORT=$oldport
      set_local_guard; run systemctl start "$PROXY" || :; run systemctl start x-ui || :
      ui_stop failed; warn 'Проверка прямого HTTPS не прошла. Восстановлена прежняя конфигурация.'; return 1
    fi
    PANEL_PORT=443
    TLS_MODE=direct
  else
    TLS_MODE=none
  fi
  step 57 'Проверили доступ к панели'
  msg 'Проверяем доступность панели'
  # In localhost-only mode external access is deliberately disabled.
  step 72 'Режим доступа выбран'
  msg "Удаляем $PROXY и сертификаты прокси"
  if ! remove_proxy_components; then
    ui_stop failed; warn 'Удаление прокси прервано, см. журнал. Возможно, потребуется ручное восстановление.'; return 1
  fi
  PROXY_INSTALLED=0
  step 92 'Прокси удалён'
  msg 'Обновляем сохранённые параметры'
  save_state; write_info
  step 100 'Параметры обновлены'
  ui_stop
  note '✓ Прокси удалён.'
  if [[ "$TLS_MODE" == direct ]]; then
    note "Панель: https://$DOMAIN/$PANEL_PATH/"
    note "Подписки: https://$DOMAIN:$SUB_PORT/$SUB_PATH/CLIENT_SUB_ID"
    warn "Открой TCP $SUB_PORT во внешнем файрволе VPS. HTTPS теперь обслуживает 3x-ui, acme.sh продлевает сертификат."
  else
    warn 'Внешний доступ к панели отключён. Восстанови прокси: Обслуживание → Переустановить прокси.'
  fi
}
remove_panel_components(){
  remove_activity_timer
  run systemctl disable --now x-ui || :
  rm -f /etc/systemd/system/x-ui.service /etc/default/x-ui /usr/bin/x-ui
  rm -rf -- /etc/systemd/system/x-ui.service.d /usr/local/x-ui /etc/x-ui /var/log/x-ui
  rm -f /etc/fail2ban/filter.d/3x-ipl.conf /etc/fail2ban/action.d/3x-ipl.conf
  rm -f /etc/fail2ban/jail.d/3x-ipl.conf /etc/fail2ban/jail.d/3x-ipl-backend.conf
  # The token belonged to the removed database; the backup keeps its hash.
  rm -f -- "$API_TOKEN" "$NODE_TOKEN" "$BASE/activity.json"
  run systemctl daemon-reload || :
  run systemctl try-restart fail2ban || :
}
remove_panel_only(){
  [[ "${PANEL_INSTALLED:-1}" == 1 ]] || { warn '3x-ui уже удалена.'; return 0; }
  if [[ "${PROXY_INSTALLED:-1}" == 1 ]]; then
    check_proxy_owned_for_purge || { warn 'Чужая конфигурация прокси — удаление запрещено.'; return 1; }
  fi
  confirm_yes "Удалить 3x-ui вместе с пользователями, inbound-ами, конфигурацией Xray и базой?
Резервная копия SQLite останется в $BASE/backups/" || return 0
  local backup="$BASE/backups/before-panel-removal-$(date +%Y%m%d-%H%M%S).db"
  ui_start "Удаление 3x-ui • $DOMAIN" \
    'Останавливаем 3x-ui' 'Сохраняем SQLite-базу' \
    'Убираем маршруты панели из прокси' 'Удаляем бинарники и рабочую базу' 'Записываем состояние'
  msg 'Останавливаем 3x-ui'
  run systemctl stop x-ui || { ui_stop failed; return 1; }
  step 20 'Служба остановлена'
  msg 'Сохраняем SQLite-базу'
  backup_db "$backup" || { ui_stop failed; warn 'Резервное копирование не удалось. Удаление отменено.'; run systemctl start x-ui || :; return 1; }
  step 45 'База сохранена'
  msg 'Убираем маршруты панели из прокси'
  PANEL_INSTALLED=0
  if [[ "${PROXY_INSTALLED:-1}" == 1 ]]; then
    if ! update_proxy_safe; then
      PANEL_INSTALLED=1; ui_stop failed; warn 'Не получилось обновить прокси, удаление отменено.'
      run systemctl start x-ui || :; return 1
    fi
  fi
  step 65 'Маршруты отключены'
  msg 'Удаляем бинарники и рабочую базу'
  remove_panel_components
  if [[ "${TLS_MODE:-proxy}" == direct && "${PROXY_INSTALLED:-1}" == 0 ]]; then
    if [[ -x /root/.acme.sh/acme.sh ]]; then run /root/.acme.sh/acme.sh --remove -d "$DOMAIN" || :; fi
    rm -rf -- "/root/cert/$DOMAIN"
  fi
  TLS_MODE=$([[ "${PROXY_INSTALLED:-1}" == 1 ]] && echo proxy || echo none)
  step 92 'Панель удалена'
  msg 'Записываем состояние'
  save_state; write_info
  step 100 'Состояние сохранено'
  ui_stop
  note "✓ 3x-ui удалена. Резервная копия: $backup"
}
reinstall_panel(){
  local direct=0
  if [[ "${TLS_MODE:-proxy}" == direct && "${PROXY_INSTALLED:-1}" == 0 && "${PANEL_INSTALLED:-1}" == 1 ]]; then
    direct=1
    [[ -s "/root/cert/$DOMAIN/privkey.pem" && -s "/root/cert/$DOMAIN/fullchain.pem" ]] || {
      warn 'Не найдены сертификаты прямого HTTPS, сначала восстанови прокси.'; return 1
    }
  elif [[ "${PROXY_INSTALLED:-1}" == 1 ]]; then
    check_proxy_owned_for_purge || { warn 'Сторонняя конфигурация прокси, действие отменено.'; return 1; }
  else
    warn 'Для переустановки удалённой панели сначала восстанови прокси (пункт 11).'; return 1
  fi
  confirm_yes 'Переустановить 3x-ui последней версии? SQLite-база, пользователи и учётные данные будут сохранены.' || return 0
  local had_panel="${PANEL_INSTALLED:-1}" backup='' installer="$BASE/3x-ui-upstream-install.sh"
  ui_start "Переустановка 3x-ui • $DOMAIN" \
    'Проверяем настройки' 'Сохраняем SQLite' \
    'Скачиваем официальный установщик' 'Устанавливаем 3x-ui' \
    'Применяем локальные порты и подписки' 'Проверяем работу и обновляем ссылки'
  msg 'Проверяем настройки'
  [[ -d "$BASE" && -f "$(proxy_conf)" ]] || { ui_stop failed; warn 'Нет конфигурации прокси.'; return 1; }
  step 10 'Параметры проверены'
  msg 'Сохраняем SQLite'
  if [[ "$had_panel" == 1 ]]; then
    run systemctl stop x-ui || { ui_stop failed; return 1; }
    backup="$BASE/backups/before-panel-reinstall-$(date +%Y%m%d-%H%M%S).db"
    backup_db "$backup" || { ui_stop failed; run systemctl start x-ui || :; return 1; }
  fi
  step 25 'Резервная копия готова'
  msg 'Скачиваем официальный установщик'
  run curl -fsSL --retry 3 -o "$installer" "$XUI_INSTALL_URL" || { ui_stop failed; warn 'Не удалось скачать установщик.'; return 1; }
  chmod 700 "$installer"
  step 38 'Установщик получен'
  msg 'Устанавливаем 3x-ui'
  prepare_bootstrap_guard
  # We must prevent even an intermediate upstream start from exposing plain HTTP.
  if ! XUI_NONINTERACTIVE=1 XUI_SSL_MODE=none XUI_DB_TYPE=sqlite \
      XUI_PANEL_PORT="$PANEL_PORT" XUI_WEB_BASE_PATH="$PANEL_PATH" \
      XUI_USERNAME="$PANEL_USER" XUI_PASSWORD="$PANEL_PASS" \
      bash "$installer" >>"$LOG" 2>&1; then
    ui_stop failed; warn 'Официальный установщик завершился с ошибкой; копия SQLite сохранена.'; return 1
  fi
  [[ -f "$DB" && -x "$CLI" ]] || { ui_stop failed; warn 'Отсутствует бинарник или база.'; return 1; }
  run systemctl stop x-ui || :
  if [[ -n "$backup" ]]; then cp -a "$backup" "$DB"; fi
  step 66 'Бинарник установлен, база восстановлена'
  msg 'Применяем локальные порты и подписки'
  if ((direct)); then
    # Installer's temporary guard protected the first start; direct HTTPS
    # configuration is restored only AFTER validating certificate files.
    rm -f /etc/systemd/system/x-ui.service.d/20-reverse-localhost.conf
    rm -f "$BASE/bootstrap-guard.py" "$BASE/bootstrap-guard.env"
    if ! run systemctl daemon-reload ||
       ! run "$CLI" setting -port 443 -webBasePath "$PANEL_PATH" -listenIP 0.0.0.0 ||
       ! run "$CLI" cert -webCert "/root/cert/$DOMAIN/fullchain.pem" -webCertKey "/root/cert/$DOMAIN/privkey.pem" ||
       ! set_direct_subscriptions ||
       ! run "$CLI" setting -username "$PANEL_USER" -password "$PANEL_PASS" ||
       ! run systemctl restart x-ui; then
      run systemctl stop x-ui || :
      ui_stop failed; warn 'Не удалось вернуть прямой HTTPS, x-ui остановлен.'; return 1
    fi
    if ! verify_remote; then
      run systemctl stop x-ui || :
      ui_stop failed; warn 'Проверка прямого HTTPS не прошла, x-ui остановлен.'; return 1
    fi
    step 89 '3x-ui обслуживает HTTPS самостоятельно'
    msg 'Проверяем работу и обновляем ссылки'
    PANEL_INSTALLED=1; TLS_MODE=direct; PROXY_INSTALLED=0
  else
    if ! apply_panel || ! set_subscriptions >>"$LOG" 2>&1 ||
       ! run "$CLI" setting -username "$PANEL_USER" -password "$PANEL_PASS"; then
      ui_stop failed; warn 'Ошибка применения конфигурации. Сервис остановлен.'; return 1
    fi
    finalize_bootstrap_guard
    if ! run systemctl restart x-ui || ! wait_local_stack; then
      run systemctl stop x-ui || :
      ui_stop failed; warn 'Локальная проверка 3x-ui не пройдена. Сервис остановлен.'; return 1
    fi
    step 89 '3x-ui работает на localhost'
    msg 'Проверяем работу и обновляем ссылки'
    PANEL_INSTALLED=1; TLS_MODE=proxy
    if ! update_proxy_safe; then
      ui_stop failed; warn 'Прокси не обновился, но 3x-ui установлена. Проверь журнал.'; return 1
    fi
  fi
  save_state; write_info
  # The restored database keeps inbounds, users and the Xray template (access log,
  # groups); only the activity timer has to come back after a removal.
  if ensure_api_token; then
    setup_activity_timer || warn 'Не удалось включить учёт активности.'
  else
    warn 'API 3x-ui недоступен: учёт активности не включён.'
  fi
  step 100 'Переустановка завершена'
  ui_stop
  note '✓ 3x-ui установлена. Клиенты и пути сохранены.'
  [[ -z "$backup" ]] || note "Резервная копия базы: $backup"
}
rollback_direct_proxy(){
  local backup=$1 oldport=$2
  # Reinstall had started without a proxy present; restore the direct TLS mode.
  run systemctl disable --now "$PROXY" || :
  if [[ "$PROXY" == caddy ]]; then
    if [[ -L /etc/caddy/Caddyfile && $(readlink -f /etc/caddy/Caddyfile) == "$BASE/Caddyfile" ]]; then
      rm -f /etc/caddy/Caddyfile
    fi
    run env DEBIAN_FRONTEND=noninteractive apt-get purge -y caddy || :
  else
    rm -f /etc/nginx/sites-enabled/3x-ui_reverse.conf /etc/nginx/sites-available/3x-ui_reverse.conf
    run env DEBIAN_FRONTEND=noninteractive apt-get purge -y nginx nginx-common certbot || :
  fi
  run systemctl stop x-ui || :
  if [[ -s "$backup" ]]; then cp -a "$backup" "$DB"; fi
  rm -f /etc/systemd/system/x-ui.service.d/20-reverse-localhost.conf
  run systemctl daemon-reload || :
  PANEL_PORT=$oldport
  PROXY_INSTALLED=0
  TLS_MODE=direct
  run systemctl start x-ui || :
  if ! verify_remote; then
    warn 'Восстановленный прямой HTTPS не отвечает. Проверь логи x-ui немедленно.'
  fi
}
reinstall_proxy(){
  confirm_yes "Переустановить $PROXY? Конфигурация и сертификаты будут сохранены." || return 0
  local had_proxy="${PROXY_INSTALLED:-1}" direct=0 oldport=$PANEL_PORT \
        backup=''
  ui_start "Переустановка $PROXY • $DOMAIN" \
    'Проверяем конфигурацию и порты' 'Сохраняем параметры и сертификаты' \
    "Устанавливаем $PROXY" 'Настраиваем сертификаты и маршруты' \
    'Проверяем HTTPS и сохраняем параметры'
  msg 'Проверяем конфигурацию и порты'
  if [[ "$had_proxy" == 1 ]]; then
    check_proxy_owned_for_purge || { ui_stop failed; warn 'Прокси управляется посторонней конфигурацией.'; return 1; }
  else
    if command -v caddy >/dev/null || command -v nginx >/dev/null; then
      ui_stop failed; warn 'Найден сторонний Caddy или Nginx. Автоматическая переустановка запрещена.'; return 1
    fi
    if [[ "${TLS_MODE:-none}" == direct && "${PANEL_INSTALLED:-1}" == 1 ]]; then direct=1; fi
    if (( !direct )) && ss -H -ltn '( sport = :80 or sport = :443 )' | grep -q .; then
      ui_stop failed; warn 'Порты 80/443 заняты.'; return 1
    fi
  fi
  step 12 'Совместимость проверена'
  msg 'Сохраняем параметры и сертификаты'
  if [[ "$had_proxy" == 0 && "${PANEL_INSTALLED:-1}" == 0 && "$PANEL_PORT" == 443 ]]; then
    PANEL_PORT=$(newport) || { ui_stop failed; return 1; }
  fi
  cp -a "$STATE" "$BASE/backup-state-proxy-$(date +%Y%m%d-%H%M%S).env"
  if ((direct)); then
    run systemctl stop x-ui || { ui_stop failed; return 1; }
    backup="$BASE/backups/before-proxy-return-$(date +%Y%m%d-%H%M%S).db"
    backup_db "$backup" || { ui_stop failed; run systemctl start x-ui || :; return 1; }
    PANEL_PORT=$(newport) || { run systemctl start x-ui || :; ui_stop failed; return 1; }
    if ! set_local_guard || ! apply_panel || ! clear_direct_tls; then
      rollback_direct_proxy "$backup" "$oldport"
      ui_stop failed; warn 'Не удалось подготовить переход на localhost.'; return 1
    fi
  fi
  step 30 'Параметры сохранены'
  msg "Устанавливаем $PROXY"
  if [[ "$PROXY" == caddy ]]; then
    if ! run env DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall caddy; then
      if ((direct)); then rollback_direct_proxy "$backup" "$oldport"; fi
      ui_stop failed; warn 'Не удалось установить Caddy.'; return 1
    fi
    mkdir -p "$(certdir)"
    if [[ "$had_proxy" == 0 ]]; then
      [[ -f /etc/caddy/Caddyfile && ! -L /etc/caddy/Caddyfile ]] && cp -a /etc/caddy/Caddyfile "$BASE/Caddyfile.package-default"
      ln -sfn "$BASE/Caddyfile" /etc/caddy/Caddyfile
    fi
    chown -R caddy:caddy "$(certdir)"
    chmod 750 "$(certdir)"
  else
    if ! run env DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall nginx certbot; then
      if ((direct)); then rollback_direct_proxy "$backup" "$oldport"; fi
      ui_stop failed; warn 'Не удалось установить Nginx/Certbot.'; return 1
    fi
    if [[ "$had_proxy" == 0 ]]; then
      rm -f /etc/nginx/sites-enabled/default
      ln -sfn /etc/nginx/sites-available/3x-ui_reverse.conf /etc/nginx/sites-enabled/3x-ui_reverse.conf
    fi
  fi
  step 60 'Прокси установлен'
  msg 'Настраиваем сертификаты и маршруты'
  if [[ "$had_proxy" == 1 ]]; then
    if ! update_proxy_safe; then ui_stop failed; warn 'Прокси не удалось восстановить, исходная конфигурация сохранена.'; return 1; fi
  elif [[ "$PROXY" == caddy ]]; then
    write_caddy
    if ! validate_proxy || ! run systemctl enable --now caddy || ! run systemctl restart caddy; then
      if ((direct)); then rollback_direct_proxy "$backup" "$oldport"; fi
      ui_stop failed; warn 'Caddy не запустился.'; return 1
    fi
  else
    write_nginx bootstrap
    if ! validate_proxy || ! run systemctl enable --now nginx || ! run systemctl restart nginx; then
      if ((direct)); then rollback_direct_proxy "$backup" "$oldport"; fi
      ui_stop failed; warn 'Nginx не запустился.'; return 1
    fi
    if ! run certbot certonly --non-interactive --agree-tos --register-unsafely-without-email \
       --webroot -w "$SITE" -d "$DOMAIN" --cert-name "$DOMAIN" \
       --config-dir "$(certdir)" --work-dir "$BASE/certbot-work" --logs-dir "$BASE/certbot-logs"; then
      if ((direct)); then rollback_direct_proxy "$backup" "$oldport"; fi
      ui_stop failed; warn 'Не удалось получить сертификат Certbot.'; return 1
    fi
    write_nginx full
    if ! validate_proxy || ! reload_proxy; then
      if ((direct)); then rollback_direct_proxy "$backup" "$oldport"; fi
      ui_stop failed; warn 'Nginx не прошёл проверку HTTPS.'; return 1
    fi
    setup_renew_timer
  fi
  step 88 'Прокси и HTTPS настроены'
  msg 'Проверяем HTTPS и сохраняем параметры'
  if ((direct)); then
    if ! run systemctl start x-ui || ! wait_local_stack; then
      rollback_direct_proxy "$backup" "$oldport"
      ui_stop failed; warn 'Локальный 3x-ui не запустился после миграции; прямой режим восстановлен.'; return 1
    fi
  fi
  PROXY_INSTALLED=1; TLS_MODE=proxy
  if ! verify_remote; then
    if ((direct)); then
      rollback_direct_proxy "$backup" "$oldport"
    else
      save_state; write_info
    fi
    ui_stop failed; warn 'Локальная HTTPS-проверка не прошла; проверь сертификаты.'
    return 1
  fi
  save_state; write_info
  if ((direct)) && [[ -x /root/.acme.sh/acme.sh ]]; then
    run /root/.acme.sh/acme.sh --remove -d "$DOMAIN" || :
    rm -rf -- "/root/cert/$DOMAIN"
  fi
  step 100 'HTTPS доступен'
  ui_stop
  note "✓ $PROXY установлен, панель и ссылки проверены."
}
api_base(){
  if [[ "${TLS_MODE:-proxy}" == direct && "${PROXY_INSTALLED:-1}" == 0 ]]; then
    printf 'https://127.0.0.1:443/%s/panel/api' "${PANEL_PATH:-}"
  else
    printf 'http://127.0.0.1:%s/%s/panel/api' "${PANEL_PORT:-0}" "${PANEL_PATH:-}"
  fi
}
helper(){
  [[ -f "$HELPER" ]] || write_helper
  XR_API="$(api_base)" XR_TLS_SNI="${DOMAIN:-}" XR_TOKEN_FILE="$API_TOKEN" \
  XR_STATE_DIR="${HELPER_STATE:-$BASE}" XR_ACCESS_LOG="$ACCESS_LOG" python3 -I "$HELPER" "$@"
}
write_helper_env(){
  [[ -d "$BASE" && -n "${PANEL_PATH:-}" ]] || return 0
  local tmp; tmp=$(mktemp "$BASE/helper-env.XXXXXXXX")
  printf 'XR_API=%s\nXR_TLS_SNI=%s\nXR_TOKEN_FILE=%s\nXR_ACCESS_LOG=%s\n' \
    "$(api_base)" "$DOMAIN" "$API_TOKEN" "$ACCESS_LOG" > "$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$HELPER_ENV"
}

# ---- Inbounds, users and groups ----
# Everything below talks to the local 3x-ui REST API with a dedicated admin
# API token (x-ui setting -getApiToken), through a small Python helper.
ensure_api_token(){
  # $1 — how many seconds to wait for a starting panel (1 = just check once).
  local tries=${1:-10} i token=''
  [[ "${PANEL_INSTALLED:-1}" == 1 && -x "$CLI" ]] || return 1
  [[ -f "$HELPER" ]] || write_helper
  if [[ -s "$API_TOKEN" ]]; then
    for ((i=0; i<tries; i++)); do
      helper ping >/dev/null 2>&1 && return 0
      ((i + 1 < tries)) && sleep 1
    done
    # Panel down: a new token would not help.
    systemctl is-active --quiet x-ui || return 1
  fi
  # Regenerates only the token named 3x-ui_reverse; other API tokens stay valid.
  # The plaintext token goes straight into a 0600 file and is never logged.
  token=$("$CLI" setting -getApiToken -tokenName 3x-ui_reverse -tokenScope admin 2>/dev/null \
          | sed -n 's/^apiToken: //p' | tail -n1) || return 1
  [[ -n "$token" ]] || return 1
  ( umask 077; printf '%s\n' "$token" > "$API_TOKEN" )
  for ((i=0; i<10; i++)); do
    helper ping >/dev/null 2>>"$LOG" && return 0
    sleep 1
  done
  return 1
}
sub_base(){
  if [[ "${PROXY_INSTALLED:-1}" == 1 ]]; then printf 'https://%s' "$DOMAIN"
  elif [[ "${TLS_MODE:-none}" == direct ]]; then printf 'https://%s:%s' "$DOMAIN" "$SUB_PORT"
  fi
}
print_user_links(){
  local email=$1 sid base
  sid=$(helper sub-id "$email" 2>>"$LOG") || return 1
  base=$(sub_base)
  if [[ -z "$base" ]]; then warn 'Подписки недоступны: прокси удалён.'; return 0; fi
  # Label and URL on separate lines: long links must not wrap inside dialogs.
  printf '  Обычная (VLESS, MTProto):\n    %s\n' "$base/$SUB_PATH/$sid"
  printf '  JSON:\n    %s\n' "$base/$JSON_PATH/$sid"
  printf '  Mihomo / Clash:\n    %s\n' "$base/$CLASH_PATH/$sid"
}
setup_activity_timer(){
  [[ -f "$HELPER" ]] || write_helper
  write_helper_env
  cat > "/etc/systemd/system/$ACTIVITY_UNIT.service" <<EOF
[Unit]
Description=3x-ui_reverse: last activity of users per inbound
After=x-ui.service
[Service]
Type=oneshot
Environment=XR_STATE_DIR=$BASE
ExecStart=/usr/bin/python3 -I $HELPER track-activity
EOF
  cat > "/etc/systemd/system/$ACTIVITY_UNIT.timer" <<'EOF'
[Unit]
Description=3x-ui_reverse: fold Xray access log into per-user activity every minute
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=15s
[Install]
WantedBy=timers.target
EOF
  chmod 644 "/etc/systemd/system/$ACTIVITY_UNIT.service" "/etc/systemd/system/$ACTIVITY_UNIT.timer"
  run systemctl daemon-reload && run systemctl enable --now "$ACTIVITY_UNIT.timer"
}
remove_activity_timer(){
  run systemctl disable --now "$ACTIVITY_UNIT.timer" || :
  rm -f "/etc/systemd/system/$ACTIVITY_UNIT.service" "/etc/systemd/system/$ACTIVITY_UNIT.timer"
  run systemctl daemon-reload || :
}

# ---------------------------------------------------------------- inbound catalog
# Kinds offered by the script (keys match the Python helper's catalog).
declare -A KIND_LABEL=(
  [vless-tcp-reality]='VLESS TCP Reality' [vless-xhttp-reality]='VLESS XHTTP Reality'
  [vless-xhttp-tls]='VLESS XHTTP TLS' [trojan-tcp]='Trojan TCP'
  [trojan-tcp-reality]='Trojan TCP Reality' [trojan-xhttp-reality]='Trojan XHTTP Reality'
  [trojan-xhttp-tls]='Trojan XHTTP TLS' [hysteria]='Hysteria2' [amneziawg]='AmneziaWG' [mtproto]='MTProto'
)
TLS_KINDS=' vless-xhttp-tls trojan-xhttp-tls hysteria '
SNI_KINDS=' vless-tcp-reality vless-xhttp-reality trojan-tcp-reality trojan-xhttp-reality mtproto '
INB_KINDS=()
declare -A INB_TLS=()
CREATED_IDS=''
TLS_SPEC=''

# Certificate the proxy (or acme.sh in direct mode) obtained for $DOMAIN.
# Prints two lines: certificate and key. Xray re-reads them hourly, so renewals
# are picked up without a restart.
domain_cert_paths(){
  local crt key
  if [[ "${PROXY_INSTALLED:-1}" == 1 && "$PROXY" == caddy ]]; then
    crt=$(find "$(certdir)" -type f -path "*/certificates/*/$DOMAIN/$DOMAIN.crt" 2>/dev/null | sort | head -n1)
    key=${crt%.crt}.key
  elif [[ "${PROXY_INSTALLED:-1}" == 1 ]]; then
    crt="$(certdir)/live/$DOMAIN/fullchain.pem"; key="$(certdir)/live/$DOMAIN/privkey.pem"
  else
    crt="/root/cert/$DOMAIN/fullchain.pem"; key="/root/cert/$DOMAIN/privkey.pem"
  fi
  [[ -n "$crt" && -s "$crt" && -s "$key" ]] || return 1
  printf '%s\n%s\n' "$crt" "$key"
}
# Caddy obtains the certificate in the background right after it starts.
wait_domain_cert(){
  local i
  for ((i=0; i<45; i++)); do
    domain_cert_paths && return 0
    sleep 2
  done
  return 1
}
# Checks a user-supplied certificate: files, expiry, host name and key pair.
check_cert_files(){
  local crt=$1 key=$2 sni=$3
  [[ -s "$crt" ]] || { printf 'файл сертификата не найден: %s' "$crt"; return 1; }
  [[ -s "$key" ]] || { printf 'файл ключа не найден: %s' "$key"; return 1; }
  openssl x509 -in "$crt" -noout >/dev/null 2>&1 || { printf '%s — не сертификат в формате PEM' "$crt"; return 1; }
  openssl x509 -in "$crt" -noout -checkend 0 >/dev/null 2>&1 || { printf 'срок действия сертификата истёк'; return 1; }
  if ! openssl x509 -in "$crt" -noout -checkhost "$sni" 2>/dev/null | grep -q 'does match'; then
    printf 'сертификат не выдан для %s' "$sni"; return 1
  fi
  if [[ "$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null)" != "$(openssl pkey -in "$key" -pubout 2>/dev/null)" ]]; then
    printf 'ключ не подходит к сертификату'; return 1
  fi
  return 0
}
cert_label(){
  local crt=$1
  if [[ "$crt" == "$(certdir)"/* || "$crt" == "/root/cert/$DOMAIN/"* ]]; then
    printf 'сертификат домена %s' "$DOMAIN"
  else
    printf 'свой: %s' "$crt"
  fi
}
# Asks which certificate a TLS inbound uses. Result in TLS_SPEC:
# "domain" (resolved when the inbound is created) or "CERT|KEY|SNI".
choose_tls(){
  local label=$1 src crt key sni err
  src=$(tui_radiolist "TLS: $label" "Какой сертификат использовать для $label?" \
        domain $'Сертификат домена\t{dim}'"$DOMAIN"$' · продлевается автоматически{/}' ON \
        own $'Другой сертификат\t{dim}свои файлы .crt / .key{/}' OFF) || return 1
  if [[ "$src" == domain ]]; then TLS_SPEC=domain; return 0; fi
  crt=$(tui_input "Сертификат: $label" 'Полный путь к файлу сертификата (fullchain, PEM):' '/root/cert/') || return 1
  key=$(tui_input "Сертификат: $label" 'Полный путь к файлу закрытого ключа (PEM):' "${crt%/*}/") || return 1
  sni=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^,]*' | head -n1 | cut -d: -f2)
  sni=$(tui_input "Сертификат: $label" 'Домен (SNI), на который выдан сертификат:' "$sni") || return 1
  sni=${sni,,}
  if ! err=$(check_cert_files "$crt" "$key" "$sni"); then
    tui_msg 'Сертификат не подходит' "{red}✗ $err{/}"
    return 1
  fi
  TLS_SPEC="$crt|$key|$sni"
}
# Inbound selection list → INB_KINDS / INB_TLS. $1=fresh: no panel yet.
select_inbounds(){
  local sel k
  local -a picked=()
  read_check menu-kinds ${1:+--fresh}
  if ((${#TSV_ITEMS[@]} == 0)); then tui_msg 'Inbound-ы' 'Не удалось получить список inbound-ов.'; return 1; fi
  sel=$(tui_checklist 'Какие inbound-ы создать?' \
        'Порты подбираются свободные, SNI — доступные из России сайты. Отмечены рекомендуемые.' \
        "${TSV_ITEMS[@]}") || return 1
  mapfile -t picked <<< "$sel"
  INB_KINDS=()
  INB_TLS=()
  for k in "${picked[@]}"; do
    [[ -n "$k" && -n "${KIND_LABEL[$k]:-}" ]] || continue
    INB_KINDS+=("$k")
    if [[ "$TLS_KINDS" == *" $k "* ]]; then
      choose_tls "${KIND_LABEL[$k]}" || return 1
      INB_TLS[$k]=$TLS_SPEC
    fi
  done
  ((${#INB_KINDS[@]})) || { tui_msg 'Inbound-ы' 'Ничего не выбрано.'; return 1; }
}
selected_labels(){
  local k out=''
  for k in "${INB_KINDS[@]}"; do out+="${out:+, }${KIND_LABEL[$k]}"; done
  printf '%s' "$out"
}
open_firewall_ports(){
  # Only touches a firewall that is already active; the provider's external
  # firewall (security groups) still has to be opened by hand.
  local ports p
  ports=$(helper ports "$@" 2>>"$LOG") || return 1
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    for p in $ports; do run ufw allow "$p" || :; done
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for p in $ports; do run firewall-cmd --permanent --add-port="$p" || :; done
    run firewall-cmd --reload || :
  fi
  return 0
}
# Creates INB_KINDS (with INB_TLS certificates); new ids in CREATED_IDS.
setup_inbounds(){
  local k spec out kinds='' paths
  local -a args=() snis=()
  CREATED_IDS=''
  write_helper
  write_helper_env
  ensure_api_token || { warn 'Не удалось получить API-токен 3x-ui.'; return 1; }
  [[ -n "${XR_SNI:-}" ]] && IFS=, read -ra snis <<< "$XR_SNI"
  for k in "${INB_KINDS[@]}"; do
    spec=${INB_TLS[$k]:-}
    if [[ "$TLS_KINDS" == *" $k "* ]]; then
      if [[ "$spec" == domain || -z "$spec" ]]; then
        if ! paths=$(wait_domain_cert); then
          warn "${KIND_LABEL[$k]} не создан: сертификат домена ещё не выпущен. Создай его позже в меню «Inbound-ы»."
          continue
        fi
        spec="$(sed -n 1p <<< "$paths")|$(sed -n 2p <<< "$paths")|$DOMAIN"
      fi
      args+=(--tls "$k|$spec")
    elif [[ "$SNI_KINDS" == *" $k "* ]] && ((${#snis[@]})); then
      args+=(--sni "$k|${snis[0]}")
      snis=("${snis[@]:1}")
    fi
    kinds+="${kinds:+,}$k"
  done
  [[ -n "$kinds" ]] || return 1
  printf 'Creating inbounds: %s\n' "$kinds" >>"$LOG"
  if ! out=$(helper create-inbounds "$kinds" --sniff "$XR_SNIFF" "${args[@]}" 2>&1); then
    printf '%s\n' "$out" >>"$LOG"
    warn "Не удалось создать inbound-ы: ${out#Ошибка: }"
    return 1
  fi
  CREATED_IDS=$(tail -n1 <<< "$out")
  helper enable-access-log >>"$LOG" 2>&1 || warn 'Не удалось включить журнал активности Xray.'
  setup_activity_timer || warn 'Не удалось включить учёт активности.'
  # shellcheck disable=SC2086  # ids are numbers separated by spaces
  open_firewall_ports $CREATED_IDS || :
  return 0
}

# ---------------------------------------------------------------- DNS check
# Like dnschecker.org: public resolvers in several countries and the domain's
# authoritative server must point the A record at this VPS.
dns_check_screen(){
  local out table verdict auth aaaa okn ip head ch first
  while :; do
    if ! out=$(helper dns-check "$DOMAIN" 2>&1); then
      if getent ahostsv4 "$DOMAIN" >/dev/null; then return 0; fi
      tui_yesno 'Проверка DNS' "{red}✗ Для $DOMAIN не найдена A-запись.{/} Настрой DNS у регистратора домена." \
        'Проверить снова' 'Отмена' yes || return 1
      continue
    fi
    table=$(grep -v '^VERDICT ' <<< "$out")
    read -r _ verdict auth aaaa okn ip <<< "$(grep '^VERDICT ' <<< "$out" | tail -n1)"
    auth=${auth#AUTH=}; aaaa=${aaaa#AAAA=}; okn=${okn#OK=}; ip=${ip#IP=}
    case "$verdict" in
      ok)      head="{green}✓ $DOMAIN указывает на этот сервер ($ip) во всех DNS ($okn).{/}"; first=go ;;
      partial) head="{yellow}⚠ Правильный адрес видят не все DNS ($okn) — запись ещё распространяется.{/}"
               if [[ "$auth" == ok ]]; then
                 head+=$'\n'"Авторитетный сервер уже отдаёт верный адрес — сертификат выпустится, можно продолжать."; first=go
               else first=again; fi ;;
      wrong)   head="{red}✗ $DOMAIN не указывает на этот сервер ($ip).{/}"$'\n'"Создай или исправь A-запись у регистратора и проверь снова (обновление занимает от минут до нескольких часов)."
               first=again ;;
      *)       head="{yellow}⚠ Не удалось опросить DNS-серверы (закрыты UDP 53 и DoH?).{/}"; first=go ;;
    esac
    if [[ "$aaaa" == wrong ]]; then
      head+=$'\n'"{yellow}⚠ У домена есть AAAA-запись (IPv6) на другой адрес: Let's Encrypt может проверить её и не выдать сертификат. Удали её или укажи IPv6 этого сервера.{/}"
    fi
    if [[ "${DNS_MODE:-}" == standalone ]]; then
      ch=$(TUI_LOGO=1 TUI_DEFAULT=again TUI_CANCEL='Назад' tui_menu 'Проверка DNS' "$head"$'\n\n'"$table" \
           again 'Проверить снова' finish 'Готово') || return 0
      [[ "$ch" == again ]] && continue
      return 0
    fi
    if [[ "$first" == go ]]; then
      ch=$(TUI_LOGO=1 TUI_DEFAULT=go TUI_CANCEL='Отмена' tui_menu 'Проверка DNS' "$head"$'\n\n'"$table" \
           go '{green}Продолжить установку{/}' again 'Проверить снова' cancel 'Отменить') || return 1
    else
      ch=$(TUI_LOGO=1 TUI_DEFAULT=again TUI_CANCEL='Отмена' tui_menu 'Проверка DNS' "$head"$'\n\n'"$table" \
           again 'Проверить снова' go '{yellow}Всё равно продолжить{/}' cancel 'Отменить') || return 1
    fi
    case "$ch" in
      go) return 0 ;;
      again) continue ;;
      *) return 1 ;;
    esac
  done
}

# ---------------------------------------------------------------- inbound screens
inbound_add(){
  select_inbounds || return 0
  if with_progress 'Создание inbound-ов' "Создаём: $(selected_labels)" setup_inbounds; then
    note "{green}✓ Создано: $(selected_labels).{/}"
    # shellcheck disable=SC2086
    note "Открой во внешнем файрволе провайдера: $(helper ports $CREATED_IDS 2>/dev/null || echo '?')."
    note 'Подключи пользователей к новым inbound-ам: Пользователи или Группы → Inbound-ы.'
  fi
}
pick_inbound(){
  read_menu menu-all-inbounds
  if ((${#TSV_ITEMS[@]} == 0)); then tui_msg "$1" 'В панели нет inbound-ов.'; return 1; fi
  tui_menu "$1" "${2:-Выбери inbound:}" "${TSV_ITEMS[@]}"
}
# Loads "helper inbound-info" into IB_* variables.
IB_ID='' IB_KIND='' IB_LABEL='' IB_REMARK='' IB_PORT='' IB_TRANSPORT='' IB_SECURITY=''
IB_SNI='' IB_CERT='' IB_KEY='' IB_ENABLE='' IB_PROTOCOL=''
# shellcheck disable=SC2034  # IB_KIND and IB_KEY are kept for later screens
load_inbound(){
  local k v info
  info=$(helper inbound-info "$1" 2>>"$LOG") || return 1
  while IFS='=' read -r k v; do
    case "$k" in
      id) IB_ID=$v;; kind) IB_KIND=$v;; label) IB_LABEL=$v;; remark) IB_REMARK=$v;;
      port) IB_PORT=$v;; transport) IB_TRANSPORT=$v;; security) IB_SECURITY=$v;; sni) IB_SNI=$v;;
      cert) IB_CERT=$v;; key) IB_KEY=$v;; enable) IB_ENABLE=$v;; protocol) IB_PROTOCOL=$v;;
    esac
  done <<< "$info"
}
inbound_set_port(){
  local id=$1 v reason
  while :; do
    v=$(tui_input "Порт: $IB_REMARK" "Новый порт ($IB_TRANSPORT). Сейчас: $IB_PORT" "$IB_PORT") || return 0
    [[ "$v" == "$IB_PORT" ]] && return 0
    if reason=$(helper check-port "$v" "$IB_TRANSPORT" "$id" 2>&1); then break; fi
    tui_msg 'Порт недоступен' "{red}✗ $v/$IB_TRANSPORT ${reason#Ошибка: }{/}"$'\n\n'"Выбери другой порт."
  done
  if run_h "{green}✓ Порт изменён на $v/$IB_TRANSPORT.{/}" set-port "$id" "$v"; then
    open_firewall_ports "$id" || :
    note "Открой $v/$IB_TRANSPORT во внешнем файрволе провайдера. Ссылки у клиентов обновятся после обновления подписки."
  fi
}
inbound_set_name(){
  local id=$1 v reason
  while :; do
    v=$(tui_input "Название: $IB_REMARK" 'Новое название inbound-а:' "$IB_REMARK") || return 0
    [[ "$v" == "$IB_REMARK" ]] && return 0
    if reason=$(helper check-name "$v" "$id" 2>&1); then break; fi
    tui_msg 'Название недоступно' "{red}✗ «$v»: ${reason#Ошибка: }{/}"
  done
  run_h "{green}✓ Название изменено на «$v».{/}" set-name "$id" "$v" || :
}
inbound_set_sni(){
  local id=$1 how host
  how=$(tui_menu "SNI: $IB_REMARK" "Сейчас: {bold}$IB_SNI{/}" \
        auto $'Подобрать лучший для России\t{dim}проверка сайтов с этого сервера, ~30 с{/}' \
        manual 'Ввести вручную') || return 0
  if [[ "$how" == auto ]]; then
    ui_start 'Подбор SNI' 'Проверяем сайты: TLS 1.3, HTTP/2, X25519, задержка'
    msg 'Проверяем сайты: TLS 1.3, HTTP/2, X25519, задержка'
    step 30
    read_menu sni-list
    ui_stop
    if ((${#TSV_ITEMS[@]} == 0)); then tui_msg 'Подбор SNI' 'Ни один сайт не прошёл проверку — введи SNI вручную.'; return 0; fi
    host=$(tui_menu "SNI: $IB_REMARK" 'Подходящие сайты, лучшие сверху (не заблокированы в России, не за Cloudflare):' \
           "${TSV_ITEMS[@]}") || return 0
  else
    host=$(tui_input "SNI: $IB_REMARK" 'Домен чужого сайта (TLS 1.3, HTTP/2), например www.microsoft.com:' "$IB_SNI") || return 0
  fi
  [[ -n "$host" && "$host" != "$IB_SNI" ]] || return 0
  run_h "{green}✓ SNI: $host.{/} Клиентам нужно обновить подписку." set-sni "$id" "$host" || :
}
inbound_set_tls(){
  local id=$1 crt key paths
  choose_tls "$IB_REMARK" || return 0
  if [[ "$TLS_SPEC" == domain ]]; then
    paths=$(domain_cert_paths) || { tui_msg 'Сертификат' "{red}✗ Сертификат домена $DOMAIN не найден.{/}"; return 0; }
    crt=$(sed -n 1p <<< "$paths"); key=$(sed -n 2p <<< "$paths")
    run_h "{green}✓ Используется сертификат домена $DOMAIN.{/}" set-tls "$id" "$crt" "$key" "$DOMAIN" || :
  else
    IFS='|' read -r crt key paths <<< "$TLS_SPEC"
    run_h "{green}✓ Сертификат обновлён ($paths).{/}" set-tls "$id" "$crt" "$key" "$paths" || :
  fi
}
inbound_screen(){
  local id=$1 ch
  local -a items
  while :; do
    load_inbound "$id" || { note "Inbound $id не найден."; return 0; }
    items=(port $'Порт\t'"$IB_PORT/$IB_TRANSPORT" name $'Название\t'"$IB_REMARK")
    if [[ "$IB_SECURITY" == reality || "$IB_PROTOCOL" == mtproto ]]; then
      items+=(sni $'SNI\t'"$IB_SNI")
    fi
    if [[ "$IB_SECURITY" == tls ]]; then
      items+=(tls $'TLS-сертификат\t'"$(cert_label "$IB_CERT") · SNI $IB_SNI")
    fi
    if [[ "$IB_ENABLE" == 1 ]]; then items+=(toggle $'Выключить\t{dim}клиенты не смогут подключиться{/}')
    else items+=(toggle $'{green}Включить{/}'); fi
    items+=(delete '{red}Удалить inbound{/}')
    ch=$(tui_menu "$IB_REMARK" "{dim}$IB_LABEL · id $IB_ID · $([[ $IB_ENABLE == 1 ]] && echo '{green}● включён{/}' || echo '{red}○ выключен{/}'){/}" \
         "${items[@]}") || return 0
    case "$ch" in
      port) inbound_set_port "$id" ;;
      name) inbound_set_name "$id" ;;
      sni) inbound_set_sni "$id" ;;
      tls) inbound_set_tls "$id" ;;
      toggle) if [[ "$IB_ENABLE" == 1 ]]; then run_h '○ Inbound выключен.' set-enable "$id" 0 || :
              else run_h '{green}● Inbound включён.{/}' set-enable "$id" 1 || :; fi ;;
      delete)
        if tui_yesno 'Удалить inbound' "Удалить «$IB_REMARK» ($IB_PORT/$IB_TRANSPORT)?
Пользователи останутся, но потеряют это подключение." 'Удалить' 'Отмена'; then
          run_h "✓ Inbound «$IB_REMARK» удалён." del-inbound "$id" && { flush_notes; return 0; }
        fi ;;
    esac
    flush_notes
  done
}

# ---------------------------------------------------------------- TUI screens
need_panel_api(){
  if [[ "${PANEL_INSTALLED:-1}" != 1 ]]; then
    tui_msg 'Панель удалена' 'Сначала восстанови 3x-ui: Обслуживание → Переустановить 3x-ui.'
    return 1
  fi
  if ! ensure_api_token 3; then
    tui_msg 'API недоступен' 'API 3x-ui не отвечает. Проверь, что служба x-ui запущена (Состояние служб).'
    return 1
  fi
}
# run_h "message on success" helper-args… — errors from the helper go to a dialog.
run_h(){
  local ok_msg=$1 out; shift
  if out=$(helper "$@" 2>&1); then
    [[ -z "$ok_msg" ]] || note "$ok_msg"
    return 0
  fi
  tui_msg 'Ошибка' "${out#Ошибка: }"
  return 1
}
# Helper rows -> TSV_ITEMS for dialogs.
#   read_menu  CMD…  rows "tag<TAB>label…"            -> tag label …
#   read_check CMD…  rows "tag<TAB>ON|OFF<TAB>label…"  -> tag label state …
# Tabs left inside a label become aligned columns in the dialog.
TSV_ITEMS=()
read_menu(){
  local tag rest
  TSV_ITEMS=()
  while IFS=$'\t' read -r tag rest; do
    [[ -n "$tag" ]] && TSV_ITEMS+=("$tag" "$rest")
  done < <(helper "$@" 2>>"$LOG")
  return 0
}
read_check(){
  local tag st rest
  TSV_ITEMS=()
  while IFS=$'\t' read -r tag st rest; do
    [[ -n "$tag" ]] && TSV_ITEMS+=("$tag" "$rest" "$st")
  done < <(helper "$@" 2>>"$LOG")
  return 0
}
join_lines(){ paste -sd, - 2>/dev/null || :; }
# ids_names "1,3" → "RAW, MTProto"
ids_names(){
  local ids=",$1," out='' i
  read_check menu-inbounds ''
  for ((i=0; i<${#TSV_ITEMS[@]}; i+=3)); do
    if [[ "$ids" == *",${TSV_ITEMS[i]},"* ]]; then out+="${out:+, }${TSV_ITEMS[i+1]%%$'\t'*}"; fi
  done
  printf '%s' "${out:-—}"
}
with_progress(){
  # with_progress TITLE PHASE command… — a one-phase gauge around a slow action.
  local title=$1 phase=$2 rc=0; shift 2
  ui_start "$title" "$phase"
  msg "$phase"
  step 35 "$phase"
  "$@" || rc=$?
  if ((rc == 0)); then ui_stop; else ui_stop failed; fi
  return "$rc"
}

# Header shown on the main screen: domain, proxy, panel and user counters.
users_summary(){
  local stats total active expired depleted disabled online
  if [[ "${PANEL_INSTALLED:-1}" != 1 ]]; then
    printf '{dim}Пользователи: панель удалена{/}'
  elif ensure_api_token 1 && stats=$(helper stats 2>/dev/null); then
    read -r total active expired depleted disabled online <<< "$stats"
    printf '{dim}Пользователи{/} {bold}%s{/}   {green}● активных %s{/}   {red}● просроченных %s{/}   {accent}● в сети %s{/}' \
      "$total" "$active" "$expired" "$online"
    if ((depleted + disabled > 0)); then
      printf '   {dim}○ без доступа %s{/}' $((depleted + disabled))
    fi
  else
    printf '{yellow}⚠ Пользователи: нет данных — API 3x-ui не отвечает{/}'
  fi
  return 0
}
main_header(){
  local proxy xui
  if [[ "${PROXY_INSTALLED:-1}" == 1 ]]; then proxy="{green}● $PROXY{/}  {dim}HTTPS :443{/}"
  elif [[ "${TLS_MODE:-none}" == direct ]]; then proxy='{yellow}● 3x-ui{/}  {dim}HTTPS :443{/}'
  else proxy='{red}○ прокси отключён{/}'; fi
  if [[ "${PANEL_INSTALLED:-1}" != 1 ]]; then xui='{dim}○ 3x-ui удалена{/}'
  elif systemctl is-active --quiet x-ui; then xui='{green}● 3x-ui работает{/}'
  else xui='{red}✗ 3x-ui остановлена{/}'; fi
  printf '{accent}●{/} {bold}%s{/}   %s   %s\n%s' "$DOMAIN" "$proxy" "$xui" "$(users_summary)"
}

# ---- users
pick_user(){
  read_menu menu-users
  if ((${#TSV_ITEMS[@]} == 0)); then tui_msg "$1" 'Пользователей пока нет.'; return 1; fi
  tui_menu "$1" 'Выбери пользователя:' "${TSV_ITEMS[@]}"
}
user_details(){
  helper user-card "$1"
  printf '\nСсылки подписки:\n'
  print_user_links "$1" || printf '  недоступны\n'
}
inbound_checklist(){
  # inbound_checklist TITLE TEXT TARGET — prints selected ids joined by commas.
  local title=$1 text=$2 target=$3 sel
  read_check menu-inbounds "$target"
  if ((${#TSV_ITEMS[@]} == 0)); then tui_msg "$title" 'В панели нет inbound-ов.'; return 1; fi
  sel=$(tui_checklist "$title" "$text" "${TSV_ITEMS[@]}") || return 1
  printf '%s\n' "$sel" | join_lines
}
user_inbounds(){
  local email=$1 ids
  ids=$(inbound_checklist "Inbound-ы: $email" 'Отметь inbound-ы, к которым подключён пользователь:' "$email") || return 0
  run_h "✓ Inbound-ы пользователя $email обновлены." set-inbounds "$email" "$ids" || :
}
# choose_group TITLE TEXT — prints the group name ('' = without group).
choose_group(){
  local title=$1 text=$2 sel name
  read_menu menu-groups
  sel=$(tui_menu "$title" "$text" "${TSV_ITEMS[@]}" \
        '[новая]' '{accent}+ Создать новую группу…{/}' '[без группы]' '{dim}Без группы{/}') || return 1
  case "$sel" in
    '[без группы]') printf '' ;;
    '[новая]')
      name=$(tui_input 'Новая группа' 'Название группы (до 32 символов: буквы, цифры, пробел, . _ -):') || return 1
      if [[ -z "$name" ]]; then tui_msg 'Группа' 'Название не может быть пустым.'; return 1; fi
      printf '%s' "$name" ;;
    *) printf '%s' "$sel" ;;
  esac
}
pick_group(){
  read_menu menu-groups
  if ((${#TSV_ITEMS[@]} == 0)); then tui_msg "$1" 'Групп пока нет. Создай группу в этом же меню.'; return 1; fi
  tui_menu "$1" "${2:-Выбери группу:}" "${TSV_ITEMS[@]}"
}
user_group(){
  local email=$1 group
  group=$(choose_group "Группа: $email" 'Выбери группу пользователя:') || return 0
  run_h "✓ $email: группа «${group:-без группы}»." set-group "$email" "$group" || :
}
user_delete(){
  local email=$1
  tui_yesno 'Удаление пользователя' "Удалить пользователя $email из всех inbound-ов?
Его ссылки перестанут работать, статистика трафика будет удалена." 'Удалить' 'Отмена' || return 1
  run_h "✓ Пользователь $email удалён." del-user "$email"
}
user_screen(){
  local email=$1 card ch
  while :; do
    card=$(helper user-card "$email" 2>>"$LOG") || { note "Пользователь $email не найден."; return 0; }
    ch=$(tui_menu "Пользователь $email" "$(printf '%s\n' "$card" | sed -n '2,6p')" \
         1 'Подробности и ссылки подписки' \
         2 'Inbound-ы: подключить / отключить' \
         3 'Группа' \
         4 'Удалить пользователя') || return 0
    case "$ch" in
      1) tui_show "Пользователь $email" user_details "$email" ;;
      2) user_inbounds "$email" ;;
      3) user_group "$email" ;;
      4) if user_delete "$email"; then return 0; fi ;;
    esac
    flush_notes
  done
}
user_add(){
  local name gb days group ids out
  name=$(tui_input 'Новый пользователь' 'Имя: 2–64 символа — латиница, цифры, . _ @ -') || return 0
  if ! [[ "$name" =~ ^[A-Za-z0-9._@-]{2,64}$ ]]; then
    tui_msg 'Неверное имя' 'Имя: 2–64 символа — латиница, цифры, . _ @ -'; return 0
  fi
  gb=$(tui_input "Новый пользователь: $name" 'Лимит трафика в ГБ (0 — без лимита):' 0) || return 0
  if ! [[ "$gb" =~ ^[0-9]+([.][0-9]+)?$ ]]; then tui_msg 'Неверный лимит' 'Лимит — число гигабайт.'; return 0; fi
  days=$(tui_input "Новый пользователь: $name" 'Срок действия в днях (0 — бессрочно):' 0) || return 0
  if ! [[ "$days" =~ ^[0-9]{1,5}$ ]]; then tui_msg 'Неверный срок' 'Срок — целое число дней.'; return 0; fi
  group=$(choose_group "Новый пользователь: $name" 'Группа пользователя:') || return 0
  ids=$(inbound_checklist "Новый пользователь: $name" 'Inbound-ы пользователя:' managed) || return 0
  if [[ -z "$ids" ]]; then tui_msg 'Нет inbound-ов' 'Выбери хотя бы один inbound.'; return 0; fi
  if out=$(helper add-user "$name" "$gb" "$days" "$group" "$ids" 2>&1); then
    tui_show "Пользователь $name создан" user_details "$name"
  else
    tui_msg 'Ошибка' "${out#Ошибка: }"
  fi
}
menu_users(){
  need_panel_api || return 0
  local ch email
  while :; do
    ch=$(tui_menu 'Пользователи' "$(users_summary)" \
         1 'Список: группа, inbound-ы, трафик, активность' \
         2 'Открыть пользователя…' \
         3 'Добавить пользователя' \
         4 'Удалить пользователя…') || return 0
    case "$ch" in
      1) tui_show 'Пользователи' helper users "$(ui_width)" ;;
      2) if email=$(pick_user 'Открыть пользователя'); then user_screen "$email"; fi ;;
      3) user_add ;;
      4) if email=$(pick_user 'Удалить пользователя'); then user_delete "$email" || :; fi ;;
    esac
    flush_notes
  done
}

# ---- groups
group_inbounds(){
  local group mode ids label text
  group=$(pick_group 'Inbound-ы для группы' 'Для какой группы назначить inbound-ы?') || return 0
  mode=$(tui_radiolist "Группа «$group»" 'Что сделать с отмеченными inbound-ами у всех участников группы?' \
         set 'Установить ровно отмеченные (остальные отключить)' ON \
         add 'Только подключить отмеченные' OFF \
         remove 'Отключить отмеченные' OFF) || return 0
  case "$mode" in
    set) text='Inbound-ы, которые останутся у всех участников (сейчас отмечены общие для всех):'
         ids=$(inbound_checklist "Группа «$group»" "$text" "group:$group") || return 0 ;;
    add) text='Inbound-ы, которые нужно подключить всем участникам:'
         ids=$(inbound_checklist "Группа «$group»" "$text" '') || return 0 ;;
    remove) text='Inbound-ы, которые нужно отключить у всех участников:'
         ids=$(inbound_checklist "Группа «$group»" "$text" '') || return 0 ;;
    *) return 0 ;;
  esac
  if [[ -z "$ids" && "$mode" != remove ]]; then tui_msg 'Нет inbound-ов' 'Выбери хотя бы один inbound.'; return 0; fi
  if [[ -z "$ids" ]]; then return 0; fi
  case "$mode" in
    set) label='установить ровно выбранные';; add) label='подключить';; remove) label='отключить';;
  esac
  tui_yesno 'Подтверждение' "Группа: $group
Действие: $label
Inbound-ы: $(ids_names "$ids")" 'Применить' 'Отмена' yes || return 0
  run_h "✓ Группа «$group»: inbound-ы обновлены у всех участников." group-inbounds "$group" "$mode" "$ids" || :
}
group_members(){
  local group sel emails
  group=$(choose_group 'Состав группы' 'Выбери группу или создай новую:') || return 0
  if [[ -z "$group" ]]; then tui_msg 'Состав группы' 'Выбери конкретную группу.'; return 0; fi
  read_check menu-members "$group"
  if ((${#TSV_ITEMS[@]} == 0)); then tui_msg 'Состав группы' 'Пользователей пока нет.'; return 0; fi
  sel=$(tui_checklist "Группа «$group»" 'Отметь участников группы (справа — их текущая группа):' \
        "${TSV_ITEMS[@]}") || return 0
  mapfile -t emails <<< "$sel"
  run_h "✓ Состав группы «$group» обновлён." group-set-members "$group" "${emails[@]}" || :
}
menu_groups(){
  need_panel_api || return 0
  local ch group name
  while :; do
    ch=$(tui_menu 'Группы' 'Группы объединяют пользователей для массовых действий.' \
         1 'Список групп и участников' \
         2 'Назначить inbound-ы группе…' \
         3 'Состав группы…' \
         4 'Создать группу' \
         5 'Переименовать группу…' \
         6 'Удалить группу…') || return 0
    case "$ch" in
      1) tui_show 'Группы' helper groups ;;
      2) group_inbounds ;;
      3) group_members ;;
      4) if name=$(tui_input 'Новая группа' 'Название группы (до 32 символов: буквы, цифры, пробел, . _ -):'); then
           [[ -z "$name" ]] || run_h "✓ Группа «$name» создана. Добавь участников: «Состав группы»." group-create "$name" || :
         fi ;;
      5) if group=$(pick_group 'Переименовать группу') &&
            name=$(tui_input 'Переименовать группу' "Новое название для «$group»:" "$group"); then
           run_h "✓ Группа «$group» переименована в «$name»." group-rename "$group" "$name" || :
         fi ;;
      6) if group=$(pick_group 'Удалить группу') &&
            tui_yesno 'Удалить группу' "Удалить группу «$group»?
Пользователи и их inbound-ы останутся, у них просто не будет группы." 'Удалить' 'Отмена'; then
           run_h "✓ Группа «$group» удалена." group-delete "$group" || :
         fi ;;
    esac
    flush_notes
  done
}

# ---- inbounds
inbounds_screen_text(){
  helper inbounds --compact 2>/dev/null || printf '  нет данных'
  return 0
}
firewall_ports_text(){
  local port proto remark
  while read -r port proto remark; do
    [[ -n "$port" ]] && printf '  {bold}%-6s{/} {accent}%s{/}  {dim}%s{/}\n' "$port" "$proto" "$remark"
  done < <(helper ports-all 2>/dev/null)
  return 0
}
menu_inbounds(){
  need_panel_api || return 0
  local ch list id
  while :; do
    ch=$(tui_menu 'Inbound-ы' "$(inbounds_screen_text)" \
         add $'Добавить inbound-ы\t{dim}10 типов: VLESS, Trojan, Hysteria2, AmneziaWG, MTProto{/}' \
         edit $'Изменить inbound\t{dim}порт, название, SNI, TLS, вкл/выкл, удалить{/}' \
         list 'Подробный список' \
         ports 'Порты для внешнего файрвола') || return 0
    case "$ch" in
      add) inbound_add ;;
      edit) if id=$(pick_inbound 'Изменить inbound'); then inbound_screen "$id"; fi ;;
      list) tui_show 'Inbound-ы панели' helper inbounds "$(ui_width)" ;;
      ports)
        list=$(firewall_ports_text)
        tui_msg 'Порты inbound-ов' "Порты всех включённых inbound-ов — их нужно открыть во внешнем файрволе провайдера:

${list:-  нет данных}

Скрипт сам открывает порты только в уже включённом ufw/firewalld." ;;
    esac
    flush_notes
  done
}

# ---- panel settings (were items 3–7)
menu_settings(){
  local ch v olduser oldpass
  while :; do
    ch=$(tui_menu 'Настройки панели' "Порт панели: $PANEL_PORT    Путь: /$PANEL_PATH/
Порт подписок: $SUB_PORT    Путь подписок: /$SUB_PATH/" \
         1 'Изменить порт панели' \
         2 'Изменить путь панели' \
         3 'Изменить логин и пароль' \
         4 'Изменить порт подписок' \
         5 'Изменить путь подписок') || return 0
    if [[ "${PANEL_INSTALLED:-1}" != 1 ]]; then
      tui_msg 'Панель удалена' 'Восстанови её: Обслуживание → Переустановить 3x-ui.'; continue
    fi
    if [[ "${PROXY_INSTALLED:-1}" != 1 ]]; then
      tui_msg 'Нет прокси' 'Для изменения настроек сначала верни прокси: Обслуживание → Переустановить прокси.'; continue
    fi
    case "$ch" in
      1)
        v=$(tui_input 'Порт панели' 'Новый порт панели (пусто — случайный):' '') || continue
        v=${v:-$(newport)}
        if ! valid_port "$v" || [[ "$v" == "$SUB_PORT" ]]; then tui_msg 'Ошибка' 'Неверный порт.'; continue; fi
        if [[ -n $(ss -H -ltn "sport = :$v") && "$v" != "$PANEL_PORT" ]]; then tui_msg 'Ошибка' 'Порт занят.'; continue; fi
        PANEL_PORT=$v
        with_progress 'Порт панели' 'Применяем порт и проверяем панель' transaction_change || warn 'Изменение отменено.'
        load_state ;;
      2)
        v=$(tui_input 'Путь панели' 'Новый путь панели без / (пусто — случайный):' '') || continue
        v=${v:-panel$(rand 18)}
        if ! valid_path "$v" || [[ "$v" == "$SUB_PATH" || "$v" == "$JSON_PATH" || "$v" == "$CLASH_PATH" ]]; then
          tui_msg 'Ошибка' 'Путь: 6–64 символа a-z A-Z 0-9 _ -'; continue
        fi
        PANEL_PATH=$v
        with_progress 'Путь панели' 'Применяем путь и проверяем панель' transaction_change || warn 'Изменение отменено.'
        load_state ;;
      3)
        olduser=$PANEL_USER; oldpass=$PANEL_PASS
        v=$(tui_input 'Логин панели' 'Новый логин, 6–48 символов (пусто — случайный):' '') || continue
        PANEL_USER=${v:-u$(rand 12)}
        if ! [[ "$PANEL_USER" =~ ^[a-zA-Z0-9_-]{6,48}$ ]]; then
          PANEL_USER=$olduser; tui_msg 'Ошибка' 'Логин: 6–48 символов a-z A-Z 0-9 _ -'; continue
        fi
        v=$(tui_input 'Пароль панели' 'Новый пароль, от 12 символов (пусто — случайный):' '') || { PANEL_USER=$olduser; continue; }
        PANEL_PASS=${v:-$(rand 28)}
        if ! [[ ${#PANEL_PASS} -ge 12 && "$PANEL_PASS" =~ ^[a-zA-Z0-9_-]+$ ]]; then
          PANEL_USER=$olduser; PANEL_PASS=$oldpass; tui_msg 'Ошибка' 'Пароль: от 12 символов a-z A-Z 0-9 _ -'; continue
        fi
        if with_progress 'Логин и пароль' 'Применяем учётные данные' rotate_credentials; then
          note "Логин:  $PANEL_USER"
          note "Пароль: $PANEL_PASS"
        else
          warn 'Учётные данные не изменены.'
        fi
        load_state ;;
      4)
        v=$(tui_input 'Порт подписок' 'Новый порт подписок (пусто — случайный):' '') || continue
        v=${v:-$(newport)}
        if ! valid_port "$v" || [[ "$v" == "$PANEL_PORT" ]]; then tui_msg 'Ошибка' 'Неверный порт.'; continue; fi
        if [[ -n $(ss -H -ltn "sport = :$v") && "$v" != "$SUB_PORT" ]]; then tui_msg 'Ошибка' 'Порт занят.'; continue; fi
        SUB_PORT=$v
        with_progress 'Порт подписок' 'Применяем порт и проверяем подписки' transaction_change || warn 'Изменение отменено.'
        load_state ;;
      5)
        v=$(tui_input 'Путь подписок' 'Новый путь подписок без / (пусто — случайный):' '') || continue
        v=${v:-sub$(rand 19)}
        if ! valid_path "$v" || [[ "$v" == "$PANEL_PATH" || "$v" == "$JSON_PATH" || "$v" == "$CLASH_PATH" ]]; then
          tui_msg 'Ошибка' 'Путь: 6–64 символа a-z A-Z 0-9 _ -'; continue
        fi
        SUB_PATH=$v
        with_progress 'Путь подписок' 'Применяем путь и проверяем подписки' transaction_change || warn 'Изменение отменено.'
        load_state ;;
    esac
    flush_notes 'Настройки панели'
  done
}

# ---- maintenance (were items 8–11)
restart_services(){
  ui_start 'Перезапуск служб' 'Перезапускаем 3x-ui' 'Перезапускаем прокси' 'Проверяем состояние'
  msg 'Перезапускаем 3x-ui'
  if [[ "${PANEL_INSTALLED:-1}" == 1 ]] && ! run systemctl restart x-ui; then
    ui_stop failed; warn 'Ошибка запуска 3x-ui.'; return 1
  fi
  step 40 '3x-ui запущена'
  msg 'Перезапускаем прокси'
  if [[ "${PROXY_INSTALLED:-1}" == 1 ]] && ! reload_proxy; then
    ui_stop failed; warn 'Ошибка прокси.'; return 1
  fi
  step 75 'Прокси проверен'
  msg 'Проверяем состояние'
  step 100 'Службы перезапущены'
  ui_stop
  note '✓ Службы перезапущены.'
}
edit_proxy_config(){
  if [[ "${PROXY_INSTALLED:-1}" != 1 ]]; then tui_msg 'Нет прокси' 'Прокси не установлен.'; return 0; fi
  tui_yesno 'Редактирование' "Откроется редактор для $(proxy_conf).
После выхода конфигурация будет проверена и применена." 'Открыть' 'Отмена' yes || return 0
  local editor=${EDITOR:-}
  [[ -n "$editor" ]] || editor=$(command -v nano || command -v vi || echo vi)
  tui_suspend
  "$editor" "$(proxy_conf)" </dev/tty >/dev/tty 2>&1 || :
  tui_resume
  if validate_proxy && reload_proxy; then
    note '✓ Конфигурация прокси проверена и применена.'
  else
    warn 'Конфигурация некорректна и не применена; исправь её (журнал: '"$LOG"').'
  fi
}
menu_service(){
  local ch
  while :; do
    ch=$(tui_menu 'Обслуживание' 'Перезапуск, ручная правка и переустановка компонентов.' \
         1 'Перезапустить службы' \
         2 'Редактировать конфигурацию прокси' \
         3 'Переустановить 3x-ui (данные сохраняются)' \
         4 "Переустановить прокси ($PROXY)" \
         bbr "BBR + CAKE"$'\t'"$(bbr_active && echo '{green}● включено{/}' || echo "{dim}○ $(bbr_label){/}")") || return 0
    case "$ch" in
      1) restart_services || : ;;
      2) edit_proxy_config ;;
      3) reinstall_panel || warn 'Переустановка панели не завершена.'; load_state ;;
      4) reinstall_proxy || warn 'Переустановка прокси не завершена.'; load_state ;;
      bbr) menu_bbr ;;
    esac
    flush_notes 'Обслуживание'
  done
}

# ---- removal (were items 12–15)
menu_remove(){
  local ch
  while :; do
    ch=$(tui_menu 'Удаление' 'Каждое действие запросит отдельное подтверждение.' \
         1 "Удалить прокси $PROXY (опционально перенести HTTPS на 3x-ui)" \
         2 'Удалить 3x-ui (резервная копия базы сохранится)' \
         3 'Полностью удалить 3x-ui, прокси и все данные' \
         4 'Удалить только команду 3x-ui_reverse') || return 0
    case "$ch" in
      1) remove_proxy_only || warn 'Удаление прокси не завершено.'; load_state ;;
      2) remove_panel_only || warn 'Удаление 3x-ui не завершено.'; load_state ;;
      3) uninstall_all || : ;;
      4) if remove_manager_command; then exit 0; fi ;;
    esac
    flush_notes 'Удаление'
  done
}

# ---- Nodes: this panel as a master, or this server as a node of another one.
# The master reaches a node's panel through the node's own HTTPS proxy:
# https://DOMAIN/PANEL_PATH/panel/api/… with a node-sync API token.
PAIR_DIR=''        # pairing file published by this session (removed on exit)

# The node-sync token for a master panel. 3x-ui stores only a hash, so the
# plaintext is kept in $NODE_TOKEN (0600) and created on first use.
node_api_token(){
  [[ "${PANEL_INSTALLED:-1}" == 1 ]] || return 1
  if [[ -s "$NODE_TOKEN" ]]; then
    # Shown as stored unless the panel says it is gone (e.g. 3x-ui reinstalled).
    if ! ensure_api_token 1 >/dev/null 2>&1 || helper node-token-check >/dev/null 2>&1; then
      cat -- "$NODE_TOKEN"; return 0
    fi
  fi
  ensure_api_token 3 || return 1
  local t
  t=$(helper node-token-create) || return 1
  [[ -n "$t" ]] || return 1
  ( umask 077; printf '%s\n' "$t" > "$NODE_TOKEN" )
  printf '%s\n' "$t"
}
node_token_rotate(){
  ensure_api_token 3 || return 1
  local t
  t=$(helper node-token-create) || return 1
  ( umask 077; printf '%s\n' "$t" > "$NODE_TOKEN" )
}

# Removes the pairing file of this session and any expired leftovers.
pair_revoke(){
  local d exp now keep=''
  if [[ -n "${PAIR_DIR:-}" ]]; then rm -rf -- "$PAIR_DIR" 2>/dev/null || :; fi
  if [[ -f "$PAIR_ACTIVE" ]]; then
    now=$(date +%s)
    while read -r d exp; do
      [[ -n "$d" ]] || continue
      if [[ "$d" == "${PAIR_DIR:-//}" || ! "${exp:-0}" =~ ^[0-9]+$ ]] || ((exp < now)); then
        [[ "$d" == "$SITE"/* && "$d" != *..* ]] && rm -rf -- "$d" 2>/dev/null
      else
        keep+="$d $exp"$'\n'
      fi
    done < "$PAIR_ACTIVE" || :
    if [[ -n "$keep" ]]; then printf '%s' "$keep" > "$PAIR_ACTIVE" 2>/dev/null || :
    else rm -f -- "$PAIR_ACTIVE" 2>/dev/null || :; fi
  fi
  PAIR_DIR=''
  return 0
}

# Node side: show a one-time token; the master downloads the encrypted
# connection details from the stub site while this screen is open.
node_pair_screen(){
  if [[ "${PANEL_INSTALLED:-1}" != 1 ]]; then
    tui_msg 'Токен подключения' 'Панель 3x-ui на этом сервере удалена — подключать нечего.'
    return 0
  fi
  if [[ "${PROXY_INSTALLED:-1}" != 1 || ! -d "$SITE" ]]; then
    tui_msg 'Токен подключения' "Автоматическое подключение идёт через сайт-заглушку, а веб-сервер на этом VPS удалён.

Подключи узел вручную: адрес панели и API-токен узла есть в «Параметры и ссылки»."
    return 0
  fi
  if ! node_api_token >/dev/null 2>>"$LOG"; then
    tui_msg 'Токен подключения' '{red}Не удалось получить API-токен узла.{/} Проверь, что служба x-ui запущена («Состояние служб»).'
    return 0
  fi
  pair_revoke
  local out token dir file exp tmp rc
  if ! out=$(helper pair-publish "$SITE" "$DOMAIN" 443 "/$PANEL_PATH/" "$NODE_TOKEN" 2>>"$LOG"); then
    tui_msg 'Токен подключения' '{red}Не удалось выпустить токен.{/} Подробности в журнале.'
    return 0
  fi
  read -r token dir file exp <<< "$out"
  PAIR_DIR=$dir
  ( umask 077; printf '%s %s\n' "$dir" "$exp" >> "$PAIR_ACTIVE" )
  # Safety net if this session is killed without running its exit trap.
  if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --quiet --collect --on-active=$(( exp - $(date +%s) + 30 )) \
      /bin/rm -rf -- "$dir" >/dev/null 2>&1 || :
  fi
  tmp=$(mktemp "${UI_DIR:-${TMPDIR:-/tmp}}/pair.XXXXXXXX")
  cat > "$tmp" <<EOF
{bold}Подключение этого сервера к мастер-панели{/}

  Домен узла    {green}$DOMAIN{/}
  Токен         {yellow}$token{/}

На мастере открой {accent}3x-ui_reverse → Подключить узел → Автоматически{/}
и введи домен и токен.

{dim}Токен одноразовый и действует, пока открыт этот экран (не дольше 30 минут).
Он не связан с 3x-ui: по нему мастер один раз получит адрес и путь панели
и API-токен узла. После закрытия экрана токен не сработает.{/}
EOF
  copy_item 'домен' "$DOMAIN"
  copy_item 'токен' "$token"
  TUI_WATCH=$file TUI_EXPIRES=$exp tui_textfile 'Токен подключения узла' "$tmp"
  rc=$UI_RC
  rm -f -- "$tmp"
  pair_revoke
  case "$rc" in
    3) tui_msg 'Токен использован' "{green}✓ Мастер-панель получила данные подключения.{/}

Токен удалён и повторно не сработает. Проверь узел на мастере: «Подключить узел» → «Подключённые узлы»." ;;
    4) tui_msg 'Токен недействителен' '{yellow}⚠ Срок действия токена истёк.{/} Выдай новый, когда будешь готов подключать узел.' ;;
    *) note '○ Токен подключения отозван.' ;;
  esac
}

node_addr_text(){   # scheme address port path -> URL
  local port_part=''
  [[ "$3" == 443 ]] || port_part=":$3"
  printf '%s://%s%s%s' "$1" "$2" "$port_part" "$4"
}

# Master side, automatic: domain + one-time token issued on the node.
node_add_auto(){
  need_panel_api || return 0
  local domain token out bundle name address port path country nname
  domain=$(tui_input 'Подключить узел' 'Домен узла — показан на узле рядом с токеном:' '') || return 0
  domain=${domain,,}; domain=${domain#http://}; domain=${domain#https://}; domain=${domain%%/*}; domain=${domain%.}
  if ! valid_domain "$domain"; then
    tui_msg 'Неверный домен' "«$domain» — не доменное имя. Введи домен узла, например node.example.com."
    return 0
  fi
  token=$(tui_input 'Подключить узел' "Токен подключения узла $domain.

{dim}На узле: 3x-ui_reverse → Подключить узел → Выдать токен подключения.
Регистр и дефисы не важны.{/}" '') || return 0
  bundle=$(mktemp "${UI_DIR:-${TMPDIR:-/tmp}}/node.XXXXXXXX")
  chmod 600 "$bundle"
  if ! out=$(helper pair-fetch "$domain" "$token" "$bundle" 2>&1); then
    rm -f -- "$bundle"
    tui_msg 'Узел не ответил' "{red}✗ ${out#Ошибка: }{/}"
    return 0
  fi
  address=$(sed -n 's/^address=//p' <<< "$out"); port=$(sed -n 's/^port=//p' <<< "$out")
  path=$(sed -n 's/^basePath=//p' <<< "$out"); nname=$(sed -n 's/^name=//p' <<< "$out")
  country=$(sed -n 's/^country=//p' <<< "$out")
  name=$(helper node-name "${nname:-$address}" 2>>"$LOG") || name=${nname:-$address}
  name=$(tui_input 'Имя узла' "{green}✓ Данные узла получены, токен на узле погашен.{/}

  Панель узла   {accent}$(node_addr_text https "$address" "$port" "$path"){/}
  Страна        ${country:-—}

Имя узла в этой панели:" "$name") || { rm -f -- "$bundle"; return 0; }
  node_add_finish --from "$bundle" --name "$name"
  rm -f -- "$bundle"
}

# Master side, manual: panel URL + API token of the node.
node_add_manual(){
  need_panel_api || return 0
  local url out address token name
  url=$(tui_input 'Подключить узел вручную' "Адрес панели узла, например {accent}https://node.example.com/AbCd1234/{/}

{dim}На узле с 3x-ui_reverse он в «Параметры и ссылки» → «Адрес панели».{/}" '') || return 0
  if ! out=$(helper parse-url "$url" 2>&1); then
    tui_msg 'Неверный адрес' "{red}✗ ${out#Ошибка: }{/}"
    return 0
  fi
  address=$(sed -n 's/^address=//p' <<< "$out")
  token=$(tui_input 'API-токен узла' "API-токен панели узла.

{dim}На узле с 3x-ui_reverse: «Параметры и ссылки» → «API-токен узла».
В обычной 3x-ui: Настройки → Безопасность → API-токены (область node-sync).{/}" '') || return 0
  token=${token//[[:space:]]/}
  [[ -n "$token" ]] || { tui_msg 'API-токен узла' 'Токен не введён — узел не подключён.'; return 0; }
  name=$(helper node-name "$address" 2>>"$LOG") || name=$address
  name=$(tui_input 'Имя узла' 'Имя узла в этой панели:' "$name") || return 0
  XR_NODE_API_TOKEN=$token node_add_finish --url "$url" --name "$name"
}

node_add_finish(){
  local out ch
  while :; do
    if out=$(helper node-add "$@" 2>&1); then
      local id nm st ver lat
      id=$(sed -n 's/^id=//p' <<< "$out"); nm=$(sed -n 's/^name=//p' <<< "$out")
      st=$(sed -n 's/^status=//p' <<< "$out"); ver=$(sed -n 's/^version=//p' <<< "$out")
      lat=$(sed -n 's/^latency=//p' <<< "$out")
      tui_msg 'Узел подключён' "{green}✓ Узел «$nm» подключён{/} (id $id).

  Состояние    $(if [[ $st == online ]]; then echo "{green}● в сети{/}${lat:+ · $lat мс}"; else echo '{yellow}◌ проверяется{/} — обнови список через несколько секунд'; fi)
  3x-ui        ${ver:-—}

Inbound-ы узла появятся в этой панели после первой синхронизации."
      return 0
    fi
    ch=$(tui_menu 'Узел не подключён' "{red}✗ ${out#Ошибка: }{/}" \
         retry 'Повторить' \
         cancel 'Отмена') || return 0
    [[ "$ch" == retry ]] || return 0
  done
}

nodes_header(){
  local total=0 online=0
  read -r total online < <(helper nodes-count 2>>"$LOG" || echo '0 0')
  printf 'Узлы — другие серверы с 3x-ui, которыми управляет эта панель.\n'
  if ((total > 0)); then
    printf 'Подключено: {bold}%s{/}, в сети: {green}%s{/}\n' "$total" "$online"
  else
    printf '{dim}Подключённых узлов пока нет.{/}\n'
  fi
}

node_screen(){
  local id=$1 card ch name enable
  while :; do
    card=$(helper node-card "$id" 2>>"$LOG") || { tui_msg 'Узел' 'Узел не найден — возможно, он уже удалён.'; return 0; }
    name=$(sed -n 's/^#name=//p' <<< "$card"); enable=$(sed -n 's/^#enable=//p' <<< "$card")
    card=$(grep -v '^#' <<< "$card")
    local -a toggle=(on $'Включить\t{dim}возобновить синхронизацию{/}')
    [[ "$enable" == 1 ]] && toggle=(off $'Выключить\t{dim}приостановить синхронизацию{/}')
    ch=$(tui_menu "Узел: $name" "$card" \
         probe $'Проверить связь\t{dim}запрос к панели узла{/}' \
         "${toggle[@]}" \
         del $'{red}Удалить узел{/}\t{dim}из этой панели; сам узел не меняется{/}') || return 0
    case "$ch" in
      probe)
        local out st err
        out=$(helper node-probe "$id" 2>&1) || { tui_msg 'Проверка' "{red}✗ ${out#Ошибка: }{/}"; continue; }
        st=$(sed -n 's/^status=//p' <<< "$out"); err=$(sed -n 's/^error=//p' <<< "$out")
        if [[ "$st" == online ]]; then tui_msg 'Проверка' "{green}✓ Узел отвечает{/} ($(sed -n 's/^latency=//p' <<< "$out") мс)."
        else tui_msg 'Проверка' "{red}✗ Узел недоступен{/}${err:+: $err}"; fi ;;
      on|off)
        helper node-enable "$id" "$([[ $ch == on ]] && echo 1 || echo 0)" 2>>"$LOG" \
          || tui_msg 'Ошибка' 'Не удалось изменить состояние узла.' ;;
      del)
        if tui_yesno 'Удалить узел' "Удалить узел «$name» из этой панели?

Сам сервер узла и его inbound-ы не изменятся; inbound-ы, привязанные к узлу в этой панели, не переносятся." 'Удалить' 'Отмена' no; then
          helper node-del "$id" 2>>"$LOG" && { note "✓ Узел «$name» удалён."; return 0; }
          tui_msg 'Ошибка' 'Не удалось удалить узел.'
        fi ;;
    esac
  done
}

menu_nodes_list(){
  local id first=1
  while :; do
    read_menu menu-nodes
    if ((${#TSV_ITEMS[@]} == 0)); then
      ((first)) && tui_msg 'Подключённые узлы' 'Узлов пока нет. Подключи первый: «Автоматически» или «Вручную».'
      return 0
    fi
    first=0
    id=$(tui_menu 'Подключённые узлы' 'Выбери узел:' "${TSV_ITEMS[@]}") || return 0
    node_screen "$id"
    flush_notes
  done
}

menu_nodes(){
  local ch
  ensure_api_token 3 >/dev/null 2>&1 || :
  while :; do
    ch=$(tui_menu 'Подключить узел' "$(nodes_header)" \
         '#Подключить узел к этой панели' '' \
         auto $'Автоматически\t{dim}домен и одноразовый токен с узла{/}' \
         manual $'Вручную\t{dim}адрес панели и API-токен узла{/}' \
         list $'Подключённые узлы\t{dim}состояние, проверка, удаление{/}' \
         '#Этот сервер как узел' '' \
         pair $'Выдать токен подключения\t{dim}действует, пока открыт экран{/}' \
         rotate $'Перевыпустить API-токен узла\t{dim}старый перестанет работать{/}') || return 0
    case "$ch" in
      auto) node_add_auto ;;
      manual) node_add_manual ;;
      list) need_panel_api && menu_nodes_list ;;
      pair) node_pair_screen ;;
      rotate)
        if tui_yesno 'API-токен узла' 'Выпустить новый API-токен узла?

Мастер-панель, к которой этот сервер уже подключён, потеряет к нему доступ — подключи узел на мастере заново.' 'Перевыпустить' 'Отмена' no; then
          if node_token_rotate 2>>"$LOG"; then note '✓ Новый API-токен узла — в «Параметры и ссылки».'
          else warn 'Не удалось перевыпустить API-токен узла.'; fi
        fi ;;
    esac
    flush_notes
  done
}

# ---- Network tuning: TCP BBR + CAKE
BBR_SYSCTL=/etc/sysctl.d/90-3x-ui_reverse-bbr.conf
BBR_MODULES=/etc/modules-load.d/3x-ui_reverse-bbr.conf

bbr_now(){       # "congestion_control qdisc"
  printf '%s %s' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')" \
                  "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
}
bbr_active(){
  local cc q
  read -r cc q <<< "$(bbr_now)"
  [[ "$cc" == bbr && "$q" == cake ]]
}
bbr_label(){
  local cc q
  read -r cc q <<< "$(bbr_now)"
  if [[ "$cc" == bbr && "$q" == cake ]]; then printf 'BBR + CAKE'
  elif [[ "$cc" == bbr ]]; then printf 'BBR + %s' "$q"
  else printf '%s + %s' "$cc" "$q"; fi
}
default_iface(){
  ip -o -4 route show default 2>/dev/null |
    awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
}
bbr_enable(){
  local qdisc=cake iface
  modprobe tcp_bbr >>"$LOG" 2>&1 || :
  modprobe sch_cake >>"$LOG" 2>&1 || :
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    warn 'Ядро не поддерживает TCP BBR — ускорение сети не включено.'
    return 1
  fi
  if ! sysctl -w net.core.default_qdisc=cake >>"$LOG" 2>&1; then
    qdisc=fq                    # kernel without sch_cake: fq is BBR's classic pair
    sysctl -w net.core.default_qdisc=fq >>"$LOG" 2>&1 || :
  fi
  if ! sysctl -w net.ipv4.tcp_congestion_control=bbr >>"$LOG" 2>&1; then
    warn 'Не удалось включить BBR: ядро VPS недоступно для настройки (контейнерная виртуализация?).'
    return 1
  fi
  printf 'tcp_bbr\n%s\n' "$([[ $qdisc == cake ]] && echo sch_cake || echo sch_fq)" > "$BBR_MODULES"
  cat > "$BBR_SYSCTL" <<EOF
# Managed by 3x-ui_reverse: TCP BBR congestion control + $qdisc queueing.
net.core.default_qdisc = $qdisc
net.ipv4.tcp_congestion_control = bbr
EOF
  chmod 644 "$BBR_MODULES" "$BBR_SYSCTL"
  # default_qdisc only affects new queues: replace the running one too.
  iface=$(default_iface)
  if [[ -n "$iface" ]]; then
    tc qdisc replace dev "$iface" root "$qdisc" >>"$LOG" 2>&1 ||
      printf 'tc: %s остался на прежней очереди (применится после перезагрузки)\n' "$iface" >>"$LOG"
  fi
  [[ $qdisc == cake ]] || warn 'CAKE недоступен в ядре — включены BBR + fq.'
  return 0
}
bbr_disable(){
  local iface
  rm -f -- "$BBR_SYSCTL" "$BBR_MODULES"
  sysctl -w net.ipv4.tcp_congestion_control=cubic >>"$LOG" 2>&1 || :
  sysctl -w net.core.default_qdisc=fq_codel >>"$LOG" 2>&1 || :
  iface=$(default_iface)
  # Deleting the root qdisc makes the kernel recreate its default (fq_codel/mq).
  [[ -n "$iface" ]] && { tc qdisc del dev "$iface" root >>"$LOG" 2>&1 || :; }
  return 0
}
bbr_question_text(){
  printf '%s' "Включить TCP BBR + CAKE?

{bold}BBR{/} — алгоритм управления перегрузкой от Google: выше скорость и ниже задержки
на каналах с потерями пакетов (типично для подключений из России).
{bold}CAKE{/} — умная очередь пакетов: убирает «раздувание буфера» и лаги под нагрузкой.

Сейчас: {accent}$(bbr_label){/}"
}
menu_bbr(){
  if bbr_active; then
    tui_yesno 'BBR + CAKE' "{green}● Включены TCP BBR + CAKE.{/}

Выключить и вернуть стандартные cubic + fq_codel?" 'Выключить' 'Назад' no || return 0
    bbr_disable
    note "○ BBR + CAKE выключены: сейчас $(bbr_label)."
  else
    tui_yesno 'BBR + CAKE' "$(bbr_question_text)" 'Включить' 'Назад' yes || return 0
    if bbr_enable; then note "{green}✓ Включено: $(bbr_label).{/}"; fi
  fi
}

# ---- PDF with the server parameters
pdf_ready(){ python3 -c 'import reportlab' >/dev/null 2>&1; }
pdf_install_deps(){
  pdf_ready && return 0
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y python3-reportlab fonts-dejavu-core
}
server_ip_label(){
  local ip
  ip=$(ip -4 -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
  case "$ip" in ''|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) ip='' ;; esac
  printf '%s' "$ip"
}
# write_pdf [quiet] — $PDF_FILE from the current state; returns 1 if impossible.
write_pdf(){
  [[ -d "$BASE" ]] || return 1
  pdf_ready || return 1
  local data panel_url='' certpath proxy_line proxy_label tls_label country ip sid ntoken sbase rc=0
  data=$(mktemp "${UI_DIR:-${TMPDIR:-/tmp}}/pdf.XXXXXXXX")
  chmod 600 "$data"
  if [[ "${PROXY_INSTALLED:-1}" == 1 ]]; then
    certpath=$(certdir); proxy_line="${PROXY^} (установлен)"; proxy_label="${PROXY^} · HTTPS :443"
    tls_label="Let's Encrypt"
  elif [[ "${TLS_MODE:-none}" == direct ]]; then
    certpath="/root/cert/$DOMAIN"; proxy_line='не используется — HTTPS у 3x-ui'; proxy_label='Прямой HTTPS'
    tls_label='acme.sh'
  else
    certpath='нет'; proxy_line='удалён'; proxy_label='Без прокси'; tls_label=''
  fi
  [[ "${PANEL_INSTALLED:-1}" == 1 && ( "${PROXY_INSTALLED:-1}" == 1 || "${TLS_MODE:-none}" == direct ) ]] &&
    panel_url="https://$DOMAIN/$PANEL_PATH/"
  country=$(helper country 2>/dev/null || :)
  ip=$(server_ip_label)
  {
    printf 'domain\t%s\nversion\t%s\ndate\t%s\n' "$DOMAIN" "$VERSION" "$(date '+%d.%m.%Y %H:%M')"
    printf 'proxy_label\t%s\ntls_label\t%s\nproxy_line\t%s\ncertpath\t%s\n' \
      "$proxy_label" "$tls_label" "$proxy_line" "$certpath"
    [[ -n "$country$ip" ]] && printf 'server_label\t%s\n' "${country}${country:+${ip:+ · }}${ip}"
    [[ "$(bbr_now)" == bbr\ * ]] && printf 'bbr_label\t%s\n' "$(bbr_label)"
    if [[ -n "$panel_url" ]]; then
      printf 'panel_url\t%s\nuser\t%s\npass\t%s\nport\t%s\n' "$panel_url" "$PANEL_USER" "$PANEL_PASS" "$PANEL_PORT"
      ntoken=$(node_api_token 2>>"$LOG") && printf 'node_token\t%s\n' "$ntoken"
      printf 'sub\t/%s/\njson\t/%s/\nclash\t/%s/\n' "$SUB_PATH" "$JSON_PATH" "$CLASH_PATH"
      sbase=$(sub_base)
      if [[ -n "$sbase" ]] && sid=$(helper sub-id user1 2>/dev/null) && [[ -n "$sid" ]]; then
        printf 'user1_sub\t%s\nuser1_json\t%s\nuser1_clash\t%s\n' \
          "$sbase/$SUB_PATH/$sid" "$sbase/$JSON_PATH/$sid" "$sbase/$CLASH_PATH/$sid"
      fi
    fi
  } > "$data"
  helper pdf "$PDF_FILE" "$data" >>"$LOG" 2>&1 || rc=1
  rm -f -- "$data"
  return "$rc"
}
pdf_download_hint(){
  local host=${DOMAIN:-IP_СЕРВЕРА}
  printf 'scp root@%s:%s .' "$host" "$PDF_FILE"
}
pdf_screen(){
  if ! pdf_ready; then
    tui_yesno 'PDF с параметрами' 'Для PDF нужны пакеты python3-reportlab и fonts-dejavu-core (≈10 МБ). Установить?' \
      'Установить' 'Отмена' yes || return 0
    with_progress 'PDF' 'Устанавливаем python3-reportlab и шрифты' pdf_install_deps ||
      { tui_msg 'PDF' '{red}Не удалось установить пакеты.{/} Подробности в журнале.'; return 0; }
  fi
  if ! with_progress 'PDF' 'Формируем PDF' write_pdf; then
    tui_msg 'PDF' "{red}Не удалось сформировать PDF.{/} Подробности: $LOG"
    return 0
  fi
  local tmp
  tmp=$(mktemp "${UI_DIR:-${TMPDIR:-/tmp}}/pdfmsg.XXXXXXXX")
  cat > "$tmp" <<EOF
{green}✓ PDF обновлён{/}

  Файл        {accent}$PDF_FILE{/}  (chmod 600)

Скачать на свой компьютер (команда для терминала компьютера):
  {yellow}$(pdf_download_hint){/}

{dim}В файле пароль и токены — не пересылай его посторонним.
PDF обновляется сам при смене логина, пароля, портов и путей.{/}
EOF
  copy_item 'путь к PDF' "$PDF_FILE"
  copy_item 'команда scp' "$(pdf_download_hint)"
  tui_textfile 'PDF с параметрами' "$tmp"
  rm -f -- "$tmp"
}

# ---- First run: nothing installed yet
# $BASE must not exist until the user confirms the install, so until then the
# helper, its cache and the diagnostic log live in the temporary UI dir.
PRE_ENV=0 HELPER_FINAL='' LOG_FINAL=''
preinstall_env(){
  ((PRE_ENV)) && return 0
  HELPER_FINAL=$HELPER; LOG_FINAL=$LOG
  HELPER=$UI_DIR/xr_helper.py
  HELPER_STATE=$UI_DIR
  LOG=$UI_DIR/install.log
  : >"$LOG"
  write_helper
  PRE_ENV=1
}
preinstall_commit(){        # $BASE now exists: move log and cache there
  ((PRE_ENV)) || return 0
  install -m 600 /dev/null "$LOG_FINAL"
  cat "$LOG" >>"$LOG_FINAL" 2>/dev/null || :
  [[ -s "$UI_DIR/country.txt" ]] && install -m 600 "$UI_DIR/country.txt" "$BASE/country.txt"
  LOG=$LOG_FINAL; HELPER=$HELPER_FINAL; HELPER_STATE=''
  PRE_ENV=0
}
ENV_CHECKED=0
first_run_prepare(){
  ((ENV_CHECKED)) && return 0
  tui_init || die 'Нужен интерактивный терминал (и python3).'
  check_environment
  preinstall_env
  ENV_CHECKED=1
}
dns_standalone(){
  local entered=${DOMAIN:-}
  while :; do
    entered=$(TUI_LOGO=1 tui_input 'Проверка DNS' 'Домен для проверки (например, panel.example.com):' "$entered") || return 0
    entered=${entered,,}; entered=${entered%.}; entered=${entered#http://}; entered=${entered#https://}; entered=${entered%%/*}
    valid_domain "$entered" && break
    tui_msg 'Неверный домен' 'Введи корректное DNS-имя: не IP-адрес, не URL и без порта.'
  done
  DOMAIN=$entered DNS_MODE=standalone dns_check_screen || :
  DOMAIN=''
}
start_menu(){
  first_run_prepare
  local ch os
  os=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-Linux}")
  while :; do
    ch=$(TUI_LOGO=1 TUI_CANCEL='Выход' tui_menu '3x-ui_reverse' "Сервер ещё не настроен.
{dim}$os · $(hostname 2>/dev/null || echo VPS){/}" \
         install $'Установить 3x-ui + прокси\t{dim}Caddy или Nginx, HTTPS, сайт-заглушка{/}' \
         dns $'Проверить DNS-записи\t{dim}куда указывает домен в 16 DNS мира{/}' \
         diag $'Диагностика сервера\t{dim}iPerf3 до РФ, IP Region, Censorcheck DPI{/}' \
         multitest $'Multitest by @saveksme\t{dim}полный набор тестов сервера{/}' \
         quit '{dim}Выход{/}') || return 0
    case "$ch" in
      install)
        if install_fresh && [[ -f "$STATE" ]]; then manager; return 0; fi
        DOMAIN='' ;;
      dns) dns_standalone ;;
      diag) menu_diag ;;
      multitest) diag_multitest ;;
      quit) return 0 ;;
    esac
  done
}

# ---- Diagnostics: iPerf3 to Russia (own screen) and original third-party tests
DIAG_IPREGION_URL='https://github.com/Davoyan/ipregion/raw/main/ipregion.sh'
DIAG_CENSOR_URL='https://github.com/vernette/censorcheck/raw/master/censorcheck.sh'
MULTITEST_URL='https://github.com/saveksme/multitest/raw/master/multitest.sh'

iperf_ensure(){
  command -v iperf3 >/dev/null 2>&1 && return 0
  run apt-get update || :
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y iperf3
}
# iperf_run SECONDS RESULTFILE — one gauge phase per city.
iperf_run(){
  local secs=$1 res=$2 n i
  local -a cities=()
  mapfile -t cities < <(helper iperf-cities 2>>"$LOG")
  n=${#cities[@]}
  ((n > 0)) || return 1
  : > "$res"
  ui_start "iPerf3 до РФ · ${secs} с на тест" 'Устанавливаем iperf3' "${cities[@]}"
  msg 'Устанавливаем iperf3'
  if ! iperf_ensure; then ui_stop failed; warn 'Не удалось установить iperf3 (apt-get install iperf3).'; return 1; fi
  step 4 'iperf3 готов'
  for ((i = 0; i < n; i++)); do
    msg "${cities[i]}"
    helper iperf-city "$i" "$secs" >> "$res" 2>>"$LOG" ||
      printf '{"city":"%s","error":"ошибка теста"}\n' "${cities[i]}" >> "$res"
    step $(( 4 + 96 * (i + 1) / n )) "${cities[i]} — готово"
  done
  ui_stop
}
diag_iperf(){
  local mode secs res
  mode=$(tui_radiolist 'iPerf3 до РФ' "Скорость между этим VPS и серверами провайдеров в 5 городах России:
отдача (VPS → РФ — то, что получают клиенты VPN), загрузка (РФ → VPS) и пинг.

{dim}Тест создаёт заметный трафик. Серверы: github.com/itdoginfo/russian-iperf3-servers{/}" \
         quick 'Быстрый — 3 с на направление (≈ 40 с)' ON \
         full 'Полный — 10 с на направление (≈ 2 мин)' OFF) || return 0
  secs=3; [[ "$mode" == full ]] && secs=10
  res=$(mktemp "${UI_DIR:-${TMPDIR:-/tmp}}/iperf.XXXXXXXX")
  if iperf_run "$secs" "$res"; then
    tui_show 'iPerf3 до РФ' helper iperf-table "$res"
  fi
  rm -f -- "$res"
}

# run_external TITLE URL [ARGS…] — download an original script and run it in
# the terminal; the TUI steps aside meanwhile.
run_external(){
  local title=$1 url=$2 tmp rc=0; shift 2
  tmp=$(mktemp "${UI_DIR:-${TMPDIR:-/tmp}}/ext.XXXXXXXX")
  if ! with_progress "$title" 'Скачиваем скрипт с GitHub' \
       run curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 -o "$tmp" "$url" ||
     ! bash -n "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    tui_msg "$title" "{red}✗ Не удалось скачать скрипт:{/} $url"
    return 0
  fi
  tui_suspend
  {
    printf '\033[H\033[2J'
    printf '\033[1;36m◆ %s\033[0m\n\033[2m%s\033[0m\n\033[2mCtrl+C — прервать тест\033[0m\n\n' "$title" "$url"
  } >/dev/tty
  # A handler (not an ignore) for INT: Ctrl+C stops the test, not this menu.
  trap ':' INT
  bash "$tmp" "$@" </dev/tty >/dev/tty 2>&1 {TUI_REQ}>&- {TUI_RESP}>&- || rc=$?
  trap 'exit 130' INT
  printf '\n\033[2m%s — Enter, чтобы вернуться в 3x-ui_reverse\033[0m' \
    "$( ((rc == 0)) && echo 'Готово' || echo "Завершено с кодом $rc")" >/dev/tty
  read -r _ </dev/tty || :
  tui_resume
  rm -f -- "$tmp"
}
diag_multitest(){
  tui_yesno 'Multitest by @saveksme' "Интерактивный набор тестов сервера: IP Region, Censorcheck,
iPerf3, YABS, bench.sh, IPQuality и другие ({accent}github.com/saveksme/multitest{/}).

{yellow}⚠ Это сторонний скрипт:{/} он сам ставит нужные пакеты, а в конце загружает картинку
с результатами (IP замаскированы, есть строка спонсора) на imgdb.io.
Перед запуском он будет скачан с GitHub." 'Запустить' 'Отмена' yes || return 0
  run_external 'Multitest by @saveksme' "$MULTITEST_URL"
}
menu_diag(){
  local ch
  while :; do
    ch=$(tui_menu 'Диагностика сервера' 'Скорость до России, видимость IP и блокировки.' \
         iperf $'iPerf3 до РФ\t{dim}скорость до 5 городов России · встроенный тест{/}' \
         ipregion $'IP Region\t{dim}страна IP для сервисов · оригинал Davoyan/ipregion{/}' \
         dpi $'Censorcheck DPI\t{dim}сайты, блокируемые в РФ · оригинал vernette/censorcheck{/}' \
         multitest $'Multitest by @saveksme\t{dim}все тесты разом · оригинал{/}') || return 0
    case "$ch" in
      iperf) diag_iperf ;;
      ipregion) run_external 'IP Region (Davoyan/ipregion)' "$DIAG_IPREGION_URL" ;;
      dpi) run_external 'Censorcheck DPI (vernette/censorcheck)' "$DIAG_CENSOR_URL" --mode dpi ;;
      multitest) diag_multitest ;;
    esac
    flush_notes
  done
}

write_helper(){
  local dir=${HELPER%/*} tmp
  [[ -d "$dir" ]] || return 0
  tmp=$(mktemp "$dir/xr_helper.XXXXXXXX")
  cat > "$tmp" <<'XRHELPER'
#!/usr/bin/env python3
# 3x-ui_reverse helper: talks to the local 3x-ui API (Bearer token) for inbounds,
# users, groups and activity. Installed by 3x-ui_reverse; not for direct use.
import datetime, http.client, json, os, re, secrets, socket
import ssl, sys, time, urllib.parse


def _env_file():
    """The activity timer has no shell around it: read helper.env instead."""
    path = os.path.join(os.environ.get('XR_STATE_DIR', '/opt/3x-ui_reverse'), 'helper.env')
    try:
        with open(path) as f:
            for line in f:
                key, _, value = line.strip().partition('=')
                if key.startswith('XR_') and key not in os.environ:
                    os.environ[key] = value
    except OSError:
        pass


_env_file()
API = os.environ.get('XR_API', '')                # http://127.0.0.1:PORT/PATH/panel/api
TOKEN_FILE = os.environ.get('XR_TOKEN_FILE', '')
TLS_SNI = os.environ.get('XR_TLS_SNI', '')         # direct-TLS mode: verify against this name
STATE_DIR = os.environ.get('XR_STATE_DIR', '/opt/3x-ui_reverse')
ACCESS_LOG = os.environ.get('XR_ACCESS_LOG', '/var/log/x-ui/3xr-access.log')
ACTIVITY = os.path.join(STATE_DIR, 'activity.json')
# Hosts that are not blocked in Russia, are served from global CDNs other than
# Cloudflare (throttled in RU) and are not on Xray's discouraged list (apple/icloud).
# The panel's scanner keeps only those offering TLS 1.3 + h2 + X25519 from this VPS.
SNI_CANDIDATES = [
    'www.microsoft.com', 'learn.microsoft.com', 'www.bing.com', 'dl.google.com',
    'www.samsung.com', 'www.nvidia.com', 'www.amd.com', 'www.asus.com',
    'www.lenovo.com', 'www.logitech.com', 'addons.mozilla.org', 'www.mozilla.org',
    'www.yahoo.com', 'www.xbox.com', 'www.office.com', 'www.oracle.com',
]


def die(msg, code=1):
    print('Ошибка: ' + str(msg), file=sys.stderr)
    sys.exit(code)


# ---------------------------------------------------------------- API client
class _SNIConnection(http.client.HTTPSConnection):
    """HTTPS to 127.0.0.1 while verifying the certificate for TLS_SNI."""
    def connect(self):
        sock = socket.create_connection((self.host, self.port), self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=TLS_SNI)


def _token():
    try:
        return open(TOKEN_FILE).read().strip()
    except OSError:
        die('нет API-токена 3x-ui (%s)' % TOKEN_FILE)


def call(path, data=None, form=False, method=None, timeout=60):
    if not API:
        die('XR_API не задан')
    u = urllib.parse.urlsplit(API + path)
    headers = {'Authorization': 'Bearer ' + _token(), 'Accept': 'application/json'}
    body = None
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode()
            headers['Content-Type'] = 'application/x-www-form-urlencoded'
        else:
            body = json.dumps(data).encode()
            headers['Content-Type'] = 'application/json'
    method = method or ('POST' if body is not None else 'GET')
    target = u.path + ('?' + u.query if u.query else '')
    if u.scheme == 'https':
        ctx = ssl.create_default_context()
        conn = _SNIConnection(u.hostname, u.port or 443, timeout=timeout, context=ctx)
    else:
        conn = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=timeout)
    try:
        conn.request(method, target, body=body, headers=headers)
        resp = conn.getresponse()
        raw = resp.read()
    except OSError as e:
        die('API 3x-ui недоступен: %s' % e)
    finally:
        conn.close()
    if resp.status == 404 and path != '/inbounds/list':
        die('API %s не найден: нужна 3x-ui 3.x — обнови панель: Обслуживание → Переустановить 3x-ui' % path)
    if resp.status != 200:
        die('API %s вернул HTTP %s' % (path, resp.status))
    try:
        reply = json.loads(raw)
    except ValueError:
        die('API %s вернул не JSON' % path)
    return reply


def ok(reply, what):
    if not reply.get('success'):
        die('%s: %s' % (what, (reply.get('msg') or '').strip()))
    return reply.get('obj')


def inbounds():
    return ok(call('/inbounds/list'), 'список inbound') or []


def jload(value, default):
    if isinstance(value, (dict, list)):
        return value
    try:
        return json.loads(value) if value else default
    except ValueError:
        return default


# ------------------------------------------------------------------ helpers
def human(n):
    n = float(n or 0)
    for unit in ('Б', 'КБ', 'МБ', 'ГБ', 'ТБ'):
        if n < 1024 or unit == 'ТБ':
            return ('%.0f %s' if unit == 'Б' else '%.2f %s') % (n, unit)
        n /= 1024


def ago(ts):
    if not ts:
        return 'не подключался'
    if ts > 10**11:            # milliseconds
        ts //= 1000
    d = max(0, int(time.time() - ts))
    if d < 90:
        return 'только что'
    if d < 3600:
        return '%d мин назад' % (d // 60)
    if d < 86400:
        return '%d ч назад' % (d // 3600)
    if d < 86400 * 30:
        return '%d дн назад' % (d // 86400)
    return datetime.datetime.fromtimestamp(ts).strftime('%d.%m.%Y')


def width(s):
    return len(re.sub(r'\x1b\[[0-9;]*m', '', s))


def pad(s, w):
    return s + ' ' * max(0, w - width(s))


# Output may carry markup ({green}…{/}): kept for the script's dialogs
# (XR_MARKUP=1), turned into ANSI on a terminal, stripped otherwise.
MARK_RE = re.compile(r'\{(/|green|red|yellow|accent|cyan|blue|magenta|dim|bold|white)\}')
ANSI_CODES = {'green': '32', 'red': '31', 'yellow': '33', 'accent': '36;1', 'cyan': '36', 'blue': '34',
              'magenta': '35', 'dim': '90', 'bold': '1', 'white': '97;1', '/': '0'}


def render(text):
    if os.environ.get('XR_MARKUP') == '1':
        return text
    if sys.stdout.isatty() and not os.environ.get('NO_COLOR'):
        return MARK_RE.sub(lambda m: '\x1b[%sm' % ANSI_CODES[m.group(1)], text)
    return MARK_RE.sub('', text)


def out(text=''):
    print(render(text))


def c(style, s):
    return '{%s}%s{/}' % (style, s)


# ------------------------------------------------------------ countries
COUNTRY_EN = {
    'AE': 'UAE', 'AL': 'Albania', 'AM': 'Armenia', 'AR': 'Argentina', 'AT': 'Austria', 'AU': 'Australia',
    'AZ': 'Azerbaijan', 'BA': 'Bosnia', 'BD': 'Bangladesh', 'BE': 'Belgium', 'BG': 'Bulgaria',
    'BH': 'Bahrain', 'BR': 'Brazil', 'BY': 'Belarus', 'CA': 'Canada', 'CH': 'Switzerland', 'CL': 'Chile',
    'CN': 'China', 'CO': 'Colombia', 'CY': 'Cyprus', 'CZ': 'Czechia', 'DE': 'Germany', 'DK': 'Denmark',
    'EE': 'Estonia', 'EG': 'Egypt', 'ES': 'Spain', 'FI': 'Finland', 'FR': 'France', 'GB': 'United Kingdom',
    'GE': 'Georgia', 'GR': 'Greece', 'HK': 'Hong Kong', 'HR': 'Croatia', 'HU': 'Hungary', 'ID': 'Indonesia',
    'IE': 'Ireland', 'IL': 'Israel', 'IN': 'India', 'IR': 'Iran', 'IS': 'Iceland', 'IT': 'Italy',
    'JP': 'Japan', 'KE': 'Kenya', 'KG': 'Kyrgyzstan', 'KR': 'South Korea', 'KZ': 'Kazakhstan', 'LT': 'Lithuania',
    'LU': 'Luxembourg', 'LV': 'Latvia', 'MA': 'Morocco', 'MD': 'Moldova', 'ME': 'Montenegro',
    'MK': 'North Macedonia', 'MN': 'Mongolia', 'MT': 'Malta', 'MX': 'Mexico', 'MY': 'Malaysia', 'NG': 'Nigeria',
    'NL': 'Netherlands', 'NO': 'Norway', 'NZ': 'New Zealand', 'PE': 'Peru', 'PH': 'Philippines', 'PK': 'Pakistan',
    'PL': 'Poland', 'PT': 'Portugal', 'QA': 'Qatar', 'RO': 'Romania', 'RS': 'Serbia', 'RU': 'Russia',
    'SA': 'Saudi Arabia', 'SC': 'Seychelles', 'SE': 'Sweden', 'SG': 'Singapore', 'SI': 'Slovenia', 'SK': 'Slovakia',
    'TH': 'Thailand', 'TJ': 'Tajikistan', 'TM': 'Turkmenistan', 'TR': 'Turkey', 'TW': 'Taiwan', 'UA': 'Ukraine',
    'US': 'USA', 'UZ': 'Uzbekistan', 'VN': 'Vietnam', 'ZA': 'South Africa',
}
# Russian names used by v2.0.x, recognised when shortening inbound names.
LEGACY_COUNTRY_RU = ('Нидерланды', 'Германия', 'Финляндия', 'Франция', 'Швеция', 'Польша', 'США',
                     'Великобритания', 'Латвия', 'Литва', 'Эстония', 'Казахстан', 'Турция', 'Швейцария',
                     'Австрия', 'Чехия', 'Румыния', 'Болгария', 'Сербия', 'Молдова', 'Грузия', 'Армения',
                     'Сингапур', 'Япония', 'Канада', 'Испания', 'Италия', 'Норвегия', 'Россия')


def _fetch(url, timeout=6):
    import urllib.request
    req = urllib.request.Request(url, headers={'User-Agent': '3x-ui_reverse', 'Accept': '*/*'})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read(1 << 20).decode('utf-8', 'replace')


def country_code():
    """ISO code of the VPS's country by its public IP (cached); '' if unknown."""
    cache = os.path.join(STATE_DIR, 'country.txt')
    try:
        with open(cache) as f:
            code = f.read().strip()
    except OSError:
        code = ''
    if re.fullmatch(r'[A-Z]{2}', code):
        return code
    probes = [('https://ipinfo.io/country', lambda t: t.strip()),
              ('https://api.country.is/', lambda t: json.loads(t).get('country', '')),
              ('https://ipapi.co/country/', lambda t: t.strip()),
              ('http://ip-api.com/line/?fields=countryCode', lambda t: t.strip())]
    for url, parse in probes:
        try:
            value = (parse(_fetch(url)) or '').upper()
        except Exception:
            continue
        if re.fullmatch(r'[A-Z]{2}', value):
            try:
                with open(cache, 'w') as f:
                    f.write(value + '\n')
            except OSError:
                pass
            return value
    return ''


def country_name():
    """English country name for inbound names. XR_COUNTRY overrides: an ISO
    code, any text, or 'none' to drop the prefix."""
    forced = os.environ.get('XR_COUNTRY', '').strip()
    if forced:
        return '' if forced.lower() == 'none' else COUNTRY_EN.get(forced.upper(), forced)
    code = country_code()
    return COUNTRY_EN.get(code, code)


def cmd_country(_args):
    print(country_name())


def short_name(remark):
    """Inbound name without the country prefix (for compact tables)."""
    for prefix in list(COUNTRY_EN.values()) + list(LEGACY_COUNTRY_RU):
        if remark.startswith(prefix + ' ') and len(remark) > len(prefix) + 1:
            return remark[len(prefix) + 1:]
    return remark


# ------------------------------------------------------------ catalog
# (kind, label, transport, note). Order = order in the selection list.
KINDS = [
    ('vless-tcp-reality', 'VLESS TCP Reality', 'tcp',
     'рекомендуется · маскировка под чужой сайт, XTLS Vision'),
    ('vless-xhttp-reality', 'VLESS XHTTP Reality', 'tcp',
     'рекомендуется · HTTP-транспорт с паддингом'),
    ('vless-xhttp-tls', 'VLESS XHTTP TLS', 'tcp',
     'сертификат твоего домена, можно ставить за CDN'),
    ('trojan-tcp', 'Trojan TCP', 'tcp',
     'без TLS, трафик не шифруется — только для цепочек'),
    ('trojan-tcp-reality', 'Trojan TCP Reality', 'tcp',
     'Reality без XTLS Vision'),
    ('trojan-xhttp-reality', 'Trojan XHTTP Reality', 'tcp',
     'XHTTP + Reality'),
    ('trojan-xhttp-tls', 'Trojan XHTTP TLS', 'tcp',
     'сертификат твоего домена'),
    ('hysteria', 'Hysteria2', 'udp',
     'QUIC + обфускация Salamander, SNI домена'),
    ('amneziawg', 'AmneziaWG', 'udp',
     'WireGuard с обфускацией AmneziaWG 3.1'),
    ('mtproto', 'MTProto', 'tcp',
     'прокси для Telegram (FakeTLS)'),
]
KIND = {k: {'label': l, 'transport': t, 'note': n} for k, l, t, n in KINDS}
DEFAULT_KINDS = ('vless-tcp-reality', 'vless-xhttp-reality', 'mtproto')
REALITY_KINDS = {'vless-tcp-reality', 'vless-xhttp-reality', 'trojan-tcp-reality', 'trojan-xhttp-reality'}
TLS_KINDS = {'vless-xhttp-tls', 'trojan-xhttp-tls', 'hysteria'}
# Names used by v2.0.x for the inbounds it created.
LEGACY_REMARKS = ('vless raw reality', 'vless xhttp reality', 'mtproto')
REGISTRY = os.path.join(STATE_DIR, 'inbounds.json')

NET_NAMES = {'tcp': 'TCP', 'raw': 'TCP', 'xhttp': 'XHTTP', 'ws': 'WS', 'grpc': 'gRPC',
             'httpupgrade': 'HTTPUpgrade', 'kcp': 'mKCP', 'quic': 'QUIC', 'splithttp': 'XHTTP'}
UDP_PROTOCOLS = {'wireguard', 'hysteria', 'hysteria2', 'tuic', 'amneziawg', 'masque'}


def stream(ib):
    return jload(ib.get('streamSettings'), {})


def classify(ib):
    """Catalog kind of an inbound by its structure ('' if not in the catalog)."""
    proto = ib.get('protocol')
    ss = stream(ib)
    net = ss.get('network') or 'tcp'
    net = 'tcp' if net == 'raw' else net
    sec = ss.get('security') or 'none'
    if proto in ('vless', 'trojan') and net in ('tcp', 'xhttp'):
        if proto == 'vless' and sec == 'none':
            return ''
        if net == 'tcp' and sec == 'tls':
            return ''
        return '%s-%s%s' % (proto, net, '' if sec == 'none' else '-' + sec)
    return proto if proto in ('hysteria', 'amneziawg', 'mtproto') else ''


def inbound_kind(ib):
    """'vless · XHTTP · Reality'"""
    ss = stream(ib)
    parts = [ib.get('protocol') or '?']
    net = ss.get('network') or ''
    if net and ib.get('protocol') not in UDP_PROTOCOLS | {'mtproto'}:
        parts.append(NET_NAMES.get(net, net.upper()))
    sec = ss.get('security') or ''
    if sec and sec != 'none':
        parts.append({'reality': 'Reality', 'tls': 'TLS'}.get(sec, sec))
    return ' · '.join(parts)


def inbound_sni(ib):
    st, ss = jload(ib.get('settings'), {}), stream(ib)
    if ib.get('protocol') == 'mtproto':
        return st.get('fakeTlsDomain') or ''
    if ss.get('security') == 'reality':
        return ','.join((ss.get('realitySettings') or {}).get('serverNames') or [])
    if ss.get('security') == 'tls':
        return (ss.get('tlsSettings') or {}).get('serverName') or ''
    return ''


def inbound_transport(ib):
    """tcp | udp — which firewall port the inbound needs."""
    if ib.get('protocol') in UDP_PROTOCOLS or stream(ib).get('network') in ('kcp', 'quic'):
        return 'udp'
    return 'tcp'


def registry():
    try:
        with open(REGISTRY) as f:
            return set(int(x) for x in json.load(f).get('ids', []))
    except (OSError, ValueError, TypeError):
        return set()


def register(ids, remove=False):
    current = registry()
    current = current - set(ids) if remove else current | set(ids)
    try:
        with open(REGISTRY + '.tmp', 'w') as f:
            json.dump({'ids': sorted(current)}, f)
        os.replace(REGISTRY + '.tmp', REGISTRY)
    except OSError:
        pass


def managed(ibs=None):
    """Inbounds created by this tool: {id: inbound}."""
    reg = registry()
    out = {}
    for ib in ibs if ibs is not None else inbounds():
        name = short_name(ib.get('remark') or '').lower()
        if ib['id'] in reg or (name in LEGACY_REMARKS and classify(ib)):
            out[ib['id']] = ib
    return out


def default_user_inbounds(ibs=None):
    """Inbounds a new user is attached to: the tool's own, else every enabled one."""
    ibs = ibs if ibs is not None else inbounds()
    own = [i for i, ib in managed(ibs).items() if ib.get('enable')]
    return sorted(own) or sorted(ib['id'] for ib in ibs if ib.get('enable') and ib.get('protocol') != 'tunnel')


# ------------------------------------------------------------ ports
PREFERRED_PORTS = {'tcp': [8443, 2053, 2083, 2087, 9443, 10443, 4443, 6443, 7443, 3443],
                   'udp': [443, 8443, 2053, 2083, 9443, 10443, 4443, 6443]}


def listening(transport):
    """Ports with a listening socket on this host (from /proc/net)."""
    ports = set()
    for fam in ('', '6'):
        try:
            with open('/proc/net/%s%s' % (transport, fam)) as f:
                next(f)
                for line in f:
                    parts = line.split()
                    if transport == 'tcp' and parts[3] != '0A':
                        continue
                    ports.add(int(parts[1].rsplit(':', 1)[1], 16))
        except (OSError, StopIteration, ValueError, IndexError):
            pass
    return ports


def port_problem(port, transport, ibs, ignore_id=None):
    """'' if PORT/TRANSPORT is free for an inbound, else why it is not."""
    if not 1 <= port <= 65535:
        return 'порт должен быть от 1 до 65535'
    for ib in ibs:
        if ib['id'] != ignore_id and ib.get('port') == port and inbound_transport(ib) == transport:
            return 'занят inbound-ом «%s»' % (ib.get('remark') or ib['id'])
    own = next((ib for ib in ibs if ib['id'] == ignore_id), None)
    if port in listening(transport) and not (own and own.get('port') == port):
        return 'занят другой программой на этом сервере (%s)' % transport.upper()
    return ''


def pick_port(transport, ibs, taken):
    import random
    candidates = PREFERRED_PORTS[transport] + random.sample(range(20000, 60000), 200)
    for p in candidates:
        if (p, transport) not in taken and not port_problem(p, transport, ibs):
            return p
    die('не нашлось свободного порта (%s)' % transport)


def cmd_check_port(args):
    """check-port PORT TRANSPORT [ID] — prints the reason when busy (exit 1)."""
    try:
        port = int(args[0])
    except (ValueError, IndexError):
        die('порт — число')
    reason = port_problem(port, args[1] if len(args) > 1 else 'tcp', inbounds(),
                          int(args[2]) if len(args) > 2 and args[2] else None)
    if reason:
        print(reason)
        sys.exit(1)


# ------------------------------------------------------------ names
def name_taken(name, ibs, ignore_id=None):
    low = name.strip().lower()
    return any(ib['id'] != ignore_id and (ib.get('remark') or '').strip().lower() == low for ib in ibs)


def unique_name(base, ibs):
    name, n = base, 2
    while name_taken(name, ibs):
        name = '%s %d' % (base, n)
        n += 1
    return name


def cmd_check_name(args):
    name = (args[0] if args else '').strip()
    if not name or len(name) > 64:
        print('название: от 1 до 64 символов')
        sys.exit(1)
    if name_taken(name, inbounds(), int(args[1]) if len(args) > 1 and args[1] else None):
        print('inbound с таким названием уже есть')
        sys.exit(1)


# ------------------------------------------------------------ SNI
def scan_snis(extra=()):
    """Reality targets usable from this VPS, best first: [(host, latency_ms)]."""
    targets = list(dict.fromkeys(list(extra) + SNI_CANDIDATES))
    reply = call('/server/scanRealityTargets', {'targets': ','.join(targets)}, form=True, timeout=180)
    good = []
    for r in ok(reply, 'проверка SNI') or []:
        host = r.get('host') or ''
        if r.get('feasible') and r.get('tls13') and r.get('h2') and r.get('x25519') \
                and not r.get('privateTarget') and host in targets and host not in [g[0] for g in good]:
            good.append((host, int(r.get('latencyMs') or 0)))
    return good


def pick_sni(count, exclude=()):
    # Domains already used by other inbounds go last: one SNI per inbound is
    # harder to correlate, but reuse is still better than failing.
    used = {inbound_sni(ib) for ib in inbounds()} if API else set()
    hosts = [h for h, _ in scan_snis() if h not in exclude]
    good = [h for h in hosts if h not in used] + [h for h in hosts if h in used]
    if len(good) < count:
        die('найдено только %d подходящих SNI из %d нужных (проверь исходящий доступ VPS к :443)'
            % (len(good), count))
    return good[:count]


def cmd_sni_list(_args):
    """Menu rows: host <TAB> host <TAB> latency."""
    for host, ms in scan_snis():
        print('%s\t%s\t{dim}%d мс{/}' % (host, host, ms))


def check_reality_sni(host):
    """Raises die() with the reason when HOST cannot serve as a Reality target."""
    if not re.fullmatch(r'[A-Za-z0-9.-]+\.[A-Za-z]{2,}', host or ''):
        die('SNI — доменное имя, например www.microsoft.com')
    r = ok(call('/server/scanRealityTarget', {'target': host + ':443'}, form=True, timeout=60), 'проверка SNI')
    if not r.get('feasible'):
        die('%s не подходит для Reality: %s' % (host, r.get('reason') or 'нет TLS 1.3 / h2 / X25519'))


# ------------------------------------------------------------ building inbounds
def sniffing(mode):
    s = {'enabled': True, 'destOverride': ['http', 'tls', 'quic'], 'metadataOnly': False, 'routeOnly': True}
    if mode == 'metadata':
        s.update(metadataOnly=True, routeOnly=False)
    return s


def reality(sni):
    keys = ok(call('/server/getNewX25519Cert'), 'ключи Reality')
    return {
        'show': False, 'xver': 0, 'target': sni + ':443', 'serverNames': [sni],
        'privateKey': keys['privateKey'], 'minClientVer': '', 'maxClientVer': '',
        'maxTimediff': 0, 'shortIds': [secrets.token_hex(4), secrets.token_hex(8)],
        'mldsa65Seed': '',
        'settings': {'publicKey': keys['publicKey'], 'fingerprint': 'chrome',
                     'serverName': '', 'spiderX': '/' + secrets.token_hex(6), 'mldsa65Verify': ''},
    }


def tls(cert, key, sni, alpn):
    for path in (cert, key):
        if not path or not os.path.isfile(path):
            die('файл сертификата не найден: %s' % (path or '(не указан)'))
    # ocspStapling also sets how often Xray re-reads the files: renewed
    # certificates are picked up within an hour without a restart.
    return {'serverName': sni, 'minVersion': '1.2', 'maxVersion': '1.3', 'alpn': alpn,
            'rejectUnknownSni': False,
            'certificates': [{'certificateFile': cert, 'keyFile': key, 'ocspStapling': 3600,
                              'oneTimeLoading': False, 'usage': 'encipherment', 'buildChain': False}],
            'settings': {'fingerprint': 'chrome'}}


def xhttp():
    return {'path': '/' + secrets.token_hex(8), 'host': '', 'mode': 'auto', 'xPaddingBytes': '100-1000'}


def build(kind, port, sni='', cert='', key='', sniff='route'):
    """Inbound payload for the panel API."""
    sn = sniffing(sniff)
    vless = {'clients': [], 'decryption': 'none', 'fallbacks': []}
    trojan = {'clients': [], 'fallbacks': []}
    tcp = {'acceptProxyProtocol': False, 'header': {'type': 'none'}}
    proto, net, sec = (kind.split('-') + ['', ''])[:3] if kind.startswith(('vless', 'trojan')) else (kind, '', '')
    if proto in ('vless', 'trojan'):
        ss = {'network': net, 'security': sec or 'none', 'externalProxy': []}
        if net == 'tcp':
            ss['tcpSettings'] = tcp
        else:
            ss['xhttpSettings'] = xhttp()
        if sec == 'reality':
            ss['realitySettings'] = reality(sni)
        elif sec == 'tls':
            ss['tlsSettings'] = tls(cert, key, sni, ['h2', 'http/1.1'])
        return dict(protocol=proto, port=port, settings=vless if proto == 'vless' else trojan,
                    streamSettings=ss, sniffing=sn)
    if kind == 'hysteria':
        # Salamander makes the QUIC handshake look like random UDP: plain QUIC to
        # foreign servers is fingerprinted and throttled in Russia.
        ss = {'network': 'hysteria', 'security': 'tls',
              'hysteriaSettings': {'version': 2, 'udpIdleTimeout': 60},
              'tlsSettings': tls(cert, key, sni, ['h3']),
              'finalmask': {'udp': [{'type': 'salamander', 'settings': {'password': secrets.token_urlsafe(18)}}]}}
        return dict(protocol='hysteria', port=port, settings={'version': 2, 'clients': []},
                    streamSettings=ss, sniffing=sn)
    if kind == 'amneziawg':
        # The panel generates keys and a random AmneziaWG 3.1 obfuscation set.
        return dict(protocol='amneziawg', port=port, settings={'clients': []},
                    streamSettings={}, sniffing={'enabled': False})
    if kind == 'mtproto':
        return dict(protocol='mtproto', port=port, settings={'fakeTlsDomain': sni, 'clients': []},
                    streamSettings={}, sniffing={'enabled': False})
    die('неизвестный тип inbound: %s' % kind)


def parse_opts(args):
    """Positional args + --key value options."""
    pos, opts, i = [], {}, 0
    while i < len(args):
        if args[i].startswith('--'):
            opts.setdefault(args[i][2:], []).append(args[i + 1] if i + 1 < len(args) else '')
            i += 2
        else:
            pos.append(args[i])
            i += 1
    return pos, opts


def cmd_create_inbounds(args):
    """create-inbounds KIND[,KIND…] [--sniff route|metadata]
         [--tls KIND|CERT|KEY|SNI]… [--port KIND|PORT]… [--sni KIND|HOST]… [--name KIND|NAME]…
    Creates the inbounds (same kind may repeat), attaches user1 when the panel has
    no clients yet and prints the ids of the new inbounds."""
    pos, opts = parse_opts(args)
    kinds = [k for k in (pos[0] if pos else '').split(',') if k]
    for k in kinds:
        if k not in KIND:
            die('неизвестный тип inbound: %s' % k)
    if not kinds:
        die('не выбран ни один inbound')
    per = lambda name: dict(v.split('|', 1) for v in opts.get(name, []) if '|' in v)
    tls_opts = {k: v.split('|') for k, v in per('tls').items()}
    ports, snis, names = per('port'), per('sni'), per('name')
    sniff = (opts.get('sniff') or ['route'])[0]
    for k in kinds:
        if k in TLS_KINDS and (k not in tls_opts or len(tls_opts[k]) != 3):
            die('для %s нужен сертификат: --tls "%s|CERT|KEY|SNI"' % (KIND[k]['label'], k))
    ibs = inbounds()
    # Everything is checked before the first inbound is created.
    for k, (cert, key, _) in ((k, tls_opts[k]) for k in kinds if k in TLS_KINDS):
        for path in (cert, key):
            if not os.path.isfile(path):
                die('%s: файл сертификата не найден: %s' % (KIND[k]['label'], path))
    for k, host in snis.items():
        if k in REALITY_KINDS:
            check_reality_sni(host)
    # One scan gives a different Reality/FakeTLS domain to every inbound that needs one.
    need = [k for k in kinds if (k in REALITY_KINDS or k == 'mtproto') and k not in snis]
    auto_snis = pick_sni(len(need)) if need else []
    taken, plan = set(), []
    for k in kinds:
        transport = KIND[k]['transport']
        if k in ports:
            port = int(ports[k])
            reason = port_problem(port, transport, ibs)
            if reason:
                die('порт %d: %s' % (port, reason))
        else:
            port = pick_port(transport, ibs, taken)
        taken.add((port, transport))
        cert = key = ''
        if k in TLS_KINDS:
            cert, key, sni = tls_opts[k]
        else:
            sni = snis.get(k) or (auto_snis.pop(0) if k in REALITY_KINDS or k == 'mtproto' else '')
        plan.append((k, port, sni, cert, key))
    created = []
    country = country_name()
    for k, port, sni, cert, key in plan:
        base = names.get(k) or ('%s %s' % (country, KIND[k]['label'])).strip()
        payload = build(k, port, sni, cert, key, sniff)
        payload.update(enable=True, remark=unique_name(base, ibs), listen='', expiryTime=0, total=0)
        ok(call('/inbounds/add', payload), 'создание %s' % KIND[k]['label'])
        ibs = inbounds()
        new = max((ib for ib in ibs if ib.get('remark') == payload['remark']), key=lambda x: x['id'])
        created.append(new['id'])
        register([new['id']])
    if not any(jload(ib.get('settings'), {}).get('clients') for ib in ibs) and \
            not any(cl.get('email') == 'user1' for cl in clients_all()):
        ok(call('/clients/add', {'client': {'email': 'user1', 'enable': True, 'flow': 'xtls-rprx-vision',
                                            'totalGB': 0, 'expiryTime': 0, 'limitIp': 0},
                                 'inboundIds': created}), 'создание user1')
    print(' '.join(str(i) for i in created))


# ------------------------------------------------------------ editing inbounds
def get_inbound(ib_id):
    ib = ok(call('/inbounds/get/%d' % ib_id), 'inbound %d' % ib_id)
    if not ib:
        die('inbound %d не найден' % ib_id)
    return ib


def save_inbound(ib):
    payload = {k: ib[k] for k in ('remark', 'enable', 'listen', 'port', 'protocol', 'expiryTime',
                                  'total', 'up', 'down', 'tag', 'trafficReset', 'settings',
                                  'streamSettings', 'sniffing') if k in ib}
    for k in ('settings', 'streamSettings', 'sniffing'):
        payload[k] = jload(payload.get(k), {})
    ok(call('/inbounds/update/%d' % ib['id'], payload), 'сохранение inbound')


def update_client(email, change):
    """Change some fields of a client; the update API replaces the whole record."""
    r = ok(call('/clients/get/' + urllib.parse.quote(email, safe='')), 'клиент %s' % email) or {}
    cl = r.get('client') or {}
    body = {k: v for k, v in cl.items() if k not in ('id', 'createdAt', 'updatedAt')}
    ips = body.get('allowedIPs')
    body['allowedIPs'] = [x.strip() for x in ips.split(',') if x.strip()] if isinstance(ips, str) else (ips or [])
    body.update(change)
    body['inboundIds'] = r.get('inboundIds') or []
    ok(call('/clients/update/' + urllib.parse.quote(email, safe=''), body), 'обновление клиента %s' % email)


def int_arg(args, i, what):
    try:
        return int(args[i])
    except (ValueError, IndexError):
        die('%s — число' % what)


def cmd_inbound_info(args):
    """KEY=VALUE lines about one inbound (for the script's edit screen)."""
    ib = get_inbound(int_arg(args, 0, 'ID'))
    kind = classify(ib)
    ss = stream(ib)
    cert = ((ss.get('tlsSettings') or {}).get('certificates') or [{}])[0]
    for k, v in (('id', ib['id']), ('kind', kind), ('label', KIND.get(kind, {}).get('label', inbound_kind(ib))),
                 ('remark', ib.get('remark') or ''), ('port', ib.get('port')),
                 ('transport', inbound_transport(ib)), ('security', ss.get('security') or ''),
                 ('sni', inbound_sni(ib)), ('cert', cert.get('certificateFile') or ''),
                 ('key', cert.get('keyFile') or ''), ('enable', 1 if ib.get('enable') else 0),
                 ('protocol', ib.get('protocol'))):
        print('%s=%s' % (k, str(v).replace('\n', ' ')))


def cmd_menu_all_inbounds(_args):
    """Menu rows: id <TAB> name <TAB> type <TAB> port/transport."""
    for ib in sorted(inbounds(), key=lambda x: x['id']):
        dot = '{green}●{/}' if ib.get('enable') else '{red}○{/}'
        print('%s\t%s %s\t%s\t%s/%s' % (ib['id'], dot, ib.get('remark') or ib.get('tag'), inbound_kind(ib),
                                       ib.get('port'), inbound_transport(ib)))


def cmd_menu_kinds(args):
    """Checklist rows: kind <TAB> ON|OFF <TAB> label <TAB> note (+ how many exist).
    --fresh: before the panel is installed (no API)."""
    counts = {}
    for ib in ([] if '--fresh' in args else inbounds()):
        counts[classify(ib)] = counts.get(classify(ib), 0) + 1
    fresh = not any(counts.values())
    for k, label, _, note in KINDS:
        have = counts.get(k, 0)
        mark = 'ON' if fresh and k in DEFAULT_KINDS else 'OFF'
        extra = ('{green}✓ есть%s{/}' % (' ×%d' % have if have > 1 else '')) if have else ' '
        print('%s\t%s\t%s\t%s\t{dim}%s{/}' % (k, mark, label, extra, note))


def cmd_kind_info(args):
    """kind-info KIND — transport and whether a certificate / SNI is needed."""
    k = args[0] if args else ''
    if k not in KIND:
        die('неизвестный тип inbound: %s' % k)
    print('label=%s' % KIND[k]['label'])
    print('transport=%s' % KIND[k]['transport'])
    print('tls=%d' % (k in TLS_KINDS))
    print('reality=%d' % (k in REALITY_KINDS))


def cmd_set_port(args):
    ib = get_inbound(int_arg(args, 0, 'ID'))
    port = int_arg(args, 1, 'порт')
    reason = port_problem(port, inbound_transport(ib), inbounds(), ib['id'])
    if reason:
        die('порт %d %s' % (port, reason))
    ib['port'] = port
    save_inbound(ib)


def cmd_set_name(args):
    ib = get_inbound(int_arg(args, 0, 'ID'))
    name = (args[1] if len(args) > 1 else '').strip()
    if not name or len(name) > 64:
        die('название: от 1 до 64 символов')
    if name_taken(name, inbounds(), ib['id']):
        die('inbound «%s» уже есть' % name)
    ib['remark'] = name
    save_inbound(ib)


def cmd_set_sni(args):
    """set-sni ID HOST [--force] — Reality target / MTProto FakeTLS domain."""
    ib = get_inbound(int_arg(args, 0, 'ID'))
    host = (args[1] if len(args) > 1 else '').strip().lower()
    if not re.fullmatch(r'[a-z0-9.-]+\.[a-z]{2,}', host):
        die('SNI — доменное имя, например www.microsoft.com')
    ss = stream(ib)
    if ib.get('protocol') == 'mtproto':
        st = jload(ib.get('settings'), {})
        st['fakeTlsDomain'] = host
        ib['settings'] = st
        save_inbound(ib)
        # Each client's secret embeds its own FakeTLS domain and the panel keeps
        # it: rebuild them with the new domain, keeping the random middle part.
        for cl in st.get('clients') or []:
            sec = cl.get('secret') or ''
            middle = sec[2:34] if len(sec) >= 34 and re.fullmatch(r'[0-9a-f]+', sec[2:34]) else secrets.token_hex(16)
            if cl.get('email'):
                update_client(cl['email'], {'secret': 'ee' + middle + host.encode().hex()})
        return
    elif ss.get('security') == 'reality':
        if '--force' not in args:
            check_reality_sni(host)
        rs = ss['realitySettings']
        rs['target'] = host + ':443'
        rs['serverNames'] = [host]
        ib['streamSettings'] = ss
    elif ss.get('security') == 'tls':
        die('у TLS-inbound-а SNI задаётся вместе с сертификатом (изменить TLS)')
    else:
        die('у этого inbound-а нет SNI')
    save_inbound(ib)


def cmd_set_tls(args):
    """set-tls ID CERT KEY SNI — certificate of a TLS inbound."""
    ib = get_inbound(int_arg(args, 0, 'ID'))
    if len(args) < 4:
        die('set-tls ID CERT KEY SNI')
    ss = stream(ib)
    if ss.get('security') != 'tls':
        die('этот inbound не использует TLS')
    old = ss.get('tlsSettings') or {}
    new = tls(args[1], args[2], args[3].strip().lower(), old.get('alpn') or ['h2', 'http/1.1'])
    old.update(serverName=new['serverName'], certificates=new['certificates'])
    ss['tlsSettings'] = old
    ib['streamSettings'] = ss
    save_inbound(ib)


def cmd_set_enable(args):
    ib_id = int_arg(args, 0, 'ID')
    ok(call('/inbounds/setEnable/%d' % ib_id, {'enable': (args[1] if len(args) > 1 else '1') in ('1', 'true', 'on')}),
       'включение inbound')


def cmd_del_inbound(args):
    ib_id = int_arg(args, 0, 'ID')
    get_inbound(ib_id)
    ok(call('/inbounds/del/%d' % ib_id, {}), 'удаление inbound')
    register([ib_id], remove=True)


# ------------------------------------------------------------ listing
def cmd_inbounds(args):
    """Every inbound of the panel; ◆ marks those created by 3x-ui_reverse.
    inbounds [WIDTH] — table fitted to WIDTH; inbounds --compact — short list."""
    ibs = sorted(inbounds(), key=lambda x: x['id'])
    ours = set(managed(ibs))
    if not ibs:
        out('{yellow}⚠ В панели нет inbound-ов.{/}')
        return
    if '--compact' in args:
        w = max(len(ib.get('remark') or '') for ib in ibs)
        for ib in ibs:
            dot = '{green}●{/}' if ib.get('enable') else '{red}○{/}'
            sni = inbound_sni(ib)
            out('%s %s  %-10s {dim}%s{/}' % (dot, (ib.get('remark') or ib.get('tag') or '').ljust(min(w, 34)),
                                          '%s/%s' % (ib.get('port'), inbound_transport(ib)), sni))
        out('{dim}%d inbound-ов · изменить порт, название, SNI или TLS — «Изменить inbound»{/}' % len(ibs))
        return
    max_w = int(args[0]) if args and args[0].isdigit() else 200
    rows = []
    for ib in ibs:
        clients = len(jload(ib.get('settings'), {}).get('clients') or [])
        used = (ib.get('up') or 0) + (ib.get('down') or 0)
        total = ib.get('total') or 0
        rows.append((ib, str(ib['id']), ib.get('remark') or ib.get('tag') or '—', inbound_kind(ib),
                     '%s/%s' % (ib.get('port'), inbound_transport(ib)), str(clients),
                     '%s / %s' % (human(used), human(total) if total else '∞'), inbound_sni(ib) or '—'))
    head = ('', 'ID', 'НАЗВАНИЕ', 'ПРОТОКОЛ', 'ПОРТ', 'КЛ.', 'ТРАФИК', 'SNI')
    caps = [2, 4, 34, 24, 10, 4, 20, 28]
    widths = [2] + [min(caps[i], max([len(head[i])] + [len(r[i]) for r in rows])) for i in range(1, 8)]
    cols = list(range(8))
    # Narrow screens: drop traffic, then client count, then shorten names and SNI.
    for drop in (6, 5):
        if sum(widths[i] + 2 for i in cols) > max_w:
            cols.remove(drop)
    while sum(widths[i] + 2 for i in cols) > max_w and (widths[2] > 18 or widths[7] > 14):
        i = 2 if widths[2] - 18 >= widths[7] - 14 else 7
        widths[i] -= 1
    out('{accent}' + '  '.join(head[i].ljust(widths[i]) for i in cols).rstrip() + '{/}')
    for r in rows:
        ib = r[0]
        dot = ('{green}●{/}' if ib.get('enable') else '{red}○{/}') + ('{accent}◆{/}' if ib['id'] in ours else ' ')
        name = cut(r[2], widths[2]).ljust(widths[2])
        cells = {0: dot, 1: '{dim}%s{/}' % r[1].rjust(widths[1]),
                 2: ('{bold}%s{/}' % name) if ib['id'] in ours else name,
                 3: cut(r[3], widths[3]).ljust(widths[3]), 4: r[4].ljust(widths[4]), 5: r[5].rjust(widths[5]),
                 6: r[6].ljust(widths[6]), 7: '{dim}%s{/}' % cut(r[7], widths[7])}
        out('  '.join(cells[i] for i in cols).rstrip())
    off = sum(1 for ib in ibs if not ib.get('enable'))
    out('')
    out('{dim}Всего %d%s · {/}{accent}◆{/}{dim} создан скриптом{/}' % (len(ibs), (' · выключено %d' % off) if off else ''))


def cmd_ports_all(_args):
    """PORT TRANSPORT REMARK for every enabled inbound (what the firewall must allow)."""
    for ib in sorted(inbounds(), key=lambda x: x['id']):
        if ib.get('enable'):
            print('%s %s %s' % (ib.get('port'), inbound_transport(ib), ib.get('remark') or ib.get('tag') or ''))


def cmd_ports(args):
    """PORT/TRANSPORT of the tool's inbounds (or of the given ids)."""
    ibs = inbounds()
    want = {int(x) for x in args if x.isdigit()}
    sel = [ib for ib in ibs if ib['id'] in want] if want else list(managed(ibs).values())
    print(' '.join('%s/%s' % (ib.get('port'), inbound_transport(ib)) for ib in sorted(sel, key=lambda x: x['id'])))


def cmd_all_ports(_args):
    print(' '.join(str(ib.get('port')) for ib in inbounds()))

# -------------------------------------------------------------------- users
NAME_RE = re.compile(r'[A-Za-z0-9._@-]{2,64}')
GROUP_RE = re.compile(r'[\w .-]{1,32}')


def clients_all():
    return ok(call('/clients/list'), 'список клиентов') or []


def find_client(email, clients=None):
    for cl in clients if clients is not None else clients_all():
        if cl.get('email') == email:
            return cl
    die('пользователь %s не найден' % email)


def inbound_names(ibs):
    """inbound id -> compact display name (without the country prefix)."""
    return {ib['id']: short_name(ib.get('remark') or ib.get('tag') or str(ib['id'])) for ib in ibs}


def parse_ids(text, ibs):
    known = {ib['id'] for ib in ibs}
    ids = []
    for part in (text or '').replace(' ', ',').split(','):
        if not part:
            continue
        if not part.isdigit() or int(part) not in known:
            die('неизвестный inbound: %s' % part)
        ids.append(int(part))
    return sorted(set(ids))


def check_group(group):
    if group and not GROUP_RE.fullmatch(group):
        die('группа: до 32 символов — буквы, цифры, пробел, . _ -')
    return group


def group_emails(group):
    return ok(call('/clients/groups/%s/emails' % urllib.parse.quote(group, safe='')),
              'участники группы') or []


class Snapshot:
    """Everything the user screens need, fetched once."""
    def __init__(self):
        self.ibs = inbounds()
        self.clients = clients_all()
        self.names = inbound_names(self.ibs)
        self.tag2name = {ib.get('tag'): self.names[ib['id']] for ib in self.ibs}
        self.onlines = set(ok(call('/clients/onlines', {}), 'онлайн') or [])
        self.last = ok(call('/clients/lastOnline', {}), 'последняя активность') or {}
        try:
            with open(ACTIVITY) as f:
                self.activity = json.load(f)
        except (OSError, ValueError):
            self.activity = {}
        self.now_ms = time.time() * 1000

    def used(self, cl):
        tr = cl.get('traffic') or {}
        return (tr.get('up') or 0) + (tr.get('down') or 0)

    def kind(self, cl):
        """disabled | expired | depleted | online | idle"""
        # The panel itself disables expired/depleted clients: check those first.
        exp, total = cl.get('expiryTime') or 0, cl.get('totalGB') or 0
        if 0 < exp < self.now_ms:
            return 'expired'
        if total and self.used(cl) >= total:
            return 'depleted'
        if not cl.get('enable', True):
            return 'disabled'
        return 'online' if cl.get('email') in self.onlines else 'idle'

    def where(self, email):
        act = self.activity.get(email) or {}
        return self.tag2name.get(act.get('inbound'), act.get('inbound') or '')

    def state(self, cl):
        email, kind = cl.get('email', ''), self.kind(cl)
        if kind == 'disabled':
            return '{dim}○ отключён{/}'
        if kind == 'expired':
            return '{red}○ срок истёк{/}'
        if kind == 'depleted':
            return '{red}○ трафик исчерпан{/}'
        where = self.where(email)
        if kind == 'online':
            return '{green}● в сети' + (' · ' + where if where else '') + '{/}'
        ts = max(int(self.last.get(email) or 0), int((self.activity.get(email) or {}).get('ts') or 0))
        return '{dim}○ ' + ago(ts) + (' · ' + where if where and ts else '') + '{/}'

    def traffic(self, cl):
        total = cl.get('totalGB') or 0
        return '%s / %s' % (human(self.used(cl)), human(total) if total else '∞')

    def inb(self, cl):
        ids = cl.get('inboundIds') or []
        return ', '.join(self.names.get(i, str(i)) for i in sorted(ids)) or '—'


def cut(s, w):
    return s if len(s) <= w else s[:max(1, w - 1)] + '…'


def plain_len(text):
    return len(MARK_RE.sub('', text))


def cut_mark(text, w):
    """Truncate text that may contain markup to w visible characters."""
    if plain_len(text) <= w:
        return text + ' ' * (w - plain_len(text))
    plain = MARK_RE.sub('', text)
    return cut(plain, w)


def cmd_users(args):
    """Table of users; optional width (dialogs pass their width)."""
    snap = Snapshot()
    if not snap.clients:
        out('Пользователей пока нет.')
        return
    max_w = int(args[0]) if args and args[0].isdigit() else 200
    rows = [(cl.get('email', ''), cl.get('group') or '—', snap.inb(cl), snap.traffic(cl), snap.state(cl))
            for cl in sorted(snap.clients, key=lambda x: ((x.get('group') or '\uffff'), x.get('email', '')))]
    head = ('ИМЯ', 'ГРУППА', 'INBOUND-Ы', 'ТРАФИК', 'СОСТОЯНИЕ')
    caps = [18, 14, 22, 22, 40]
    widths = [min(caps[i], max(len(head[i]), *(plain_len(r[i]) for r in rows))) for i in range(5)]
    # Shrink the last column first so the table fits the given width.
    widths[4] = max(10, min(widths[4], max_w - sum(widths[:4]) - 8))
    out('{accent}' + '  '.join(head[i].ljust(widths[i]) for i in range(5)).rstrip() + '{/}')
    out('{dim}' + '  '.join('─' * w for w in widths) + '{/}')
    for r in rows:
        cells = ['{bold}%s{/}' % cut_mark(r[0], widths[0]), '{cyan}%s{/}' % cut_mark(r[1], widths[1])] + \
                [cut_mark(r[i], widths[i]) for i in (2, 3)] + [r[4]]
        out('  '.join(cells).rstrip())


def cmd_stats(_args):
    """total active expired depleted disabled online"""
    snap = Snapshot()
    kinds = [snap.kind(cl) for cl in snap.clients]
    online = sum(1 for k in kinds if k == 'online')
    active = sum(1 for k in kinds if k in ('online', 'idle'))
    print(len(kinds), active, kinds.count('expired'), kinds.count('depleted'),
          kinds.count('disabled'), online)


def cmd_menu_users(_args):
    """Menu rows: email <TAB> email <TAB> group <TAB> traffic <TAB> state."""
    snap = Snapshot()
    for cl in sorted(snap.clients, key=lambda x: ((x.get('group') or '\uffff'), x.get('email', ''))):
        group = cl.get('group') or 'без группы'
        print('%s\t%s\t%s\t%s\t%s' % (cl.get('email'), cl.get('email'), cut(group, 16),
                                      snap.traffic(cl), snap.state(cl)))


def cmd_menu_groups(_args):
    """Menu rows: name <TAB> name <TAB> member count."""
    for g in ok(call('/clients/groups'), 'группы') or []:
        print('%s\t%s\t%d польз.' % (g.get('name'), g.get('name'), g.get('clientCount') or 0))


def cmd_menu_inbounds(args):
    """Checklist rows: id <TAB> ON|OFF <TAB> name <TAB> protocol :port.
    Arg: email (ON = attached), group:NAME (ON = every member attached) or managed."""
    snap = Snapshot()
    target = args[0] if args else ''
    attached = set()
    if target == 'managed':      # preselection for a new user
        attached = set(default_user_inbounds(snap.ibs))
    elif target.startswith('group:'):
        members = set(group_emails(target[6:]))
        sets = [set(cl.get('inboundIds') or []) for cl in snap.clients if cl.get('email') in members]
        attached = set.intersection(*sets) if sets else set()
    elif target:
        attached = set(find_client(target, snap.clients).get('inboundIds') or [])
    for ib in sorted(snap.ibs, key=lambda x: x['id']):
        extra = '' if ib.get('enable') else '  {red}выкл{/}'
        print('%s\t%s\t%s\t%s :%s%s' % (ib['id'], 'ON' if ib['id'] in attached else 'OFF',
                                       snap.names[ib['id']], ib.get('protocol'), ib.get('port'), extra))


def cmd_user_card(args):
    snap = Snapshot()
    cl = find_client(args[0], snap.clients)
    exp = cl.get('expiryTime') or 0
    expires = datetime.datetime.fromtimestamp(exp / 1000).strftime('%d.%m.%Y %H:%M') if exp > 0 else 'бессрочно'
    out('{dim}Имя{/}           {bold}%s{/}' % cl.get('email'))
    out('{dim}Группа{/}        {cyan}%s{/}' % (cl.get('group') or 'без группы'))
    out('{dim}Состояние{/}     %s' % snap.state(cl))
    out('{dim}Трафик{/}        %s' % snap.traffic(cl))
    out('{dim}Действует до{/}  %s' % expires)
    out('{dim}Inbound-ы{/}     %s' % snap.inb(cl))
    out('')
    out('{accent}Все inbound-ы панели{/}')
    ids = set(cl.get('inboundIds') or [])
    for ib in sorted(snap.ibs, key=lambda x: x['id']):
        mark = '{green}✓{/}' if ib['id'] in ids else '{dim}·{/}'
        out('  %s %-10s {dim}%s :%s{/}' % (mark, cut(snap.names[ib['id']], 10), ib.get('protocol'), ib.get('port')))
    out('')
    out('{dim}Sub ID{/}        %s' % cl.get('subId', ''))


def cmd_add_user(args, quiet=False):
    """add-user EMAIL [GB] [DAYS] [GROUP] [IDS]; IDS defaults to the 3x-ui_reverse inbounds."""
    email = args[0]
    gb = float(args[1]) if len(args) > 1 and args[1] else 0
    days = int(args[2]) if len(args) > 2 and args[2] else 0
    group = check_group(args[3] if len(args) > 3 else '')
    if not NAME_RE.fullmatch(email):
        die('имя: 2–64 символа A-Z a-z 0-9 . _ @ -')
    ibs = inbounds()
    ids = parse_ids(args[4], ibs) if len(args) > 4 and args[4] else default_user_inbounds(ibs)
    if not ids:
        die('не выбран ни один inbound')
    if any(cl.get('email') == email for cl in clients_all()):
        die('пользователь %s уже существует' % email)
    client = {'email': email, 'enable': True, 'flow': 'xtls-rprx-vision',
              'totalGB': int(gb * 1024 ** 3), 'limitIp': 0, 'group': group,
              'expiryTime': int((time.time() + days * 86400) * 1000) if days > 0 else 0}
    ok(call('/clients/add', {'client': client, 'inboundIds': ids}), 'добавление пользователя')
    if not quiet:
        print(find_client(email).get('subId', ''))


def cmd_del_user(args):
    find_client(args[0])
    ok(call('/clients/del/' + urllib.parse.quote(args[0], safe=''), {}), 'удаление пользователя')


def cmd_sub_id(args):
    print(find_client(args[0]).get('subId', ''))


def cmd_set_inbounds(args):
    """set-inbounds EMAIL IDS — attach the checked, detach the unchecked."""
    email = args[0]
    ibs = inbounds()
    want = set(parse_ids(args[1] if len(args) > 1 else '', ibs))
    if not want:
        die('выбери хотя бы один inbound, иначе у пользователя не будет подключений')
    have = set(find_client(email).get('inboundIds') or [])
    path = urllib.parse.quote(email, safe='')
    if want - have:
        ok(call('/clients/%s/attach' % path, {'inboundIds': sorted(want - have)}), 'подключение inbound-ов')
    if have - want:
        ok(call('/clients/%s/detach' % path, {'inboundIds': sorted(have - want)}), 'отключение inbound-ов')
    print('+%d / −%d' % (len(want - have), len(have - want)))


def cmd_set_group(args):
    email, group = args[0], check_group(args[1] if len(args) > 1 else '')
    find_client(email)
    if group:
        ok(call('/clients/groups/bulkAdd', {'emails': [email], 'group': group}), 'назначение группы')
    else:
        ok(call('/clients/groups/bulkRemove', {'emails': [email]}), 'снятие группы')


def cmd_group_create(args):
    ok(call('/clients/groups/create', {'name': check_group(args[0])}), 'создание группы')


def cmd_group_rename(args):
    ok(call('/clients/groups/rename', {'oldName': args[0], 'newName': check_group(args[1])}),
       'переименование группы')


def cmd_group_delete(args):
    ok(call('/clients/groups/delete', {'name': args[0]}), 'удаление группы')


def cmd_group_add_users(args):
    group, emails = check_group(args[0]), [e for e in args[1:] if e]
    if not emails:
        die('не выбраны пользователи')
    ok(call('/clients/groups/bulkAdd', {'emails': emails, 'group': group}), 'добавление в группу')


def cmd_group_inbounds(args):
    """group-inbounds GROUP add|remove|set IDS — bulk attach/detach for all members."""
    group, mode = args[0], args[1]
    ibs = inbounds()
    ids = parse_ids(args[2] if len(args) > 2 else '', ibs)
    emails = group_emails(group)
    if not emails:
        die('в группе «%s» нет пользователей' % group)
    if mode in ('add', 'set') and not ids:
        die('выбери хотя бы один inbound')
    attach = ids if mode in ('add', 'set') else []
    detach = ids if mode == 'remove' else \
        sorted({ib['id'] for ib in ibs} - set(ids)) if mode == 'set' else []
    if mode not in ('add', 'remove', 'set'):
        die('режим: add | remove | set')
    if attach:
        ok(call('/clients/bulkAttach', {'emails': emails, 'inboundIds': attach}), 'массовое подключение')
    if detach:
        ok(call('/clients/bulkDetach', {'emails': emails, 'inboundIds': detach}), 'массовое отключение')
    print(len(emails))



def cmd_groups(_args):
    """Overview: every group with its members."""
    groups = ok(call('/clients/groups'), 'группы') or []
    if not groups:
        out('Групп пока нет. Создай группу и добавь в неё пользователей.')
        return
    snap = Snapshot()
    for g in groups:
        name = g.get('name')
        members = sorted(cl.get('email') for cl in snap.clients if (cl.get('group') or '') == name)
        out('{cyan}%s{/}  {dim}%d польз. · трафик %s{/}' % (name, len(members), human(g.get('trafficUsed') or 0)))
        out('   ' + (', '.join(members) if members else '{dim}(пусто){/}'))
        out('')
    free = sorted(cl.get('email') for cl in snap.clients if not cl.get('group'))
    if free:
        out('{dim}Без группы  %d польз.{/}' % len(free))
        out('   ' + ', '.join(free))


def cmd_menu_members(args):
    """Checklist rows: email <TAB> ON|OFF <TAB> email <TAB> current group."""
    group = args[0]
    for cl in sorted(clients_all(), key=lambda x: x.get('email', '')):
        current = cl.get('group') or ''
        print('%s\t%s\t%s\t%s' % (cl.get('email'), 'ON' if current == group else 'OFF',
                                   cl.get('email'), current or 'без группы'))


def cmd_group_set_members(args):
    """group-set-members GROUP EMAIL... — make exactly these users the members."""
    group = check_group(args[0])
    want = {e for e in args[1:] if e}
    have = {cl.get('email') for cl in clients_all() if (cl.get('group') or '') == group}
    if want - have:
        ok(call('/clients/groups/bulkAdd', {'emails': sorted(want - have), 'group': group}), 'добавление в группу')
    if have - want:
        ok(call('/clients/groups/bulkRemove', {'emails': sorted(have - want)}), 'исключение из группы')
    print('+%d / −%d' % (len(want - have), len(have - want)))


# ------------------------------------------------------------ DNS check
# Public resolvers in different countries, like dnschecker.org: they show
# whether the domain's A record has propagated and points to this server.
RESOLVERS = [
    ('Google', 'США', '8.8.8.8'),
    ('Cloudflare', 'anycast', '1.1.1.1'),
    ('Quad9', 'Швейцария', '9.9.9.9'),
    ('OpenDNS', 'США', '208.67.222.222'),
    ('Level3', 'США', '4.2.2.1'),
    ('Comodo', 'США', '8.26.56.26'),
    ('Hurricane Electric', 'США', '74.82.42.42'),
    ('Control D', 'Канада', '76.76.2.0'),
    ('DNS.SB', 'Германия', '185.222.222.222'),
    ('Gcore', 'Люксембург', '95.85.95.85'),
    ('AdGuard', 'Кипр', '94.140.14.14'),
    ('CleanBrowsing', 'Великобритания', '185.228.168.9'),
    ('Yandex', 'Россия', '77.88.8.8'),
    ('SafeDNS', 'Россия', '195.46.39.39'),
    ('Alibaba', 'Китай', '223.5.5.5'),
    ('DNSPod', 'Китай', '119.29.29.29'),
]
DOH = {'8.8.8.8': 'https://dns.google/resolve?name=%s&type=%s',
       '1.1.1.1': 'https://cloudflare-dns.com/dns-query?name=%s&type=%s',
       '223.5.5.5': 'https://dns.alidns.com/resolve?name=%s&type=%s'}
QTYPE = {'A': 1, 'NS': 2, 'CNAME': 5, 'AAAA': 28}


def _dns_name(buf, pos):
    labels, jumped, end = [], False, pos
    for _ in range(128):
        n = buf[pos]
        if n == 0:
            pos += 1
            break
        if n & 0xC0 == 0xC0:
            if not jumped:
                end = pos + 2
            pos = ((n & 0x3F) << 8) | buf[pos + 1]
            jumped = True
            continue
        labels.append(buf[pos + 1:pos + 1 + n].decode('ascii', 'replace'))
        pos += 1 + n
    return '.'.join(labels).lower(), (end if jumped else pos)


def dns_query(server, name, qtype='A', timeout=2.5, recursive=True):
    """Minimal DNS client over UDP: returns (rcode, [values]) for QTYPE records."""
    import struct
    qid = secrets.randbits(16)
    q = struct.pack('>HHHHHH', qid, 0x0100 if recursive else 0, 1, 0, 0, 0)
    for part in name.strip('.').split('.'):
        q += bytes([len(part)]) + part.encode('idna')
    q += b'\0' + struct.pack('>HH', QTYPE[qtype], 1)
    family = socket.AF_INET6 if ':' in server else socket.AF_INET
    with socket.socket(family, socket.SOCK_DGRAM) as s:
        s.settimeout(timeout)
        s.sendto(q, (server, 53))
        while True:
            buf, _ = s.recvfrom(4096)
            if len(buf) >= 12 and struct.unpack('>H', buf[:2])[0] == qid:
                break
    flags, qd, an, ns_count = struct.unpack('>HHHH', buf[2:10])
    pos = 12
    for _ in range(qd):
        _, pos = _dns_name(buf, pos)
        pos += 4
    values = []
    for _ in range(an + ns_count):
        _, pos = _dns_name(buf, pos)
        rtype, _, _, rdlen = struct.unpack('>HHIH', buf[pos:pos + 10])
        pos += 10
        rdata = buf[pos:pos + rdlen]
        if rtype == QTYPE[qtype]:
            if rtype == 1 and rdlen == 4:
                values.append(socket.inet_ntop(socket.AF_INET, rdata))
            elif rtype == 28 and rdlen == 16:
                values.append(socket.inet_ntop(socket.AF_INET6, rdata))
            elif rtype == 2:
                values.append(_dns_name(buf, pos)[0])
        pos += rdlen
    return flags & 0xF, values


def doh_query(server, name, qtype):
    url = DOH[server] % (urllib.parse.quote(name), qtype)
    import urllib.request
    req = urllib.request.Request(url, headers={'Accept': 'application/dns-json', 'User-Agent': '3x-ui_reverse'})
    with urllib.request.urlopen(req, timeout=6) as r:
        data = json.loads(r.read().decode())
    return data.get('Status', 0), [a.get('data', '') for a in data.get('Answer') or [] if a.get('type') == QTYPE[qtype]]


def public_ips():
    """This server's public IPv4 (and IPv6) as seen from the Internet + local addresses."""
    found = set()
    for url in ('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com', 'https://ipinfo.io/ip'):
        try:
            ip = _fetch(url, 5).strip()
            socket.inet_aton(ip)
            found.add(ip)
            break
        except Exception:
            continue
    for url in ('https://api6.ipify.org', 'https://ipv6.icanhazip.com'):
        try:
            ip = _fetch(url, 5).strip()
            socket.inet_pton(socket.AF_INET6, ip)
            found.add(ip)
            break
        except Exception:
            continue
    for fam, probe in ((socket.AF_INET, '1.1.1.1'), (socket.AF_INET6, '2606:4700:4700::1111')):
        try:
            with socket.socket(fam, socket.SOCK_DGRAM) as s:
                s.connect((probe, 53))
                found.add(s.getsockname()[0])
        except OSError:
            pass
    return found


def cmd_public_ip(_args):
    print(' '.join(sorted(public_ips())))


def authoritative(name):
    """(ns host, ns ip) of the zone that serves NAME, via Google DNS."""
    labels = name.strip('.').split('.')
    for i in range(len(labels) - 1):
        zone = '.'.join(labels[i:])
        try:
            rc, ns = dns_query('8.8.8.8', zone, 'NS')
        except OSError:
            try:
                rc, ns = doh_query('8.8.8.8', zone, 'NS')
                ns = [n.rstrip('.') for n in ns]
            except Exception:
                return '', ''
        if ns:
            host = sorted(ns)[0]
            try:
                _, ips = dns_query('8.8.8.8', host, 'A')
            except OSError:
                ips = []
            return host, (ips[0] if ips else '')
    return '', ''


def cmd_dns_check(args):
    """dns-check DOMAIN — table of resolvers and a verdict line:
    VERDICT ok|partial|wrong|none AUTH=ok|wrong|none|unknown AAAA=ok|wrong|none IP=…"""
    import concurrent.futures as cf
    domain = (args[0] if args else '').strip().lower().rstrip('.')
    if not re.fullmatch(r'([a-z0-9-]+\.)+[a-z]{2,63}', domain):
        die('неверный домен')
    mine = public_ips()
    mine4 = sorted(ip for ip in mine if '.' in ip)
    ns_host, ns_ip = authoritative(domain)

    def ask(entry):
        name, where, server = entry
        try:
            rc, ips = dns_query(server, domain, 'A', recursive=(where != 'NS'))
            via = 'UDP'
        except OSError:
            if server not in DOH:
                return entry, None, 'нет ответа'
            try:
                rc, ips = doh_query(server, domain, 'A')
                via = 'DoH'
            except Exception:
                return entry, None, 'нет ответа'
        if rc == 3:
            return entry, [], 'NXDOMAIN'
        return entry, ips, via

    entries = list(RESOLVERS)
    if ns_ip:
        entries.insert(0, ('%s' % ns_host, 'NS', ns_ip))
    with cf.ThreadPoolExecutor(max_workers=len(entries)) as pool:
        results = list(pool.map(ask, entries))
    good = answered = 0
    auth = 'unknown'
    w = max(len(e[0]) for e in entries)
    out('{accent}%s  %-14s  %s{/}' % ('РЕЗОЛВЕР'.ljust(w), 'РАСПОЛОЖЕНИЕ', 'ОТВЕТ'))
    for (name, where, server), ips, note in results:
        place = 'авторитетный' if where == 'NS' else where
        if ips is None:
            mark, text = '{dim}·{/}', '{dim}%s{/}' % note
        elif not ips:
            mark, text = '{red}✗{/}', '{red}нет A-записи%s{/}' % (' (NXDOMAIN)' if note == 'NXDOMAIN' else '')
        elif set(ips) & mine:
            mark, text = '{green}✓{/}', '{green}%s{/}' % ', '.join(ips)
        else:
            mark, text = '{red}✗{/}', '{red}%s{/}' % ', '.join(ips)
        if ips is not None:
            if where == 'NS':
                auth = 'ok' if ips and set(ips) & mine else ('none' if not ips else 'wrong')
            else:
                answered += 1
                good += 1 if ips and set(ips) & mine else 0
        out('%s %s  %-14s  %s' % (mark, name.ljust(w), place, text))
    try:
        _, aaaa = dns_query('8.8.8.8', domain, 'AAAA')
    except OSError:
        aaaa = []
    aaaa_state = 'none' if not aaaa else ('ok' if set(aaaa) & mine else 'wrong')
    out('')
    out('{dim}IP этого сервера:{/} %s' % (', '.join(mine4) or '{yellow}не удалось определить{/}'))
    if aaaa:
        out('{dim}AAAA (IPv6):{/} %s %s' % (', '.join(aaaa), '{green}✓{/}' if aaaa_state == 'ok'
                                             else '{yellow}⚠ не указывает на этот сервер{/}'))
    if not answered:
        verdict = 'none'
    elif good == answered:
        verdict = 'ok'
    elif good:
        verdict = 'partial'
    else:
        verdict = 'wrong'
    print('VERDICT %s AUTH=%s AAAA=%s OK=%d/%d IP=%s' % (verdict, auth, aaaa_state, good, answered,
                                                         ','.join(mine4) or '-'))

# ------------------------------------------------------- activity tracking
LOG_RE = re.compile(r'^(\S+ \S+) .*?\[(\S+) (?:>>|->) [^\]]*\].*?email: (\S+)')


def cmd_track_activity(_args):
    """Run every minute by a timer: fold the short-lived Xray access log into
    activity.json (email -> last inbound + time), then truncate the log so
    visited destinations never stay on disk for more than a minute."""
    try:
        activity = json.load(open(ACTIVITY))
    except (OSError, ValueError):
        activity = {}
    seen = set()
    try:
        with open(ACCESS_LOG, 'r+', errors='replace') as f:
            for line in f:
                m = LOG_RE.search(line)
                if not m:
                    continue
                stamp, tag, email = m.groups()
                if tag == 'api':
                    continue
                try:
                    ts = int(datetime.datetime.strptime(stamp[:19], '%Y/%m/%d %H:%M:%S').timestamp())
                except ValueError:
                    ts = int(time.time())
                activity[email] = {'inbound': tag, 'ts': ts}
                seen.add(email)
            f.truncate(0)    # Xray appends with O_APPEND, so writes resume at offset 0
    except FileNotFoundError:
        pass
    # MTProto is served by mtg, not Xray: attribute online users we did not see
    # in the Xray log to an active mtproto inbound they are attached to.
    try:
        onlines = set(ok(call('/clients/onlines', {}, timeout=20), 'онлайн') or [])
        active = set()
        for tags in (ok(call('/clients/activeInbounds', {}, timeout=20), 'активные') or {}).values():
            active.update(tags or [])
        mt = [ib for ib in inbounds() if ib.get('protocol') == 'mtproto' and ib.get('tag') in active]
        for ib in mt:
            for cl in jload(ib.get('settings'), {}).get('clients') or []:
                email = cl.get('email')
                if email in onlines and email not in seen:
                    activity[email] = {'inbound': ib.get('tag'), 'ts': int(time.time())}
    except SystemExit:
        pass
    tmp = ACTIVITY + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(activity, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, ACTIVITY)


# ------------------------------------------------------- xray template I/O
def get_template():
    obj = ok(call('/xray/', {}, form=True), 'шаблон Xray')
    obj = jload(obj, {})
    return jload(obj.get('xraySetting'), {})


def put_template(tpl, previous):
    ok(call('/xray/update', {'xraySetting': json.dumps(tpl, ensure_ascii=False)}, form=True),
       'сохранение шаблона Xray')
    ok(call('/server/restartXrayService', {}), 'перезапуск Xray')
    time.sleep(3)
    err = ok(call('/xray/getXrayResult'), 'состояние Xray') or ''
    if err.strip():
        ok(call('/xray/update', {'xraySetting': json.dumps(previous, ensure_ascii=False)}, form=True),
           'откат шаблона Xray')
        call('/server/restartXrayService', {})
        die('Xray не принял конфигурацию, откат выполнен: ' + err.strip()[:400])


def cmd_enable_access_log(_args):
    tpl = get_template()
    prev = json.loads(json.dumps(tpl))
    log = tpl.setdefault('log', {})
    if log.get('access') == ACCESS_LOG and log.get('maskAddress') == 'quarter':
        return
    log['access'] = ACCESS_LOG
    log['maskAddress'] = 'quarter'      # client IPs are stored masked
    put_template(tpl, prev)




# ------------------------------------------------------------------ nodes
# A node is another 3x-ui panel managed by this one (3x-ui "Nodes"). The node
# side keeps a node-sync API token for the master; pairing hands the node's
# connection details to the master through a one-time encrypted file on the
# node's stub site, so nothing new is exposed and no port is opened.
import base64, hashlib, hmac, ipaddress

NODE_TOKEN_NAME = '3x-ui_reverse node'
PAIR_TTL = 1800                       # a pairing token lives at most 30 minutes
B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'


def _opt(args, name, default=''):
    if name in args:
        i = args.index(name)
        if i + 1 < len(args):
            return args[i + 1]
    return default


def cmd_node_token_create(args):
    """Mint the node-sync token the master uses; any previous one is revoked."""
    tokens = ok(call('/setting/apiTokens'), 'список API-токенов') or []
    for t in tokens:
        if t.get('name') == NODE_TOKEN_NAME:
            ok(call('/setting/apiTokens/delete/%s' % t['id'], {'expectedScope': t.get('scope') or 'node-sync'}),
               'удаление старого токена узла')
    obj = ok(call('/setting/apiTokens/create', {'name': NODE_TOKEN_NAME, 'scope': 'node-sync', 'expiresAt': 0}),
             'создание токена узла')
    token = (obj or {}).get('token') or ''
    if not token:
        die('панель не вернула токен')
    print(token)


def cmd_node_token_check(args):
    """Exit 0 if the node token is still registered in the panel."""
    tokens = ok(call('/setting/apiTokens'), 'список API-токенов') or []
    sys.exit(0 if any(t.get('name') == NODE_TOKEN_NAME and t.get('enabled', True) for t in tokens) else 1)


# ---- pairing crypto: HMAC-SHA256 keystream + HMAC tag (stdlib only)
def _kdf(secret, label):
    return hmac.new(secret, b'3xr-pair:' + label, hashlib.sha256).digest()


def _stream(key, nonce, n):
    out, ctr = b'', 0
    while len(out) < n:
        out += hmac.new(key, nonce + ctr.to_bytes(8, 'big'), hashlib.sha256).digest()
        ctr += 1
    return out[:n]


def _seal(secret, data):
    nonce = secrets.token_bytes(16)
    ct = bytes(a ^ b for a, b in zip(data, _stream(_kdf(secret, b'enc'), nonce, len(data))))
    tag = hmac.new(_kdf(secret, b'mac'), nonce + ct, hashlib.sha256).digest()
    return base64.b64encode(nonce + ct + tag)


def _open(secret, blob):
    try:
        raw = base64.b64decode(blob.strip(), validate=True)
    except (ValueError, TypeError):
        return None
    if len(raw) < 48:
        return None
    nonce, ct, tag = raw[:16], raw[16:-32], raw[-32:]
    if not hmac.compare_digest(tag, hmac.new(_kdf(secret, b'mac'), nonce + ct, hashlib.sha256).digest()):
        return None
    return bytes(a ^ b for a, b in zip(ct, _stream(_kdf(secret, b'enc'), nonce, len(ct))))


def _pair_paths(secret):
    return _kdf(secret, b'dir').hex()[:20], _kdf(secret, b'file').hex()[:32]


def _fmt_token(secret):
    bits = int.from_bytes(secret, 'big')
    chars = ''.join(B32[(bits >> (5 * i)) & 31] for i in range(len(secret) * 8 // 5))[::-1]
    return '-'.join(chars[i:i + 4] for i in range(0, len(chars), 4))


def _parse_token(text):
    s = re.sub(r'[\s\-_]', '', (text or '').upper()).replace('0', 'O').replace('1', 'I').replace('8', 'B')
    if len(s) != 24 or any(ch not in B32 for ch in s):
        return None
    bits = 0
    for ch in s:
        bits = (bits << 5) | B32.index(ch)
    return bits.to_bytes(15, 'big')


def cmd_pair_publish(args):
    """pair-publish SITE DOMAIN PORT BASEPATH TOKENFILE -> TOKEN DIR FILE EXPIRES"""
    site, domain, port, base_path, token_file = args[:5]
    try:
        api_token = open(token_file).read().strip()
    except OSError:
        die('нет API-токена узла')
    secret = secrets.token_bytes(15)
    d, f = _pair_paths(secret)
    exp = int(time.time()) + PAIR_TTL
    bundle = {'v': 1, 'scheme': 'https', 'address': domain, 'port': int(port), 'basePath': base_path,
              'apiToken': api_token, 'country': country_name(), 'name': country_name() or domain, 'exp': exp}
    blob = _seal(secret, json.dumps(bundle).encode())
    path = os.path.join(site, d)
    os.makedirs(path, mode=0o755, exist_ok=True)
    os.chmod(path, 0o755)
    target = os.path.join(path, f)
    with open(target + '.tmp', 'wb') as fh:
        fh.write(blob)
    os.chmod(target + '.tmp', 0o644)
    os.rename(target + '.tmp', target)
    # A fresh file has atime == mtime: the first read by the web server moves
    # atime forward (relatime), which is how the node sees the token was used.
    st = os.stat(target)
    os.utime(target, ns=(st.st_mtime_ns, st.st_mtime_ns))
    print(_fmt_token(secret), path, target, exp)


def cmd_pair_fetch(args):
    """pair-fetch DOMAIN TOKEN OUTFILE: download, verify and decrypt the bundle."""
    domain, token_text, outfile = args[:3]
    secret = _parse_token(token_text)
    if not secret:
        die('токен должен состоять из 24 символов (A–Z, 2–7), например ABCD-EFGH-IJKL-MNOP-QRST-UVWX')
    d, f = _pair_paths(secret)
    url = 'https://%s/%s/%s' % (domain, d, f)
    try:
        body = _fetch(url, timeout=15)
    except Exception as e:
        reason = getattr(e, 'reason', None) or e
        die('узел %s недоступен по HTTPS: %s' % (domain, reason))
    plain = _open(secret, body)
    if plain is None:
        die('токен не подошёл: он введён с ошибкой, уже использован, или экран с токеном на узле закрыт')
    try:
        bundle = json.loads(plain)
    except ValueError:
        die('узел прислал повреждённые данные')
    if int(bundle.get('exp', 0)) < time.time():
        die('срок действия токена истёк — выдай новый на узле')
    fd = os.open(outfile, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as fh:
        json.dump(bundle, fh)
    for key in ('address', 'port', 'basePath', 'name', 'country'):
        print('%s=%s' % (key, bundle.get(key, '')))


# ---- master side: the panel's /nodes API
def _nodes():
    return ok(call('/nodes/list'), 'список узлов') or []


def _private_only(host):
    try:
        addrs = {ai[4][0] for ai in socket.getaddrinfo(host, None)}
    except OSError:
        return False
    try:
        return bool(addrs) and all(not ipaddress.ip_address(a.split('%')[0]).is_global for a in addrs)
    except ValueError:
        return False


def _unique_node_name(base, nodes, skip_id=None):
    names = {n.get('name') for n in nodes if n.get('id') != skip_id}
    if base not in names:
        return base
    i = 2
    while '%s %d' % (base, i) in names:
        i += 1
    return '%s %d' % (base, i)


def cmd_node_name(args):
    """node-name BASE -> a name not used by another node yet."""
    print(_unique_node_name(args[0] if args else 'node', _nodes()))


def parse_panel_url(text):
    """https://host[:port]/path/ -> (scheme, host, port, path)."""
    text = (text or '').strip()
    if '://' not in text:
        text = 'https://' + text
    u = urllib.parse.urlsplit(text)
    if u.scheme not in ('http', 'https') or not u.hostname:
        return None
    try:
        port = u.port or (443 if u.scheme == 'https' else 80)
    except ValueError:
        return None
    path = u.path or '/'
    for tail in ('/panel/api', '/panel'):
        if path.rstrip('/').endswith(tail):
            path = path.rstrip('/')[:-len(tail)]
    path = '/' + path.strip('/') + '/' if path.strip('/') else '/'
    return u.scheme, u.hostname, port, path


def cmd_parse_url(args):
    p = parse_panel_url(args[0] if args else '')
    if not p:
        die('ожидается адрес панели узла вида https://node.example.com/путь/')
    print('scheme=%s\naddress=%s\nport=%s\nbasePath=%s' % p)


def cmd_node_add(args):
    """node-add --from FILE | --url URL (token in $XR_NODE_API_TOKEN) [--name NAME]"""
    src = _opt(args, '--from')
    if src:
        try:
            with open(src) as fh:
                b = json.load(fh)
        except (OSError, ValueError):
            die('нет данных узла — получи токен заново')
        scheme, address, port, path = b.get('scheme', 'https'), b['address'], int(b['port']), b['basePath']
        api_token = b.get('apiToken', '')
        base_name = b.get('name') or address
    else:
        p = parse_panel_url(_opt(args, '--url'))
        if not p:
            die('ожидается адрес панели узла вида https://node.example.com/путь/')
        scheme, address, port, path = p
        api_token = os.environ.get('XR_NODE_API_TOKEN', '').strip()
        base_name = address
    if not api_token:
        die('не задан API-токен узла')
    nodes = _nodes()
    for n in nodes:
        if n.get('address') == address and int(n.get('port') or 0) == port and \
                (n.get('basePath') or '/') == path:
            die('этот узел уже подключён: «%s» (id %s)' % (n.get('name'), n.get('id')))
    name = (_opt(args, '--name') or '').strip() or _unique_node_name(base_name, nodes)
    if any(n.get('name') == name for n in nodes):
        die('узел с именем «%s» уже есть' % name)
    body = {'name': name, 'remark': 'добавлен 3x-ui_reverse', 'scheme': scheme, 'address': address,
            'port': port, 'basePath': path, 'apiToken': api_token, 'enable': True,
            'allowPrivateAddress': _private_only(address), 'tlsVerifyMode': 'verify',
            'inboundSyncMode': 'all', 'inboundTags': [], 'outboundTag': ''}
    reply = call('/nodes/add', body, timeout=40)
    if not reply.get('success'):
        msg = (reply.get('msg') or '').strip()
        hint = ''
        low = msg.lower()
        if '404' in low or "character '<'" in low:
            hint = ' — по этому адресу нет панели: проверь путь'
        elif '401' in low or '403' in low or 'unauthor' in low or 'token' in low:
            hint = ' — неверный API-токен узла'
        elif 'x509' in low or 'certificate' in low:
            hint = ' — сертификат узла не прошёл проверку'
        elif 'timeout' in low or 'refused' in low or 'no such host' in low:
            hint = ' — узел недоступен с этого сервера'
        die('панель не подключила узел: %s%s' % (msg or 'ошибка', hint))
    v = reply.get('obj') or {}
    print('id=%s\nname=%s\nstatus=%s\nversion=%s\nlatency=%s' % (
        v.get('id', ''), v.get('name', name), v.get('status', ''), v.get('panelVersion', ''), v.get('latencyMs', '')))


def _node_state(n):
    if not n.get('enable', True):
        return c('dim', '○ выключен')
    st = n.get('status') or ''
    if st == 'online':
        return c('green', '● в сети') + c('dim', ' %s мс' % n.get('latencyMs', '?'))
    if st == 'offline':
        err = (n.get('lastError') or '').strip()
        return c('red', '✗ недоступен') + (c('dim', ' — ' + err[:60]) if err else '')
    return c('yellow', '◌ проверяется')


def cmd_nodes(args):
    nodes = _nodes()
    if not nodes:
        out(c('dim', 'Узлов пока нет. Подключи первый: «Подключить узел» → «Автоматически» или «Вручную».'))
        return
    head = ['ID', 'УЗЕЛ', 'АДРЕС', 'СОСТОЯНИЕ', 'ВЕРСИЯ', 'INB', 'КЛ.']
    rows = []
    for n in nodes:
        port = int(n.get('port') or 0)
        addr = n.get('address', '') + ('' if port in (443, 0) else ':%d' % port)
        rows.append([str(n.get('id')), n.get('name', ''), addr, _node_state(n),
                     n.get('panelVersion') or '—', str(n.get('inboundCount', 0)), str(n.get('clientCount', 0))])
    widths = [max(width(MARK_RE.sub('', r[i])) for r in rows + [head]) for i in range(len(head))]
    out(c('dim', '  '.join(pad(h, widths[i]) for i, h in enumerate(head))))
    for r in rows:
        cells = []
        for i, v in enumerate(r):
            vis = width(MARK_RE.sub('', v))
            cells.append(v + ' ' * max(0, widths[i] - vis))
        out('  '.join(cells).rstrip())


def cmd_nodes_count(args):
    nodes = _nodes()
    print(len(nodes), sum(1 for n in nodes if n.get('status') == 'online' and n.get('enable', True)))


def cmd_menu_nodes(args):
    for n in _nodes():
        port = int(n.get('port') or 0)
        addr = n.get('address', '') + ('' if port in (443, 0) else ':%d' % port)
        print('%s\t%s\t%s\t%s' % (n.get('id'), n.get('name', ''), _node_state(n), c('dim', addr)))


def cmd_node_card(args):
    nid = int(args[0])
    for n in _nodes():
        if n.get('id') == nid:
            port = int(n.get('port') or 0)
            url = '%s://%s%s%s' % (n.get('scheme', 'https'), n.get('address', ''),
                                   '' if port in (443, 0) else ':%d' % port, n.get('basePath') or '/')
            rows = [('Состояние', _node_state(n)), ('Адрес панели', c('green', url)),
                    ('Версия 3x-ui', n.get('panelVersion') or '—'),
                    ('Xray', '%s %s' % (n.get('xrayVersion') or '—', n.get('xrayState') or '')),
                    ('Inbound-ы', str(n.get('inboundCount', 0))),
                    ('Клиенты', '%s, в сети %s' % (n.get('clientCount', 0), n.get('onlineCount', 0))),
                    ('CPU / память', '%s%% / %s%%' % (round(n.get('cpuPct') or 0), round(n.get('memPct') or 0))),
                    ('Проверка TLS', n.get('tlsVerifyMode') or 'verify')]
            if n.get('lastHeartbeat'):
                rows.append(('Последний отклик', ago(n['lastHeartbeat'])))
            for k, v in rows:
                out('  ' + c('dim', pad(k, 18)) + v)
            print('#name=%s' % n.get('name', ''))
            print('#enable=%s' % (1 if n.get('enable', True) else 0))
            return
    die('узел %s не найден' % nid)


def cmd_node_del(args):
    ok(call('/nodes/del/%d' % int(args[0]), {}), 'удаление узла')


def cmd_node_enable(args):
    ok(call('/nodes/setEnable/%d' % int(args[0]), {'enable': args[1] == '1'}), 'включение узла')


def cmd_node_probe(args):
    v = ok(call('/nodes/probe/%d' % int(args[0]), {}, timeout=40), 'проверка узла') or {}
    print('status=%s\nerror=%s\nlatency=%s' % (v.get('status', ''), v.get('error', ''), v.get('latencyMs', '')))


# ------------------------------------------------------------------ PDF
# The server summary as a page styled like a modern landing site: navbar,
# gradient hero with buttons and QR, feature tiles, form-like credential
# fields, subscription cards and a dark footer. Links are clickable.
# Needs python3-reportlab and fonts-dejavu-core.
PDF_FONTS = {
    'Sans': 'DejaVuSans.ttf', 'Sans-Bold': 'DejaVuSans-Bold.ttf',
    'Mono': 'DejaVuSansMono.ttf', 'Mono-Bold': 'DejaVuSansMono-Bold.ttf',
}
PDF_FONT_DIRS = ('/usr/share/fonts/truetype/dejavu', '/usr/share/fonts/dejavu', '/usr/share/fonts/TTF',
                 '/usr/share/fonts/truetype')


def _pdf_fonts():
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.ttfonts import TTFont
    for name, fname in PDF_FONTS.items():
        path = next((os.path.join(d, fname) for d in PDF_FONT_DIRS if os.path.isfile(os.path.join(d, fname))), None)
        if not path:
            die('не найден шрифт %s — установи fonts-dejavu-core' % fname)
        pdfmetrics.registerFont(TTFont('XR-' + name, path))


def cmd_pdf(args):
    """pdf OUT DATAFILE — DATAFILE has "key<TAB>value" lines."""
    out_path, data_file = args[:2]
    try:
        from reportlab.pdfgen import canvas
        from reportlab.lib.colors import HexColor, white, Color
        from reportlab.lib.pagesizes import A4
        from reportlab.graphics.barcode.qr import QrCodeWidget
        from reportlab.graphics.shapes import Drawing
        from reportlab.graphics import renderPDF
        from reportlab.pdfbase.pdfmetrics import stringWidth
    except ImportError:
        die('нет python3-reportlab: apt-get install python3-reportlab fonts-dejavu-core')
    _pdf_fonts()
    d = {}
    with open(data_file, encoding='utf-8') as fh:
        for line in fh:
            k, _, v = line.rstrip('\n').partition('\t')
            if k:
                d[k] = v

    W, H = A4
    M = 34
    INK, BODY, MUTED, FAINT = HexColor('#0B1020'), HexColor('#334155'), HexColor('#64748B'), HexColor('#94A3B8')
    BG, CARD, LINE, FIELD = HexColor('#F4F6FB'), white, HexColor('#E2E8F0'), HexColor('#F8FAFC')
    INDIGO, VIOLET, CYAN = HexColor('#4F46E5'), HexColor('#7C3AED'), HexColor('#06B6D4')
    AMBER, GREEN, ROSE = HexColor('#D97706'), HexColor('#059669'), HexColor('#E11D48')

    tmp_path = out_path + '.tmp'
    c = canvas.Canvas(tmp_path, pagesize=A4)
    c.setTitle('3x-ui_reverse — %s' % d.get('domain', ''))
    c.setAuthor('3x-ui_reverse')
    c.setSubject('Параметры сервера')
    st = {'y': 0, 'page': 1}

    # ---------------------------------------------------------- primitives
    def font(name, size):
        c.setFont('XR-' + name, size)

    def text(x, y, s, f='Sans', size=10, color=INK):
        font(f, size)
        c.setFillColor(color)
        c.drawString(x, y, s)

    def rtext(x, y, s, f='Sans', size=10, color=INK):
        font(f, size)
        c.setFillColor(color)
        c.drawRightString(x, y, s)

    def sw(s, f, size):
        return stringWidth(s, 'XR-' + f, size)

    def fit(s, f, size, width, floor=7.0):
        """Largest size <= size at which s fits width (down to floor)."""
        while size > floor and sw(s, f, size) > width:
            size -= 0.25
        return size

    def wrap(s, f, size, width):
        lines, cur = [], ''
        for word in re.findall(r'\S+\s*', s) or ['']:
            if sw(cur + word.rstrip(), f, size) <= width:
                cur += word
                continue
            if cur:
                lines.append(cur.rstrip())
                cur = ''
            for ch in word:
                if sw(cur + ch, f, size) > width and cur.strip():
                    lines.append(cur.rstrip())
                    cur = ''
                cur += ch
        lines.append(cur.rstrip())
        return lines

    def rrect(x, y, w, h, r, fill=None, stroke=None, width=0.8, alpha=None):
        c.saveState()
        if fill is not None:
            c.setFillColor(fill)
        if alpha is not None:          # after the colour: setFillColor resets alpha
            c.setFillAlpha(alpha)
        if stroke is not None:
            c.setStrokeColor(stroke)
            c.setLineWidth(width)
        c.roundRect(x, y, w, h, r, stroke=1 if stroke is not None else 0, fill=1 if fill is not None else 0)
        c.restoreState()

    def gradient_rect(x, y, w, h, r, stops, diagonal=True):
        c.saveState()
        p = c.beginPath()
        p.roundRect(x, y, w, h, r)
        c.clipPath(p, stroke=0, fill=0)
        c.linearGradient(x, y + h if diagonal else y, x + w, y, [HexColor(s) for s in stops], extend=True)
        c.restoreState()

    def shadow(x, y, w, h, r):
        for i, a in ((6, 0.025), (3, 0.04), (1.2, 0.05)):
            rrect(x - i / 2, y - i, w + i, h + i, r + i / 2, fill=HexColor('#0F172A'), alpha=a)

    def link(url, x, y, w, h):
        if url:
            c.linkURL(url, (x, y, x + w, y + h), relative=0, thickness=0)

    def qr(value, x, y, size):
        wdg = QrCodeWidget(value, barLevel='M')
        b = wdg.getBounds()
        bw, bh = b[2] - b[0], b[3] - b[1]
        dr = Drawing(size, size, transform=[size / bw, 0, 0, size / bh, 0, 0])
        dr.add(wdg)
        renderPDF.draw(dr, c, x, y)

    def icon(x, y, glyph, color, size=26):
        """Rounded tinted square with a glyph — like a website feature icon."""
        rrect(x, y, size, size, 8, fill=color, alpha=0.12)
        gs = size * 0.5
        text(x + (size - sw(glyph, 'Sans-Bold', gs)) / 2, y + size * 0.3, glyph, 'Sans-Bold', gs, color)

    def page_bg():
        c.setFillColor(BG)
        c.rect(0, 0, W, H, stroke=0, fill=1)

    def footer():
        h = 46
        c.setFillColor(INK)
        c.rect(0, 0, W, h, stroke=0, fill=1)
        gradient_rect(0, h - 2, W, 2, 0, ['#06B6D4', '#6366F1', '#A855F7'], diagonal=False)
        text(M, 26, '◆ 3x-ui_reverse', 'Sans-Bold', 9, white)
        text(M, 13, 'Создано %s · %s' % (d.get('date', ''), d.get('version', '')), 'Sans', 7, FAINT)
        rtext(W - M, 26, 'Документ содержит пароль и токены — храни его в защищённом месте', 'Sans', 7, HexColor('#FCA5A5'))
        rtext(W - M, 13, 'стр. %d' % st['page'], 'Sans', 7, FAINT)

    def new_page():
        footer()
        c.showPage()
        st['page'] += 1
        page_bg()
        st['y'] = H - M

    def need(h):
        if st['y'] - h < 62:
            new_page()

    def section(eyebrow, title, subtitle='', body=0):
        need(60 + body)                # keep the heading with its content
        y = st['y']
        text(M, y - 10, eyebrow.upper(), 'Sans-Bold', 7.5, INDIGO)
        text(M, y - 30, title, 'Sans-Bold', 17, INK)
        if subtitle:
            text(M, y - 46, subtitle, 'Sans', 9, MUTED)
            st['y'] = y - 60
        else:
            st['y'] = y - 44

    # ---------------------------------------------------------- navbar
    page_bg()
    nav_h = 48
    c.setFillColor(white)
    c.rect(0, H - nav_h, W, nav_h, stroke=0, fill=1)
    c.setStrokeColor(LINE)
    c.setLineWidth(0.6)
    c.line(0, H - nav_h, W, H - nav_h)
    gradient_rect(M, H - nav_h + 12, 24, 24, 7, ['#06B6D4', '#6366F1', '#A855F7'])
    text(M + 6.5, H - nav_h + 19.5, '3x', 'Sans-Bold', 9, white)
    text(M + 32, H - nav_h + 19, '3x-ui_reverse', 'Sans-Bold', 12, INK)
    x = W - M
    pill = '● В работе'
    pw = sw(pill, 'Sans-Bold', 8) + 18
    rrect(x - pw, H - nav_h + 14, pw, 20, 10, fill=GREEN, alpha=0.12)
    text(x - pw + 9, H - nav_h + 20.5, pill, 'Sans-Bold', 8, GREEN)
    x -= pw + 16
    for item in reversed(('Сервер', 'Доступ', 'Подписки')):
        iw = sw(item, 'Sans', 8.5)
        text(x - iw, H - nav_h + 20.5, item, 'Sans', 8.5, MUTED)
        x -= iw + 16

    # ---------------------------------------------------------- hero
    hero_top = H - nav_h - 18
    hero_h = 214
    hx, hy, hw = M, hero_top - hero_h, W - 2 * M
    shadow(hx, hy, hw, hero_h, 18)
    gradient_rect(hx, hy, hw, hero_h, 18, ['#1E1B4B', '#4338CA', '#7C3AED', '#0891B2'])
    c.saveState()                       # decorative rings
    p = c.beginPath()
    p.roundRect(hx, hy, hw, hero_h, 18)
    c.clipPath(p, stroke=0, fill=0)
    c.setStrokeColor(white)
    for r, a in ((150, 0.07), (110, 0.08), (70, 0.09)):
        c.setStrokeAlpha(a)
        c.setLineWidth(18)
        c.circle(hx + hw - 40, hy + hero_h - 10, r, stroke=1, fill=0)
    c.restoreState()
    qr_box = 132
    content_w = hw - qr_box - 64
    eyebrow = 'СЕРВЕР ГОТОВ К РАБОТЕ'
    ew = sw(eyebrow, 'Sans-Bold', 7.5) + 20
    rrect(hx + 26, hy + hero_h - 44, ew, 18, 9, fill=white, alpha=0.16)
    text(hx + 36, hy + hero_h - 38, eyebrow, 'Sans-Bold', 7.5, white)
    dom = d.get('domain', '')
    ds = fit(dom, 'Sans-Bold', 28, content_w, 14)
    text(hx + 26, hy + hero_h - 82, dom, 'Sans-Bold', ds, white)
    sub = 'Панель 3x-ui за HTTPS-прокси: снаружи сервер выглядит как обычный сайт, панель и подписки скрыты за секретными путями.'
    for i, ln in enumerate(wrap(sub, 'Sans', 9.5, content_w)[:3]):
        text(hx + 26, hy + hero_h - 104 - i * 14, ln, 'Sans', 9.5, HexColor('#E0E7FF'))
    # buttons
    by = hy + 30
    bx = hx + 26
    if d.get('panel_url'):
        label = 'Открыть панель  →'
        bw = sw(label, 'Sans-Bold', 9.5) + 32
        rrect(bx, by, bw, 30, 15, fill=white)
        text(bx + 16, by + 10.5, label, 'Sans-Bold', 9.5, INDIGO)
        link(d['panel_url'], bx, by, bw, 30)
        bx += bw + 10
    if d.get('user1_sub'):
        label = 'Подписка user1'
        bw = sw(label, 'Sans-Bold', 9.5) + 32
        rrect(bx, by, bw, 30, 15, stroke=white, width=1)
        text(bx + 16, by + 10.5, label, 'Sans-Bold', 9.5, white)
        link(d['user1_sub'], bx, by, bw, 30)
    # QR card
    if d.get('panel_url'):
        qx, qy = hx + hw - qr_box - 24, hy + (hero_h - qr_box - 18) / 2 + 8
        rrect(qx, qy - 18, qr_box, qr_box + 18, 14, fill=white)
        qr(d['panel_url'], qx + 12, qy - 4, qr_box - 24)
        cap = 'Сканируй — откроется панель'
        text(qx + (qr_box - sw(cap, 'Sans', 7)) / 2, qy - 11, cap, 'Sans', 7, MUTED)
    st['y'] = hy - 20

    # ---------------------------------------------------------- feature tiles
    tiles = [('⚙', INDIGO, 'Веб-сервер', d.get('proxy_label', '—')),
             ('⌂', CYAN, 'Сервер', d.get('server_label') or '—'),
             ('⚡', AMBER, 'Сеть', d.get('bbr_label') or 'стандартная'),
             ('✓', GREEN, 'Сертификат', d.get('tls_label') or '—')]
    gap = 10
    tw = (W - 2 * M - gap * 3) / 4
    th = 64
    for i, (g, col, title, val) in enumerate(tiles):
        tx = M + i * (tw + gap)
        ty = st['y'] - th
        shadow(tx, ty, tw, th, 12)
        rrect(tx, ty, tw, th, 12, fill=CARD)
        icon(tx + 12, ty + th - 36, g, col, 24)
        text(tx + 44, ty + th - 22, title, 'Sans', 7.5, MUTED)
        vs = fit(val, 'Sans-Bold', 9.5, tw - 24, 7)
        text(tx + 12, ty + 12, val, 'Sans-Bold', vs, INK)
    st['y'] -= th + 26

    # ---------------------------------------------------------- access
    if d.get('panel_url'):
        section('Доступ', 'Вход в панель 3x-ui', 'Панель слушает только 127.0.0.1 — снаружи она доступна лишь по секретному пути.',
                body=18 + (3 if d.get('node_token') else 2) * 48)
        fields = [('Адрес панели', d['panel_url'], 'Mono', INK, True),
                  ('Логин', d.get('user', ''), 'Mono-Bold', VIOLET, False),
                  ('Пароль', d.get('pass', ''), 'Mono-Bold', VIOLET, False)]
        if d.get('node_token'):
            fields.append(('API-токен узла · для подключения к мастер-панели', d['node_token'], 'Mono', INK, False))
        layout = [[fields[0]], fields[1:3]] + ([[fields[3]]] if len(fields) > 3 else [])
        card_h = 18 + len(layout) * 48
        need(card_h)
        cy = st['y'] - card_h
        shadow(M, cy, W - 2 * M, card_h, 14)
        rrect(M, cy, W - 2 * M, card_h, 14, fill=CARD)
        fy = st['y'] - 18
        for line in layout:
            n = len(line)
            fw = (W - 2 * M - 32 - (n - 1) * 16) / n
            for j, (label, val, f, col, is_url) in enumerate(line):
                fx = M + 16 + j * (fw + 16)
                text(fx, fy - 8, label, 'Sans-Bold', 7.5, MUTED)
                rrect(fx, fy - 40, fw, 26, 8, fill=FIELD, stroke=LINE, width=0.8)
                vs = fit(val, f, 10, fw - 22, 7)
                text(fx + 11, fy - 31, val, f, vs, col)
                if is_url:
                    link(val, fx, fy - 40, fw, 26)
            fy -= 48
        st['y'] = cy - 26

    # ---------------------------------------------------------- subscriptions
    if d.get('sub'):
        section('Подписки', 'Три формата для любых клиентов',
                'Полный адрес: https://%s<путь>SUB_ID — Sub ID есть в карточке пользователя.' % d.get('domain', ''),
                body=104)
        subs = [('Обычная', 'VLESS · Trojan · MTProto', d.get('sub', ''), 'Happ, v2rayNG, Streisand, Hiddify', INDIGO),
                ('JSON', 'конфигурация Xray', d.get('json', ''), 'v2rayN, v2rayNG', CYAN),
                ('Mihomo / Clash', 'YAML-профиль', d.get('clash', ''), 'Clash Verge, FlClash, Mihomo', VIOLET)]
        cw = (W - 2 * M - 2 * 12) / 3
        ch = 104
        need(ch)
        for i, (title, kind, path, apps, col) in enumerate(subs):
            x0 = M + i * (cw + 12)
            y0 = st['y'] - ch
            shadow(x0, y0, cw, ch, 14)
            rrect(x0, y0, cw, ch, 14, fill=CARD)
            c.saveState()                  # accent stripe along the card's rounded top
            p = c.beginPath()
            p.roundRect(x0, y0, cw, ch, 14)
            c.clipPath(p, stroke=0, fill=0)
            p2 = c.beginPath()
            p2.rect(x0, y0 + ch - 4, cw, 4)
            c.clipPath(p2, stroke=0, fill=0)
            c.linearGradient(x0, y0, x0 + cw, y0, [HexColor(h) for h in
                             (['#06B6D4', '#6366F1'] if i != 2 else ['#8B5CF6', '#EC4899'])], extend=True)
            c.restoreState()
            text(x0 + 14, y0 + ch - 24, title, 'Sans-Bold', 11, INK)
            text(x0 + 14, y0 + ch - 37, kind, 'Sans', 7.5, MUTED)
            rrect(x0 + 12, y0 + 34, cw - 24, 22, 7, fill=AMBER, alpha=0.10)
            ps = fit(path, 'Mono-Bold', 9, cw - 40, 6.5)
            text(x0 + 20, y0 + 41.5, path, 'Mono-Bold', ps, AMBER)
            for k, ln in enumerate(wrap(apps, 'Sans', 7, cw - 28)[:2]):
                text(x0 + 14, y0 + 20 - k * 9, ln, 'Sans', 7, MUTED)
        st['y'] -= ch + 26

    # ---------------------------------------------------------- user1
    if d.get('user1_sub'):
        section('Быстрый старт', 'Подключи первое устройство',
                'Отсканируй QR в приложении или скопируй ссылку подписки пользователя user1.', body=136)
        links = [('Обычная', d['user1_sub']), ('JSON', d.get('user1_json', '')), ('Mihomo / Clash', d.get('user1_clash', ''))]
        box = 108
        ch = box + 28
        need(ch)
        y0 = st['y'] - ch
        shadow(M, y0, W - 2 * M, ch, 14)
        rrect(M, y0, W - 2 * M, ch, 14, fill=CARD)
        rrect(M + 14, y0 + 14, box, box, 12, fill=FIELD, stroke=LINE)
        qr(d['user1_sub'], M + 20, y0 + 20, box - 12)
        lx = M + 14 + box + 18
        lw = W - M - 16 - lx
        ly = y0 + ch - 22
        for label, url in links:
            text(lx, ly, label, 'Sans-Bold', 7.5, MUTED)
            rrect(lx, ly - 27, lw, 20, 7, fill=FIELD, stroke=LINE, width=0.7)
            us = fit(url, 'Mono', 8.5, lw - 18, 6)
            text(lx + 9, ly - 20.5, url, 'Mono', us, INK)
            link(url, lx, ly - 27, lw, 20)
            ly -= 38
        st['y'] = y0 - 22

    # ---------------------------------------------------------- server details
    section('Сервер', 'Технические детали', body=100)
    rows = [('Домен', 'https://%s' % d.get('domain', '')), ('Веб-сервер', d.get('proxy_line', '')),
            ('TLS-сертификаты', d.get('certpath', '')), ('Порт панели (локальный)', d.get('port', '') or '—')]
    rh = 22
    ch = 10 + len(rows) * rh
    need(ch)
    y0 = st['y'] - ch
    shadow(M, y0, W - 2 * M, ch, 14)
    rrect(M, y0, W - 2 * M, ch, 14, fill=CARD)
    ry = st['y'] - 20
    for i, (k, v) in enumerate(rows):
        if i:
            c.setStrokeColor(LINE)
            c.setLineWidth(0.5)
            c.line(M + 14, ry + 14, W - M - 14, ry + 14)
        text(M + 16, ry, k, 'Sans', 8.5, MUTED)
        vs = fit(v, 'Mono', 8.5, W - 2 * M - 200, 6.5)
        rtext(W - M - 16, ry, v, 'Mono', vs, BODY)
        ry -= rh
    st['y'] = y0 - 10

    footer()
    c.save()
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, out_path)


# ------------------------------------------------------------------ iPerf3 to Russia
# Public iperf3 servers of Russian providers; the list (primary + fallback per
# city) follows github.com/itdoginfo/russian-iperf3-servers.
IPERF_RU = [
    ('Москва', 'spd-rudp.hostkey.ru', 'Тверь', 'st.tver.ertelecom.ru'),
    ('Санкт-Петербург', 'st.spb.ertelecom.ru', 'Ярославль', 'st.yar.ertelecom.ru'),
    ('Нижний Новгород', 'st.nn.ertelecom.ru', 'Нижний Новгород', 'speed-nn.vtt.net'),
    ('Челябинск', 'st.chel.ertelecom.ru', 'Магнитогорск', 'st.mgn.ertelecom.ru'),
    ('Тюмень', 'st.tmn.ertelecom.ru', 'Красноярск', 'st.krsk.ertelecom.ru'),
]
IPERF_PORTS = range(5201, 5210)


def iperf_servers():
    """XR_IPERF="Город=host[,Город=host…]" replaces the built-in list."""
    custom = os.environ.get('XR_IPERF', '').strip()
    if not custom:
        return IPERF_RU
    out = []
    for item in custom.split(','):
        city, _, host = item.partition('=')
        if city.strip() and host.strip():
            out.append((city.strip(), host.strip(), '', ''))
    return out or IPERF_RU


def _iperf_run(host, port, reverse, secs, streams=8):
    """One iperf3 run -> (result dict | None, error text, retry_other_port)."""
    import subprocess
    cmd = ['iperf3', '-c', host, '-p', str(port), '-t', str(secs), '-P', str(streams), '-J',
           '--connect-timeout', '4000'] + (['-R'] if reverse else [])
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=secs + 20)
    except subprocess.TimeoutExpired:
        return None, 'таймаут', True
    except FileNotFoundError:
        die('iperf3 не установлен')
    try:
        j = json.loads(r.stdout)
    except ValueError:
        return None, (r.stderr or r.stdout or 'нет ответа').strip().splitlines()[-1][:80], True
    err = (j.get('error') or '').lower()
    if err:
        hard = any(s in err for s in ('resolve', 'name or service', 'no route', 'network is unreachable'))
        return None, j.get('error', '')[:80], not hard
    end = j.get('end') or {}
    bps = (end.get('sum_received') or {}).get('bits_per_second') or \
        (end.get('sum_sent') or {}).get('bits_per_second') or 0
    rtts = [((s.get('sender') or {}).get('mean_rtt') or 0) for s in end.get('streams') or []]
    rtts = [x for x in rtts if x]
    return {'mbps': bps / 1e6, 'rtt': (sum(rtts) / len(rtts) / 1000) if rtts else None}, '', False


def _iperf_host(host, secs):
    """Upload (VPS -> server) and download (server -> VPS) on the first free port."""
    last = 'нет свободного порта'
    for port in IPERF_PORTS:
        up, err, retry = _iperf_run(host, port, False, secs)
        if not up:
            last = err or last
            if retry:
                continue
            break
        down = None
        for p2 in [port] + [p for p in IPERF_PORTS if p != port]:
            down, err, retry = _iperf_run(host, p2, True, secs)
            if down or not retry:
                break
        return {'up': up['mbps'], 'down': down['mbps'] if down else None, 'rtt': up['rtt'],
                'port': port}, ''
    return None, last


def cmd_iperf_cities(args):
    for city, *_ in iperf_servers():
        print(city)


def cmd_iperf_city(args):
    """iperf-city INDEX SECONDS -> one JSON line."""
    i, secs = int(args[0]), int(args[1])
    city, host, fcity, fhost = iperf_servers()[i]
    res, err = _iperf_host(host, secs)
    used_city, used_host, fallback = city, host, False
    if not res and fhost:
        res2, err2 = _iperf_host(fhost, secs)
        if res2:
            res, used_city, used_host, fallback = res2, fcity, fhost, True
        else:
            err = err or err2
    row = {'city': city, 'via': used_city if fallback else '', 'host': used_host, 'error': '' if res else err}
    if res:
        row.update(res)
    print(json.dumps(row, ensure_ascii=False))


def _speed(v):
    if v is None:
        return c('dim', '—')
    if v >= 1000:
        return '%.2f Гбит/с' % (v / 1000)
    return '%.0f Мбит/с' % v if v >= 10 else '%.1f Мбит/с' % v


def _iperf_reason(err):
    e = (err or '').lower()
    if 'busy' in e or 'свободного' in e:
        return 'занят другими тестами — повтори позже'
    if 'name or service' in e or 'resolve' in e:
        return 'сервер не найден в DNS'
    if 'таймаут' in e or 'timed out' in e or 'timeout' in e:
        return 'нет ответа (таймаут)'
    if 'unable to connect' in e or 'refused' in e or 'unreachable' in e or 'no route' in e:
        return 'не отвечает (закрыт или блокирует этот VPS)'
    return 'ошибка: ' + (err or '?')[:50]


def _vpad(s, w):
    return s + ' ' * max(0, w - len(MARK_RE.sub('', s)))


def cmd_iperf_table(args):
    rows = []
    with open(args[0], encoding='utf-8') as fh:
        for line in fh:
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
    if not rows:
        out(c('red', '✗ Нет результатов.'))
        return
    peak = max([r.get('up') or 0 for r in rows] + [1])
    bar_w = 14
    out(c('dim', '  %-18s  %-*s %-13s %-13s %s' % ('ГОРОД', bar_w + 14, 'VPS → РФ (отдача)', 'РФ → VPS', 'ПИНГ', '')))
    for r in rows:
        name = r['city'] + (' → ' + r['via'] if r.get('via') else '')
        if r.get('error'):
            out('  %s  %s' % (_vpad(name, 18), c('red', '✗ ' + _iperf_reason(r['error']))))
            continue
        up = r.get('up') or 0
        filled = max(1, round(bar_w * up / peak)) if up else 0
        bar = c('green' if up >= 300 else ('yellow' if up >= 50 else 'red'), '█' * filled) + c('dim', '░' * (bar_w - filled))
        rtt = ('%.0f мс' % r['rtt']) if r.get('rtt') else '—'
        out('  %s  %s %s %s %s' % (_vpad(name, 18), bar, _vpad(_speed(r.get('up')), 13),
                                   _vpad(_speed(r.get('down')), 13), rtt))
    ok_rows = [r for r in rows if not r.get('error')]
    out('')
    if ok_rows:
        avg_up = sum(r.get('up') or 0 for r in ok_rows) / len(ok_rows)
        out('  Средняя отдача в РФ: %s · отвечают %d из %d серверов' % (c('accent', _speed(avg_up)), len(ok_rows), len(rows)))
    out(c('dim', '  «VPS → РФ» — с какой скоростью сервер отдаёт данные клиентам в России (главное для VPN).'))
    out(c('dim', '  Серверы: github.com/itdoginfo/russian-iperf3-servers'))


# ------------------------------------------------------------ self-update
REPO_RE = re.compile(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+')
TAG_VER_RE = re.compile(r'v?\d+(\.\d+){0,3}')


def verkey(tag):
    return tuple(int(x) for x in re.findall(r'\d+', tag))


def cmd_update_check(args):
    """update-check REPO CURRENT -> "TAG SHORT_SHA newer|same|older"."""
    repo, current = args[0], args[1] if len(args) > 1 else 'v0'
    if not REPO_RE.fullmatch(repo):
        die('репозиторий указывается как owner/name')
    api = 'https://api.github.com/repos/' + repo
    tag = ''
    try:
        tag = json.loads(_fetch(api + '/releases/latest', 10)).get('tag_name') or ''
    except Exception:
        pass
    if not TAG_VER_RE.fullmatch(tag or ''):
        try:
            tags = json.loads(_fetch(api + '/tags?per_page=100', 10))
        except Exception as e:
            die('не удалось получить теги %s: %s' % (repo, e))
        names = [t.get('name', '') for t in tags if TAG_VER_RE.fullmatch(t.get('name', ''))]
        if not names:
            die('в %s нет тегов версий вида v1.2.3' % repo)
        tag = max(names, key=verkey)
    sha = '-'
    try:
        sha = (json.loads(_fetch(api + '/commits/' + tag, 10)).get('sha') or '-')[:7]
    except Exception:
        pass
    rel = 'newer' if verkey(tag) > verkey(current) else ('same' if verkey(tag) == verkey(current) else 'older')
    print(tag, sha, rel)


def cmd_update_fetch(args):
    """update-fetch REPO TAG ASSET DEST — download the script of a tagged release."""
    repo, tag, asset, dest = args[:4]
    if not REPO_RE.fullmatch(repo) or not TAG_VER_RE.fullmatch(tag):
        die('некорректный репозиторий или тег')
    url = 'https://raw.githubusercontent.com/%s/%s/%s' % (repo, tag, asset)
    try:
        body = _fetch(url, 30)
    except Exception as e:
        die('не удалось скачать %s: %s' % (url, e))
    if not body.startswith('#!/usr/bin/env bash'):
        die('скачанный файл не похож на скрипт 3x-ui_reverse')
    with open(dest, 'w') as f:
        f.write(body)
    os.chmod(dest, 0o700)


def cmd_ping(_args):
    ok(call('/inbounds/list', timeout=10), 'проверка API')


COMMANDS = {
    'ping': cmd_ping, 'pick-sni': None, 'create-inbounds': cmd_create_inbounds,
    'inbounds': cmd_inbounds, 'ports': cmd_ports, 'ports-all': cmd_ports_all, 'all-ports': cmd_all_ports,
    'check-port': cmd_check_port, 'check-name': cmd_check_name, 'sni-list': cmd_sni_list,
    'inbound-info': cmd_inbound_info, 'menu-all-inbounds': cmd_menu_all_inbounds, 'menu-kinds': cmd_menu_kinds,
    'kind-info': cmd_kind_info, 'set-port': cmd_set_port, 'set-name': cmd_set_name, 'set-sni': cmd_set_sni,
    'set-tls': cmd_set_tls, 'set-enable': cmd_set_enable, 'del-inbound': cmd_del_inbound,
    'users': cmd_users, 'stats': cmd_stats, 'user-card': cmd_user_card,
    'menu-users': cmd_menu_users, 'menu-groups': cmd_menu_groups, 'menu-inbounds': cmd_menu_inbounds,
    'add-user': cmd_add_user, 'del-user': cmd_del_user, 'sub-id': cmd_sub_id,
    'set-inbounds': cmd_set_inbounds, 'set-group': cmd_set_group,
    'group-create': cmd_group_create, 'group-rename': cmd_group_rename, 'group-delete': cmd_group_delete,
    'group-add-users': cmd_group_add_users, 'group-inbounds': cmd_group_inbounds,
    'groups': cmd_groups, 'menu-members': cmd_menu_members, 'group-set-members': cmd_group_set_members,
    'country': cmd_country, 'update-check': cmd_update_check, 'update-fetch': cmd_update_fetch,
    'dns-check': cmd_dns_check, 'public-ip': cmd_public_ip,
    'track-activity': cmd_track_activity, 'enable-access-log': cmd_enable_access_log,
    'node-token-create': cmd_node_token_create, 'node-token-check': cmd_node_token_check,
    'pair-publish': cmd_pair_publish, 'pair-fetch': cmd_pair_fetch, 'node-name': cmd_node_name,
    'parse-url': cmd_parse_url, 'node-add': cmd_node_add, 'nodes': cmd_nodes, 'nodes-count': cmd_nodes_count,
    'menu-nodes': cmd_menu_nodes, 'node-card': cmd_node_card, 'node-del': cmd_node_del,
    'node-enable': cmd_node_enable, 'node-probe': cmd_node_probe, 'pdf': cmd_pdf,
    'iperf-cities': cmd_iperf_cities, 'iperf-city': cmd_iperf_city, 'iperf-table': cmd_iperf_table,
}

if __name__ == '__main__':
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        die('команда: ' + ', '.join(COMMANDS))
    if sys.argv[1] == 'pick-sni':
        print(','.join(pick_sni(int(sys.argv[2]), sys.argv[3:])))
    else:
        COMMANDS[sys.argv[1]](sys.argv[2:])
XRHELPER
  chmod 700 "$tmp"; mv -f "$tmp" "$HELPER"
}

# The dialog program (TUI + CLI renderer); written to a private runtime dir.
write_ui_program(){
  cat > "$1" <<'XRTUI'
#!/usr/bin/env python3
# 3x-ui_reverse user interface. Started by the bash script, never on its own.
#   serve DIR — full-screen curses TUI; dialogs are requested over DIR/req and
#               answered over DIR/resp ("RC LEN\n" + LEN characters of payload).
#   cli       — one dialog as classic text (numbered lists), request on stdin,
#               answer on stdout, return code = exit status.
# Text may contain markup: {green} {red} {yellow} {accent} {cyan} {blue}
# {magenta} {dim} {bold} {white} … {/}. Lines without markup are coloured by
# their status glyph (● ✓ green, ✗ red, ⚠ yellow, ○ dim).
import json, locale, os, re, select, sys, time, unicodedata

os.environ.setdefault('ESCDELAY', '25')
try:
    locale.setlocale(locale.LC_ALL, '')
except locale.Error:
    pass

APP = '3x-ui_reverse'
TAG_RE = re.compile(r'\{(/|green|red|yellow|accent|cyan|blue|magenta|dim|bold|white)\}')
ANSI_RE = re.compile(r'\x1b\[[0-9;]*m')
GLYPHS = {'●': 'green', '✓': 'green', '✗': 'red', '⚠': 'yellow', '○': 'dim', '➜': 'accent'}
SPIN = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
LOGO = [
    '██████╗ ██╗  ██╗      ██╗   ██╗██╗',
    '╚════██╗╚██╗██╔╝      ██║   ██║██║',
    ' █████╔╝ ╚███╔╝ █████╗██║   ██║██║',
    ' ╚═══██╗ ██╔██╗ ╚════╝██║   ██║██║',
    '██████╔╝██╔╝ ██╗      ╚██████╔╝██║',
    '╚═════╝ ╚═╝  ╚═╝       ╚═════╝ ╚═╝',
]
LOGO_SUB = '━━━━━━━  r e v e r s e  ━━━━━━━'
LOGO_H = len(LOGO) + 2                    # logo, subtitle and a blank line
LOGO_256 = [51, 45, 39, 33, 69, 105]      # cyan → blue → violet gradient
LOGO_8 = [6, 6, 6, 4, 4, 5]
LOGO_ANSI = ['38;5;%d' % n for n in LOGO_256]


def cwidth(ch):
    if unicodedata.combining(ch) or ch in '‍️':
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ('W', 'F') else 1


def swidth(s):
    return sum(cwidth(c) for c in ANSI_RE.sub('', s))


def strip_markup(s):
    return TAG_RE.sub('', s)


def parse_line(line, base=None):
    """One text line -> [(text, style)]."""
    if not TAG_RE.search(line):
        for i, ch in enumerate(line):
            if ch in GLYPHS:
                return ([(line[:i], base)] if i else []) + [(line[i:], GLYPHS[ch])]
        return [(line, base)]
    segs, style, pos = [], base, 0
    for m in TAG_RE.finditer(line):
        if m.start() > pos:
            segs.append((line[pos:m.start()], style))
        style = base if m.group(1) == '/' else m.group(1)
        pos = m.end()
    if pos < len(line):
        segs.append((line[pos:], style))
    return segs


def wrap_segs(segs, width):
    """Word-wrap styled segments to a display width."""
    width = max(4, width)
    lines, cur, w = [], [], 0
    for text, st in segs:
        for tok in re.findall(r'\S+|\s+', text):
            tw = swidth(tok)
            if w + tw > width and w > 0:
                lines.append(cur)
                cur, w = [], 0
                if tok.isspace():
                    continue
            while tw > width:                      # hard-split very long words
                part, pw = '', 0
                for ch in tok:
                    if pw + cwidth(ch) > width - w:
                        break
                    part += ch
                    pw += cwidth(ch)
                cur.append((part, st))
                lines.append(cur)
                cur, w = [], 0
                tok = tok[len(part):]
                tw = swidth(tok)
            if tok:
                cur.append((tok, st))
                w += tw
    lines.append(cur)
    return lines


def text_lines(text, width, base=None):
    out = []
    for raw in (text or '').split('\n'):
        out.extend(wrap_segs(parse_line(raw.expandtabs(4), base), width))
    return out


def fit(s, width):
    """Truncate a plain string to a display width."""
    out, w = '', 0
    for ch in s:
        cw = cwidth(ch)
        if w + cw > width:
            return out[:-1] + '…' if out and width > 1 else out
        out += ch
        w += cw
    return out


class Item:
    __slots__ = ('tag', 'cols', 'header', 'on')

    def __init__(self, tag, label, on=False):
        self.tag = tag
        self.header = tag.startswith('#')
        self.cols = label.split('\t')
        self.on = on


def build_items(req, kind):
    raw, items = req.get('items') or [], []
    step = 3 if kind in ('check', 'radio') else 2
    for i in range(0, len(raw) - step + 1, step):
        on = kind in ('check', 'radio') and str(raw[i + 2]).upper() == 'ON'
        items.append(Item(str(raw[i]), str(raw[i + 1]), on))
    return items


def column_widths(items, limit):
    widths = []
    for it in items:
        if it.header:
            continue
        for i, col in enumerate(it.cols):
            w = swidth(strip_markup(col))
            if i >= len(widths):
                widths.append(w)
            else:
                widths[i] = max(widths[i], w)
    # Shrink the widest columns until the row fits.
    while widths and sum(widths) + 2 * (len(widths) - 1) > limit:
        i = widths.index(max(widths))
        if widths[i] <= 6:
            break
        widths[i] -= 1
    return widths


# =================================================================== curses
class TUI:
    def __init__(self, scr, req_fd, resp_fd):
        import curses
        self.c = curses
        self.scr = scr
        self.req_fd, self.resp_fd = req_fd, resp_fd
        self.buf = b''
        self.last = {}                 # dialog title -> last chosen tag
        self.gauge = None
        self.busy_since = None
        self.ctx = ''
        self.clicks = []               # footer hot zones: (y, x0, x1, action)
        self.want_logo = False
        self.splash = None
        curses.curs_set(0)
        curses.raw()                   # Ctrl+C must not kill a half-done operation
        scr.keypad(True)
        try:
            # No REPORT_MOUSE_POSITION: with motion tracking ncurses may report a
            # press at a new position as plain movement and the click is lost.
            curses.mousemask(curses.ALL_MOUSE_EVENTS)
            curses.mouseinterval(0)
        except curses.error:
            pass
        self.init_colors()

    # ----------------------------------------------------------- colours
    def init_colors(self):
        c = self.c
        self.st = {}
        if not c.has_colors():
            for k in ('text', 'accent', 'green', 'red', 'yellow', 'cyan', 'blue', 'magenta',
                      'white', 'dim', 'border', 'title', 'sel', 'bar', 'barhi', 'key', 'field', 'track'):
                self.st[k] = c.A_NORMAL
            for i in range(len(LOGO)):
                self.st['logo%d' % i] = c.A_BOLD
            self.st['logosub'] = c.A_BOLD
            self.st.update(sel=c.A_REVERSE, bar=c.A_REVERSE, barhi=c.A_REVERSE | c.A_BOLD,
                           key=c.A_REVERSE, title=c.A_BOLD, bold=c.A_BOLD, field=c.A_UNDERLINE)
            return
        c.start_color()
        try:
            c.use_default_colors()
            bg = -1
        except c.error:
            bg = c.COLOR_BLACK
        rich = c.COLORS >= 256
        if rich:
            acc, grn, red, yel, cyn, blu, mag, dim, brd = 81, 114, 203, 221, 80, 75, 177, 245, 240
            white, selfg, selbg, barfg, barbg, keyfg, keybg, fieldbg, track = 255, 255, 25, 252, 236, 235, 81, 237, 238
        else:
            acc, grn, red, yel, cyn, blu, mag, dim, brd = 6, 2, 1, 3, 6, 4, 5, 7, 6
            white, selfg, selbg, barfg, barbg, keyfg, keybg, fieldbg, track = 7, 0, 6, 0, 6, 0, 7, 4, 7
        n = [0]

        def pair(fg, b=bg):
            n[0] += 1
            c.init_pair(n[0], fg, b)
            return c.color_pair(n[0])
        B = c.A_BOLD
        self.st = {
            'text': c.A_NORMAL, 'bold': B,
            'accent': pair(acc) | B, 'green': pair(grn), 'red': pair(red), 'yellow': pair(yel),
            'cyan': pair(cyn), 'blue': pair(blu), 'magenta': pair(mag), 'white': pair(white) | B,
            'dim': pair(dim) if rich else pair(dim) | c.A_DIM, 'border': pair(brd),
            'title': pair(acc) | B, 'sel': pair(selfg, selbg) | B,
            'bar': pair(barfg, barbg), 'barhi': pair(acc, barbg) | B, 'key': pair(keyfg, keybg) | B,
            'field': pair(white, fieldbg), 'track': pair(track),
        }
        for i, col in enumerate(LOGO_256 if rich else LOGO_8):
            self.st['logo%d' % i] = pair(col) | B
        self.st['logosub'] = pair(mag if rich else 5) | B

    def a(self, style):
        return self.st.get(style or 'text', self.st['text'])

    # ----------------------------------------------------------- drawing
    def put(self, y, x, text, attr=0, maxw=None):
        h, w = self.scr.getmaxyx()
        if y < 0 or y >= h or x >= w:
            return 0
        maxw = min(maxw if maxw is not None else w - x, w - x - (1 if y == h - 1 else 0))
        if maxw <= 0:
            return 0
        s = fit(text, maxw)
        try:
            self.scr.addstr(y, x, s, attr)
        except self.c.error:
            pass
        return swidth(s)

    def put_segs(self, y, x, segs, maxw, extra=0, base_attr=None):
        used = 0
        for text, st in segs:
            if used >= maxw:
                break
            attr = (self.a(st) if base_attr is None or st else base_attr) | extra
            used += self.put(y, x + used, text, attr, maxw - used)
        return used

    def fill(self, y, x, w, attr):
        self.put(y, x, ' ' * max(0, w), attr, w)

    def chrome(self, footer):
        """Top bar, background and key-hint footer."""
        h, w = self.scr.getmaxyx()
        self.scr.erase()
        self.fill(0, 0, w, self.a('bar'))
        x = self.put(0, 1, ' ◆ ', self.a('barhi'))
        self.put(0, 1 + x, APP, self.a('barhi'))
        right = self.ctx
        if self.busy_since and time.time() - self.busy_since > 0.25:
            right = SPIN[int(time.time() * 10) % len(SPIN)] + ' выполняется…' + ('   ' + right if right else '')
        if right:
            self.put(0, max(len(APP) + 6, w - swidth(right) - 2), right, self.a('bar'))
        self.clicks = []
        x = 1
        for key, label, action in footer:
            if x >= w - 4:
                break
            x0 = x
            x += self.put(h - 1, x, ' %s ' % key, self.a('key'))
            x += self.put(h - 1, x, ' %s' % label, self.a('dim'))
            if action:
                self.clicks.append((h - 1, x0, x, action))
            x += 3
        hint = 'мышь: клик, колесо'
        if x + swidth(hint) + 2 < w:
            self.put(h - 1, w - swidth(hint) - 2, hint, self.a('dim'))

    def draw_logo(self, y):
        W = self.scr.getmaxyx()[1]
        x = max(0, (W - swidth(LOGO[0])) // 2)
        for i, line in enumerate(LOGO):
            self.put(y + i, x, line, self.a('logo%d' % i))
        self.put(y + len(LOGO), max(0, (W - swidth(LOGO_SUB)) // 2), LOGO_SUB, self.a('logosub'))

    def logo_fits(self, inner_h):
        H = self.scr.getmaxyx()[0]
        return self.want_logo and H - 3 - (inner_h + 2) >= LOGO_H + 1

    def panel(self, title, inner_w, inner_h, top=None):
        """Rounded panel; returns (y, x, w, h) of the inner area."""
        H, W = self.scr.getmaxyx()
        w = min(inner_w + 4, W - 2)
        h = min(inner_h + 2, H - 3)
        if top is None and self.logo_fits(inner_h):
            # Logo and panel are centred together.
            block = LOGO_H + h
            ly = max(1, 1 + (H - 2 - block) // 2)
            self.draw_logo(ly)
            top = ly + LOGO_H
        y = top if top is not None else max(2, 1 + (H - 2 - h) // 2)
        x = max(1, (W - w) // 2)
        b = self.a('border')
        self.put(y, x, '╭' + '─' * (w - 2) + '╮', b)
        for i in range(1, h - 1):
            self.put(y + i, x, '│', b)
            self.put(y + i, x + w - 1, '│', b)
        self.put(y + h - 1, x, '╰' + '─' * (w - 2) + '╯', b)
        if title:
            t = ' %s ' % fit(title, w - 6)
            self.put(y, x + 2, t, self.a('title'))
        return y + 1, x + 2, w - 4, h - 2

    def too_small(self):
        H, W = self.scr.getmaxyx()
        if H >= 12 and W >= 50:
            return False
        self.scr.erase()
        self.put(0, 0, 'Окно слишком мало: нужно не меньше 50×12', self.a('yellow'))
        self.scr.refresh()
        return True

    # ----------------------------------------------------------- input
    def key(self, timeout=None):
        self.scr.timeout(-1 if timeout is None else int(timeout * 1000))
        try:
            k = self.scr.get_wch()
            self.errors = 0
        except self.c.error:
            if timeout is None:
                # A blocking read that keeps failing means the terminal is gone.
                self.errors = getattr(self, 'errors', 0) + 1
                if self.errors > 50:
                    raise SystemExit(1)
            return None
        if k == self.c.KEY_MOUSE:
            try:
                _, mx, my, _, bstate = self.c.getmouse()
            except self.c.error:
                self.lost_press = True    # the press was lost: let the release count
                return None
            return ('mouse', my, mx, bstate)
        if k == '\x1b':
            return self.escape()
        return k

    # Sequences ncurses did not translate (terminals that ignore keypad mode,
    # SGR mouse reports on older terminfo) are decoded here.
    ESC_KEYS = {'[A': 'KEY_UP', 'OA': 'KEY_UP', '[B': 'KEY_DOWN', 'OB': 'KEY_DOWN',
                '[C': 'KEY_RIGHT', 'OC': 'KEY_RIGHT', '[D': 'KEY_LEFT', 'OD': 'KEY_LEFT',
                '[H': 'KEY_HOME', 'OH': 'KEY_HOME', '[F': 'KEY_END', 'OF': 'KEY_END',
                '[1~': 'KEY_HOME', '[7~': 'KEY_HOME', '[4~': 'KEY_END', '[8~': 'KEY_END',
                '[5~': 'KEY_PPAGE', '[6~': 'KEY_NPAGE', '[3~': 'KEY_DC', '[Z': 'KEY_BTAB'}

    def escape(self):
        c = self.c
        seq = ''
        self.scr.timeout(40)
        try:
            while len(seq) < 24:
                try:
                    ch = self.scr.get_wch()
                except c.error:
                    break
                if not isinstance(ch, str):
                    break
                seq += ch
                if len(seq) >= 2 and (ch.isalpha() or ch == '~') and not (seq == '[<' or seq == 'O'):
                    if not seq.startswith('[<') or ch in 'Mm':
                        break
        finally:
            self.scr.timeout(-1)
        if not seq:
            return '\x1b'
        if seq in self.ESC_KEYS:
            return getattr(c, self.ESC_KEYS[seq])
        m = re.fullmatch(r'\[<(\d+);(\d+);(\d+)([Mm])', seq)
        if m:
            b, mx, my, kind = int(m.group(1)), int(m.group(2)) - 1, int(m.group(3)) - 1, m.group(4)
            if kind == 'm':
                return None                       # button release
            if b == 64:
                return ('mouse', my, mx, getattr(c, 'BUTTON4_PRESSED', 0))
            if b == 65:
                return ('mouse', my, mx, getattr(c, 'BUTTON5_PRESSED', 0x200000))
            if b & 3 == 2:
                return ('mouse', my, mx, c.BUTTON3_CLICKED)
            if b & 3 == 0 and b < 32:
                return ('mouse', my, mx, c.BUTTON1_CLICKED)
        return None

    def norm(self, k):
        """Map a raw key to an action name (or keep the character)."""
        c = self.c
        if isinstance(k, tuple):
            return k
        if k in ('\n', '\r', c.KEY_ENTER):
            return 'enter'
        if k in ('\x1b',):
            return 'esc'
        if k in (c.KEY_BACKSPACE, '\x7f', '\x08'):
            return 'back'
        if k == '\x03':
            return 'esc'
        if k == ' ':
            return 'space'
        return {c.KEY_UP: 'up', c.KEY_DOWN: 'down', c.KEY_LEFT: 'left', c.KEY_RIGHT: 'right',
                c.KEY_PPAGE: 'pgup', c.KEY_NPAGE: 'pgdn', c.KEY_HOME: 'home', c.KEY_END: 'end',
                c.KEY_DC: 'del', c.KEY_RESIZE: 'resize', '\t': 'down', c.KEY_BTAB: 'up'}.get(k, k)

    def mouse_kind(self, bstate):
        c = self.c
        if bstate & getattr(c, 'BUTTON4_PRESSED', 0):
            return 'wheelup'
        if bstate & getattr(c, 'BUTTON5_PRESSED', 0x200000):
            return 'wheeldown'
        if bstate & (c.BUTTON1_DOUBLE_CLICKED | c.BUTTON1_TRIPLE_CLICKED):
            return 'double'
        # Press and release arrive as separate events and only one of them may
        # count, or a checkbox would toggle twice. ncurses occasionally loses the
        # press (getmouse() fails): then the release stands in for it.
        if bstate & (c.BUTTON1_CLICKED | c.BUTTON1_PRESSED):
            self.lost_press = False
            return 'click'
        if bstate & c.BUTTON1_RELEASED:
            lost, self.lost_press = getattr(self, 'lost_press', False), False
            return 'click' if lost else None
        if bstate & (c.BUTTON3_CLICKED | c.BUTTON3_PRESSED):
            return 'right'
        return None

    def footer_hit(self, y, x):
        for fy, x0, x1, action in self.clicks:
            if y == fy and x0 <= x < x1:
                return action
        return None

    # ----------------------------------------------------------- dialogs
    def d_menu(self, req, kind):
        c = self.c
        title = req.get('title', '')
        items = build_items(req, kind)
        selectable = [i for i, it in enumerate(items) if not it.header]
        if not selectable:
            return 1, ''
        want = req.get('default') or self.last.get(title, '')
        if kind == 'radio':
            want = next((it.tag for it in items if it.on), want)
        sel = next((i for i in selectable if items[i].tag == want), selectable[0])
        if kind == 'yesno':
            sel = selectable[1] if req.get('defaultno') else selectable[0]
        top = 0
        cancel = req.get('cancel') or 'назад'
        footers = {
            'menu': [('↑↓', 'выбор', None), ('Enter', 'подтвердить', 'enter'), ('Backspace', cancel.lower(), 'back')],
            'radio': [('↑↓', 'выбор', None), ('Enter', 'подтвердить', 'enter'), ('Backspace', 'назад', 'back')],
            'check': [('Пробел', 'отметить', 'space'), ('Enter', 'подтвердить', 'enter'), ('Backspace', 'назад', 'back')],
            'yesno': [('↑↓', 'выбор', None), ('Enter', 'подтвердить', 'enter'), ('Backspace', 'отмена', 'back')],
        }
        self.c.flushinp()
        while True:
            if self.too_small():
                k = self.norm(self.key())
                continue
            H, W = self.scr.getmaxyx()
            maxw = min(W - 6, 100)
            mark_w = {'menu': 2, 'yesno': 2, 'radio': 4, 'check': 4}[kind]
            widths = column_widths(items, maxw - mark_w - 2)
            row_w = mark_w + sum(widths) + 2 * max(0, len(widths) - 1) + 2
            tl_probe = text_lines(req.get('text', ''), maxw)
            text_w = max([sum(swidth(s) for s, _ in ln) for ln in tl_probe] + [0])
            inner_w = max(min(maxw, max(row_w, text_w, swidth(title) + 4)), 44)
            tl = text_lines(req.get('text', ''), inner_w) if req.get('text') else []
            avail = H - 4 - 2
            list_h = min(len(items), max(3, avail - len(tl) - (1 if tl else 0)))
            if len(tl) + (1 if tl else 0) + list_h > avail:
                tl = tl[:max(0, avail - list_h - 1)]
            inner_h = len(tl) + (1 if tl else 0) + list_h
            self.chrome(footers[kind])
            y, x, w, h = self.panel(title, inner_w, inner_h)
            for i, ln in enumerate(tl):
                self.put_segs(y + i, x, ln, w)
            ly = y + len(tl) + (1 if tl else 0)
            if sel < top:
                top = sel
            if sel >= top + list_h:
                top = sel - list_h + 1
            top = max(0, min(top, len(items) - list_h))
            rows = {}
            for r in range(list_h):
                i = top + r
                if i >= len(items):
                    break
                it = items[i]
                rows[ly + r] = i
                if it.header:
                    label = strip_markup(it.tag[1:] or it.cols[0])
                    self.put(ly + r, x, label.upper(), self.a('dim') | c.A_BOLD, w)
                    continue
                active = i == sel
                base = self.a('sel') if active else None
                if active:
                    self.fill(ly + r, x - 1, w + 2, self.a('sel'))
                if kind in ('menu', 'yesno'):
                    mark = '❯ ' if active else '  '
                elif kind == 'radio':
                    mark = ' ◉  ' if it.on else ' ○  '
                else:
                    mark = ' ■  ' if it.on else ' □  '
                mattr = self.a('sel') if active else (self.a('accent') if it.on or kind in ('menu', 'yesno') else self.a('dim'))
                cx = x + self.put(ly + r, x, mark, mattr)
                for ci, col in enumerate(it.cols):
                    cw_ = widths[ci] if ci < len(widths) else swidth(col)
                    segs = parse_line(col)
                    if active:
                        segs = [(s, None) for s, _ in segs]
                    elif ci > 0 and len(it.cols) > 1 and not TAG_RE.search(col) and segs[0][1] is None:
                        segs = [(s, 'dim') for s, _ in segs]
                    self.put_segs(ly + r, cx, segs, min(cw_, x + w - cx), base_attr=base)
                    cx += cw_ + 2
            if top > 0:
                self.put(ly - 1 if tl else y - 1, x + w - 2, '▲', self.a('accent'))
            if top + list_h < len(items):
                self.put(ly + list_h, x + w - 2, '▼', self.a('accent'))
            self.scr.refresh()

            raw = self.key()
            if os.environ.get('XR_TUI_DEBUG'):
                sys.stderr.write('%.2f key %r\n' % (time.time(), raw))
                sys.stderr.flush()
            k = self.norm(raw)
            act = k
            if isinstance(k, tuple):
                _, my, mx, bstate = k
                kind_m = self.mouse_kind(bstate)
                hit = self.footer_hit(my, mx)
                if hit:
                    act = hit
                elif kind_m == 'wheelup':
                    act = 'up'
                elif kind_m == 'wheeldown':
                    act = 'down'
                elif kind_m == 'right':
                    act = 'back'
                elif kind_m in ('click', 'double') and my in rows and not items[rows[my]].header:
                    sel = rows[my]
                    act = 'space' if kind == 'check' else 'enter'   # a click chooses
                else:
                    act = None
            if act in ('up', 'down', 'pgup', 'pgdn', 'home', 'end'):
                pos = selectable.index(sel)
                step = {'up': -1, 'down': 1, 'pgup': -list_h, 'pgdn': list_h}.get(act, 0)
                if act == 'home':
                    pos = 0
                elif act == 'end':
                    pos = len(selectable) - 1
                else:
                    pos = max(0, min(len(selectable) - 1, pos + step))
                sel = selectable[pos]
            elif act == 'space':
                if kind == 'check':
                    items[sel].on = not items[sel].on
                elif kind == 'radio':
                    for it in items:
                        it.on = False
                    items[sel].on = True
            elif act in ('enter',) or (act == 'right' and kind == 'menu'):
                if kind == 'check':
                    return 0, '\n'.join(it.tag for it in items if it.on and not it.header)
                if kind == 'radio':
                    return 0, items[sel].tag
                if kind == 'yesno':
                    return (0 if sel == selectable[0] else 1), ''
                self.last[title] = items[sel].tag
                return 0, items[sel].tag
            elif act in ('back', 'esc', 'left'):
                return 1, ''
            elif isinstance(act, str) and len(act) == 1 and act.isprintable() and kind in ('menu', 'radio'):
                # Type-to-jump: next item whose label starts with the letter.
                pos = selectable.index(sel)
                order = selectable[pos + 1:] + selectable[:pos + 1]
                for i in order:
                    if strip_markup(items[i].cols[0]).strip().lower().startswith(act.lower()):
                        sel = i
                        break

    def d_input(self, req):
        c = self.c
        value = list(req.get('default') or '')
        cur = len(value)
        scroll = 0
        footer = [('Enter', 'подтвердить', 'enter'), ('Esc', 'назад', 'esc'), ('Backspace', 'стереть', None)]
        c.flushinp()
        while True:
            if self.too_small():
                self.key()
                continue
            H, W = self.scr.getmaxyx()
            inner_w = max(44, min(W - 6, 90))
            tl = text_lines(req.get('text', ''), inner_w)[:max(1, H - 9)]
            self.chrome(footer)
            y, x, w, h = self.panel(req.get('title', ''), inner_w, len(tl) + 2)
            for i, ln in enumerate(tl):
                self.put_segs(y + i, x, ln, w)
            fy = y + len(tl) + 1
            self.fill(fy, x, w, self.a('field'))
            text = ''.join(value)
            pre = swidth(''.join(value[:cur]))
            if pre - scroll > w - 2:
                scroll = pre - (w - 2)
            if pre < scroll:
                scroll = pre
            vis, acc = '', 0
            for ch in text:
                if acc >= scroll:
                    vis += ch
                acc += cwidth(ch)
            self.put(fy, x + 1, vis, self.a('field'), w - 2)
            try:
                c.curs_set(1)
                self.scr.move(fy, x + 1 + pre - scroll)
            except c.error:
                pass
            self.scr.refresh()
            k = self.key()
            act = self.norm(k)
            if isinstance(act, tuple):
                hit = self.footer_hit(act[1], act[2])
                act = hit or ('esc' if self.mouse_kind(act[3]) == 'right' else None)
            if act == 'enter':
                c.curs_set(0)
                return 0, ''.join(value)
            if act == 'esc':
                c.curs_set(0)
                return 1, ''
            if act == 'back':
                if not value:
                    c.curs_set(0)
                    return 1, ''
                if cur > 0:
                    del value[cur - 1]
                    cur -= 1
            elif act == 'del':
                if cur < len(value):
                    del value[cur]
            elif act == 'left':
                cur = max(0, cur - 1)
            elif act == 'right':
                cur = min(len(value), cur + 1)
            elif act == 'home':
                cur = 0
            elif act == 'end':
                cur = len(value)
            elif k == '\x15':                       # Ctrl+U clears the field
                value, cur = [], 0
            elif act == 'space':
                value.insert(cur, ' ')
                cur += 1
            elif isinstance(k, str) and k.isprintable():
                value.insert(cur, k)
                cur += 1

    def copy_out(self, value):
        """Put text on the system clipboard with OSC 52 (terminal permitting)."""
        b64 = __import__('base64').b64encode(value.encode('utf-8')).decode()
        seq = '\x1b]52;c;%s\x07' % b64
        if os.environ.get('TMUX'):
            seq = '\x1bPtmux;\x1b%s\x1b\\' % seq
        try:
            sys.stdout.flush()
            os.write(sys.stdout.fileno(), seq.encode())
        except OSError:
            pass

    @staticmethod
    def copy_spots(tl, items):
        """Positions of copyable values: [(line, col0, col1, item index)]."""
        spots, found = [], set()
        for i, segs in enumerate(tl):
            line = ''.join(t for t, _ in segs)
            for n, (_, value) in enumerate(items):
                if not value or n in found:
                    continue
                at = line.find(value)
                if at >= 0:                       # first occurrence only
                    found.add(n)
                    col = swidth(line[:at])
                    spots.append((i, col, col + swidth(value), n))
        return spots

    @staticmethod
    def watch_state(path, expires):
        """Pairing file: 'used' once the web server read it, 'gone' if removed/expired."""
        if expires and time.time() > expires:
            return 'gone'
        try:
            st = os.stat(path)
        except OSError:
            return 'gone'
        return 'used' if st.st_atime_ns > st.st_mtime_ns else ''

    def d_text(self, req):
        title = req.get('title', '')
        text = req.get('text', '')
        if req.get('file'):
            try:
                with open(req['file'], encoding='utf-8', errors='replace') as f:
                    text = f.read().rstrip('\n')
            except OSError as e:
                text = '{red}Не удалось открыть файл: %s{/}' % e
        items = [tuple(x) for x in req.get('copy') or [] if len(x) == 2]
        watch, expires = req.get('watch'), float(req.get('expires') or 0)
        top, sel, status = 0, None, None
        self.c.flushinp()
        while True:
            if self.too_small():
                self.key(1 if watch else None)
                continue
            H, W = self.scr.getmaxyx()
            maxw = min(W - 6, 104)
            probe = text_lines(text, maxw)
            need = max([sum(swidth(s) for s, _ in ln) for ln in probe] + [0])
            inner_w = max(44, min(maxw, need, maxw))
            tl = text_lines(text, inner_w)
            spots = self.copy_spots(tl, items)
            view = min(len(tl), H - 6)
            scrollable = len(tl) > view
            footer = [('↑↓', 'прокрутка', None)] if scrollable else []
            if spots:
                footer.append(('Tab', 'значение', None))
                if sel is not None:
                    footer.append(('Enter', 'копировать', 'enter'))
                footer.append(('Backspace', req.get('ok') or 'закрыть', 'back'))
            else:
                footer.append(('Enter', req.get('ok') or 'закрыть', 'enter'))
            self.chrome(footer)
            y, x, w, h = self.panel(title, inner_w, view)
            top = max(0, min(top, len(tl) - view))
            for i in range(view):
                self.put_segs(y + i, x, tl[top + i], w)
            if sel is not None:
                for ln, c0, c1, n in spots:
                    if n == sel and top <= ln < top + view:
                        self.put(y + ln - top, x + c0, items[n][1], self.a('sel'), max(0, w - c0))
            if scrollable:
                pct = int(100 * (top + view) / len(tl))
                self.put(y + h, x + w - 6, ' %3d%% ' % pct, self.a('accent'))
            if watch and expires:
                left = max(0, int(expires - time.time()))
                self.put(y + h, x + w - 9, ' %02d:%02d ' % (left // 60, left % 60), self.a('accent'))
            if status:
                self.put(y + h, x + 1, ' %s ' % status, self.a('green'), max(0, w - 12))
            self.scr.refresh()
            raw = self.key(1 if watch else None)
            if watch:
                state = self.watch_state(watch, expires)
                if state == 'used':
                    return 3, ''
                if state == 'gone':
                    return 4, ''
            if raw is None:
                continue
            if spots and raw in ('\t', self.c.KEY_BTAB):
                order = sorted({n for *_, n in spots})
                if sel not in order:
                    sel = order[0 if raw == '\t' else -1]
                else:
                    sel = order[(order.index(sel) + (1 if raw == '\t' else -1)) % len(order)]
                ln = next(l for l, _, _, n in spots if n == sel)
                if not top <= ln < top + view:
                    top = max(0, ln - view // 2)
                status = None
                continue
            act = self.norm(raw)
            if isinstance(act, tuple):
                kind_m = self.mouse_kind(act[3])
                hit = None
                if kind_m in ('click', 'double'):
                    for ln, c0, c1, n in spots:
                        if act[1] == y + ln - top and top <= ln < top + view and x + c0 <= act[2] < x + c1:
                            hit = n
                if hit is not None:
                    sel = hit
                    act = 'copy'
                else:
                    act = self.footer_hit(act[1], act[2]) or \
                        {'wheelup': 'up', 'wheeldown': 'down', 'right': 'back'}.get(kind_m)
            if act == 'enter' and spots and sel is not None:
                act = 'copy'
            if act == 'copy':
                self.copy_out(items[sel][1])
                status = '✓ Скопировано: %s' % items[sel][0]
                continue
            if act in ('enter', 'esc', 'back', 'left', 'q'):
                return 0, ''
            step = {'up': -1, 'down': 1, 'pgup': -view, 'pgdn': view, 'space': view}.get(act)
            if step:
                top += step
            elif act == 'home':
                top = 0
            elif act == 'end':
                top = len(tl)

    def draw_splash(self):
        sp = self.splash
        H, W = self.scr.getmaxyx()
        self.scr.erase()
        top = max(0, (H - LOGO_H - 3) // 2)
        self.draw_logo(top)
        line = sp.get('text') or ''
        self.put(top + LOGO_H, max(0, (W - swidth(line)) // 2), line, self.a('dim'))
        frame = SPIN[int(time.time() * 10) % len(SPIN)] + ' ' + (sp.get('status') or 'загрузка…')
        self.put(top + LOGO_H + 2, max(0, (W - swidth(frame)) // 2), frame, self.a('accent'))
        self.scr.refresh()

    def draw_gauge(self):
        g = self.gauge
        phases, states = g.get('phases') or [], g.get('states') or []
        pct = max(0, min(100, int(g.get('pct') or 0)))
        H, W = self.scr.getmaxyx()
        inner_w = max(48, min(W - 6, 76))
        self.chrome([('', 'операция выполняется — дождись завершения', None)])
        y, x, w, h = self.panel(g.get('title', ''), inner_w, len(phases) + 3)
        frame = SPIN[int(time.time() * 10) % len(SPIN)]
        for i, ph in enumerate(phases):
            st = states[i] if i < len(states) else 'pending'
            icon, ia, ta = {'done': ('✓', 'green', 'text'), 'current': (frame, 'accent', 'white'),
                            'failed': ('✗', 'red', 'red')}.get(st, ('·', 'dim', 'dim'))
            self.put(y + i, x, icon, self.a(ia))
            self.put(y + i, x + 2, ph, self.a(ta), w - 2)
        by = y + len(phases) + 1
        bw = w - 12
        filled = int(bw * pct / 100)
        self.put(by, x, '━' * filled, self.a('accent'))
        self.put(by, x + filled, '─' * (bw - filled), self.a('track'))
        self.put(by, x + bw + 1, '%3d%%' % pct, self.a('white'))
        el = int(time.time() - g['_start'])
        self.put(by, x + bw + 6, '%d:%02d' % (el // 60, el % 60), self.a('dim'))
        self.scr.refresh()

    # ----------------------------------------------------------- server loop
    def read_request(self, timeout):
        while b'\n' not in self.buf:
            r, _, _ = select.select([self.req_fd], [], [], timeout)
            if not r:
                return ''
            chunk = os.read(self.req_fd, 65536)
            if not chunk:
                return None
            self.buf += chunk
        line, self.buf = self.buf.split(b'\n', 1)
        return line.decode('utf-8', 'replace')

    def respond(self, rc, value=''):
        data = '%d %d\n%s' % (rc, len(value), value)
        os.write(self.resp_fd, data.encode('utf-8'))
        self.busy_since = time.time()

    def idle(self):
        """Between requests: animate the gauge or the 'busy' spinner, eat keys."""
        if getattr(self, 'suspended', False):
            return                      # another program owns the terminal
        if self.splash:
            self.draw_splash()
        elif self.gauge:
            self.draw_gauge()
        elif self.busy_since and time.time() - self.busy_since > 0.25:
            H, W = self.scr.getmaxyx()
            right = SPIN[int(time.time() * 10) % len(SPIN)] + ' выполняется…' + ('   ' + self.ctx if self.ctx else '')
            self.fill(0, len(APP) + 6, W - len(APP) - 6, self.a('bar'))
            self.put(0, max(len(APP) + 6, W - swidth(right) - 2), right, self.a('bar'))
            self.scr.refresh()
        self.scr.timeout(0)
        try:
            while True:
                k = self.scr.get_wch()
                if k == self.c.KEY_RESIZE and self.gauge:
                    self.draw_gauge()
        except self.c.error:
            pass

    def handle(self, req):
        cmd = req.get('cmd')
        if 'ctx' in req:
            self.ctx = req.get('ctx') or ''
        self.want_logo = bool(req.get('logo'))
        if cmd != 'splash':
            self.splash = None
        new_gauge = cmd == 'gauge' and (not self.gauge or self.gauge.get('title') != req.get('title'))
        if cmd != 'gauge':
            self.gauge = None
        if cmd not in ('gauge', 'ping', 'quit', 'suspend', 'resume') or new_gauge:
            # A new window: repaint everything, so nothing from the previous
            # screen (or stray output from other programs) can survive.
            self.scr.clear()
        self.busy_since = None
        if cmd in ('menu', 'radio', 'check', 'yesno'):
            if cmd == 'yesno':
                req = dict(req, items=['y', req.get('yes') or 'Да', 'n', req.get('no') or 'Нет'])
            return self.d_menu(req, cmd)
        if cmd == 'input':
            return self.d_input(req)
        if cmd in ('msg', 'text'):
            return self.d_text(req)
        if cmd == 'gauge':
            if not self.gauge or self.gauge.get('title') != req.get('title'):
                req['_start'] = time.time()
            else:
                req['_start'] = self.gauge['_start']
            self.gauge = req
            self.draw_gauge()
            return 0, ''
        if cmd == 'splash':
            self.splash = req
            self.draw_splash()
            return 0, ''
        if cmd == 'suspend':
            self.c.endwin()
            self.suspended = True
            return 0, ''
        if cmd == 'resume':
            self.suspended = False
            self.scr.clear()
            self.scr.refresh()
            return 0, ''
        if cmd in ('ping', 'quit'):
            return 0, ''
        return 2, 'unknown command'

    def loop(self):
        while True:
            busy = (self.gauge or self.busy_since or self.splash) and not getattr(self, 'suspended', False)
            line = self.read_request(0.1 if busy else None)
            if line is None:
                return
            if line == '':
                self.idle()
                continue
            try:
                req = json.loads(line, strict=False)
            except ValueError:
                self.respond(2, 'bad request')
                continue
            try:
                rc, value = self.handle(req)
            except Exception as e:                      # never leave bash waiting
                import traceback
                traceback.print_exc()
                rc, value = 2, 'ui error: %s' % e
            self.respond(rc, value)
            if req.get('cmd') == 'quit':
                return


def serve(path):
    req_fd = os.open(os.path.join(path, 'req'), os.O_RDONLY)
    resp_fd = os.open(os.path.join(path, 'resp'), os.O_WRONLY)
    os.write(resp_fd, b'READY\n')
    import curses
    curses.wrapper(lambda scr: TUI(scr, req_fd, resp_fd).loop())


# =================================================================== CLI
ANSI = {'green': '32', 'red': '31', 'yellow': '33', 'accent': '36;1', 'cyan': '36', 'blue': '34',
        'magenta': '35', 'dim': '90', 'bold': '1', 'white': '97;1'}


def to_ansi(text, color=True):
    out = []
    for raw in text.split('\n'):
        line = ''
        for s, st in parse_line(raw):
            line += ('\x1b[%sm%s\x1b[0m' % (ANSI[st], s)) if color and st in ANSI else s
        out.append(line)
    return '\n'.join(out)


def print_logo(stream, color=True):
    for i, line in enumerate(LOGO):
        stream.write(('\x1b[1;%sm%s\x1b[0m' % (LOGO_ANSI[i], line) if color else line) + '\n')
    stream.write(('\x1b[1;38;5;177m%s\x1b[0m' % LOGO_SUB if color else LOGO_SUB) + '\n')
    stream.flush()


def cli(req):
    tin = open('/dev/tty', 'r', encoding='utf-8', errors='replace')
    tty = open('/dev/tty', 'w', encoding='utf-8', errors='replace')
    color = not os.environ.get('NO_COLOR')

    def say(text=''):
        tty.write(to_ansi(text, color) + '\n')
        tty.flush()

    def ask(prompt):
        tty.write(to_ansi(prompt, color))
        tty.flush()
        line = tin.readline()
        if not line:
            raise EOFError
        return line.rstrip('\n')

    cmd = req.get('cmd')
    title, text = req.get('title', ''), req.get('text', '')
    if cmd == 'splash':
        print_logo(tty, color)
        if req.get('text'):
            say('{dim}%s{/}' % req['text'])
        return 0, ''
    if req.get('logo'):
        print_logo(tty, color)
    if title:
        say('\n{accent}◆ %s{/}' % title)
    if text and cmd not in ('text',):
        say(text)
    try:
        if cmd in ('menu', 'radio', 'check', 'yesno'):
            kind = cmd
            if cmd == 'yesno':
                default_yes = not req.get('defaultno')
                ans = ask('%s / %s [%s]: ' % (req.get('yes') or 'Да', req.get('no') or 'Нет',
                                              'Y/n' if default_yes else 'y/N')).strip().lower()
                if not ans:
                    return (0 if default_yes else 1), ''
                return (0 if ans[:1] in ('y', 'д', 'l') else 1), ''
            items = build_items(req, kind)
            pick = [it for it in items if not it.header]
            widths = column_widths(items, 100)
            n = 0
            for it in items:
                if it.header:
                    say('{dim}  %s{/}' % strip_markup(it.tag[1:] or it.cols[0]).upper())
                    continue
                n += 1
                cols = []
                for i, col in enumerate(it.cols):
                    pad = (widths[i] if i < len(widths) else 0) - swidth(strip_markup(col))
                    cols.append(col + ' ' * max(0, pad))
                mark = ''
                if kind == 'check':
                    mark = '[x] ' if it.on else '[ ] '
                elif kind == 'radio':
                    mark = '(•) ' if it.on else '( ) '
                say('  {accent}%2d){/} %s%s' % (n, mark, '  '.join(cols).rstrip()))
            if kind == 'check':
                while True:
                    ans = ask('Номера для отметки через пробел, Enter — готово, 0 — назад: ').strip()
                    if ans == '0':
                        return 1, ''
                    if not ans:
                        return 0, '\n'.join(it.tag for it in pick if it.on)
                    for part in ans.replace(',', ' ').split():
                        if part.isdigit() and 1 <= int(part) <= len(pick):
                            pick[int(part) - 1].on = not pick[int(part) - 1].on
                    say('Отмечено: ' + (', '.join(strip_markup(it.cols[0]) for it in pick if it.on) or '—'))
            say('  {dim} 0) %s{/}' % (req.get('cancel') or 'Назад'))
            while True:
                ans = ask('Выбор: ').strip()
                if ans in ('', '0'):
                    if ans == '' and kind == 'radio':
                        on = [it for it in pick if it.on]
                        if on:
                            return 0, on[0].tag
                    return 1, ''
                if ans.isdigit() and 1 <= int(ans) <= len(pick):
                    return 0, pick[int(ans) - 1].tag
                say('{yellow}Введи номер из списка.{/}')
        if cmd == 'input':
            default = req.get('default') or ''
            ans = ask('> ' + ('[%s] ' % default if default else ''))
            return 0, (ans if ans else default)
        if cmd in ('msg', 'text'):
            body = text
            if req.get('file'):
                with open(req['file'], encoding='utf-8', errors='replace') as f:
                    body = f.read().rstrip('\n')
            if cmd == 'text':
                say(body)
            if req.get('watch'):
                tty.write(to_ansi('{dim}Enter — отозвать токен и вернуться{/}', color))
                tty.flush()
                expires = float(req.get('expires') or 0)
                while True:
                    state = TUI.watch_state(req['watch'], expires)
                    if state:
                        tty.write('\n')
                        return (3 if state == 'used' else 4), ''
                    r, _, _ = select.select([tin], [], [], 1)
                    if r:
                        tin.readline()
                        return 0, ''
            ask('{dim}Enter — продолжить{/}')
            return 0, ''
    except (EOFError, KeyboardInterrupt):
        tty.write('\n')
        return 1, ''
    return 2, ''


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == 'serve':
        serve(sys.argv[2])
        return 0
    if len(sys.argv) >= 2 and sys.argv[1] == 'cli':
        req = json.loads(sys.stdin.read(), strict=False)
        rc, value = cli(req)
        sys.stdout.write(value)
        return rc
    if len(sys.argv) >= 2 and sys.argv[1] == 'logo':
        print_logo(sys.stdout, sys.stdout.isatty() and not os.environ.get('NO_COLOR'))
        return 0
    if len(sys.argv) >= 2 and sys.argv[1] == 'ansi':      # markup -> ANSI for plain output
        color = sys.stdout.isatty() and not os.environ.get('NO_COLOR')
        sys.stdout.write(to_ansi(sys.stdin.read(), color))
        return 0
    sys.stderr.write('usage: serve DIR | cli | ansi\n')
    return 2


if __name__ == '__main__':
    sys.exit(main())
XRTUI
  chmod 700 "$1"
}

# ---------------------------------------------------------------- version & updates
update_repo(){ printf '%s' "${XR_REPO:-${UPDATE_REPO:-$DEFAULT_REPO}}"; }
# Installs this script as the "3x-ui_reverse" command. Started as
# bash <(curl …) the script is a pipe that bash has already consumed, so copying
# "$0" would give an empty file: then the same version is fetched by its tag.
install_self(){
  local src=$0 tmp ref repo
  if [[ -f "$src" && -s "$src" ]] && grep -qx "VERSION=$VERSION" "$src" 2>/dev/null; then
    install -m 755 -- "$src" "$SELF"
    return 0
  fi
  repo=$(update_repo)
  [[ -n "$repo" ]] || return 1
  tmp=$(mktemp)
  for ref in "$VERSION" main; do
    if curl -fsSL --retry 2 --max-time 60 -o "$tmp" \
         "https://raw.githubusercontent.com/$repo/$ref/$UPDATE_ASSET" 2>>"$LOG" \
       && bash -n "$tmp" 2>>"$LOG" && grep -qx "VERSION=$VERSION" "$tmp"; then
      install -m 755 -- "$tmp" "$SELF"
      rm -f -- "$tmp"
      return 0
    fi
  done
  rm -f -- "$tmp"
  return 1
}
UPDATE_CACHE=$BASE/update-check
# Cached result: "EPOCH TAG SHA newer|same|older" (refreshed at most daily).
update_cached(){
  local epoch tag sha rel
  [[ -r "$UPDATE_CACHE" ]] || return 1
  read -r epoch tag sha rel < "$UPDATE_CACHE" || return 1
  [[ "$epoch" =~ ^[0-9]+$ && -n "$tag" ]] || return 1
  printf '%s %s %s %s' "$epoch" "$tag" "$sha" "$rel"
}
update_check_now(){
  local repo out
  repo=$(update_repo)
  [[ -n "$repo" ]] || return 1
  out=$(helper update-check "$repo" "$VERSION" 2>&1) || { printf '%s' "${out#Ошибка: }"; return 1; }
  [[ -d "$BASE" ]] && printf '%s %s\n' "$(date +%s)" "$out" > "$UPDATE_CACHE"
  printf '%s' "$out"
}
# Daily background refresh so the main menu can show "доступна vX.Y.Z".
update_check_background(){
  local cached epoch
  [[ -n "$(update_repo)" && -d "$BASE" && -f "$HELPER" ]] || return 0
  cached=$(update_cached) || cached='0'
  epoch=${cached%% *}
  (( $(date +%s) - epoch > 86400 )) || return 0
  if [[ $UI_MODE == tui ]]; then
    ( update_check_now >/dev/null 2>&1 || : ) {TUI_REQ}>&- {TUI_RESP}>&- {UI_OUT_FD}>&- {UI_ERR_FD}>&- </dev/null &
  else
    ( update_check_now >/dev/null 2>&1 || : ) </dev/null &
  fi
  return 0
}
version_label(){
  local cached tag rel
  if cached=$(update_cached); then
    read -r _ tag _ rel <<< "$cached"
    if [[ "$rel" == newer ]]; then
      printf 'Версия %s\t{green}● доступна %s{/}' "$VERSION" "$tag"; return 0
    fi
  fi
  printf 'Версия %s\t{dim}обновления{/}' "$VERSION"
}
do_update(){
  local tag=$1 repo tmp backup
  repo=$(update_repo)
  tui_yesno 'Обновление' "Обновить 3x-ui_reverse $VERSION → {green}$tag{/}?

Будет скачан скрипт из github.com/$repo (тег $tag) и установлен как $SELF.
Текущая версия сохранится в $BASE/backups/." 'Обновить' 'Отмена' yes || return 0
  tmp=$(mktemp "${UI_DIR:-/tmp}/update.XXXXXXXX")
  ui_start 'Обновление' 'Скачиваем новую версию' 'Проверяем файл' 'Устанавливаем'
  msg 'Скачиваем новую версию'
  step 20
  if ! helper update-fetch "$repo" "$tag" "$UPDATE_ASSET" "$tmp" >>"$LOG" 2>&1; then
    ui_stop failed; rm -f -- "$tmp"; warn "Не удалось скачать $UPDATE_ASSET для тега $tag (см. журнал)."; return 1
  fi
  msg 'Проверяем файл'
  step 60
  if ! bash -n "$tmp" 2>>"$LOG" || ! grep -qx "VERSION=$tag" "$tmp"; then
    ui_stop failed; rm -f -- "$tmp"
    warn "Файл тега $tag не прошёл проверку: синтаксис или VERSION=$tag в нём не совпадают."; return 1
  fi
  msg 'Устанавливаем'
  step 85
  install -d -m 700 "$BASE/backups"
  backup="$BASE/backups/3x-ui_reverse-$VERSION.sh"
  if [[ -f "$SELF" ]]; then cp -a -- "$SELF" "$backup"; else cp -a -- "$0" "$backup" 2>/dev/null || :; fi
  install -m 755 -- "$tmp" "$SELF"
  rm -f -- "$tmp" "$UPDATE_CACHE"
  ui_stop
  tui_msg 'Обновлено' "{green}✓ Установлена версия $tag.{/}
Предыдущая версия: $backup

Интерфейс перезапустится в новой версии."
  local mode_flag=--tui
  [[ $UI_MODE == cli ]] && mode_flag=--cli
  ui_shutdown
  exec "$SELF" "$mode_flag"
}
menu_version(){
  local repo cached tag sha rel status ch out shown
  while :; do
    repo=$(update_repo)
    shown=$repo
    [[ -n "$shown" ]] || shown='{yellow}не задан{/}'
    status='{dim}не проверялось{/}'
    tag=''; rel=''
    if cached=$(update_cached); then
      read -r _ tag sha rel <<< "$cached"
      case "$rel" in
        newer) status="{green}● доступна $tag{/} {dim}(коммит $sha){/}" ;;
        same)  status="{green}✓ установлена последняя версия{/} {dim}($tag, коммит $sha){/}" ;;
        *)     status="{dim}в репозитории $tag (коммит $sha) — не новее установленной{/}" ;;
      esac
    fi
    local -a items=(check 'Проверить обновления')
    [[ "$rel" == newer ]] && items+=(update "{green}Обновить до $tag{/}")
    items+=(repo 'Источник обновлений (GitHub)')
    ch=$(tui_menu 'Версия' "{dim}Установлена{/}   {bold}$VERSION{/}
{dim}Репозиторий{/}   $shown
{dim}Обновления{/}    $status" "${items[@]}") || return 0
    case "$ch" in
      check)
        if [[ -z "$repo" ]]; then tui_msg 'Обновления' 'Сначала укажи репозиторий (GitHub owner/name), где публикуются теги версий.'; continue; fi
        ui_start 'Проверка обновлений' "Запрашиваем теги github.com/$repo"
        msg "Запрашиваем теги github.com/$repo"
        step 40
        if out=$(update_check_now); then
          ui_stop
          read -r tag sha rel <<< "$out"
          case "$rel" in
            newer) tui_msg 'Обновления' "{green}● Доступна версия $tag{/} (коммит $sha). Выбери «Обновить до $tag»." ;;
            same)  tui_msg 'Обновления' "{green}✓ У тебя последняя версия{/} ($tag, коммит $sha)." ;;
            *)     tui_msg 'Обновления' "Последний тег в репозитории — $tag, он не новее $VERSION." ;;
          esac
        else
          ui_stop failed
          tui_msg 'Обновления' "{red}Проверка не удалась:{/} $out"
        fi ;;
      update) do_update "$tag" || : ;;
      repo)
        if out=$(tui_input 'Источник обновлений' 'Репозиторий GitHub в виде owner/name, где публикуются теги версий (v8.0.1 …).
Пусто — отключить проверку обновлений.' "$repo"); then
          if [[ -n "$out" && ! "$out" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
            tui_msg 'Ошибка' 'Формат: owner/name, например ivan/3x-ui_reverse.'
          else
            UPDATE_REPO=$out; save_state; rm -f -- "$UPDATE_CACHE"
            note "✓ Источник обновлений: ${out:-отключён}."
          fi
        fi ;;
    esac
    flush_notes 'Версия'
  done
}

manager(){
  [[ $EUID -eq 0 ]] || die 'Запусти через sudo.'
  ui_init || die 'Нужен интерактивный терминал. Для скриптов используй команды: 3x-ui_reverse --help'
  ui_splash "$VERSION · управление 3x-ui за Caddy/Nginx" 'подключаемся к панели…'
  load_state
  touch "$LOG"; chmod 600 "$LOG"
  # Running a newer copy of this file upgrades the installed command,
  # unless the command was removed on purpose.
  # Started from a file or as bash <(curl …): install that version as the command.
  local installed_ver=''
  [[ -f "$SELF" ]] && installed_ver=$(sed -n 's/^VERSION=//p' "$SELF" 2>/dev/null | head -n1)
  if [[ "$0" != "$SELF" && ! -L "$SELF" && -f "$SELF" ]] &&
     { [[ "$installed_ver" != "$VERSION" ]] || { [[ -f "$0" ]] && ! cmp -s "$0" "$SELF"; }; }; then
    if install_self; then
      note "✓ Команда $SELF обновлена до версии $VERSION."
    else
      warn "Не удалось обновить команду $SELF до $VERSION (нет доступа к GitHub?)."
    fi
  fi
  # Keep the API helper in sync with this version of the script.
  write_helper; write_helper_env
  pair_revoke                     # pairing files left by a killed session
  update_check_background
  flush_notes 'Обновление'
  local ch
  # The text menu already has "0) Выход"; the TUI gets an explicit item for the mouse.
  local -a quit_item=()
  [[ $UI_MODE == tui ]] && quit_item=(quit '{dim}Выход{/}')
  while :; do
    ch=$(TUI_LOGO=1 TUI_CANCEL='Выход' tui_menu '3x-ui_reverse' "$(main_header)" \
         '#Обзор' '' \
         info $'Параметры и ссылки\t{dim}панель, подписки, файлы{/}' \
         pdf $'PDF с параметрами\t{dim}красивая сводка для печати и хранения{/}' \
         status $'Состояние служб\t{dim}3x-ui, прокси, порты, HTTPS{/}' \
         '#Управление' '' \
         users $'Пользователи\t{dim}трафик, активность, inbound-ы{/}' \
         groups $'Группы\t{dim}массовые действия{/}' \
         inbounds $'Inbound-ы\t{dim}VLESS, Trojan, Hysteria2, AmneziaWG, MTProto{/}' \
         nodes $'Подключить узел\t{dim}другие серверы 3x-ui под управлением этой панели{/}' \
         '#Диагностика' '' \
         diag $'Диагностика сервера\t{dim}iPerf3 до РФ, IP Region, Censorcheck DPI{/}' \
         multitest $'Multitest by @saveksme\t{dim}полный набор тестов сервера{/}' \
         '#Система' '' \
         settings $'Настройки панели\t{dim}порты, пути, логин{/}' \
         service $'Обслуживание\t{dim}перезапуск, переустановка{/}' \
         version "$(version_label)" \
         remove $'{red}Удаление{/}\t{dim}прокси, 3x-ui, всё{/}' \
         "${quit_item[@]}") || return 0
    case "$ch" in
      info) tui_show 'Параметры и ссылки' show_info_color ;;
      pdf) pdf_screen ;;
      status) tui_show 'Состояние служб' show_status_color ;;
      users) menu_users ;;
      groups) menu_groups ;;
      inbounds) menu_inbounds ;;
      nodes) menu_nodes ;;
      diag) menu_diag ;;
      multitest) diag_multitest ;;
      settings) menu_settings ;;
      service) menu_service ;;
      version) menu_version ;;
      remove) menu_remove ;;
      quit) return 0 ;;
    esac
    flush_notes
  done
}

# Visual preview only. Does not install, delete or change anything on the VPS.
demo_ui(){
  local idx
  local -a titles=(
    'Проверяем окружение'
    'Подготавливаем компоненты'
    'Устанавливаем Caddy'
    'Создаём страницу-заглушку'
    'Устанавливаем 3x-ui'
    'Привязываем веб-панель и подписки к 127.0.0.1'
    'Создаём inbound-ы Reality RAW / XHTTP / MTProto'
    'Записываем параметры входа'
  )
  local -a percentages=(5 18 33 43 75 85 93 100)
  ui_start 'Предпросмотр интерфейса' "${titles[@]}"
  for idx in "${!titles[@]}"; do
    msg "${titles[idx]}"
    sleep 0.7
    step "${percentages[idx]}" "${titles[idx]}"
  done
  ui_stop
  if [[ $TUI_OK == 1 ]]; then tui_msg 'Предпросмотр' '{green}✓ Предпросмотр завершён.{/} Система не изменена.'
  else printf 'Предпросмотр завершён. Система не изменена.\n'; fi
}

# ---------------------------------------------------------------- command line
usage(){
  cat <<EOF
3x-ui_reverse $VERSION — установка и управление 3x-ui за Caddy/Nginx

Интерактивно:
  3x-ui_reverse                 TUI (мышь, Enter — подтвердить, Backspace — назад)
  3x-ui_reverse --cli           то же меню в классическом текстовом виде
  3x-ui_reverse --tui           принудительно TUI

Команды:
  info | status                         параметры и ссылки | состояние служб
  pdf                                   (пере)создать PDF с параметрами
  bbr [on|off]                          TCP BBR + CAKE: состояние | включить | выключить
  diag iperf [--full]                   скорость до 5 городов России (iPerf3)
  diag ipregion | diag dpi              IP Region / Censorcheck DPI (оригинальные скрипты)
  multitest                             Multitest by @saveksme (оригинальный скрипт)
  users [list]                          пользователи: группа, inbound-ы, трафик, активность
  users show NAME                       карточка и ссылки подписки
  users add NAME [--gb N] [--days N] [--group G] [--inbounds 1,2,3]
  users del NAME
  users inbounds NAME 1,2,3             оставить пользователю ровно эти inbound-ы
  users group NAME [GROUP]              назначить группу (без GROUP — снять)
  groups [list]
  groups create NAME | rename OLD NEW | delete NAME
  groups members GROUP [NAME…]          установить состав группы
  groups inbounds GROUP set|add|remove 1,2,3
  inbounds [list]                       все inbound-ы панели
  inbounds kinds                        какие inbound-ы умеет создавать скрипт
  inbounds add KIND[,KIND…] [--tls CERT:KEY:SNI] [--port N] [--sni HOST] [--name NAME]
  inbounds edit ID [--port N] [--name NAME] [--sni HOST] [--tls domain|CERT:KEY:SNI] [--enable 0|1]
  inbounds del ID
  node [list]                           подключённые узлы (другие панели 3x-ui)
  node add DOMAIN TOKEN [--name NAME]   подключить узел по одноразовому токену с узла
  node add https://узел/путь/ --api-token T [--name NAME]   подключить вручную
  node show ID | node del ID
  node token                            (на узле) выдать токен подключения и ждать мастер
  node api-token [--rotate]             (на узле) API-токен для мастер-панели
  version | update [--check]            версия | проверить/установить обновление

Служебные: --repair  --demo  --uninstall  --remove-command  --restore-command

Переменные: XR_IPERF='Город=host,…'  XR_UI=cli|tui  XR_SNI=a.com,b.com,c.com  XR_SNIFF=route|metadata
            XR_COUNTRY=NL|none  XR_REPO=owner/name  NO_COLOR=1
EOF
}
cli_need_panel(){
  [[ $EUID -eq 0 ]] || die 'Запусти через sudo.'
  load_state
  write_helper                    # always the helper of this script version
  [[ "${PANEL_INSTALLED:-1}" == 1 ]] || die 'Панель 3x-ui удалена.'
  ensure_api_token 5 || die 'API 3x-ui недоступен (служба x-ui запущена?).'
}
cli_opt(){
  # cli_opt NAME ARGS… — value of --NAME in ARGS
  local name=$1; shift
  while (($#)); do
    if [[ "$1" == "--$name" ]]; then printf '%s' "${2:-}"; return 0; fi
    shift
  done
  return 0
}
cli_cmd(){
  local cmd=$1 sub=${2:-list}
  case "$cmd" in
    info) [[ $EUID -eq 0 ]] || die 'Запусти через sudo.'; load_state; write_helper; show_info_color ;;
    status) [[ $EUID -eq 0 ]] || die 'Запусти через sudo.'; load_state; write_helper; show_status_color ;;
    pdf)
      [[ $EUID -eq 0 ]] || die 'Запусти через sudo.'; load_state; write_helper
      pdf_ready || pdf_install_deps || die 'Не удалось установить python3-reportlab и fonts-dejavu-core.'
      write_pdf || die "Не удалось сформировать PDF (см. $LOG)."
      printf 'PDF: %s\nСкачать: %s\n' "$PDF_FILE" "$(pdf_download_hint)" ;;
    diag|multitest)
      [[ $EUID -eq 0 ]] || die 'Запусти через sudo.'
      [[ -r "$STATE" ]] && load_state
      if [[ ! -d "$BASE" ]]; then      # not installed: work from a temporary dir
        local d; d=$(mktemp -d "${TMPDIR:-/tmp}/3xr-diag.XXXXXXXX")
        HELPER=$d/xr_helper.py; HELPER_STATE=$d; LOG=$d/diag.log
      fi
      write_helper
      if [[ "$cmd" == multitest ]]; then run_external 'Multitest by @saveksme' "$MULTITEST_URL"; return; fi
      case "$sub" in
        iperf)
          local res secs=3; [[ "${3:-}" == --full ]] && secs=10
          res=$(mktemp); iperf_run "$secs" "$res" || die 'iPerf3: тест не выполнен.'
          helper iperf-table "$res"; rm -f -- "$res" ;;
        ipregion) run_external 'IP Region (Davoyan/ipregion)' "$DIAG_IPREGION_URL" ;;
        dpi) run_external 'Censorcheck DPI (vernette/censorcheck)' "$DIAG_CENSOR_URL" --mode dpi ;;
        *) die 'diag iperf [--full] | diag ipregion | diag dpi' ;;
      esac ;;
    bbr)
      [[ $EUID -eq 0 ]] || die 'Запусти через sudo.'; load_state
      case "$sub" in
        on) bbr_enable || exit 1; printf 'Включено: %s\n' "$(bbr_label)" ;;
        off) bbr_disable; printf 'Сейчас: %s\n' "$(bbr_label)" ;;
        *) printf '%s\n' "$(bbr_label)" ;;
      esac ;;
    users)
      cli_need_panel
      case "$sub" in
        list) helper users "$(tput cols 2>/dev/null || echo 120)" ;;
        show) [[ -n "${3:-}" ]] || die 'users show NAME'
              helper user-card "$3"; printf '\nСсылки подписки:\n'; print_user_links "$3" || : ;;
        add)  [[ -n "${3:-}" ]] || die 'users add NAME [--gb N] [--days N] [--group G] [--inbounds 1,2]'
              helper add-user "$3" "$(cli_opt gb "$@")" "$(cli_opt days "$@")" "$(cli_opt group "$@")" \
                "$(cli_opt inbounds "$@")" >/dev/null
              printf 'Пользователь %s создан.\n' "$3"; print_user_links "$3" || : ;;
        del)  [[ -n "${3:-}" ]] || die 'users del NAME'; helper del-user "$3"; printf 'Удалён: %s\n' "$3" ;;
        inbounds) [[ -n "${3:-}" ]] || die 'users inbounds NAME 1,2,3'; helper set-inbounds "$3" "${4:-}" ;;
        group) [[ -n "${3:-}" ]] || die 'users group NAME [GROUP]'; helper set-group "$3" "${4:-}" ;;
        *) die "Неизвестная подкоманда users $sub" ;;
      esac ;;
    groups)
      cli_need_panel
      case "$sub" in
        list) helper groups ;;
        create) helper group-create "${3:?groups create NAME}" ;;
        rename) helper group-rename "${3:?groups rename OLD NEW}" "${4:?groups rename OLD NEW}" ;;
        delete) helper group-delete "${3:?groups delete NAME}" ;;
        members) helper group-set-members "${3:?groups members GROUP NAME…}" "${@:4}" ;;
        inbounds) helper group-inbounds "${3:?groups inbounds GROUP set|add|remove IDS}" "${4:?set|add|remove}" "${5:-}" ;;
        *) die "Неизвестная подкоманда groups $sub" ;;
      esac ;;
    inbounds)
      cli_need_panel
      case "$sub" in
        list) helper inbounds ;;
        kinds) local k; for k in vless-tcp-reality vless-xhttp-reality vless-xhttp-tls trojan-tcp trojan-tcp-reality \
                 trojan-xhttp-reality trojan-xhttp-tls hysteria amneziawg mtproto; do
                 printf '  %-22s %s\n' "$k" "${KIND_LABEL[$k]}"; done ;;
        add|create) cli_inbounds_add "${@:3}" ;;
        edit) cli_inbounds_edit "${@:3}" ;;
        del) [[ -n "${3:-}" ]] || die 'inbounds del ID'; helper del-inbound "$3"; printf 'Удалён inbound %s\n' "$3" ;;
        *) die "Неизвестная подкоманда inbounds $sub" ;;
      esac ;;
    node|nodes)
      case "$sub" in
        list) cli_need_panel; helper nodes ;;
        add) cli_node_add "${@:3}" ;;
        show) cli_need_panel; [[ -n "${3:-}" ]] || die 'node show ID'; helper node-card "$3" | grep -v '^#' ;;
        del) cli_need_panel; [[ -n "${3:-}" ]] || die 'node del ID'; helper node-del "$3"; printf 'Узел %s удалён.\n' "$3" ;;
        token)
          cli_need_panel
          UI_WANT=cli; ui_init || die 'Нужен интерактивный терминал.'
          node_pair_screen; flush_notes ;;
        api-token)
          cli_need_panel
          if [[ "${3:-}" == --rotate ]]; then node_token_rotate || die 'Не удалось перевыпустить токен.'; fi
          node_api_token || die 'Не удалось получить API-токен узла.' ;;
        *) die "Неизвестная подкоманда node $sub" ;;
      esac ;;
    version)
      printf '3x-ui_reverse %s\n' "$VERSION"
      [[ -r "$STATE" ]] && load_state
      printf 'Репозиторий обновлений: %s\n' "$(update_repo || :)"
      ;;
    update)
      [[ $EUID -eq 0 ]] || die 'Запусти через sudo.'
      load_state; write_helper
      local out tag sha rel
      [[ -n "$(update_repo)" ]] || die 'Репозиторий обновлений не задан (XR_REPO=owner/name или экран «Версия»).'
      out=$(update_check_now) || die "Проверка не удалась: $out"
      read -r tag sha rel <<< "$out"
      printf 'Установлена %s, в репозитории %s (коммит %s)\n' "$VERSION" "$tag" "$sha"
      [[ "$rel" == newer ]] || { printf 'Обновление не требуется.\n'; return 0; }
      [[ "$sub" == --check ]] && return 0
      local tmp; tmp=$(mktemp)
      helper update-fetch "$(update_repo)" "$tag" "$UPDATE_ASSET" "$tmp" || die 'Не удалось скачать обновление.'
      bash -n "$tmp" && grep -qx "VERSION=$tag" "$tmp" || { rm -f -- "$tmp"; die 'Скачанный файл не прошёл проверку.'; }
      install -d -m 700 "$BASE/backups"
      [[ -f "$SELF" ]] && cp -a -- "$SELF" "$BASE/backups/3x-ui_reverse-$VERSION.sh"
      install -m 755 -- "$tmp" "$SELF"; rm -f -- "$tmp" "$UPDATE_CACHE"
      printf 'Обновлено до %s: %s\n' "$tag" "$SELF" ;;
  esac
}
# inbounds add KIND[,KIND…] [--tls CERT:KEY:SNI] [--port N] [--sni HOST] [--name NAME]
# node add DOMAIN TOKEN [--name N]          — по одноразовому токену с узла
# node add URL --api-token T [--name N]     — вручную
cli_node_add(){
  local target=${1:-} second=${2:-} name api out tmp
  [[ -n "$target" ]] || die 'node add DOMAIN TOKEN [--name ИМЯ]  |  node add https://узел/путь/ --api-token T [--name ИМЯ]'
  cli_need_panel
  name=$(cli_opt name "$@"); api=$(cli_opt api-token "$@")
  if [[ -n "$api" ]]; then
    [[ -n "$name" ]] || name=$(helper node-name "$(helper parse-url "$target" | sed -n 's/^address=//p')")
    out=$(XR_NODE_API_TOKEN=$api helper node-add --url "$target" --name "$name") || exit 1
  else
    [[ -n "$second" && "$second" != --* ]] || die 'node add DOMAIN TOKEN — нужен токен, выданный на узле (node token)'
    target=${target,,}; target=${target#https://}; target=${target%%/*}
    tmp=$(mktemp); chmod 600 "$tmp"
    if ! out=$(helper pair-fetch "$target" "$second" "$tmp"); then rm -f -- "$tmp"; exit 1; fi
    [[ -n "$name" ]] || name=$(helper node-name "$(sed -n 's/^name=//p' <<< "$out")")
    out=$(helper node-add --from "$tmp" --name "$name") || { rm -f -- "$tmp"; exit 1; }
    rm -f -- "$tmp"
  fi
  local st; st=$(sed -n 's/^status=//p' <<< "$out")
  [[ "$st" == online ]] && st='в сети' || st='проверяется (см. node list через несколько секунд)'
  printf 'Узел «%s» подключён (id %s), состояние: %s\n' "$(sed -n 's/^name=//p' <<< "$out")" \
    "$(sed -n 's/^id=//p' <<< "$out")" "$st"
}
cli_inbounds_add(){
  local kinds=${1:-} k tls port sni name crt key host err
  [[ -n "$kinds" ]] || die 'inbounds add KIND[,KIND…] (список: 3x-ui_reverse inbounds kinds)'
  tls=$(cli_opt tls "$@"); port=$(cli_opt port "$@"); sni=$(cli_opt sni "$@"); name=$(cli_opt name "$@")
  INB_KINDS=(); INB_TLS=()
  IFS=, read -ra INB_KINDS <<< "$kinds"
  for k in "${INB_KINDS[@]}"; do
    [[ -n "${KIND_LABEL[$k]:-}" ]] || die "Неизвестный тип: $k (список: 3x-ui_reverse inbounds kinds)"
    if [[ "$TLS_KINDS" == *" $k "* ]]; then
      if [[ -z "$tls" || "$tls" == domain ]]; then INB_TLS[$k]=domain
      else
        IFS=: read -r crt key host <<< "$tls"
        err=$(check_cert_files "$crt" "$key" "${host,,}") || die "$err"
        INB_TLS[$k]="$crt|$key|${host,,}"
      fi
    fi
  done
  if [[ -n "$port$sni$name" ]]; then
    ((${#INB_KINDS[@]} == 1)) || die '--port/--sni/--name можно задать только для одного inbound-а'
    [[ -z "$sni" ]] || XR_SNI=$sni
  fi
  setup_inbounds_cli "$port" "$name" || die 'Inbound-ы не созданы (см. журнал).'
  helper inbounds
}
setup_inbounds_cli(){
  local port=$1 name=$2 k=${INB_KINDS[0]}
  if [[ -n "$port" || -n "$name" ]]; then
    setup_inbounds || return 1
    [[ -z "$port" ]] || helper set-port "$CREATED_IDS" "$port" || return 1
    [[ -z "$name" ]] || helper set-name "$CREATED_IDS" "$name" || return 1
    open_firewall_ports "$CREATED_IDS" || :
    printf 'Создан %s (id %s)\n' "${KIND_LABEL[$k]}" "$CREATED_IDS"
    return 0
  fi
  setup_inbounds
}
# inbounds edit ID [--port N] [--name NAME] [--sni HOST] [--tls domain|CERT:KEY:SNI] [--enable 0|1]
cli_inbounds_edit(){
  local id=${1:-} v crt key host paths err
  [[ "$id" =~ ^[0-9]+$ ]] || die 'inbounds edit ID [--port N] [--name NAME] [--sni HOST] [--tls …] [--enable 0|1]'
  v=$(cli_opt port "$@");   [[ -z "$v" ]] || { helper set-port "$id" "$v" && open_firewall_ports "$id"; } || exit 1
  v=$(cli_opt name "$@");   [[ -z "$v" ]] || helper set-name "$id" "$v" || exit 1
  v=$(cli_opt sni "$@");    [[ -z "$v" ]] || helper set-sni "$id" "$v" || exit 1
  v=$(cli_opt enable "$@"); [[ -z "$v" ]] || helper set-enable "$id" "$v" || exit 1
  v=$(cli_opt tls "$@")
  if [[ "$v" == domain ]]; then
    paths=$(domain_cert_paths) || die "Сертификат домена $DOMAIN не найден."
    helper set-tls "$id" "$(sed -n 1p <<< "$paths")" "$(sed -n 2p <<< "$paths")" "$DOMAIN" || exit 1
  elif [[ -n "$v" ]]; then
    IFS=: read -r crt key host <<< "$v"
    err=$(check_cert_files "$crt" "$key" "${host,,}") || die "$err"
    helper set-tls "$id" "$crt" "$key" "${host,,}" || exit 1
  fi
  helper inbound-info "$id"
}
main_interactive(){
  if [[ -f "$STATE" ]]; then manager; else start_menu; fi
}

if [[ "${XUI_REVERSE_LIB_ONLY:-0}" != 1 ]]; then
  case "${1:-}" in
    --cli) UI_WANT=cli; main_interactive ;;
    --tui) UI_WANT=tui; main_interactive ;;
    --repair) ui_init || :; repair_incomplete ;;
    --demo) ui_init || :; demo_ui ;;
    --users) cli_cmd users list ;;
    --uninstall) uninstall_all || { flush_notes 'Удаление'; exit 1; } ;;
    --remove-command) remove_manager_command || : ;;
    --restore-command) restore_manager_command ;;
    --help|-h|help) usage ;;
    info|status|pdf|bbr|diag|multitest|users|groups|inbounds|node|nodes|version|update) cli_cmd "$@" ;;
    '') main_interactive ;;
    *) die "Неизвестный параметр: $1 (см. --help)" ;;
  esac
fi
