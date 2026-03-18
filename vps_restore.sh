#!/bin/bash

# Скрипт для восстановления VPS из локального бэкапа
# Использование: ./vps_restore_from_backup.sh <backup_path>
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Функция для очистки known_hosts
clear_known_hosts() {
    local host="$1"
    ssh-keygen -R "$host" -f ~/.ssh/known_hosts >/dev/null 2>&1
    sed -i.bak "/$host/d" ~/.ssh/known_hosts 2>/dev/null || true
}

# Проверка и установка sshpass
check_sshpass() {
    if ! command -v sshpass &> /dev/null; then
        echo "Устанавливаем sshpass..."
        if [[ "$(uname)" == "Darwin" ]]; then
            brew install sshpass
        else
            sudo apt-get install -y sshpass || sudo yum install -y sshpass
        fi
    fi
}

# Проверка наличия необходимых файлов
check_required_files() {
    local missing_files=()
    
    [ ! -f "migrate.env" ] && missing_files+=("migrate.env")
    [ ! -f "id_ed25519" ] && missing_files+=("id_ed25519")
    [ ! -f "id_ed25519.pub" ] && missing_files+=("id_ed25519.pub")
    [ ! -f "movies-api.env" ] && missing_files+=("movies-api.env")
    [ ! -f "numparser_config.yml" ] && missing_files+=("numparser_config.yml")
    
    if [ ${#missing_files[@]} -ne 0 ]; then
        echo -e "${RED}Отсутствуют необходимые файлы: ${missing_files[*]}${NC}"
        exit 1
    fi
    
    source migrate.env
    
    # Обязательные переменные
    required_vars=(
        "DEST_HOST" "DEST_ROOT_PASSWORD" 
        "NEW_USER" "NEW_USER_PASSWORD" "DOMAINS_TO_UPDATE_MAIN" 
        "SWAP_SIZE"
        "BEGET_LOGIN" "BEGET_PASSWORD"
        "DEBUG"
        # Флаги выполнения функций
        "RUN_SETUP_SSH_KEYS" "RUN_CREATE_USER" "RUN_INSTALL_BASE_PACKAGES"
        "RUN_SETUP_OH_MY_ZSH" "RUN_INSTALL_PYENV" "RUN_INSTALL_POETRY"
        "RUN_INSTALL_LAMPAC" "RUN_TRANSFER_NGINX_CERTS" "RUN_SETUP_MARZBAN"
        "RUN_INSTALL_GO" "RUN_SETUP_ANTIZAPRET" "RUN_SETUP_NUMPARSER"
        "RUN_SETUP_MOVIES_API" "RUN_SETUP_3PROXY" "RUN_SETUP_GLANCES"
        "RUN_SETUP_SWAP"
        "RUN_SETUP_FAIL2BAN"  # Добавлен флаг для fail2ban
        "RUN_UPDATE_DNS_RECORDS"
        "RUN_CLEANUP"
    )
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            echo -e "${RED}Не задана переменная $var в migrate.env${NC}"
            exit 1
        fi
    done
    
    SSH_KEY="$SCRIPT_DIR/id_ed25519"
    SSH_PUB_KEY="$SCRIPT_DIR/id_ed25519.pub"
    chmod 600 "$SSH_KEY"
}

# =============================================
# Функция-обертка для выполнения команд
# =============================================
run_if_enabled() {
    local func_name=$1
    local flag_name="RUN_$(echo $func_name | tr '[:lower:]' '[:upper:]')"
    
    if [ "${!flag_name}" = "True" ]; then
        echo -e "\n${BLUE}=== ВЫПОЛНЕНИЕ: ${func_name} ===${NC}"
        $func_name
    else
        echo -e "\n${YELLOW}=== ПРОПУСК: ${func_name} (отключено в конфиге) ===${NC}"
    fi
}

# Функция для безопасного выполнения SSH-команд с обработкой known_hosts
safe_ssh() {
    local host="$1"
    local command="$2"
    local known_hosts="$HOME/.ssh/known_hosts"
    
    # Удаляем старые записи по IP/домену
    ssh-keygen -R "$host" -f "$known_hosts" >/dev/null 2>&1
    sed -i.bak "/$host/d" "$known_hosts" 2>/dev/null

    # Выполняем команду с автоматическим принятием нового ключа
    ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" "$host" "$command"
    
    # Проверяем статус выполнения
    if [ $? -ne 0 ]; then
        echo -e "${RED}Ошибка выполнения команды на $host: $command${NC}" >&2
        return 1
    fi
}

safe_sshpass() {
    local host="$1"
    local command="$2"
    local password="$3"

    sshpass -p "$password" ssh -o StrictHostKeyChecking=no "$host" "$command"
    if [ $? -ne 0 ]; then
        echo -e "${RED}Ошибка выполнения команды на $host: $command${NC}" >&2
        return 1
    fi
}

# Выбор цели восстановления
select_restore_target() {
    local backup_path="$1"
    
    # Проверяем наличие директорий в бэкапе
    local has_main=false
    local has_ru=false
    [ -d "$backup_path/main" ] && has_main=true
    [ -d "$backup_path/ru" ] && has_ru=true
    
    if ! $has_main && ! $has_ru; then
        echo -e "${RED}В бэкапе нет директорий main/ или ru/${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}Доступные данные в бэкапе:${NC}"
    $has_main && echo "  [✓] main — полная инфраструктура"
    $has_ru && echo "  [✓] ru   — antizapret (/root/antizapret)"
    echo ""
    
    # Формируем подсказку выбора
    local prompt="Ваш выбор [1"
    $has_ru && prompt+=" / 2"
    $has_main && $has_ru && prompt+=" / 3"
    prompt+="]: "
    
    # Интерактивный выбор
    local choice
    while true; do
        echo -e "${BLUE}Выберите что восстанавливать:${NC}"
        echo "  1) main   — основной сервер"
        $has_ru && echo "  2) ru     — российский сервер (antizapret)"
        $has_main && $has_ru && echo "  3) оба    — оба сервера"
        echo -n "$prompt"
        read -r choice
        
        case "$choice" in
            1) RESTORE_TARGET="main"; break ;;
            2) if $has_ru; then RESTORE_TARGET="ru"; break; else echo -e "${YELLOW}В бэкапе нет ru/${NC}"; fi ;;
            3) if $has_main && $has_ru; then RESTORE_TARGET="both"; break; else echo -e "${YELLOW}Недостаточно данных для восстановления обоих${NC}"; fi ;;
            *) echo -e "${YELLOW}Неверный выбор${NC}" ;;
        esac
    done
    
    echo -e "${GREEN}Выбрано: $RESTORE_TARGET${NC}"
}

myshows_proxy_ru() {
    local dest_host="$1"
    local backup_path="$2"

    echo -e "${BLUE}=== ВОССТАНОВЛЕНИЕ myshows_proxy (ru) ===${NC}"
    
    if [ ! -d "$backup_path/ru/root/myshows_proxy" ]; then
        echo -e "${RED}В бэкапе нет /root/myshows_proxy${NC}"
        return 1
    fi

    # Копируем данные
    echo "Копируем /root/myshows_proxy..."
    rsync -aq -e "ssh -i $SSH_KEY" "$backup_path/ru/root/myshows_proxy/" root@"$dest_host":/root/myshows_proxy/

    # Запускаем install.sh
    echo "Запускаем install.sh..."
    ssh -i "$SSH_KEY" root@"$dest_host" "cd /root/myshows_proxy && chmod +x install.sh && ./install.sh"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ myshows_proxy успешно восстановлен${NC}"
        return 0
    else
        echo -e "${RED}✗ Ошибка при установке myshows_proxy${NC}"
        return 1
    fi
}

restore_antizapret_ru() {
    local dest_host="$1"
    local backup_path="$2"
    
    echo -e "${BLUE}=== ВОССТАНОВЛЕНИЕ antizapret (ru) ===${NC}"
    
    if [ ! -d "$backup_path/ru/root/antizapret" ]; then
        echo -e "${RED}В бэкапе нет /root/antizapret${NC}"
        return 1
    fi

    echo "Исправляем локали на $dest_host..."
    fix_system_locale "$dest_host"

    # Устанавливаем ядерные модули для производительности
    install_openvpn_dco "$dest_host"
    install_amneziawg "$dest_host"

    # Устанавливаем Docker
    echo "Устанавливаем Docker..."
    install_docker_if_needed "$dest_host" "root"
    
    # Копируем данные
    echo "Копируем /root/antizapret..."
    rsync -aq -e "ssh -i $SSH_KEY" "$backup_path/ru/root/antizapret/" root@"$dest_host":/root/antizapret/
    
    # Устанавливаем hostname
    echo "Устанавливаем hostname..."
    safe_ssh root@"$dest_host" "hostnamectl set-hostname az-local"
    
    # Инициализируем Swarm
    echo "Инициализируем Docker Swarm на $dest_host..."
    SWARM_TOKEN=$(safe_ssh root@"$dest_host" "
        if docker info 2>/dev/null | grep -q 'Swarm: active'; then
            docker swarm join-token worker -q
        else
            docker swarm init --advertise-addr $dest_host 2>&1 | grep -oP 'SWMTKN-[0-9a-zA-Z_-]+' || echo 'ERROR'
        fi
    ")
    
    if [[ "$SWARM_TOKEN" == "ERROR" || -z "$SWARM_TOKEN" ]]; then
        echo -e "${RED}Ошибка инициализации Swarm${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✓ Swarm инициализирован на $dest_host${NC}"
    
    # Присоединяем основной сервер
    local target_host=""
    if [ "$RESTORE_TARGET" = "ru" ]; then
        target_host="$SOURCE_HOST"
        echo "Присоединяем старый основной сервер ($SOURCE_HOST) к Swarm..."
    elif [ "$RESTORE_TARGET" = "both" ]; then
        target_host="$DEST_HOST"
        echo "Присоединяем новый основной сервер ($DEST_HOST) к Swarm..."
    fi
    
    if [ -n "$target_host" ]; then
        if ping -c 1 "$target_host" &>/dev/null; then
            echo "Устанавливаем Docker на $target_host..."
            install_docker_if_needed "$target_host" "root"
            # Присоединяем к сварму
            safe_ssh root@"$target_host" "
                docker swarm leave --force 2>/dev/null || true
                docker swarm join --token $SWARM_TOKEN $dest_host:2377
            "
            echo -e "${GREEN}✓ Сервер $target_host присоединён к Swarm${NC}"
        else
            echo -e "${YELLOW}⚠ $target_host недоступен, пропускаем присоединение${NC}"
        fi
    fi
    
    # Аутентификация в Docker Hub
    if [ -n "$DOCKER_USER" ] && [ -n "$DOCKER_PASSWORD" ]; then
        echo "Аутентифицируемся в Docker Hub..."
        safe_ssh root@"$dest_host" "
            echo '$DOCKER_PASSWORD' | docker login -u '$DOCKER_USER' --password-stdin 2>&1 | grep -q 'Login Succeeded' && \
            echo '✓ Успешная аутентификация'
        " | grep -q "✓" || echo -e "${YELLOW}⚠ Аутентификация не удалась${NC}"
    else
        echo -e "${YELLOW}⚠ DOCKER_USER/DOCKER_PASSWORD не заданы — возможны ошибки лимита Docker Hub${NC}"
    fi
    
    # Подготовка и деплой стека
    echo "Подготавливаем и деплоим стек Antizapret..."
    safe_ssh root@"$dest_host" "
        cd /root/antizapret
        
        # Лейблы узлов
        docker node update --label-add location=local az-local
        [ -n \"$target_host\" ] && docker node update --label-add location=world az-world || true
        
        # Создаём конфиг-папки
        docker compose pull
        docker compose up -d
        sleep 60
        docker compose down
        
        # Деплой в сварм
        docker compose config | docker run --rm -i xtrime/antizapret-vpn:5 compose2swarm | \
        docker stack deploy --prune -c - antizapret
    "

    # Обновление DNS только в production-режиме
    if [ "$DEBUG" = "False" ]; then
        update_dns_records "$dest_host" "$DOMAINS_TO_UPDATE_RU"
        update_migrate_env_after_restore
    fi
    
    echo -e "${GREEN}✓ Antizapret восстановлен на $dest_host${NC}"
    echo -e "${CYAN}Статус сервисов:${NC}"
    safe_ssh root@"$dest_host" "docker service ls --filter name=antizapret"
}

install_openvpn_dco() {
    local host="$1"
    
    echo "Устанавливаем OpenVPN DCO kernel module на $host..."
    
    safe_ssh root@"$host" "
        export LC_ALL=C LANG=C
        
        # Определяем версию Ubuntu
        UBUNTU_VERSION=\$(lsb_release -rs 2>/dev/null || grep -oP 'VERSION_ID=\"\K[0-9.]+' /etc/os-release | head -1)
        
        if [[ \"\$UBUNTU_VERSION\" == \"24.04\" ]]; then
            echo \"Ubuntu 24.04 — устанавливаем из репозитория...\"
            apt update -qq
            apt install -y openvpn-dco-dkms
        elif [[ \"\$UBUNTU_VERSION\" == \"22.04\" || \"\$UBUNTU_VERSION\" == \"20.04\" ]]; then
            echo \"Ubuntu \$UBUNTU_VERSION — устанавливаем из .deb...\"
            apt update -qq
            apt install -y dkms linux-headers-\$(uname -r) efivar
            
            # Скачиваем и устанавливаем пакет вручную
            DEB_URL=\"http://archive.ubuntu.com/ubuntu/pool/universe/o/openvpn-dco-dkms/openvpn-dco-dkms_0.0+git20231103-1_all.deb\"
            wget -q \"\$DEB_URL\" -O /tmp/openvpn-dco-dkms.deb && \
            dpkg -i /tmp/openvpn-dco-dkms.deb || apt --fix-broken install -y
        else
            echo \"⚠ Неизвестная версия Ubuntu (\$UBUNTU_VERSION) — пропускаем установку DCO\"
            exit 0
        fi
        
        # Проверяем установку
        if modprobe openvpn-dco 2>/dev/null; then
            echo '✓ OpenVPN DCO kernel module загружен'
            lsmod | grep openvpn-dco
        else
            echo '⚠ Модуль не загружен (требуется перезагрузка для активации)'
            echo '  Выполните после восстановления: sudo reboot'
        fi
    "
}

install_amneziawg() {
    local host="$1"
    
    echo "Устанавливаем Amnezia WireGuard kernel module на $host..."
    
    safe_ssh root@"$host" "
        export LC_ALL=C LANG=C
        
        # Определяем версию Ubuntu
        UBUNTU_VERSION=\$(lsb_release -rs 2>/dev/null || grep -oP 'VERSION_ID=\"\K[0-9.]+' /etc/os-release | head -1)
        
        # Добавляем ключ репозитория Amnezia
        apt install -y software-properties-common gnupg 2>/dev/null
        add-apt-repository -y ppa:amnezia/ppa 2>/dev/null || {
            # Ручное добавление если нет add-apt-repository
            echo 'deb http://ppa.launchpad.net/amnezia/ppa/ubuntu \$UBUNTU_VERSION main' | \\
                sed \"s/\\\$UBUNTU_VERSION/\$UBUNTU_VERSION/\" > /etc/apt/sources.list.d/amnezia.list
            apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 0x7B276667 2>/dev/null || true
        }
        
        if [[ \"\$UBUNTU_VERSION\" == \"24.04\" ]]; then
            echo \"Ubuntu 24.04 — устанавливаем amneziawg...\"
            apt update -qq
            apt install -y amneziawg dkms linux-headers-\$(uname -r)
        elif [[ \"\$UBUNTU_VERSION\" == \"22.04\" || \"\$UBUNTU_VERSION\" == \"20.04\" ]]; then
            echo \"Ubuntu \$UBUNTU_VERSION — устанавливаем amneziawg с исходниками ядра...\"
            apt update -qq
            
            # Раскомментируем deb-src в sources.list
            sed -i 's/^# deb-src/deb-src/' /etc/apt/sources.list 2>/dev/null || true
            
            # Устанавливаем зависимости
            apt install -y dkms linux-headers-\$(uname -r) build-essential libelf-dev
            
            # Устанавливаем amneziawg
            apt install -y amneziawg
            
            # Принудительно пересобираем модуль через DKMS
            dkms install -m amneziawg -v 1.0.0 2>/dev/null || true
        else
            echo \"⚠ Неизвестная версия Ubuntu (\$UBUNTU_VERSION) — пропускаем установку amneziawg\"
            exit 0
        fi
        
        # Загружаем модуль
        modprobe amneziawg 2>/dev/null || true
        
        # Проверяем установку
        echo '=== Проверка установки ==='
        if dkms status 2>/dev/null | grep -q amneziawg; then
            echo '✓ amneziawg зарегистрирован в DKMS'
        else
            echo '⚠ amneziawg не найден в DKMS (может потребоваться перезагрузка)'
        fi
        
        if lsmod | grep -q amneziawg; then
            echo '✓ amneziawg kernel module загружен'
            echo '  Для активации в Антизапрете выполните:'
            echo '  docker service update --force antizapret_wireguard-amnezia'
        else
            echo '⚠ Модуль не загружен (требуется перезагрузка или перезапуск сервиса)'
            echo '  Выполните после восстановления:'
            echo '  sudo reboot'
            echo '  или'
            echo '  docker service update --force antizapret_wireguard-amnezia'
        fi
    "
}

# Проверка аргументов
check_arguments() {
    if [ $# -lt 1 ]; then
        echo -e "${RED}Использование: $0 <backup_path>${NC}"
        echo ""
        echo "Аргументы:"
        echo "  backup_path  - Путь к директории бэкапа (обязательно)"
        echo ""
        echo "Примеры:"
        echo "  $0 ./backups/backup_20250629_174231"
        exit 1
    fi
    
    BACKUP_PATH="$1"
    
    if [ ! -d "$BACKUP_PATH" ]; then
        echo -e "${RED}Бэкап не найден: $BACKUP_PATH${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}Используем параметры:${NC}"
    echo "  Бэкап: $BACKUP_PATH"
    echo "  Сервер: $DEST_HOST"
    echo "  Пользователь: $NEW_USER"
    echo "  SSH ключ: $SSH_KEY"
}

fix_system_locale() {
    local host="${1:-$DEST_HOST}"
    echo "Исправляем настройки локалей на целевом сервере ($host)..."
    
    # Выполняем команды через SSH на целевом сервере
    ssh -i "$SSH_KEY" root@"$host" "
        # Проверяем, установлен ли пакет locales
        if ! dpkg -l | grep -q \"locales\"; then
            echo \"Устанавливаем пакет locales...\"
            apt-get install -y locales
        fi
        
        # Проверяем наличие нужных локалей
        if ! locale -a | grep -q \"ru_RU.utf8\"; then
            echo \"Генерируем локаль ru_RU.UTF-8...\"
            locale-gen ru_RU.UTF-8
        fi
        
        if ! locale -a | grep -q \"en_US.utf8\"; then
            echo \"Генерируем локаль en_US.UTF-8...\"
            locale-gen en_US.UTF-8
        fi
        
        # Проверяем текущие глобальные настройки
        if ! grep -q \"LANG=en_US.UTF-8\" /etc/default/locale 2>/dev/null || \
           ! grep -q \"LC_ALL=en_US.UTF-8\" /etc/default/locale 2>/dev/null; then
            echo \"Обновляем глобальные настройки локалей...\"
            cat > /etc/default/locale <<EOF
LANG=en_US.UTF-8
LANGUAGE=en_US:en
LC_CTYPE=en_US.UTF-8
LC_ALL=en_US.UTF-8
EOF
            dpkg-reconfigure -f noninteractive locales
            update-locale
        fi
        
        echo \"Текущие настройки локалей:\"
        locale
    "
}

setup_ssh_keys() {
    echo "Настраиваем SSH доступ на целевом сервере ($DEST_HOST)"

    check_sshpass

    # Очищаем known_hosts перед подключением
    echo "Очищаем known_hosts"
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$DEST_HOST" >/dev/null 2>&1
    
    # if ! safe_ssh "root@$DEST_HOST" "echo 'Тестовое подключение'"; then
    if ! safe_sshpass "root@$DEST_HOST" "echo 'Тестовое подключение'" "$DEST_ROOT_PASSWORD"; then
        echo -e "${RED}Не удалось установить SSH-соединение с $DEST_HOST${NC}" >&2
        exit 1
    fi
       
    if ! ping -c 1 "$DEST_HOST" &> /dev/null; then
        echo -e "${RED}Ошибка: сервер $DEST_HOST недоступен${NC}"
        exit 1
    fi
    
    if ! sshpass -p "$DEST_ROOT_PASSWORD" ssh-copy-id -i "$SSH_PUB_KEY" -o StrictHostKeyChecking=no root@"$DEST_HOST"; then
        echo "Пробуем альтернативный метод копирования ключа..."
        if ! ssh -o PasswordAuthentication=yes -o PubkeyAuthentication=no root@"$DEST_HOST" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo $(cat $SSH_PUB_KEY) >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"; then
            echo -e "${RED}Ошибка при копировании SSH ключа${NC}"
            exit 1
        fi
    fi
    
    # Отключаем парольную аутентификацию и настраиваем root-доступ только по ключу
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config"
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config"
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config"
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "sed -i 's/^#*UsePAM.*/UsePAM no/' /etc/ssh/sshd_config"

    ssh -i "$SSH_KEY" root@"$DEST_HOST" "
    sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/50-cloud-init.conf || \
    rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf
    "
    
    if ssh -i "$SSH_KEY" root@"$DEST_HOST" "systemctl restart sshd.service 2>/dev/null || systemctl restart ssh.service"; then
        echo "SSH служба перезапущена"
    else
        echo -e "${YELLOW}Предупреждение: не удалось перезапустить SSH службу${NC}"
    fi
}

create_user() {
    echo "Создаем пользователя $NEW_USER и настраиваем sudo"
    
    if ssh -i "$SSH_KEY" root@"$DEST_HOST" "id -u $NEW_USER" &>/dev/null; then
        echo "Пользователь $NEW_USER уже существует"
    else
        ssh -i "$SSH_KEY" root@"$DEST_HOST" "adduser --disabled-password --gecos '' $NEW_USER"
        ssh -i "$SSH_KEY" root@"$DEST_HOST" "echo '$NEW_USER:$NEW_USER_PASSWORD' | chpasswd"
    fi
    
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "usermod -aG sudo $NEW_USER"
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "echo '$NEW_USER ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/$NEW_USER"
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "chmod 440 /etc/sudoers.d/$NEW_USER"
    
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "mkdir -p /home/$NEW_USER/.ssh && chown $NEW_USER:$NEW_USER /home/$NEW_USER/.ssh && chmod 700 /home/$NEW_USER/.ssh"
    scp -i "$SSH_KEY" "$SSH_PUB_KEY" root@"$DEST_HOST":/home/$NEW_USER/.ssh/authorized_keys
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "chown $NEW_USER:$NEW_USER /home/$NEW_USER/.ssh/authorized_keys && chmod 600 /home/$NEW_USER/.ssh/authorized_keys"
}

install_base_packages() {
    echo "Устанавливаем базовые пакеты"
    
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "sudo apt update && sudo apt upgrade -y"
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "sudo apt-get install -y zsh tree redis-server nginx zlib1g-dev libbz2-dev libreadline-dev llvm libncurses5-dev libncursesw5-dev xz-utils tk-dev liblzma-dev python3-dev python3-lxml libxslt-dev libffi-dev libssl-dev gnumeric libsqlite3-dev libpq-dev libxml2-dev libxslt1-dev libjpeg-dev libfreetype6-dev libcurl4-openssl-dev supervisor libevent-dev yacc unzip net-tools pipx jq snapd"
    
    # Установка Docker
    # ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh && rm get-docker.sh"
    # ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "sudo usermod -aG docker $NEW_USER"
    install_docker_if_needed "$DEST_HOST" "$NEW_USER"

    # Установка certbot
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "sudo snap install --classic certbot"
}

install_docker_if_needed() {
    local host="$1"
    local user="$2"

    # Устанавливаем с автоматическим определением необходимости sudo
    local sudo_cmd=""
    [ "$user" != "root" ] && sudo_cmd="sudo"

    safe_ssh "$user@$host" "
        if ! command -v docker &>/dev/null; then
            curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && \
            $sudo_cmd sh /tmp/get-docker.sh && \
            rm -f /tmp/get-docker.sh
        fi
        docker --version 
    "

    # Добавляем в группу docker только для не-root пользователя
    if [ "$user" != "root" ]; then
        safe_ssh "$user"@"$host" "sudo usermod -aG docker '$user'"
    fi
}

setup_oh_my_zsh() {
    echo "=== Настройка oh-my-zsh ==="
    
    # 1. Установка oh-my-zsh
    echo "Устанавливаем oh-my-zsh..."
    ssh -i "$SSH_KEY" "$NEW_USER@$DEST_HOST" << 'EOF'
# Установка без автоматического изменения .zshrc
RUNZSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)" || {
    echo "Ошибка установки oh-my-zsh!" >&2
    exit 1
}

# Создаем структуру кастомных директорий
mkdir -p ~/.oh-my-zsh/custom/{plugins,themes}

# Установка плагинов
echo "Устанавливаем плагины..."
git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions || {
    echo "Не удалось установить zsh-autosuggestions" >&2
}
git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting || {
    echo "Не удалось установить zsh-syntax-highlighting" >&2
}
EOF

    # 2. Копирование конфигурационных файлов
    echo "Копируем zsh конфигурации..."
    
    # Создаем временную папку
    local temp_dir=$(mktemp -d)
    
    # Копируем .zshrc из бэкапа
    echo "Копируем .zshrc..."
    if [ -f "$BACKUP_PATH/main/home/$NEW_USER/.zshrc" ]; then
        cp "$BACKUP_PATH/main/home/$NEW_USER/.zshrc" "$temp_dir/.zshrc"
        scp -i "$SSH_KEY" "$temp_dir/.zshrc" "$NEW_USER@$DEST_HOST:/home/$NEW_USER/.zshrc"
    else
        echo -e "${YELLOW}Файл .zshrc не найден в бэкапе${NC}"
    fi
    
    # Копируем .zprofile из бэкапа (если существует)
    echo "Копируем .zprofile..."
    if [ -f "$BACKUP_PATH/main/home/$NEW_USER/.zprofile" ]; then
        cp "$BACKUP_PATH/main/home/$NEW_USER/.zprofile" "$temp_dir/.zprofile"
        scp -i "$SSH_KEY" "$temp_dir/.zprofile" "$NEW_USER@$DEST_HOST:/home/$NEW_USER/.zprofile"
    else
        echo "Файл .zprofile не найден в бэкапе, пропускаем"
    fi
    
    # Устанавливаем правильные права
    ssh -i "$SSH_KEY" "$NEW_USER@$DEST_HOST" "
        chmod 644 ~/.zshrc ~/.zprofile 2>/dev/null
        chown $NEW_USER:$NEW_USER ~/.zshrc ~/.zprofile 2>/dev/null
    "
    
    # Очищаем временные файлы
    rm -rf "$temp_dir"

    # 3. Установка Zsh как оболочки по умолчанию
    echo "Устанавливаем Zsh как оболочку по умолчанию..."
    ssh -i "$SSH_KEY" "$NEW_USER@$DEST_HOST" "
        sudo chsh -s $(which zsh) $NEW_USER || {
            echo 'Не удалось изменить оболочку по умолчанию' >&2
            exit 1
        }
    "

    # 4. Проверка установки
    echo "Проверяем установку..."
    ssh -i "$SSH_KEY" "$NEW_USER@$DEST_HOST" "
        echo 'Текущая оболочка:'
        grep $NEW_USER /etc/passwd | cut -d: -f7
        echo 'Версия Zsh:'
        zsh --version
    "

    echo "=== oh-my-zsh успешно настроен ==="
}

install_pyenv() {
    echo "Устанавливаем pyenv и Python 3.13.5..."
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" << 'EOF'
# Установка зависимостей
sudo apt-get install -y make build-essential libssl-dev zlib1g-dev \
libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm \
libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev

# Установка pyenv
curl -s https://pyenv.run | bash

# Установка Python
source ~/.zshrc
pyenv install 3.13.5 --skip-existing
pyenv global 3.13.5
EOF
    echo "Pyenv и Python 3.13.5 успешно установлены"
}

install_poetry() {
    echo "Устанавливаем Poetry..."
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" << 'EOF'
# Установка Poetry
curl -sSL https://install.python-poetry.org | python3 -

# Создаем директорию для автодополнений
mkdir -p ~/.oh-my-zsh/custom/plugins/poetry

# Настраиваем автодополнения
source ~/.zshrc
poetry completions zsh > ~/.oh-my-zsh/custom/plugins/poetry/_poetry 2>/dev/null || true
EOF
    echo "Poetry успешно установлен и настроен"
}

install_lampac() {
    echo "Устанавливаем Lampac из-под root"
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "curl -L -k -s https://lampac.sh | bash"

    # Копируем файлы из бэкапа
    if [ -d "$BACKUP_PATH/main/home/lampac" ]; then
        rsync -avz -e "ssh -i $SSH_KEY" "$BACKUP_PATH/main/home/lampac/" root@"$DEST_HOST":/home/lampac/
    else
        echo -e "${YELLOW}Директория lampac не найдена в бэкапе${NC}"
    fi

    # Перезагружаем сервисы
    safe_ssh root@"$DEST_HOST" "systemctl restart lampac"
}

setup_antizapret() {
    echo "Настраиваем Антизапрет из бэкапа..."
    
    # Копируем данные
    safe_ssh root@"$DEST_HOST" "mkdir -p /home/$NEW_USER/antizapret"
    if [ -d "$BACKUP_PATH/main/home/$NEW_USER/antizapret" ]; then
        rsync -aq -e "ssh -i $SSH_KEY" "$BACKUP_PATH/main/home/$NEW_USER/antizapret/" root@"$DEST_HOST":/home/$NEW_USER/antizapret/
        safe_ssh root@"$DEST_HOST" "chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/antizapret"
    else
        echo -e "${YELLOW}Директория antizapret не найдена в бэкапе${NC}"
        return 0
    fi
    
    # Проверяем: есть ли активный сварм на существующем RU-сервере?
    local ru_host="${SOURCE_HOST_RU:-$DEST_HOST_RU}"
    local swarm_active=false
    
    if [ -n "$ru_host" ] && safe_ssh root@"$ru_host" "
        export LC_ALL=C LANG=C
        docker info 2>/dev/null | grep -q 'Swarm: active' && \
        docker node ls 2>/dev/null | grep -q 'az-local'
    " 2>/dev/null; then
        swarm_active=true
    fi
    
    if [ "$swarm_active" = true ]; then
        echo "✓ Обнаружен активный Swarm на $ru_host (менеджер: az-local)"
        
        # Получаем токен
        local swarm_token
        swarm_token=$(safe_ssh root@"$ru_host" "
            export LC_ALL=C LANG=C
            docker swarm join-token worker -q
        ")
        
        if [ -n "$swarm_token" ]; then
            echo "  → Присоединяемся к сварму как воркер..."
            safe_ssh root@"$DEST_HOST" "
                export LC_ALL=C LANG=C
                docker swarm leave --force 2>/dev/null || true
                docker swarm join --token $swarm_token $ru_host:2377
                hostnamectl set-hostname az-world
                echo '✓ Присоединён к сварму, hostname: az-world'
            "
            echo -e "${GREEN}✓ Антизапрет готов как воркер Swarm${NC}"
            echo -e "${YELLOW}💡 Стек деплоится на менеджере (az-local)${NC}"
        else
            echo -e "${RED}✗ Не удалось получить токен присоединения${NC}"
            swarm_active=false
        fi
    fi
    
    # Локальный режим (если нет сварма или ошибка получения токена)
    if [ "$swarm_active" = false ]; then
        echo "⚠ Swarm недоступен — запускаем в локальном режиме"
        
        # Устанавливаем ядерные модули
        install_openvpn_dco "$DEST_HOST"
        install_amneziawg "$DEST_HOST"
        
        # Запускаем локально
        safe_ssh $NEW_USER@"$DEST_HOST" "
            export LC_ALL=C LANG=C
            cd ~/antizapret
            docker compose pull 2>/dev/null || true
            docker compose up -d
            sleep 15
            docker compose ps
        "
        
        echo -e "${GREEN}✓ Антизапрет запущен локально с ядерными модулями${NC}"
    fi
}

transfer_nginx_certs() {
    echo "Переносим конфиги Nginx и сертификаты из бэкапа"
    
    # Копируем конфиги Nginx
    echo "Копируем конфиги Nginx..."
    safe_ssh root@"$DEST_HOST" "mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled"

    # nginx.conf
    if [ -f "$BACKUP_PATH/main/etc/nginx/nginx.conf" ]; then
        rsync -avz -e "ssh -i $SSH_KEY" "$BACKUP_PATH/main/etc/nginx/nginx.conf" root@"$DEST_HOST":/etc/nginx/
    else
        echo -e "${YELLOW}Файл nginx.conf не найден в бэкапе${NC}"
    fi
    
    # sites-available
    if [ -d "$BACKUP_PATH/main/etc/nginx/sites-available" ]; then
        rsync -avz -e "ssh -i $SSH_KEY" "$BACKUP_PATH/main/etc/nginx/sites-available/" root@"$DEST_HOST":/etc/nginx/sites-available/
    else
        echo -e "${YELLOW}Директория sites-available не найдена в бэкапе${NC}"
    fi
    
    # sites-enabled
    if [ -d "$BACKUP_PATH/main/etc/nginx/sites-enabled" ]; then
        rsync -avz -e "ssh -i $SSH_KEY" "$BACKUP_PATH/main/etc/nginx/sites-enabled/" root@"$DEST_HOST":/etc/nginx/sites-enabled/
    else
        echo -e "${YELLOW}Директория sites-enabled не найдена в бэкапе${NC}"
    fi
    
    # Сертификаты Let's Encrypt
    echo "Копируем сертификаты Let's Encrypt..."
    if [ -d "$BACKUP_PATH/main/etc/letsencrypt" ]; then
        safe_ssh root@"$DEST_HOST" "mkdir -p /etc/letsencrypt"
        rsync -avz -e "ssh -i $SSH_KEY" "$BACKUP_PATH/main/etc/letsencrypt/" root@"$DEST_HOST":/etc/letsencrypt/
    else
        echo -e "${YELLOW}Директория letsencrypt не найдена в бэкапе${NC}"
    fi
    
    # Перезагружаем Nginx
    echo "Перезагружаем Nginx..."
    safe_ssh root@"$DEST_HOST" "systemctl restart nginx"
}

install_go() {
    echo "Устанавливаем Go и настраиваем окружение"
    
    ssh -i "$SSH_KEY" "$NEW_USER@$DEST_HOST" << 'EOF'
# Устанавливаем Go (если ещё не установлен)
if ! command -v go &>/dev/null; then
    wget -q https://go.dev/dl/go1.22.4.linux-amd64.tar.gz
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf go1.22.4.linux-amd64.tar.gz
    rm go1.22.4.linux-amd64.tar.gz
fi

# Явно добавляем PATH для текущей сессии
export PATH="$PATH:/usr/local/go/bin"

# Проверяем установку
go version || { echo "ОШИБКА: Go не работает!"; exit 1; }
EOF
}

setup_numparser() {
    echo "Настраиваем NUMParser из бэкапа"
    
    # Клонируем репозиторий (если еще не существует)
    safe_ssh $NEW_USER@"$DEST_HOST" "git clone https://github.com/Igorek1986/NUMParser.git || true"
    
    # Копируем конфиг
    scp -i "$SSH_KEY" numparser_config.yml $NEW_USER@"$DEST_HOST":/home/$NEW_USER/NUMParser/config.yml
    
    # Копируем базу данных из бэкапа
    if [ -f "$BACKUP_PATH/main/home/$NEW_USER/NUMParser/db/numparser.db" ]; then
        echo "Копируем базу данных numparser.db..."
        safe_ssh $NEW_USER@"$DEST_HOST" "mkdir -p /home/$NEW_USER/NUMParser/db"
        rsync -avz -e "ssh -i $SSH_KEY" \
            "$BACKUP_PATH/main/home/$NEW_USER/NUMParser/db/numparser.db" \
            $NEW_USER@"$DEST_HOST":/home/$NEW_USER/NUMParser/db/
    else
        echo -e "${YELLOW}Файл базы данных numparser.db не найден в бэкапе${NC}"
    fi
    
    # Пересобираем и настраиваем службу
    safe_ssh $NEW_USER@"$DEST_HOST" "
        cd NUMParser
        export PATH=\"\$PATH:/usr/local/go/bin\"
        go build -o NUMParser_deb ./cmd || {
            echo 'ОШИБКА: Не удалось собрать NUMParser'
            exit 1
        }
    "


    if [ -f "$BACKUP_PATH/main/etc/systemd/system/numparser.service" ]; then
        echo "Копируем numparser.service..."
        rsync -avz -e "ssh -i $SSH_KEY" \
            "$BACKUP_PATH/main/etc/systemd/system/numparser.service" \
            root@"$DEST_HOST":/etc/systemd/system/
        safe_ssh $NEW_USER@"$DEST_HOST" "sudo systemctl daemon-reload && sudo systemctl start numparser && sudo systemctl enable numparser"
    else
        echo -e "${YELLOW}Файл numparser.service не найден в бэкапе${NC}"
    fi
     
}

setup_movies_api() {
    echo "Настраиваем Movies-api из бэкапа"
    
    safe_ssh $NEW_USER@"$DEST_HOST" "git clone https://github.com/Igorek1986/movies-api.git || true"
    
    # Копируем .env файл
    scp -i "$SSH_KEY" movies-api.env $NEW_USER@"$DEST_HOST":/home/$NEW_USER/movies-api/.env
    
    # Копируем базу данных из бэкапа (если есть)
    if [ -f "$BACKUP_PATH/main/home/$NEW_USER/movies-api/db.sqlite3" ]; then
        echo "Копируем базу данных movies-api..."
        rsync -avz -e "ssh -i $SSH_KEY" \
            "$BACKUP_PATH/main/home/$NEW_USER/movies-api/db.sqlite3" \
            $NEW_USER@"$DEST_HOST":/home/$NEW_USER/movies-api/
    fi
    
    echo "Устанавливаем зависимости..."
    safe_ssh "$NEW_USER@$DEST_HOST" "
        cd movies-api
        export PATH=\"/home/$NEW_USER/.local/bin:\$PATH\"
        /home/$NEW_USER/.local/bin/poetry install --no-root || {
            echo -e '${RED}Ошибка установки зависимостей!${NC}'
            exit 1
        }
    "

    if [ -f "$BACKUP_PATH/main/etc/systemd/system/movies-api.service" ]; then
        echo "Копируем movies-api.service..."
        rsync -avz -e "ssh -i $SSH_KEY" \
            "$BACKUP_PATH/main/etc/systemd/system/movies-api.service" \
            root@"$DEST_HOST":/etc/systemd/system/
        safe_ssh $NEW_USER@"$DEST_HOST" "sudo systemctl daemon-reload && sudo systemctl start movies-api && sudo systemctl enable movies-api"
    else
        echo -e "${YELLOW}Файл movies-api.service не найден в бэкапе${NC}"
    fi
        
}

setup_3proxy() {
    echo "Устанавливаем 3proxy из бэкапа"
    
    # Установка 3proxy
    safe_ssh $NEW_USER@"$DEST_HOST" "git clone https://github.com/z3apa3a/3proxy || true"
    safe_ssh $NEW_USER@"$DEST_HOST" "cd 3proxy && ln -s Makefile.Linux Makefile && make && sudo make install"
    
    # Копируем конфиг из бэкапа
    if [ -f "$BACKUP_PATH/main/etc/3proxy/3proxy.cfg" ]; then
        echo "Копируем конфигурацию 3proxy..."
        safe_ssh $NEW_USER@"$DEST_HOST" "sudo mkdir -p /etc/3proxy/"
        rsync -avz -e "ssh -i $SSH_KEY" \
            "$BACKUP_PATH/main/etc/3proxy/3proxy.cfg" \
            root@"$DEST_HOST":/etc/3proxy/3proxy.cfg
    else
        echo -e "${YELLOW}Файл конфигурации 3proxy не найден в бэкапе${NC}"
    fi
    
    # Запускаем службу
    safe_ssh $NEW_USER@"$DEST_HOST" "sudo systemctl start 3proxy.service && sudo systemctl enable 3proxy.service"
}

setup_glances() {
    echo "Устанавливаем Glances"
    
    safe_ssh $NEW_USER@"$DEST_HOST" "pipx install glances && pipx inject glances fastapi uvicorn jinja2 || true"

    if [ -f "$BACKUP_PATH/main/etc/systemd/system/glances.service" ]; then
        echo "Копируем glances.service..."
        rsync -avz -e "ssh -i $SSH_KEY" \
            "$BACKUP_PATH/main/etc/systemd/system/glances.service" \
            root@"$DEST_HOST":/etc/systemd/system/
        safe_ssh $NEW_USER@"$DEST_HOST" "sudo systemctl daemon-reload && sudo systemctl start glances && sudo systemctl enable glances"
    else
        echo -e "${YELLOW}Файл glances.service не найден в бэкапе${NC}"
    fi
}

setup_marzban() {
    echo "=== Процесс восстановления Marzban из бэкапа ==="

    safe_ssh root@"$DEST_HOST" '
        echo "▶️ Начинаем установку Marzban..."

        # Запускаем установку в фоне
        echo "Запускаем установку в фоне"
        bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install &
        INSTALL_PID=$!
        echo "install complete"

        # Проверяем статус Marzban каждые 5 секунд без ограничения времени
        while true; do
            STATUS=$(marzban status | sed "s/\x1b\[[0-9;]*m//g" | grep "^Status:" | awk "{print \$2}")
            echo "⏳ Проверяем статус Marzban: $STATUS"

            if [ "$STATUS" = "Up" ]; then
                echo "✅ Marzban запущен, выполняем остановку..."
                marzban down || echo "⚠️ Не удалось остановить Marzban"
                break
            fi

            sleep 5
        done

        # Ждём завершения установки
        wait $INSTALL_PID
        INSTALL_EXIT=$?

        if [ $INSTALL_EXIT -eq 0 ]; then
            echo "✅ Установка Marzban завершена успешно."
        else
            echo "❌ Установка завершилась с ошибкой (код $INSTALL_EXIT)"
        fi
    '

    # 2. Копирование данных из бэкапа
    echo "Копируем данные Marzban из бэкапа..."
    
    # /var/lib/marzban
    if [ -d "$BACKUP_PATH/main/var/lib/marzban" ]; then
        rsync -avz -e "ssh -i $SSH_KEY" \
            "$BACKUP_PATH/main/var/lib/marzban/" \
            root@"$DEST_HOST":/var/lib/marzban/ || {
                echo -e "${RED}Ошибка копирования данных Marzban${NC}" >&2
                return 1
            }
    else
        echo -e "${YELLOW}Директория /var/lib/marzban не найдена в бэкапе${NC}"
    fi

    # /opt/marzban/.env
    if [ -f "$BACKUP_PATH/main/opt/marzban/.env" ]; then
        rsync -avz -e "ssh -i $SSH_KEY" \
            "$BACKUP_PATH/main/opt/marzban/.env" \
            root@"$DEST_HOST":/opt/marzban/.env || {
                echo -e "${RED}Ошибка копирования .env файла${NC}" >&2
                return 1
            }
    else
        echo -e "${YELLOW}Файл /opt/marzban/.env не найден в бэкапе${NC}"
    fi

    # 3. Запуск Marzban
    safe_ssh root@"$DEST_HOST" '
    set -e

    STATUS=$(marzban status | sed "s/\x1b\[[0-9;]*m//g" | grep "^Status:" | awk "{print \$2}")
    echo "⏳ Текущий статус Marzban: $STATUS"
    
    if [ "$STATUS" = "Down" ]; then
        echo "▶️ Marzban не запущен — запускаем..."
        marzban up > /var/log/marzban.log 2>&1 &
        break
    fi

    echo "▶️ Продолжаем выполнение скрипта после успешного запуска Marzban."
    '

    ## 4. Получаем порт из .env (надежная версия)
    PANEL_PORT=$(safe_ssh root@"$DEST_HOST" \
        "grep '^UVICORN_PORT' /opt/marzban/.env | awk -F'=' '{gsub(/[ \"]/, \"\", \$2); print \$2}'")

    echo "=== Восстановление Marzban успешно завершено ==="
    echo "Панель доступна по адресу: https://$DEST_HOST:${PANEL_PORT:-8000}"
}

# Восстановление конфигурации fail2ban
setup_fail2ban() {
    echo "Восстанавливаем конфигурацию fail2ban из бэкапа"
    
    # Устанавливаем fail2ban если еще не установлен
    safe_ssh root@"$DEST_HOST" "apt-get install -y fail2ban"

    # Копируем /usr/local/bin/ban
    if [ -f "$BACKUP_PATH/main//usr/local/bin/ban" ]; then
        echo "Копируем ban..."
        rsync -avz -e "ssh -i $SSH_KEY" \
            "$BACKUP_PATH/main/usr/local/bin/ban" \
            root@"$DEST_HOST":/usr/local/bin/ban
    else
        echo -e "${YELLOW}Файл ban не найден в бэкапе${NC}"
    fi
    
    # Копируем jail.local
    if [ -f "$BACKUP_PATH/main/etc/fail2ban/jail.local" ]; then
        echo "Копируем jail.local..."
        rsync -avz -e "ssh -i $SSH_KEY" \
            "$BACKUP_PATH/main/etc/fail2ban/jail.local" \
            root@"$DEST_HOST":/etc/fail2ban/
    else
        echo -e "${YELLOW}Файл jail.local не найден в бэкапе${NC}"
    fi
    
    # Копируем фильтры
    if [ -d "$BACKUP_PATH/main/etc/fail2ban/filter.d" ]; then
        echo "Копируем фильтры..."
        safe_ssh root@"$DEST_HOST" "mkdir -p /etc/fail2ban/filter.d"
        rsync -avz -e "ssh -i $SSH_KEY" \
            "$BACKUP_PATH/main/etc/fail2ban/filter.d/" \
            root@"$DEST_HOST":/etc/fail2ban/filter.d/
    else
        echo -e "${YELLOW}Директория filter.d не найдена в бэкапе${NC}"
    fi
    
    # Устанавливаем правильные права
    safe_ssh root@"$DEST_HOST" "
        chmod 644 /etc/fail2ban/jail.local
        chmod 644 /etc/fail2ban/filter.d/*
    "
    
    # Перезапускаем fail2ban
    echo "Перезапускаем fail2ban..."
    safe_ssh root@"$DEST_HOST" "systemctl restart fail2ban"
    
    # Проверяем статус
    echo "Проверяем статус fail2ban..."
    safe_ssh root@"$DEST_HOST" "fail2ban-client status"
}

cleanup() {
    echo "Выполняем очистку"
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "sudo apt autoremove -y"
}

update_dns_records() {
    local target_host="${1:-$DEST_HOST}"
    local domains="${2:-$DOMAINS_TO_UPDATE_MAIN}"

    if [ "$DEBUG" = "True" ]; then
        echo -e "\n${YELLOW}=== ПРОПУСК: Обновление DNS (режим отладки) ===${NC}"
        return 0
    fi

    echo -e "\n${BLUE}=== ОБНОВЛЕНИЕ DNS: $target_host ===${NC}"

    # Кодируем логин и пароль для URL
    local encoded_login
    encoded_login=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$BEGET_LOGIN'))")
    local encoded_password
    encoded_password=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$BEGET_PASSWORD'))")

    local all_success=true

    for domain in $domains; do
        echo "Обновляем A-запись для $domain..."

        # Формируем JSON и кодируем его
        local json_data="{\"fqdn\":\"$domain\",\"records\":{\"A\":[{\"priority\":10,\"value\":\"$target_host\"}]}}"
        local encoded_data
        encoded_data=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$json_data")

        # Выполняем запрос к API Beget
        local response
        response=$(curl -s "https://api.beget.com/api/dns/changeRecords?login=$encoded_login&passwd=$encoded_password&input_format=json&output_format=json&input_data=$encoded_data")

        echo "Ответ API: $response"

        # Проверяем успешность
        if ! echo "$response" | jq -e '.status == "success" and .answer.status == "success"' >/dev/null; then
            all_success=false
            echo -e "${RED}Ошибка при обновлении DNS для $domain${NC}" >&2
        fi

        # Обновляем www-поддомен
        local www_domain="www.$domain"
        echo "Обновляем A-запись для $www_domain..."
        local www_json_data="{\"fqdn\":\"$www_domain\",\"records\":{\"A\":[{\"priority\":10,\"value\":\"$target_host\"}]}}"
        local www_encoded_data
        www_encoded_data=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$www_json_data")

        local www_response
        www_response=$(curl -s "https://api.beget.com/api/dns/changeRecords?login=$encoded_login&passwd=$encoded_password&input_format=json&output_format=json&input_data=$www_encoded_data")

        echo "Ответ API для www: $www_response"

        if ! echo "$www_response" | jq -e '.status == "success" and .answer.status == "success"' >/dev/null; then
            all_success=false
            echo -e "${RED}Ошибка при обновлении DNS для $www_domain${NC}" >&2
        fi
    done

    # Возвращаем статус через глобальную переменную
    DNS_UPDATED=$all_success
}

setup_swap() {
    if [ "$SWAP_SIZE" = "0" ]; then
        echo -e "${YELLOW}SWAP_SIZE=0 — swap не создаётся.${NC}"
        return 0
    fi

    echo "Создаём swap размером $SWAP_SIZE..."

    # Проверяем, не создан ли уже swap
    if ssh -i "$SSH_KEY" root@"$DEST_HOST" "swapon --show | grep -q '/swapfile'"; then
        echo -e "${YELLOW}Swap уже существует, пропускаем.${NC}"
        return 0
    fi

    # Создаём и настраиваем swap напрямую
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "
        fallocate -l $SWAP_SIZE /swapfile &&
        chmod 600 /swapfile &&
        mkswap /swapfile &&
        swapon /swapfile &&
        echo '/swapfile none swap sw 0 0' >> /etc/fstab &&
        echo 'vm.swappiness=10' >> /etc/sysctl.conf &&
        sysctl -p
    "

    echo -e "${GREEN}Swap ($SWAP_SIZE) успешно настроен.${NC}"
}

# Автоматическое обновление migrate.env после успешного восстановления
update_migrate_env_after_restore() {
    local migrate_file="$SCRIPT_DIR/migrate.env"
    
    [ ! -f "$migrate_file" ] && { echo -e "${RED}migrate.env не найден${NC}"; return 1; }
    
    # Бэкап конфигурации
    cp "$migrate_file" "$migrate_file.pre-restore-$(date +%Y%m%d_%H%M%S)"
    
    echo -e "${BLUE}=== ОБНОВЛЕНИЕ migrate.env ===${NC}"
    
    # Обновляем основной сервер если восстанавливался
    if [[ "$RESTORE_TARGET" == "main" || "$RESTORE_TARGET" == "both" ]]; then
        if [[ "$OLD_DEST_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            sed -i "s|^SOURCE_HOST=.*|SOURCE_HOST=$OLD_DEST_HOST|" "$migrate_file"
            sed -i "s|^DEST_HOST=.*|DEST_HOST=|" "$migrate_file"
            echo -e "${GREEN}✓ Основной сервер: SOURCE_HOST ← $OLD_DEST_HOST, DEST_HOST очищен${NC}"
        fi
    fi
    
    # Обновляем RU-сервер если восстанавливался
    if [[ "$RESTORE_TARGET" == "ru" || "$RESTORE_TARGET" == "both" ]]; then
        if [[ "$OLD_DEST_HOST_RU" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            sed -i "s|^SOURCE_HOST_RU=.*|SOURCE_HOST_RU=$OLD_DEST_HOST_RU|" "$migrate_file"
            sed -i "s|^DEST_HOST_RU=.*|DEST_HOST_RU=|" "$migrate_file"
            echo -e "${GREEN}✓ RU-сервер: SOURCE_HOST_RU ← $OLD_DEST_HOST_RU, DEST_HOST_RU очищен${NC}"
        fi
    fi
    
    echo -e "${CYAN}Текущая конфигурация:${NC}"
    grep -E "^(SOURCE_HOST|DEST_HOST|SOURCE_HOST_RU|DEST_HOST_RU)=" "$migrate_file" | sed "s/^/  /"
}

main() {

    [ $# -lt 1 ] && { echo -e "${RED}Использование: $0 <backup_path>${NC}"; exit 1; }
    [ ! -d "$1" ] && { echo -e "${RED}Бэкап не найден: $1${NC}"; exit 1; }
    
    BACKUP_PATH="$1"
    check_required_files
    select_restore_target "$BACKUP_PATH"

    # Сохраняем оригинальные значения ДО восстановления
    OLD_SOURCE_HOST="$SOURCE_HOST"
    OLD_DEST_HOST="$DEST_HOST"
    OLD_SOURCE_HOST_RU="$SOURCE_HOST_RU"
    OLD_DEST_HOST_RU="$DEST_HOST_RU"
    
    # Восстановление ru-сервера (antizapret, myshows_proxy)
    if [[ "$RESTORE_TARGET" == "ru" || "$RESTORE_TARGET" == "both" ]]; then
        [ -z "$DEST_HOST_RU" ] && { echo -e "${RED}Не задан DEST_HOST_RU в migrate.env${NC}"; exit 1; }
        restore_antizapret_ru "$DEST_HOST_RU" "$BACKUP_PATH"
        myshows_proxy_ru "$DEST_HOST_RU" "$BACKUP_PATH"
        [ "$RESTORE_TARGET" == "ru" ] && exit 0  # если только ru — завершаем
    fi

    echo -e "${BLUE}\n=== НАЧАЛО ВОССТАНОВЛЕНИЯ VPS ИЗ БЭКАПА ===${NC}"
    
    check_required_files
    check_arguments "$@"
    
    # Проверка подключения к целевому серверу
    if ! safe_sshpass "root@$DEST_HOST" "echo 'Тестовое подключение'" "$DEST_ROOT_PASSWORD"; then
        echo -e "${RED}Не удалось подключиться к $DEST_HOST${NC}" >&2
        exit 1
    fi

    # Выполнение функций по флагам
    run_if_enabled "setup_ssh_keys"
    run_if_enabled "fix_system_locale"
    run_if_enabled "create_user"

    # Базовые настройки
    run_if_enabled "install_base_packages"
    run_if_enabled "setup_oh_my_zsh"
    run_if_enabled "install_pyenv"
    run_if_enabled "install_poetry"
    run_if_enabled "setup_swap"

    # Восстановление данных из бэкапа
    run_if_enabled "install_lampac"
    run_if_enabled "transfer_nginx_certs"
    run_if_enabled "setup_marzban"
    run_if_enabled "setup_fail2ban"  # Добавлен вызов функции восстановления fail2ban

    # Установка и настройка приложений
    run_if_enabled "install_go"
    run_if_enabled "setup_antizapret"
    run_if_enabled "setup_numparser"
    run_if_enabled "setup_movies_api"
    run_if_enabled "setup_3proxy"
    run_if_enabled "setup_glances"

    # Обновление DNS только в production-режиме
    if [ "$DEBUG" = "False" ]; then
        run_if_enabled "update_dns_records"
        update_migrate_env_after_restore
    fi

    # Очистка
    run_if_enabled "cleanup"

    echo -e "${PURPLE}\n=== ВОССТАНОВЛЕНИЕ ЗАВЕРШЕНО ===${NC}"
    echo "Доступ к серверу:"
    echo "SSH: ssh -i $SSH_KEY $NEW_USER@$DEST_HOST"
    echo "Пароль пользователя: $NEW_USER_PASSWORD"

    if [ "$DEBUG" = "True" ] || [ "$RUN_UPDATE_DNS_RECORDS" = "False" ] || [ "$DNS_UPDATED" = "false" ]; then
        echo -e "\n${CYAN}=== НЕ ЗАБУДЬТЕ ОБНОВИТЬ DNS ЗАПИСИ ===${NC}"
        echo -e "${YELLOW}Следующие домены нужно перенаправить на новый IP ($DEST_HOST):${NC}"

        for domain in $DOMAINS_TO_UPDATE_MAIN; do
            echo -e "  • ${GREEN}$domain${NC}"
            echo -e "  • ${GREEN}www.$domain${NC}"
        done

        echo -e "\n${RED}❗ Это важно сделать сразу после восстановления!${NC}\n"
    fi
}

main "$@"
