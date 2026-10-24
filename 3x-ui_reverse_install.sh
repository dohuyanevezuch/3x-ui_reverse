#!/usr/bin/env bash
# 3x-ui_reverse: installer & manager for 3x-ui behind Nginx/Caddy + HTTPS,
# auto-created Reality/XHTTP/MTProto inbounds, users and groups. TUI and CLI.
# Run as root on a CLEAN VPS. Does not support existing panels/web sites.
set -Eeuo pipefail
umask 077

# Release version = the git tag of the commit this file comes from.
VERSION=v2.0.1
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
  ui_call "{\"cmd\":\"msg\",\"title\":\"$jt\",\"text\":\"$jx\",\"ok\":\"продолжить\",\"ctx\":\"$(_ctx)\"}"
  return 0
}
# tui_yesno TITLE TEXT [YES] [NO] [yes|no — default choice, «no» by default]
tui_yesno(){
  local jt jx jy jn dn=true
  _jesc "$1"; jt=$JESC; _jesc "$2"; jx=$JESC; _jesc "${3:-Да}"; jy=$JESC; _jesc "${4:-Нет}"; jn=$JESC
  [[ "${5:-no}" == yes ]] && dn=false
  ui_call "{\"cmd\":\"yesno\",\"title\":\"$jt\",\"text\":\"$jx\",\"yes\":\"$jy\",\"no\":\"$jn\",\"defaultno\":$dn,\"ctx\":\"$(_ctx)\"}"
  return "$UI_RC"
}
tui_input(){
  local jt jx jd
  _jesc "$1"; jt=$JESC; _jesc "$2"; jx=$JESC; _jesc "${3:-}"; jd=$JESC
  ui_call "{\"cmd\":\"input\",\"title\":\"$jt\",\"text\":\"$jx\",\"default\":\"$jd\",\"ctx\":\"$(_ctx)\"}"
  ((UI_RC == 0)) || return 1
  printf '%s' "$UI_VAL"
}
# tui_menu TITLE TEXT TAG LABEL [TAG LABEL…] — prints the chosen tag.
# Tags are never shown in the TUI; a tag starting with # is a section heading.
# A tab inside LABEL splits it into aligned columns.
tui_menu(){
  local jt jx jc
  _jesc "$1"; jt=$JESC; _jesc "$2"; jx=$JESC; shift 2
  _jarr "$@"; _jesc "${TUI_CANCEL:-Назад}"; jc=$JESC
  ui_call "{\"cmd\":\"menu\",\"title\":\"$jt\",\"text\":\"$jx\",\"items\":$JARR,\"cancel\":\"$jc\",\"ctx\":\"$(_ctx)\"}"
  ((UI_RC == 0)) || return 1
  printf '%s' "$UI_VAL"
}
# tui_checklist / tui_radiolist TITLE TEXT TAG LABEL ON|OFF … — one tag per line.
_tui_list(){
  local kind=$1 jt jx
  _jesc "$2"; jt=$JESC; _jesc "$3"; jx=$JESC; shift 3
  _jarr "$@"
  ui_call "{\"cmd\":\"$kind\",\"title\":\"$jt\",\"text\":\"$jx\",\"items\":$JARR,\"ctx\":\"$(_ctx)\"}"
  ((UI_RC == 0)) || return 1
  printf '%s\n' "$UI_VAL"
}
tui_checklist(){ _tui_list check "$@"; }
tui_radiolist(){ _tui_list radio "$@"; }
tui_textfile(){
  local jt jf
  _jesc "$1"; jt=$JESC; _jesc "$2"; jf=$JESC
  ui_call "{\"cmd\":\"text\",\"title\":\"$jt\",\"file\":\"$jf\",\"ctx\":\"$(_ctx)\"}"
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
trap ui_shutdown EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

unexpected_failure(){
  local code=$1 line=$2
  trap - ERR
  ui_stop failed
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
  . /etc/os-release
  [[ ${ID:-} == debian || ${ID:-} == ubuntu ]] || die 'Поддерживаются только Debian 12/13 и Ubuntu 22.04/24.04.'
  case "$ID:${VERSION_ID:-}" in debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;; *) die 'Неподдерживаемая версия Debian/Ubuntu.';; esac
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
  tui_init || die 'Установка ведётся в интерактивном терминале (нужен python3).'
  check_environment
  local ch
  ch=$(tui_radiolist 'Установка на чистый VPS' \
        'Веб-сервер обслуживает сайт-заглушку, выпускает HTTPS и скрывает за собой панель и подписки.' \
        caddy 'Caddy — автоматический HTTPS' ON \
        nginx 'Nginx + Certbot' OFF) || exit 0
  case "$ch" in caddy|nginx) PROXY=$ch;; *) exit 0;; esac
  local entered=''
  while :; do
    entered=$(tui_input 'Домен' 'Домен, A-запись которого указывает на этот VPS (например, panel.example.com):' "$entered") || exit 0
    entered=${entered,,}; entered=${entered%.}
    valid_domain "$entered" && break
    tui_msg 'Неверный домен' 'Введи корректное DNS-имя: не IP-адрес, не URL и без порта.'
  done
  DOMAIN=$entered
  if ! getent ahostsv4 "$DOMAIN" >/dev/null; then
    die "Для $DOMAIN не найдена A-запись. Настрой DNS заранее."
  fi
  tui_yesno 'Подтверждение' "Домен:       $DOMAIN
Веб-сервер:  $PROXY

Будут установлены веб-сервер с сайтом-заглушкой и HTTPS, панель 3x-ui (только на 127.0.0.1) и inbound-ы VLESS Reality (RAW, XHTTP) и MTProto на свободных портах с пользователем user1.

Требования: A-запись домена указывает на этот VPS, TCP 80/443 доступны извне." 'Установить' 'Отмена' yes || exit 0
  install -d -m 755 "$BASE"
  touch "$LOG"; chmod 600 "$LOG"
  local proxy_install_stage proxy_https_stage inbounds_ok=0
  if [[ $PROXY == caddy ]]; then
    proxy_install_stage='Устанавливаем Caddy'
    proxy_https_stage='Настраиваем Caddy и HTTPS'
  else
    proxy_install_stage='Устанавливаем Nginx и Certbot'
    proxy_https_stage='Настраиваем Nginx и сертификат HTTPS'
  fi
  ui_start "Установка • $DOMAIN • $PROXY" \
    'Проверяем окружение' \
    'Подготавливаем компоненты' \
    "$proxy_install_stage" \
    'Создаём страницу-заглушку' \
    "$proxy_https_stage" \
    'Устанавливаем 3x-ui' \
    'Привязываем веб-панель и подписки к 127.0.0.1' \
    'Создаём inbound-ы Reality RAW / XHTTP / MTProto' \
    'Записываем параметры входа' \
    'Проверяем доступность HTTPS'
  msg 'Проверяем окружение'
  step 1 'Проверяем окружение'
  msg 'Подготавливаем компоненты'
  run apt-get update
  step 12 'Обновили списки пакетов'
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl openssl python3 iproute2 coreutils
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
  msg 'Создаём inbound-ы Reality RAW / XHTTP / MTProto'
  # Not fatal: the panel is already installed and inbounds can be created later (menu 19).
  if setup_inbounds; then
    inbounds_ok=1
    step 93 'Inbound-ы и пользователь user1 созданы'
  else
    warn 'Inbound-ы не созданы автоматически. Создай их в меню «Inbound-ы».'
    step 93 'Inbound-ы пропущены'
  fi
  msg 'Записываем параметры входа'
  save_state; write_info
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
    warn "Открой во внешнем файрволе провайдера TCP-порты inbound-ов: $(helper ports 2>/dev/null || echo '?')."
  fi
  tui_show 'Установка завершена' install_summary
  flush_notes 'Обрати внимание'
}
install_summary(){
  show_info_color
  if helper sub-id user1 >/dev/null 2>&1; then
    printf '  ● ПОЛЬЗОВАТЕЛЬ user1\n'
    print_user_links user1 || :
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
  local panel_url sub_base certpath
  if [[ "${PROXY_INSTALLED:-1}" == 1 ]]; then
    panel_url="https://$DOMAIN/$PANEL_PATH/"
    sub_base="https://$DOMAIN"
    certpath=$(certdir)
  elif [[ "${TLS_MODE:-none}" == direct && "${PANEL_INSTALLED:-1}" == 1 ]]; then
    panel_url="https://$DOMAIN/$PANEL_PATH/"
    sub_base="https://$DOMAIN:$SUB_PORT"
    certpath="/root/cert/$DOMAIN"
  else
    panel_url='Недоступна'
    sub_base='Недоступны'
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
    printf '\n%s  ● ПОДПИСКИ%s\n' "$C_BLUE" "$C_RESET"
    color_value 'Обычная / VLESS' "$sub_base/$SUB_PATH/CLIENT_SUB_ID" "$C_GREEN"
    color_value 'JSON' "$sub_base/$JSON_PATH/CLIENT_SUB_ID" "$C_GREEN"
    color_value 'Mihomo / Clash' "$sub_base/$CLASH_PATH/CLIENT_SUB_ID" "$C_GREEN"
    color_value 'Порт подписок' "$SUB_PORT" "$C_DIM"
    printf '\n%s  ● INBOUND-Ы%s\n' "$C_BLUE" "$C_RESET"
    if ! { ensure_api_token 1 && helper inbounds; } 2>>"$LOG"; then
      printf '  %sНедоступно (служба x-ui остановлена?)%s\n' "$C_DIM" "$C_RESET"
    fi
  fi
  printf '\n%s  ● ФАЙЛЫ%s\n' "$C_BLUE" "$C_RESET"
  color_value 'Параметры (chmod 600)' "$INFO" "$C_DIM"
  color_value 'Лог' "$LOG" "$C_DIM"
  printf '\n%s  ⚠ Учётные данные не передавай посторонним.%s\n\n' "$C_YELLOW" "$C_RESET"
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
  rm -f -- "$API_TOKEN" "$BASE/activity.json"
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
    printf 'https://127.0.0.1:443/%s/panel/api' "$PANEL_PATH"
  else
    printf 'http://127.0.0.1:%s/%s/panel/api' "$PANEL_PORT" "$PANEL_PATH"
  fi
}
helper(){
  [[ -f "$HELPER" ]] || write_helper
  XR_API="$(api_base)" XR_TLS_SNI="$DOMAIN" XR_TOKEN_FILE="$API_TOKEN" \
  XR_STATE_DIR="$BASE" XR_ACCESS_LOG="$ACCESS_LOG" python3 -I "$HELPER" "$@"
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
valid_sni_list(){
  local s; local -a list
  IFS=, read -ra list <<< "$1"
  ((${#list[@]} == 3)) || return 1
  for s in "${list[@]}"; do valid_domain "$s" || return 1; done
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
open_firewall_ports(){
  # Only touches a firewall that is already active; the provider's external
  # firewall (security groups) still has to be opened by hand.
  local ports p
  ports=$(helper ports 2>>"$LOG") || return 1
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    for p in $ports; do run ufw allow "$p/tcp" || :; done
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for p in $ports; do run firewall-cmd --permanent --add-port="$p/tcp" || :; done
    run firewall-cmd --reload || :
  fi
  return 0
}
# Creates the missing ones of: Vless RAW Reality, Vless xhttp Reality, mtproto,
# plus user1 attached to all of them. Safe to re-run: existing inbounds are kept.
setup_inbounds(){
  local snis p1 p2 p3
  write_helper
  write_helper_env
  ensure_api_token || { warn 'Не удалось получить API-токен 3x-ui.'; return 1; }
  TAKEN_PORTS=$(helper all-ports 2>>"$LOG") || TAKEN_PORTS=''
  p1=$(inbound_port) || { warn 'Нет свободного порта для inbound.'; return 1; }
  TAKEN_PORTS+=" $p1"
  p2=$(inbound_port) || { warn 'Нет свободного порта для inbound.'; return 1; }
  TAKEN_PORTS+=" $p2"
  p3=$(inbound_port) || { warn 'Нет свободного порта для inbound.'; return 1; }
  TAKEN_PORTS+=" $p3"
  if [[ -n "${XR_SNI:-}" ]]; then
    snis=$XR_SNI
  elif ! snis=$(helper pick-sni 3 2>>"$LOG"); then
    warn 'Не удалось подобрать SNI автоматически (см. лог). Можно задать вручную: XR_SNI=a.com,b.com,c.com'
    return 1
  fi
  valid_sni_list "$snis" || { warn "Некорректный список SNI: $snis"; return 1; }
  printf 'Inbound ports %s %s %s, SNI %s\n' "$p1" "$p2" "$p3" "$snis" >>"$LOG"
  helper create-inbounds "$p1,$p2,$p3" "$snis" "$XR_SNIFF" >>"$LOG" 2>&1 \
    || { warn 'Не удалось создать inbound-ы (см. лог).'; return 1; }
  helper enable-access-log >>"$LOG" 2>&1 || warn 'Не удалось включить журнал активности Xray.'
  setup_activity_timer || warn 'Не удалось включить учёт активности.'
  open_firewall_ports || :
  return 0
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
  helper inbounds 2>/dev/null || printf '  нет данных'
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
  local ch list
  while :; do
    ch=$(tui_menu 'Inbound-ы' "$(inbounds_screen_text)" \
         list 'Подробный список всех inbound-ов' \
         create 'Создать недостающие inbound-ы скрипта (порты и SNI — автоматически)' \
         ports 'Порты для внешнего файрвола') || return 0
    case "$ch" in
      list) tui_show 'Inbound-ы панели' helper inbounds ;;
      create)
        if tui_yesno 'Создание inbound-ов' 'Создать отсутствующие из Vless RAW Reality, Vless xhttp Reality и mtproto?
Остальные inbound-ы панели не изменяются. SNI проверяются сканером панели — это может занять до минуты.' 'Создать' 'Отмена' yes; then
          if with_progress 'Создание inbound-ов' 'Подбираем порты и SNI, создаём inbound-ы' setup_inbounds; then
            note '{green}✓ Inbound-ы созданы.{/}'
            note "Открой во внешнем файрволе провайдера порты: $(helper ports 2>/dev/null || echo '?') (TCP)."
          fi
        fi ;;
      ports)
        list=$(firewall_ports_text)
        tui_msg 'Порты inbound-ов' "Порты всех включённых inbound-ов — их нужно открыть во внешнем файрволе провайдера:

${list:-  нет данных}

Скрипт сам открывает порты только своих inbound-ов и только в уже включённом ufw/firewalld." ;;
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
         4 "Переустановить прокси ($PROXY)") || return 0
    case "$ch" in
      1) restart_services || : ;;
      2) edit_proxy_config ;;
      3) reinstall_panel || warn 'Переустановка панели не завершена.'; load_state ;;
      4) reinstall_proxy || warn 'Переустановка прокси не завершена.'; load_state ;;
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

write_helper(){
  [[ -d "$BASE" ]] || return 0
  local tmp; tmp=$(mktemp "$BASE/xr_helper.XXXXXXXX")
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
REMARKS = {'raw': 'Vless RAW Reality', 'xhttp': 'Vless xhttp Reality', 'mtproto': 'mtproto'}

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


# ------------------------------------------------------------ country names
COUNTRY_RU = {
    'AE': 'ОАЭ', 'AL': 'Албания', 'AM': 'Армения', 'AR': 'Аргентина', 'AT': 'Австрия', 'AU': 'Австралия',
    'AZ': 'Азербайджан', 'BA': 'Босния и Герцеговина', 'BD': 'Бангладеш', 'BE': 'Бельгия', 'BG': 'Болгария',
    'BH': 'Бахрейн', 'BR': 'Бразилия', 'BY': 'Беларусь', 'CA': 'Канада', 'CH': 'Швейцария', 'CL': 'Чили',
    'CN': 'Китай', 'CO': 'Колумбия', 'CY': 'Кипр', 'CZ': 'Чехия', 'DE': 'Германия', 'DK': 'Дания',
    'EE': 'Эстония', 'EG': 'Египет', 'ES': 'Испания', 'FI': 'Финляндия', 'FR': 'Франция', 'GB': 'Великобритания',
    'GE': 'Грузия', 'GR': 'Греция', 'HK': 'Гонконг', 'HR': 'Хорватия', 'HU': 'Венгрия', 'ID': 'Индонезия',
    'IE': 'Ирландия', 'IL': 'Израиль', 'IN': 'Индия', 'IR': 'Иран', 'IS': 'Исландия', 'IT': 'Италия',
    'JP': 'Япония', 'KE': 'Кения', 'KG': 'Киргизия', 'KR': 'Южная Корея', 'KZ': 'Казахстан', 'LT': 'Литва',
    'LU': 'Люксембург', 'LV': 'Латвия', 'MA': 'Марокко', 'MD': 'Молдова', 'ME': 'Черногория', 'MK': 'Северная Македония',
    'MN': 'Монголия', 'MT': 'Мальта', 'MX': 'Мексика', 'MY': 'Малайзия', 'NG': 'Нигерия', 'NL': 'Нидерланды',
    'NO': 'Норвегия', 'NZ': 'Новая Зеландия', 'PE': 'Перу', 'PH': 'Филиппины', 'PK': 'Пакистан', 'PL': 'Польша',
    'PT': 'Португалия', 'QA': 'Катар', 'RO': 'Румыния', 'RS': 'Сербия', 'RU': 'Россия', 'SA': 'Саудовская Аравия',
    'SC': 'Сейшелы', 'SE': 'Швеция', 'SG': 'Сингапур', 'SI': 'Словения', 'SK': 'Словакия', 'TH': 'Таиланд',
    'TJ': 'Таджикистан', 'TM': 'Туркмения', 'TR': 'Турция', 'TW': 'Тайвань', 'UA': 'Украина', 'US': 'США',
    'UZ': 'Узбекистан', 'VN': 'Вьетнам', 'ZA': 'ЮАР',
}


def _fetch(url, timeout=6):
    import urllib.request
    req = urllib.request.Request(url, headers={'User-Agent': '3x-ui_reverse', 'Accept': '*/*'})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read(1 << 20).decode('utf-8', 'replace')


def country_name():
    """Russian name of the VPS's country by its public IP (cached); '' if unknown.
    XR_COUNTRY overrides: a name, an ISO code, or 'none' to disable the prefix."""
    forced = os.environ.get('XR_COUNTRY', '').strip()
    if forced:
        return '' if forced.lower() == 'none' else COUNTRY_RU.get(forced.upper(), forced)
    cache = os.path.join(STATE_DIR, 'country.txt')
    try:
        with open(cache) as f:
            code = f.read().strip()
    except OSError:
        code = ''
    if not re.fullmatch(r'[A-Z]{2}', code):
        code = ''
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
                code = value
                break
        if code:
            try:
                with open(cache, 'w') as f:
                    f.write(code + '\n')
            except OSError:
                pass
    return COUNTRY_RU.get(code, code)


def remark_for(key):
    name = country_name()
    return ('%s %s' % (name, REMARKS[key])) if name else REMARKS[key]


def cmd_country(_args):
    print(country_name())


def managed():
    """Inbounds created by this tool, keyed raw/xhttp/mtproto."""
    out = {}
    # Matches "Vless RAW Reality" as well as "<Страна> Vless RAW Reality".
    for ib in inbounds():
        remark = (ib.get('remark') or '').lower()
        for key, base in REMARKS.items():
            if remark == base.lower() or remark.endswith(' ' + base.lower()):
                out.setdefault(key, ib)
    return out


# --------------------------------------------------------------- SNI picking
def pick_sni(count, exclude=()):
    targets = [h for h in SNI_CANDIDATES if h not in exclude]
    reply = call('/server/scanRealityTargets', {'targets': ','.join(targets)}, form=True, timeout=180)
    results = ok(reply, 'проверка SNI') or []
    good = []
    for r in results:
        host = r.get('host') or ''
        if not (r.get('feasible') and r.get('tls13') and r.get('h2') and r.get('x25519')):
            continue
        if r.get('privateTarget') or host not in targets or host in good:
            continue
        good.append(host)          # API ranks by feasibility, then latency
    if len(good) < count:
        die('найдено только %d подходящих SNI из %d нужных (проверь исходящий доступ VPS к :443)'
            % (len(good), count))
    return good[:count]


# --------------------------------------------------------- inbound creation
def sniffing(mode):
    s = {'enabled': True, 'destOverride': ['http', 'tls', 'quic'],
         'metadataOnly': False, 'routeOnly': True}
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


def cmd_create_inbounds(args):
    # args: ports(raw,xhttp,mtproto) snis(raw,xhttp,mtproto) sniff-mode
    ports = [int(p) for p in args[0].split(',')]
    snis = args[1].split(',')
    sniff = sniffing(args[2] if len(args) > 2 else 'route')
    have = managed()
    base = {'enable': True, 'listen': '', 'expiryTime': 0, 'total': 0}
    if 'raw' not in have:
        ok(call('/inbounds/add', dict(base, remark=remark_for('raw'), port=ports[0], protocol='vless',
            settings={'clients': [], 'decryption': 'none', 'fallbacks': []},
            streamSettings={'network': 'tcp', 'security': 'reality', 'externalProxy': [],
                            'realitySettings': reality(snis[0]),
                            'tcpSettings': {'acceptProxyProtocol': False, 'header': {'type': 'none'}}},
            sniffing=sniff)), 'создание Vless RAW Reality')
    if 'xhttp' not in have:
        ok(call('/inbounds/add', dict(base, remark=remark_for('xhttp'), port=ports[1], protocol='vless',
            settings={'clients': [], 'decryption': 'none', 'fallbacks': []},
            streamSettings={'network': 'xhttp', 'security': 'reality', 'externalProxy': [],
                            'realitySettings': reality(snis[1]),
                            'xhttpSettings': {'path': '/' + secrets.token_hex(8), 'host': '',
                                              'mode': 'auto', 'xPaddingBytes': '100-1000'}},
            sniffing=sniff)), 'создание Vless xhttp Reality')
    if 'mtproto' not in have:
        # MTProto is served by the mtg sidecar, not Xray: sniffing does not apply.
        ok(call('/inbounds/add', dict(base, remark=remark_for('mtproto'), port=ports[2], protocol='mtproto',
            settings={'fakeTlsDomain': snis[2], 'clients': []}, streamSettings={},
            sniffing={'enabled': False})), 'создание mtproto')
    have = managed()
    if not any((jload(ib.get('settings'), {}).get('clients') or []) for ib in have.values()):
        cmd_add_user(['user1', '0', '0'], quiet=True)
    cmd_inbounds([])


NET_NAMES = {'tcp': 'TCP', 'raw': 'TCP', 'xhttp': 'XHTTP', 'ws': 'WS', 'grpc': 'gRPC',
             'httpupgrade': 'HTTPUpgrade', 'kcp': 'mKCP', 'quic': 'QUIC', 'splithttp': 'XHTTP'}
UDP_PROTOCOLS = {'wireguard', 'hysteria', 'hysteria2', 'tuic', 'amneziawg', 'masque'}


def inbound_kind(ib):
    """'vless · XHTTP · Reality'"""
    ss = jload(ib.get('streamSettings'), {})
    parts = [ib.get('protocol') or '?']
    net = ss.get('network') or ''
    if net and ib.get('protocol') not in UDP_PROTOCOLS | {'mtproto'}:
        parts.append(NET_NAMES.get(net, net.upper()))
    sec = ss.get('security') or ''
    if sec and sec != 'none':
        parts.append({'reality': 'Reality', 'tls': 'TLS'}.get(sec, sec))
    return ' · '.join(parts)


def inbound_sni(ib):
    st = jload(ib.get('settings'), {})
    ss = jload(ib.get('streamSettings'), {})
    if ib.get('protocol') == 'mtproto':
        return st.get('fakeTlsDomain') or ''
    if ss.get('security') == 'reality':
        return ','.join((ss.get('realitySettings') or {}).get('serverNames') or [])
    if ss.get('security') == 'tls':
        return (ss.get('tlsSettings') or {}).get('serverName') or ''
    return ''


def inbound_transport(ib):
    """tcp | udp — which firewall port the inbound needs."""
    ss = jload(ib.get('streamSettings'), {})
    if ib.get('protocol') in UDP_PROTOCOLS or ss.get('network') in ('kcp', 'quic'):
        return 'udp'
    return 'tcp'


def cmd_inbounds(_args):
    """Every inbound of the panel; ◆ marks those created by 3x-ui_reverse."""
    ibs = sorted(inbounds(), key=lambda x: x['id'])
    have = managed()
    ours = {ib['id'] for ib in have.values()}
    if not ibs:
        out('{yellow}⚠ В панели нет inbound-ов.{/}')
    else:
        rows = []
        for ib in ibs:
            clients = len(jload(ib.get('settings'), {}).get('clients') or [])
            used = (ib.get('up') or 0) + (ib.get('down') or 0)
            total = ib.get('total') or 0
            rows.append((ib, str(ib['id']), ib.get('remark') or ib.get('tag') or '—', inbound_kind(ib),
                         str(ib.get('port')), str(clients),
                         '%s / %s' % (human(used), human(total) if total else '∞'), inbound_sni(ib) or '—'))
        head = ('', 'ID', 'НАЗВАНИЕ', 'ПРОТОКОЛ', 'ПОРТ', 'КЛ.', 'ТРАФИК', 'SNI')
        caps = [1, 4, 26, 26, 6, 4, 20, 30]
        widths = [min(caps[i], max([len(head[i])] + [len(r[i]) for r in rows])) for i in range(1, 8)]
        widths.insert(0, 2)
        out('{accent}' + '  '.join(head[i].ljust(widths[i]) for i in range(8)).rstrip() + '{/}')
        for r in rows:
            ib = r[0]
            dot = ('{green}●{/}' if ib.get('enable') else '{red}○{/}') + \
                ('{accent}◆{/}' if ib['id'] in ours else ' ')
            name = cut(r[2], widths[2]).ljust(widths[2])
            if ib['id'] in ours:
                name = '{bold}%s{/}' % name
            cells = [dot, '{dim}%s{/}' % r[1].rjust(widths[1]), name, cut(r[3], widths[3]).ljust(widths[3]),
                     r[4].ljust(widths[4]), r[5].rjust(widths[5]), r[6].ljust(widths[6]),
                     '{dim}%s{/}' % cut(r[7], widths[7])]
            out('  '.join(cells).rstrip())
    missing = [k for k in REMARKS if k not in have]
    off = sum(1 for ib in ibs if not ib.get('enable'))
    out('')
    out('{dim}Всего %d%s · {/}{accent}◆{/}{dim} создан скриптом%s{/}' % (
        len(ibs), (' · выключено %d' % off) if off else '',
        (' · не хватает: ' + ', '.join(remark_for(k) for k in missing)) if missing else ''))


def cmd_ports_all(_args):
    """PORT PROTO REMARK for every enabled inbound (what the firewall must allow)."""
    for ib in sorted(inbounds(), key=lambda x: x['id']):
        if ib.get('enable'):
            print('%s %s %s' % (ib.get('port'), inbound_transport(ib), ib.get('remark') or ib.get('tag') or ''))


def cmd_ports(_args):
    print(' '.join(str(ib.get('port')) for ib in managed().values()))


def cmd_all_ports(_args):
    # Disabled inbounds do not listen, but their ports are still reserved.
    print(' '.join(str(ib.get('port')) for ib in inbounds()))




# -------------------------------------------------------------------- users
SHORT = {'raw': 'RAW', 'xhttp': 'XHTTP', 'mtproto': 'MTProto'}
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
    """inbound id -> short display name (RAW / XHTTP / MTProto or remark)."""
    names = {}
    for ib in ibs:
        remark = (ib.get('remark') or '').lower()
        key = next((k for k, base in REMARKS.items()
                    if remark == base.lower() or remark.endswith(' ' + base.lower())), None)
        names[ib['id']] = SHORT[key] if key else (ib.get('remark') or ib.get('tag') or str(ib['id']))
    return names


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
        attached = {ib['id'] for ib in managed().values()}
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
    ids = parse_ids(args[4], ibs) if len(args) > 4 and args[4] else [ib['id'] for ib in managed().values()]
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
    'users': cmd_users, 'stats': cmd_stats, 'user-card': cmd_user_card,
    'menu-users': cmd_menu_users, 'menu-groups': cmd_menu_groups, 'menu-inbounds': cmd_menu_inbounds,
    'add-user': cmd_add_user, 'del-user': cmd_del_user, 'sub-id': cmd_sub_id,
    'set-inbounds': cmd_set_inbounds, 'set-group': cmd_set_group,
    'group-create': cmd_group_create, 'group-rename': cmd_group_rename, 'group-delete': cmd_group_delete,
    'group-add-users': cmd_group_add_users, 'group-inbounds': cmd_group_inbounds,
    'groups': cmd_groups, 'menu-members': cmd_menu_members, 'group-set-members': cmd_group_set_members,
    'country': cmd_country, 'update-check': cmd_update_check, 'update-fetch': cmd_update_fetch,
    'track-activity': cmd_track_activity, 'enable-access-log': cmd_enable_access_log,
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
        curses.curs_set(0)
        curses.raw()                   # Ctrl+C must not kill a half-done operation
        scr.keypad(True)
        try:
            curses.mousemask(curses.ALL_MOUSE_EVENTS | curses.REPORT_MOUSE_POSITION)
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

    def panel(self, title, inner_w, inner_h, top=None):
        """Rounded panel; returns (y, x, w, h) of the inner area."""
        H, W = self.scr.getmaxyx()
        w = min(inner_w + 4, W - 2)
        h = min(inner_h + 2, H - 3)
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
        except self.c.error:
            return None
        if k == self.c.KEY_MOUSE:
            try:
                _, mx, my, _, bstate = self.c.getmouse()
            except self.c.error:
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
        if bstate & (c.BUTTON1_CLICKED | c.BUTTON1_PRESSED | c.BUTTON1_RELEASED):
            return 'click'
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

            k = self.norm(self.key())
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

    def d_text(self, req):
        title = req.get('title', '')
        text = req.get('text', '')
        if req.get('file'):
            try:
                with open(req['file'], encoding='utf-8', errors='replace') as f:
                    text = f.read().rstrip('\n')
            except OSError as e:
                text = '{red}Не удалось открыть файл: %s{/}' % e
        top = 0
        self.c.flushinp()
        while True:
            if self.too_small():
                self.key()
                continue
            H, W = self.scr.getmaxyx()
            maxw = min(W - 6, 104)
            probe = text_lines(text, maxw)
            need = max([sum(swidth(s) for s, _ in ln) for ln in probe] + [0])
            inner_w = max(44, min(maxw, need, maxw))
            tl = text_lines(text, inner_w)
            view = min(len(tl), H - 6)
            scrollable = len(tl) > view
            footer = ([('↑↓', 'прокрутка', None)] if scrollable else []) + \
                [('Enter', req.get('ok') or 'закрыть', 'enter')]
            self.chrome(footer)
            y, x, w, h = self.panel(title, inner_w, view)
            top = max(0, min(top, len(tl) - view))
            for i in range(view):
                self.put_segs(y + i, x, tl[top + i], w)
            if scrollable:
                pct = int(100 * (top + view) / len(tl))
                self.put(y + h, x + w - 6, ' %3d%% ' % pct, self.a('accent'))
            self.scr.refresh()
            act = self.norm(self.key())
            if isinstance(act, tuple):
                kind_m = self.mouse_kind(act[3])
                act = self.footer_hit(act[1], act[2]) or \
                    {'wheelup': 'up', 'wheeldown': 'down', 'right': 'back'}.get(kind_m)
            if act in ('enter', 'esc', 'back', 'left', 'q'):
                return 0, ''
            step = {'up': -1, 'down': 1, 'pgup': -view, 'pgdn': view, 'space': view}.get(act)
            if step:
                top += step
            elif act == 'home':
                top = 0
            elif act == 'end':
                top = len(tl)

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
        if self.gauge:
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
        if cmd == 'suspend':
            self.c.endwin()
            return 0, ''
        if cmd == 'resume':
            self.scr.clear()
            self.scr.refresh()
            return 0, ''
        if cmd in ('ping', 'quit'):
            return 0, ''
        return 2, 'unknown command'

    def loop(self):
        while True:
            line = self.read_request(0.1 if (self.gauge or self.busy_since) else None)
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
  load_state
  touch "$LOG"; chmod 600 "$LOG"
  # Running a newer copy of this file upgrades the installed command,
  # unless the command was removed on purpose.
  if [[ "$0" != "$SELF" && -f "$0" && -f "$SELF" && ! -L "$SELF" ]] && ! cmp -s "$0" "$SELF"; then
    install -m 755 -- "$0" "$SELF"
    note "✓ Команда $SELF обновлена до версии $VERSION."
  fi
  # Keep the API helper in sync with this version of the script.
  write_helper; write_helper_env
  update_check_background
  flush_notes 'Обновление'
  local ch
  # The text menu already has "0) Выход"; the TUI gets an explicit item for the mouse.
  local -a quit_item=()
  [[ $UI_MODE == tui ]] && quit_item=(quit '{dim}Выход{/}')
  while :; do
    ch=$(TUI_CANCEL='Выход' tui_menu '3x-ui_reverse' "$(main_header)" \
         '#Обзор' '' \
         info $'Параметры и ссылки\t{dim}панель, подписки, файлы{/}' \
         status $'Состояние служб\t{dim}3x-ui, прокси, порты, HTTPS{/}' \
         '#Управление' '' \
         users $'Пользователи\t{dim}трафик, активность, inbound-ы{/}' \
         groups $'Группы\t{dim}массовые действия{/}' \
         inbounds $'Inbound-ы\t{dim}Reality RAW / XHTTP, MTProto{/}' \
         '#Система' '' \
         settings $'Настройки панели\t{dim}порты, пути, логин{/}' \
         service $'Обслуживание\t{dim}перезапуск, переустановка{/}' \
         version "$(version_label)" \
         remove $'{red}Удаление{/}\t{dim}прокси, 3x-ui, всё{/}' \
         "${quit_item[@]}") || return 0
    case "$ch" in
      info) tui_show 'Параметры и ссылки' show_info_color ;;
      status) tui_show 'Состояние служб' show_status_color ;;
      users) menu_users ;;
      groups) menu_groups ;;
      inbounds) menu_inbounds ;;
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
  inbounds [list] | inbounds create     список | создать недостающие
  version | update [--check]            версия | проверить/установить обновление

Служебные: --repair  --demo  --uninstall  --remove-command  --restore-command

Переменные: XR_UI=cli|tui  XR_SNI=a.com,b.com,c.com  XR_SNIFF=route|metadata
            XR_COUNTRY=NL|none  XR_REPO=owner/name  NO_COLOR=1
EOF
}
cli_need_panel(){
  [[ $EUID -eq 0 ]] || die 'Запусти через sudo.'
  load_state
  [[ -f "$HELPER" ]] || write_helper
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
    info) [[ $EUID -eq 0 ]] || die 'Запусти через sudo.'; load_state; show_info_color ;;
    status) [[ $EUID -eq 0 ]] || die 'Запусти через sudo.'; load_state; show_status_color ;;
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
        create) setup_inbounds || die 'Inbound-ы не созданы (см. журнал).'; helper inbounds ;;
        *) die "Неизвестная подкоманда inbounds $sub" ;;
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
main_interactive(){
  if [[ -f "$STATE" ]]; then manager; else install_fresh; manager; fi
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
    info|status|users|groups|inbounds|version|update) cli_cmd "$@" ;;
    '') main_interactive ;;
    *) die "Неизвестный параметр: $1 (см. --help)" ;;
  esac
fi
