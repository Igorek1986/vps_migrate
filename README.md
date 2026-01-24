# VPS Migration Toolkit

**VPS Migration Toolkit** — набор Bash-скриптов для автоматизации резервного копирования, миграции и восстановления сервисов между VPS. Скрипты позволяют быстро и безопасно переносить сервисы, минимизируя ручной труд и риски.

## 🔍 Состав репозитория

- `vps_backup.sh` — создание резервной копии важных данных с исходного сервера
- `vps_restore.sh` — восстановление данных на новом сервере из бэкапа
- `vps_migrate.sh` — автоматизация полного процесса миграции (бэкап + копирование + восстановление + настройка)
- `migrate.env_template` — шаблон файла с переменными окружения для настройки миграции
- `movies-api.env_tempalte` — шаблон переменных окружения для сервиса movies-api
- `numparser_config_tempalte.yml` — шаблон конфига для NUMParser
- `backups/` — папка для хранения резервных копий (создается автоматически)
- `id_ed25519` — приватный SSH-ключ для доступа к серверам (добавляется вручную)

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
Заполните все необходимые переменные (см. раздел ниже).

### 3. Добавьте приватный SSH-ключ:
- Поместите файл `id_ed25519` в корень проекта.
- Установите права:
```bash
chmod 600 id_ed25519
```

### 4. Установите зависимости:
- Для MacOS:
```bash
brew install sshpass
```
- Для Linux:
```bash
sudo apt-get install -y sshpass
```

---

## 🛠️ Основные команды

### Создание резервной копии

```bash
./vps_backup.sh
```
Дополнительные опции:
- Бэкап будет создан в папке `backups/` с уникальным именем по дате и времени.
- Старые бэкапы автоматически удаляются, остаётся только 3 последних (можно изменить в скрипте).
- Для просмотра списка бэкапов:
```bash
./vps_backup.sh list
  ```
- Для ручной очистки старых бэкапов:
```bash
./vps_backup.sh cleanup
```

---

### Восстановление данных на новом сервере

**Вариант 1 (рекомендуется):**

```bash
./vps_restore.sh ./backups/backup_YYYYMMDD_HHMMSS
```

- IP-адрес и имя пользователя подтянутся автоматически из `migrate.env`.
- Скрипт создаст пользователя, скопирует все данные, настроит права и выведет дальнейшие инструкции.

- Если нужно указать другой IP или пользователя, используйте дополнительные аргументы:
```bash
./vps_restore.sh ./backups/backup_YYYYMMDD_HHMMSS <DEST_HOST> <NEW_USER> [NEW_USER_PASSWORD]
  ```

**Вариант 2 (ручной запуск restore.sh из папки бэкапа):**

```bash
cd backups/backup_YYYYMMDD_HHMMSS
./restore.sh <DEST_HOST> <NEW_USER> [NEW_USER_PASSWORD]
```

---

### Полная автоматизация миграции

```bash
./vps_migrate.sh
```

- Скрипт выполнит все этапы: создание бэкапа, копирование, восстановление, настройку сервисов.
- Все параметры берутся из `migrate.env`.
- Подходит для миграции "под ключ".

---

### 📌 Поддерживаемые сервисы
Скрипты настроены для работы со следующими сервисами:

- [Antizapret](https://github.com/xtrime-ru/antizapret-vpn-docker)
- [Marzban](https://github.com/Gozargah/Marzban) — панель управления VPN
- [Lampac](https://github.com/immisterio/Lampac) — медиа-агрегатор
- [NUMParser)](ttps://github.com/Igorek1986/NUMParser) — парсер для фильмов и сериалов с rutor и сопоставлением с TMDB (GitHub)
- [Movies API](https://github.com/Igorek1986/movies-api) — сервис для раздачи JSON данных от NUMParser (GitHub)
- [3proxy](https://github.com/3proxy/3proxy) — легковесный прокси-сервер
- [Glances](https://github.com/nicolargo/glances) — система мониторинга сервера


### ⚠️ Особенности безопасности
Скрипты автоматически:

- Отключают парольную аутентификацию для root и пользователя
- Настраивают доступ только по SSH-ключу
- Запрещают вход по паролю в sshd_config

### ✅ Протестированные окружения
Миграция: Ubuntu 24.04 → Ubuntu 24.04

Запуск скриптов:
- MacOS (современные версии)
- Debian (11/12)
- Ubuntu (22.04/24.04)


### Готовые команды для проверки доступа только по ключу
```bash

DEST_HOST="1.2.3.4"
NEW_USER="user"

#Permission denied (publickey).
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@"$DEST_HOST"
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no "$NEW_USER"@"$DEST_HOST"

#Access is allowed
ssh root@"$DEST_HOST"
ssh "$NEW_USER"@"$DEST_HOST"
```

---

### Добавление скрипта в крон

```bash
sudo touch /var/log/vps_backup.log
sudo chown user:user /var/log/vps_backup.log
sudo chmod 644 /var/log/vps_backup.log

crontab -e
  0 4 * * * /home/user/code/vps_migrate/vps_backup.sh >> /var/log/vps_backup.log 2>&1
  ```

---

## ⚙️ Настройка и описание шаблонов переменных

### migrate.env_template

Пример содержимого (обязательно заполните все переменные):

```env
SOURCE_HOST=1.2.3.4         # IP исходного сервера
DEST_HOST=5.6.7.8           # IP целевого сервера
NEW_USER=user               # Имя пользователя для создания
NEW_USER_PASSWORD=password  # Пароль пользователя (опционально)
DOMAINS_TO_UPDATE="example.com www.example.com"  # Домены для обновления DNS
BEGET_LOGIN=your_login      # Логин Beget для DNS API
BEGET_PASSWORD=your_pass    # Пароль Beget для DNS API
# ... другие переменные по необходимости ...
```

---

### movies-api.env_tempalte

Пример:

```env
TMDB_TOKEN='Bearer TOKEN'
RELEASES_DIR=releases
DEBUG=False
CACHE_CLEAR_PASSWORD=PASSWORD
```

---

### numparser_config_tempalte.yml

Пример:

```yaml
tmdbtoken: 'Bearer TOKEN'.
```

---

## Требования

- rsync
- sshpass
- git
- SSH-ключ с доступом к обоим серверам

---
