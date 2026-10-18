# 3x-ui_reverse

**Русский** | [English](#english)

## Русский

**3x-ui_reverse** — Bash-скрипт для установки и управления **3x-ui** с обратным прокси **Caddy** или **Nginx** на VPS с Debian/Ubuntu.

### Возможности

- Установка 3x-ui и выбранного прокси с HTTPS для домена.
- Автоматический выпуск и продление TLS-сертификатов через прокси.
- Красивая страница-заглушка по основному адресу домена.
- Случайные логин, пароль, пути и внутренние порты панели и подписок.
- Доступ к панели и подпискам через прокси; внутренние сервисы привязаны к `127.0.0.1`.
- Цветное CLI-меню и динамический индикатор выполнения.
- Изменение настроек, проверка служб, переустановка и раздельное удаление компонентов.
- Возможность удалить прокси и перевести панель на прямой HTTPS.

### Установка

**Требования:** чистый VPS на Debian/Ubuntu, домен с A-записью на IP сервера и доступные порты TCP 80/443.

```bash
sudo bash 3x-ui_reverse_v5.sh
```

При запуске выберите Caddy или Nginx и укажите домен. После установки параметры доступа сохраняются в `/opt/3x-ui_reverse/panel.txt` (содержит секреты).

### Управление

```bash
sudo 3x-ui_reverse                 # Меню управления
sudo 3x-ui_reverse --demo          # Демонстрация интерфейса
sudo 3x-ui_reverse --repair        # Восстановление прерванной установки
sudo 3x-ui_reverse --uninstall     # Полное удаление
sudo 3x-ui_reverse --remove-command # Удаление только команды управления
```

> **Внимание:** операции удаления могут уничтожить конфигурацию и базу данных 3x-ui. Сделайте резервную копию перед использованием. Для HTTPS домен должен указывать на VPS.

---

## English

**3x-ui_reverse** is a Bash installer and management utility for running **3x-ui** behind a **Caddy** or **Nginx** reverse proxy on a Debian/Ubuntu VPS.

### Features

- Install 3x-ui and the selected reverse proxy with domain-based HTTPS.
- Automatic TLS certificate issuance and renewal managed by the proxy.
- A simple, polished coming-soon landing page at the domain root.
- Randomized credentials, paths, and internal ports for the panel and subscriptions.
- Proxy access to the panel and subscriptions, with backend services bound to `127.0.0.1`.
- Colorful CLI menu and dynamic installation progress display.
- Settings management, service checks, component reinstallation and selective removal.
- Optional removal of the proxy with migration to direct HTTPS for the panel.

### Installation

**Requirements:** a clean Debian/Ubuntu VPS, a domain A record pointing to the server, and accessible TCP ports 80/443.

```bash
sudo bash 3x-ui_reverse_v5.sh
```

Choose Caddy or Nginx and enter your domain. Connection details are saved to `/opt/3x-ui_reverse/panel.txt` (contains secrets).

### Management

```bash
sudo 3x-ui_reverse                  # Management menu
sudo 3x-ui_reverse --demo           # UI preview
sudo 3x-ui_reverse --repair         # Recover interrupted installation
sudo 3x-ui_reverse --uninstall      # Full removal
sudo 3x-ui_reverse --remove-command # Remove the management command only
```

> **Warning:** removal operations can delete 3x-ui configuration and database files. Back up your data first. HTTPS requires a domain pointing to the VPS.
