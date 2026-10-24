# 3x-ui_reverse

**Русский** | [English](#english)

![version](https://img.shields.io/github/v/release/dohuyanevezuch/3x-ui_reverse?label=version)
![platform](https://img.shields.io/badge/Debian%2012%2F13%20%7C%20Ubuntu%2022.04%2F24.04-blue)

## Русский

**3x-ui_reverse** — скрипт для установки и управления панелью **3x-ui** за обратным прокси **Caddy** или **Nginx** на VPS с Debian/Ubuntu. Снаружи сервер выглядит как обычный сайт с HTTPS. Панель и подписки спрятаны за случайными путями. Пользователи подключаются через VLESS Reality (RAW и XHTTP) и MTProto для Telegram.

### Возможности

**Установка**
- Caddy или Nginx + Certbot с автоматическим выпуском и продлением сертификатов HTTPS.
- Страница-заглушка «Скоро открытие» на главной странице домена.
- 3x-ui ставится официальным установщиком. Панель и подписки слушают только `127.0.0.1` — даже при самом первом запуске.
- Случайные логин, пароль, пути и внутренние порты панели и подписок.
- Сразу создаются три inbound-а и пользователь `user1`:
  - `Vless RAW Reality`, `Vless xhttp Reality` и `mtproto`;
  - порты подбираются свободные (8443, 2053, 2083 и т. д.);
  - SNI проверяется сканером панели: подходят сайты, доступные из России и не на Cloudflare;
  - в начало названия добавляется страна VPS, например «Нидерланды Vless RAW Reality».

**Управление**
- Полноэкранный интерфейс с цветами и поддержкой мыши. Enter — подтвердить, Backspace — назад.
- Классический текстовый режим (`--cli`) и команды для скриптов.
- На главном экране: состояние прокси и 3x-ui, число пользователей — активных, просроченных и в сети.
- Пользователи:
  - таблица с группой, подключёнными inbound-ами, трафиком «использовано / всего» и состоянием;
  - в состоянии видно «в сети» или время последней активности и inbound, через который подключались;
  - добавление с лимитом трафика, сроком и группой;
  - выбор inbound-ов галочками, ссылки подписки.
- Группы: создание и состав, **массовое назначение inbound-ов всей группе** (установить ровно выбранные, подключить или отключить).
- Inbound-ы: список всех inbound-ов панели, создание недостающих, порты для файрвола.
- Смена портов, путей и логина/пароля с проверкой и автоматическим откатом при ошибке.
- Перезапуск служб, переустановка 3x-ui (данные сохраняются) или прокси, раздельное удаление компонентов.
- Можно удалить прокси и перевести панель на собственный HTTPS (acme.sh).

**Обновления**
- Экран «Версия»: проверка новых версий по тегам этого репозитория и обновление в одно действие. Прежняя версия сохраняется в `/opt/3x-ui_reverse/backups/`.
- Раз в сутки проверка идёт в фоне. Если вышла новая версия, в меню появится «● доступна vX.Y.Z».

### Требования

- Чистый VPS: Debian 12/13 или Ubuntu 22.04/24.04, доступ root.
- Домен, A-запись которого указывает на IP сервера.
- Открытые извне TCP 80 и 443, а также порты inbound-ов (скрипт покажет их в конце установки).

### Установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dohuyanevezuch/3x-ui_reverse/main/3x-ui_reverse_install.sh)
```

Выбери Caddy или Nginx и введи домен. В конце появятся адрес панели, логин и пароль, а также ссылки подписки для `user1`. Параметры сохраняются в `/opt/3x-ui_reverse/panel.txt` — файл содержит секреты.

Подписки доступны по трём адресам (вместо `SUB_ID` подставляется Sub ID пользователя):

| Формат | Для приложений |
|---|---|
| `https://домен/<путь>/SUB_ID` | Happ, v2rayNG, Streisand, Hiddify и др. (VLESS, MTProto) |
| `https://домен/<путь-json>/SUB_ID` | v2rayN, v2rayNG (JSON-конфигурация Xray) |
| `https://домен/<путь-clash>/SUB_ID` | Mihomo / Clash |

> Порты inbound-ов нужно открыть во **внешнем** файрволе хостера (панель провайдера, security groups). Скрипт сам открывает их только в уже включённом ufw или firewalld.

### Управление

```bash
sudo 3x-ui_reverse          # полноэкранное меню (TUI)
sudo 3x-ui_reverse --cli    # то же меню в виде текстовых вопросов
```

В TUI: ↑↓ или колесо мыши — выбор, Enter или клик — подтвердить, Backspace или правая кнопка мыши — назад, пробел — отметить пункт в списке. Если терминал слишком мал или curses недоступен, скрипт сам переходит в текстовый режим.

### Команды

```bash
sudo 3x-ui_reverse info                     # параметры и ссылки
sudo 3x-ui_reverse status                   # состояние служб и портов
sudo 3x-ui_reverse users                    # пользователи: группа, inbound-ы, трафик, активность
sudo 3x-ui_reverse users show anna          # карточка и ссылки подписки
sudo 3x-ui_reverse users add anna --gb 50 --days 30 --group Семья --inbounds 1,2,3
sudo 3x-ui_reverse users inbounds anna 1,2  # оставить пользователю ровно эти inbound-ы
sudo 3x-ui_reverse users group anna Работа  # сменить группу (без имени — снять)
sudo 3x-ui_reverse users del anna
sudo 3x-ui_reverse groups                   # группы и участники
sudo 3x-ui_reverse groups create Семья
sudo 3x-ui_reverse groups members Семья anna petr
sudo 3x-ui_reverse groups inbounds Семья set 1,3   # set | add | remove
sudo 3x-ui_reverse inbounds                 # все inbound-ы панели
sudo 3x-ui_reverse inbounds create          # создать недостающие inbound-ы скрипта
sudo 3x-ui_reverse version
sudo 3x-ui_reverse update --check           # только проверить
sudo 3x-ui_reverse update                   # проверить и установить
sudo 3x-ui_reverse --help
```

Номера inbound-ов (1,2,3) — это ID из списка `3x-ui_reverse inbounds`.

Служебные параметры:

```bash
sudo 3x-ui_reverse --demo            # предпросмотр интерфейса, ничего не меняет
sudo 3x-ui_reverse --repair          # продолжить прерванную установку
sudo 3x-ui_reverse --uninstall       # полное удаление
sudo 3x-ui_reverse --remove-command  # удалить только команду 3x-ui_reverse
sudo bash 3x-ui_reverse_install.sh --restore-command   # вернуть команду
```

### Переменные окружения

| Переменная | Назначение |
|---|---|
| `XR_UI=cli` | всегда текстовый режим |
| `XR_SNI=a.com,b.com,c.com` | свои SNI для трёх inbound-ов вместо автоподбора |
| `XR_SNIFF=metadata` | сниффинг только по метаданным (по умолчанию `route` — домен используется только для маршрутизации) |
| `XR_COUNTRY=NL` / `XR_COUNTRY=none` | задать страну в названиях inbound-ов или убрать её |
| `XR_REPO=owner/name` | другой репозиторий для проверки обновлений |
| `NO_COLOR=1` | вывод без цветов |

Пример: `XR_SNI=www.microsoft.com,www.samsung.com,www.nvidia.com bash <(curl -fsSL …)`

### Как определяется активность пользователей

«В сети» — данные 3x-ui о текущих подключениях. Inbound последней активности скрипт узнаёт из журнала Xray. Раз в минуту журнал разбирается и сразу очищается, поэтому адреса посещённых сайтов на диске не хранятся, а IP клиентов в нём замаскированы. Для MTProto используется статистика mtg.

### Обновление

Из меню: **Версия → Проверить обновления → Обновить до vX.Y.Z**. Или командой `sudo 3x-ui_reverse update`. Скрипт скачивает файл того коммита, на который указывает тег новой версии, проверяет его и только потом заменяет команду.

Если на сервере стоит старая версия без экрана «Версия» (v1.x), обнови её один раз вручную — скачай файл и запусти его:

```bash
curl -fsSLo 3x-ui_reverse_install.sh https://raw.githubusercontent.com/dohuyanevezuch/3x-ui_reverse/main/3x-ui_reverse_install.sh
sudo bash 3x-ui_reverse_install.sh
```

Скрипт увидит существующую установку, заменит команду `3x-ui_reverse` новой версией и откроет меню. Дальнейшие обновления — уже из меню.

### Файлы на сервере

| Путь | Что там |
|---|---|
| `/opt/3x-ui_reverse/panel.txt` | адреса, логин и пароль (секреты, chmod 600) |
| `/opt/3x-ui_reverse/install.log` | журнал операций |
| `/opt/3x-ui_reverse/backups/` | резервные копии базы и прежних версий скрипта |
| `/opt/3x-ui_reverse/site/` | страница-заглушка |
| `/usr/local/sbin/3x-ui_reverse` | команда управления |

> **Внимание:** операции удаления уничтожают конфигурацию, пользователей и базу 3x-ui. Перед ними сделай резервную копию. Для HTTPS домен должен указывать на VPS.

### Для разработчика: выпуск версии

Серверы обновляются по тегам `vX.Y.Z`. Тег должен стоять на коммите, где в файле есть строка `VERSION=vX.Y.Z` с тем же номером, иначе обновление отклоняется. Номера только растут, теги не переиспользуются.

```bash
./release.sh v2.0.2 "что изменилось"
```

`release.sh` сам впишет `VERSION`, проверит синтаксис, сделает коммит и тег, отправит их на GitHub и создаст Release (если установлен `gh`).

---

## English

**3x-ui_reverse** installs and manages the **3x-ui** panel behind a **Caddy** or **Nginx** reverse proxy on a Debian/Ubuntu VPS. From the outside the server looks like an ordinary HTTPS website. The panel and subscriptions live under random paths. Users connect via VLESS Reality (RAW and XHTTP) and MTProto for Telegram.

### Features

- Caddy or Nginx + Certbot with automatic HTTPS, plus a "coming soon" landing page.
- 3x-ui installed by the official installer. The panel and subscriptions are bound to `127.0.0.1`, even on the very first start.
- Random credentials, paths and internal ports.
- Created automatically:
  - `Vless RAW Reality`, `Vless xhttp Reality`, `mtproto` and user `user1`;
  - free ports are picked for them;
  - SNIs are verified by the panel's Reality scanner;
  - inbound names are prefixed with the VPS country.
- Full-screen TUI with colours and mouse support (Enter — confirm, Backspace — back), a classic text mode (`--cli`) and scriptable commands.
- Main screen shows proxy and panel status and user counts (active, expired, online).
- Users:
  - table with group, attached inbounds, traffic used/total, online state or last activity and the inbound used;
  - create with limits and group, toggle inbounds, show subscription links.
- Groups, including **bulk assignment of inbounds to a whole group** (set / add / remove).
- Overview of every inbound in the panel; creation of the missing ones.
- Port/path/credential changes with automatic rollback; reinstall or remove components separately; optional migration to direct HTTPS.
- Version screen with update checks against this repository's tags and one-step updates; a daily background check.

### Requirements

A clean Debian 12/13 or Ubuntu 22.04/24.04 VPS with root access, a domain whose A record points to the server, TCP 80/443 open, and the inbound ports open (shown at the end of the installation).

### Installation

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dohuyanevezuch/3x-ui_reverse/main/3x-ui_reverse_install.sh)
```

Choose Caddy or Nginx and enter your domain. Connection details are saved to `/opt/3x-ui_reverse/panel.txt` (contains secrets).

### Management

```bash
sudo 3x-ui_reverse              # full-screen menu (TUI)
sudo 3x-ui_reverse --cli        # the same menu as text prompts
sudo 3x-ui_reverse users        # users: group, inbounds, traffic, activity
sudo 3x-ui_reverse users add anna --gb 50 --days 30 --group Family --inbounds 1,2,3
sudo 3x-ui_reverse groups inbounds Family set 1,3
sudo 3x-ui_reverse inbounds     # all inbounds of the panel
sudo 3x-ui_reverse update       # check for and install updates
sudo 3x-ui_reverse --help       # all commands
```

Maintenance flags: `--demo`, `--repair`, `--uninstall`, `--remove-command`, `--restore-command`.

Upgrading from v1.x (no "Version" screen yet): download the script and run it once from the file — `curl -fsSLo 3x-ui_reverse_install.sh <raw URL above> && sudo bash 3x-ui_reverse_install.sh`. Later updates are done from the menu.

Environment variables: `XR_UI=cli`, `XR_SNI=a.com,b.com,c.com`, `XR_SNIFF=route|metadata`, `XR_COUNTRY=NL|none`, `XR_REPO=owner/name`, `NO_COLOR=1`.

> **Warning:** removal operations delete the 3x-ui configuration, users and database. Back up first. HTTPS requires the domain to point to the VPS.

### Releasing (maintainers)

Servers update from `vX.Y.Z` tags. The tagged commit must contain `VERSION=vX.Y.Z` with the same number. Run `./release.sh v2.0.2 "notes"` — it bumps `VERSION`, checks the script, commits, tags, pushes and creates a GitHub Release (if `gh` is installed).
