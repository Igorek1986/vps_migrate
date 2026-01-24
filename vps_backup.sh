#!/bin/bash

# Скрипт для создания бэкапов VPS
# Использование: ./vps_backup.sh
# ✅ ❌ 🚀 ⚠️ ▶️ 🕐 ⏹️ ⏳
set -e

# Цветовые коды
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
PURPLE='\033[1;35m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Цветовые коды для ошибок и предупреждений
ERROR_COLOR=$RED
WARNING_COLOR=$YELLOW
SUCCESS_COLOR=$GREEN
INFO_COLOR=$BLUE
HEADER_COLOR=$PURPLE
HIGHLIGHT_COLOR=$CYAN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Проверка наличия необходимых файлов
check_required_files() {
    local missing_files=()
    
    [ ! -f "migrate.env" ] && missing_files+=("migrate.env")
    [ ! -f "id_ed25519" ] && missing_files+=("id_ed25519")
    
    if [ ${#missing_files[@]} -ne 0 ]; then
        echo -e "${ERROR_COLOR}Отсутствуют необходимые файлы: ${missing_files[*]}${NC}"
        exit 1
    fi
    
    source migrate.env
    
    # Проверяем обязательные переменные для бэкапа
    if [ -z "$SOURCE_HOST" ] || [ -z "$NEW_USER" ]; then
        echo -e "${ERROR_COLOR}Не заданы обязательные переменные SOURCE_HOST или NEW_USER в migrate.env${NC}"
        exit 1
    fi
    
    SSH_KEY="$SCRIPT_DIR/id_ed25519"
    chmod 600 "$SSH_KEY"
}

# Проверка и установка sshpass
check_sshpass() {
    if ! command -v sshpass &> /dev/null; then
        echo "Устанавливаем sshpass..."
        if [[ "$(uname)" == "Darwin" ]]; then
            # Для MacOS
            brew install sshpass
        else
            echo "Добавляем репозиторий с sshpass для Debian..."
            # Для Linux
            sudo apt-get install -y sshpass || sudo yum install -y sshpass
        fi
    fi
}

# Создание бэкапа важных данных
create_backup() {
    echo -e "${INFO_COLOR}=== СОЗДАНИЕ БЭКАПА ВАЖНЫХ ДАННЫХ ===${NC}"
    
    # Создаем директорию для бэкапов
    local backup_dir="$SCRIPT_DIR/backups"
    mkdir -p "$backup_dir"
    
    # Генерируем имя бэкапа с датой и временем
    local backup_name="backup_$(date +%Y%m%d_%H%M%S)"
    local backup_path="$backup_dir/$backup_name"
    
    echo "Создаем бэкап: $backup_name"
    mkdir -p "$backup_path"
    
    # Список важных данных для бэкапа с путями восстановления
    local backup_items=(
        "/var/lib/marzban:/var/lib/"
        "/opt/marzban/.env:/opt/marzban/"
        "/etc/nginx/sites-available:/etc/nginx/"
        "/etc/nginx/sites-enabled:/etc/nginx/"
        "/etc/nginx/nginx.conf:/etc/nginx/"
        "/etc/letsencrypt:/etc/"
        "/home/$NEW_USER/antizapret:/home/$NEW_USER/"
        "/home/$NEW_USER/NUMParser/db/numparser.db:/home/$NEW_USER/NUMParser/db/"
        "/home/lampac/module/manifest.json:/home/lampac/module/"
        "/home/lampac/init.conf:/home/lampac/"
        "/home/lampac/users.json:/home/lampac/"
        "/home/lampac/wwwroot/profileIcons:/home/lampac/wwwroot/"
        "/home/lampac/plugins/lampainit.my.js:/home/lampac/plugins/"
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
    )
    
    # Создаем бэкап каждого элемента
    for item_pair in "${backup_items[@]}"; do
        local source_path="${item_pair%%:*}"
        local restore_path="${item_pair##*:}"
        local item_name=$(basename "$source_path")
        
        echo "Бэкапим: $source_path"
        
        if ssh -i "$SSH_KEY" root@"$SOURCE_HOST" "[ -e '$source_path' ]"; then
            # Создаем директорию для этого элемента в бэкапе
            local item_backup_dir="$backup_path$restore_path"
            mkdir -p "$item_backup_dir"
            
            # Копируем данные с сохранением владельца и прав через rsync
            if rsync -avz -e "ssh -i $SSH_KEY" \
                root@"$SOURCE_HOST:$source_path" \
                "$item_backup_dir/"; then
                echo -e "${SUCCESS_COLOR}✓ Бэкап $item_name создан${NC}"
            else
                echo -e "${WARNING_COLOR}⚠ Ошибка копирования $item_name${NC}"
            fi
        else
            echo -e "${WARNING_COLOR}⚠ $source_path не найден, пропускаем${NC}"
        fi
    done
    
    # Создаем файл с метаданными бэкапа
    cat > "$backup_path/backup_info.txt" << EOF
Дата создания: $(date)
Исходный сервер: $SOURCE_HOST
Пользователь: $NEW_USER
Домены: ${DOMAINS_TO_UPDATE:-"не заданы"}
Версия скрипта: $(git rev-parse HEAD 2>/dev/null || echo "unknown")
Метод копирования: rsync с сохранением владельца и прав

Содержимое бэкапа:
- Конфигурация Nginx (sites-available, sites-enabled)
- SSL сертификаты Let's Encrypt
- Конфигурация Marzban
- Конфигурация Lampac
- Конфигурация NUMParser
- Конфигурация Movies API
- Конфигурация 3proxy
- Конфигурация Glances
- Конфигурация fail2ban
- Пользовательские настройки (.zshrc, .zprofile)
EOF
    
    # Создаем скрипт для восстановления
    cat > "$backup_path/restore.sh" << 'EOF'
#!/bin/bash

# Скрипт восстановления из бэкапа
# Использование: ./restore.sh <DEST_HOST> <NEW_USER> [NEW_USER_PASSWORD]
# SSH ключ автоматически определяется из родительской директории

set -e

if [ $# -lt 2 ]; then
    echo "Использование: $0 <DEST_HOST> <NEW_USER> [NEW_USER_PASSWORD]"
    echo ""
    echo "Аргументы:"
    echo "  DEST_HOST        - IP-адрес или домен целевого сервера"
    echo "  NEW_USER         - Имя пользователя на целевом сервере"
    echo "  NEW_USER_PASSWORD - Пароль для пользователя (опционально)"
    echo ""
    echo "SSH ключ автоматически определяется из родительской директории"
    echo "Убедитесь, что id_ed25519 находится в корне проекта"
    exit 1
fi

DEST_HOST="$1"
NEW_USER="$2"
NEW_USER_PASSWORD="$3"

# Определяем путь к SSH ключу (на два уровня выше - корень проекта)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
SSH_KEY="$PROJECT_ROOT/id_ed25519"

echo "Восстанавливаем данные на $DEST_HOST..."
echo "Пользователь: $NEW_USER"
echo "SSH ключ: $SSH_KEY"

# Проверяем наличие SSH ключа
if [ ! -f "$SSH_KEY" ]; then
    echo "ОШИБКА: SSH ключ не найден: $SSH_KEY"
    echo "Убедитесь, что id_ed25519 находится в корне проекта"
    exit 1
fi

chmod 600 "$SSH_KEY"

# Проверяем подключение
echo "Проверяем подключение к серверу..."
if ! ssh -i "$SSH_KEY" -o ConnectTimeout=10 root@"$DEST_HOST" "echo 'Подключение успешно'" &> /dev/null; then
    echo "ОШИБКА: Не удалось подключиться к $DEST_HOST по SSH"
    exit 1
fi

# Создаем пользователя если его нет
echo "Проверяем и создаем пользователя $NEW_USER..."
if ! ssh -i "$SSH_KEY" root@"$DEST_HOST" "id -u $NEW_USER" &>/dev/null; then
    echo "Создаем пользователя $NEW_USER..."
    
    # Создаем пользователя
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "adduser --disabled-password --gecos '' $NEW_USER" || {
        echo "ОШИБКА: Не удалось создать пользователя $NEW_USER"
        exit 1
    }
    
    # Устанавливаем пароль если передан
    if [ -n "$NEW_USER_PASSWORD" ]; then
        echo "Устанавливаем пароль для пользователя $NEW_USER..."
        ssh -i "$SSH_KEY" root@"$DEST_HOST" "echo '$NEW_USER:$NEW_USER_PASSWORD' | chpasswd"
    fi
    
    # Добавляем в sudo группу
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "usermod -aG sudo $NEW_USER"
    
    # Настраиваем sudo права
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "echo '$NEW_USER ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/$NEW_USER"
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "chmod 440 /etc/sudoers.d/$NEW_USER"
    
    echo "✓ Пользователь $NEW_USER создан и настроен"
else
    echo "✓ Пользователь $NEW_USER уже существует"
fi

# Создаем домашнюю директорию если её нет
ssh -i "$SSH_KEY" root@"$DEST_HOST" "mkdir -p /home/$NEW_USER"
ssh -i "$SSH_KEY" root@"$DEST_HOST" "chown $NEW_USER:$NEW_USER /home/$NEW_USER"

# Восстанавливаем каждый элемент с сохранением владельца и прав
# Исключаем файлы самого бэкапа (backup_info.txt, restore.sh)
for item_dir in */; do
    if [ -d "$item_dir" ]; then
        item_name=$(basename "$item_dir")
        echo "Восстанавливаем: $item_name"
        
        # Определяем путь восстановления на основе структуры директорий
        case "$item_name" in
            "var")
                restore_path="/var/"
                ;;
            "etc")
                restore_path="/etc/"
                ;;
            "home")
                restore_path="/home/"
                ;;
            "opt")
                restore_path="/opt/"
                ;;
            *)
                restore_path="/tmp/"
                ;;
        esac
        
        # Восстанавливаем с сохранением владельца и прав через rsync
        # Копируем содержимое директории, а не саму директорию
        if rsync -avz -e "ssh -i $SSH_KEY" \
            "$item_dir/" \
            root@"$DEST_HOST:$restore_path"; then
            echo "✓ Восстановлен: $item_name"
            
            # Проверяем, что данные действительно скопировались
            echo "Проверяем восстановление..."
            case "$item_name" in
                "home")
                    if ssh -i "$SSH_KEY" root@"$DEST_HOST" "[ -d '/home/$NEW_USER' ]"; then
                        echo "✓ /home/$NEW_USER существует"
                        ssh -i "$SSH_KEY" root@"$DEST_HOST" "ls -la /home/$NEW_USER/"
                    else
                        echo "⚠ /home/$NEW_USER не найден"
                    fi
                    ;;
                "etc")
                    if ssh -i "$SSH_KEY" root@"$DEST_HOST" "[ -d '/etc/nginx' ]"; then
                        echo "✓ /etc/nginx существует"
                    else
                        echo "⚠ /etc/nginx не найден"
                    fi
                    
                    # Проверяем fail2ban
                    if ssh -i "$SSH_KEY" root@"$DEST_HOST" "[ -f '/etc/fail2ban/jail.local' ]"; then
                        echo "✓ /etc/fail2ban/jail.local существует"
                        # Перезапускаем fail2ban
                        ssh -i "$SSH_KEY" root@"$DEST_HOST" "systemctl restart fail2ban"
                        echo "✓ fail2ban перезапущен"
                    else
                        echo "⚠ /etc/fail2ban/jail.local не найден"
                    fi
                    ;;
                "var")
                    if ssh -i "$SSH_KEY" root@"$DEST_HOST" "[ -d '/var/lib/marzban' ]"; then
                        echo "✓ /var/lib/marzban существует"
                    else
                        echo "⚠ /var/lib/marzban не найден"
                    fi
                    ;;
            esac
        else
            echo "⚠ Ошибка восстановления: $item_name"
        fi
    fi
done

echo "Восстановление завершено!"
echo ""
echo "Данные скопированы. Теперь нужно установить зависимости и перезапустить службы."
echo "Используйте основной скрипт vps_restore.sh для полного восстановления."
echo ""
echo "Не забудьте:"
echo "  • Установить зависимости (Go, Poetry, pipx, 3proxy)"
echo "  • Пересобрать приложения (NUMParser, movies-api)"
echo "  • Перезапустить службы: systemctl restart nginx numparser movies-api glances 3proxy fail2ban"
echo "  • Проверить работу всех служб"
echo "  • Обновить DNS записи если необходимо"
echo "  • Проверить SSL сертификаты"
EOF
    
    chmod +x "$backup_path/restore.sh"
    
    # Очищаем старые бэкапы (оставляем только 5 последних)
    cleanup_old_backups "$backup_dir"
    
    echo -e "${SUCCESS_COLOR}✓ Бэкап создан: $backup_path${NC}"
    echo -e "${INFO_COLOR}Для восстановления используйте: $backup_path/restore.sh${NC}"
}

cleanup_old_backups() {
    local backup_dir="$1"
    local max_backups=3

    echo "Очищаем старые бэкапы (оставляем $max_backups последних)..."

    # Универсальный способ для macOS и Linux
    if [[ "$(uname)" == "Darwin" ]]; then
        # Для macOS
        local all_backups=($(find "$backup_dir" -maxdepth 1 -type d -name "backup_*" -exec stat -f "%m %N" {} \; | sort -rn | awk '{print $2}'))
    else
        # Для Linux и других Unix-систем
        local all_backups=($(find "$backup_dir" -maxdepth 1 -type d -name "backup_*" -printf "%T@ %p\n" | sort -rn | awk '{print $2}'))
    fi

    if [ ${#all_backups[@]} -le $max_backups ]; then
        echo "Количество бэкапов ($(( ${#all_backups[@]} ))) не превышает лимит ($max_backups), очистка не требуется"
        return
    fi

    for backup in "${all_backups[@]:$max_backups}"; do
        if [ -d "$backup" ]; then
            echo "Удаляем старый бэкап: $(basename "$backup")"
            rm -rf "$backup"
        fi
    done

    echo "Очистка завершена. Осталось бэкапов: $max_backups"
}

# Список доступных бэкапов
list_backups() {
    local backup_dir="$SCRIPT_DIR/backups"

    if [ ! -d "$backup_dir" ]; then
        echo -e "${WARNING_COLOR}Директория бэкапов не найдена${NC}"
        return
    fi

    echo -e "${INFO_COLOR}=== ДОСТУПНЫЕ БЭКАПЫ ===${NC}"

    local backups=()
    if stat -f "%m %N" "$backup_dir" &>/dev/null; then
        # macOS/BSD
        backups=($(find "$backup_dir" -maxdepth 1 -type d -name "backup_*" -exec stat -f "%m %N" {} \; | sort -rn | awk '{print $2}'))
    else
        # Linux
        backups=($(find "$backup_dir" -maxdepth 1 -type d -name "backup_*" -exec stat -c "%Y %n" {} \; | sort -rn | awk '{print $2}'))
    fi

    if [ ${#backups[@]} -eq 0 ]; then
        echo "Бэкапы не найдены"
        return
    fi

    echo -e "${INFO_COLOR}Всего бэкапов: ${#backups[@]}${NC}"

    for backup in "${backups[@]}"; do
        local backup_name=$(basename "$backup")
        local info_file="$backup/backup_info.txt"

        echo -e "${SUCCESS_COLOR}$backup_name${NC}"
        if [ -f "$info_file" ]; then
            echo "  Информация:"
            cat "$info_file" | sed 's/^/    /'
        fi
        echo ""
    done
}

# Принудительная очистка старых бэкапов
force_cleanup() {
    local backup_dir="$SCRIPT_DIR/backups"
    
    if [ ! -d "$backup_dir" ]; then
        echo -e "${WARNING_COLOR}Директория бэкапов не найдена${NC}"
        return
    fi
    
    echo -e "${INFO_COLOR}=== ПРИНУДИТЕЛЬНАЯ ОЧИСТКА БЭКАПОВ ===${NC}"
    cleanup_old_backups "$backup_dir"
}

# Главная функция
main() {
    # Обработка аргументов командной строки
    case "${1:-}" in
        "list"|"list-backups")
            list_backups
            exit 0
            ;;
        "cleanup"|"clean")
            force_cleanup
            exit 0
            ;;
        "help"|"-h"|"--help")
            echo -e "${INFO_COLOR}Использование: $0 [команда]${NC}"
            echo ""
            echo "Команды:"
            echo "  (без аргументов)  - Создать бэкап"
            echo "  list              - Показать список бэкапов"
            echo "  cleanup           - Принудительно очистить старые бэкапы (оставить 3 последних)"
            echo "  help              - Показать эту справку"
            echo ""
            echo "Примеры:"
            echo "  $0"
            echo "  $0 list"
            echo "  $0 cleanup"
            exit 0
            ;;
    esac

    echo -e "${HEADER_COLOR}=== СОЗДАНИЕ БЭКАПА VPS ===${NC}"
    
    check_sshpass
    check_required_files
    
    echo "Источник: $SOURCE_HOST"
    echo "Пользователь: $NEW_USER"
    
    create_backup
    
    echo -e "${HEADER_COLOR}=== БЭКАП ЗАВЕРШЕН ===${NC}"
}

main "$@"