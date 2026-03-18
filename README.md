# VPS Migration Toolkit

**VPS Migration Toolkit** — набор Bash-скриптов для автоматизации резервного копирования, миграции и восстановления сервисов между VPS. Скрипты позволяют быстро и безопасно переносить сервисы, минимизируя ручной труд и риски.

## 🔍 Состав репозитория

- `vps_backup.sh` — создание резервной копии с одного или двух серверов (main + RU)
- `vps_restore.sh` — интерактивное восстановление данных на новом сервере из бэкапа
- `vps_migrate.sh` — автоматизация полного процесса миграции (устаревший, не поддерживается)
- `migrate.env_template` — шаблон файла с переменными окружения
- `movies-api.env_tempalte` — шаблон переменных окружения для сервиса movies-api
- `numparser_config_tempalte.yml` — шаблон конфига для NUMParser
- `backups/` — папка для хранения резервных копий (создаётся автоматически)
- `backups/logs/` — логи каждого запуска бэкапа (создаётся автоматически)
- `id_ed25519` — приватный SSH-ключ для доступа к серверам (добавляется вручную)

---

## 🚀 Быстрый старт

### 1. Клонирование и подготовка

```bash
git clone https://github.com/Igorek1986/vps_migrate.git
cd vps_migrate
```

### 2. Настройка окружения

```bash
cp migrate.env_template migrate.env
nano migrate.env
```
```bash
cp movies-api.env_tempalte movies-api.env
nano movies-api.env
```
```bash
cp numparser_config_tempalte.yml numparser_config.yml
nano numparser_config.yml
```

### 3. Добавьте приватный SSH-ключ

Поместите файл `id_ed25519` в корень проекта:
```bash
chmod 600 id_ed25519
```

### 4. Установите зависимости

MacOS:
```bash
brew install sshpass
```
Linux:
```bash
sudo apt-get install -y sshpass
```

---

## 🛠️ Основные команды

### Создание резервной копии

```bash
./vps_backup.sh
```

- Бэкап создаётся в `backups/backup_YYYYMMDD_HHMMSS/` с подпапками `main/` и `ru/`
- Если задан `SOURCE_HOST` — бэкапится основной сервер (main)
- Если задан `SOURCE_HOST_RU` — бэкапится RU-сервер (antizapret, myshows_proxy)
- Лог каждого запуска сохраняется в `backups/logs/`
- Автоматически удаляются старые бэкапы, остаётся 3 последних
- Защита от параллельных запусков через lock-файл

Дополнительные команды:
```bash
./vps_backup.sh list      # список бэкапов со статусом
./vps_backup.sh cleanup   # ручная очистка старых бэкапов
```

---

### Восстановление данных на новом сервере

```bash
./vps_restore.sh
```

Без аргументов скрипт запустит интерактивное меню:
1. **Выбор бэкапа** стрелками — список из `backups/`, отсортирован от новых к старым
2. **Выбор цели** стрелками — `main`, `ru` или `оба сервера`

По завершении выводится итоговая таблица (✓ / ✗ / —) по каждому шагу.

**Неинтерактивный режим** (для скриптов):
```bash
./vps_restore.sh ./backups/backup_YYYYMMDD_HHMMSS --target main
./vps_restore.sh ./backups/backup_YYYYMMDD_HHMMSS --target ru
./vps_restore.sh ./backups/backup_YYYYMMDD_HHMMSS --target both
```

---

### Добавление бэкапа в cron

Скрипт пишет лог автоматически в `backups/logs/`. Достаточно добавить задание:

```bash
crontab -e
```
```
0 4 * * * /home/user/code/vps_migrate/vps_backup.sh
```

При ошибках (или всегда, если `TELEGRAM_NOTIFY_ERRORS_ONLY=False`) придёт уведомление в Telegram.

---

## 📌 Поддерживаемые сервисы

| Сервис | Сервер |
|--------|--------|
| [Antizapret](https://github.com/xtrime-ru/antizapret-vpn-docker) — VPN с обходом блокировок (Docker Swarm) | main + RU |
| [Marzban](https://github.com/Gozargah/Marzban) — панель управления VPN | main |
| [Lampac](https://github.com/immisterio/Lampac) — медиа-агрегатор | main |
| [NUMParser](https://github.com/Igorek1986/NUMParser) — парсер rutor + сопоставление с TMDB | main |
| [Movies API](https://github.com/Igorek1986/movies-api) — JSON API поверх NUMParser | main |
| [3proxy](https://github.com/3proxy/3proxy) — лёгкий прокси-сервер | main |
| [Glances](https://github.com/nicolargo/glances) — мониторинг сервера | main |
| [Fail2ban](https://github.com/fail2ban/fail2ban) — защита от брутфорса | main |
| myshows_proxy — прокси для MyShows | RU |

---

## ⚙️ Переменные окружения

### migrate.env

```env
# Серверы
SOURCE_HOST=1.2.3.4          # IP исходного основного сервера
DEST_HOST=5.6.7.8            # IP целевого основного сервера
SOURCE_HOST_RU=1.2.3.5       # IP исходного RU-сервера
DEST_HOST_RU=5.6.7.9         # IP целевого RU-сервера

# Пользователь
NEW_USER=user
NEW_USER_PASSWORD=password
DEST_ROOT_PASSWORD=rootpass
SWAP_SIZE=2G

# DNS (Beget API)
BEGET_LOGIN=your_login
BEGET_PASSWORD=your_api_password
DOMAINS_TO_UPDATE_MAIN="example.ru"
DOMAINS_TO_UPDATE_RU="example.ru"

# Docker Hub (для Antizapret)
DOCKER_USER=your_login
DOCKER_PASSWORD=your_personal_access_token

# Telegram-уведомления
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
TELEGRAM_NOTIFY_ERRORS_ONLY="True"   # True — только при ошибках

# Go
GO_VERSION="go1.22.4"

# Режим отладки (DNS не обновляется при True)
DEBUG="True"

# Флаги выполнения шагов восстановления
RUN_SETUP_SSH_KEYS="False"
RUN_CREATE_USER="False"
RUN_INSTALL_BASE_PACKAGES="False"
# ... и т.д.
```

### movies-api.env

```env
TMDB_TOKEN='Bearer TOKEN'
RELEASES_DIR=releases
DEBUG=False
CACHE_CLEAR_PASSWORD=PASSWORD
```

### numparser_config.yml

```yaml
tmdbtoken: 'Bearer TOKEN'
```

---

## ⚠️ Безопасность

Скрипты автоматически при восстановлении:
- Копируют SSH-ключ на целевой сервер
- Отключают парольную аутентификацию в `sshd_config`
- Настраивают доступ только по ключу для root и пользователя

Проверка что доступ по паролю закрыт:
```bash
DEST_HOST="1.2.3.4"
NEW_USER="user"

# Должно вернуть: Permission denied (publickey)
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@"$DEST_HOST"
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no "$NEW_USER"@"$DEST_HOST"

# Должно работать
ssh root@"$DEST_HOST"
ssh "$NEW_USER"@"$DEST_HOST"
```

---

## ✅ Протестированные окружения

Миграция: Ubuntu 24.04 → Ubuntu 24.04

Запуск скриптов:
- macOS (современные версии)
- Debian 11/12
- Ubuntu 22.04 / 24.04

---

## Требования

- `rsync`
- `sshpass` (устанавливается автоматически если отсутствует)
- `git`
- SSH-ключ Ed25519 с доступом к серверам
