#!/bin/bash

# Скрипт для переноса данных между VPS
# Использование: ./vps_migrate.sh
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

# Проверка наличия необходимых файлов
check_required_files() {
    local missing_files=()
    
    [ ! -f "migrate.env" ] && missing_files+=("migrate.env")
    [ ! -f "id_rsa" ] && missing_files+=("id_rsa")
    [ ! -f "id_rsa.pub" ] && missing_files+=("id_rsa.pub")
    [ ! -f "movies-api.env" ] && missing_files+=("movies-api.env")
    [ ! -f "numparser_config.yml" ] && missing_files+=("numparser_config.yml")
    
    if [ ${#missing_files[@]} -ne 0 ]; then
        echo -e "${ERROR_COLOR}Отсутствуют необходимые файлы: ${missing_files[*]}${NC}"
        exit 1
    fi
    
    source migrate.env
    
    # Обязательные переменные
    required_vars=(
        "SOURCE_HOST" "DEST_HOST" "DEST_ROOT_PASSWORD" 
        "NEW_USER" "NEW_USER_PASSWORD" "DOMAINS_TO_UPDATE" 
        "BEGET_LOGIN" "BEGET_PASSWORD"
        "DEBUG"
        # Флаги выполнения функций
        "RUN_SETUP_SSH_KEYS" "RUN_CREATE_USER" "RUN_INSTALL_BASE_PACKAGES"
        "RUN_SETUP_OH_MY_ZSH" "RUN_INSTALL_PYENV" "RUN_INSTALL_POETRY"
        "RUN_INSTALL_LAMPAC" "RUN_TRANSFER_NGINX_CERTS" "RUN_SETUP_MARZBAN"
        "RUN_INSTALL_GO" "RUN_SETUP_ANTIZAPRET" "RUN_SETUP_NUMPARSER"
        "RUN_SETUP_MOVIES_API" "RUN_SETUP_3PROXY" "RUN_SETUP_GLANCES"
        "RUN_UPDATE_DNS_RECORDS"
        "RUN_CLEANUP"
    )
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            echo -e "${ERROR_COLOR}Не задана переменная $var в migrate.env${NC}"
            exit 1
        fi
    done
    
    SSH_KEY="$SCRIPT_DIR/id_rsa"
    SSH_PUB_KEY="$SCRIPT_DIR/id_rsa.pub"
    chmod 600 "$SSH_KEY"
}

# =============================================
# Функция-обертка для выполнения команд
# =============================================
run_if_enabled() {
    local func_name=$1
    local flag_name="RUN_$(echo $func_name | tr '[:lower:]' '[:upper:]')"
    
    if [ "${!flag_name}" = "True" ]; then
        echo -e "\n${INFO_COLOR}=== ВЫПОЛНЕНИЕ: ${func_name} ===${NC}"
        $func_name
    else
        echo -e "\n${WARNING_COLOR}=== ПРОПУСК: ${func_name} (отключено в конфиге) ===${NC}"
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
        echo -e "${ERROR_COLOR}Ошибка выполнения команды на $host: $command${NC}" >&2
        return 1
    fi
}

safe_sshpass() {
    local host="$1"
    local command="$2"
    local password="$3"

    sshpass -p "$password" ssh -o StrictHostKeyChecking=no "$host" "$command"
    if [ $? -ne 0 ]; then
        echo -e "${ERROR_COLOR}Ошибка выполнения команды на $host: $command${NC}" >&2
        return 1
    fi
}

fix_system_locale() {
    echo "Исправляем настройки локалей на целевом сервере ($DEST_HOST)..."
    
    # Выполняем команды через SSH на целевом сервере
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "
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
        echo -e "${ERROR_COLOR}Не удалось установить SSH-соединение с $DEST_HOST${NC}" >&2
        exit 1
    fi
       
    if ! ping -c 1 "$DEST_HOST" &> /dev/null; then
        echo -e "${ERROR_COLOR}Ошибка: сервер $DEST_HOST недоступен${NC}"
        exit 1
    fi
    
    if ! sshpass -p "$DEST_ROOT_PASSWORD" ssh-copy-id -i "$SSH_PUB_KEY" -o StrictHostKeyChecking=no root@"$DEST_HOST"; then
        echo "Пробуем альтернативный метод копирования ключа..."
        if ! ssh -o PasswordAuthentication=yes -o PubkeyAuthentication=no root@"$DEST_HOST" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo $(cat $SSH_PUB_KEY) >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"; then
            echo -e "${ERROR_COLOR}Ошибка при копировании SSH ключа${NC}"
            exit 1
        fi
    fi
    
    # # Пробуем оба варианта имени службы SSH
    # ssh -i "$SSH_KEY" root@"$DEST_HOST" "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config"
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
        echo -e "${WARNING_COLOR}Предупреждение: не удалось перезапустить SSH службу${NC}"
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
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "sudo apt-get install -y zsh tree redis-server nginx zlib1g-dev libbz2-dev libreadline-dev llvm libncurses5-dev libncursesw5-dev xz-utils tk-dev liblzma-dev python3-dev python3-lxml libxslt-dev libffi-dev libssl-dev gnumeric libsqlite3-dev libpq-dev libxml2-dev libxslt1-dev libjpeg-dev libfreetype6-dev libcurl4-openssl-dev supervisor libevent-dev yacc unzip net-tools pipx jq fail2ban"
    
    # Установка Docker
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh && rm get-docker.sh"
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "sudo usermod -aG docker $NEW_USER"

    # Установка certbot
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "sudo snap install --classic certbot"
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
    
    # Копируем .zshrc
    echo "Копируем .zshrc..."
    ssh -i "$SSH_KEY" "$NEW_USER@$SOURCE_HOST" "cat /home/$NEW_USER/.zshrc" > "$temp_dir/.zshrc"
    scp -i "$SSH_KEY" "$temp_dir/.zshrc" "$NEW_USER@$DEST_HOST:/home/$NEW_USER/.zshrc"
    
    # Копируем .zprofile (если существует)
    echo "Копируем .zprofile..."
    if ssh -i "$SSH_KEY" "$NEW_USER@$SOURCE_HOST" "[ -f /home/$NEW_USER/.zprofile ]"; then
        ssh -i "$SSH_KEY" "$NEW_USER@$SOURCE_HOST" "cat /home/$NEW_USER/.zprofile" > "$temp_dir/.zprofile"
        scp -i "$SSH_KEY" "$temp_dir/.zprofile" "$NEW_USER@$DEST_HOST:/home/$NEW_USER/.zprofile"
    else
        echo "Файл .zprofile не найден на исходном сервере, пропускаем"
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

    # Создаем временную папку локально
    LOCAL_TEMP_DIR=$(mktemp -d)

    echo "Копируем файлы с исходного сервера..."
    rsync -avz --relative -e "ssh -i $SSH_KEY" \
    root@"$SOURCE_HOST":/./home/lampac/{module/manifest.json,init.conf,users.json,wwwroot/profileIcons,plugins/lampainit.my.js,plugins/privateinit.my.js,cache/storage,wwwroot/my_plugins,passwd} \
    "$LOCAL_TEMP_DIR"


    echo "Копируем файлы на целевой сервер..."
    rsync -avz -e "ssh -i $SSH_KEY" \
        "$LOCAL_TEMP_DIR/home/lampac/" \
        root@"$DEST_HOST":/home/lampac/ || {
        echo "Ошибка при копировании файлов на целевой сервер"
        return 1
    }

    # Очищаем временные файлы
    rm -rf "$LOCAL_TEMP_DIR" || {
        echo "Не удалось удалить временные файлы"
        return 1
    }

    echo "Перенос Lampac завершен успешно"
    return 0
}

setup_antizapret() {
    echo "Настраиваем Антизапрет"
    
    # Создаем папку на целевом сервере
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "mkdir -p /home/$NEW_USER/antizapret"
    
    # Создаем временную папку локально
    LOCAL_TEMP_DIR=$(mktemp -d)
    
    # Копируем с исходного сервера на локальную машину
    echo "Копируем antizapret с исходного сервера на локальную машину..."
    rsync -avz -e "ssh -i $SSH_KEY" root@"$SOURCE_HOST":/home/$NEW_USER/antizapret/ "$LOCAL_TEMP_DIR/antizapret_data"
    
    # Копируем с локальной машины на целевой сервер
    echo "Копируем antizapret на целевой сервер..."
    rsync -avz -e "ssh -i $SSH_KEY" "$LOCAL_TEMP_DIR/antizapret_data/" root@"$DEST_HOST":/home/$NEW_USER/antizapret/
    
    # Очищаем временную папку
    rm -rf "$LOCAL_TEMP_DIR"
    
    # Запускаем docker-контейнеры
    echo "Запускаем Docker-контейнеры..."
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "cd /home/$NEW_USER/antizapret && docker compose pull && docker compose build && docker compose up -d && docker system prune -f"
}

transfer_nginx_certs() {
    echo "Переносим конфиги Nginx и сертификаты"
    
    # Создаем временную папку локально
    LOCAL_TEMP_DIR=$(mktemp -d)
    
    # Копируем конфиги Nginx
    echo "Копируем конфиги Nginx..."
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled"
    
    # sites-available
    rsync -avz -e "ssh -i $SSH_KEY" root@"$SOURCE_HOST":/etc/nginx/sites-available/ "$LOCAL_TEMP_DIR/sites-available"
    rsync -avz -e "ssh -i $SSH_KEY" -r "$LOCAL_TEMP_DIR/sites-available/" root@"$DEST_HOST":/etc/nginx/sites-available/
    # scp -i "$SSH_KEY" -r "$LOCAL_TEMP_DIR/sites-available" root@"$DEST_HOST":/etc/nginx/
    
    # sites-enabled
    rsync -avz -e "ssh -i $SSH_KEY" root@"$SOURCE_HOST":/etc/nginx/sites-enabled/ "$LOCAL_TEMP_DIR/sites-enabled"
    rsync -avz -e "ssh -i $SSH_KEY" -r "$LOCAL_TEMP_DIR/sites-enabled" root@"$DEST_HOST":/etc/nginx/
    
    # Сертификаты Let's Encrypt
    echo "Копируем сертификаты Let's Encrypt..."
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "mkdir -p /etc/letsencrypt"
    rsync -avz -e "ssh -i $SSH_KEY" root@"$SOURCE_HOST":/etc/letsencrypt/ "$LOCAL_TEMP_DIR/letsencrypt"
    rsync -avz -e "ssh -i $SSH_KEY" -r "$LOCAL_TEMP_DIR/letsencrypt" root@"$DEST_HOST":/etc/
    
    # Очищаем временную папку
    rm -rf "$LOCAL_TEMP_DIR"
    
    # Перезагружаем Nginx
    echo "Перезагружаем Nginx..."
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "systemctl restart nginx"
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
    echo "Настраиваем NUMParser"

    # Создаем временную директорию
    mkdir -p "$LOCAL_TEMP_DIR/numparser_data" || {
        echo "Не удалось создать временную директорию"
        return 1
    }
    
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "git clone https://github.com/Igorek1986/NUMParser.git || true"
    scp -i "$SSH_KEY" numparser_config.yml $NEW_USER@"$DEST_HOST":/home/$NEW_USER/NUMParser/config.yml
    ssh -i "$SSH_KEY" "$NEW_USER@$DEST_HOST" "
    # Принудительно обновляем PATH
    export PATH=\"\$PATH:/usr/local/go/bin\"
    
    # Переходим в директорию и собираем
    cd NUMParser && \
    go build -o NUMParser_deb ./cmd || {
        echo -e '${ERROR_COLOR}ОШИБКА сборки NUMParser${NC}';
        echo 'Проверьте путь к Go:';
        which go;
        exit 1;
    }
"
    
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "sudo bash -c 'cat > /etc/systemd/system/numparser.service <<\"EOF\"
[Unit]
Description=NUMParser Service
Wants=network.target
After=network.target

[Service]
WorkingDirectory=/home/$NEW_USER/NUMParser
ExecStart=/home/$NEW_USER/NUMParser/NUMParser_deb
Environment=GIN_MODE=release
Restart=always
User=$NEW_USER

[Install]
WantedBy=multi-user.target
EOF'"
    
    # Копируем файлы с исходного сервера на локальную машину
    rsync -avz -e "ssh -i $SSH_KEY" $NEW_USER@"$SOURCE_HOST":/home/$NEW_USER/NUMParser/db/numparser.db "$LOCAL_TEMP_DIR/numparser_data"
    rsync -avz -e "ssh -i $SSH_KEY" "$LOCAL_TEMP_DIR/numparser_data/numparser.db" $NEW_USER@"$DEST_HOST":/home/$NEW_USER/NUMParser/db/
    
    # Очищаем временную папку
    rm -rf "$LOCAL_TEMP_DIR"

    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "sudo systemctl daemon-reload && sudo systemctl start numparser && sudo systemctl enable numparser"
}

setup_movies_api() {
    echo "Настраиваем Movies-api"
    
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "git clone https://github.com/Igorek1986/movies-api.git || true"
    scp -i "$SSH_KEY" movies-api.env $NEW_USER@"$DEST_HOST":/home/$NEW_USER/movies-api/.env
    # ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "cd movies-api && poetry install --no-root"
    echo "Устанавливаем зависимости..."
    ssh -i "$SSH_KEY" "$NEW_USER@$DEST_HOST" "
        cd movies-api
        export PATH=\"/home/$NEW_USER/.local/bin:\$PATH\"
        /home/$NEW_USER/.local/bin/poetry install --no-root || {
            echo -e '${ERROR_COLOR}Ошибка установки зависимостей!${NC}'
            exit 1
        }
    "
    
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "sudo bash -c 'cat > /etc/systemd/system/movies-api.service <<\"EOF\"
[Unit]
Description=Movies API Service
Wants=network.target
After=network.target

[Service]
WorkingDirectory=/home/$NEW_USER/movies-api
ExecStart=/home/$NEW_USER/.local/bin/poetry run python main.py
Restart=always
User=$NEW_USER

[Install]
WantedBy=multi-user.target
EOF'"
    
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "sudo systemctl daemon-reload && sudo systemctl start movies-api && sudo systemctl enable movies-api"
}

setup_3proxy() {
    echo "Устанавливаем 3proxy"
    
    # Установка 3proxy
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "git clone https://github.com/z3apa3a/3proxy || true"
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "cd 3proxy && ln -s Makefile.Linux Makefile && make && sudo make install"
    
    # Копируем конфиг 3proxy
    echo "Копируем конфигурацию 3proxy..."
    LOCAL_TEMP_FILE=$(mktemp)
    rsync -avz -e "ssh -i $SSH_KEY" root@"$SOURCE_HOST":/etc/3proxy/conf/3proxy.cfg "$LOCAL_TEMP_FILE"
    # scp -i "$SSH_KEY" root@"$SOURCE_HOST":/etc/3proxy/conf/3proxy.cfg "$LOCAL_TEMP_FILE"
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "sudo mkdir -p /etc/3proxy/conf"
    rsync -avz -e "ssh -i $SSH_KEY" "$LOCAL_TEMP_FILE" root@"$DEST_HOST":/etc/3proxy/conf/3proxy.cfg
    # scp -i "$SSH_KEY" "$LOCAL_TEMP_FILE" root@"$DEST_HOST":/etc/3proxy/conf/3proxy.cfg
    rm -f "$LOCAL_TEMP_FILE"
    
    # Запускаем службу
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "sudo systemctl start 3proxy.service && sudo systemctl enable 3proxy.service"
}

setup_glances() {
    echo "Устанавливаем Glances"
    
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "pipx install glances && pipx inject glances fastapi uvicorn jinja2 || true"
    
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "sudo bash -c 'cat > /etc/systemd/system/glances.service <<\"EOF\"
[Unit]
Description=Glances (via pipx)
After=network.target

[Service]
ExecStart=/home/$NEW_USER/.local/bin/glances -w -B 0.0.0.0
Restart=on-failure
User=$NEW_USER

[Install]
WantedBy=multi-user.target
EOF'"
    
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "sudo systemctl daemon-reload && sudo systemctl start glances && sudo systemctl enable glances"
}

setup_marzban() {
    echo "=== Процесс миграции Marzban ==="

    ssh -i "$SSH_KEY" root@"$DEST_HOST" '
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

    # 2. Копирование данных через временную папку
    echo "Подготавливаем данные для переноса..."
    LOCAL_TEMP_DIR=$(mktemp -d)
    
    # Копируем данные
    echo "Копируем /var/lib/marzban..."
    rsync -avz -e "ssh -i $SSH_KEY" \
        root@"$SOURCE_HOST":/var/lib/marzban/ \
        "$LOCAL_TEMP_DIR/marzban_data/" || {
            echo -e "${ERROR_COLOR}Ошибка копирования данных Marzban${NC}" >&2
            rm -rf "$LOCAL_TEMP_DIR"
            return 1
        }

    # Копируем .env файл
    echo "Копируем конфигурацию .env..."
    rsync -avz -e "ssh -i $SSH_KEY" \
        root@"$SOURCE_HOST":/opt/marzban/.env \
        "$LOCAL_TEMP_DIR/.env" || {
            echo -e "${ERROR_COLOR}Ошибка копирования .env файла${NC}" >&2
            rm -rf "$LOCAL_TEMP_DIR"
            return 1
        }

    # Переносим на целевой сервер
    echo "Переносим данные на новый сервер..."
    rsync -avz -e "ssh -i $SSH_KEY" \
        "$LOCAL_TEMP_DIR/marzban_data/" \
        root@"$DEST_HOST":/var/lib/marzban/ || {
            echo -e "${ERROR_COLOR}Ошибка переноса данных${NC}" >&2
            rm -rf "$LOCAL_TEMP_DIR"
            return 1
        }

    if [ "$DEBUG" = "True" ]; then
        echo -e "\n${ERROR_COLOR}❗ Режим отладки${NC}\n"
    else
        rsync -avz -e "ssh -i $SSH_KEY" \
            "$LOCAL_TEMP_DIR/.env" \
            root@"$DEST_HOST":/opt/marzban/.env || {
                echo -e "${ERROR_COLOR}Ошибка переноса .env файла${NC}" >&2
                rm -rf "$LOCAL_TEMP_DIR"
                return 1
            }
    fi

    # Очистка
    rm -rf "$LOCAL_TEMP_DIR"

    if [ "$DEBUG" = "True" ]; then
        echo -e "\n${ERROR_COLOR}❗ Режим отладки${NC}\n"
    else
        echo "Останавливаем Marzban на исходном сервере..."
        ssh -i "$SSH_KEY" root@"$SOURCE_HOST" "marzban down"
        echo "Marzban на исходном сервере остановлен"
    fi

    # # 3. Запуск Marzban
    ssh -i "$SSH_KEY" root@"$DEST_HOST" '
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
    PANEL_PORT=$(ssh -i "$SSH_KEY" root@"$DEST_HOST" \
        "grep '^UVICORN_PORT' /opt/marzban/.env | awk -F'=' '{gsub(/[ \"]/, \"\", \$2); print \$2}'")

    echo "=== Миграция Marzban успешно завершена ==="
    echo "Панель доступна по адресу: https://$DEST_HOST:${PANEL_PORT:-8000}"
}

setup_fail2ban() {
    echo "Настраиваем fail2ban"

    # Создаем временную папку локально
    LOCAL_TEMP_DIR=$(mktemp -d)
    mkdir -p "$LOCAL_TEMP_DIR/fail2ban"

    # Копируем конфигурационные файлы с исходного сервера
    echo "Копируем конфигурацию fail2ban..."
    rsync -avz -e "ssh -i $SSH_KEY" \
        root@"$SOURCE_HOST":/etc/fail2ban/jail.local \
        "$LOCAL_TEMP_DIR/fail2ban/" || {
            echo -e "${ERROR_COLOR}Ошибка копирования jail.local${NC}"
            return 1
        }

    rsync -avz -e "ssh -i $SSH_KEY" \
        root@"$SOURCE_HOST":/etc/fail2ban/filter.d/ \
        "$LOCAL_TEMP_DIR/fail2ban/filter.d/" || {
            echo -e "${ERROR_COLOR}Ошибка копирования фильтров${NC}"
            return 1
        }

    # Копируем файлы на целевой сервер
    echo "Переносим конфигурацию на новый сервер..."
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "mkdir -p /etc/fail2ban/filter.d"
    
    rsync -avz -e "ssh -i $SSH_KEY" \
        "$LOCAL_TEMP_DIR/fail2ban/jail.local" \
        root@"$DEST_HOST":/etc/fail2ban/ || {
            echo -e "${ERROR_COLOR}Ошибка переноса jail.local${NC}"
            return 1
        }

    rsync -avz -e "ssh -i $SSH_KEY" \
        "$LOCAL_TEMP_DIR/fail2ban/filter.d/" \
        root@"$DEST_HOST":/etc/fail2ban/filter.d/ || {
            echo -e "${ERROR_COLOR}Ошибка переноса фильтров${NC}"
            return 1
        }

    # Убедимся, что права установлены правильно
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "
        chmod 644 /etc/fail2ban/jail.local
        chmod 644 /etc/fail2ban/filter.d/*
    "

    # Перезапускаем fail2ban
    echo "Перезапускаем fail2ban..."
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "systemctl restart fail2ban"

    # Проверяем статус
    echo "Проверяем статус fail2ban..."
    ssh -i "$SSH_KEY" root@"$DEST_HOST" "fail2ban-client status"

    # Очищаем временные файлы
    rm -rf "$LOCAL_TEMP_DIR"

    echo "Настройка fail2ban завершена"
}

cleanup() {
    echo "Выполняем очистку"
    ssh -i "$SSH_KEY" $NEW_USER@"$DEST_HOST" "sudo apt autoremove -y"
}

update_dns_records() {
    if [ "$DEBUG" = "True" ]; then
        echo -e "\n${WARNING_COLOR}=== ПРОПУСК: Обновление DNS (режим отладки) ===${NC}"
        return 0
    fi

    echo -e "\n${INFO_COLOR}=== ОБНОВЛЕНИЕ DNS ЗАПИСЕЙ ===${NC}"
    echo "Используем IP из DEST_HOST: $DEST_HOST"

    # Кодируем логин и пароль для URL
    local encoded_login
    encoded_login=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$BEGET_LOGIN'))")
    local encoded_password
    encoded_password=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$BEGET_PASSWORD'))")

    local all_success=true

    for domain in $DOMAINS_TO_UPDATE; do
        echo "Обновляем A-запись для $domain..."

        # Формируем JSON и кодируем его
        local json_data="{\"fqdn\":\"$domain\",\"records\":{\"A\":[{\"priority\":10,\"value\":\"$DEST_HOST\"}]}}"
        local encoded_data
        encoded_data=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$json_data")

        # Выполняем запрос к API Beget
        local response
        response=$(curl -s "https://api.beget.com/api/dns/changeRecords?login=$encoded_login&passwd=$encoded_password&input_format=json&output_format=json&input_data=$encoded_data")

        echo "Ответ API: $response"

        # Проверяем успешность
        if ! echo "$response" | jq -e '.status == "success" and .answer.status == "success"' >/dev/null; then
            all_success=false
            echo -e "${ERROR_COLOR}Ошибка при обновлении DNS для $domain${NC}" >&2
        fi

        # Обновляем www-поддомен
        local www_domain="www.$domain"
        echo "Обновляем A-запись для $www_domain..."
        local www_json_data="{\"fqdn\":\"$www_domain\",\"records\":{\"A\":[{\"priority\":10,\"value\":\"$DEST_HOST\"}]}}"
        local www_encoded_data
        www_encoded_data=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$www_json_data")

        local www_response
        www_response=$(curl -s "https://api.beget.com/api/dns/changeRecords?login=$encoded_login&passwd=$encoded_password&input_format=json&output_format=json&input_data=$www_encoded_data")

        echo "Ответ API для www: $www_response"

        if ! echo "$www_response" | jq -e '.status == "success" and .answer.status == "success"' >/dev/null; then
            all_success=false
            echo -e "${ERROR_COLOR}Ошибка при обновлении DNS для $www_domain${NC}" >&2
        fi
    done

    # Возвращаем статус через глобальную переменную
    DNS_UPDATED=$all_success
}

main() {
    # echo "=== Начало миграции VPS ==="
    echo -e "${HEADER_COLOR}\n=== НАЧАЛО МИГРАЦИИ VPS ===${NC}"
    check_required_files
    
    echo "Источник: $SOURCE_HOST"
    echo "Назначение: $DEST_HOST"
    echo "Пользователь: $NEW_USER"

    # Выполнение функций по флагам
    run_if_enabled "setup_ssh_keys"
    run_if_enabled "fix_system_locale"
    run_if_enabled "create_user"

    # Базовые настройки
    run_if_enabled "install_base_packages"
    run_if_enabled "setup_oh_my_zsh"
    run_if_enabled "install_pyenv"
    run_if_enabled "install_poetry"

    # Установка от root
    run_if_enabled "install_lampac"
    run_if_enabled "transfer_nginx_certs"
    run_if_enabled "setup_marzban"
    run_if_enabled "setup_fail2ban"

    # Установка от пользователя
    run_if_enabled "install_go"
    run_if_enabled "setup_antizapret"
    run_if_enabled "setup_numparser"
    run_if_enabled "setup_movies_api"
    run_if_enabled "setup_3proxy"
    run_if_enabled "setup_glances"

    # Обновление DNS только в production-режиме
    if [ "$DEBUG" = "False" ]; then
        run_if_enabled "update_dns_records"
    fi

    # Очистка
    run_if_enabled "cleanup"

    echo ""
    # echo "=== Миграция успешно завершена! ==="
    echo -e "${HEADER_COLOR}\n=== МИГРАЦИЯ ЗАВЕРШЕНА ===${NC}"
    echo "Доступ к серверу:"
    echo "SSH: ssh -i $SSH_KEY $NEW_USER@$DEST_HOST"
    echo "Пароль пользователя: $NEW_USER_PASSWORD"

    # Красивое напоминание
    if [ "$DEBUG" = "True" ] || [ "$RUN_UPDATE_DNS_RECORDS" = "False" ] || [ "$DNS_UPDATED" = "false" ]; then
        echo -e "\n${HIGHLIGHT_COLOR}=== НЕ ЗАБУДЬТЕ ОБНОВИТЬ DNS ЗАПИСИ ===${NC}"
        echo -e "${WARNING_COLOR}Следующие домены нужно перенаправить на новый IP ($DEST_HOST):${NC}"

        for domain in $DOMAINS_TO_UPDATE; do
            echo -e "  • ${SUCCESS_COLOR}$domain${NC}"
            echo -e "  • ${SUCCESS_COLOR}www.$domain${NC}"
        done

        echo -e "\n${ERROR_COLOR}❗ Это важно сделать сразу после миграции!${NC}\n"
    fi
}

main "$@"