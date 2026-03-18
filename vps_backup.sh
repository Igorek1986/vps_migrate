#!/bin/bash
set -e

# Цветовые коды
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; PURPLE='\033[1;35m'; NC='\033[0m'
ERROR_COLOR=$RED; WARNING_COLOR=$YELLOW; SUCCESS_COLOR=$GREEN; INFO_COLOR=$BLUE; HEADER_COLOR=$PURPLE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Проверка файлов и загрузка переменных
check_required_files() {
    [ ! -f migrate.env ] && { echo -e "${ERROR_COLOR}Нет migrate.env${NC}"; exit 1; }
    [ ! -f id_ed25519 ] && { echo -e "${ERROR_COLOR}Нет id_ed25519${NC}"; exit 1; }
    
    source migrate.env
    [ -z "$NEW_USER" ] && { echo -e "${ERROR_COLOR}Не задан NEW_USER${NC}"; exit 1; }
    
    SSH_KEY="$SCRIPT_DIR/id_ed25519"
    chmod 600 "$SSH_KEY"
}

# Функция копирования одного элемента
backup_item() {
    local item_pair="$1"
    local source_host="$2"
    local base_path="$3"  # backup_path + subdir (main/ru)
    
    local src="${item_pair%%:*}"
    local dst="${item_pair##*:}"
    local name=$(basename "$src" | sed 's:/*$::')
    
    echo "Бэкапим: $src"
    
    if ssh -i "$SSH_KEY" root@"$source_host" "[ -e '$src' ]" 2>/dev/null; then
        mkdir -p "$base_path$dst"
        if rsync -aq -e "ssh -i $SSH_KEY" root@"$source_host:$src" "$base_path$dst/" 2>/dev/null; then
            echo -e "${SUCCESS_COLOR}✓ $name${NC}"
        else
            echo -e "${WARNING_COLOR}⚠ ошибка копирования $name${NC}"
        fi
    else
        echo -e "${WARNING_COLOR}⚠ $src не найден${NC}"
    fi
}

# Создание бэкапа
create_backup() {
    local backup_path="$SCRIPT_DIR/backups/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_path/main" "$backup_path/ru"
    
    echo -e "${INFO_COLOR}Бэкап: $backup_path${NC}"
    
    # === Основной сервер ===
    if [ -n "$SOURCE_HOST" ]; then
        echo -e "${HEADER_COLOR}Основной сервер ($SOURCE_HOST)${NC}"
        local backup_items=(
            "/var/lib/marzban:/var/lib/"
            "/opt/marzban/.env:/opt/marzban/"
            "/etc/nginx/sites-available:/etc/nginx/"
            "/etc/nginx/sites-enabled:/etc/nginx/"
            "/etc/nginx/nginx.conf:/etc/nginx/"
            "/etc/letsencrypt:/etc/"
            "/root/antizapret:/root/"  # ← из-под root
            "/home/$NEW_USER/NUMParser/db/numparser.db:/home/$NEW_USER/NUMParser/db/"
            "/home/lampac/module/manifest.json:/home/lampac/module/"
            "/home/lampac/init.conf:/home/lampac/"
            "/home/lampac/users.json:/home/lampac/"
            "/home/lampac/wwwroot/profileIcons:/home/lampac/wwwroot/"
            "/home/lampac/plugins/lampainit-invc.my.js:/home/lampac/plugins/"
            "/home/lampac/plugins/privateinit.my.js:/home/lampac/plugins/"
            "/home/lampac/wwwroot/my_plugins:/home/lampac/wwwroot/"
            "/home/lampac/database/:/home/lampac/database/"
            "/home/lampac/passwd:/home/lampac/"
            "/home/lampac/module/TimecodeUser/:/home/lampac/module/TimecodeUser/"
            "/home/$NEW_USER/movies-api:/home/$NEW_USER/"
            "/etc/3proxy/3proxy.cfg:/etc/3proxy/"
            "/etc/systemd/system/numparser.service:/etc/systemd/system/"
            "/etc/systemd/system/movies-api.service:/etc/systemd/system/"
            "/etc/systemd/system/glances.service:/etc/systemd/system/"
            "/home/$NEW_USER/.zshrc:/home/$NEW_USER/"
            "/home/$NEW_USER/.zprofile:/home/$NEW_USER/"
            "/etc/fail2ban/jail.local:/etc/fail2ban/"
            "/etc/fail2ban/filter.d/nginx-404.conf:/etc/fail2ban/filter.d/"
            "/etc/fail2ban/filter.d/nginx-noscript.conf:/etc/fail2ban/filter.d/"
            "/etc/fail2ban/filter.d/nginx-badbots.conf:/etc/fail2ban/filter.d/"
            "/etc/fail2ban/filter.d/nginx-req-limit.conf:/etc/fail2ban/filter.d/"
            "/usr/local/bin/ban:/usr/local/bin/ban"
        )
        
        for item in "${backup_items[@]}"; do
            backup_item "$item" "$SOURCE_HOST" "$backup_path/main"
        done
    else
        echo -e "${WARNING_COLOR}SOURCE_HOST не задан — пропускаем основной сервер${NC}"
    fi
    
    # === VPS_RU (только antizapret) ===
    if [ -n "$SOURCE_HOST_RU" ]; then
        echo -e "${HEADER_COLOR}VPS_RU ($SOURCE_HOST_RU) — antizapret, myshows_proxy${NC}"
        local backup_items_ru=(
            "/root/antizapret:/root/"
            "/root/myshows_proxy:/root/"
            )
        
        for item in "${backup_items_ru[@]}"; do
            backup_item "$item" "$SOURCE_HOST_RU" "$backup_path/ru"
        done
    else
        echo -e "${WARNING_COLOR}SOURCE_HOST_RU не задан — пропускаем VPS_RU${NC}"
    fi
    
    # Метаданные
    cat > "$backup_path/backup_info.txt" << EOF
Дата: $(date)
SOURCE_HOST: ${SOURCE_HOST:-не задан}
SOURCE_HOST_RU: ${SOURCE_HOST_RU:-не задан}
NEW_USER: $NEW_USER
EOF
    
    # Очистка старых бэкапов
    cleanup_old_backups "$SCRIPT_DIR/backups"
    
    echo -e "${SUCCESS_COLOR}✓ Готово: $backup_path${NC}"
}

# Очистка старых бэкапов (оставляем 3 последних)
cleanup_old_backups() {
    local dir="$1"
    [ ! -d "$dir" ] && return
    
    if [[ "$(uname)" == "Darwin" ]]; then
        mapfile -t backups < <(find "$dir" -maxdepth 1 -type d -name "backup_*" -exec stat -f "%m %N" {} \; 2>/dev/null | sort -rn | awk '{print $2}')
    else
        mapfile -t backups < <(find "$dir" -maxdepth 1 -type d -name "backup_*" -printf "%T@ %p\n" 2>/dev/null | sort -rn | awk '{print $2}')
    fi
    
    local keep=3
    [ ${#backups[@]} -le $keep ] && return
    
    for ((i=keep; i<${#backups[@]}; i++)); do
        echo "Удаляем: $(basename "${backups[$i]}")"
        rm -rf "${backups[$i]}"
    done
}

# Список бэкапов
list_backups() {
    local dir="$SCRIPT_DIR/backups"
    [ ! -d "$dir" ] && { echo "Нет бэкапов"; return; }
    
    echo -e "${INFO_COLOR}Бэкапы:${NC}"
    find "$dir" -maxdepth 1 -type d -name "backup_*" -exec basename {} \; | sort -r | while read name; do
        echo "  $name"
        [ -f "$dir/$name/backup_info.txt" ] && grep -E "^(SOURCE_HOST|SOURCE_HOST_RU)" "$dir/$name/backup_info.txt" | sed 's/^/    /'
    done
}

# Основная функция
main() {
    case "${1:-}" in
        list|list-backups) list_backups; exit 0 ;;
        cleanup|clean) cleanup_old_backups "$SCRIPT_DIR/backups"; exit 0 ;;
        help|-h|--help)
            echo "Использование: $0 [list|cleanup|help]"
            echo "Бэкапит оба сервера если заданы SOURCE_HOST и SOURCE_HOST_RU в migrate.env"
            exit 0
            ;;
    esac
    
    echo -e "${HEADER_COLOR}=== БЭКАП VPS ===${NC}"
    check_required_files
    create_backup
    echo -e "${HEADER_COLOR}=== ГОТОВО ===${NC}"
}

main "$@"