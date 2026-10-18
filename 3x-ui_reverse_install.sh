#!/usr/bin/env bash
# 3x-ui_reverse v5: installer & lifecycle manager for 3x-ui + Nginx/Caddy + HTTPS.
# Run as root on a CLEAN VPS. Does not support existing panels/web sites.
set -Eeuo pipefail
umask 077

BASE=/opt/3x-ui_reverse
SITE=$BASE/site
STATE=$BASE/state.env
INFO=$BASE/panel.txt
LOG=$BASE/install.log
DB=/etc/x-ui/x-ui.db
CLI=/usr/local/x-ui/x-ui
SELF=/usr/local/sbin/3x-ui_reverse
XUI_INSTALL_URL=https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh
# Terminal styles are disabled when stdout is not a terminal.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
  C_BLUE=$'\e[36m'; C_RESET=$'\e[0m'; C_WHITE=$'\e[97m'
  C_DIM=$'\e[90m'; C_BOLD=$'\e[1m'; C_MAGENTA=$'\e[35m'
else
  C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''; C_RESET=''
  C_WHITE=''; C_DIM=''; C_BOLD=''; C_MAGENTA=''
fi
PCT=0
UI_ACTIVE=0
UI_PHASE_INDEX=-1
UI_SPINNER_PID=''
UI_COLS=80
UI_WARNINGS=()
UI_PHASES=()
UI_STATES=()

# Compact in-place dashboard. The cursor remains immediately below the block;
# relative movements redraw its lines without clearing the screen, using the
# alternate screen, changing the scroll region or pinning to terminal bottom.
ui_columns(){
  UI_COLS=$(tput cols 2>/dev/null || printf '80')
  [[ $UI_COLS =~ ^[0-9]+$ ]] || UI_COLS=80
}
ui_fit(){
  # UTF-8 aware truncation, even on minimal VPS configured with LANG=C.
  local LC_CTYPE=C.UTF-8
  local value=$1 max=$((UI_COLS-7))
  ((max >= 10)) || max=10
  if ((${#value} > max)); then
    printf '%s…' "${value:0:max-1}"
  else
    printf '%s' "$value"
  fi
}
ui_spinner_stop(){
  if [[ -n "${UI_SPINNER_PID:-}" ]]; then
    kill "$UI_SPINNER_PID" 2>/dev/null || :
    wait "$UI_SPINNER_PID" 2>/dev/null || :
    UI_SPINNER_PID=''
  fi
}
ui_paint_phase(){
  [[ $UI_ACTIVE == 1 ]] || return 0
  local i=$1 icon color title offset
  offset=$((${#UI_PHASES[@]}+2-i))
  title=$(ui_fit "${UI_PHASES[i]}")
  case "${UI_STATES[i]}" in
    done)    icon='✓'; color=$C_GREEN;;
    current) icon='⠋'; color=$C_WHITE;;
    failed)  icon='✗'; color=$C_RED;;
    *)       icon='○'; color=$C_DIM;;
  esac
  # Save and restore the cursor around one compact line update.
  printf '\0337\033[%dA\r\033[2K  %s%s %s%s\0338' \
    "$offset" "$color" "$icon" "$title" "$C_RESET"
}
ui_draw_bar(){
  [[ $UI_ACTIVE == 1 ]] || return 0
  local w=$((UI_COLS-12)) filled unfilled left right
  ((w > 48)) && w=48
  ((w < 10)) && w=10
  filled=$((PCT*w/100))
  unfilled=$((w-filled))
  printf -v left '%*s' "$filled" ''
  printf -v right '%*s' "$unfilled" ''
  # The progress row sits exactly one line above the preserved cursor.
  printf '\0337\033[1A\r\033[2K  %s%s%s%s%s  %s%3d%%%s\0338' \
    "$C_BLUE" "${left// /━}" "$C_DIM" "${right// /─}" "$C_RESET" "$C_BOLD" "$PCT" "$C_RESET"
}
ui_spinner_start(){
  [[ $UI_ACTIVE == 1 && $UI_PHASE_INDEX -ge 0 ]] || return 0
  local offset=$((${#UI_PHASES[@]}+2-UI_PHASE_INDEX))
  (
    trap - EXIT ERR WINCH
    trap 'exit 0' TERM INT
    local frame
    local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    while :; do
      for frame in "${frames[@]}"; do
        # No line feed: background animation never advances the cursor.
        printf '\0337\033[%dA\r  %s%s%s\0338' \
          "$offset" "$C_WHITE" "$frame" "$C_RESET" > /dev/tty 2>/dev/null || exit 0
        sleep 0.12
      done
    done
  ) &
  UI_SPINNER_PID=$!
}
ui_resize(){
  [[ $UI_ACTIVE == 1 ]] || return 0
  ui_spinner_stop
  ui_columns
  local i
  for i in "${!UI_PHASES[@]}"; do ui_paint_phase "$i"; done
  ui_draw_bar
  ui_spinner_start
}
ui_start(){
  local heading=$1; shift
  UI_PHASES=("$@")
  PCT=0
  UI_STATES=()
  UI_PHASE_INDEX=-1
  UI_WARNINGS=()
  [[ -t 0 && -t 1 && "${TERM:-dumb}" != dumb && -r /dev/tty && -w /dev/tty ]] || return 0
  command -v tput >/dev/null 2>&1 || return 0
  ui_columns
  ((UI_COLS >= 32 && ${#UI_PHASES[@]} > 0)) || return 0
  UI_ACTIVE=1
  local title
  printf '\n  %s%s◆ 3x-ui_reverse%s  %s%s%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_DIM" "$heading" "$C_RESET"
  for title in "${UI_PHASES[@]}"; do
    UI_STATES+=(pending)
    printf '  %s○ %s%s\n' "$C_DIM" "$(ui_fit "$title")" "$C_RESET"
  done
  printf '\n  %s%*s%s  %s  0%%%s\n' "$C_DIM" 1 '' "$C_RESET" "$C_BOLD" "$C_RESET"
  ui_draw_bar
  printf '\033[?25l'
  trap ui_resize WINCH
}
ui_finish_step(){
  [[ $UI_ACTIVE == 1 && $UI_PHASE_INDEX -ge 0 ]] || return 0
  ui_spinner_stop
  UI_STATES[UI_PHASE_INDEX]=done
  ui_paint_phase "$UI_PHASE_INDEX"
  UI_PHASE_INDEX=-1
}
ui_stage(){
  local title=$1 i found=-1
  if [[ $UI_ACTIVE != 1 ]]; then
    printf '%s◌%s %s\n' "$C_BLUE" "$C_RESET" "$title"
    return 0
  fi
  ui_finish_step
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
  ui_paint_phase "$found"
  ui_spinner_start
}
ui_stop(){
  [[ $UI_ACTIVE == 1 ]] || return 0
  local result=${1:-complete} w
  ui_spinner_stop
  if ((UI_PHASE_INDEX >= 0)); then
    if [[ $result == complete ]]; then UI_STATES[UI_PHASE_INDEX]=done
    else UI_STATES[UI_PHASE_INDEX]=failed; fi
    ui_paint_phase "$UI_PHASE_INDEX"
  fi
  UI_PHASE_INDEX=-1
  UI_ACTIVE=0
  printf '\033[?25h\n'
  trap - WINCH
  for w in "${UI_WARNINGS[@]}"; do
    printf '%s⚠ %s%s\n' "$C_YELLOW" "$w" "$C_RESET"
  done
  UI_WARNINGS=()
}
ui_exit(){ ui_stop interrupted || :; }
trap ui_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

unexpected_failure(){
  local code=$1 line=$2
  trap - ERR
  ui_stop failed
  printf '\n%sНеожиданная ошибка на строке %s (код %s).%s\n' "$C_RED" "$line" "$code" "$C_RESET" >&2
  printf 'Лог диагностики: %s\n' "$LOG" >&2
  exit "$code"
}
trap 'unexpected_failure "$?" "$LINENO"' ERR
msg(){ ui_stage "$*"; }
warn(){
  if [[ $UI_ACTIVE == 1 ]]; then UI_WARNINGS+=("$*")
  else printf '%s⚠ %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; fi
}
die(){ ui_stop failed; printf '\n%sОшибка: %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; [[ -f "$LOG" ]] && printf 'Лог: %s\n' "$LOG" >&2; exit 1; }
progress(){
  PCT=$1
  if [[ $UI_ACTIVE == 1 ]]; then ui_draw_bar
  else printf '%s  %3d%%%s  %s\n' "$C_BLUE" "$PCT" "$C_RESET" "${2:-}"; fi
}
step(){ progress "$1" "${2:-}"; }
run(){ "$@" >>"$LOG" 2>&1; }
rand(){ head -c 72 /dev/urandom | base64 -w0 | tr -dc 'a-zA-Z0-9' | head -c "$1" || true; }
newport(){
  local p i
  for ((i=0;i<150;i++)); do
    p=$(shuf -i 15000-59000 -n1)
    [[ "$p" != "${PANEL_PORT:-}" && "$p" != "${SUB_PORT:-}" ]] || continue
    if ! ss -H -ltn "sport = :$p" | grep -q .; then echo "$p"; return; fi
  done
  return 1
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
  } > "$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$STATE"
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
  curl -fsS --max-time 12 -o /dev/null "http://127.0.0.1:$PANEL_PORT/$PANEL_PATH/"
}
verify_remote(){
  # Probe localhost with DNS-independent SNI. In direct mode the root is not a
  # web site and may legitimately return 404, so check the panel path instead.
  local uri="https://$DOMAIN/"
  if [[ "${TLS_MODE:-proxy}" == direct && "${PROXY_INSTALLED:-1}" == 0 ]]; then
    uri="https://$DOMAIN/$PANEL_PATH/"
  fi
  curl -fsS --max-time 15 --resolve "$DOMAIN:443:127.0.0.1" -o /dev/null "$uri"
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
     echo 'Новые учётные данные применены.'
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
  echo 'Изменения применены.'
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
  install -m 755 "$0" "$SELF"
  step 100 'Восстановление завершено'
  ui_stop
  printf '\n%sГотово. Настройки сохранены:%s\n' "$C_GREEN" "$C_RESET"
  show_info_color
  if ! verify_remote; then
    warn 'Локальная HTTPS-проверка не прошла; проверь выпуск сертификата и DNS.'
  fi
  warn 'Важно: зайди в настройки 3x-ui и перевыпусти/отзови API-токен из прежнего install.log.'
}

install_fresh(){
  check_environment
  printf '\n%s3x-ui_reverse — установка на чистый VPS%s\n' "$C_BLUE" "$C_RESET"
  printf 'Прокси: 1) Caddy (автоматический HTTPS)  2) Nginx + Certbot\n'
  local ch
  while :; do read -rp 'Выбор [1/2]: ' ch; case "$ch" in 1) PROXY=caddy; break;; 2) PROXY=nginx; break;; *) warn 'Введи 1 или 2.';; esac; done
  while :; do
    read -rp 'Домен (например, panel.example.com): ' DOMAIN
    DOMAIN=${DOMAIN,,}; DOMAIN=${DOMAIN%.}
    if valid_domain "$DOMAIN"; then break; fi
    warn 'Введи корректное DNS-имя, не IP, не URL и не домен с портом.'
  done
  if ! getent ahostsv4 "$DOMAIN" >/dev/null; then
    die "Для $DOMAIN не найдена A-запись. Настрой DNS заранее."
  fi
  printf '\nТребования: A-запись домена указывает на VPS, TCP 80/443 доступны извне.\n'
  read -rp 'Продолжить установку? [y/N]: ' ch
  [[ $ch =~ ^[yYдД]$ ]] || exit 0
  install -d -m 755 "$BASE"
  touch "$LOG"; chmod 600 "$LOG"
  local proxy_install_stage proxy_https_stage
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
  step 78 'Панель 3x-ui установлена'
  msg 'Привязываем веб-панель и подписки к 127.0.0.1'
  apply_panel || die 'Не удалось установить параметры веб-панели.'
  set_subscriptions >>"$LOG" 2>&1 || die 'Не удалось установить параметры подписок.'
  finalize_bootstrap_guard
  run systemctl start x-ui || die 'Не удалось запустить x-ui.'
  if ! wait_local_stack; then
    run systemctl stop x-ui || true
    die 'Локальные порты панели/подписок не прошли проверку после настройки. x-ui остановлен.'
  fi
  step 91 'Локальные сервисы проверены'
  msg 'Записываем параметры входа'
  save_state; write_info
  install -m 755 "$0" "$SELF"
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
  printf '\n%sГотово!%s\n' "$C_GREEN" "$C_RESET"
  show_info_color
}


# Colorized CLI overview. panel.txt stays a plain-text machine-readable summary.
color_value(){
  local name=$1 value=$2 color=${3:-$C_WHITE} pad
  # Bash character count (not UTF-8 byte count) keeps Russian labels aligned.
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
  fi
  printf '\n%s  ● ФАЙЛЫ%s\n' "$C_BLUE" "$C_RESET"
  color_value 'Параметры (chmod 600)' "$INFO" "$C_DIM"
  color_value 'Лог' "$LOG" "$C_DIM"
  printf '\n%s  ⚠ Учётные данные не передавай посторонним.%s\n\n' "$C_YELLOW" "$C_RESET"
}

service_badge(){
  local name=$1
  if systemctl is-active --quiet "$name"; then
    printf '%s● Работает%s' "$C_GREEN" "$C_RESET"
  else
    printf '%s● Не работает%s' "$C_RED" "$C_RESET"
  fi
}
show_status_color(){
  printf '\n%s  ◆ Состояние компонентов%s\n' "$C_BLUE" "$C_RESET"
  if [[ "${PANEL_INSTALLED:-1}" == 1 ]]; then
    printf '  %-16s %s\n' '3x-ui' "$(service_badge x-ui)"
    if [[ "${TLS_MODE:-proxy}" == proxy ]]; then
      if verify_local "$PANEL_PORT" && verify_local "$SUB_PORT" && verify_panel_http; then
        printf '  %-16s %s✓ Порты на 127.0.0.1%s\n' 'Безопасность' "$C_GREEN" "$C_RESET"
      else
        printf '  %-16s %s✗ Проверка портов не пройдена%s\n' 'Безопасность' "$C_RED" "$C_RESET"
      fi
    else
      printf '  %-16s %s● Панель на 443; подписки :%s%s\n' 'Режим HTTPS' "$C_YELLOW" "$SUB_PORT" "$C_RESET"
    fi
  else printf '  %-16s %s● Удалена%s\n' '3x-ui' "$C_DIM" "$C_RESET"; fi
  if [[ "${PROXY_INSTALLED:-1}" == 1 ]]; then
    printf '  %-16s %s\n' "$PROXY" "$(service_badge "$PROXY")"
  else printf '  %-16s %s● Удалён%s\n' "$PROXY" "$C_DIM" "$C_RESET"; fi
  if [[ "${PROXY_INSTALLED:-1}" == 1 || "${TLS_MODE:-none}" == direct ]]; then
    if verify_remote; then
      printf '  %-16s %s✓ HTTPS доступен%s\n' 'Домен' "$C_GREEN" "$C_RESET"
    else
      printf '  %-16s %s⚠ HTTPS недоступен%s\n' 'Домен' "$C_YELLOW" "$C_RESET"
    fi
  fi
  printf '\n'
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
  [[ -t 0 ]] || die 'Требуется интерактивное подтверждение.'
  printf '\n%sУдалить ТОЛЬКО команду %s?%s\n' "$C_YELLOW" "$SELF" "$C_RESET"
  printf '3x-ui, прокси, сертификаты, подписки и данные останутся без изменений.\n'
  local answer
  read -rp 'Напиши УДАЛИТЬ для подтверждения: ' answer
  if [[ $answer != 'УДАЛИТЬ' ]]; then warn 'Отменено.'; return 0; fi
  [[ ! -L "$SELF" ]] || die 'Управляющий скрипт — неожиданная символьная ссылка. Удаление остановлено.'
  rm -f -- "$SELF"
  printf '%s✓ Команда 3x-ui_reverse удалена. Сервисы продолжают работать.%s\n' "$C_GREEN" "$C_RESET"
  printf 'Чтобы вернуть её: sudo bash 3x-ui_reverse_v4.sh --restore-command\n'
}
restore_manager_command(){
  [[ $EUID -eq 0 ]] || die 'Нужны права root.'
  load_state
  [[ ! -L "$SELF" ]] || die 'Неожиданная ссылка по пути команды; сначала проверь вручную.'
  install -m 755 -- "$0" "$SELF"
  printf '%s✓ Управляющая команда восстановлена: %s%s\n' "$C_GREEN" "$SELF" "$C_RESET"
}

uninstall_all(){
  [[ $EUID -eq 0 ]] || die 'Нужны права root.'
  [[ -t 0 ]] || die 'Для полного удаления нужен интерактивный терминал.'
  load_state
  if [[ "${PROXY_INSTALLED:-1}" == 1 ]]; then
    check_proxy_owned_for_purge || die 'Сначала проверь сторонние конфигурации прокси.'
  fi
  printf '\n%s%s  ПОЛНОЕ УДАЛЕНИЕ 3x-ui_reverse%s\n' "$C_BOLD" "$C_RED" "$C_RESET"
  printf '%sБудут безвозвратно удалены:%s\n' "$C_YELLOW" "$C_RESET"
  printf '  • 3x-ui, Xray, все inbounds, пользователи, база SQLite и журналы 3x-ui\n'
  printf '  • Веб-сервер %s, его настройки, сайт-заглушка и TLS-сертификаты\n' "$PROXY"
  printf '  • Каталог %s и команда %s\n' "$BASE" "$SELF"
  printf '  • Настройки 3x-ui для Fail2ban (общие правила Fail2ban сохраняются)\n'
  printf '%sСоздай резервную копию самостоятельно, если данные ещё понадобятся.%s\n\n' "$C_YELLOW" "$C_RESET"
  local typed
  read -rp 'Для полного удаления напиши yes: ' typed
  if [[ "$typed" != yes ]]; then warn 'Удаление отменено.'; return 0; fi
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
  ui_draw_bar
  ui_stop
  printf '%s✓ Полное удаление завершено.%s\n' "$C_GREEN" "$C_RESET"
  printf 'Пакеты общего назначения (curl, python3 и др.) оставлены для других программ.\n'
  printf 'Исходный скрипт, загруженный вручную в /root, удаляется отдельно.\n'
  exit 0
}

# ---- Component lifecycle operations (v5) ----
confirm_yes(){
  [[ -t 0 ]] || { warn 'Операция требует интерактивного терминала.'; return 1; }
  local answer
  read -rp "${1:-Для подтверждения введи yes}: " answer
  [[ "$answer" == yes ]] || { warn 'Отменено.'; return 1; }
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
  printf '\n%sУдаление %s%s\n' "$C_YELLOW" "$PROXY" "$C_RESET"
  local convert='n' oldport=$PANEL_PORT backup='' changed=0
  if [[ "${PANEL_INSTALLED:-1}" == 1 ]]; then
    printf 'Без прокси нельзя сохранить общие ссылки на панель и подписки без отдельного порта.\n'
    read -rp 'Перенести HTTPS на саму 3x-ui и выпуск сертификатов в acme.sh? [y/N]: ' convert
    if [[ "$convert" =~ ^[yYдД]$ ]]; then
      printf 'Панель займёт :443, подписки останутся на :%s (этот TCP-порт нужно открыть).\n' "$SUB_PORT"
    else
      printf 'Панель останется доступна только локально. Внешние URL перестанут работать.\n'
    fi
  fi
  confirm_yes 'Для удаления прокси введи yes' || return 0
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
  printf '%s✓ Прокси удалён.%s\n' "$C_GREEN" "$C_RESET"
  if [[ "$TLS_MODE" == direct ]]; then
    printf 'Панель: https://%s/%s/\nПодписки: https://%s:%s/%s/CLIENT_SUB_ID\n' "$DOMAIN" "$PANEL_PATH" "$DOMAIN" "$SUB_PORT" "$SUB_PATH"
    warn "Открой TCP $SUB_PORT во внешнем файрволе VPS. HTTPS теперь обслуживает 3x-ui, acme.sh продлевает сертификат."
  else
    warn 'Внешний доступ к панели отключён. Восстанови прокси пунктом меню.'
  fi
}
remove_panel_components(){
  run systemctl disable --now x-ui || :
  rm -f /etc/systemd/system/x-ui.service /etc/default/x-ui /usr/bin/x-ui
  rm -rf -- /etc/systemd/system/x-ui.service.d /usr/local/x-ui /etc/x-ui /var/log/x-ui
  rm -f /etc/fail2ban/filter.d/3x-ipl.conf /etc/fail2ban/action.d/3x-ipl.conf
  rm -f /etc/fail2ban/jail.d/3x-ipl.conf /etc/fail2ban/jail.d/3x-ipl-backend.conf
  run systemctl daemon-reload || :
  run systemctl try-restart fail2ban || :
}
remove_panel_only(){
  [[ "${PANEL_INSTALLED:-1}" == 1 ]] || { warn '3x-ui уже удалена.'; return 0; }
  printf '\n%sУдалить 3x-ui вместе с клиентами, конфигурациями Xray и базой?%s\n' "$C_YELLOW" "$C_RESET"
  printf 'Резервная копия SQLite останется в %s/backups/\n' "$BASE"
  if [[ "${PROXY_INSTALLED:-1}" == 1 ]]; then
    check_proxy_owned_for_purge || { warn 'Чужая конфигурация прокси — удаление запрещено.'; return 1; }
  fi
  confirm_yes 'Для удаления 3x-ui введи yes' || return 0
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
  printf '%s✓ 3x-ui удалена. Резервная копия: %s%s\n' "$C_GREEN" "$backup" "$C_RESET"
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
  printf '\nПереустановить 3x-ui? SQLite-база и учётные данные будут сохранены.\n'
  confirm_yes 'Для переустановки 3x-ui введи yes' || return 0
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
  step 100 'Переустановка завершена'
  ui_stop
  printf '%s✓ 3x-ui установлена. Клиенты и пути сохранены.%s\n' "$C_GREEN" "$C_RESET"
  [[ -n "$backup" ]] && printf 'Резервная копия базы: %s\n' "$backup"
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
  printf '\nПереустановить %s? Конфиг и сертификаты будут сохранены при обновлении.\n' "$PROXY"
  confirm_yes 'Для переустановки прокси введи yes' || return 0
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
  printf '%s✓ %s установлен, панель и ссылки проверены.%s\n' "$C_GREEN" "$PROXY" "$C_RESET"
}

manager(){
  [[ $EUID -eq 0 ]] || die 'Запусти через sudo.'
  load_state
  touch "$LOG"; chmod 600 "$LOG"
  while :; do
    printf '\n%s%s  ◆ 3x-ui_reverse  /  управление%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
    local badge
    if [[ "${PROXY_INSTALLED:-1}" == 1 ]]; then badge="${C_GREEN}● ${PROXY}${C_RESET}  ${C_DIM}HTTPS :443${C_RESET}"
    elif [[ "${TLS_MODE:-none}" == direct ]]; then badge="${C_YELLOW}● 3x-ui HTTPS :443${C_RESET}"
    else badge="${C_RED}● Прокси отключён${C_RESET}"; fi
    printf '  %s●%s %s   %b\n' "$C_GREEN" "$C_RESET" "$DOMAIN" "$badge"
    printf '  %s────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
    printf '  %sИНФОРМАЦИЯ%s\n' "$C_BLUE" "$C_RESET"
    printf '  %s 1%s  Показать параметры и ссылки\n  %s 2%s  Проверить состояние\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf '  %sНАСТРОЙКИ%s\n' "$C_BLUE" "$C_RESET"
    printf '  %s 3%s  Изменить порт панели\n  %s 4%s  Изменить путь панели\n  %s 5%s  Изменить логин / пароль\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf '  %s 6%s  Изменить порт подписок\n  %s 7%s  Изменить путь подписок\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf '  %sОБСЛУЖИВАНИЕ%s\n' "$C_BLUE" "$C_RESET"
    printf '  %s 8%s  Перезапустить службы\n  %s 9%s  Редактировать конфигурацию прокси\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf '  %s10%s  Переустановить 3x-ui (сохранить данные)\n  %s11%s  Переустановить прокси\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf '  %sУДАЛЕНИЕ%s\n' "$C_RED" "$C_RESET"
    printf '  %s12%s  Удалить прокси (опционально перейти на HTTPS 3x-ui)\n' "$C_RED" "$C_RESET"
    printf '  %s13%s  Удалить 3x-ui\n' "$C_RED" "$C_RESET"
    printf '  %s14%s  Полностью удалить 3x-ui, прокси и все данные\n' "$C_RED" "$C_RESET"
    printf '  %s15%s  Удалить только команду 3x-ui_reverse\n' "$C_YELLOW" "$C_RESET"
    printf '   %s0%s  Выход\n\n' "$C_DIM" "$C_RESET"
    local n v olduser oldpass
    read -rp 'Выбор: ' n || return 0
    case "$n" in
      1) show_info_color;;
      2) show_status_color;;
      3|4|5|6|7)
         if [[ "${PANEL_INSTALLED:-1}" != 1 ]]; then
           warn 'Панель удалена. Восстанови её пунктом 10.'; continue
         fi
         if [[ "${PROXY_INSTALLED:-1}" != 1 ]]; then
           warn 'Для изменения настроек сначала верни прокси (пункт 11).'; continue
         fi
         case "$n" in
           3)
              read -rp 'Новый порт панели (Enter — случайный): ' v
              v=${v:-$(newport)}
              valid_port "$v" && [[ "$v" != "$SUB_PORT" ]] || { warn 'Неверный порт.'; continue; }
              [[ -z $(ss -H -ltn "sport = :$v") || "$v" == "$PANEL_PORT" ]] || { warn 'Порт занят.'; continue; }
              PANEL_PORT=$v; transaction_change || warn 'Изменение отменено.'; load_state;;
           4)
              read -rp 'Новый путь панели без / (Enter — случайный): ' v
              v=${v:-panel$(rand 18)}
              valid_path "$v" && [[ "$v" != "$SUB_PATH" && "$v" != "$JSON_PATH" && "$v" != "$CLASH_PATH" ]] || { warn 'Неверный путь.'; continue; }
              PANEL_PATH=$v; transaction_change || warn 'Изменение отменено.'; load_state;;
           5)
              olduser=$PANEL_USER; oldpass=$PANEL_PASS
              read -rp 'Новый логин (Enter — случайный): ' v
              PANEL_USER=${v:-u$(rand 12)}
              if ! [[ "$PANEL_USER" =~ ^[a-zA-Z0-9_-]{6,48}$ ]]; then PANEL_USER=$olduser; warn 'Логин: 6–48 символов.'; continue; fi
              read -rp 'Новый пароль (Enter — случайный): ' v
              PANEL_PASS=${v:-$(rand 28)}
              [[ ${#PANEL_PASS} -ge 12 && "$PANEL_PASS" =~ ^[a-zA-Z0-9_-]+$ ]] || { PANEL_USER=$olduser; PANEL_PASS=$oldpass; warn 'Некорректный пароль.'; continue; }
              rotate_credentials || warn 'Учётные данные не изменены.'; load_state;;
           6)
              read -rp 'Новый порт подписок (Enter — случайный): ' v
              v=${v:-$(newport)}
              valid_port "$v" && [[ "$v" != "$PANEL_PORT" ]] || { warn 'Неверный порт.'; continue; }
              [[ -z $(ss -H -ltn "sport = :$v") || "$v" == "$SUB_PORT" ]] || { warn 'Порт занят.'; continue; }
              SUB_PORT=$v; transaction_change || warn 'Изменение отменено.'; load_state;;
           7)
              read -rp 'Новый путь подписок без / (Enter — случайный): ' v
              v=${v:-sub$(rand 19)}
              valid_path "$v" && [[ "$v" != "$PANEL_PATH" && "$v" != "$JSON_PATH" && "$v" != "$CLASH_PATH" ]] || { warn 'Неверный путь.'; continue; }
              SUB_PATH=$v; transaction_change || warn 'Изменение отменено.'; load_state;;
         esac
         ;;
      8)
         ui_start 'Перезапуск сервисов' 'Перезапускаем 3x-ui' 'Перезапускаем прокси' 'Проверяем состояние'
         msg 'Перезапускаем 3x-ui'
         [[ "${PANEL_INSTALLED:-1}" == 0 ]] || run systemctl restart x-ui || { ui_stop failed; warn 'Ошибка запуска 3x-ui.'; continue; }
         step 40 '3x-ui запущена'
         msg 'Перезапускаем прокси'
         [[ "${PROXY_INSTALLED:-1}" == 0 ]] || reload_proxy || { ui_stop failed; warn 'Ошибка прокси.'; continue; }
         step 75 'Прокси проверен'
         msg 'Проверяем состояние'
         step 100 'Сервисы перезапущены'; ui_stop;;
      9)
         [[ "${PROXY_INSTALLED:-1}" == 1 ]] || { warn 'Прокси отсутствует.'; continue; }
         ${EDITOR:-vi} "$(proxy_conf)"
         validate_proxy && reload_proxy || warn 'Конфигурация некорректна; проверь журнал и восстанови вручную.';;
      10) reinstall_panel || warn 'Переустановка панели не завершена.'; load_state;;
      11) reinstall_proxy || warn 'Переустановка прокси не завершена.'; load_state;;
      12) remove_proxy_only || warn 'Удаление прокси не завершено.'; load_state;;
      13) remove_panel_only || warn 'Удаление 3x-ui не завершено.'; load_state;;
      14) uninstall_all;;
      15) remove_manager_command; exit 0;;
      0) return 0;;
      *) warn 'Некорректный пункт.';;
    esac
  done
}

# Visual preview only. Does not install, delete or change anything on the VPS.
demo_ui(){
  local title idx
  local -a titles=(
    'Проверяем окружение'
    'Подготавливаем компоненты'
    'Устанавливаем Caddy'
    'Создаём страницу-заглушку'
    'Устанавливаем 3x-ui'
    'Привязываем веб-панель и подписки к 127.0.0.1'
    'Записываем параметры входа'
  )
  local -a percentages=(5 18 33 43 78 91 100)
  ui_start 'Предпросмотр интерфейса • демонстрация' "${titles[@]}"
  for idx in "${!titles[@]}"; do
    msg "${titles[idx]}"
    sleep 0.35
    step "${percentages[idx]}" "${titles[idx]}"
  done
  ui_stop
  printf '%s✓ Предпросмотр завершён. Система не изменена.%s\n' "$C_GREEN" "$C_RESET"
}

if [[ "${XUI_REVERSE_LIB_ONLY:-0}" != 1 ]]; then
  case "${1:-}" in
    --repair) repair_incomplete ;;
    --demo) demo_ui ;;
    --uninstall) uninstall_all ;;
    --remove-command) remove_manager_command ;;
    --restore-command) restore_manager_command ;;
    --help|-h)
      printf 'Usage: sudo bash %s [--demo | --repair | --uninstall | --remove-command | --restore-command]\n' "$0"
      ;;
    '')
      if [[ -f "$STATE" ]]; then manager; else install_fresh; fi
      ;;
    *) die "Неизвестный параметр: $1" ;;
  esac
fi
