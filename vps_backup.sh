#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Цвета — только если запущен в терминале (до настройки логирования)
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[1;34m'; PURPLE='\033[1;35m'; NC='\033[0m'
    ERROR_COLOR=$RED; WARNING_COLOR=$YELLOW; SUCCESS_COLOR=$GREEN
    INFO_COLOR=$BLUE; HEADER_COLOR=$PURPLE
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; PURPLE=''; NC=''
    ERROR_COLOR=''; WARNING_COLOR=''; SUCCESS_COLOR=''; INFO_COLOR=''; HEADER_COLOR=''
fi

LOCK_FILE="/tmp/vps_backup.lock"
BACKUP_STATUS_MAIN="skipped"
BACKUP_STATUS_RU="skipped"
FAILED_ITEMS=0
TOTAL_ITEMS=0

# === Лок-файл (защита от параллельных запусков) ===
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            echo "Бэкап уже запущен (PID: $pid), выходим"
            exit 1
        fi
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
}

# === Логирование в файл ===
setup_logging() {
    local log_dir="$SCRIPT_DIR/backups/logs"
    mkdir -p "$log_dir"
    LOG_FILE="$log_dir/backup_$(date +%Y%m%d_%H%M%S).log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "=== Бэкап запущен: $(date) ==="
}

# === Telegram-уведомление ===
notify_telegram() {
    local message="$1"
    [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ] && return 0
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=HTML" > /dev/null 2>&1 || true
}

# === Проверка файлов и загрузка переменных ===
check_required_files() {
    [ ! -f migrate.env ] && { echo -e "${ERROR_COLOR}Нет migrate.env${NC}"; exit 1; }
    [ ! -f id_ed25519 ] && { echo -e "${ERROR_COLOR}Нет id_ed25519${NC}"; exit 1; }

    source migrate.env
    [ -z "${NEW_USER:-}" ] && { echo -e "${ERROR_COLOR}Не задан NEW_USER${NC}"; exit 1; }

    SSH_KEY="$SCRIPT_DIR/id_ed25519"
    chmod 600 "$SSH_KEY"
}

# === Копирование одного элемента (без предварительной проверки через SSH) ===
backup_item() {
    local item_pair="$1"
    local source_host="$2"
    local base_path="$3"

    local src="${item_pair%%:*}"
    local dst="${item_pair##*:}"
    local name
    name=$(basename "$src" | sed 's|/*$||')

    TOTAL_ITEMS=$((TOTAL_ITEMS + 1))
    mkdir -p "$base_path$dst"

    local attempt
    for attempt in 1 2 3; do
        if rsync -aq --timeout=30 \
            -e "ssh -i $SSH_KEY -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
            "root@${source_host}:${src}" "$base_path$dst/" 2>/dev/null; then
            [ $attempt -gt 1 ] && echo -e "${SUCCESS_COLOR}✓ $name (попытка $attempt)${NC}" || echo -e "${SUCCESS_COLOR}✓ $name${NC}"
            return 0
        fi
        [ $attempt -lt 3 ] && sleep 5
    done
    echo -e "${WARNING_COLOR}⚠ $src — не найден или ошибка копирования${NC}"
    FAILED_ITEMS=$((FAILED_ITEMS + 1))
}

# === Бэкап movies-go (дамп БД через админский API-ключ + .env и plugins по rsync) ===
backup_movies_go() {
    local backup_path="$1"

    # 1. Полный дамп БД через API-ключ (вся БД: пользователи, токены, настройки, карточки)
    if [ -n "${MOVIES_GO_DOMAIN:-}" ] && [ -n "${MOVIES_GO_API_KEY:-}" ]; then
        TOTAL_ITEMS=$((TOTAL_ITEMS + 1))
        mkdir -p "$backup_path/main/movies-go"
        echo "Скачиваем дамп БД movies-go через API ($MOVIES_GO_DOMAIN)..."
        if curl -fsS --max-time 600 -H "X-API-Key: ${MOVIES_GO_API_KEY}" \
            "https://${MOVIES_GO_DOMAIN}/api/admin/backup" \
            -o "$backup_path/main/movies-go/movies-go-db.sql.gz"; then
            local size
            size=$(du -sh "$backup_path/main/movies-go/movies-go-db.sql.gz" 2>/dev/null | cut -f1)
            echo -e "${SUCCESS_COLOR}✓ movies-go-db.sql.gz ($size)${NC}"
        else
            rm -f "$backup_path/main/movies-go/movies-go-db.sql.gz"
            echo -e "${WARNING_COLOR}⚠ Не удалось скачать дамп movies-go через API${NC}"
            FAILED_ITEMS=$((FAILED_ITEMS + 1))
        fi
    else
        echo -e "${WARNING_COLOR}MOVIES_GO_DOMAIN/MOVIES_GO_API_KEY не заданы — дамп БД movies-go пропущен${NC}"
    fi

    # 2. .env и plugins/ — файлы на хосте, не в БД (как у других сервисов)
    local mg_path="/home/$NEW_USER/movies-go"
    backup_item "$mg_path/.env:/movies-go/" "$SOURCE_HOST" "$backup_path/main"
    backup_item "$mg_path/plugins:/movies-go/" "$SOURCE_HOST" "$backup_path/main"
}

# === Бэкап основного сервера ===
backup_main() {
    local backup_path="$1"
    local items_before=$FAILED_ITEMS

    local backup_items=(
        "/var/lib/marzban:/var/lib/"
        "/opt/marzban/.env:/opt/marzban/"
        "/home/$NEW_USER/docker/3x-ui:/home/$NEW_USER/docker/"
        "/usr/local/bin/sync-3xui-cert.sh:/usr/local/bin/"
        "/etc/systemd/system/3xui-cert.path:/etc/systemd/system/"
        "/etc/systemd/system/3xui-cert.service:/etc/systemd/system/"
        "/etc/nginx/sites-available:/etc/nginx/"
        "/etc/nginx/sites-enabled:/etc/nginx/"
        "/etc/nginx/nginx.conf:/etc/nginx/"
        "/etc/nginx/stream.conf:/etc/nginx/"
        "/etc/nginx/ssl:/etc/nginx/"
        "/etc/systemd/system/nginx.service.d:/etc/systemd/system/"
        "/root/antizapret:/root/"
        "/home/$NEW_USER/docker/lampac-nextgen/lampac-docker/config:/home/$NEW_USER/docker/lampac-nextgen/lampac-docker/"
        "/home/$NEW_USER/docker/lampac-nextgen/lampac-docker/mods:/home/$NEW_USER/docker/lampac-nextgen/lampac-docker/"
        "/home/$NEW_USER/docker/lampac-nextgen/lampac-docker/plugins:/home/$NEW_USER/docker/lampac-nextgen/lampac-docker/"
        "/home/$NEW_USER/docker/lampac-nextgen/lampac-docker/database:/home/$NEW_USER/docker/lampac-nextgen/lampac-docker/"
        "/home/$NEW_USER/docker/lampac-nextgen/docker-compose.yaml:/home/$NEW_USER/docker/lampac-nextgen/"
        "/home/$NEW_USER/docker/torrserver:/home/$NEW_USER/docker/"
        "/home/$NEW_USER/docker/watchtower:/home/$NEW_USER/docker/"
        "/home/$NEW_USER/docker/jackett:/home/$NEW_USER/docker/"
        "/etc/cloudflared/config.yml:/etc/cloudflared/"
        "/home/$NEW_USER/.cloudflared:/home/$NEW_USER/"
        "/etc/3proxy/3proxy.cfg:/etc/3proxy/"
        "/etc/systemd/system/glances.service:/etc/systemd/system/"
        "/home/$NEW_USER/.zshrc:/home/$NEW_USER/"
        "/home/$NEW_USER/.zprofile:/home/$NEW_USER/"
        "/etc/fail2ban/jail.local:/etc/fail2ban/"
        "/etc/fail2ban/filter.d/nginx-404.conf:/etc/fail2ban/filter.d/"
        "/etc/fail2ban/filter.d/nginx-noscript.conf:/etc/fail2ban/filter.d/"
        "/etc/fail2ban/filter.d/nginx-badbots.conf:/etc/fail2ban/filter.d/"
        "/etc/fail2ban/filter.d/nginx-req-limit.conf:/etc/fail2ban/filter.d/"
        "/usr/local/bin/ban:/usr/local/bin/"
    )

    for item in "${backup_items[@]}"; do
        backup_item "$item" "$SOURCE_HOST" "$backup_path/main"
    done

    if [ $FAILED_ITEMS -eq $items_before ]; then
        BACKUP_STATUS_MAIN="ok"
    else
        BACKUP_STATUS_MAIN="partial"
    fi
}

# === Бэкап RU-сервера ===
backup_ru() {
    local backup_path="$1"
    local items_before=$FAILED_ITEMS

    local backup_items_ru=(
        "/root/antizapret:/root/"
        "/root/myshows_proxy:/root/"
        "/root/az-world.sh:/root/"
        "/root/.ssh/id_ed25519:/root/.ssh/"
        "/etc/3proxy/3proxy.cfg:/etc/3proxy/"
        # AmneziaWG->home-LAN access (host-level, outside the antizapret stack)
        "/etc/wireguard/wg-home.conf:/etc/wireguard/"
        "/usr/local/bin/az-lan-firewall.sh:/usr/local/bin/"
        "/etc/systemd/system/az-lan-firewall.service:/etc/systemd/system/"
        "/etc/systemd/system/az-lan-firewall.timer:/etc/systemd/system/"
        "/etc/systemd/system/wg-quick@wg-home.service.d:/etc/systemd/system/"
    )

    for item in "${backup_items_ru[@]}"; do
        backup_item "$item" "$SOURCE_HOST_RU" "$backup_path/ru"
    done

    if [ $FAILED_ITEMS -eq $items_before ]; then
        BACKUP_STATUS_RU="ok"
    else
        BACKUP_STATUS_RU="partial"
    fi
}

# === Создание бэкапа ===
create_backup() {
    local backup_path="$SCRIPT_DIR/backups/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_path/main" "$backup_path/ru"

    echo -e "${INFO_COLOR}Бэкап: $backup_path${NC}"

    # --- Основной сервер ---
    if [ -n "${SOURCE_HOST:-}" ]; then
        echo -e "${HEADER_COLOR}--- Основной сервер ($SOURCE_HOST) ---${NC}"
        backup_main "$backup_path"
        backup_movies_go "$backup_path"
    else
        echo -e "${WARNING_COLOR}SOURCE_HOST не задан — пропускаем${NC}"
    fi

    # --- VPS_RU ---
    if [ -n "${SOURCE_HOST_RU:-}" ]; then
        echo -e "${HEADER_COLOR}--- VPS_RU ($SOURCE_HOST_RU) ---${NC}"
        backup_ru "$backup_path"
    else
        echo -e "${WARNING_COLOR}SOURCE_HOST_RU не задан — пропускаем${NC}"
    fi

    # Метаданные
    cat > "$backup_path/backup_info.txt" << EOF
Дата: $(date)
SOURCE_HOST: ${SOURCE_HOST:-не задан}
SOURCE_HOST_RU: ${SOURCE_HOST_RU:-не задан}
NEW_USER: $NEW_USER
Статус main: $BACKUP_STATUS_MAIN
Статус ru: $BACKUP_STATUS_RU
Ошибок: $FAILED_ITEMS из $TOTAL_ITEMS
EOF

    if [ $FAILED_ITEMS -eq 0 ]; then
        cleanup_old_backups "$SCRIPT_DIR/backups"
    else
        echo -e "${WARNING_COLOR}Очистка старых бэкапов пропущена — были ошибки${NC}"
    fi

    echo -e "${SUCCESS_COLOR}✓ Готово: $backup_path${NC}"
    echo "Ошибок: $FAILED_ITEMS из $TOTAL_ITEMS"

    # Telegram-уведомление — только при ошибках (если TELEGRAM_NOTIFY_ERRORS_ONLY=True)
    # или всегда (если False/не задано)
    local should_notify=false
    if [ $FAILED_ITEMS -gt 0 ]; then
        should_notify=true
    elif [ "${TELEGRAM_NOTIFY_ERRORS_ONLY:-True}" != "True" ]; then
        should_notify=true
    fi

    if $should_notify; then
        local status_icon="✅"
        [ $FAILED_ITEMS -gt 0 ] && status_icon="⚠️"
        notify_telegram "${status_icon} <b>VPS Backup</b>
Main: ${BACKUP_STATUS_MAIN}  RU: ${BACKUP_STATUS_RU}
Ошибок: ${FAILED_ITEMS}/${TOTAL_ITEMS}
<i>$(date '+%Y-%m-%d %H:%M')</i>"
    fi
}

# === Очистка старых бэкапов (оставляем 3 последних) ===
cleanup_old_backups() {
    local dir="$1"
    [ ! -d "$dir" ] && return

    local backups=()
    if [[ "$(uname)" == "Darwin" ]]; then
        while IFS= read -r line; do backups+=("$line"); done < <(find "$dir" -maxdepth 1 -type d -name "backup_*" -exec stat -f "%m %N" {} \; 2>/dev/null | sort -rn | awk '{print $2}')
    else
        while IFS= read -r line; do backups+=("$line"); done < <(find "$dir" -maxdepth 1 -type d -name "backup_*" -printf "%T@ %p\n" 2>/dev/null | sort -rn | awk '{print $2}')
    fi

    local keep=3
    [ ${#backups[@]} -le $keep ] && return

    for ((i=keep; i<${#backups[@]}; i++)); do
        echo "Удаляем старый бэкап: $(basename "${backups[$i]}")"
        rm -rf "${backups[$i]}"
    done

    # Логи ротируются вместе с бэкапами — оставляем столько же
    local log_dir="$dir/logs"
    [ ! -d "$log_dir" ] && return

    local logs=()
    if [[ "$(uname)" == "Darwin" ]]; then
        while IFS= read -r line; do logs+=("$line"); done < <(find "$log_dir" -maxdepth 1 -type f -name "backup_*.log" -exec stat -f "%m %N" {} \; 2>/dev/null | sort -rn | awk '{print $2}')
    else
        while IFS= read -r line; do logs+=("$line"); done < <(find "$log_dir" -maxdepth 1 -type f -name "backup_*.log" -printf "%T@ %p\n" 2>/dev/null | sort -rn | awk '{print $2}')
    fi

    [ ${#logs[@]} -le $keep ] && return

    for ((i=keep; i<${#logs[@]}; i++)); do
        echo "Удаляем старый лог: $(basename "${logs[$i]}")"
        rm -f "${logs[$i]}"
    done
}

# === Список бэкапов ===
list_backups() {
    local dir="$SCRIPT_DIR/backups"
    [ ! -d "$dir" ] && { echo "Нет бэкапов"; return; }

    echo -e "${INFO_COLOR}Бэкапы:${NC}"
    find "$dir" -maxdepth 1 -type d -name "backup_*" -exec basename {} \; | sort -r | while read -r name; do
        echo "  $name"
        [ -f "$dir/$name/backup_info.txt" ] && \
            grep -E "^(SOURCE_HOST|SOURCE_HOST_RU|Статус|Ошибок)" "$dir/$name/backup_info.txt" | \
            sed 's/^/    /'
    done
}

main() {
    case "${1:-}" in
        list|list-backups) check_required_files; list_backups; exit 0 ;;
        cleanup|clean)     check_required_files; cleanup_old_backups "$SCRIPT_DIR/backups"; exit 0 ;;
        help|-h|--help)
            echo "Использование: $0 [list|cleanup|help]"
            echo "Без аргументов — запускает бэкап обоих серверов"
            exit 0
            ;;
    esac

    acquire_lock
    mkdir -p "$SCRIPT_DIR/backups"
    setup_logging

    echo -e "${HEADER_COLOR}=== БЭКАП VPS ===${NC}"
    check_required_files

    create_backup

    echo -e "${HEADER_COLOR}=== ЗАВЕРШЕНО ===${NC}"
    echo "Лог: ${LOG_FILE:-не настроен}"
}

main "$@"
