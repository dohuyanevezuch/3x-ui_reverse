#!/usr/bin/env bash
# 3x-ui_reverse: installer & manager for 3x-ui behind Nginx/Caddy + HTTPS,
# auto-created Reality/XHTTP/MTProto inbounds, users and groups. TUI and CLI.
# Run as root on a CLEAN VPS. Does not support existing panels/web sites.
set -Eeuo pipefail
umask 077

# Release version = the git tag of the commit this file comes from.
VERSION=v2.10.1
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
OLD_SUB_PORT='' OLD_SUB_SCHEME='' OLD_DOMAINS=''   # subscription port of a migrated panel (redirected)
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
  else printf '%s\n' "$*" | sed 's/{\(\/\|[a-z]*\)}//g'; fi
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
  local undo=''
  # A failed migration must not leave the panel hidden behind a broken proxy.
  if [[ ${MIGRATING:-0} == 1 ]] && declare -F migrate_restore >/dev/null && migrate_restore; then
    undo=$'\n\n'"Миграция отменена: прежняя база 3x-ui восстановлена, панель работает как раньше."
    [[ -n "${MIGRATE_KEPT:-}" ]] && undo+=$'\n'"Журнал и копия базы: $MIGRATE_KEPT"
    NOTES=()
  fi
  set -- "$*$undo"
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
  check_system
  command -v ss >/dev/null || true
}
# Root, systemd and a supported OS — needed by every mode (install, migration, tools).
check_system(){
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
}
# Only a fresh install needs a clean VPS; a migration takes over what is there.
check_clean_vps(){
  # An existing 3x-ui is not an error at start: the first-run menu offers to migrate it.
  # Only a fresh install refuses to run over it.
  if [[ -e "$STATE" || -e "$DB" || -e "$CLI" ]] || systemctl list-unit-files --no-legend x-ui.service 2>/dev/null | grep -q '^x-ui.service'; then
    if xui_present; then
      die "На сервере уже есть 3x-ui. Выбери «Перенести существующую 3x-ui» — пути, inbound-ы и пользователи сохранятся."
    fi
    die "Найдены остатки 3x-ui ($( { [[ -e "$CLI" ]] && printf '%s ' "$CLI"; [[ -e "$DB" ]] && printf '%s ' "$DB"; } )служба x-ui), но база или программа неполные. Удали их (x-ui uninstall) или восстанови 3x-ui и запусти скрипт снова — он предложит перенос."
  fi
  if [[ -e "$SELF" && "$0" != "$SELF" && ! -e "$STATE" ]]; then die "Найден $SELF без состояния (прошлая установка не завершилась?). Удали его и каталог $BASE, затем запусти установку снова."; fi
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
    printf 'OLD_SUB_PORT=%q\n' "${OLD_SUB_PORT:-}"
    printf 'OLD_SUB_SCHEME=%q\n' "${OLD_SUB_SCHEME:-}"
    printf 'OLD_DOMAINS=%q\n' "${OLD_DOMAINS:-}"
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
  # Paths kept from a migrated panel may be short (e.g. /sub/): only the charset is checked.
  for p in "$PANEL_PATH" "$SUB_PATH" "$JSON_PATH" "$CLASH_PATH"; do
    [[ "$p" =~ ^[A-Za-z0-9._~-]{1,64}$ ]] || die 'Неверный путь в состоянии.'
  done
  OLD_SUB_PORT=${OLD_SUB_PORT:-}; OLD_SUB_SCHEME=${OLD_SUB_SCHEME:-}
  [[ -z "$OLD_SUB_PORT" || ( "$OLD_SUB_PORT" =~ ^[0-9]{1,5}$ && "$OLD_SUB_SCHEME" =~ ^https?$ ) ]] || OLD_SUB_PORT=''
  OLD_DOMAINS=${OLD_DOMAINS:-}
  local od
  for od in $OLD_DOMAINS; do valid_domain "$od" || { OLD_DOMAINS=''; break; }; done
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
Пароль:                ${PANEL_PASS:-(изменён в панели 3x-ui)}
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
  local target=${1:-$BASE/Caddyfile} wd; wd=$(web_dir)
  # Hand edits of the live Caddyfile are not lost: other domains move to caddy/sites/.
  [[ "$target" == "$BASE/Caddyfile" ]] && caddy_keep_manual
  write_caddy_body "$target"
  [[ "$target" == "$BASE/Caddyfile" ]] && caddy_mark
  return 0
}
write_caddy_body(){
  local target=$1 wd; wd=$(web_dir)
  local acme=''
  [[ -s "$wd/acme-email" ]] && acme=$(head -n1 "$wd/acme-email")
  [[ "$acme" =~ ^[^[:space:]@{}]+@[^[:space:]@{}]+$ ]] || acme=''
  cat > "$target" <<EOF
{
    storage file_system $(certdir)${acme:+
    email $acme}
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
  if [[ -s "$wd/root.caddy" ]]; then
    # A service on the domain root instead of the stub; if it is down, the stub answers.
    cat >> "$target" <<EOF
    handle {
        import $wd/root.caddy
    }
    handle_errors {
        @down expression \`{err.status_code} in [502, 503, 504]\`
        handle @down {
            root * $SITE
            rewrite * /index.html
            file_server {
                status 200
            }
        }
    }
}
EOF
  else
    cat >> "$target" <<'EOF'
    handle {
        try_files {path} /index.html
        file_server
    }
}
EOF
  fi
  # Subscription links from before the migration (domain:OLD_PORT/…) -> 443.
  if [[ -n "${OLD_SUB_PORT:-}" && "${PANEL_INSTALLED:-1}" == 1 ]]; then
    local addr="https://$DOMAIN:$OLD_SUB_PORT"
    [[ "${OLD_SUB_SCHEME:-https}" == http ]] && addr="http://:$OLD_SUB_PORT"
    cat >> "$target" <<EOF

$addr {
    redir https://$DOMAIN{uri} 308
}
EOF
  fi
  # Former main domains: their links keep working through a redirect.
  local od
  for od in ${OLD_DOMAINS:-}; do
    [[ "$od" != "$DOMAIN" ]] || continue
    printf '\n# Former main domain (3x-ui_reverse: «Основной домен»)\n%s {\n    redir https://%s{uri} 308\n}\n' "$od" "$DOMAIN" >> "$target"
  done
  if compgen -G "$wd/sites/*.caddy" >/dev/null; then
    printf '\n# Other sites and services: %s/sites (not rewritten by the script)\nimport %s/sites/*.caddy\n' "$wd" "$wd" >> "$target"
  fi
  chmod 644 "$target"
}
web_dir(){ echo "$BASE/caddy"; }
# Checksum of the Caddyfile as the script wrote it: a mismatch means hand edits.
caddy_mark(){ [[ -f "$BASE/Caddyfile" ]] && sha256sum "$BASE/Caddyfile" | cut -d' ' -f1 > "$BASE/.Caddyfile.sha256"; return 0; }
caddy_keep_manual(){
  local live=$BASE/Caddyfile sum cand copy out moved
  [[ -f "$live" && -n "${DOMAIN:-}" ]] || return 0
  sum=$(sha256sum "$live" | cut -d' ' -f1)
  [[ -f "$BASE/.Caddyfile.sha256" && "$(cat "$BASE/.Caddyfile.sha256")" == "$sum" ]] && return 0
  if [[ ! -f "$BASE/.Caddyfile.sha256" ]]; then
    # No checksum yet (older version): unchanged if it renders the same.
    cand=$(mktemp "$BASE/caddy-check.XXXXXXXX")
    write_caddy_body "$cand"
    if cmp -s "$cand" "$live"; then rm -f "$cand"; return 0; fi
    rm -f "$cand"
  fi
  copy="$BASE/Caddyfile.manual-$(date +%Y%m%d-%H%M%S)"
  cp -a "$live" "$copy"
  out=$(helper caddy-split "$live" "$DOMAIN" "$(web_dir)/sites" --source "Caddyfile (ручные правки)" 2>>"$LOG") || out=''
  printf 'caddy-split %s:\n%s\n' "$copy" "$out" >> "$LOG"
  moved=$(awk -F'\t' '$1=="moved"{printf "%s%s", (n++?", ":""), $2}' <<< "$out")
  if [[ -n "$moved" ]]; then
    note "Caddyfile был изменён вручную. Сайты других доменов сохранены отдельно и продолжат работать: $moved (каталог $(web_dir)/sites). Правки внутри блока $DOMAIN не переносятся — они в копии: $copy"
  elif [[ -f "$BASE/.Caddyfile.sha256" ]]; then
    note "{yellow}⚠ Caddyfile был изменён вручную — правки основного домена перезаписаны. Копия: $copy. Свой сервис на корне домена задаётся в «Сайты и сервисы».{/}"
  fi
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
  # Subscription links from before the migration (domain:OLD_PORT/…) -> 443.
  if [[ -n "${OLD_SUB_PORT:-}" && "${PANEL_INSTALLED:-1}" == 1 ]]; then
    if [[ "${OLD_SUB_SCHEME:-https}" == https && "$mode" == full ]]; then
      cat >> "$target" <<EOF
server {
    listen $OLD_SUB_PORT ssl;
    listen [::]:$OLD_SUB_PORT ssl;
    server_name $DOMAIN;
    ssl_certificate $(certdir)/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key $(certdir)/live/$DOMAIN/privkey.pem;
    return 308 https://$DOMAIN\$request_uri;
}
EOF
    elif [[ "${OLD_SUB_SCHEME:-https}" == http ]]; then
      cat >> "$target" <<EOF
server {
    listen $OLD_SUB_PORT;
    listen [::]:$OLD_SUB_PORT;
    server_name _;
    return 308 https://$DOMAIN\$request_uri;
}
EOF
    fi
  fi
  chmod 644 "$target"
}

validate_proxy(){
  if [[ "$PROXY" == caddy ]]; then web_validate
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
  run "$CLI" setting -port "$PANEL_PORT" -webBasePath "$PANEL_PATH" -listenIP 127.0.0.1 || return 1
  xui_env_sync_port "$PANEL_PORT"
}
# ---- Environment of the x-ui service. 3x-ui 3.x reads XUI_* variables from these
# files itself (and from systemd Environment=): XUI_PORT overrides the panel port
# stored in the database, XUI_DB_FOLDER moves the SQLite file, XUI_DB_TYPE=postgres
# keeps everything in PostgreSQL.
XUI_ENV_FILES=(/etc/default/x-ui /etc/sysconfig/x-ui /etc/conf.d/x-ui)
XUI_ENV_BACKUPS=()               # "original|copy" made by xui_env_sync_port (migration undo)
xui_unit_files(){ systemctl cat x-ui 2>/dev/null | sed -n 's/^# \(\/.*\)$/\1/p'; }
# Env files: the ones 3x-ui reads itself plus EnvironmentFile= of the unit.
xui_env_paths(){
  printf '%s\n' "${XUI_ENV_FILES[@]}"
  systemctl show x-ui -p EnvironmentFiles --value 2>/dev/null | tr ' ' '\n' | grep '^/' | sed 's/^-//' || :
}
xui_env_get(){
  local key=$1 f v='' line
  for f in $(xui_env_paths | sort -u); do
    [[ -f "$f" ]] || continue
    line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?$key=" "$f" 2>/dev/null | tail -n1) || :
    [[ -n "$line" ]] && v=${line#*=}
  done
  if [[ -z "$v" ]]; then
    line=$(systemctl show x-ui -p Environment --value 2>/dev/null | tr ' ' '\n' | grep -E "^$key=" | tail -n1) || :
    [[ -n "$line" ]] && v=${line#*=}
  fi
  v=${v%%#*}; v=${v//[[:space:]]/}; v=${v%\"}; v=${v#\"}; v=${v%\'}; v=${v#\'}
  printf '%s' "$v"
}
# SQLite path of the running panel when XUI_DB_FOLDER is set for the service.
xui_resolve_db(){
  local folder
  [[ "$DB" == /etc/x-ui/x-ui.db ]] || return 0
  folder=$(xui_env_get XUI_DB_FOLDER)
  [[ -n "$folder" && "$folder" == /* ]] || return 0
  DB="${folder%/}/x-ui.db"
  export XUI_DB_FOLDER=${folder%/}     # the CLI must edit the same database
}
# XUI_PORT wins over the port in the database: keep it equal to PANEL_PORT.
xui_env_sync_port(){
  local port=$1 f cur changed=0 copy
  cur=$(xui_env_get XUI_PORT)
  [[ -n "$cur" && "$cur" != "$port" ]] || return 0
  install -d -m 700 "$BASE/backups"
  for f in $(xui_env_paths | sort -u) $(xui_unit_files); do
    [[ -f "$f" ]] && grep -q 'XUI_PORT=' "$f" 2>/dev/null || continue
    copy="$BASE/backups/$(basename "$f").$(date +%Y%m%d-%H%M%S-%N)"
    cp -a "$f" "$copy" && XUI_ENV_BACKUPS+=("$f|$copy")
    sed -i -E "s/(XUI_PORT=[\"']?)[0-9]+/\1$port/g" "$f"
    printf 'XUI_PORT %s -> %s in %s\n' "$cur" "$port" "$f" >> "$LOG"
    changed=1
  done
  ((changed)) && run systemctl daemon-reload
  return 0
}
xui_env_restore(){
  local e
  for e in "${XUI_ENV_BACKUPS[@]}"; do cp -a "${e#*|}" "${e%%|*}" 2>>"$LOG" || :; done
  ((${#XUI_ENV_BACKUPS[@]})) && { XUI_ENV_BACKUPS=(); run systemctl daemon-reload || :; }
  return 0
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
    cp -a "$backup" "$config"; [[ "$PROXY" == caddy ]] && caddy_mark
    warn "Новый конфиг не прошёл проверку, восстановлен $backup"
    return 1
  fi
  if ! reload_proxy; then
    cp -a "$backup" "$config"; [[ "$PROXY" == caddy ]] && caddy_mark
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
     restore_db "$before_db"
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
    restore_db "$dbbackup"
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
    restore_db "$dbbackup"
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

# Proxy packages and configuration (fresh install and migration).
proxy_install_pkgs(){
  if [[ "$PROXY" == caddy ]]; then
    command -v caddy >/dev/null 2>&1 || run env DEBIAN_FRONTEND=noninteractive apt-get install -y caddy
  else
    { command -v nginx >/dev/null 2>&1 && command -v certbot >/dev/null 2>&1; } ||
      run env DEBIAN_FRONTEND=noninteractive apt-get install -y nginx certbot
  fi
}
proxy_configure(){
  mkdir -p "$(certdir)"
  chmod 755 "$BASE/sertificates"
  if [[ "$PROXY" == caddy ]]; then
    # Stock package places a demo Caddyfile; back it up before replacing.
    [[ -f /etc/caddy/Caddyfile && ! -L /etc/caddy/Caddyfile ]] &&
      cp -a /etc/caddy/Caddyfile "$BASE/Caddyfile.$([[ ${MIGRATING:-0} == 1 ]] && echo before-migration || echo package-default)"
    if [[ ${MIGRATING:-0} == 1 && -f "$BASE/Caddyfile.before-migration" ]]; then
      local kept
      kept=$(helper caddy-split "$BASE/Caddyfile.before-migration" "$DOMAIN" "$(web_dir)/sites" --source 'прежний Caddyfile' 2>>"$LOG" |
             awk -F'\t' '$1=="moved"{printf "%s%s", (n++?", ":""), $2}')
      [[ -n "$kept" ]] && note "✓ Сайты из прежнего Caddyfile перенесены и продолжат работать: $kept."
    fi
    write_caddy
    ln -sfn "$BASE/Caddyfile" /etc/caddy/Caddyfile
    chown -R caddy:caddy "$(certdir)"
    chmod 750 "$(certdir)"
    validate_proxy || die 'Ошибка конфигурации Caddy.'
    run systemctl enable --now caddy
    run systemctl restart caddy
  else
    # Only on a fresh nginx install: disable the packaged default site.
    if [[ ${MIGRATING:-0} != 1 && -L /etc/nginx/sites-enabled/default ]]; then rm -f /etc/nginx/sites-enabled/default; fi
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
}

install_fresh(){
  first_run_prepare
  check_clean_vps
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
  msg "$proxy_install_stage"
  proxy_install_pkgs
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
  proxy_configure
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
    if [[ -n "$PANEL_PASS" ]]; then color_value 'Пароль' "$PANEL_PASS" "$C_YELLOW"
    else color_value 'Пароль' 'изменён в панели — «Настройки панели → Сохранить пароль из панели»' "$C_DIM"; fi
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
    [[ -n "$PANEL_PASS" ]] && copy_item 'пароль' "$PANEL_PASS"
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
    if rows=$( { ensure_api_token 1 && helper ports-all --local; } 2>>"$LOG") && [[ -n "$rows" ]]; then
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
  # Nodes of this master: their inbounds are checked on the nodes themselves.
  if [[ "${PANEL_INSTALLED:-1}" == 1 ]]; then
    local sym name addr detail
    while IFS=$'\t' read -r sym name addr detail; do
      [[ -n "$sym" ]] || continue
      case "$sym" in
        ●) status_line 'Узел' "● $name  $addr  ($detail)" ;;
        ✗) status_line 'Узел' "✗ $name  $addr  $detail" ;;
        *) status_line 'Узел' "$sym $name  $addr  ($detail)" ;;
      esac
    done < <(helper nodes-status 2>>"$LOG" || :)
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
      if [[ -s "$(web_dir)/root.caddy" ]] || compgen -G "$(web_dir)/sites/*.caddy" >/dev/null; then
        warn "Caddy обслуживает твои сайты и сервисы ($(web_dir)). Чтобы не отключить их, удаление Caddy остановлено."
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
# Copy a backup INTO the live database with SQLite's backup API: a plain cp
# would leave a stale -wal journal that SQLite replays over the restored data.
# Login/password from the state; an unknown password (changed in the web panel)
# leaves the panel's own credentials in place.
apply_creds(){
  [[ -n "$PANEL_PASS" ]] || return 0
  run "$CLI" setting -username "$PANEL_USER" -password "$PANEL_PASS"
}
restore_db(){
  local src=$1
  [[ -f "$src" ]] || return 1
  python3 - "$src" "$DB" <<'PYRESTORE' >>"$LOG" 2>&1
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as src, sqlite3.connect(sys.argv[2]) as dest:
    src.backup(dest)
    dest.execute('PRAGMA wal_checkpoint(TRUNCATE)')
PYRESTORE
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
      run systemctl stop x-ui || :; restore_db "$backup"; PANEL_PORT=$oldport
      set_local_guard; run systemctl start "$PROXY" || :; run systemctl start x-ui || :
      ui_stop failed; warn 'Перенос HTTPS завершился ошибкой. Восстановлена база и прежний прокси.'; return 1
    fi
    if ! curl -fsS --max-time 15 --resolve "$DOMAIN:443:127.0.0.1" -o /dev/null "https://$DOMAIN/$PANEL_PATH/" || ! ss -H -ltn "sport = :$SUB_PORT" | awk '{print $4}' | grep -Eq "(0\\.0\\.0\\.0|\\[::\\]):$SUB_PORT$"; then
      run systemctl stop x-ui || :; restore_db "$backup"; PANEL_PORT=$oldport
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
  if [[ -n "$backup" ]]; then restore_db "$backup" || { ui_stop failed; warn 'Не удалось вернуть базу из копии.'; return 1; }; fi
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
       ! apply_creds ||
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
       ! apply_creds; then
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
  if [[ -s "$backup" ]]; then restore_db "$backup"; fi
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
INB_NODE=0
select_inbounds(){
  local sel k
  local -a picked=() kopt=()
  [[ -n "${1:-}" ]] && kopt=(--fresh)
  ((INB_NODE)) && kopt+=(--node "$INB_NODE")
  read_check menu-kinds "${kopt[@]}"
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
  ((INB_NODE)) && args+=(--node "$INB_NODE")
  if ! out=$(helper create-inbounds "$kinds" --sniff "$XR_SNIFF" "${args[@]}" 2>&1); then
    printf '%s\n' "$out" >>"$LOG"
    warn "Не удалось создать inbound-ы: ${out#Ошибка: }"
    return 1
  fi
  CREATED_IDS=$(tail -n1 <<< "$out")
  helper enable-access-log >>"$LOG" 2>&1 || warn 'Не удалось включить журнал активности Xray.'
  setup_activity_timer || warn 'Не удалось включить учёт активности.'
  # shellcheck disable=SC2086  # ids are numbers separated by spaces
  ((INB_NODE)) || open_firewall_ports $CREATED_IDS || :
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
           go "{green}${DNS_GO_LABEL:-Продолжить установку}{/}" again 'Проверить снова' cancel 'Отменить') || return 1
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
  local where=''
  INB_NODE=0
  read_menu menu-servers
  if ((${#TSV_ITEMS[@]} > 2)); then
    INB_NODE=$(tui_menu 'Добавить inbound-ы' "Где создать inbound-ы?
{dim}На узле они создаются через эту панель, как у скрипта: свободные порты, SNI, название
с флагом страны узла. Inbound-ы с сертификатом домена (XHTTP TLS, Hysteria2) — только
на самом узле.{/}" "${TSV_ITEMS[@]}") || return 0
    ((INB_NODE)) && where=" на узле $(printf '%s\n' "${TSV_ITEMS[@]}" | awk -v n="$INB_NODE" 'f{print; exit} $0==n{f=1}' | cut -f1)"
  fi
  select_inbounds || return 0
  if with_progress 'Создание inbound-ов' "Создаём$where: $(selected_labels)" setup_inbounds; then
    note "{green}✓ Создано$where: $(selected_labels).{/}"
    if ((INB_NODE)); then
      # shellcheck disable=SC2086
      note "Открой на узле (ufw и файрвол провайдера): $(helper ports $CREATED_IDS 2>/dev/null || echo '?')."
    else
      # shellcheck disable=SC2086
      note "Открой во внешнем файрволе провайдера: $(helper ports $CREATED_IDS 2>/dev/null || echo '?')."
    fi
    note 'Подключи пользователей к новым inbound-ам: Пользователи или Группы → Inbound-ы.'
  fi
  INB_NODE=0
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
country_style_text(){
  if [[ "$(helper country-style 2>/dev/null)" == code ]]; then printf 'сокращение: 🇳🇱 NL'; else printf 'полностью: 🇳🇱 Netherlands'; fi
}
country_style_screen(){
  local cur ch n
  cur=$(helper country-style 2>>"$LOG") || cur=full
  ch=$(tui_radiolist 'Подпись страны' "Как писать страну в названиях inbound-ов, которые создаёт скрипт
(и при «Массовые действия → Названия как у скрипта»):" \
       full 'Полностью — 🇳🇱 Netherlands VLESS TCP Reality' "$([[ $cur == full ]] && echo ON || echo OFF)" \
       code 'Сокращение — 🇳🇱 NL VLESS TCP Reality' "$([[ $cur == code ]] && echo ON || echo OFF)") || return 0
  [[ "$ch" == "$cur" ]] && return 0
  helper country-style "$ch" >/dev/null 2>>"$LOG" || return 0
  if tui_yesno 'Подпись страны' "Переписать страну в названиях существующих inbound-ов?
{dim}Затронет только названия вида «🇳🇱 Netherlands …» / «🇳🇱 NL …», остальные не меняются.{/}" 'Переписать' 'Только для новых' yes; then
    n=$(helper inbounds-restyle 2>>"$LOG") || n=0
    note "✓ Переименовано inbound-ов: ${n:-0}."
  fi
}
# Several inbounds at once, on this server and on every node.
inbounds_bulk(){
  local ids act n plan changes
  ids=$(inbound_checklist 'Массовые действия' 'Отметь inbound-ы — со всех серверов (заголовки — сервер и страна):' '') || return 0
  [[ -n "$ids" ]] || return 0
  act=$(tui_menu 'Массовые действия' "Выбрано: $(tr ',' '\n' <<< "$ids" | grep -c .)" \
        rename $'Названия как у скрипта\t{dim}флаг, страна сервера, тип — 🇩🇪 Germany VLESS TCP Reality{/}' \
        enable 'Включить' \
        disable 'Выключить' \
        delete '{red}Удалить{/}') || return 0
  case "$act" in
    rename)
      plan=$(helper inbounds-rename-plan "$ids" 2>&1) || { tui_msg 'Ошибка' "${plan#Ошибка: }"; return 0; }
      changes=$(sed -n 's/^CHANGES=//p' <<< "$plan")
      if [[ "${changes:-0}" == 0 ]]; then tui_msg 'Названия' 'Все выбранные inbound-ы уже названы как у скрипта.'; return 0; fi
      tui_show "Новые названия ($changes)" grep -v '^CHANGES=' <<< "$plan"
      tui_yesno 'Названия' "Переименовать $changes inbound-ов?
{dim}Порты, ключи и пользователи не меняются. В приложениях клиентов новые названия
появятся после обновления подписки.{/}" 'Переименовать' 'Отмена' yes || return 0
      n=$(helper inbounds-rename "$ids" 2>&1) || { tui_msg 'Ошибка' "${n#Ошибка: }"; return 0; }
      note "{green}✓ Переименовано: $n.{/}" ;;
    enable|disable)
      n=$(helper inbounds-bulk "$act" "$ids" 2>&1) || { tui_msg 'Ошибка' "${n#Ошибка: }"; return 0; }
      note "✓ $([[ $act == enable ]] && echo Включено || echo Выключено): $n." ;;
    delete)
      tui_confirm_word 'Удалить inbound-ы' "Будут удалены inbound-ы: $(ids_names "$ids")

{red}Клиенты потеряют эти подключения.{/} Сами пользователи останутся в панели,
их можно подключить к другим inbound-ам: «Пользователи» или «Группы → Inbound-ы»." 'УДАЛИТЬ' || return 0
      n=$(helper inbounds-bulk delete "$ids" 2>&1) || { tui_msg 'Ошибка' "${n#Ошибка: }"; return 0; }
      note "✓ Удалено inbound-ов: $n." ;;
  esac
}
menu_inbounds(){
  need_panel_api || return 0
  local ch list id
  while :; do
    ch=$(tui_menu 'Inbound-ы' "$(inbounds_screen_text)" \
         add $'Добавить inbound-ы\t{dim}10 типов: VLESS, Trojan, Hysteria2, AmneziaWG, MTProto{/}' \
         edit $'Изменить inbound\t{dim}порт, название, SNI, TLS, вкл/выкл, удалить{/}' \
         bulk $'Массовые действия\t{dim}названия как у скрипта, вкл/выкл, удаление — со всех узлов{/}' \
         list 'Подробный список' \
         ports 'Порты для внешнего файрвола' \
         style "Подпись страны в названиях"$'\t{dim}'"$(country_style_text){/}") || return 0
    case "$ch" in
      add) inbound_add ;;
      edit) if id=$(pick_inbound 'Изменить inbound'); then inbound_screen "$id"; fi ;;
      bulk) inbounds_bulk ;;
      style) country_style_screen ;;
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

# ---- subscription page templates (3x-ui "Sub Theme Directory")
subpage_dir(){ printf "%s" "$BASE/custom_subpage"; }
subpages_sync(){
  local out
  out=$(helper subpages-sync "$(subpage_dir)" "${XR_SUBPAGES_REPO:-}" 2>&1) || { SUBPAGE_ERR=${out#Ошибка: }; return 1; }
  SUBPAGE_ERR=''
}
subpage_apply(){ helper subpage-set "$(subpage_dir)" "$1" >>"$LOG" 2>&1; }
subpage_preview_hint(){
  local sid base
  base=$(sub_base); [[ -n "$base" ]] || return 0
  sid=$(helper sub-id user1 2>/dev/null) || sid=''
  if [[ -n "$sid" ]]; then
    printf 'Открой в браузере ссылку подписки, например user1:\n  %s' "$base/$SUB_PATH/$sid"
  else
    printf 'Открой в браузере ссылку подписки любого пользователя: %s' "$base/$SUB_PATH/…"
  fi
}
subpage_screen(){
  local rows cur src updated name active size ch label head age
  local -a items=()
  # Templates are downloaded on first use and refreshed when older than a day.
  updated=$(helper subpages-list "$(subpage_dir)" 2>>"$LOG" | awk -F'\t' '$1=="SRC"{print $3}') || updated=0
  if (( $(date +%s) - ${updated:-0} > 86400 )); then
    if ! with_progress 'Страница подписки' 'Скачиваем шаблоны с GitHub' subpages_sync; then
      [[ -d "$(subpage_dir)" ]] && compgen -G "$(subpage_dir)/*/index.html" >/dev/null ||
        { tui_msg 'Страница подписки' "{red}✗ Не удалось скачать шаблоны:{/} $SUBPAGE_ERR"; return 0; }
      note "{yellow}⚠ Шаблоны не обновились ($SUBPAGE_ERR) — показаны скачанные раньше.{/}"
      flush_notes 'Страница подписки'
    fi
  fi
  while :; do
    rows=$(helper subpages-list "$(subpage_dir)" 2>&1) || { tui_msg 'Страница подписки' "{red}✗ ${rows#Ошибка: }{/}"; return 0; }
    cur=$(awk -F'\t' '$1=="CUR"{print $2}' <<< "$rows")
    src=$(awk -F'\t' '$1=="SRC"{print $2}' <<< "$rows")
    updated=$(awk -F'\t' '$1=="SRC"{print $3}' <<< "$rows")
    items=(default "$([[ -z $cur ]] && echo '{green}●{/}' || echo '○') Стандартная страница 3x-ui")
    label=''
    while IFS=$'\t' read -r name active size; do
      [[ "$name" == CUR || "$name" == SRC || -z "$name" ]] && continue
      items+=("t:$name" "$([[ $active == 1 ]] && echo '{green}●{/}' || echo '○') $name"$'\t'"{dim}$size{/}")
      [[ $active == 1 ]] && label=$name
    done <<< "$rows"
    if [[ -z "$cur" ]]; then label='стандартная 3x-ui'
    elif [[ -z "$label" ]]; then label="своя: $cur"; fi
    age=''; [[ "$updated" =~ ^[0-9]+$ && "$updated" -gt 0 ]] && age=$(date -d "@$updated" '+%d.%m.%Y %H:%M')
    head="Сейчас: {bold}$label{/}
{dim}Шаблоны: github.com/${src:-${XR_SUBPAGES_REPO:-dohuyanevezuch/3x-ui_subpages}}${age:+ · обновлены $age}
Страница открывается, когда ссылку подписки открывают в браузере; приложения
получают подписку как раньше.{/}"
    ch=$(tui_menu 'Страница подписки' "$head" "${items[@]}" \
         sync $'Обновить шаблоны\t{dim}скачать заново из репозитория{/}') || return 0
    case "$ch" in
      sync)
        if with_progress 'Страница подписки' 'Скачиваем шаблоны с GitHub' subpages_sync; then
          note '{green}✓ Шаблоны обновлены.{/} Выбранная страница уже показывает новую версию.'
        else
          note "{red}✗ $SUBPAGE_ERR{/}"
        fi ;;
      default|t:*)
        name=${ch#t:}
        if with_progress 'Страница подписки' 'Применяем страницу' subpage_apply "$name"; then
          note "{green}✓ Страница подписки: $([[ $name == default ]] && echo 'стандартная 3x-ui' || echo "$name").{/}"
          note "$(subpage_preview_hint)"
        else
          note "{red}✗ Не удалось применить (журнал: $LOG).{/}"
        fi ;;
    esac
    flush_notes 'Страница подписки'
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
         6 "Сохранить пароль из панели"$'\t{dim}если его сменили в самой 3x-ui{/}' \
         4 'Изменить порт подписок' \
         5 'Изменить путь подписок' \
         7 "Страница подписки"$'\t{dim}оформление ссылки подписки в браузере{/}' \
         8 "Сменить основной домен"$'\t{dim}'"$DOMAIN"$'{/}') || return 0
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
      6) panel_creds_remember ;;
      7) subpage_screen ;;
      8) domain_screen; load_state ;;
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
      printf 'panel_url\t%s\nuser\t%s\npass\t%s\nport\t%s\n' "$panel_url" "$PANEL_USER" "${PANEL_PASS:-изменён в панели}" "$PANEL_PORT"
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
  local head_extra='' 
  local -a mig_item=() inst_item=(install $'Установить 3x-ui + прокси\t{dim}Caddy или Nginx, HTTPS, сайт-заглушка{/}')
  if xui_present; then
    head_extra=$'\n\n'"{yellow}⚠ Найдена установленная 3x-ui $(xui_version).{/} Её можно перенести под управление
скрипта: пути панели и подписок, inbound-ы и пользователи сохранятся."
    mig_item=(migrate $'Перенести существующую 3x-ui\t{dim}миграция с сохранением путей и inbound-ов{/}')
    inst_item=()                  # a fresh install needs a clean VPS
  fi
  while :; do
    ch=$(TUI_LOGO=1 TUI_CANCEL='Выход' tui_menu '3x-ui_reverse' "Сервер ещё не настроен.
{dim}$os · $(hostname 2>/dev/null || echo VPS){/}$head_extra" \
         "${mig_item[@]}" \
         "${inst_item[@]}" \
         dns $'Проверить DNS-записи\t{dim}куда указывает домен в 16 DNS мира{/}' \
         diag $'Диагностика сервера\t{dim}iPerf3 до РФ, IP Region{/}' \
         quit '{dim}Выход{/}') || return 0
    case "$ch" in
      install)
        if install_fresh && [[ -f "$STATE" ]]; then manager; return 0; fi
        DOMAIN='' ;;
      migrate)
        if migrate_flow && [[ -f "$STATE" ]]; then manager; return 0; fi
        MIGRATING=0; DOMAIN='' ;;
      dns) dns_standalone ;;
      diag) menu_diag ;;
      quit) return 0 ;;
    esac
  done
}

# ---- Diagnostics: iPerf3 to Russia and IP Region (original script, our table)
DIAG_IPREGION_URL='https://github.com/Davoyan/ipregion/raw/main/ipregion.sh'

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

# run_capture OUT command… — like run(), but stdout goes to OUT.
run_capture(){
  local out=$1; shift
  if [[ $UI_MODE == tui ]]; then
    "$@" </dev/null >"$out" 2>>"$LOG" {TUI_REQ}>&- {TUI_RESP}>&- {UI_OUT_FD}>&- {UI_ERR_FD}>&-
  else
    "$@" </dev/null >"$out" 2>>"$LOG"
  fi
}
# IP Region: the original Davoyan/ipregion runs in the background (JSON mode)
# while the gauge spins; its results are shown as our own table.
ipregion_deps(){
  local -a pkgs=()
  command -v curl >/dev/null 2>&1 || pkgs+=(curl)
  command -v jq >/dev/null 2>&1 || pkgs+=(jq)
  if ((${#pkgs[@]})) || ! command -v column >/dev/null 2>&1; then
    run apt-get update || :
    ((${#pkgs[@]})) && { run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" || return 1; }
    if ! command -v column >/dev/null 2>&1; then
      run env DEBIAN_FRONTEND=noninteractive apt-get install -y bsdextrautils ||
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y util-linux || return 1
    fi
  fi
  # ipregion would otherwise ask on /dev/tty to install them itself.
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v column >/dev/null 2>&1
}
# ipregion_run JSONFILE — 0 when the file holds the script's JSON result.
ipregion_run(){
  local out=$1 script rc=0
  script=$(mktemp "${UI_DIR:-${TMPDIR:-/tmp}}/ipregion.XXXXXXXX")
  ui_start 'IP Region · Davoyan/ipregion' \
    'Скачиваем ipregion с GitHub' \
    'Проверяем зависимости: curl, jq, column' \
    'Опрашиваем GeoIP-базы и сервисы — около минуты' \
    'Готовим таблицу'
  msg 'Скачиваем ipregion с GitHub'
  if ! run curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 -o "$script" "$DIAG_IPREGION_URL" ||
     ! bash -n "$script" 2>/dev/null; then
    ui_stop failed; rm -f -- "$script"
    warn "Не удалось скачать ipregion: $DIAG_IPREGION_URL"
    return 1
  fi
  step 10 'Скрипт скачан'
  msg 'Проверяем зависимости: curl, jq, column'
  if ! ipregion_deps; then
    ui_stop failed; rm -f -- "$script"
    warn 'Не удалось установить зависимости ipregion (curl, jq, bsdextrautils).'
    return 1
  fi
  step 20 'Зависимости на месте'
  msg 'Опрашиваем GeoIP-базы и сервисы — около минуты'
  # setsid: no controlling terminal, so the script can never prompt over the TUI.
  run_capture "$out" setsid -w timeout 300 bash "$script" --json || rc=$?
  rm -f -- "$script"
  msg 'Готовим таблицу'
  if ! helper ipregion-check "$out" >/dev/null 2>>"$LOG"; then
    ui_stop failed
    warn "ipregion не вернул результат (код $rc). Подробности: $LOG"
    return 1
  fi
  step 100 'Готово'
  ui_stop
}
diag_ipregion(){
  local res
  res=$(mktemp "${UI_DIR:-${TMPDIR:-/tmp}}/ipregion-res.XXXXXXXX")
  if ipregion_run "$res"; then
    tui_show 'IP Region — как сервисы видят этот IP' helper ipregion-table "$res" "$(ui_width)"
  fi
  rm -f -- "$res"
}
menu_diag(){
  local ch
  while :; do
    ch=$(tui_menu 'Диагностика сервера' 'Скорость до России и то, какой страной сервисы считают этот IP.' \
         iperf $'iPerf3 до РФ\t{dim}скорость до 5 городов России{/}' \
         ipregion $'IP Region\t{dim}страна IP в GeoIP-базах и сервисах · Davoyan/ipregion{/}') || return 0
    case "$ch" in
      iperf) diag_iperf ;;
      ipregion) diag_ipregion ;;
    esac
    flush_notes
  done
}

# ---- Routing on the clients' devices, delivered by this panel's subscriptions
ROUTING_UNIT=3x-ui_reverse-routing

routing_timer_sync(){
  # Daily refresh of URL lists — only while such lists exist.
  if [[ -f "$BASE/routing.json" ]] && { grep -q '"type": "url"' "$BASE/routing.json" ||
       grep -Eq '"mode": "(ru-direct|blocked-proxy)"' "$BASE/routing.json"; } 2>/dev/null; then
    [[ -f "/etc/systemd/system/$ROUTING_UNIT.timer" ]] && return 0
    write_helper_env
    cat > "/etc/systemd/system/$ROUTING_UNIT.service" <<EOF
[Unit]
Description=3x-ui_reverse: refresh routing lists
After=x-ui.service network-online.target
[Service]
Type=oneshot
Environment=XR_STATE_DIR=$BASE
ExecStart=/usr/bin/python3 -I $HELPER routing-refresh
EOF
    cat > "/etc/systemd/system/$ROUTING_UNIT.timer" <<'EOF'
[Unit]
Description=3x-ui_reverse: refresh routing lists daily
[Timer]
OnBootSec=10min
OnUnitActiveSec=1d
RandomizedDelaySec=30min
[Install]
WantedBy=timers.target
EOF
    chmod 644 "/etc/systemd/system/$ROUTING_UNIT.service" "/etc/systemd/system/$ROUTING_UNIT.timer"
    run systemctl daemon-reload && run systemctl enable --now "$ROUTING_UNIT.timer" || :
  elif [[ -f "/etc/systemd/system/$ROUTING_UNIT.timer" ]]; then
    run systemctl disable --now "$ROUTING_UNIT.timer" || :
    rm -f "/etc/systemd/system/$ROUTING_UNIT.service" "/etc/systemd/system/$ROUTING_UNIT.timer"
    run systemctl daemon-reload || :
  fi
  return 0
}
# routing_do TITLE PHASE helper-args… — run a routing change with a gauge;
# the helper rolls Xray back itself if the new config is rejected.
routing_do(){
  local title=$1 phase=$2 out; shift 2
  ui_start "$title" "$phase"
  msg "$phase"
  step 40 "$phase"
  if out=$(helper "$@" 2>&1); then
    ui_stop
    ROUTING_OUT=$out
    routing_timer_sync
    return 0
  fi
  ui_stop failed
  tui_msg "$title" "{red}✗ ${out#Ошибка: }{/}"
  return 1
}
routing_apps_text(){
  printf '%s\n' "Правила приходят в приложение вместе с подпиской — настраивать на устройстве ничего не нужно:

  {green}●{/} Happ, INCY — любая подписка (обычная или JSON)
  {green}●{/} v2rayN, v2rayNG и др. на Xray — {bold}JSON-подписка{/} (/$JSON_PATH/…)
  {green}●{/} Clash Verge, FlClash, Mihomo — {bold}Clash-подписка{/} (/$CLASH_PATH/…)
  {dim}○ Hiddify, Streisand, Shadowrocket и v2rayNG с обычной подпиской правила не получают —
    там маршрутизация настраивается в самом приложении.{/}

{dim}Приложение подхватит правила при следующем обновлении подписки.{/}"
}
routing_after_note(){
  local dropped
  dropped=$(sed -n 's/^happ_dropped=//p' <<< "$ROUTING_OUT")
  if [[ -n "$dropped" && "$dropped" != 0 ]]; then
    note "{yellow}⚠ В Happ/INCY не поместились $dropped своих записей (заголовок подписки до 8 КБ); в JSON- и Clash-подписках они есть.{/}"
  fi
  if grep -q '^lists_missing=1' <<< "$ROUTING_OUT"; then
    note '{yellow}⚠ Список заблокированного (itdoginfo) не скачался — JSON-подписка получит его при следующем обновлении (раз в сутки). Happ и Clash берут списки сами.{/}'
  fi
  note '{dim}Клиенты получат правила при следующем обновлении подписки. Подключения через сервер не прерывались.{/}'
}
routing_mode_screen(){
  local cur ch
  cur=$(helper routing-show 2>>"$LOG" | sed -n 's/^mode=//p')
  ch=$(tui_radiolist 'Режим маршрутизации' "Маршрутизация на устройствах клиентов — её раздаёт подписка этой панели.
{bold}Напрямую{/} — сайт открывается с IP самого устройства (домашний интернет, мобильная сеть).
{bold}Через сервер{/} — через inbound этой панели (сервер за границей).

{dim}Списки: runetfreedom (geosite/geoip: ru-blocked, category-ru) и itdoginfo/allow-domains.{/}" \
       off 'Выключена — весь трафик через сервер' "$([[ $cur == off ]] && echo ON || echo OFF)" \
       ru-direct 'Российские сайты напрямую, остальное через сервер' "$([[ $cur == ru-direct ]] && echo ON || echo OFF)" \
       blocked-proxy 'Через сервер только заблокированное в РФ, остальное напрямую' "$([[ $cur == blocked-proxy ]] && echo ON || echo OFF)") || return 0
  [[ "$ch" == "$cur" ]] && return 0
  routing_do 'Маршрутизация' 'Записываем правила в подписки' routing-mode "$ch" || return 0
  case "$ch" in
    off) note '○ Маршрутизация выключена: клиенты снова пускают весь трафик через сервер.' ;;
    ru-direct) note '{green}✓ Российские сайты — напрямую с устройства, остальное — через сервер.{/}' ;;
    *) note '{green}✓ Через сервер — только заблокированное в РФ, остальное — напрямую.{/}' ;;
  esac
  [[ "$ch" == off ]] || routing_after_note
}
routing_add_screen(){
  local kind=$1 val action out
  if [[ "$kind" == url ]]; then
    val=$(tui_input 'Список по ссылке' "Ссылка на список доменов или IP (текстовый файл).
{dim}Понимает строки доменов, domain:/full:/regexp:, IP и подсети, формат hosts и dnsmasq.
Список обновляется автоматически раз в сутки.{/}" '') || return 0
  else
    val=$(tui_input 'Свои домены' "Домены или IP через пробел или запятую, например:
{accent}youtube.com googlevideo.com 1.2.3.0/24{/}
{dim}Поддомены входят автоматически (youtube.com → www.youtube.com, m.youtube.com).{/}" '') || return 0
  fi
  [[ -n "${val// /}" ]] || return 0
  action=$(tui_radiolist 'Куда направлять' 'Как устройства клиентов будут открывать эти адреса:' \
           proxy 'Через сервер' ON direct 'Напрямую' OFF) || return 0
  if [[ "$kind" == url ]]; then
    routing_do 'Маршрутизация' 'Скачиваем список и обновляем подписки' routing-add "$action" url "$val" || return 0
  else
    routing_do 'Маршрутизация' 'Обновляем подписки' routing-add "$action" domains "$val" || return 0
  fi
  out=$(sed -n 's/^count=//p' <<< "$ROUTING_OUT")
  note "{green}✓ Добавлено записей: ${out:-?} — $([[ $action == proxy ]] && echo 'через сервер' || echo 'напрямую').{/}"
  routing_after_note
}
routing_rules_screen(){
  local id ch first=1
  while :; do
    read_menu routing-rules
    if ((${#TSV_ITEMS[@]} == 0)); then
      ((first)) && tui_msg 'Свои правила' 'Своих правил пока нет.'
      return 0
    fi
    first=0
    id=$(tui_menu 'Свои правила' 'Свои правила важнее режима: «через сервер» — раньше всего остального.' "${TSV_ITEMS[@]}") || return 0
    ch=$(tui_menu 'Правило' "$(helper routing-rules 2>>"$LOG" | awk -F'\t' -v i="$id" '$1==i {print $2"  "$3}')" \
         proxy 'Через сервер' direct 'Напрямую' refresh 'Обновить список сейчас' del '{red}Удалить правило{/}') || continue
    routing_do 'Маршрутизация' 'Обновляем подписки' routing-rule "$id" "$ch" || :
  done
}
menu_routing(){
  need_panel_api || return 0
  local ch head
  while :; do
    head=$(helper routing-text 2>>"$LOG") || head='{red}API 3x-ui недоступен{/}'
    ch=$(tui_menu 'Маршрутизация' "$head
{dim}Сайты открываются напрямую с устройства клиента или через этот сервер.{/}" \
         mode $'Режим\t{dim}РФ напрямую / только заблокированное через сервер{/}' \
         '#Свои правила' '' \
         domains $'Добавить домены или IP\t{dim}напрямую или через сервер{/}' \
         url $'Добавить список по ссылке\t{dim}обновляется раз в сутки{/}' \
         rules $'Свои правила\t{dim}изменить, обновить, удалить{/}' \
         '#Справка' '' \
         apps $'Какие приложения поддерживают\t{dim}Happ, v2rayN, Clash…{/}') || return 0
    case "$ch" in
      mode) routing_mode_screen ;;
      domains) routing_add_screen domains ;;
      url) routing_add_screen url ;;
      rules) routing_rules_screen ;;
      apps) tui_msg 'Маршрутизация в приложениях' "$(routing_apps_text)" ;;
    esac
    flush_notes
  done
}

# ---- Migration of an existing 3x-ui (installed without this script)
# Keeps the panel path, subscription paths, inbounds and users; moves the
# panel and subscriptions to 127.0.0.1 behind Caddy/Nginx on 443 and
# redirects the old subscription port (domain:PORT/path) to https://domain/path.
MIGRATING=0
declare -A XS=()          # settings of the existing panel (migrate-scan)
MIG_INB=()                # "id port transport proto listen sec crt sni enable remark"

xui_present(){ [[ -x "$CLI" ]] && { [[ -f "$DB" ]] || xui_on_postgres; }; }
xui_on_postgres(){ [[ "$(xui_env_get XUI_DB_TYPE)" == postgres* ]]; }
xui_version(){ local v; v=$("$CLI" -v 2>/dev/null || :); v=${v%%$'\n'*}; printf '%s' "${v//$'\r'/}"; }
xui_has_tokens(){ local h; h=$("$CLI" setting -h 2>&1 || :); [[ "$h" == *getApiToken* ]]; }
# Who listens on a TCP port: process names, comma separated.
port_owner(){
  ss -H -ltnp "sport = :$1" 2>/dev/null | grep -o 'users:(("[^"]*"' | sed 's/users:(("//;s/"$//' | sort -u | paste -sd, - || :
}
strip_slashes(){ local p=${1#/}; p=${p%/}; printf '%s' "$p"; }

migrate_scan(){
  local line k v
  XS=(); MIG_INB=()
  while IFS= read -r line; do
    if [[ "$line" == INB$'\t'* ]]; then
      MIG_INB+=("${line#INB$'\t'}")
    elif [[ "$line" == *=* ]]; then
      k=${line%%=*}; v=${line#*=}; XS[$k]=$v
    fi
  done < <(helper migrate-scan "$DB" 2>>"$LOG")
  # XUI_PORT for the service overrides the port stored in the database.
  v=$(xui_env_get XUI_PORT)
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    printf 'XUI_PORT override: %s (database: %s)\n' "$v" "${XS[webPort]:-}" >> "$LOG"
    XS[webPort]=$v
  fi
  [[ -n "${XS[webPort]:-}" ]]
}
# Domain candidates: panel/subscription domain, certificate names, subURI host.
migrate_domain_guess(){
  local d f
  for d in "${XS[subDomain]:-}" "${XS[webDomain]:-}"; do
    valid_domain "$d" && { printf '%s' "$d"; return; }
  done
  d=$(sed -E 's#^[a-z]+://([^/:]+).*#\1#' <<< "${XS[subURI]:-}")
  valid_domain "$d" && { printf '%s' "$d"; return; }
  for f in "${XS[webCertFile]:-}" "${XS[subCertFile]:-}"; do
    [[ -n "$f" && -r "$f" ]] || continue
    d=$(openssl x509 -in "$f" -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^,]*' | head -n1 | cut -d: -f2)
    [[ -z "$d" ]] && d=$(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p')
    valid_domain "$d" && { printf '%s' "$d"; return; }
  done
  return 0
}
migrate_conflicts(){       # inbounds that hold 80/443 TCP (needed by the proxy)
  local r id port tr rest
  for r in "${MIG_INB[@]}"; do
    IFS=$'\t' read -r id port tr rest <<< "$r"
    [[ "$tr" == tcp && ( "$port" == 443 || "$port" == 80 ) ]] && printf '%s %s\n' "$id" "$port"
  done
  return 0
}
migrate_summary_text(){
  local ver=$1 web sub n o80 o443
  web="${XS[webCertFile]:+https}"; web=${web:-http}
  sub="${XS[subCertFile]:+https}"; sub=${sub:-http}
  n=${#MIG_INB[@]}
  o80=$(port_owner 80); o443=$(port_owner 443)
  [[ -n "$o80" ]] || o80='{dim}свободен{/}'
  [[ -n "$o443" ]] || o443='{dim}свободен{/}'
  printf '%s\n' "{yellow}⚠ На сервере уже установлена 3x-ui${ver:+ $ver}.{/}" ''
  printf '  Панель       %s://…:%s%s\n' "$web" "${XS[webPort]}" "${XS[webBasePath]}"
  if [[ "${XS[subEnable]}" == true ]]; then
    printf '  Подписки     %s://…:%s%s\n' "$sub" "${XS[subPort]}" "${XS[subPath]}"
  else
    printf '  Подписки     {dim}выключены{/}\n'
  fi
  printf '  Inbound-ы    %s\n' "$n"
  printf '  Порт 80      %s\n' "$o80"
  printf '  Порт 443     %s\n' "$o443"
  printf '\n%s\n' 'Скрипт может взять её под управление: панель и подписки уйдут за прокси на 443,'
  printf '%s\n' 'пути панели и подписок, inbound-ы и пользователи сохранятся,'
  printf '%s\n' 'а старые ссылки подписки domain:порт/… будут перенаправляться на domain/….'
}

migrate_flow(){
  first_run_prepare
  MIGRATING=1
  local ver mode entered pass_mode pass1 proxy_choice o443 o80 conf
  local -a conflicts=() blockers=()
  ver=$(xui_version)
  if xui_on_postgres; then
    pg_to_sqlite_flow || return 1
    ver=$(xui_version)
  fi
  if ! migrate_scan; then
    tui_msg 'Миграция' "{red}✗ Не удалось прочитать базу 3x-ui ($DB).{/} Подробности в журнале."
    return 1
  fi
  # --- 1. what to do with the panel binary
  if xui_has_tokens; then
    mode=$(TUI_LOGO=1 tui_radiolist 'Миграция 3x-ui' "$(migrate_summary_text "$ver")" \
           takeover 'Взять под управление — оставить установленную 3x-ui как есть' ON \
           reinstall 'Переустановить последнюю 3x-ui — с сохранением базы, путей и inbound-ов' OFF) || return 1
  else
    TUI_LOGO=1 tui_yesno 'Миграция 3x-ui' "$(migrate_summary_text "$ver")

{yellow}Эта версия 3x-ui слишком старая для управления скриптом{/} (нет API-токенов).
Её нужно обновить официальным установщиком — база, пути и inbound-ы сохранятся." \
      'Обновить и перенести' 'Отмена' yes || return 1
    mode=reinstall
  fi
  # --- 2. domain
  entered=$(migrate_domain_guess)
  while :; do
    entered=$(TUI_LOGO=1 tui_input 'Домен' 'Домен этого сервера — на нём будут панель и подписки (HTTPS на 443):' "$entered") || return 1
    entered=${entered,,}; entered=${entered%.}
    valid_domain "$entered" && break
    tui_msg 'Неверный домен' 'Введи корректное DNS-имя: не IP-адрес, не URL и без порта.'
  done
  DOMAIN=$entered
  dns_check_screen || return 1
  # --- 3. credentials
  PANEL_USER=${XS[username]:-}
  pass_mode=$(tui_radiolist 'Вход в панель' "Логин в панели сейчас: {bold}${PANEL_USER:-?}{/}" \
              keep 'Оставить текущий логин и пароль' ON \
              new 'Задать новые случайные логин и пароль' OFF) || return 1
  if [[ "$pass_mode" == keep ]]; then
    while :; do
      pass1=$(tui_input 'Текущий пароль' "Пароль панели для «$PANEL_USER» — скрипт проверит его и сохранит в параметрах (chmod 600):" '') || return 1
      if migrate_check_password "$pass1"; then PANEL_PASS=$pass1; break; fi
      tui_yesno 'Пароль не подошёл' 'Панель не приняла этот пароль (или включена двухфакторная защита).' \
        'Ввести снова' 'Задать новый' yes || { pass_mode=new; break; }
    done
  fi
  if [[ "$pass_mode" == new ]]; then PANEL_USER="u$(rand 12)"; PANEL_PASS=$(rand 28); fi
  # --- 4. proxy
  o80=$(port_owner 80); o443=$(port_owner 443)
  for conf in ${o80//,/ } ${o443//,/ }; do
    case "$conf" in caddy|nginx|x-ui|xray*|'') ;; *) blockers+=("$conf") ;; esac
  done
  if ((${#blockers[@]})); then
    local dhint=''
    if [[ " ${blockers[*]} " == *docker-proxy* ]]; then
      dhint=$'\n\n'"{yellow}Порты держит контейнер Docker{/} — скорее всего, Caddy или Nginx в Docker.
Останови только его, остальные контейнеры не трогай:
  {accent}docker compose stop caddy{/}   (в каталоге его docker-compose.yml)
Его Caddyfile после миграции переносится в «Сайты и сервисы → Перенести сайты из Caddyfile»:
сайты других доменов и сервис на корне домена продолжат работать через этот Caddy."
    fi
    tui_msg 'Порты 80/443 заняты' "{red}✗ Порты 80/443 занимает: ${blockers[*]}.{/}

Прокси должен слушать 80 и 443. Останови или удали эту программу и запусти миграцию снова.$dhint"
    return 1
  fi
  local has_c=0 has_n=0 def=caddy lc ln
  command -v caddy >/dev/null 2>&1 && has_c=1
  command -v nginx >/dev/null 2>&1 && has_n=1
  ((has_n && !has_c)) && def=nginx
  [[ "$o443" == *nginx* ]] && def=nginx
  [[ "$o443" == *caddy* ]] && def=caddy
  lc='Установить Caddy — автоматический HTTPS'; ((has_c)) && lc='Взять под управление установленный Caddy'
  ln='Установить Nginx + Certbot'; ((has_n)) && ln='Взять под управление установленный Nginx (+ Certbot)'
  local -a pitems=(caddy "$lc" "$([[ $def == caddy ]] && echo ON || echo OFF)"
                   nginx "$ln" "$([[ $def == nginx ]] && echo ON || echo OFF)")
  proxy_choice=$(tui_radiolist 'Прокси' "Веб-сервер на 443: сайт-заглушка, HTTPS, панель и подписки по секретным путям.
{dim}Если Caddy уже обслуживает другие сайты, его прежний Caddyfile сохранится в копию —
перенеси их вручную. В Nginx свои сайты остаются, отключаются только блоки с этим доменом.{/}" \
                 "${pitems[@]}") || return 1
  PROXY=$proxy_choice
  # --- 5. inbounds on 80/443
  mapfile -t conflicts < <(migrate_conflicts)
  if ((${#conflicts[@]})); then
    tui_yesno 'Порт 443 занят inbound-ом' "Эти inbound-ы слушают TCP 80/443, а эти порты нужны прокси:
$(for c in "${conflicts[@]}"; do printf '  id %s — порт %s\n' "${c% *}" "${c#* }"; done)

Скрипт перенесёт их на свободные порты (8443, 2053…). Клиенты получат новый порт,
когда обновят подписку; ссылки, добавленные вручную, придётся обновить." \
      'Перенести' 'Отмена' yes || return 1
  fi
  # --- 6. confirm
  local panel_path sub_path note_paths=''
  panel_path=$(strip_slashes "${XS[webBasePath]}"); sub_path=$(strip_slashes "${XS[subPath]}")
  [[ -z "$panel_path" ]] && note_paths=$'\n'"{yellow}Панель была в корне (/) — ей будет выдан секретный путь.{/}"
  TUI_LOGO=1 tui_yesno 'Подтверждение миграции' "Домен:       $DOMAIN
3x-ui:       $([[ $mode == takeover ]] && echo "оставить $ver" || echo 'переустановить последнюю версию')
Прокси:      $PROXY ($(command -v "$PROXY" >/dev/null 2>&1 && echo 'взять под управление' || echo 'установить'))
Панель:      https://$DOMAIN/${panel_path:-<новый путь>}/
Подписки:    https://$DOMAIN/${sub_path:-sub}/…$( migrate_sub_redirect && printf '\n             старые %s://%s:%s/… → перенаправление' "${XS[subCertFile]:+https}${XS[subCertFile]:-http}" "$DOMAIN" "${XS[subPort]}")
Вход:        $([[ $pass_mode == keep ]] && echo "прежний ($PANEL_USER)" || echo 'новые логин и пароль')$note_paths

Перед изменениями база будет сохранена в /opt/3x-ui_reverse/backups/." 'Мигрировать' 'Отмена' yes || return 1
  migrate_run "$mode" "${conflicts[@]}"
}
# Old public subscription port that needs a redirect to 443. Not needed when
# clients already use the subscription on 443 (an external reverse proxy, e.g.
# Caddy in Docker): subURI is https://domain/… without a port.
migrate_sub_redirect(){
  [[ "${XS[subEnable]:-}" == true && "${XS[subPort]:-}" =~ ^[0-9]+$ && "${XS[subPort]}" != 443 && "${XS[subPort]}" != 80 ]] || return 1
  ! [[ "${XS[subURI]:-}" =~ ^https://[^/:]+(:443)?(/|$) ]]
}
migrate_check_password(){
  local scheme=http host=127.0.0.1 url
  [[ -n "${XS[webCertFile]:-}" ]] && scheme=https
  case "${XS[webListen]:-}" in ''|0.0.0.0|::|'[::]') ;; *:*) host="[${XS[webListen]}]" ;; *) host=${XS[webListen]} ;; esac
  url="$scheme://$host:${XS[webPort]}${XS[webBasePath]%/}"
  printf '%s\n' "$1" | helper panel-login "$url" "$PANEL_USER" >/dev/null 2>>"$LOG"
}

migrate_run(){
  local mode=$1; shift
  local -a conflicts=("$@")
  local backup c id newp ids crt key cert_paths installer="$BASE/3x-ui-upstream-install.sh" old_port
  install -d -m 755 "$BASE"
  preinstall_commit
  PROXY_INSTALLED=1; PANEL_INSTALLED=1; TLS_MODE=proxy
  PANEL_PATH=$(strip_slashes "${XS[webBasePath]}"); [[ -n "$PANEL_PATH" ]] || PANEL_PATH="panel$(rand 18)"
  SUB_PATH=$(strip_slashes "${XS[subPath]}"); [[ -n "$SUB_PATH" ]] || SUB_PATH="sub$(rand 19)"
  JSON_PATH=$(strip_slashes "${XS[subJsonPath]}"); [[ -n "$JSON_PATH" ]] || JSON_PATH="json$(rand 19)"
  CLASH_PATH=$(strip_slashes "${XS[subClashPath]}"); [[ -n "$CLASH_PATH" ]] || CLASH_PATH="clash$(rand 19)"
  # Panel keeps its port (now local only) unless it is 80/443; subscriptions get a
  # new local port, the old public one becomes the redirect.
  PANEL_PORT=${XS[webPort]}
  if [[ "$PANEL_PORT" == 80 || "$PANEL_PORT" == 443 ]] || ! valid_port "$PANEL_PORT"; then
    PANEL_PORT=''; PANEL_PORT=$(newport) || die 'Не удалось подобрать порт панели.'
  fi
  old_port=${XS[subPort]}
  SUB_PORT=''; SUB_PORT=$(newport) || die 'Не удалось подобрать порт подписок.'
  OLD_SUB_PORT=''; OLD_SUB_SCHEME=''
  if migrate_sub_redirect && [[ "$old_port" != "$PANEL_PORT" ]]; then
    OLD_SUB_PORT=$old_port
    OLD_SUB_SCHEME=http; [[ -n "${XS[subCertFile]:-}" ]] && OLD_SUB_SCHEME=https
  fi
  local -a stages=('Сохраняем базу 3x-ui')
  [[ "$mode" == reinstall ]] && stages+=('Переустанавливаем 3x-ui (официальный установщик)')
  stages+=('Переводим панель и подписки на 127.0.0.1')
  ((${#conflicts[@]})) && stages+=('Освобождаем порты 80/443')
  stages+=("Настраиваем $PROXY и HTTPS" 'Переводим TLS-inbound-ы на сертификат домена'
           'Записываем параметры и PDF' 'Проверяем доступность HTTPS')
  ui_start "Миграция • $DOMAIN • $PROXY" "${stages[@]}"
  msg 'Сохраняем базу 3x-ui'
  run systemctl stop x-ui || die 'Не удалось остановить x-ui.'
  backup="$BASE/backups/before-migration-$(date +%Y%m%d-%H%M%S).db"
  MIGRATE_BACKUP=''
  backup_db "$backup" || die 'Не удалось сохранить базу 3x-ui — миграция остановлена, ничего не изменено.'
  MIGRATE_BACKUP=$backup          # from now on any failure restores the old panel
  step 8 'Копия базы сохранена'
  if [[ "$mode" == reinstall ]]; then
    msg 'Переустанавливаем 3x-ui (официальный установщик)'
    run curl -fsSL --retry 3 -o "$installer" "$XUI_INSTALL_URL" || migrate_fail "$backup" 'Не удалось скачать установщик 3x-ui.'
    chmod 700 "$installer"
    prepare_bootstrap_guard
    XUI_NONINTERACTIVE=1 XUI_SSL_MODE=none XUI_DB_TYPE=sqlite XUI_PANEL_PORT="$PANEL_PORT" \
      XUI_WEB_BASE_PATH="$PANEL_PATH" XUI_USERNAME="$PANEL_USER" XUI_PASSWORD="$PANEL_PASS" \
      bash "$installer" >>"$LOG" 2>&1 || migrate_fail "$backup" 'Официальный установщик 3x-ui завершился с ошибкой.'
    run systemctl stop x-ui || :
    restore_db "$backup" || migrate_fail "$backup" 'Не удалось вернуть базу после переустановки.'
    step 30 '3x-ui обновлена, база восстановлена'
  fi
  msg 'Переводим панель и подписки на 127.0.0.1'
  apply_panel || migrate_fail "$backup" 'Не удалось изменить адрес панели.'
  set_subscriptions >>"$LOG" 2>&1 || migrate_fail "$backup" 'Не удалось изменить настройки подписок.'
  run "$CLI" setting -username "$PANEL_USER" -password "$PANEL_PASS" || migrate_fail "$backup" 'Не удалось записать логин и пароль.'
  [[ "$mode" == reinstall ]] && finalize_bootstrap_guard
  run systemctl start x-ui || migrate_fail "$backup" 'x-ui не запустилась после изменения настроек.'
  wait_local_stack || migrate_fail "$backup" 'Панель или подписки не поднялись на 127.0.0.1.'
  write_helper; write_helper_env
  ensure_api_token || migrate_fail "$backup" 'Не удалось получить API-токен 3x-ui.'
  step 45 'Панель и подписки на 127.0.0.1'
  if ((${#conflicts[@]})); then
    msg 'Освобождаем порты 80/443'
    local moved
    for c in "${conflicts[@]}"; do
      id=${c% *}; moved=0
      # The helper refuses ports used by other inbounds (also stopped ones): try a few.
      for _ in 1 2 3 4 5 6; do
        newp=$(inbound_port) || break
        TAKEN_PORTS="${TAKEN_PORTS:-} $newp"
        if helper set-port "$id" "$newp" >>"$LOG" 2>&1; then moved=1; break; fi
      done
      ((moved)) || migrate_fail "$backup" "Не удалось перенести inbound $id с порта ${c#* }."
      note "Inbound $id перенесён с порта ${c#* } на $newp."
    done
    sleep 2
  fi
  msg "Настраиваем $PROXY и HTTPS"
  proxy_install_pkgs || migrate_fail "$backup" "Не удалось установить $PROXY."
  migrate_nginx_conflicts
  site_html
  firewall_web_ports
  proxy_configure
  step 75 'Прокси и HTTPS готовы'
  msg 'Переводим TLS-inbound-ы на сертификат домена'
  ids=$(helper tls-inbounds-for "$DOMAIN" "$(certdir)" 2>>"$LOG" || :)
  if [[ -n "$ids" ]] && cert_paths=$(wait_domain_cert); then
    crt=$(sed -n 1p <<< "$cert_paths"); key=$(sed -n 2p <<< "$cert_paths")
    for id in $ids; do
      helper set-tls "$id" "$crt" "$key" "$DOMAIN" >>"$LOG" 2>&1 &&
        note "Inbound $id теперь использует сертификат прокси (продлевается автоматически)." || :
    done
  fi
  step 85 'Inbound-ы проверены'
  msg 'Записываем параметры и PDF'
  save_state; write_info
  pdf_install_deps >/dev/null 2>&1 || :
  write_pdf || :
  helper enable-access-log >>"$LOG" 2>&1 || :
  setup_activity_timer || :
  install_self || warn "Не удалось установить команду $SELF."
  step 95 'Параметры записаны'
  msg 'Проверяем доступность HTTPS'
  if verify_remote; then step 100 'HTTPS работает'
  else ui_stop failed; warn 'HTTPS-проверка по localhost не прошла. Проверь DNS, TLS и журнал прокси.'; fi
  ui_stop
  note "Копия прежней базы: $backup"
  [[ -n "$OLD_SUB_PORT" ]] &&
    note "Старые ссылки подписки ${OLD_SUB_SCHEME}://$DOMAIN:$OLD_SUB_PORT/… перенаправляются на https://$DOMAIN/…"
  MIGRATE_BACKUP=''
  if [[ "$PROXY" == caddy ]] && helper web-caddyfiles 2>>"$LOG" | grep -q .; then
    note "{yellow}Найден Caddyfile от Caddy в Docker.{/} Его сайты (другие домены и сервис на корне $DOMAIN) переносятся в «Сайты и сервисы → Перенести сайты из Caddyfile»."
  fi
  tui_show 'Миграция завершена' install_summary
  flush_notes 'Обрати внимание'
  MIGRATING=0
  return 0
}
# After a failed step: put the old database (and proxy config) back and start
# the panel as it was. Called by migrate_fail and, for any other fatal error
# during a migration, from die().
MIGRATE_BACKUP=''
migrate_restore(){
  local backup=${MIGRATE_BACKUP:-} f
  [[ -f "$backup" ]] || return 1
  MIGRATE_BACKUP=''
  run systemctl stop x-ui || :
  restore_db "$backup" || :
  xui_env_restore
  rm -f /etc/systemd/system/x-ui.service.d/20-reverse-localhost.conf
  run systemctl daemon-reload || :
  if [[ "$PROXY" == caddy && -f "$BASE/Caddyfile.before-migration" ]]; then
    rm -f /etc/caddy/Caddyfile && cp -a "$BASE/Caddyfile.before-migration" /etc/caddy/Caddyfile
    run systemctl restart caddy || :
  elif [[ "$PROXY" == nginx ]]; then
    rm -f /etc/nginx/sites-enabled/3x-ui_reverse.conf
    for f in /etc/nginx/conf.d/*.disabled-by-3x-ui_reverse; do [[ -e "$f" ]] && mv -f -- "$f" "${f%.disabled-by-3x-ui_reverse}"; done
    run systemctl reload nginx || :
  fi
  run systemctl start x-ui || :
  # Keep the log and the copy of the database, but out of the way of a new attempt.
  local keep
  keep="$BASE.failed-$(date +%Y%m%d-%H%M%S)"
  if mv -f -- "$BASE" "$keep" 2>/dev/null; then
    LOG=$keep/install.log; MIGRATE_KEPT=$keep
  fi
  return 0
}
MIGRATE_KEPT=''
migrate_fail(){
  local reason=$2
  if migrate_restore; then
    reason+=$'\n\n'"Прежняя база 3x-ui восстановлена, панель запущена в старом виде."
    [[ -n "$MIGRATE_KEPT" ]] && reason+=" Журнал и копия базы: $MIGRATE_KEPT"
    NOTES=()
  fi
  die "$reason"
}
# Nginx server blocks of other files with the same server_name would win over ours.
migrate_nginx_conflicts(){
  [[ "$PROXY" == nginx ]] || return 0
  local f
  for f in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
    [[ -e "$f" ]] || continue
    [[ "$(readlink -f "$f")" == /etc/nginx/sites-available/3x-ui_reverse.conf ]] && continue
    grep -Eq "server_name[^;]*[[:space:]]$DOMAIN([[:space:];]|$)" "$f" 2>/dev/null || continue
    if [[ -L "$f" ]]; then rm -f -- "$f"; else mv -f -- "$f" "$f.disabled-by-3x-ui_reverse"; fi
    note "Nginx: отключён $f (тот же домен $DOMAIN)."
  done
}
firewall_web_ports(){
  local p
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    for p in 80 443 ${OLD_SUB_PORT:-}; do run ufw allow "$p/tcp" || :; done
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for p in 80 443 ${OLD_SUB_PORT:-}; do run firewall-cmd --permanent --add-port="$p/tcp" || :; done
    run firewall-cmd --reload || :
  fi
  return 0
}

# ---- 3x-ui on PostgreSQL -> SQLite. The script backs up and restores SQLite only,
# so a PostgreSQL panel is first switched to a SQLite copy that 3x-ui itself builds
# from the live data (/panel/api/server/getMigration). PostgreSQL is not touched:
# undoing means putting XUI_DB_TYPE back.
PG_ENV_BACKUPS=()
pg_panel_url(){
  local show port path listen host scheme=http
  show=$("$CLI" setting -show 2>&1) || :
  port=$(sed -n 's/^port: *\([0-9]\+\).*/\1/p' <<< "$show" | head -n1)
  path=$(sed -n 's/^webBasePath: *//p' <<< "$show" | head -n1)
  listen=$("$CLI" setting -getListen 2>&1 | sed -n 's/^listenIP: *//p' | head -n1)
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  case "$listen" in ''|0.0.0.0|::|'[::]'|127.0.0.1) host=127.0.0.1 ;; *:*) host="[$listen]" ;; *) host=$listen ;; esac
  "$CLI" setting -getCert 2>&1 | grep -Eq 'cert(File)?: *[^ ]+' && scheme=https
  path=/$(strip_slashes "$path"); [[ "$path" == / ]] || path+=/
  printf '%s://%s:%s%s' "$scheme" "$host" "$port" "$path"
}
pg_env_switch(){        # comment out XUI_DB_TYPE / XUI_DB_DSN (backups kept for undo)
  local f copy
  PG_ENV_BACKUPS=()
  for f in $(xui_env_paths | sort -u); do
    [[ -f "$f" ]] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?XUI_DB_(TYPE|DSN)=' "$f" || continue
    copy="$f.before-sqlite-$(date +%Y%m%d-%H%M%S)"
    cp -a "$f" "$copy" || return 1
    PG_ENV_BACKUPS+=("$f|$copy")
    sed -i -E 's/^([[:space:]]*(export[[:space:]]+)?XUI_DB_(TYPE|DSN)=)/# 3x-ui_reverse: SQLite now, PostgreSQL kept as a backup: \1/' "$f"
  done
  ((${#PG_ENV_BACKUPS[@]}))
}
pg_env_undo(){
  local e
  for e in "${PG_ENV_BACKUPS[@]}"; do cp -a "${e#*|}" "${e%%|*}" 2>>"$LOG" || :; done
}
pg_to_sqlite(){
  local url token tmp code n_api n_db stale='' ts
  ts=$(date +%Y%m%d-%H%M%S)
  url=$(pg_panel_url) || { PG_ERR='Не удалось узнать порт панели (x-ui setting -show).'; return 1; }
  printf 'pg->sqlite: panel %s\n' "$url" >> "$LOG"
  token=$("$CLI" setting -getApiToken -tokenName 3x-ui_reverse-pg2sqlite -tokenScope admin 2>>"$LOG" | sed -n 's/^apiToken: *//p' | tail -n1)
  [[ -n "$token" ]] || { PG_ERR='3x-ui не выдала API-токен (x-ui setting -getApiToken).'; return 1; }
  n_api=$(curl -fsSk --max-time 20 -H "Authorization: Bearer $token" "${url}panel/api/inbounds/list" 2>>"$LOG" |
          python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("obj") or []))' 2>>"$LOG") ||
    { PG_ERR="Панель не отвечает на $url — проверь, что x-ui запущена."; return 1; }
  install -d -m 700 "$(dirname "$DB")"
  tmp="$(dirname "$DB")/x-ui.db.from-postgres-$ts"
  code=$(curl -sSk --max-time 300 -H "Authorization: Bearer $token" -o "$tmp" -w '%{http_code}' \
         "${url}panel/api/server/getMigration" 2>>"$LOG") || code=000
  if [[ "$code" != 200 ]]; then rm -f "$tmp"; PG_ERR="3x-ui не отдала копию базы (HTTP $code)."; return 1; fi
  chmod 600 "$tmp"
  n_db=$(python3 - "$tmp" <<'PYCHK' 2>>"$LOG"
import sqlite3, sys
con = sqlite3.connect('file:%s?mode=ro' % sys.argv[1], uri=True)
assert con.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
con.execute('SELECT count(*) FROM settings').fetchone()
print(con.execute('SELECT count(*) FROM inbounds').fetchone()[0])
PYCHK
  ) || { rm -f "$tmp"; PG_ERR='Полученная копия базы повреждена.'; return 1; }
  if [[ "$n_db" != "$n_api" ]]; then
    rm -f "$tmp"; PG_ERR="В копии $n_db inbound-ов, а в панели $n_api."; return 1
  fi
  # Switch: the old SQLite file (unused while on PostgreSQL) is kept aside.
  run systemctl stop x-ui || { rm -f "$tmp"; PG_ERR='Не удалось остановить x-ui.'; return 1; }
  if [[ -f "$DB" ]]; then stale="$DB.unused-$ts"; mv -f "$DB" "$stale"; fi
  rm -f "$DB-wal" "$DB-shm"
  mv -f "$tmp" "$DB"
  if ! pg_env_switch; then
    PG_ERR='XUI_DB_TYPE задан не в /etc/default/x-ui — переключи базу вручную.'
    pg_sqlite_undo "$stale"; return 1
  fi
  python3 - "$DB" <<'PYTOK' >>"$LOG" 2>&1 || :
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
try:
    con.execute("DELETE FROM api_tokens WHERE name = '3x-ui_reverse-pg2sqlite'")
    con.commit()
except sqlite3.Error as e:
    print('api_tokens:', e)
PYTOK
  run systemctl start x-ui || :
  local i ok=0
  for ((i=0; i<20; i++)); do
    sleep 1
    curl -sk -o /dev/null --max-time 5 "$url" 2>>"$LOG" && { ok=1; break; }
  done
  if ((!ok)) || xui_on_postgres; then
    PG_ERR='После перехода на SQLite панель не запустилась.'
    pg_sqlite_undo "$stale"; return 1
  fi
  PG_STALE=$stale
  return 0
}
pg_sqlite_undo(){
  local stale=$1
  run systemctl stop x-ui || :
  pg_env_undo
  if [[ -f "$DB" ]]; then mv -f "$DB" "$DB.failed-$(date +%Y%m%d-%H%M%S)"; fi
  [[ -n "$stale" && -f "$stale" ]] && mv -f "$stale" "$DB"
  run systemctl start x-ui || :
}
PG_ERR='' PG_STALE=''
pg_to_sqlite_flow(){
  TUI_LOGO=1 tui_yesno 'Миграция 3x-ui' "{yellow}Эта 3x-ui хранит данные в PostgreSQL{/} (XUI_DB_TYPE=postgres в /etc/default/x-ui).

Скрипт работает с базой SQLite: перед любыми изменениями делает её копию и при ошибке
возвращает как было. Поэтому сначала панель переводится на SQLite:
  1. 3x-ui сама собирает SQLite-копию из текущих данных (как «Скачать миграцию» в панели);
  2. копия проверяется: целостность и число inbound-ов;
  3. в /etc/default/x-ui строки XUI_DB_TYPE/XUI_DB_DSN закомментируются, x-ui перезапустится.

{dim}Данные в PostgreSQL не трогаются и остаются резервной копией. Подключения клиентов
прервутся на несколько секунд. При ошибке всё вернётся на PostgreSQL.{/}" 'Перевести на SQLite' 'Отмена' yes || return 1
  ui_start 'PostgreSQL → SQLite' 'Получаем копию базы от 3x-ui' 'Переключаем x-ui на SQLite'
  msg 'Получаем копию базы от 3x-ui'; step 30 'Получаем копию базы от 3x-ui'
  if ! pg_to_sqlite; then
    ui_stop failed
    tui_msg 'PostgreSQL → SQLite' "{red}✗ $PG_ERR{/}

x-ui работает на PostgreSQL, как раньше. Подробности: $LOG"
    return 1
  fi
  step 100 'x-ui работает на SQLite'; ui_stop
  note "✓ 3x-ui переведена с PostgreSQL на SQLite ($DB). Данные в PostgreSQL не менялись — это резервная копия; базу можно отключить позже."
  [[ -n "$PG_STALE" ]] && note "{dim}Старый неиспользуемый файл SQLite: $PG_STALE{/}"
  return 0
}

# ---- Login and password changed in the 3x-ui web panel: the script keeps a copy
# in its state (the panel stores only a hash). The login is read from the
# database; the password is checked by logging in on 127.0.0.1. A password the
# panel rejects is forgotten (shown as "changed in the panel") and is not tried
# again, so 3x-ui does not log failed logins every time the manager starts.
panel_local_url(){
  local scheme=http
  [[ "${TLS_MODE:-proxy}" == direct ]] && scheme=https
  printf '%s://127.0.0.1:%s/%s' "$scheme" "$PANEL_PORT" "$PANEL_PATH"
}
panel_login_check(){       # USER PASS -> 0 accepted, 1 rejected, 3 panel did not answer
  local rc=0
  printf '%s\n' "$2" | helper panel-login "$(panel_local_url)" "$1" >/dev/null 2>>"$LOG" || rc=$?
  return $rc
}
panel_creds_sync(){
  [[ "${PANEL_INSTALLED:-1}" == 1 && -f "$DB" && -d "$BASE" ]] || return 0
  local out user tfa rc=0 changed=0
  out=$(helper panel-user "$DB" 2>>"$LOG") || return 0
  user=$(sed -n 's/^user=//p' <<< "$out"); tfa=$(sed -n 's/^2fa=//p' <<< "$out")
  [[ -n "$user" ]] || return 0
  if [[ "$user" != "$PANEL_USER" ]]; then
    note "Логин панели изменён в 3x-ui: теперь «$user»."
    PANEL_USER=$user; changed=1
  fi
  if [[ -n "$PANEL_PASS" && "$tfa" != 1 ]]; then
    panel_login_check "$PANEL_USER" "$PANEL_PASS" || rc=$?
    if ((rc == 1)); then
      PANEL_PASS=''; changed=1
      note "{yellow}Пароль панели изменён в 3x-ui — скрипт его не знает.{/} Чтобы он снова показывался в параметрах и PDF: «Настройки панели → Сохранить пароль из панели»."
    fi
  fi
  if ((changed)); then
    save_state; write_info 2>>"$LOG" || :
    write_pdf quiet >/dev/null 2>&1 || :
  fi
  return 0
}
# Settings: remember the password set in the web panel (checked before saving).
panel_creds_remember(){
  local v rc
  while :; do
    v=$(tui_input 'Пароль из панели' "Пароль, который сейчас задан в 3x-ui для «$PANEL_USER».
{dim}Скрипт проверит его входом в панель на 127.0.0.1 и сохранит в параметрах (chmod 600).{/}" '') || return 0
    [[ -n "$v" ]] || return 0
    rc=0; panel_login_check "$PANEL_USER" "$v" || rc=$?
    case $rc in
      0) PANEL_PASS=$v; save_state; write_info 2>>"$LOG" || :; write_pdf quiet >/dev/null 2>&1 || :
         note "{green}✓ Пароль сохранён.{/}"; return 0 ;;
      1) tui_yesno 'Пароль не подошёл' "Панель не приняла этот пароль для «$PANEL_USER»
(или включена двухфакторная защита)." 'Ввести снова' 'Отмена' yes || return 0 ;;
      *) tui_msg 'Пароль из панели' '{red}Панель не ответила.{/} Проверь, что x-ui запущена.'; return 0 ;;
    esac
  done
}

# ---- Sites and services behind Caddy: the domain root and other domains.
# Files in $(web_dir) belong to the user: the script imports them and never
# rewrites them when it regenerates its own Caddyfile.
WEB_ERR=''
web_snapshot(){
  local wd snap; wd=$(web_dir)
  install -d -m 755 "$wd" "$wd/sites" "$BASE/backups"
  snap="$BASE/backups/web-$(date +%Y%m%d-%H%M%S-%N).tar"
  local -a what=(caddy Caddyfile)
  [[ -f "$BASE/.Caddyfile.sha256" ]] && what+=(.Caddyfile.sha256)
  tar -C "$BASE" -cf "$snap" "${what[@]}" 2>>"$LOG" || :
  # keep the last 10 snapshots
  find "$BASE/backups" -maxdepth 1 -name 'web-*.tar' -printf '%T@ %p\n' 2>/dev/null | sort -rn | tail -n +11 | cut -d' ' -f2- | xargs -r rm -f --
  printf '%s' "$snap"
}
web_restore(){
  local snap=$1
  [[ -f "$snap" ]] || return 0
  rm -rf "$(web_dir)"
  tar -C "$BASE" -xf "$snap" 2>>"$LOG" || :
  reload_proxy >/dev/null 2>&1 || :
}
# Validate the Caddyfile; a broken file of the user's (caddy/sites/*.caddy or
# root.caddy) is switched off (renamed *.disabled) so the panel keeps working.
WEB_VALIDATE_ERR='' WEB_DISABLED=''
# "caddy validate" runs as root and creates the access logs of the sites it checks;
# the caddy service user could not open those root-owned files and would fail to start.
caddy_check(){
  local out rc=0
  out=$(caddy validate --config "$1" --adapter caddyfile 2>&1) || rc=$?
  caddy_fix_logs
  printf '%s\n' "$out"
  return $rc
}
caddy_fix_logs(){
  id caddy >/dev/null 2>&1 || return 0
  install -d -m 755 -o caddy -g caddy /var/log/caddy 2>>"$LOG" || :
  chown -R caddy:caddy /var/log/caddy 2>>"$LOG" || :
  # validate (as root) may also create files in Caddy's storage
  [[ -n "${DOMAIN:-}" && -d "$(certdir)" ]] && chown -R caddy:caddy "$(certdir)" 2>>"$LOG"
  return 0
}
# Last error of the caddy service (why it did not start or reload).
caddy_last_error(){
  journalctl -u caddy -n 40 --no-pager 2>/dev/null | grep -o 'Error: .*\|"error":"[^"]*' | tail -n1 |
    sed 's/^"error":"//; s/\\"/"/g' | cut -c1-400
}
# E-mail for Let's Encrypt from an imported Caddyfile (global "email" option).
web_keep_email(){
  local e
  e=$(awk -F'\t' '$1=="email"{print $2; exit}' <<< "$1")
  [[ -n "$e" && ! -s "$(web_dir)/acme-email" ]] || return 0
  [[ "$e" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] || return 0
  printf '%s\n' "$e" > "$(web_dir)/acme-email"; chmod 644 "$(web_dir)/acme-email"
}
web_validate(){
  local out f wd tmp snip
  WEB_VALIDATE_ERR='' WEB_DISABLED=''
  out=$(caddy_check "$BASE/Caddyfile") && return 0
  printf 'caddy validate:\n%s\n' "$out" >> "$LOG"
  wd=$(web_dir)
  tmp=$(mktemp "$BASE/caddy-one.XXXXXXXX")
  snip=''; [[ -f "$wd/sites/00-snippets.caddy" ]] && snip="import $wd/sites/00-snippets.caddy"
  for f in "$wd"/sites/*.caddy "$wd/root.caddy"; do
    [[ -f "$f" ]] || continue
    if [[ "$f" == */root.caddy ]]; then
      printf '{\n    admin off\n}\n%s\nroot-check.invalid {\n    handle {\n        import %s\n    }\n}\n' "$snip" "$f" > "$tmp"
    elif [[ "$f" == */00-snippets.caddy ]]; then
      printf '{\n    admin off\n}\nimport %s\n' "$f" > "$tmp"
    else
      printf '{\n    admin off\n}\n%s\nimport %s\n' "$snip" "$f" > "$tmp"
    fi
    if ! caddy_check "$tmp" >/dev/null; then
      mv -f "$f" "$f.disabled"
      WEB_DISABLED+="${WEB_DISABLED:+, }${f##*/}"
    fi
  done
  rm -f "$tmp"
  if [[ -n "$WEB_DISABLED" ]]; then
    write_caddy_body "$BASE/Caddyfile"; caddy_mark
    if caddy_check "$BASE/Caddyfile" >/dev/null; then
      note "{yellow}⚠ В файлах ошибка, они отключены (переименованы в *.disabled): $WEB_DISABLED. Исправь и включи обратно — «Сайты и сервисы».{/}"
      return 0
    fi
  fi
  WEB_VALIDATE_ERR=$(grep -v '"level":"info"' <<< "$out" | tail -n 3 | cut -c1-500)
  return 1
}
# Panel through Caddy on this server: HTTP code (000 = no answer) and curl's reason.
# -k: this checks routing; a certificate still being issued is not a routing error.
WEB_PROBE_ERR=''
web_panel_probe(){
  local code err
  WEB_PROBE_ERR=''
  err=$(curl -sSk -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$DOMAIN:443:127.0.0.1" \
        "https://$DOMAIN/$PANEL_PATH/" 2>&1) || :
  code=${err: -3}; [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
  [[ "$code" == 000 ]] && WEB_PROBE_ERR=$(sed 's/^curl: ([0-9]*) //' <<< "${err%???}" | grep -v '^$' | tail -n1 | cut -c1-200)
  printf '%s' "$code"
}
# Regenerate, validate, reload and make sure the panel still answers through Caddy.
# If the panel did not answer through Caddy before the change either, the change is
# not the cause: it is applied and the existing problem is reported instead.
WEB_WARN=''
web_apply_now(){
  local code before='' before_err='' i
  WEB_ERR='' WEB_WARN=''
  if [[ "${PANEL_INSTALLED:-1}" == 1 ]]; then
    before=$(web_panel_probe); before_err=$WEB_PROBE_ERR
  fi
  # Imported sites may log to /var/log/caddy: make sure the service user can write there.
  id caddy >/dev/null 2>&1 && install -d -m 755 -o caddy -g caddy /var/log/caddy 2>>"$LOG"
  write_caddy
  if ! web_validate; then
    WEB_ERR=$WEB_VALIDATE_ERR
    return 1
  fi
  caddy_fix_logs
  if ! reload_proxy; then
    WEB_ERR="Caddy не перезагрузился."
    local cerr; cerr=$(caddy_last_error); [[ -n "$cerr" ]] && WEB_ERR+=$'\n'"Caddy: $cerr"
    return 1
  fi
  [[ "${PANEL_INSTALLED:-1}" == 1 ]] || return 0
  for ((i=0; i<10; i++)); do
    code=$(web_panel_probe)
    [[ "$code" == 200 ]] && return 0
    sleep 1
  done
  printf 'panel via caddy: before=%s (%s) after=%s (%s)\n' "$before" "$before_err" "$code" "$WEB_PROBE_ERR" >> "$LOG"
  if [[ "$before" != 200 ]]; then
    WEB_WARN="Панель через Caddy не отвечала и до изменения (HTTP $before${before_err:+: $before_err}). Проверь: systemctl status caddy, ss -ltnp | grep -E ':(80|443) ', journalctl -u caddy -n 50."
    return 0
  fi
  WEB_ERR="Панель через Caddy перестала отвечать (HTTP $code${WEB_PROBE_ERR:+: $WEB_PROBE_ERR})."
  local cerr; cerr=$(caddy_last_error); [[ -n "$cerr" ]] && WEB_ERR+=$'\n'"Caddy: $cerr"
  return 1
}
# web_change TITLE PHASE SNAPSHOT — apply with a gauge; roll back on failure.
web_change(){
  local title=$1 phase=$2 snap=$3
  ui_start "$title" "$phase"
  msg "$phase"; step 40 "$phase"
  if web_apply_now; then
    ui_stop
    [[ -n "$WEB_WARN" ]] && note "{yellow}⚠ $WEB_WARN{/}"
    return 0
  fi
  ui_stop failed
  web_restore "$snap"
  tui_msg "$title" "{red}✗ Конфигурация не применена, всё возвращено как было.{/}

$WEB_ERR"
  return 1
}
# Wait for Caddy to get a certificate for a new domain (any HTTP answer over TLS).
web_cert_ok(){
  local d=$1 i
  for ((i=0; i<20; i++)); do
    curl -s -o /dev/null --max-time 6 --resolve "$d:443:127.0.0.1" "https://$d/" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}
web_flag_text(){
  case "$1" in
    ok) printf '{green}✓ только 127.0.0.1{/}' ;;
    exposed) printf '{yellow}⚠ порт открыт наружу мимо Caddy{/}' ;;
    ip) printf '{yellow}⚠ не опубликован — адрес контейнера{/}' ;;
    unknown) printf '{red}✗ контейнер не найден{/}' ;;
    log) printf '{dim}журнал → /var/log/caddy{/}' ;;
    path) printf '{green}✓ каталог на сервере{/}' ;;
    nopath) printf '{yellow}⚠ каталога нет на сервере{/}' ;;
    *) printf '{red}✗ нет адреса{/}' ;;
  esac
}
web_exposed_help(){
  printf '%s' "Чтобы закрыть его снаружи, в docker-compose.yml контейнера укажи
  {accent}ports:{/}
  {accent}  - \"127.0.0.1:$1:$2\"{/}
и пересоздай контейнер: {accent}docker compose up -d{/}. Docker открывает опубликованные
порты в обход UFW — без 127.0.0.1 сервис виден по IP сервера напрямую."
}
# web_pick_upstream TITLE — sets WEB_UP (host:port) and WEB_SVC (name) or returns 1.
web_pick_upstream(){
  local title=$1 src out name image ports ch line port up flag
  local -a items=() pitems=()
  WEB_UP='' WEB_SVC=''
  out=$(helper web-docker 2>>"$LOG") || out=nodocker
  if [[ "$out" != nodocker ]] && grep -q '^C' <<< "$out"; then
    src=$(tui_radiolist "$title" 'Откуда сервис:' docker 'Docker-контейнер' ON addr 'Адрес и порт (host:port)' OFF) || return 1
  else
    src=addr
  fi
  if [[ "$src" == docker ]]; then
    while IFS=$'\t' read -r _ name image ports _; do
      items+=("$name" "$name"$'\t'"{dim}$image · $ports{/}")
    done < <(grep '^C' <<< "$out")
    name=$(tui_menu "$title" 'Запущенные контейнеры:' "${items[@]}") || return 1
    while IFS=$'\t' read -r _ _ port up flag; do
      pitems+=("$port|$up|$flag" "$port"$'\t'"{dim}$up{/}  $(web_flag_text "$flag")")
    done < <(awk -F'\t' -v n="$name" '$1=="P" && $2==n' <<< "$out")
    if ((${#pitems[@]} == 0)); then
      tui_msg "$title" "{red}✗ У $name нет портов, известных Docker.{/}
Опубликуй порт приложения только для сервера — ports: \"127.0.0.1:ПОРТ:ПОРТ\" — и попробуй снова."
      return 1
    elif ((${#pitems[@]} == 2)); then
      ch=${pitems[0]}
    else
      ch=$(tui_menu "$title" "Порт приложения в $name:" "${pitems[@]}") || return 1
    fi
    IFS='|' read -r port up flag <<< "$ch"
    [[ -n "$up" && "$flag" != none ]] || { tui_msg "$title" "{red}✗ Caddy не сможет достучаться до $name:$port.{/}"; return 1; }
    case "$flag" in
      exposed) tui_yesno "$title" "{yellow}⚠ Порт ${up##*:} контейнера $name открыт на всех адресах сервера.{/}

$(web_exposed_help "${up##*:}" "$port")

Подключить через Caddy сейчас (порт закроешь позже)?" 'Подключить' 'Отмена' || return 1 ;;
      ip) tui_yesno "$title" "{yellow}⚠ Порт $port контейнера $name не опубликован{/} — Caddy пойдёт на адрес контейнера $up.
После пересоздания контейнера адрес может смениться, и сайт перестанет открываться.
Надёжнее опубликовать порт только для сервера: ports: \"127.0.0.1:$port:$port\".

Подключить по адресу контейнера сейчас?" 'Подключить' 'Отмена' || return 1 ;;
    esac
    WEB_UP=$up; WEB_SVC=$name
    return 0
  fi
  line=$(tui_input "$title" "Адрес сервиса, например {accent}127.0.0.1:3000{/}
{dim}Можно http://…, https://… или имя:порт другого сервера.{/}" '127.0.0.1:') || return 1
  line=${line// /}
  [[ "$line" =~ ^(https?://)?[A-Za-z0-9._-]+:[0-9]{1,5}$ || "$line" =~ ^https?://[A-Za-z0-9._-]+$ ]] ||
    { tui_msg "$title" 'Нужен адрес вида host:port.'; return 1; }
  WEB_UP=$line; WEB_SVC=''
}
web_header(){
  local root='' svc='' up='' kind a b c d
  while IFS=$'\t' read -r kind a b c d; do
    [[ "$kind" == ROOT ]] && { root=$a; up=$b; svc=$c; }
  done < <(helper web-sites "$(web_dir)" 2>>"$LOG")
  if [[ "$root" == service ]]; then
    printf 'Корень %s:  {green}%s{/} {dim}→ %s{/}\n' "$DOMAIN" "$( [[ -z $svc || $svc == custom ]] && echo сервис || echo "$svc")" "$up"
  else
    printf 'Корень %s:  {dim}сайт-заглушка{/}\n' "$DOMAIN"
  fi
  printf '{dim}Панель /%s/ и подписки обслуживает скрипт. Свои файлы: %s{/}' "$PANEL_PATH" "$(web_dir)"
}
web_root_screen(){
  local ch snap cur
  cur=$(helper web-sites "$(web_dir)" 2>>"$LOG" | awk -F'\t' '$1=="ROOT"{print $2}')
  ch=$(tui_radiolist "Корень $DOMAIN" "Что открывается по адресу https://$DOMAIN/
{dim}Пути панели и подписок не меняются — их обслуживает скрипт.
Если сервис упадёт, вместо ошибки 502 откроется сайт-заглушка.{/}" \
       stub 'Сайт-заглушка' "$([[ $cur != service ]] && echo ON || echo OFF)" \
       service 'Сервис — Docker-контейнер или адрес' "$([[ $cur == service ]] && echo ON || echo OFF)") || return 0
  if [[ "$ch" == stub ]]; then
    [[ "$cur" == service ]] || return 0
    snap=$(web_snapshot)
    mv -f "$(web_dir)/root.caddy" "$(web_dir)/root.caddy.off"
    web_change "Корень $DOMAIN" 'Возвращаем сайт-заглушку' "$snap" &&
      note "✓ На $DOMAIN снова сайт-заглушка. Прежняя настройка сервиса: $(web_dir)/root.caddy.off"
    return 0
  fi
  web_pick_upstream "Корень $DOMAIN" || return 0
  snap=$(web_snapshot)
  printf '%s service=%s upstream=%s date=%s\n# Directives for the root of %s (inside handle { … }); edit freely.\nreverse_proxy %s\n' \
    "# 3x-ui_reverse:" "${WEB_SVC:-custom}" "$WEB_UP" "$(date +%F)" "$DOMAIN" "$WEB_UP" > "$(web_dir)/root.caddy"
  chmod 644 "$(web_dir)/root.caddy"
  web_change "Корень $DOMAIN" 'Подключаем сервис' "$snap" || return 0
  note "{green}✓ https://$DOMAIN/ → ${WEB_SVC:+$WEB_SVC · }$WEB_UP{/}"
  note "{dim}Если приложение спрашивает свой адрес (APP_URL, BASE_URL…), укажи https://$DOMAIN{/}"
}
web_dns_check(){
  local DOMAIN=$1
  DNS_GO_LABEL='Продолжить' dns_check_screen
}
web_add_screen(){
  local d snap f
  d=$(tui_input 'Подключить домен' "Домен для сервиса, например {accent}docs.example.com{/}
{dim}A-запись домена должна указывать на этот сервер — сертификат Caddy выпустит сам.{/}" '') || return 0
  d=${d,,}; d=${d%.}; d=${d#http://}; d=${d#https://}; d=${d%%/*}
  valid_domain "$d" || { tui_msg 'Подключить домен' 'Неверное имя домена.'; return 0; }
  [[ "$d" != "${DOMAIN,,}" ]] || { tui_msg 'Подключить домен' "Это основной домен — для него пункт «Корень $DOMAIN»."; return 0; }
  if helper web-hosts "$(web_dir)" 2>>"$LOG" | cut -f1 | grep -Fxq "$d"; then
    tui_msg 'Подключить домен' "$d уже подключён."; return 0
  fi
  web_dns_check "$d" || return 0
  web_pick_upstream "$d" || return 0
  snap=$(web_snapshot)
  f="$(web_dir)/sites/$d.caddy"
  cat > "$f" <<EOF
# 3x-ui_reverse: service=${WEB_SVC:-custom} upstream=$WEB_UP date=$(date +%F)
# Edit freely: the script does not rewrite this file.
$d {
    encode zstd gzip
    header -Server
    reverse_proxy $WEB_UP
}
EOF
  chmod 644 "$f"
  web_change "$d" 'Подключаем домен' "$snap" || return 0
  ui_start "$d" 'Выпуск сертификата'; msg 'Выпуск сертификата'; step 50 'Выпуск сертификата'
  if web_cert_ok "$d"; then
    ui_stop; note "{green}✓ https://$d/ → ${WEB_SVC:+$WEB_SVC · }$WEB_UP{/}"
  else
    ui_stop failed
    note "{yellow}⚠ $d подключён, но сертификат ещё не выпущен. Проверь A-запись домена; Caddy продолжит попытки сам (journalctl -u caddy).{/}"
  fi
}
web_import_screen(){
  local -a items=() mitems=()
  local f path out snap moved maps ch up flag old new line skipped
  while IFS=$'\t' read -r f line; do items+=("$f" "$f"$'\t'"{dim}$line{/}"); done < <(helper web-caddyfiles 2>>"$LOG")
  items+=(manual 'Указать путь к файлу')
  if ((${#items[@]} > 2)); then
    path=$(tui_menu 'Перенести сайты' 'Caddyfile, из которого взять сайты (найдены у Caddy в Docker):' "${items[@]}") || return 0
  else
    path=manual
  fi
  if [[ "$path" == manual ]]; then
    path=$(tui_input 'Перенести сайты' 'Полный путь к Caddyfile (например, /root/caddy/Caddyfile):' '') || return 0
  fi
  [[ -f "$path" ]] || { tui_msg 'Перенести сайты' "Файл не найден: $path"; return 0; }
  [[ "$(readlink -f "$path")" != "$(readlink -f "$BASE/Caddyfile")" ]] ||
    { tui_msg 'Перенести сайты' 'Это Caddyfile самого скрипта.'; return 0; }
  snap=$(web_snapshot)
  if ! out=$(helper caddy-split "$path" "$DOMAIN" "$(web_dir)/sites" --docker --source "$path" 2>&1); then
    web_restore "$snap"; tui_msg 'Перенести сайты' "{red}✗ ${out#Ошибка: }{/}"; return 0
  fi
  web_keep_email "$out"
  moved=$(awk -F'\t' '$1=="moved"{print "  • " $2 "  {dim}→ " $3 "{/}"}' <<< "$out")
  maps=''
  while IFS=$'\t' read -r _ old new flag; do
    maps+="  $old → $new  $(web_flag_text "$flag")"$'\n'
  done < <(grep '^map' <<< "$out")
  skipped=$(awk -F'\t' '$1=="skipped"{print "  • " $2}' <<< "$out")
  if [[ -n "$moved" ]]; then
    tui_msg 'Перенести сайты' "Перенесено в $(web_dir)/sites:
$moved${maps:+

Адреса контейнеров и пути внутри контейнера Caddy заменены на доступные на сервере:
$maps}${skipped:+
Пропущено:
$skipped}"
  fi
  # The main domain's block of the old file: offer its upstream for the root.
  while IFS=$'\t' read -r _ old new flag; do
    [[ "$new" == *":$PANEL_PORT" || "$new" == *":$SUB_PORT" ]] && continue
    mitems+=("$new|$flag" "$old"$'\t'"{dim}→ $new{/}  $(web_flag_text "$flag")")
  done < <(grep '^main' <<< "$out")
  if ((${#mitems[@]})); then
    ch=$(TUI_CANCEL='Не трогать корень' tui_menu "Корень $DOMAIN" "В файле у $DOMAIN был сервис. Поставить его на корень домена вместо сайта-заглушки?
{dim}Панель и подписки остаются под управлением скрипта — их блоки из файла не переносятся.{/}" "${mitems[@]}") || ch=''
    if [[ -n "$ch" ]]; then
      IFS='|' read -r up flag <<< "$ch"
      if [[ "$flag" == unknown ]]; then
        tui_msg "Корень $DOMAIN" "{red}✗ Контейнер для $up не найден среди запущенных.{/} Запусти его и выбери «Корень $DOMAIN» ещё раз."
      else
        printf '%s service=imported upstream=%s date=%s\nreverse_proxy %s\n' "# 3x-ui_reverse:" "$up" "$(date +%F)" "$up" > "$(web_dir)/root.caddy"
        chmod 644 "$(web_dir)/root.caddy"
      fi
    fi
  elif [[ -z "$moved" ]]; then
    tui_msg 'Перенести сайты' "В $path нет сайтов, которые можно перенести.${skipped:+

Пропущено:
$skipped}"
    return 0
  fi
  if web_change 'Перенести сайты' 'Применяем конфигурацию Caddy' "$snap"; then
    note '{green}✓ Готово. Сертификаты для новых доменов Caddy выпустит в течение минуты.{/}'
    grep -q $'\tunknown$' <<< "$out" &&
      note "{yellow}⚠ Для части адресов контейнер не найден — поправь их в файлах $(web_dir)/sites.{/}"
  fi
  return 0
}
web_site_screen(){
  local f=$1 ch snap path
  path="$(web_dir)/sites/$f"
  ch=$(tui_menu "$f" "$(helper web-sites "$(web_dir)" 2>>"$LOG" | awk -F'\t' -v f="$f" '$1=="SITE" && $2==f {print $3 "\n{dim}→ " $4 "{/}"}')
{dim}Файл: $path — его можно править, скрипт его не перезаписывает.
После правки: «Применить изменения файлов».{/}" \
       show 'Показать конфигурацию' del '{red}Отключить{/}') || return 0
  case "$ch" in
    show) tui_textfile "$f" "$path" ;;
    del)
      tui_yesno "$f" "Отключить $f? Файл переедет в $BASE/backups." 'Отключить' 'Отмена' || return 0
      snap=$(web_snapshot)
      mv -f "$path" "$BASE/backups/$f.$(date +%Y%m%d-%H%M%S)"
      web_change "$f" 'Применяем конфигурацию Caddy' "$snap" && note "○ $f отключён."
      ;;
  esac
}
menu_web(){
  if [[ "$PROXY" != caddy || "${PROXY_INSTALLED:-1}" != 1 ]]; then
    tui_msg 'Сайты и сервисы' 'Подключение своих сайтов и сервисов пока работает только с Caddy.'
    return 0
  fi
  install -d -m 755 "$(web_dir)" "$(web_dir)/sites"
  local ch kind f doms ups svc snap
  local -a sitems=()
  while :; do
    sitems=()
    while IFS=$'\t' read -r kind f doms ups svc; do
      [[ "$kind" == SITE ]] || continue
      sitems+=("f:$f" "$doms"$'\t'"{dim}${svc:+$svc · }$ups{/}")
    done < <(helper web-sites "$(web_dir)" 2>>"$LOG")
    ((${#sitems[@]})) && sitems=('#Другие домены' '' "${sitems[@]}")
    ch=$(tui_menu 'Сайты и сервисы' "$(web_header)" \
         root $'Корень '"$DOMAIN"$'\t{dim}сайт-заглушка или свой сервис{/}' \
         add $'Подключить домен\t{dim}Docker-контейнер или адрес на отдельном домене{/}' \
         import $'Перенести сайты из Caddyfile\t{dim}например, от Caddy в Docker{/}' \
         reload $'Применить изменения файлов\t{dim}после ручной правки в '"$(web_dir)"$'{/}' \
         "${sitems[@]}") || return 0
    case "$ch" in
      root) web_root_screen ;;
      add) web_add_screen ;;
      import) web_import_screen ;;
      reload) snap=$(web_snapshot); web_change 'Сайты и сервисы' 'Проверяем и применяем' "$snap" && note '{green}✓ Конфигурация применена.{/}' ;;
      f:*) web_site_screen "${ch#f:}" ;;
    esac
    flush_notes
  done
}
# CLI: sites [list] | sites root stub|ADDR | sites add DOMAIN ADDR | sites del FILE|DOMAIN | sites import FILE | sites apply
cli_sites(){
  local sub=${1:-list} snap f d out
  [[ "$PROXY" == caddy ]] || die 'Сайты и сервисы работают только с Caddy.'
  install -d -m 755 "$(web_dir)" "$(web_dir)/sites"
  case "$sub" in
    list) helper web-sites "$(web_dir)" | sed 's/\t/  /g' ;;
    root)
      [[ -n "${2:-}" ]] || die 'sites root stub|HOST:PORT'
      snap=$(web_snapshot)
      if [[ "$2" == stub ]]; then
        [[ ! -f "$(web_dir)/root.caddy" ]] || mv -f "$(web_dir)/root.caddy" "$(web_dir)/root.caddy.off"
      else
        printf '%s service=custom upstream=%s date=%s\nreverse_proxy %s\n' "# 3x-ui_reverse:" "$2" "$(date +%F)" "$2" > "$(web_dir)/root.caddy"
        chmod 644 "$(web_dir)/root.caddy"
      fi
      web_apply_now || { web_restore "$snap"; die "$WEB_ERR"; }; [[ -z "$WEB_WARN" ]] || warn "$WEB_WARN"
      printf 'Корень %s: %s\n' "$DOMAIN" "$2" ;;
    add)
      d=${2:-}; [[ -n "$d" && -n "${3:-}" ]] || die 'sites add DOMAIN HOST:PORT'
      valid_domain "$d" || die "Неверный домен: $d"
      snap=$(web_snapshot)
      printf '# 3x-ui_reverse: service=custom upstream=%s date=%s\n%s {\n    encode zstd gzip\n    header -Server\n    reverse_proxy %s\n}\n' \
        "$3" "$(date +%F)" "$d" "$3" > "$(web_dir)/sites/$d.caddy"
      chmod 644 "$(web_dir)/sites/$d.caddy"
      web_apply_now || { web_restore "$snap"; die "$WEB_ERR"; }; [[ -z "$WEB_WARN" ]] || warn "$WEB_WARN"
      printf 'Подключён %s → %s\n' "$d" "$3"
      web_cert_ok "$d" || warn "Сертификат для $d ещё не выпущен — проверь A-запись."
      ;;
    del)
      [[ -n "${2:-}" ]] || die 'sites del FILE|DOMAIN'
      f="$(web_dir)/sites/${2%.caddy}.caddy"
      [[ -f "$f" ]] || f="$(web_dir)/sites/$(helper web-hosts "$(web_dir)" | awk -F'\t' -v d="$2" '$1==d{print $2; exit}')"
      [[ -f "$f" ]] || die "Не найдено: $2"
      snap=$(web_snapshot)
      mv -f "$f" "$BASE/backups/${f##*/}.$(date +%Y%m%d-%H%M%S)"
      web_apply_now || { web_restore "$snap"; die "$WEB_ERR"; }; [[ -z "$WEB_WARN" ]] || warn "$WEB_WARN"
      printf 'Отключён %s\n' "${f##*/}" ;;
    import)
      [[ -f "${2:-}" ]] || die 'sites import /path/to/Caddyfile'
      snap=$(web_snapshot)
      out=$(helper caddy-split "$2" "$DOMAIN" "$(web_dir)/sites" --docker --source "$2") || { web_restore "$snap"; exit 1; }
      web_keep_email "$out"
      sed 's/\t/  /g' <<< "$out"
      web_apply_now || { web_restore "$snap"; die "$WEB_ERR"; }; [[ -z "$WEB_WARN" ]] || warn "$WEB_WARN"
      printf 'Готово. Сервис на корне домена: sites root HOST:PORT\n' ;;
    apply)
      snap=$(web_snapshot)
      web_apply_now || { web_restore "$snap"; die "$WEB_ERR"; }; [[ -z "$WEB_WARN" ]] || warn "$WEB_WARN"
      printf 'Конфигурация применена.\n' ;;
    *) die "Неизвестная подкоманда sites $sub" ;;
  esac
}

# ---- Change of the main domain (proxy mode: Caddy or Nginx in front of 3x-ui).
# Panel and subscription paths, ports and inbounds stay; the proxy, the panel's
# subscription address and the TLS inbounds on the domain certificate move to the
# new name. With Caddy the old name can stay as a 308 redirect, so subscription
# links already in the apps keep updating.
DOMAIN_ERR=''
domain_list_without(){ local d out=''; for d in $1; do [[ "$d" == "$2" ]] || out+="${out:+ }$d"; done; printf '%s' "$out"; }
domain_change_apply(){
  local old=$DOMAIN new=$1 keep=$2 stamp prev_state prev_proxy dbbackup olddir newdir prev_old ids id paths crt key
  DOMAIN_ERR=''
  stamp=$(date +%Y%m%d-%H%M%S-%N)
  prev_state="$BASE/backup-state.$stamp.env"; prev_proxy="$BASE/backup-config.$stamp.conf"
  dbbackup="$BASE/backups/domain-change-$stamp.db"
  cp -a "$STATE" "$prev_state"; cp -a "$(proxy_conf)" "$prev_proxy"
  prev_old=${OLD_DOMAINS:-}
  olddir=$(certdir); newdir="$BASE/sertificates/$new"
  # Caddy: copy the storage (ACME account, certificate of the old name for the redirect).
  if [[ ! -d "$newdir" ]]; then
    if [[ "$PROXY" == caddy && -d "$olddir" ]]; then cp -a "$olddir" "$newdir"; else install -d -m 750 "$newdir"; fi
  fi
  [[ "$PROXY" == caddy ]] && chown -R caddy:caddy "$newdir" 2>>"$LOG"
  run systemctl stop x-ui
  backup_db "$dbbackup" || { run systemctl start x-ui || :; DOMAIN_ERR='не удалось сохранить базу 3x-ui'; return 1; }
  DOMAIN=$new
  OLD_DOMAINS=$(domain_list_without "$prev_old" "$new")
  if ((keep)); then OLD_DOMAINS=$(domain_list_without "$OLD_DOMAINS" "$old"); OLD_DOMAINS+="${OLD_DOMAINS:+ }$old"; fi
  domain_change_undo(){
    run systemctl stop x-ui || :
    restore_db "$dbbackup" || :
    cp -a "$prev_proxy" "$(proxy_conf)"; [[ "$PROXY" == caddy ]] && caddy_mark
    cp -a "$prev_state" "$STATE"; load_state
    [[ "$PROXY" == nginx ]] && setup_renew_timer >>"$LOG" 2>&1
    reload_proxy || :
    run systemctl start x-ui || :
    write_helper_env
  }
  if [[ "$PROXY" == nginx ]]; then
    install -d -m 755 "$SITE/.well-known/acme-challenge"
    write_nginx bootstrap
    if ! validate_proxy || ! reload_proxy; then DOMAIN_ERR='Nginx не принял конфигурацию для нового домена'; domain_change_undo; return 1; fi
    if ! run certbot certonly --non-interactive --agree-tos --register-unsafely-without-email \
         --webroot -w "$SITE" -d "$new" --cert-name "$new" \
         --config-dir "$newdir" --work-dir "$BASE/certbot-work" --logs-dir "$BASE/certbot-logs"; then
      DOMAIN_ERR="Certbot не получил сертификат для $new — проверь A-запись и порт 80"; domain_change_undo; return 1
    fi
    write_nginx full
    if ! validate_proxy || ! reload_proxy; then DOMAIN_ERR='Nginx не принял HTTPS-конфигурацию'; domain_change_undo; return 1; fi
    setup_renew_timer >>"$LOG" 2>&1 || :
  else
    if ! update_proxy_safe; then DOMAIN_ERR='Caddy не принял конфигурацию с новым доменом'; domain_change_undo; return 1; fi
  fi
  if ! set_subscriptions >>"$LOG" 2>&1; then DOMAIN_ERR='не удалось записать адрес подписок в 3x-ui'; domain_change_undo; return 1; fi
  if ! run systemctl start x-ui || ! wait_local_stack; then DOMAIN_ERR='3x-ui не запустилась после смены адреса подписок'; domain_change_undo; return 1; fi
  save_state; write_helper_env; write_info
  # TLS inbounds on the domain certificate: new certificate and SNI.
  if wait_domain_cert >/dev/null && paths=$(domain_cert_paths); then
    crt=$(sed -n 1p <<< "$paths"); key=$(sed -n 2p <<< "$paths")
    ids=$(helper tls-inbounds-for "$old" "$(certdir)" 2>>"$LOG") || ids=''
    for id in $ids; do
      if helper set-tls "$id" "$crt" "$key" "$new" >>"$LOG" 2>&1; then DOMAIN_TLS_MOVED+=("$id")
      else DOMAIN_TLS_FAILED+=("$id"); fi
    done
  else
    DOMAIN_CERT_PENDING=1
  fi
  verify_remote || DOMAIN_REMOTE_FAIL=1
  write_pdf quiet >/dev/null 2>&1 || :
  return 0
}
DOMAIN_TLS_MOVED=() DOMAIN_TLS_FAILED=() DOMAIN_CERT_PENDING=0 DOMAIN_REMOTE_FAIL=0
domain_change_report(){
  local old=$1
  note "{green}✓ Основной домен: $DOMAIN.{/} Панель: https://$DOMAIN/$PANEL_PATH/"
  if [[ " ${OLD_DOMAINS:-} " == *" $old "* ]]; then
    note "Старый адрес https://$old/… перенаправляется на новый — подписки в приложениях продолжат обновляться и получат новый домен."
  else
    note "{yellow}Ссылки подписок со старым доменом $old больше не работают — пользователям нужно добавить подписку заново.{/}"
  fi
  ((${#DOMAIN_TLS_MOVED[@]})) && note "TLS-inbound-ы переведены на сертификат $DOMAIN: ${DOMAIN_TLS_MOVED[*]}."
  ((${#DOMAIN_TLS_FAILED[@]})) && note "{yellow}⚠ Не удалось перевести inbound-ы ${DOMAIN_TLS_FAILED[*]} — «Inbound-ы → Изменить inbound → TLS».{/}"
  ((DOMAIN_CERT_PENDING)) && note "{yellow}⚠ Сертификат для $DOMAIN ещё выпускается. TLS-inbound-ы (XHTTP TLS, Hysteria2) переведи позже: «Inbound-ы → Изменить inbound → TLS → сертификат домена».{/}"
  ((DOMAIN_REMOTE_FAIL)) && note "{yellow}⚠ https://$DOMAIN пока не отвечает — проверь A-запись; Caddy продолжит попытки получить сертификат сам.{/}"
  note "{dim}Если этот сервер подключён узлом к другой панели, поменяй его адрес там. Клиенты получат новый домен в ссылках при обновлении подписки.{/}"
}
domain_screen(){
  local ch new keep=0 head old
  if [[ "${PROXY_INSTALLED:-1}" != 1 || "${TLS_MODE:-proxy}" != proxy ]]; then
    tui_msg 'Основной домен' 'Смена домена работает, когда HTTPS обслуживает прокси (Caddy или Nginx), а не сама 3x-ui.'
    return 0
  fi
  head="Сейчас: {bold}$DOMAIN{/}"
  [[ -n "${OLD_DOMAINS:-}" ]] && head+=$'\n'"{dim}Перенаправляются на него: $OLD_DOMAINS{/}"
  local -a items=(change 'Сменить основной домен')
  [[ -n "${OLD_DOMAINS:-}" ]] && items+=(dropold 'Убрать перенаправления со старых доменов')
  ch=$(tui_menu 'Основной домен' "$head
{dim}На нём панель, подписки и сайт-заглушка (или сервис в корне). Пути, порты, inbound-ы
и пользователи не меняются.{/}" "${items[@]}") || return 0
  if [[ "$ch" == dropold ]]; then
    tui_yesno 'Перенаправления' "Убрать перенаправления с $OLD_DOMAINS?
{dim}Подписки, добавленные по старым адресам, перестанут обновляться.{/}" 'Убрать' 'Отмена' no || return 0
    old=$OLD_DOMAINS; OLD_DOMAINS=''
    if update_proxy_safe; then save_state; note "○ Перенаправления убраны: $old."
    else OLD_DOMAINS=$old; warn 'Конфигурация прокси не применилась, всё оставлено как было.'; fi
    return 0
  fi
  while :; do
    new=$(tui_input 'Новый основной домен' "Домен, A-запись которого уже указывает на этот сервер, например {accent}vpn.example.com{/}" '') || return 0
    new=${new,,}; new=${new%.}; new=${new#http://}; new=${new#https://}; new=${new%%/*}
    if ! valid_domain "$new"; then tui_msg 'Неверный домен' 'Нужно DNS-имя: не IP-адрес, не URL и без порта.'; continue; fi
    if [[ "$new" == "$DOMAIN" ]]; then tui_msg 'Основной домен' 'Это и есть текущий домен.'; return 0; fi
    if [[ "$PROXY" == caddy ]] && helper web-hosts "$(web_dir)" 2>>"$LOG" | cut -f1 | grep -Fxq "$new"; then
      tui_msg 'Основной домен' "$new уже подключён как отдельный сайт («Сайты и сервисы»). Сначала отключи его там."; return 0
    fi
    break
  done
  web_dns_check "$new" || return 0
  if [[ "$PROXY" == caddy ]]; then
    tui_yesno 'Старый домен' "Оставить {bold}$DOMAIN{/} перенаправлением на {bold}$new{/}?

{dim}Тогда подписки, добавленные по старому адресу, продолжат обновляться и сами
получат новый домен. Для этого A-запись $DOMAIN должна и дальше указывать на этот сервер.{/}" \
      'Оставить перенаправление' 'Не нужно' yes && keep=1
  fi
  tui_yesno 'Подтверждение' "Домен:   $DOMAIN → {bold}$new{/}
Панель:  https://$new/$PANEL_PATH/
Подписки: https://$new/$SUB_PATH/…
Старый:  $([[ $keep == 1 ]] && echo "перенаправление на $new" || echo 'перестанет работать')

{dim}Будут обновлены: конфигурация $PROXY и сертификат, адрес подписок в 3x-ui,
TLS-inbound-ы на сертификате домена, параметры и PDF. При ошибке всё вернётся.{/}" 'Сменить домен' 'Отмена' yes || return 0
  old=$DOMAIN
  DOMAIN_TLS_MOVED=() DOMAIN_TLS_FAILED=() DOMAIN_CERT_PENDING=0 DOMAIN_REMOTE_FAIL=0
  if with_progress 'Основной домен' "Переводим $old → $new" domain_change_apply "$new" "$keep"; then
    domain_change_report "$old"
  else
    tui_msg 'Основной домен' "{red}✗ Домен не изменён:{/} $DOMAIN_ERR

Всё возвращено как было: $DOMAIN."
  fi
}
# CLI: domain | domain set NEW [--keep-old] [--force] | domain drop-old
cli_domain(){
  local sub=${1:-show} new old keep=0 v
  case "$sub" in
    show|list) printf 'Основной домен: %s\n' "$DOMAIN"; [[ -n "${OLD_DOMAINS:-}" ]] && printf 'Перенаправления: %s\n' "$OLD_DOMAINS"; return 0 ;;
    drop-old)
      old=${OLD_DOMAINS:-}; [[ -n "$old" ]] || { printf 'Перенаправлений нет.\n'; return 0; }
      OLD_DOMAINS=''; update_proxy_safe || { OLD_DOMAINS=$old; die 'Конфигурация прокси не применилась.'; }
      save_state; printf 'Убраны перенаправления: %s\n' "$old" ;;
    set)
      [[ "${PROXY_INSTALLED:-1}" == 1 && "${TLS_MODE:-proxy}" == proxy ]] || die 'Смена домена работает только с прокси (Caddy или Nginx).'
      new=${2:-}; new=${new,,}; new=${new%.}
      valid_domain "$new" || die 'domain set НОВЫЙ.ДОМЕН [--keep-old] [--force]'
      [[ "$new" != "$DOMAIN" ]] || die "$new уже основной домен."
      [[ " $* " == *' --keep-old '* ]] && { [[ "$PROXY" == caddy ]] || die '--keep-old работает только с Caddy.'; keep=1; }
      if [[ " $* " != *' --force '* ]]; then
        v=$(helper dns-check "$new" 2>/dev/null | sed -n 's/^VERDICT \([a-z]*\).*/\1/p')
        [[ "$v" == ok ]] || die "A-запись $new не указывает на этот сервер (проверка DNS: ${v:-нет ответа}). Повтори с --force, если уверен."
      fi
      old=$DOMAIN
      DOMAIN_TLS_MOVED=() DOMAIN_TLS_FAILED=() DOMAIN_CERT_PENDING=0 DOMAIN_REMOTE_FAIL=0
      domain_change_apply "$new" "$keep" || die "Домен не изменён: $DOMAIN_ERR. Всё возвращено как было."
      domain_change_report "$old"
      printf '%s\n' "${NOTES[@]}" | sed 's/{[a-z/]*}//g'; NOTES=() ;;
    *) die "Неизвестная подкоманда domain $sub" ;;
  esac
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
MARK_RE = re.compile(r'\{(/|green|red|yellow|orange|accent|cyan|blue|magenta|dim|bold|white|track)\}')
ANSI_CODES = {'green': '32', 'red': '31', 'yellow': '33', 'orange': '38;5;208', 'accent': '36;1', 'cyan': '36', 'blue': '34',
              'magenta': '35', 'dim': '90', 'bold': '1', 'white': '97;1', 'track': '38;5;238', '/': '0'}


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


FLAG_RE = re.compile('^[\U0001F1E6-\U0001F1FF]{2}\\s*')


def flag_emoji(code):
    """🇳🇱 for 'NL' (two regional indicator symbols); '' for anything else."""
    code = (code or '').upper()
    if not re.fullmatch(r'[A-Z]{2}', code):
        return ''
    return ''.join(chr(0x1F1E6 + ord(ch) - ord('A')) for ch in code)


def country_iso():
    """ISO code behind country_name(): XR_COUNTRY if it is a code, else the VPS's."""
    forced = os.environ.get('XR_COUNTRY', '').strip()
    if forced:
        if forced.upper() in COUNTRY_EN:
            return forced.upper()
        rev = {v.lower(): k for k, v in COUNTRY_EN.items()}
        return rev.get(forced.lower(), '')
    return country_code()


def country_style():
    """'full' (Netherlands) or 'code' (NL) — how the country is written in inbound names."""
    try:
        with open(os.path.join(STATE_DIR, 'country-style')) as f:
            v = f.read().strip()
    except OSError:
        v = ''
    return 'code' if v == 'code' else 'full'


def country_label(code, name=''):
    if not code:
        return name
    return code if country_style() == 'code' else COUNTRY_EN.get(code, name or code)


def country_prefix(code=None):
    """'🇳🇱 Netherlands' or '🇳🇱 NL' — the start of auto inbound names ('' with XR_COUNTRY=none).
    CODE: another server's country (a node); default — this server."""
    if code is None:
        name = country_name()
        if not name:
            return ''
        code = country_iso()
        label = country_label(code, name) if code else name
    else:
        label = country_label(code)
    return ('%s %s' % (flag_emoji(code), label)).strip()


def short_name(remark):
    """Inbound name without the flag and country prefix (for compact tables)."""
    flagged = bool(FLAG_RE.match(remark or ''))
    remark = FLAG_RE.sub('', remark or '', count=1)
    if flagged and re.match(r'^[A-Z]{2} \S', remark) and remark[:2] in COUNTRY_EN:
        return remark[3:]
    for prefix in list(COUNTRY_EN.values()) + list(LEGACY_COUNTRY_RU):
        if remark.startswith(prefix + ' ') and len(remark) > len(prefix) + 1:
            return remark[len(prefix) + 1:]
    return remark


def flagged_remark(remark):
    """Add the country flag to an auto name of an older version; None if nothing to do.
    'Netherlands VLESS…' → '🇳🇱 Netherlands VLESS…'; 'Нидерланды VLESS…' → '🇳🇱 Netherlands VLESS…'."""
    if not remark or FLAG_RE.match(remark):
        return None
    for code, name in sorted(COUNTRY_EN.items(), key=lambda kv: -len(kv[1])):
        if remark.startswith(name + ' '):
            return '%s %s' % (flag_emoji(code), remark)
    try:
        ru = COUNTRY_RU                     # defined in the IP Region part
    except NameError:
        ru = {}
    for code, name in sorted(ru.items(), key=lambda kv: -len(kv[1])):
        if remark.startswith(name + ' ') and code in COUNTRY_EN:
            return '%s %s %s' % (flag_emoji(code), COUNTRY_EN[code], remark[len(name) + 1:])
    return None


def cmd_inbound_flags(_args):
    """Prefix the flag to auto-named inbounds created by older versions; prints the count."""
    n = 0
    for ib in inbounds():
        new = flagged_remark(ib.get('remark') or '')
        if not new:
            continue
        names = {x.get('remark') for x in inbounds() if x['id'] != ib['id']}
        if new in names:
            continue
        ib['remark'] = new
        save_inbound(ib)
        n += 1
    print(n)


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


def first_sni(ib):
    """One SNI for lists: 'a.com +12' when Reality has many serverNames."""
    names = [x for x in inbound_sni(ib).split(',') if x]
    if not names:
        return ''
    return names[0] + (' +%d' % (len(names) - 1) if len(names) > 1 else '')


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


def port_problem(port, transport, ibs, ignore_id=None, node=None):
    """'' if PORT/TRANSPORT is free for an inbound, else why it is not.
    NODE: the inbound lives on that node — only its inbounds matter, local sockets do not."""
    if not 1 <= port <= 65535:
        return 'порт должен быть от 1 до 65535'
    ibs = [ib for ib in ibs if (ib.get('nodeId') or None) == (node or None)]
    for ib in ibs:
        if ib['id'] != ignore_id and ib.get('port') == port and inbound_transport(ib) == transport:
            return 'занят inbound-ом «%s»' % (ib.get('remark') or ib['id'])
    own = next((ib for ib in ibs if ib['id'] == ignore_id), None)
    if not node and port in listening(transport) and not (own and own.get('port') == port):
        return 'занят другой программой на этом сервере (%s)' % transport.upper()
    return ''


def pick_port(transport, ibs, taken, node=None):
    import random
    candidates = PREFERRED_PORTS[transport] + random.sample(range(20000, 60000), 200)
    for p in candidates:
        if (p, transport) not in taken and not port_problem(p, transport, ibs, node=node):
            return p
    die('не нашлось свободного порта (%s)' % transport)


def cmd_check_port(args):
    """check-port PORT TRANSPORT [ID] — prints the reason when busy (exit 1)."""
    try:
        port = int(args[0])
    except (ValueError, IndexError):
        die('порт — число')
    ibs = inbounds()
    ignore = int(args[2]) if len(args) > 2 and args[2] else None
    node = next((ib.get('nodeId') for ib in ibs if ib['id'] == ignore), None)
    reason = port_problem(port, args[1] if len(args) > 1 else 'tcp', ibs, ignore, node=node)
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
    node = int((opts.get('node') or ['0'])[0] or 0) or None
    if node:
        for k in kinds:
            if k in TLS_KINDS:
                die('%s на узле не создаётся: сертификат домена лежит на самом узле' % KIND[k]['label'])
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
            reason = port_problem(port, transport, ibs, node=node)
            if reason:
                die('порт %d: %s' % (port, reason))
        else:
            port = pick_port(transport, ibs, taken, node=node)
        taken.add((port, transport))
        cert = key = ''
        if k in TLS_KINDS:
            cert, key, sni = tls_opts[k]
        else:
            sni = snis.get(k) or (auto_snis.pop(0) if k in REALITY_KINDS or k == 'mtproto' else '')
        plan.append((k, port, sni, cert, key))
    created = []
    country = country_prefix(node_country(node, ibs) if node else None)
    for k, port, sni, cert, key in plan:
        base = names.get(k) or ('%s %s' % (country, KIND[k]['label'])).strip()
        payload = build(k, port, sni, cert, key, sniff)
        payload.update(enable=True, remark=unique_name(base, ibs), listen='', expiryTime=0, total=0)
        if node:
            payload['nodeId'] = node
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
    node = int(args[args.index('--node') + 1]) if '--node' in args else 0
    for ib in ([] if '--fresh' in args else inbounds()):
        if (ib.get('nodeId') or 0) != node:
            continue
        counts[classify(ib)] = counts.get(classify(ib), 0) + 1
    fresh = not any(counts.values())
    for k, label, _, note in KINDS:
        if node and k in TLS_KINDS:
            continue                    # the certificate lives on the node itself
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
    reason = port_problem(port, inbound_transport(ib), inbounds(), ib['id'], node=ib.get('nodeId'))
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
        w = min(max(len(ib.get('remark') or '') for ib in ibs), 36)
        locs = inbound_locations(ibs)
        last = None
        for ib in sorted(ibs, key=lambda x: (locs[x['id']][0], x['id']) if locs else x['id']):
            if locs and locs[ib['id']][0] != last:
                last = locs[ib['id']][0]
                out('{accent}%s{/}' % locs[ib['id']][1])
            dot = '{green}●{/}' if ib.get('enable') else '{red}○{/}'
            name = ib.get('remark') or ib.get('tag') or ''
            name = name if len(name) <= w else name[:w - 1] + '…'
            out('%s %s  %-10s {dim}%s{/}' % (dot, name.ljust(w),
                                          '%s/%s' % (ib.get('port'), inbound_transport(ib)), first_sni(ib)))
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
                     '%s / %s' % (human(used), human(total) if total else '∞'), first_sni(ib) or '—'))
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


def cmd_ports_all(args):
    """PORT TRANSPORT REMARK for every enabled inbound (what the firewall must allow).
    --local: only inbounds of this server (not of its nodes)."""
    local = '--local' in args
    for ib in sorted(inbounds(), key=lambda x: x['id']):
        if ib.get('enable') and not (local and ib.get('nodeId')):
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


# ---------------------------------------------------------------- where an inbound lives
def flag_code(text):
    """'NL' for a remark/name starting with 🇳🇱; '' otherwise."""
    m = re.match('^([\U0001F1E6-\U0001F1FF])([\U0001F1E6-\U0001F1FF])', text or '')
    return ''.join(chr(ord(c) - 0x1F1E6 + ord('A')) for c in m.groups()) if m else ''


def _remark_country(remark):
    code = flag_code(remark)
    if code:
        return code
    for c, name in sorted(COUNTRY_EN.items(), key=lambda kv: -len(kv[1])):
        if (remark or '').startswith(name + ' '):
            return c
    return ''


def _geo_country(address):
    """ISO code of a node's address by geo-IP (cached in node-countries.json)."""
    import socket
    cache_f = os.path.join(STATE_DIR, 'node-countries.json')
    try:
        with open(cache_f) as f:
            cache = json.load(f)
    except (OSError, ValueError):
        cache = {}
    if address in cache:
        return cache[address]
    code = ''
    try:
        ip = socket.gethostbyname(address)
        for url, parse in (('https://ipinfo.io/%s/country' % ip, lambda t: t.strip()),
                           ('https://api.country.is/%s' % ip, lambda t: json.loads(t).get('country', ''))):
            try:
                v = (parse(_fetch(url, timeout=4)) or '').upper()
            except Exception:
                continue
            if re.fullmatch(r'[A-Z]{2}', v):
                code = v
                break
    except OSError:
        pass
    if code:
        cache[address] = code
        try:
            with open(cache_f, 'w') as f:
                json.dump(cache, f)
        except OSError:
            pass
    return code


_NODES = None


def nodes_by_id():
    global _NODES
    if _NODES is None:
        try:
            _NODES = {n['id']: n for n in (ok(call('/nodes/list'), 'список узлов') or [])}
        except SystemExit:
            _NODES = {}
    return _NODES


def node_country(nid, ibs):
    """ISO code of node NID: flag in its name, its inbound names, then geo-IP of its address."""
    n = nodes_by_id().get(nid) or {}
    code = flag_code(n.get('name') or '') or flag_code(n.get('remark') or '')
    if not code:
        votes = {}
        for ib in ibs:
            if ib.get('nodeId') == nid:
                c = _remark_country(ib.get('remark') or '')
                if c:
                    votes[c] = votes.get(c, 0) + 1
        code = max(votes, key=votes.get) if votes else ''
    if not code and n.get('address'):
        code = _geo_country(n['address'])
    return code


def node_title(nid):
    n = nodes_by_id().get(nid) or {}
    return (n.get('name') or n.get('remark') or n.get('address') or 'узел %s' % nid).strip()


def inbound_locations(ibs):
    """{inbound id: (sort key, label)} when inbounds of other nodes are present, else {}.
    Label: '🇩🇪 de-1 · Germany' — the flag from the node name, its inbound names or geo-IP."""
    node_ids = {ib.get('nodeId') for ib in ibs if ib.get('nodeId')}
    if not node_ids:
        return {}
    labels = {}
    me = country_iso()
    labels[0] = ('0', ('%s %s · этот сервер' % (flag_emoji(me), COUNTRY_EN.get(me) or country_name())).strip())
    for nid in sorted(node_ids):
        name = node_title(nid)
        code = node_country(nid, ibs)
        label = name if flag_code(name) else ('%s %s' % (flag_emoji(code), name)).strip()
        cname = COUNTRY_EN.get(code, '')        # headers: always the full name (Windows shows flags as letters)
        if cname and cname.lower() not in label.lower():
            label += ' · ' + cname
        labels[nid] = ('1' + FLAG_RE.sub('', name).lower(), label)
    return {ib['id']: labels.get(ib.get('nodeId') or 0, labels[0]) for ib in ibs}


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
        if act.get('node'):
            nid = act['node']
            name = node_title(nid)
            if flag_code(name):
                return name
            code = node_country(nid, self.ibs)
            return ('%s %s' % (flag_emoji(code), name)).strip()
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
        """'65.00 ГБ / 100.00 ГБ' — the used part coloured by how much of the limit is gone."""
        total, used = cl.get('totalGB') or 0, self.used(cl)
        if not total:
            return '%s / ∞' % human(used)
        pct = used * 100.0 / total
        color = 'green' if pct < 50 else 'yellow' if pct < 75 else 'orange' if pct < 90 else 'red'
        return '{%s}%s{/} / %s' % (color, human(used), human(total))

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
    rows = [(cl.get('email', ''), cl.get('group') or '—', str(len(cl.get('inboundIds') or [])),
             snap.traffic(cl), snap.state(cl))
            for cl in sorted(snap.clients, key=lambda x: ((x.get('group') or '\uffff'), x.get('email', '')))]
    head = ('ИМЯ', 'ГРУППА', 'INBOUND-Ы', 'ТРАФИК', 'СОСТОЯНИЕ')
    caps = [18, 14, 9, 24, 40]
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
    locs = inbound_locations(snap.ibs)
    last = None
    for ib in sorted(snap.ibs, key=lambda x: (locs[x['id']][0], x['id']) if locs else x['id']):
        extra = '' if ib.get('enable') else '  {red}выкл{/}'
        name = snap.names[ib['id']]
        if locs:
            key, label = locs[ib['id']]
            if key != last:
                print('#%s\tOFF\t' % label)
                last = key
            flag = FLAG_RE.match(label)
            name = (flag.group(0) if flag else '') + name
        print('%s\t%s\t%s\t%s :%s%s' % (ib['id'], 'ON' if ib['id'] in attached else 'OFF',
                                       name, ib.get('protocol'), ib.get('port'), extra))


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
    log_ok = False                      # Xray writes the access log (file exists)
    try:
        with open(ACCESS_LOG, 'r+', errors='replace') as f:
            log_ok = True
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
    # Users the Xray log of THIS server did not show:
    #  - online on a node (onlinesByGuid): their traffic is in the node's own log —
    #    remember the node, not an inbound;
    #  - online here and attached to an active MTProto inbound (served by mtg, not
    #    Xray) — only when the access log is really written, otherwise every online
    #    user would look like an MTProto one.
    now = int(time.time())
    try:
        onlines = set(ok(call('/clients/onlines', {}, timeout=20), 'онлайн') or [])
        by_guid = ok(call('/clients/onlinesByGuid', {}, timeout=20), 'онлайн по узлам') or {}
        my_guid = (ok(call('/server/status', timeout=20), 'состояние') or {}).get('panelGuid') or ''
        node_of_guid = {}
        if any(g != my_guid for g in by_guid):
            for n in ok(call('/nodes/list'), 'список узлов') or []:
                if n.get('guid'):
                    node_of_guid[n['guid']] = n['id']
        on_nodes = set()
        for guid, emails in by_guid.items():
            if guid != my_guid:
                on_nodes.update(emails or [])
        here = (onlines - on_nodes) | set(by_guid.get(my_guid) or [])
        for guid, emails in by_guid.items():
            if guid == my_guid or guid not in node_of_guid:
                continue
            for email in emails or []:
                if email not in seen:
                    activity[email] = {'node': node_of_guid[guid], 'ts': now}
                    seen.add(email)
        if log_ok:
            active = set()
            for tags in (ok(call('/clients/activeInbounds', {}, timeout=20), 'активные') or {}).values():
                active.update(tags or [])
            mt = [ib for ib in inbounds() if ib.get('protocol') == 'mtproto' and not ib.get('nodeId')
                  and ib.get('tag') in active]
            for ib in mt:
                for cl in jload(ib.get('settings'), {}).get('clients') or []:
                    email = cl.get('email')
                    if email in here and email not in seen:
                        activity[email] = {'inbound': ib.get('tag'), 'ts': now}
                        seen.add(email)
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


def cmd_access_log_ok(_args):
    """Exit 0 if Xray of this panel writes the access log the activity tracker reads."""
    log = get_template().get('log') or {}
    sys.exit(0 if log.get('access') == ACCESS_LOG else 1)


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
              'apiToken': api_token, 'country': country_name(), 'name': country_prefix() or domain, 'exp': exp}
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


def cmd_nodes_status(_args):
    """For the services screen: SYMBOL <TAB> name <TAB> address <TAB> detail."""
    for n in _nodes():
        port = int(n.get('port') or 0)
        addr = (n.get('address') or '') + ('' if port in (443, 0) else ':%d' % port)
        if not n.get('enable', True):
            sym, detail = '○', 'выключен'
        elif n.get('status') == 'online':
            sym, detail = '●', 'в сети · %s мс' % n.get('latencyMs', '?')
        elif n.get('status') == 'offline':
            sym, detail = '✗', 'недоступен' + (' — ' + (n.get('lastError') or '').strip()[:60]
                                               if (n.get('lastError') or '').strip() else '')
        else:
            sym, detail = '◌', 'проверяется'
        print('%s\t%s\t%s\t%s' % (sym, n.get('name') or addr, addr, detail))


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
        # Same look as the progress bar of the install screens: ━━━━────
        bar = c('accent', '━' * filled) + c('track', '─' * (bar_w - filled))
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


# ------------------------------------------------------------------ IP Region
# Renders the JSON of github.com/Davoyan/ipregion (`ipregion.sh --json`).
COUNTRY_RU = {
    'AE': 'ОАЭ', 'AL': 'Албания', 'AM': 'Армения', 'AR': 'Аргентина', 'AT': 'Австрия', 'AU': 'Австралия',
    'AZ': 'Азербайджан', 'BA': 'Босния', 'BD': 'Бангладеш', 'BE': 'Бельгия', 'BG': 'Болгария',
    'BH': 'Бахрейн', 'BR': 'Бразилия', 'BY': 'Беларусь', 'CA': 'Канада', 'CH': 'Швейцария', 'CL': 'Чили',
    'CN': 'Китай', 'CO': 'Колумбия', 'CY': 'Кипр', 'CZ': 'Чехия', 'DE': 'Германия', 'DK': 'Дания',
    'EE': 'Эстония', 'EG': 'Египет', 'ES': 'Испания', 'FI': 'Финляндия', 'FR': 'Франция',
    'GB': 'Великобритания', 'GE': 'Грузия', 'GR': 'Греция', 'HK': 'Гонконг', 'HR': 'Хорватия',
    'HU': 'Венгрия', 'ID': 'Индонезия', 'IE': 'Ирландия', 'IL': 'Израиль', 'IN': 'Индия', 'IR': 'Иран',
    'IS': 'Исландия', 'IT': 'Италия', 'JP': 'Япония', 'KE': 'Кения', 'KG': 'Киргизия', 'KR': 'Южная Корея',
    'KZ': 'Казахстан', 'LT': 'Литва', 'LU': 'Люксембург', 'LV': 'Латвия', 'MA': 'Марокко', 'MD': 'Молдова',
    'ME': 'Черногория', 'MK': 'Сев. Македония', 'MN': 'Монголия', 'MT': 'Мальта', 'MX': 'Мексика',
    'MY': 'Малайзия', 'NG': 'Нигерия', 'NL': 'Нидерланды', 'NO': 'Норвегия', 'NZ': 'Новая Зеландия',
    'PE': 'Перу', 'PH': 'Филиппины', 'PK': 'Пакистан', 'PL': 'Польша', 'PT': 'Португалия', 'QA': 'Катар',
    'RO': 'Румыния', 'RS': 'Сербия', 'RU': 'Россия', 'SA': 'Саудовская Аравия', 'SC': 'Сейшелы',
    'SE': 'Швеция', 'SG': 'Сингапур', 'SI': 'Словения', 'SK': 'Словакия', 'TH': 'Таиланд',
    'TJ': 'Таджикистан', 'TM': 'Туркмения', 'TR': 'Турция', 'TW': 'Тайвань', 'UA': 'Украина', 'US': 'США',
    'UZ': 'Узбекистан', 'VN': 'Вьетнам', 'ZA': 'ЮАР',
}
# Services that answer Yes/No: True if "Yes" is the good answer.
IPREGION_YESNO_GOOD = {'Google Search Captcha': False}


def _ipr_load(path):
    try:
        with open(path, encoding='utf-8', errors='replace') as fh:
            raw = fh.read()
        data = json.loads(raw[raw.index('{'):])
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not isinstance(data.get('results'), dict):
        return None
    return data


def cmd_ipregion_check(args):
    data = _ipr_load(args[0])
    res = (data or {}).get('results') or {}
    sys.exit(0 if any(res.get(g) for g in ('primary', 'custom', 'cdn')) else 1)


def _country(code):
    return COUNTRY_RU.get(code) or COUNTRY_EN.get(code) or code


def _ipr_cell(service, value, main):
    """(mark, text) for one result."""
    v = (value or '').strip()
    if not v or v in ('N/A', 'null'):
        return c('dim', '○'), c('dim', 'нет данных')
    if v in ('Yes', 'No'):
        good = (v == 'Yes') == IPREGION_YESNO_GOOD.get(service, True)
        if service == 'Google Search Captcha':
            label = 'есть капча' if v == 'Yes' else 'без капчи'
        else:
            label = 'доступен' if v == 'Yes' else 'недоступен'
        return (c('green', '✓'), c('green', label)) if good else (c('red', '✗'), c('red', label))
    code = v.upper()
    if re.fullmatch(r'[A-Z]{2}', code):
        style = 'green' if code == main else 'yellow'
        return c(style, '●'), c(style, code) + ' ' + c('dim', _country(code))
    return c('dim', '·'), v[:18]


def cmd_ipregion_table(args):
    data = _ipr_load(args[0])
    if not data:
        die('нет результатов ipregion')
    width = int(args[1]) if len(args) > 1 and args[1].isdigit() else 100
    res = data['results']
    groups = [('ПОПУЛЯРНЫЕ СЕРВИСЫ', res.get('custom') or []), ('GEOIP-БАЗЫ', res.get('primary') or []),
              ('CDN', res.get('cdn') or [])]
    has_v6 = bool(data.get('ipv6')) and any(r.get('ipv6') for _, rows in groups for r in rows)
    # Majority country over all IPv4 answers.
    counts = {}
    total = 0
    for _, rows in groups:
        for r in rows:
            raw = (r.get('ipv4') or '').strip()
            v = raw.upper()
            if raw not in ('Yes', 'No') and re.fullmatch(r'[A-Z]{2}', v):
                counts[v] = counts.get(v, 0) + 1
                total += 1
    ranking = sorted(counts.items(), key=lambda kv: -kv[1])
    main = ranking[0][0] if ranking else ''

    ips = []
    if data.get('ipv4'):
        ips.append('IPv4 ' + c('bold', data['ipv4']))
    if data.get('ipv6'):
        ips.append('IPv6 ' + c('bold', data['ipv6']))
    out('  ' + ('   '.join(ips) or c('dim', 'IP не определён')))
    out('')
    if ranking:
        share = 100 * ranking[0][1] / total
        verdict = c('green', '✓ Почти все сервисы видят один регион') if share >= 85 else (
            c('yellow', '⚠ Сервисы расходятся во мнениях о стране') if share >= 50 else
            c('red', '✗ Регион IP определяется по-разному'))
        out('  ' + verdict)
        out('')
        out(c('dim', '  КАК СЕРВИСЫ ВИДЯТ СТРАНУ IP'))
        bar_w = 24
        for code, n in ranking[:4]:
            pct = 100 * n / total
            filled = max(1, round(bar_w * n / total))
            style = 'green' if code == main else 'yellow'
            out('  %s  %s  %s%s %s' % (c(style, code), _vpad(c('white', _country(code)), 18),
                                      c('accent', '━' * filled), c('track', '─' * (bar_w - filled)),
                                      c('bold', '%3.0f%%' % pct) + c('dim', '  %d из %d' % (n, total))))
        if len(ranking) > 4:
            rest = sum(n for _, n in ranking[4:])
            out(c('dim', '      и ещё %d стран(ы): %d ответ(ов)' % (len(ranking) - 4, rest)))

    name_w = 22
    cell_w = 2 + name_w + 21 + (14 if has_v6 else 0)
    cols = 2 if width >= cell_w * 2 + 2 else 1
    for title, rows in groups:
        if not rows:
            continue
        out('')
        out(c('dim', '  ' + title + ('   (IPv4 · IPv6)' if has_v6 else '')))
        cells = []
        for r in rows:
            svc = r.get('service', '')
            mark, txt = _ipr_cell(svc, r.get('ipv4'), main)
            if has_v6:
                _, t6 = _ipr_cell(svc, r.get('ipv6'), main)
                txt = _vpad(txt, 22) + c('dim', '· ') + t6
            name = svc if len(svc) <= name_w - 1 else svc[:name_w - 2] + '…'
            cells.append('%s %s %s' % (mark, _vpad(name, name_w), txt))
        if cols == 1:
            for cell in cells:
                out('  ' + cell)
        else:
            half = (len(cells) + 1) // 2
            for i in range(half):
                left = cells[i]
                right = cells[i + half] if i + half < len(cells) else ''
                out('  ' + _vpad(left, cell_w) + '  ' + right)
    out('')
    out('  ' + c('green', '●') + c('dim', ' основная страна   ') + c('yellow', '●') + c('dim', ' другая страна   ') +
        c('green', '✓') + c('dim', '/') + c('red', '✗') + c('dim', ' доступность   ○ сервис не ответил'))
    out(c('dim', '  Данные: github.com/Davoyan/ipregion'))


# ------------------------------------------------------------------ routing
# Split tunnelling ON THE CLIENTS, delivered by this panel's subscriptions:
# Russian sites go straight from the user's device, blocked ones through the
# server (or the reverse). 3x-ui sends the rules with the subscription:
#   Happ / INCY  — "Routing" header (happ://routing/onadd/… deeplink),
#   JSON         — rules baked into each Xray config (v2rayN, v2rayNG…),
#   Clash/Mihomo — rules in the YAML profile.
# State: STATE_DIR/routing.json; downloaded lists: STATE_DIR/routing-lists/.
import hashlib
import ipaddress as _ipa

ROUTING_FILE = os.path.join(STATE_DIR, 'routing.json')
ROUTING_LISTS = os.path.join(STATE_DIR, 'routing-lists')
ROUTING_MODES = {
    'off': 'выключена — весь трафик через сервер',
    'ru-direct': 'российские сайты напрямую, остальное через сервер',
    'blocked-proxy': 'через сервер только заблокированное в РФ, остальное напрямую',
}
RUNET = 'https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/'
ITDOG = 'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/'
BLOCKED_DOMAINS_URL = ITDOG + 'Russia/inside-raw.lst'
BLOCKED_SUBNET_URLS = [ITDOG + 'Subnets/IPv4/%s.lst' % n for n in ('telegram', 'meta', 'twitter', 'discord')]
PRIVATE_IP = ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '127.0.0.0/8', '169.254.0.0/16', '100.64.0.0/10']
RU_SUFFIXES = ['ru', 'su', 'xn--p1ai']
HAPP_MAX = 7000                       # 3x-ui sends at most 8 KiB in the Routing header
SUB_KEYS = ('subEnableRouting', 'subRoutingRules', 'subJsonRoutingRules', 'subClashEnableRouting',
            'subClashRules', 'subIncyEnableRouting', 'subIncyRoutingRules')
DOMAIN_RE = re.compile(r'^(\*\.)?([a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?\.)+[a-z0-9-]{2,63}\.?$', re.I)
PREFIXES = ('domain:', 'full:', 'regexp:', 'keyword:', 'geosite:', 'ext:')


def routing_load():
    try:
        with open(ROUTING_FILE) as fh:
            st = json.load(fh)
    except (OSError, ValueError):
        st = {}
    if st.get('mode') == 'blocked-vpn':          # v2.6.0 server-side names
        st['mode'] = 'blocked-proxy'
    if st.get('mode') not in ROUTING_MODES:
        st['mode'] = 'off'
    st.setdefault('custom', [])
    return st


def routing_save(st):
    tmp = ROUTING_FILE + '.tmp'
    with open(tmp, 'w') as fh:
        json.dump(st, fh, ensure_ascii=False, indent=1)
    os.chmod(tmp, 0o600)
    os.replace(tmp, ROUTING_FILE)


def parse_entries(text):
    """Domains and IPs from a list: plain, prefixed, hosts and dnsmasq formats."""
    domains, ips = [], []
    seen = set()
    for raw in text.splitlines():
        line = raw.split('#', 1)[0].strip()
        if not line or line.startswith('//') or line.startswith('!'):
            continue
        m = re.match(r'^[a-z_-]+=/(.+)/[^/]*$', line)        # dnsmasq: server=/a.com/b.com/addr
        tokens = [t for t in m.group(1).split('/') if t] if m else [line.split()[0]]
        if not m and len(line.split()) >= 2:                 # hosts: 0.0.0.0 domain
            first, second = line.split()[:2]
            try:
                _ipa.ip_address(first)
                tokens = [second]
            except ValueError:
                pass
        for tok in tokens:
            tok = tok.strip().strip(',;').lower()
            if not tok or tok in seen:
                continue
            seen.add(tok)
            if tok.startswith(PREFIXES):
                domains.append(tok)
                continue
            try:
                _ipa.ip_network(tok, strict=False)
                ips.append(tok)
                continue
            except ValueError:
                pass
            if tok.startswith('*.'):
                tok = tok[2:]
            if tok.startswith('.'):
                tok = tok[1:]
                if re.fullmatch(r'[a-z0-9-]{2,63}', tok):     # ".ua" = the whole zone
                    domains.append('domain:' + tok)
                    continue
            if DOMAIN_RE.match(tok):
                domains.append('domain:' + tok.rstrip('.'))
    return domains, ips


def _list_path(url):
    return os.path.join(ROUTING_LISTS, hashlib.sha256(url.encode()).hexdigest()[:16] + '.txt')


def _download(url, limit=32 << 20):
    import urllib.request
    req = urllib.request.Request(url, headers={'User-Agent': '3x-ui_reverse', 'Accept': '*/*'})
    with urllib.request.urlopen(req, timeout=40) as r:
        data = r.read(limit + 1)
    if len(data) > limit:
        die('список больше %d МБ' % (limit >> 20))
    return data.decode('utf-8', 'replace')


def fetch_list(url):
    """Download URL into the cache; returns (domains, ips)."""
    text = _download(url)
    domains, ips = parse_entries(text)
    if not domains and not ips:
        die('в списке не найдено ни доменов, ни IP-адресов: %s' % url)
    os.makedirs(ROUTING_LISTS, mode=0o700, exist_ok=True)
    tmp = _list_path(url) + '.tmp'
    with open(tmp, 'w') as fh:
        fh.write(text)
    os.replace(tmp, _list_path(url))
    return domains, ips


def cached_list(url):
    try:
        with open(_list_path(url), encoding='utf-8', errors='replace') as fh:
            return parse_entries(fh.read())
    except OSError:
        return [], []



def _custom(st):
    """Custom rules -> {'direct': (domains, ips), 'proxy': (domains, ips)}."""
    acc = {'direct': ([], []), 'proxy': ([], [])}
    for r in st['custom']:
        if r.get('type') == 'url':
            domains, ips = cached_list(r['url'])
        else:
            domains, ips = parse_entries('\n'.join(r.get('items') or []))
        side = 'direct' if r.get('action') == 'direct' else 'proxy'
        acc[side][0].extend(d for d in domains if d not in acc[side][0])
        acc[side][1].extend(i for i in ips if i not in acc[side][1])
    return acc


def _builtin_blocked():
    """Inline list of blocked domains/subnets (for JSON configs without runetfreedom geo files)."""
    domains, ips = cached_list(BLOCKED_DOMAINS_URL)
    for u in BLOCKED_SUBNET_URLS:
        ips += cached_list(u)[1]
    return domains, ips


def refresh_builtin():
    """Re-download the built-in lists; a failure keeps the cached copy. True if all loaded."""
    good = True
    for u in [BLOCKED_DOMAINS_URL] + BLOCKED_SUBNET_URLS:
        try:
            fetch_list(u)
        except (Exception, SystemExit) as e:
            good = False
            sys.stderr.write('routing: не удалось скачать %s: %s\n' % (u, e))
    return good


def _happ_profile(st, custom):
    """Happ/INCY profile; geo files from runetfreedom (have ru-blocked, category-ru…)."""
    mode = st['mode']
    cd, ci = custom['direct']
    pd, pi = custom['proxy']
    prof = {'Name': '3x-ui_reverse', 'GlobalProxy': 'false' if mode == 'blocked-proxy' else 'true',
            'RouteOrder': 'block-proxy-direct', 'Geoipurl': RUNET + 'geoip.dat', 'Geositeurl': RUNET + 'geosite.dat',
            'LastUpdated': str(int(time.time())), 'DomainStrategy': 'IPIfNonMatch', 'FakeDNS': 'false',
            'BlockSites': [], 'BlockIp': [], 'ProxySites': [], 'ProxyIp': [],
            'DirectSites': ['geosite:private'], 'DirectIp': ['geoip:private']}
    if mode != 'off':
        prof['ProxySites'].append('geosite:ru-blocked')
        prof['ProxyIp'].append('geoip:ru-blocked')
    if mode == 'ru-direct':
        prof['DirectSites'] += ['geosite:category-ru', 'geosite:ru-available-only-inside'] + \
            ['domain:' + t for t in RU_SUFFIXES]
        prof['DirectIp'].append('geoip:ru')
    # Custom entries go in while the deeplink stays under the header limit.
    dropped = 0
    for key, items in (('ProxySites', pd), ('ProxyIp', pi), ('DirectSites', cd), ('DirectIp', ci)):
        for it in items:
            if it.startswith('ext:'):
                continue
            prof[key].append(it)
            if len(_happ_link(prof)) > HAPP_MAX:
                prof[key].pop()
                dropped += 1
    return prof, dropped


def _happ_link(prof):
    import base64
    return 'happ://routing/onadd/' + base64.b64encode(json.dumps(prof, ensure_ascii=False,
                                                                   separators=(',', ':')).encode()).decode()


def _json_spec(st, custom):
    """Rules baked into JSON-subscription configs. Only categories present in the
    stock geo files of v2rayN/v2rayNG; blocked domains/subnets are inlined."""
    mode = st['mode']
    plain = lambda xs: [x for x in xs if not x.startswith('ext:')]
    cd, ci = plain(custom['direct'][0]), plain(custom['direct'][1])
    pd, pi = plain(custom['proxy'][0]), plain(custom['proxy'][1])
    spec = {'DomainStrategy': 'IPIfNonMatch', 'RouteOrder': 'block-proxy-direct', 'BlockSites': [], 'BlockIp': [],
            'ProxySites': pd, 'ProxyIp': pi, 'DirectSites': ['geosite:private'] + cd, 'DirectIp': ['geoip:private'] + ci}
    if mode != 'off':
        bd, bi = _builtin_blocked()
        spec['ProxySites'] = pd + bd
        spec['ProxyIp'] = pi + bi
    if mode == 'ru-direct':
        spec['DirectSites'] += ['geosite:category-ru'] + ['domain:' + t for t in RU_SUFFIXES]
        spec['DirectIp'].append('geoip:ru')
    elif mode == 'blocked-proxy':
        spec['DirectIp'] += ['0.0.0.0/0', '::/0']        # everything not listed above: direct
    return spec


def _clash_rule(entry, target):
    if entry.startswith('domain:'):
        return 'DOMAIN-SUFFIX,%s,%s' % (entry[7:], target)
    if entry.startswith('full:'):
        return 'DOMAIN,%s,%s' % (entry[5:], target)
    if entry.startswith('keyword:'):
        return 'DOMAIN-KEYWORD,%s,%s' % (entry[8:], target)
    if entry.startswith('regexp:'):
        return 'DOMAIN-REGEX,%s,%s' % (entry[7:], target)
    if entry.startswith('geosite:'):
        return 'GEOSITE,%s,%s' % (entry[8:], target)
    try:
        net = _ipa.ip_network(entry, strict=False)
        return '%s,%s,%s,no-resolve' % ('IP-CIDR6' if net.version == 6 else 'IP-CIDR', entry, target)
    except ValueError:
        return None


def _clash_yaml(st, custom):
    """Mihomo profile part (JSON is valid YAML); geo files from runetfreedom."""
    mode = st['mode']
    rules = ['IP-CIDR,%s,DIRECT,no-resolve' % n for n in PRIVATE_IP]
    for side, target in (('proxy', 'PROXY'), ('direct', 'DIRECT')):
        for e in custom[side][0] + custom[side][1]:
            r = _clash_rule(e, target)
            if r:
                rules.append(r)
    if mode != 'off':
        rules += ['GEOSITE,ru-blocked,PROXY', 'GEOIP,ru-blocked,PROXY,no-resolve']
    if mode == 'ru-direct':
        rules += ['GEOSITE,category-ru,DIRECT', 'GEOSITE,ru-available-only-inside,DIRECT'] + \
            ['DOMAIN-SUFFIX,%s,DIRECT' % t for t in RU_SUFFIXES] + ['GEOIP,ru,DIRECT']
    rules.append('MATCH,DIRECT' if mode == 'blocked-proxy' else 'MATCH,PROXY')
    doc = {'geodata-mode': True, 'geox-url': {'geosite': RUNET + 'geosite.dat', 'geoip': RUNET + 'geoip.dat'},
           'rules': rules}
    return json.dumps(doc, ensure_ascii=False, indent=1)


def _settings():
    return jload(ok(call('/setting/all', {}), 'настройки панели'), {})


def _save_settings(allset):
    ok(call('/setting/update', allset), 'сохранение настроек панели')
    # SIGHUP inside 3x-ui: only the web and subscription servers restart — Xray
    # and the users' connections keep running.
    ok(call('/setting/restartPanel', {}), 'перезапуск подписок')
    time.sleep(4)
    if _wait_panel(30):
        return
    # The panel did not come back by itself (e.g. the process exited and systemd
    # does not restart it): start the service once more.
    import subprocess
    sys.stderr.write('routing: панель не ответила после перезапуска, systemctl restart x-ui\n')
    try:
        subprocess.run(['systemctl', 'restart', 'x-ui'], timeout=60, capture_output=True)
    except (OSError, subprocess.SubprocessError):
        pass
    if _wait_panel(40):
        return
    die('панель 3x-ui не запустилась после сохранения настроек — journalctl -u x-ui -n 50')


def _wait_panel(seconds):
    """Quietly wait for the panel API (no error line per attempt)."""
    import io
    for _ in range(seconds):
        saved, sys.stderr = sys.stderr, io.StringIO()
        try:
            if call('/inbounds/list', timeout=5).get('success'):
                return True
        except SystemExit:
            pass
        finally:
            sys.stderr = saved
        time.sleep(1)
    return False


def routing_apply(st):
    allset = _settings()
    if 'prev' not in st:                              # what the panel had before us
        st['prev'] = {k: allset.get(k) for k in SUB_KEYS}
    info = {}
    if st['mode'] == 'off' and not st['custom']:
        prev = st.get('prev') or {}
        for k in SUB_KEYS:
            allset[k] = prev.get(k, allset.get(k))
        if not (prev.get('subRoutingRules') or '').strip():
            allset['subRoutingRules'] = 'happ://routing/off'      # Happ drops the profile it got from us
    else:
        if st['mode'] != 'off' and not cached_list(BLOCKED_DOMAINS_URL)[0]:
            refresh_builtin()
            if not cached_list(BLOCKED_DOMAINS_URL)[0]:
                info['lists_missing'] = 1   # JSON subscription works without them until the next refresh
        custom = _custom(st)
        prof, info['happ_dropped'] = _happ_profile(st, custom)
        link = _happ_link(prof)
        allset.update(subEnableRouting=True, subRoutingRules=link, subIncyEnableRouting=True, subIncyRoutingRules=link,
                      subJsonRoutingRules=json.dumps(_json_spec(st, custom), ensure_ascii=False, separators=(',', ':')),
                      subClashEnableRouting=True, subClashRules=_clash_yaml(st, custom))
    _save_settings(allset)
    return info


def cmd_routing_show(args):
    st = routing_load()
    print('mode=%s' % st['mode'])
    print('custom=%d' % len(st['custom']))


def cmd_routing_text(args):
    st = routing_load()
    mode = st['mode']
    out('Режим:        ' + c('dim' if mode == 'off' else 'green', ROUTING_MODES[mode]))
    n = len(st['custom'])
    out('Свои правила: %s' % (c('bold', str(n)) if n else c('dim', 'нет')))


def cmd_routing_mode(args):
    mode = args[0]
    if mode == 'blocked-vpn':
        mode = 'blocked-proxy'
    if mode not in ROUTING_MODES:
        die('режим: off | ru-direct | blocked-proxy')
    st = routing_load()
    st['mode'] = mode
    info = routing_apply(st)
    routing_save(st)
    print('ok')
    if info.get('happ_dropped'):
        print('happ_dropped=%d' % info['happ_dropped'])
    if info.get('lists_missing'):
        print('lists_missing=1')


def cmd_routing_add(args):
    """routing-add direct|proxy domains ITEMS… | routing-add direct|proxy url URL"""
    action, kind = args[0], args[1]
    if action == 'vpn':
        action = 'proxy'
    if action not in ('direct', 'proxy'):
        die('действие: direct | proxy')
    st = routing_load()
    if kind == 'url':
        url = args[2].strip()
        if not re.match(r'^https?://', url):
            die('нужна ссылка http(s)://…')
        if any(r.get('url') == url for r in st['custom']):
            die('этот список уже добавлен')
        domains, ips = fetch_list(url)
        rule = {'type': 'url', 'url': url, 'action': action, 'count': len(domains) + len(ips),
                'updated': int(time.time())}
    else:
        items = [x for a in args[2:] for x in re.split(r'[\s,;]+', a) if x]
        domains, ips = parse_entries('\n'.join(items))
        if not domains and not ips:
            die('не найдено ни одного домена или IP')
        rule = {'type': 'domains', 'items': [d[len('domain:'):] if d.startswith('domain:') else d for d in domains] + ips,
                'action': action}
    st['custom'].append(rule)
    info = routing_apply(st)
    routing_save(st)
    print('count=%d' % (len(domains) + len(ips)))
    if info.get('happ_dropped'):
        print('happ_dropped=%d' % info['happ_dropped'])
    if info.get('lists_missing'):
        print('lists_missing=1')


def cmd_routing_rules(args):
    st = routing_load()
    for i, r in enumerate(st['custom']):
        act = c('green', 'напрямую') if r.get('action') == 'direct' else c('accent', 'через сервер')
        if r.get('type') == 'url':
            what = r['url']
            if len(what) > 52:
                what = what[:30] + '…' + what[-20:]
            info = '%s · %d записей' % (what, r.get('count', 0))
        else:
            items = r.get('items') or []
            info = ', '.join(items[:3]) + (' и ещё %d' % (len(items) - 3) if len(items) > 3 else '')
        out('%d\t%s\t%s' % (i, act, info))


def cmd_routing_rule(args):
    """routing-rule N del|direct|proxy|refresh"""
    i, op = int(args[0]), args[1]
    if op == 'vpn':
        op = 'proxy'
    st = routing_load()
    if not 0 <= i < len(st['custom']):
        die('нет правила %d' % i)
    r = st['custom'][i]
    if op == 'del':
        st['custom'].pop(i)
        if r.get('type') == 'url':
            try:
                os.remove(_list_path(r['url']))
            except OSError:
                pass
    elif op in ('direct', 'proxy'):
        r['action'] = op
    elif op == 'refresh' and r.get('type') == 'url':
        domains, ips = fetch_list(r['url'])
        r['count'] = len(domains) + len(ips)
        r['updated'] = int(time.time())
    routing_apply(st)
    routing_save(st)


def cmd_routing_refresh(args):
    """Timer: re-download lists; re-apply only when something changed."""
    st = routing_load()
    if st['mode'] == 'off' and not st['custom']:
        return
    urls = [r['url'] for r in st['custom'] if r.get('type') == 'url']
    if st['mode'] != 'off':
        urls += [BLOCKED_DOMAINS_URL] + BLOCKED_SUBNET_URLS
    changed = False
    for u in urls:
        before = cached_list(u)
        try:
            after = fetch_list(u)
        except (Exception, SystemExit) as e:
            sys.stderr.write('routing: не удалось скачать %s: %s\n' % (u, e))
            continue
        changed = changed or after != before
        for r in st['custom']:
            if r.get('url') == u:
                r['count'] = len(after[0]) + len(after[1])
                r['updated'] = int(time.time())
    routing_save(st)
    if changed:
        routing_apply(st)
        routing_save(st)
        print('обновлено')


def cmd_routing_legacy_cleanup(args):
    """v2.6.0 put routing into the server's Xray (rules "3xr-…", outbound 3xr-vpn): remove it."""
    try:
        with open(ROUTING_FILE) as fh:
            raw = json.load(fh)
    except (OSError, ValueError):
        return
    if 'vpn' not in raw:
        return
    tpl = get_template()
    prev = json.loads(json.dumps(tpl))
    routing = tpl.get('routing') or {}
    rules = [r for r in routing.get('rules') or [] if not str(r.get('ruleTag', '')).startswith('3xr-')]
    changed = len(rules) != len(routing.get('rules') or [])
    routing['rules'] = rules
    used = {r.get('outboundTag') for r in rules}
    outs = tpl.get('outbounds') or []
    if any(o.get('tag') == '3xr-vpn' for o in outs) and '3xr-vpn' not in used:
        tpl['outbounds'] = [o for o in outs if o.get('tag') != '3xr-vpn']
        changed = True
    if changed:
        put_template(tpl, prev)
    raw.pop('vpn', None)
    raw['mode'] = 'off'                     # the server-side mode has no client equivalent to assume
    routing_save(raw)
    print('cleaned' if changed else 'ok')


# ------------------------------------------------------------------ migration
# Reads an existing 3x-ui database directly (sqlite3, read-only): the panel may
# be stopped and has no API token for us yet.
XUI_DEFAULTS = {'webPort': '2053', 'webBasePath': '/', 'webListen': '', 'webDomain': '', 'webCertFile': '',
                'subEnable': 'true', 'subListen': '', 'subPort': '2096', 'subPath': '/sub/', 'subDomain': '',
                'subCertFile': '', 'subURI': '', 'subJsonEnable': 'false', 'subJsonPath': '/json/',
                'subClashEnable': 'false', 'subClashPath': '/clash/', 'twoFactorEnable': 'false'}


def cmd_migrate_scan(args):
    import sqlite3
    db = args[0]
    con = sqlite3.connect('file:%s?mode=ro' % db, uri=True, timeout=10)
    try:
        st = dict(XUI_DEFAULTS)
        try:
            for k, v in con.execute('SELECT key, value FROM settings'):
                if k in st and v is not None:
                    st[k] = v
        except sqlite3.Error as e:
            die('не удалось прочитать настройки 3x-ui: %s' % e)
        for k, v in st.items():
            print('%s=%s' % (k, str(v).replace('\n', ' ')))
        try:
            row = con.execute('SELECT username FROM users ORDER BY id LIMIT 1').fetchone()
            print('username=%s' % (row[0] if row else ''))
        except sqlite3.Error:
            print('username=')
        try:
            rows = con.execute('SELECT id, port, protocol, listen, remark, stream_settings, enable FROM inbounds').fetchall()
        except sqlite3.Error:
            rows = []
        for ib_id, port, proto, listen, remark, ss_raw, enable in rows:
            ss = jload(ss_raw, {})
            sec = ss.get('security') or 'none'
            net = ss.get('network') or 'tcp'
            transport = 'udp' if proto in ('wireguard', 'amneziawg', 'hysteria') or net in ('kcp', 'hysteria') else 'tcp'
            crt, sni = '', ''
            if sec == 'tls':
                t = ss.get('tlsSettings') or {}
                sni = t.get('serverName') or ''
                certs = t.get('certificates') or [{}]
                crt = (certs[0] or {}).get('certificateFile') or ''
            print('INB\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' % (ib_id, port, transport, proto, listen or '', sec,
                                                            crt, sni, 1 if enable else 0) + '\t' + (remark or '').replace('\t', ' '))
    finally:
        con.close()


def cmd_panel_login(args):
    """panel-login URL USER — password on stdin; exit 0 if the panel accepts it."""
    import urllib.request
    import http.cookiejar
    base, user = args[0].rstrip('/'), args[1]
    password = sys.stdin.readline().rstrip('\n')
    ctx = ssl.create_default_context()
    ctx.check_hostname = False              # localhost with the domain's certificate
    ctx.verify_mode = ssl.CERT_NONE
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
                                         urllib.request.HTTPSHandler(context=ctx),
                                         urllib.request.ProxyHandler({}))
    headers = {'Content-Type': 'application/x-www-form-urlencoded', 'X-Requested-With': 'XMLHttpRequest'}
    try:                                    # 3x-ui 3.x: session-bound CSRF token
        with opener.open(base + '/csrf-token', timeout=15) as r:
            tok = (json.loads(r.read() or b'{}') or {}).get('obj')
        if tok:
            headers['X-CSRF-Token'] = tok
    except Exception:
        pass                                # older panels have no CSRF endpoint
    body = urllib.parse.urlencode({'username': user, 'password': password}).encode()
    try:
        with opener.open(urllib.request.Request(base + '/login', data=body, headers=headers), timeout=15) as r:
            reply = json.loads(r.read() or b'{}')
    except Exception as e:
        die('панель не ответила: %s' % (e or type(e).__name__), 3)   # 3: unknown, not "wrong password"
    sys.exit(0 if reply.get('success') else 1)


def cmd_panel_user(args):
    """panel-user DB — login name and 2FA flag stored in the panel database."""
    import sqlite3
    con = sqlite3.connect('file:%s?mode=ro' % args[0], uri=True, timeout=10)
    try:
        row = con.execute('SELECT username FROM users ORDER BY id LIMIT 1').fetchone()
        tfa = con.execute("SELECT value FROM settings WHERE key = 'twoFactorEnable'").fetchone()
    finally:
        con.close()
    print('user=%s' % (row[0] if row else ''))
    print('2fa=%s' % ('1' if tfa and str(tfa[0]).lower() == 'true' else '0'))


def cmd_tls_inbounds_for(args):
    """IDs of TLS inbounds that use DOMAIN (SNI or certificate path) but not CERTDIR."""
    domain, certdir = args[0].lower(), args[1]
    for ib in inbounds():
        ss = stream(ib)
        if ss.get('security') != 'tls':
            continue
        t = ss.get('tlsSettings') or {}
        crt = ((t.get('certificates') or [{}])[0] or {}).get('certificateFile') or ''
        if crt.startswith(certdir):
            continue
        if (t.get('serverName') or '').lower() == domain or domain in crt.lower():
            print(ib['id'])


# ------------------------------------------------------------------ sites & services behind Caddy
# The script owns only its own Caddyfile. Everything the user adds lives in
# $BASE/caddy: root.caddy (what serves the domain root instead of the stub)
# and sites/*.caddy (other domains). Those files are imported and never rewritten.
WEB_MARK = '# 3x-ui_reverse:'


def _caddy_tokens(text):
    """Caddyfile tokens with (start, end, line): quotes, backticks, comments, heredocs."""
    toks, i, n, line = [], 0, len(text), 1
    while i < n:
        ch = text[i]
        if ch == '\n':
            line += 1
            i += 1
            continue
        if ch in ' \t\r':
            i += 1
            continue
        if ch == '#':
            while i < n and text[i] != '\n':
                i += 1
            continue
        start = i
        if text.startswith('<<', i) and re.match(r'<<[A-Za-z0-9_]+\s*\n', text[i:]):
            m = re.match(r'<<([A-Za-z0-9_]+)', text[i:])
            end_m = re.compile(r'^\s*%s\s*$' % re.escape(m.group(1)), re.M).search(text, i + m.end())
            j = end_m.end() if end_m else n
            line += text.count('\n', i, j)
            toks.append((start, j, line, text[i:j]))
            i = j
            continue
        while i < n and text[i] not in ' \t\r\n':
            if text[i] == '"':
                i += 1
                while i < n and text[i] != '"':
                    if text[i] == '\\':
                        i += 1
                    elif text[i] == '\n':
                        line += 1
                    i += 1
                i += 1
            elif text[i] == '`':
                j = text.find('`', i + 1)
                j = n if j < 0 else j
                line += text.count('\n', i, j)
                i = j + 1
            else:
                i += 1
        toks.append((start, i, line, text[start:i]))
    return toks


def caddy_blocks(text):
    """Top-level entries of a Caddyfile:
    [{'kind': 'global'|'snippet'|'site'|'line', 'keys': [...], 'text': ..., 'body': ...}]"""
    toks = _caddy_tokens(text)
    out, k = [], 0
    while k < len(toks):
        line = toks[k][2]
        head = []
        while k < len(toks) and toks[k][2] == line and toks[k][3] != '{':
            head.append(toks[k])
            k += 1
        if k < len(toks) and toks[k][3] == '{' and toks[k][2] == line:
            depth, j = 0, k
            while j < len(toks):
                if toks[j][3] == '{':
                    depth += 1
                elif toks[j][3] == '}':
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            start = head[0][0] if head else toks[k][0]
            end = toks[j][1] if j < len(toks) else len(text)
            keys = [t[3].rstrip(',') for t in head]
            body = text[toks[k][1]:toks[j][0]] if j < len(toks) else text[toks[k][1]:]
            kind = 'global' if not keys else ('snippet' if keys[0].startswith('(') or keys[0].startswith('&(') else 'site')
            out.append({'kind': kind, 'keys': [x for x in keys if x], 'text': text[start:end], 'body': body})
            k = j + 1
        elif head:
            out.append({'kind': 'line', 'keys': [t[3] for t in head], 'text': text[head[0][0]:head[-1][1]], 'body': ''})
    # Single-site Caddyfile without braces: "domain\n directives…"
    if out and all(b['kind'] == 'line' for b in out if b['kind'] != 'global'):
        lines = [b for b in out if b['kind'] == 'line']
        if lines and not lines[0]['keys'][0] in ('import',):
            g = [b for b in out if b['kind'] == 'global']
            body = '\n'.join('    ' + b['text'] for b in lines[1:])
            site = {'kind': 'site', 'keys': [x.rstrip(',') for x in lines[0]['keys']],
                    'text': '%s {\n%s\n}' % (' '.join(lines[0]['keys']), body), 'body': body}
            return g + [site]
    return out


def _site_host(addr):
    a = re.sub(r'^[a-z]+://', '', addr.lower())
    return a.split('/')[0].rsplit(':', 1)[0] if not a.startswith('[') else a


def _safe_name(addr):
    return re.sub(r'[^a-z0-9.-]+', '_', _site_host(addr) or 'site').strip('._') or 'site'


# --------------------------------------------------------------- docker
def _docker_json(args):
    import subprocess
    try:
        r = subprocess.run(['docker'] + args, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0:
        return None
    return r.stdout


def docker_containers(all_=False):
    """[{name, names(set), image, running, ports: {'3000/tcp': [(hostip, hostport)]}, ips, hostnet, mounts}]"""
    ids = _docker_json(['ps', '-q'] + (['-a'] if all_ else []))
    if not ids or not ids.split():
        return []
    raw = _docker_json(['inspect'] + ids.split())
    try:
        data = json.loads(raw or '[]')
    except ValueError:
        return []
    out = []
    for c in data:
        cfg, ns, hc = c.get('Config') or {}, c.get('NetworkSettings') or {}, c.get('HostConfig') or {}
        name = (c.get('Name') or '').lstrip('/')
        names = {name, cfg.get('Hostname') or ''}
        labels = cfg.get('Labels') or {}
        if labels.get('com.docker.compose.service'):
            names.add(labels['com.docker.compose.service'])
        ips = []
        for net in (ns.get('Networks') or {}).values():
            names.update(net.get('Aliases') or [])
            names.update(net.get('DNSNames') or [])
            if net.get('IPAddress'):
                ips.append(net['IPAddress'])
        ports = {}
        for p, binds in (ns.get('Ports') or {}).items():
            ports[p] = [(b.get('HostIp') or '', b.get('HostPort') or '') for b in (binds or [])]
        for p in (cfg.get('ExposedPorts') or {}):
            ports.setdefault(p, [])
        out.append({'name': name, 'names': {x for x in names if x}, 'image': cfg.get('Image') or '',
                    'running': bool((c.get('State') or {}).get('Running')), 'ports': ports, 'ips': ips,
                    'hostnet': hc.get('NetworkMode') == 'host', 'mounts': c.get('Mounts') or []})
    return out


def docker_upstream(c, port):
    """Best address for Caddy on the host to reach container port PORT: (addr, flag).
    flag: ok — published on 127.0.0.1; exposed — published on all interfaces (reachable
    from the internet past Caddy and the firewall); ip — not published, container IP
    (changes when the container is recreated)."""
    if c['hostnet']:
        return '127.0.0.1:%s' % port, 'ok'
    binds = c['ports'].get('%s/tcp' % port) or []
    for hip, hport in binds:
        if hip in ('127.0.0.1', '::1') and hport:
            return '127.0.0.1:%s' % hport, 'ok'
    for hip, hport in binds:
        if hport:
            return '127.0.0.1:%s' % hport, 'exposed'
    if c['ips']:
        return '%s:%s' % (c['ips'][0], port), 'ip'
    return '', 'none'


def cmd_web_docker(args):
    """Running containers for the TUI: NAME \\t IMAGE \\t PORTS-SUMMARY, then
    PORT lines: '  NAME \\t CPORT \\t UPSTREAM \\t FLAG'."""
    if _docker_json(['version', '--format', '{{.Server.Version}}']) is None:
        print('nodocker')
        return
    for c in sorted(docker_containers(), key=lambda x: x['name']):
        tcp = sorted({int(p.split('/')[0]) for p in c['ports'] if p.endswith('/tcp')})
        if c['hostnet'] and not tcp:
            tcp = []
        summary = []
        for p in tcp:
            binds = c['ports'].get('%d/tcp' % p) or []
            if binds:
                summary.append(','.join('%s:%s→%d' % (h or '*', hp, p) for h, hp in binds))
            else:
                summary.append('%d (не опубликован)' % p)
        print('C\t%s\t%s\t%s\t%s' % (c['name'], c['image'], '; '.join(summary) or ('сеть хоста' if c['hostnet'] else 'нет портов'),
                                     'host' if c['hostnet'] else ''))
        for p in tcp:
            up, flag = docker_upstream(c, p)
            print('P\t%s\t%d\t%s\t%s' % (c['name'], p, up, flag))


def cmd_web_caddyfiles(args):
    """Caddyfiles of Caddy containers (running or stopped): candidates to import."""
    seen = set()
    for c in docker_containers(all_=True):
        if 'caddy' not in (c['image'] + ' ' + c['name']).lower():
            continue
        for m in c['mounts']:
            src, dst = m.get('Source') or '', m.get('Destination') or ''
            if not src:
                continue
            cand = []
            if dst.endswith('/Caddyfile'):
                cand.append(src)
            elif dst.rstrip('/') in ('/etc/caddy', '/config', '/srv'):
                cand.append(os.path.join(src, 'Caddyfile'))
            for f in cand:
                if os.path.isfile(f) and f not in seen:
                    seen.add(f)
                    print('%s\t%s%s' % (f, c['name'], '' if not c['running'] else ' (запущен)'))


def _rewrite_upstreams(text, containers, report):
    """Container names in reverse_proxy/to lines → addresses reachable from the host."""
    def fix(tok):
        if len(tok) > 2 and tok[0] == tok[-1] and tok[0] in '"`':
            inner = fix(tok[1:-1])
            return tok if inner == tok[1:-1] else tok[0] + inner + tok[-1]
        m = re.match(r'^(https?://|h2c://)?([A-Za-z0-9_.-]+)(?::(\d+))?$', tok)
        if not m:
            return tok
        scheme, host, port = m.group(1) or '', m.group(2), m.group(3)
        if host in ('localhost', '127.0.0.1') or re.match(r'^\d+\.\d+\.\d+\.\d+$', host):
            return tok
        if host == 'host.docker.internal':
            new = '%s127.0.0.1%s' % (scheme, ':' + port if port else '')
            report.append((tok, new, 'ok'))
            return new
        port = port or ('443' if scheme == 'https://' else '80')
        for c in containers:
            if host in c['names']:
                up, flag = docker_upstream(c, port)
                if up:
                    new = scheme + up
                    report.append((tok, new, flag))
                    return new
        if '.' not in host:
            report.append((tok, tok, 'unknown'))
        return tok

    out = []
    for ln in text.split('\n'):
        m = re.match(r'^(\s*)(reverse_proxy|to)(\s+)(.*)$', ln)
        if m:
            parts = m.group(4).split(' ')
            new = []
            for p in parts:
                if p and p not in ('{',) and not p.startswith(('@', '/', '*', '{', '#')):
                    p = fix(p)
                new.append(p)
            ln = m.group(1) + m.group(2) + m.group(3) + ' '.join(new)
        out.append(ln)
    return '\n'.join(out)


CADDY_LOG_DIR = '/var/log/caddy'


def _rewrite_paths(text, mounts, report):
    """Paths inside the Caddy container → paths on the host.
    Log files go to /var/log/caddy (writable by the caddy service user);
    'root' directories follow the container's bind mounts."""
    def host_path(p):
        best = None
        for m in mounts:
            dst, src = (m.get('Destination') or '').rstrip('/'), m.get('Source') or ''
            if dst and src and (p == dst or p.startswith(dst + '/')) and (best is None or len(dst) > len(best[0])):
                best = (dst, src)
        return best[1] + p[len(best[0]):] if best else None

    out = []
    for ln in text.split('\n'):
        m = re.match(r'^(\s*output\s+file\s+)("?)(/[^\s"{]+)("?)(.*)$', ln)
        if m and not m.group(3).startswith(CADDY_LOG_DIR + '/'):
            new = '%s/%s' % (CADDY_LOG_DIR, os.path.basename(m.group(3)))
            report.append((m.group(3), new, 'log'))
            ln = m.group(1) + m.group(2) + new + m.group(4) + m.group(5)
        m = re.match(r'^(\s*root\s+(?:\*\s+|@\S+\s+|/\S*\s+)?)(/[^\s{]+)(.*)$', ln)
        if m and not os.path.isdir(m.group(2)):
            hp = host_path(m.group(2))
            if hp:
                report.append((m.group(2), hp, 'path' if os.path.isdir(hp) else 'nopath'))
                ln = m.group(1) + hp + m.group(3)
        out.append(ln)
    return '\n'.join(out)


def _root_upstreams(body):
    """Upstreams that serve 'everything else' in a site block: reverse_proxy outside
    any handle/route with a matcher (the panel and subscription handles are skipped)."""
    ups, stack = [], []
    for raw in body.split('\n'):
        ln = raw.split('#', 1)[0].strip()
        if not ln:
            continue
        if ln == '}':
            if stack:
                stack.pop()
            continue
        words = ln.split()
        matched = len(words) > 1 and words[1] not in ('{',) and (words[1].startswith(('@', '/', '*')))
        if words[0] == 'reverse_proxy' and not any(stack) and not matched:
            for p in words[1:]:
                if p == '{' or p.startswith(('@', '/', '*', '{', '#')):
                    continue
                ups.append(p.strip('"`'))
        if ln.endswith('{'):
            stack.append(words[0] in ('handle', 'route', 'handle_path', 'redir') and matched
                         or words[0] in ('handle_path', 'handle_errors') or words[0].startswith('@'))
    return ups


def _main_upstreams(body):
    ups = []
    for ln in body.split('\n'):
        m = re.match(r'^\s*reverse_proxy\s+(.*)$', ln)
        if m:
            for p in m.group(1).split():
                if p != '{' and not p.startswith(('@', '/', '*', '{', '#')):
                    ups.append(p.strip('"`'))
    return ups


def cmd_caddy_split(args):
    """caddy-split FILE DOMAIN OUTDIR [--docker] [--source NAME]
    Moves site blocks of other domains (and snippets) from FILE into OUTDIR/*.caddy.
    Blocks of DOMAIN and the script's own redirect are skipped; their upstreams are
    reported as 'main' (candidates for the domain root)."""
    path, domain, outdir = args[0], args[1].lower(), args[2]
    docker = '--docker' in args
    src_name = args[args.index('--source') + 1] if '--source' in args else path
    try:
        with open(path, encoding='utf-8', errors='replace') as fh:
            text = fh.read()
    except OSError as e:
        die('не удалось прочитать %s: %s' % (path, e))
    blocks = caddy_blocks(text)
    containers = docker_containers(all_=True) if docker else []
    mounts = []
    if docker:
        real = os.path.realpath(path)
        for c in containers:
            for m in c['mounts']:
                src = m.get('Source') or ''
                if src and (real == os.path.realpath(src) or real.startswith(os.path.realpath(src).rstrip('/') + '/')):
                    mounts = c['mounts']
        containers = [c for c in containers if c['running']] or containers
    report, moved, mains, skipped = [], [], [], []
    os.makedirs(outdir, mode=0o755, exist_ok=True)
    existing = set()
    for f in os.listdir(outdir):
        if f.endswith('.caddy'):
            try:
                for b in caddy_blocks(open(os.path.join(outdir, f), encoding='utf-8', errors='replace').read()):
                    if b['kind'] == 'site':
                        existing.update(_site_host(k) for k in b['keys'])
            except OSError:
                pass
    stamp = time.strftime('%Y-%m-%d %H:%M')
    snippets = []
    for b in blocks:
        if b['kind'] == 'global':
            rest = []
            for ln in b['body'].split('\n'):
                w = ln.split('#', 1)[0].split()
                if len(w) == 2 and w[0] == 'email' and '@' in w[1]:
                    print('email\t%s' % w[1])
                elif w and w[0] != 'storage':
                    rest.append(ln.strip())
            if rest:
                skipped.append('глобальные опции: %s' % '; '.join(rest)[:120])
            continue
        if b['kind'] == 'line' and b['keys'][:1] == ['import'] and len(b['keys']) > 1 and \
                os.path.abspath(os.path.dirname(b['keys'][1].strip('"'))) == os.path.abspath(outdir):
            continue                                    # the script's own import of OUTDIR
        if b['kind'] in ('snippet', 'line'):
            snippets.append(b['text'])
            continue
        hosts = [_site_host(k) for k in b['keys']]
        if domain in hosts or any(h in ('', ) for h in hosts):
            mains.extend(_root_upstreams(b['body']))
            continue
        if all(h in existing for h in hosts):
            skipped.append('%s (уже есть)' % ' '.join(b['keys']))
            continue
        body = _rewrite_upstreams(b['text'], containers, report) if docker else b['text']
        body = _rewrite_paths(body, mounts, report) if docker else body
        name = _safe_name(b['keys'][0])
        fn = os.path.join(outdir, name + '.caddy')
        i = 2
        while os.path.exists(fn):
            fn = os.path.join(outdir, '%s-%d.caddy' % (name, i))
            i += 1
        with open(fn, 'w') as fh:
            fh.write('%s imported from=%s date=%s\n%s\n' % (WEB_MARK, src_name, stamp, body.strip()))
        os.chmod(fn, 0o644)
        existing.update(hosts)
        moved.append((' '.join(b['keys']), os.path.basename(fn)))
    if snippets:
        body = '\n\n'.join(snippets)
        body = _rewrite_upstreams(body, containers, report) if docker else body
        body = _rewrite_paths(body, mounts, report) if docker else body
        fn = os.path.join(outdir, '00-snippets.caddy')
        with open(fn, 'a') as fh:
            fh.write('%s imported from=%s date=%s\n%s\n\n' % (WEB_MARK, src_name, stamp, body.strip()))
        os.chmod(fn, 0o644)
        moved.append(('сниппеты и import', os.path.basename(fn)))
    for site, fn in moved:
        print('moved\t%s\t%s' % (site, fn))
    for up in mains:
        if docker:
            r = []
            new = _rewrite_upstreams('reverse_proxy ' + up, containers, r).split(' ', 1)[1]
            print('main\t%s\t%s\t%s' % (up, new, r[0][2] if r else 'ok'))
        else:
            print('main\t%s\t%s\tok' % (up, up))
    for old, new, flag in report:
        print('map\t%s\t%s\t%s' % (old, new, flag))
    for s in skipped:
        print('skipped\t%s' % s)


def _web_meta(text):
    m = re.search(r'^%s(.*)$' % re.escape(WEB_MARK), text, re.M)
    meta = {}
    if m:
        for kv in m.group(1).split():
            if '=' in kv:
                k, v = kv.split('=', 1)
                meta[k] = v
    return meta


def cmd_web_sites(args):
    """web-sites DIR — ROOT/SITE lines for the menu:
    ROOT \\t stub|service \\t upstream \\t service-name
    SITE \\t file \\t domains \\t upstreams \\t service-name"""
    d = args[0]
    root = os.path.join(d, 'root.caddy')
    if os.path.isfile(root):
        text = open(root, encoding='utf-8', errors='replace').read()
        meta = _web_meta(text)
        print('ROOT\tservice\t%s\t%s' % (', '.join(_main_upstreams(text)) or 'свои директивы', meta.get('service', '')))
    else:
        print('ROOT\tstub\t\t')
    sd = os.path.join(d, 'sites')
    for f in sorted(os.listdir(sd)) if os.path.isdir(sd) else []:
        if not f.endswith('.caddy'):
            continue
        try:
            text = open(os.path.join(sd, f), encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        meta = _web_meta(text)
        sites = [b for b in caddy_blocks(text) if b['kind'] == 'site']
        doms = ' '.join(k for b in sites for k in b['keys']) or '—'
        ups = ', '.join(u for b in sites for u in _main_upstreams(b['body']))
        if not sites:
            doms = 'сниппеты' if f.startswith('00-') else '—'
        print('SITE\t%s\t%s\t%s\t%s' % (f, doms, ups or '—', meta.get('service', '')))


def cmd_web_hosts(args):
    """Domains served by the files in DIR/sites (one per line)."""
    sd = os.path.join(args[0], 'sites')
    for f in sorted(os.listdir(sd)) if os.path.isdir(sd) else []:
        if f.endswith('.caddy'):
            try:
                text = open(os.path.join(sd, f), encoding='utf-8', errors='replace').read()
            except OSError:
                continue
            for b in caddy_blocks(text):
                if b['kind'] == 'site':
                    for k in b['keys']:
                        print('%s\t%s' % (_site_host(k), f))


# ------------------------------------------------------------------ bulk inbound actions
# Names "like the script makes them": {flag} {country} {type}. The country is the
# country of the server the inbound runs on (this server or a node).
PROTO_LABEL = {'vless': 'VLESS', 'vmess': 'VMess', 'trojan': 'Trojan', 'shadowsocks': 'Shadowsocks',
               'hysteria': 'Hysteria2', 'hysteria2': 'Hysteria2', 'tuic': 'TUIC', 'amneziawg': 'AmneziaWG',
               'wireguard': 'WireGuard', 'mtproto': 'MTProto', 'http': 'HTTP', 'socks': 'SOCKS',
               'mixed': 'SOCKS', 'masque': 'MASQUE', 'tunnel': 'Tunnel', 'dokodemo-door': 'Tunnel'}
NO_NET_PROTOCOLS = UDP_PROTOCOLS | {'mtproto', 'http', 'socks', 'mixed', 'tunnel', 'dokodemo-door'}


def type_label(ib):
    """'VLESS TCP Reality' — the catalog label, or one built the same way."""
    k = classify(ib)
    if k:
        return KIND[k]['label']
    proto = ib.get('protocol') or '?'
    parts = [PROTO_LABEL.get(proto, proto.upper())]
    ss = stream(ib)
    net = ss.get('network') or ''
    if net and proto not in NO_NET_PROTOCOLS:
        parts.append(NET_NAMES.get(net, net.upper()))
    sec = ss.get('security') or ''
    if sec in ('reality', 'tls'):
        parts.append({'reality': 'Reality', 'tls': 'TLS'}[sec])
    return ' '.join(parts)


def server_codes(ibs):
    """{inbound id: ISO code of the server it runs on}."""
    me = country_iso()
    cache = {}
    out = {}
    for ib in ibs:
        nid = ib.get('nodeId')
        if not nid:
            out[ib['id']] = me
            continue
        if nid not in cache:
            cache[nid] = node_country(nid, ibs)
        out[ib['id']] = cache[nid]
    return out


def rename_plan(ibs, ids):
    """[(inbound, new name)] for IDS; names stay unique panel-wide."""
    codes = server_codes(ibs)
    chosen = [ib for ib in sorted(ibs, key=lambda x: x['id']) if ib['id'] in ids]
    used = {(ib.get('remark') or '').strip().lower() for ib in ibs if ib['id'] not in ids}
    plan = []
    for ib in chosen:
        base = ('%s %s' % (country_prefix(codes[ib['id']]) if codes[ib['id']] else '', type_label(ib))).strip()
        name, n = base, 2
        while name.lower() in used:
            name = '%s %d' % (base, n)
            n += 1
        used.add(name.lower())
        plan.append((ib, name))
    return plan


def _ids_arg(args, ibs):
    if not args or not args[0]:
        die('не выбраны inbound-ы')
    return set(parse_ids(args[0], ibs))


def cmd_inbounds_rename_plan(args):
    """inbounds-rename-plan IDS — 'old → new' lines for the preview."""
    ibs = inbounds()
    locs = inbound_locations(ibs)
    plan = rename_plan(ibs, _ids_arg(args, ibs))
    same = 0
    for ib, new in plan:
        old = ib.get('remark') or ''
        if old == new:
            same += 1
            continue
        where = (' {dim}· %s{/}' % locs[ib['id']][1]) if locs else ''
        out('  %s{dim} → {/}{bold}%s{/}%s' % (old or '—', new, where))
    if same:
        out('{dim}  Уже в нужном виде: %d{/}' % same)
    print('CHANGES=%d' % (len(plan) - same))


def cmd_inbounds_rename(args):
    """inbounds-rename IDS — rename to '{flag} {country} {type}'; prints the count."""
    ibs = inbounds()
    n = 0
    for ib, new in rename_plan(ibs, _ids_arg(args, ibs)):
        if (ib.get('remark') or '') != new:
            ib['remark'] = new
            save_inbound(ib)
            n += 1
    print(n)


def cmd_inbounds_bulk(args):
    """inbounds-bulk delete|enable|disable IDS — prints the count."""
    action = args[0] if args else ''
    if action not in ('delete', 'enable', 'disable'):
        die('действие: delete | enable | disable')
    ibs = inbounds()
    ids = _ids_arg(args[1:], ibs)
    n = 0
    for ib in sorted(ibs, key=lambda x: x['id']):
        if ib['id'] not in ids:
            continue
        if action == 'delete':
            ok(call('/inbounds/del/%d' % ib['id'], {}), 'удаление «%s»' % (ib.get('remark') or ib['id']))
            register([ib['id']], remove=True)
        else:
            want = action == 'enable'
            if bool(ib.get('enable')) == want:
                continue
            ok(call('/inbounds/setEnable/%d' % ib['id'], {'enable': want}), 'включение «%s»' % ib.get('remark'))
        n += 1
    print(n)


def cmd_country_style(args):
    """country-style [full|code] — print or set how countries are written in names."""
    if args:
        if args[0] not in ('full', 'code'):
            die('country-style full | code')
        path = os.path.join(STATE_DIR, 'country-style')
        with open(path, 'w') as f:
            f.write(args[0] + '\n')
    print(country_style())


def cmd_inbounds_restyle(_args):
    """Rewrite the country of names that start with '{flag} {country} ' in the current style."""
    ibs = inbounds()
    n = 0
    for ib in ibs:
        remark = ib.get('remark') or ''
        code = flag_code(remark)
        if not code:
            continue
        rest = FLAG_RE.sub('', remark, count=1)
        for cur in (COUNTRY_EN.get(code, ''), code):
            if cur and rest.startswith(cur + ' '):
                new = '%s %s' % (country_prefix(code), rest[len(cur) + 1:])
                if new != remark and not name_taken(new, ibs, ib['id']):
                    ib['remark'] = new
                    save_inbound(ib)
                    n += 1
                break
    print(n)


def cmd_menu_servers(_args):
    """Where new inbounds can go: '0 <TAB> this server' and one line per node."""
    ibs = inbounds()
    me = country_iso()
    print('0\t%s\t{dim}этот сервер{/}' % ('%s %s' % (flag_emoji(me), country_label(me, country_name()))).strip())
    for nid, n in sorted(nodes_by_id().items()):
        code = node_country(nid, ibs)
        name = node_title(nid)
        label = name if flag_code(name) else ('%s %s' % (flag_emoji(code), name)).strip()
        state = '' if n.get('enable') else '  {red}выключен{/}'
        print('%s\t%s\t{dim}узел · %s%s{/}' % (nid, label, n.get('address') or '', state))


# ------------------------------------------------------------------ subscription page templates
# Templates for 3x-ui's own "Sub Theme Directory" (subThemeDir): every top-level
# folder of the repository with an index.html / sub.html is one style.
SUBPAGES_REPO = os.environ.get('XR_SUBPAGES_REPO', 'dohuyanevezuch/3x-ui_subpages')
CODELOAD = os.environ.get('XR_CODELOAD', 'https://codeload.github.com').rstrip('/')
SUBPAGE_NAME_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}')


def _subpage_ok(path):
    return any(os.path.isfile(os.path.join(path, f)) for f in ('index.html', 'sub.html'))


def cmd_subpages_sync(args):
    """subpages-sync DIR [REPO] — download the repository and refresh DIR/<style>/."""
    import io
    import shutil
    import tarfile
    import tempfile
    import urllib.request
    dest = args[0]
    repo = args[1] if len(args) > 1 and args[1] else SUBPAGES_REPO
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
        die('репозиторий указывается как owner/name')
    url = '%s/%s/tar.gz/HEAD' % (CODELOAD, repo)
    try:
        req = urllib.request.Request(url, headers={'User-Agent': '3x-ui_reverse'})
        with urllib.request.urlopen(req, timeout=60) as r:
            data = r.read((50 << 20) + 1)
    except Exception as e:
        die('не удалось скачать шаблоны с github.com/%s: %s' % (repo, e))
    if len(data) > 50 << 20:
        die('архив шаблонов больше 50 МБ')
    os.makedirs(dest, mode=0o755, exist_ok=True)
    work = tempfile.mkdtemp(prefix='.sync-', dir=dest)
    try:
        styles = {}
        total = 0
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as tar:
            for m in tar.getmembers():
                parts = m.name.split('/')
                # repo-<sha>/<style>/<file…>: regular files only, no tricks in names
                if len(parts) < 3 or not m.isfile() or any(p in ('', '.', '..') for p in parts):
                    continue
                style = parts[1]
                if not SUBPAGE_NAME_RE.fullmatch(style) or style.startswith('.'):
                    continue
                total += m.size
                if total > 50 << 20:
                    die('шаблоны больше 50 МБ')
                target = os.path.join(work, style, *parts[2:])
                os.makedirs(os.path.dirname(target), mode=0o755, exist_ok=True)
                src = tar.extractfile(m)
                with open(target, 'wb') as out_f:
                    shutil.copyfileobj(src, out_f)
                os.chmod(target, 0o644)
                styles[style] = True
        names = sorted(s for s in styles if _subpage_ok(os.path.join(work, s)))
        if not names:
            die('в github.com/%s нет папок с index.html' % repo)
        for name in names:
            final = os.path.join(dest, name)
            old = final + '.old'
            shutil.rmtree(old, ignore_errors=True)
            if os.path.isdir(final):
                os.rename(final, old)
            os.rename(os.path.join(work, name), final)
            os.chmod(final, 0o755)
            shutil.rmtree(old, ignore_errors=True)
        with open(os.path.join(dest, '.source'), 'w') as f:
            json.dump({'repo': repo, 'updated': int(time.time()), 'styles': names}, f)
        print(' '.join(names))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def _theme_dir():
    return (_settings().get('subThemeDir') or '').strip()


def cmd_subpages_list(args):
    """subpages-list DIR — 'CUR <TAB> path', then 'name <TAB> label' for the menu."""
    dest = args[0]
    cur = _theme_dir()
    print('CUR\t%s' % cur)
    try:
        src = json.load(open(os.path.join(dest, '.source')))
    except (OSError, ValueError):
        src = {}
    print('SRC\t%s\t%s' % (src.get('repo', ''), src.get('updated', 0)))
    for name in sorted(os.listdir(dest)) if os.path.isdir(dest) else []:
        path = os.path.join(dest, name)
        if name.startswith('.') or name.endswith('.old') or not os.path.isdir(path) or not _subpage_ok(path):
            continue
        size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(path) for f in fs)
        active = cur.rstrip('/') == path.rstrip('/')
        print('%s\t%s\t%s' % (name, '1' if active else '0', human(size)))


def cmd_subpage_set(args):
    """subpage-set DIR NAME|default — point 3x-ui's subscription page to DIR/NAME/."""
    dest, name = args[0], args[1]
    if name == 'default':
        value = ''
    else:
        if not SUBPAGE_NAME_RE.fullmatch(name):
            die('неверное имя шаблона')
        path = os.path.join(dest, name)
        if not _subpage_ok(path):
            die('шаблон %s не найден в %s' % (name, dest))
        value = path.rstrip('/') + '/'
    allset = _settings()
    if (allset.get('subThemeDir') or '') == value:
        print('unchanged')
        return
    allset['subThemeDir'] = value
    _save_settings(allset)
    print('ok')


# ------------------------------------------------------------ self-update
REPO_RE = re.compile(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+')
TAG_VER_RE = re.compile(r'v?\d+(\.\d+){0,3}')
GITHUB_API = os.environ.get('XR_GITHUB_API', 'https://api.github.com').rstrip('/')


def verkey(tag):
    return tuple(int(x) for x in re.findall(r'\d+', tag))


def cmd_update_check(args):
    """update-check REPO CURRENT -> "TAG SHORT_SHA newer|same|older"."""
    repo, current = args[0], args[1] if len(args) > 1 else 'v0'
    if not REPO_RE.fullmatch(repo):
        die('репозиторий указывается как owner/name')
    api = GITHUB_API + '/repos/' + repo
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


def cmd_update_notes(args):
    """update-notes REPO CURRENT TAG — what changed: the release text, else the commit
    messages between the two tags, else the message of the tag's commit."""
    repo, current, tag = args[0], args[1], args[2]
    if not REPO_RE.fullmatch(repo) or not TAG_VER_RE.fullmatch(tag):
        die('некорректный репозиторий или тег')
    api = GITHUB_API + '/repos/' + repo
    text = ''
    try:
        text = (json.loads(_fetch(api + '/releases/tags/' + tag, 10)).get('body') or '').strip()
    except Exception:
        pass
    if not text and TAG_VER_RE.fullmatch(current or ''):
        try:
            cmp_ = json.loads(_fetch('%s/compare/%s...%s' % (api, current, tag), 15))
            msgs = [(c.get('commit') or {}).get('message', '').strip() for c in cmp_.get('commits') or []]
            msgs = [m for m in reversed(msgs) if m]
            text = '\n'.join('• ' + m.split('\n')[0] + (
                ('\n' + '\n'.join('  ' + l for l in m.split('\n')[1:] if l.strip())) if len(msgs) == 1 else '')
                for m in msgs[:20])
        except Exception:
            pass
    if not text:
        try:
            text = ((json.loads(_fetch(api + '/commits/' + tag, 10)).get('commit') or {}).get('message') or '').strip()
        except Exception:
            pass
    text = re.sub(r'\{|\}', '', text)          # no markup from the outside
    print((text[:1800] + '\n…') if len(text) > 1800 else text)


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
    'country': cmd_country, 'nodes-status': cmd_nodes_status, 'access-log-ok': cmd_access_log_ok, 'inbounds-rename-plan': cmd_inbounds_rename_plan, 'inbounds-rename': cmd_inbounds_rename, 'inbounds-bulk': cmd_inbounds_bulk, 'country-style': cmd_country_style, 'inbounds-restyle': cmd_inbounds_restyle, 'menu-servers': cmd_menu_servers, 'panel-user': cmd_panel_user, 'web-docker': cmd_web_docker, 'web-caddyfiles': cmd_web_caddyfiles,
    'caddy-split': cmd_caddy_split, 'web-sites': cmd_web_sites, 'web-hosts': cmd_web_hosts, 'inbound-flags': cmd_inbound_flags, 'update-check': cmd_update_check, 'update-notes': cmd_update_notes, 'subpages-sync': cmd_subpages_sync, 'subpages-list': cmd_subpages_list, 'subpage-set': cmd_subpage_set, 'update-fetch': cmd_update_fetch,
    'dns-check': cmd_dns_check, 'public-ip': cmd_public_ip,
    'track-activity': cmd_track_activity, 'enable-access-log': cmd_enable_access_log,
    'node-token-create': cmd_node_token_create, 'node-token-check': cmd_node_token_check,
    'pair-publish': cmd_pair_publish, 'pair-fetch': cmd_pair_fetch, 'node-name': cmd_node_name,
    'parse-url': cmd_parse_url, 'node-add': cmd_node_add, 'nodes': cmd_nodes, 'nodes-count': cmd_nodes_count,
    'menu-nodes': cmd_menu_nodes, 'node-card': cmd_node_card, 'node-del': cmd_node_del,
    'node-enable': cmd_node_enable, 'node-probe': cmd_node_probe, 'pdf': cmd_pdf,
    'iperf-cities': cmd_iperf_cities, 'iperf-city': cmd_iperf_city, 'iperf-table': cmd_iperf_table,
    'ipregion-check': cmd_ipregion_check, 'ipregion-table': cmd_ipregion_table,
    'routing-show': cmd_routing_show, 'routing-text': cmd_routing_text, 'routing-mode': cmd_routing_mode,
    'routing-add': cmd_routing_add, 'routing-rules': cmd_routing_rules, 'routing-rule': cmd_routing_rule,
    'routing-refresh': cmd_routing_refresh, 'routing-legacy-cleanup': cmd_routing_legacy_cleanup,
    'migrate-scan': cmd_migrate_scan, 'panel-login': cmd_panel_login, 'tls-inbounds-for': cmd_tls_inbounds_for,
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
TAG_RE = re.compile(r'\{(/|green|red|yellow|orange|accent|cyan|blue|magenta|dim|bold|white|track)\}')
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
            for k in ('text', 'accent', 'green', 'red', 'yellow', 'orange', 'cyan', 'blue', 'magenta',
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
            'orange': pair(208 if rich else 3) | (0 if rich else B),
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
ANSI = {'green': '32', 'red': '31', 'yellow': '33', 'orange': '38;5;208', 'accent': '36;1', 'cyan': '36', 'blue': '34',
        'magenta': '35', 'dim': '90', 'bold': '1', 'white': '97;1', 'track': '38;5;238'}


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

# Cached result: "EPOCH TAG SHA newer|same|older" (refreshed at most daily).
update_cached(){
  local epoch tag sha rel
  [[ -r "$BASE/update-check" ]] || return 1
  read -r epoch tag sha rel < "$BASE/update-check" || return 1
  [[ "$epoch" =~ ^[0-9]+$ && -n "$tag" ]] || return 1
  printf '%s %s %s %s' "$epoch" "$tag" "$sha" "$rel"
}
update_check_now(){
  local repo out
  repo=$(update_repo)
  [[ -n "$repo" ]] || return 1
  out=$(helper update-check "$repo" "$VERSION" 2>&1) || { printf '%s' "${out#Ошибка: }"; return 1; }
  [[ -d "$BASE" ]] && printf '%s %s\n' "$(date +%s)" "$out" > "$BASE/update-check"
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
# On every start: check GitHub in the background, then offer a newer version
# with what changed (release text or commit messages). "Нет" is remembered for
# that version only, the menu "Версия" still offers it.
UPDATE_BG_PID='' UPDATE_BG_T0=0
update_start_bg(){
  UPDATE_BG_PID=''
  [[ -n "$(update_repo)" && -d "$BASE" && -f "$HELPER" && "${XR_NO_UPDATE_CHECK:-0}" != 1 ]] || return 0
  UPDATE_BG_T0=$(date +%s)
  if [[ $UI_MODE == tui ]]; then
    ( update_check_now >/dev/null 2>&1 || : ) {TUI_REQ}>&- {TUI_RESP}>&- {UI_OUT_FD}>&- {UI_ERR_FD}>&- </dev/null &
  else
    ( update_check_now >/dev/null 2>&1 || : ) </dev/null &
  fi
  UPDATE_BG_PID=$!
}
update_offer(){
  local i cached epoch tag sha rel notes repo
  [[ -n "$UPDATE_BG_PID" ]] || return 0
  for ((i=0; i<16; i++)); do kill -0 "$UPDATE_BG_PID" 2>/dev/null || break; sleep 0.5; done
  UPDATE_BG_PID=''
  cached=$(update_cached) || return 0
  read -r epoch tag sha rel <<< "$cached"
  [[ "$rel" == newer && "$epoch" -ge "$UPDATE_BG_T0" ]] || return 0
  [[ "$(cat "$BASE/update-dismissed" 2>/dev/null)" == "$tag" ]] && return 0
  repo=$(update_repo)
  notes=$(helper update-notes "$repo" "$VERSION" "$tag" 2>>"$LOG") || notes=''
  [[ -n "$notes" ]] || notes='{dim}описание изменений не найдено{/}'
  if tui_yesno 'Доступно обновление' "Вышла версия {green}$tag{/} {dim}(сейчас $VERSION, коммит $sha){/}

{bold}Что изменилось:{/}
$notes

Обновить сейчас?" 'Да' 'Нет' yes; then
    do_update "$tag" noconfirm || :
  else
    printf '%s\n' "$tag" > "$BASE/update-dismissed"
    note "{dim}Обновиться позже можно в «Версия $VERSION».{/}"
  fi
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
  [[ "${2:-}" == noconfirm ]] || tui_yesno 'Обновление' "Обновить 3x-ui_reverse $VERSION → {green}$tag{/}?

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
  rm -f -- "$tmp" "$BASE/update-check"
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
            UPDATE_REPO=$out; save_state; rm -f -- "$BASE/update-check"
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
  update_start_bg                 # ask GitHub while the rest of the start-up runs
  pair_revoke                     # pairing files left by a killed session
  upgrade_panel_data
  panel_creds_sync
  flush_notes 'Обновление'
  update_offer
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
         routing $'Маршрутизация\t{dim}РФ напрямую, заблокированное через сервер{/}' \
         web $'Сайты и сервисы\t{dim}корень домена, другие домены, Docker{/}' \
         nodes $'Подключить узел\t{dim}другие серверы 3x-ui под управлением этой панели{/}' \
         '#Диагностика' '' \
         diag $'Диагностика сервера\t{dim}iPerf3 до РФ, IP Region{/}' \
         '#Система' '' \
         settings $'Настройки панели\t{dim}порты, пути, логин{/}' \
         service $'Обслуживание\t{dim}перезапуск, переустановка{/}' \
         version "$(version_label)" \
         remove $'{red}Удаление{/}\t{dim}прокси, 3x-ui, всё{/}' \
         "${quit_item[@]}") || return 0
    case "$ch" in
      info) panel_creds_sync; flush_notes 'Параметры'; tui_show 'Параметры и ссылки' show_info_color ;;
      pdf) pdf_screen ;;
      status) tui_show 'Состояние служб' show_status_color ;;
      users) menu_users ;;
      groups) menu_groups ;;
      inbounds) menu_inbounds ;;
      web) menu_web ;;
      routing) menu_routing ;;
      nodes) menu_nodes ;;
      diag) menu_diag ;;
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
  diag ipregion                         IP Region: страна IP в GeoIP-базах и сервисах
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
  domain | domain set НОВЫЙ [--keep-old] | domain drop-old   основной домен (перенаправление со старого — Caddy)
  subpage list | sync | set NAME|default    страница подписки (шаблоны dohuyanevezuch/3x-ui_subpages)
  inbounds servers                      этот сервер и узлы (номер — для --node)
  inbounds add KIND,… --node N          создать на узле (без XHTTP TLS и Hysteria2)
  inbounds rename IDS [--yes]           названия как у скрипта: 🇩🇪 Germany VLESS TCP Reality
  inbounds enable|disable IDS | delete IDS --yes   массово, inbound-ы с любых узлов
  inbounds country-style full|code [--rename]      Netherlands или NL в названиях
  sites [list]                          сайты и сервисы за Caddy (корень домена, другие домены)
  sites root stub|HOST:PORT             что открывается на корне домена
  sites add ДОМЕН HOST:PORT | sites del ДОМЕН | sites import CADDYFILE | sites apply
  routing [list]                        маршрутизация на устройствах клиентов (через подписку)
  routing mode off|ru-direct|blocked-proxy   РФ напрямую / только заблокированное через сервер
  routing add ДОМЕНЫ… [--direct|--proxy]  свои домены/IP;  routing add-url URL [--direct|--proxy]
  routing del N | routing refresh
  node [list]                           подключённые узлы (другие панели 3x-ui)
  node add DOMAIN TOKEN [--name NAME]   подключить узел по одноразовому токену с узла
  node add https://узел/путь/ --api-token T [--name NAME]   подключить вручную
  node show ID | node del ID
  node token                            (на узле) выдать токен подключения и ждать мастер
  node api-token [--rotate]             (на узле) API-токен для мастер-панели
  version | update [--check]            версия | проверить/установить обновление

Служебные: --migrate  --repair  --demo  --uninstall  --remove-command  --restore-command

Переменные: XR_IPERF='Город=host,…'  XR_UI=cli|tui  XR_SNI=a.com,b.com,c.com  XR_SNIFF=route|metadata
            XR_COUNTRY=NL|none  XR_REPO=owner/name  NO_COLOR=1
EOF
}
upgrade_panel_data(){
  # One-time data upgrades from older versions; need the panel API.
  [[ "${PANEL_INSTALLED:-1}" == 1 && -d "$BASE" ]] || return 0
  activity_check
  local need=0 nflag
  [[ -f "$BASE/.flags-v27" ]] || need=1
  [[ -f "$BASE/routing.json" ]] && grep -q '"vpn"' "$BASE/routing.json" 2>/dev/null && need=1
  ((need)) || return 0
  ensure_api_token 3 >/dev/null 2>&1 || return 0
  # v2.6.0 routed inside the server's Xray; v2.7 routes on the clients instead.
  if [[ -f "$BASE/routing.json" ]] && grep -q '"vpn"' "$BASE/routing.json" 2>/dev/null; then
    helper routing-legacy-cleanup >>"$LOG" 2>&1 &&
      note '○ Маршрутизация v2.6.0 (на сервере) убрана — теперь правила раздаются клиентам через подписку: «Маршрутизация».'
  fi
  # v2.7: auto names start with the country flag — add it to inbounds of older versions.
  if [[ ! -f "$BASE/.flags-v27" ]] && nflag=$(helper inbound-flags 2>>"$LOG"); then
    touch "$BASE/.flags-v27"
    [[ "$nflag" =~ ^[1-9][0-9]*$ ]] && note "✓ К названиям inbound'ов добавлен флаг страны: $nflag шт."
  fi
  return 0
}
# Users' "where" column needs Xray's access log and the minute timer; a migrated
# or reinstalled panel may lack either.
activity_check(){
  [[ -f "$BASE/.activity-checked" && "$BASE/.activity-checked" -nt "$HELPER" ]] && return 0
  ensure_api_token 3 >/dev/null 2>&1 || return 0
  if ! helper access-log-ok >/dev/null 2>>"$LOG"; then
    helper enable-access-log >>"$LOG" 2>&1 &&
      note '✓ Включён журнал Xray для учёта активности: в «Пользователях» теперь видно, через какой inbound подключались (Xray перезапущен на секунду).'
  fi
  systemctl is-enabled --quiet "$ACTIVITY_UNIT.timer" 2>/dev/null || setup_activity_timer >>"$LOG" 2>&1 || :
  touch "$BASE/.activity-checked"
}
cli_need_panel(){
  [[ $EUID -eq 0 ]] || die 'Запусти через sudo.'
  load_state
  write_helper                    # always the helper of this script version
  [[ "${PANEL_INSTALLED:-1}" == 1 ]] || die 'Панель 3x-ui удалена.'
  ensure_api_token 5 || die 'API 3x-ui недоступен (служба x-ui запущена?).'
  upgrade_panel_data
  ((${#NOTES[@]})) && printf '%s\n' "${NOTES[@]}" | sed 's/{[a-z/]*}//g' >&2
  NOTES=()
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
    info) [[ $EUID -eq 0 ]] || die 'Запусти через sudo.'; load_state; write_helper; panel_creds_sync
          ((${#NOTES[@]})) && printf '%s\n' "${NOTES[@]}" | sed 's/{[a-z/]*}//g' >&2
          NOTES=(); show_info_color ;;
    status) [[ $EUID -eq 0 ]] || die 'Запусти через sudo.'; load_state; write_helper; show_status_color ;;
    pdf)
      [[ $EUID -eq 0 ]] || die 'Запусти через sudo.'; load_state; write_helper
      pdf_ready || pdf_install_deps || die 'Не удалось установить python3-reportlab и fonts-dejavu-core.'
      write_pdf || die "Не удалось сформировать PDF (см. $LOG)."
      printf 'PDF: %s\nСкачать: %s\n' "$PDF_FILE" "$(pdf_download_hint)" ;;
    diag)
      [[ $EUID -eq 0 ]] || die 'Запусти через sudo.'
      [[ -r "$STATE" ]] && load_state
      if [[ ! -d "$BASE" ]]; then      # not installed: work from a temporary dir
        local d; d=$(mktemp -d "${TMPDIR:-/tmp}/3xr-diag.XXXXXXXX")
        HELPER=$d/xr_helper.py; HELPER_STATE=$d; LOG=$d/diag.log
      fi
      write_helper
      case "$sub" in
        iperf)
          local res secs=3; [[ "${3:-}" == --full ]] && secs=10
          res=$(mktemp); iperf_run "$secs" "$res" || die 'iPerf3: тест не выполнен.'
          helper iperf-table "$res"; rm -f -- "$res" ;;
        ipregion)
          local res; res=$(mktemp)
          ipregion_run "$res" || { flush_notes; rm -f -- "$res"; exit 1; }
          helper ipregion-table "$res" "$(tput cols 2>/dev/null || echo 100)"; rm -f -- "$res" ;;
        *) die 'diag iperf [--full] | diag ipregion' ;;
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
        servers) helper menu-servers | sed 's/{[a-z/]*}//g; s/\t/  /g' ;;
        rename)
          [[ -n "${3:-}" ]] || die 'inbounds rename IDS [--yes]'
          helper inbounds-rename-plan "$3" | grep -v '^CHANGES=' | sed 's/{[a-z/]*}//g'
          [[ " $* " == *' --yes '* ]] || { printf '\nПрименить: inbounds rename %s --yes\n' "$3"; return 0; }
          printf 'Переименовано: %s\n' "$(helper inbounds-rename "$3")" ;;
        enable|disable) [[ -n "${3:-}" ]] || die "inbounds $sub IDS"
          printf 'Готово: %s\n' "$(helper inbounds-bulk "$sub" "$3")" ;;
        delete) [[ -n "${3:-}" && " $* " == *' --yes '* ]] || die 'inbounds delete IDS --yes'
          printf 'Удалено: %s\n' "$(helper inbounds-bulk delete "$3")" ;;
        country-style)
          if [[ -n "${3:-}" ]]; then helper country-style "$3" >/dev/null
            [[ " $* " == *' --rename '* ]] && printf 'Переименовано: %s\n' "$(helper inbounds-restyle)"; fi
          helper country-style ;;
        *) die "Неизвестная подкоманда inbounds $sub" ;;
      esac ;;
    sites)
      cli_need_panel
      cli_sites "${@:2}" ;;
    domain)
      cli_need_panel
      cli_domain "${@:2}" ;;
    subpage)
      cli_need_panel
      case "$sub" in
        list) helper subpages-list "$(subpage_dir)" | awk -F'\t' '$1=="CUR"{print "Сейчас: " ($2==""?"стандартная 3x-ui":$2); next} $1=="SRC"{next} {print ($2=="1"?"* ":"  ") $1 "  " $3}' ;;
        sync) helper subpages-sync "$(subpage_dir)" "${XR_SUBPAGES_REPO:-}" ;;
        set) [[ -n "${3:-}" ]] || die 'subpage set NAME|default'
             [[ "$3" == default ]] || [[ -d "$(subpage_dir)/$3" ]] || helper subpages-sync "$(subpage_dir)" "${XR_SUBPAGES_REPO:-}" >/dev/null
             helper subpage-set "$(subpage_dir)" "$3" >/dev/null && printf 'Страница подписки: %s\n' "$3" ;;
        *) die "Неизвестная подкоманда subpage $sub" ;;
      esac ;;
    routing)
      cli_need_panel
      local r act
      case "$sub" in
        list|show) helper routing-text; printf '\n'; helper routing-rules | sed 's/\t/  /g' ;;
        mode) [[ -n "${3:-}" ]] || die 'routing mode off|ru-direct|blocked-proxy'
              r=$(helper routing-mode "$3"); routing_timer_sync; helper routing-text
              grep -q '^lists_missing=1' <<< "$r" && warn 'Список заблокированного не скачался — JSON-подписка получит его при следующем обновлении.'
              grep -q '^happ_dropped=' <<< "$r" && warn "В Happ/INCY не поместились свои записи: $(sed -n 's/^happ_dropped=//p' <<< "$r")"
              : ;;
        add|add-url)
          act=proxy; [[ " $* " == *' --direct '* ]] && act=direct
          local -a vals=()
          for r in "${@:3}"; do [[ "$r" == --direct || "$r" == --proxy || "$r" == --vpn ]] || vals+=("$r"); done
          ((${#vals[@]})) || die 'routing add ДОМЕНЫ… [--direct|--proxy] | routing add-url URL [--direct|--proxy]'
          if [[ "$sub" == add-url ]]; then r=$(helper routing-add "$act" url "${vals[0]}")
          else r=$(helper routing-add "$act" domains "${vals[@]}"); fi
          printf 'Добавлено записей: %s (%s)\n' "$(sed -n 's/^count=//p' <<< "$r")" "$([[ $act == proxy ]] && echo 'через сервер' || echo 'напрямую')"
          routing_timer_sync ;;
        del) [[ -n "${3:-}" ]] || die 'routing del N (номер из routing list)'
             helper routing-rule "$3" del; routing_timer_sync ;;
        refresh) helper routing-refresh ;;
        *) die "Неизвестная подкоманда routing $sub" ;;
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
      install -m 755 -- "$tmp" "$SELF"; rm -f -- "$tmp" "$BASE/update-check"
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
  INB_NODE=$(cli_opt node "$@"); INB_NODE=${INB_NODE:-0}
  [[ "$INB_NODE" =~ ^[0-9]+$ ]] || die '--node N (номер из: inbounds servers)'
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
    ((INB_NODE)) || open_firewall_ports "$CREATED_IDS" || :
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
  xui_resolve_db
  case "${1:-}" in
    --cli) UI_WANT=cli; main_interactive ;;
    --tui) UI_WANT=tui; main_interactive ;;
    --repair) ui_init || :; repair_incomplete ;;
    --migrate)
      [[ -f "$STATE" ]] && die 'Сервер уже под управлением 3x-ui_reverse.'
      xui_present || die "3x-ui не найдена ($CLI, $DB)."
      if migrate_flow && [[ -f "$STATE" ]]; then manager; fi ;;
    --demo) ui_init || :; demo_ui ;;
    --users) cli_cmd users list ;;
    --uninstall) uninstall_all || { flush_notes 'Удаление'; exit 1; } ;;
    --remove-command) remove_manager_command || : ;;
    --restore-command) restore_manager_command ;;
    --help|-h|help) usage ;;
    info|status|pdf|bbr|diag|routing|sites|users|groups|inbounds|node|nodes|version|update|subpage|domain) cli_cmd "$@" ;;
    '') main_interactive ;;
    *) die "Неизвестный параметр: $1 (см. --help)" ;;
  esac
fi