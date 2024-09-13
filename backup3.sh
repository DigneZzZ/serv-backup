#!/bin/bash

# Скрипт резервного копирования с модульными функциями

# ==================== Переменные конфигурации ====================

# Настройки Telegram
TELEGRAM_BOT_TOKEN='YOUR BOT API'
TELEGRAM_CHAT_ID='YOUR CHAT ID'

# Настройки базы данных
DB_NAMES=('marzban' 'DB2' 'DB3')
DB_BACKUP_DIR='/root/backup' # Папка для хранения бэкапов баз данных

# Папки для архивации
SRC_DIRS=(
    '/root/shm'
    '/opt/marzban-shm'
    '/var/lib/marzban-shm'
    '/var/lib/marzban'
)
EXCLUDE_DIRS=('mysql' 'xray-core') # Директории, которые будут исключены из бэкапа
BACKUP_DIR='/root/backup' # Папка для хранения бэкапов файлов

# Настройки Docker для MySQL/MariaDB
USE_DOCKER_DB='yes'  # Установите 'yes', если используете Docker для базы данных
DOCKER_CONTAINER_NAME='mysql_container'  # Имя или ID Docker-контейнера
MYSQL_USER='root'
MYSQL_PASSWORD='your_password'  # Рекомендуется использовать переменные окружения или файл настроек
DB_TYPE='mysql'  # Установите 'mysql' или 'mariadb'

# IP сервера
SERVER_IP=$(curl -s ifconfig.me)

# Настройки архива
DEST_DIR='/root' # Папка для хранения архивов
DATE=$(date +'%Y-%m-%d_%H-%M-%S')
ARCHIVE_NAME="MY_backup_$DATE.zip"
ARCHIVE_PATH="$DEST_DIR/$ARCHIVE_NAME"
COMBINED_ARCHIVE_NAME="Combined_Backup_$DATE.zip"
COMBINED_ARCHIVE_PATH="$DEST_DIR/$COMBINED_ARCHIVE_NAME"

# Целевая папка в Cloudflare R2 или другом хранилище через rclone
TARGET_DIR='s3cf:yourdir/'

# Перенос строки для сообщений
NL=$'\n'

# ==================== Определение функций ====================

# Функция для проверки и установки необходимых пакетов
install_required_packages() {
    # Проверка и установка zip
    if ! command -v zip &> /dev/null; then
        echo 'zip не установлен. Установка...'
        apt-get update && apt-get install -y zip
    fi
}

# Функция для отправки сообщения в Telegram
send_telegram_message() {
    local MESSAGE="$1"
    local RESPONSE
    RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="${MESSAGE}" \
        -d parse_mode="HTML")
    if ! echo "$RESPONSE" | grep -q '"ok":true'; then
        echo "Не удалось отправить сообщение в Telegram: $RESPONSE"
    fi
}

# Функция для отправки файла в Telegram
send_backup_to_telegram() {
    local file_path="$1"
    local caption="$2"
    local RESPONSE
    RESPONSE=$(curl -s -F chat_id="${TELEGRAM_CHAT_ID}" \
        -F caption="$caption" \
        -F parse_mode='HTML' \
        -F document=@"$file_path" \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument")
    if ! echo "$RESPONSE" | grep -q '"ok":true'; then
        echo "Не удалось отправить документ в Telegram: $RESPONSE"
    fi
}

# Функция для проверки и установки клиента базы данных в контейнере Docker
install_db_client_in_container() {
    local DUMP_COMMAND="$1"
    local CLIENT_PACKAGE="$2"
    # Проверка, установлен ли клиент в контейнере
    if ! docker exec "$DOCKER_CONTAINER_NAME" command -v "$DUMP_COMMAND" &> /dev/null; then
        echo "Клиент $DUMP_COMMAND не найден в контейнере. Установка..."
        docker exec "$DOCKER_CONTAINER_NAME" apt-get update
        docker exec "$DOCKER_CONTAINER_NAME" apt-get install -y "$CLIENT_PACKAGE"
    fi
}

# Функция для резервного копирования баз данных
backup_databases() {
    local total_size=0
    local DUMP_COMMAND
    local CLIENT_PACKAGE

    # Определяем команду дампа и пакет клиента в зависимости от типа базы данных
    if [ "$DB_TYPE" == 'mysql' ]; then
        DUMP_COMMAND='mysqldump'
        CLIENT_PACKAGE='mysql-client'
    elif [ "$DB_TYPE" == 'mariadb' ]; then
        DUMP_COMMAND='mariadb-dump'
        CLIENT_PACKAGE='mariadb-client'
    else
        echo "Unsupported DB_TYPE: $DB_TYPE"
        send_telegram_message "❗ Unsupported DB_TYPE: <code>$DB_TYPE</code>."
        exit 1
    fi

    # Установка клиента в контейнере Docker
    if [ "$USE_DOCKER_DB" == 'yes' ]; then
        install_db_client_in_container "$DUMP_COMMAND" "$CLIENT_PACKAGE"
    else
        # Проверка и установка клиента локально
        if ! command -v "$DUMP_COMMAND" &> /dev/null; then
            echo "Клиент $DUMP_COMMAND не найден локально. Установка..."
            apt-get update
            apt-get install -y "$CLIENT_PACKAGE"
        fi
    fi

    # Резервное копирование каждой базы данных
    for DB_NAME in "${DB_NAMES[@]}"; do
        backup_single_database "$DB_NAME" "$DUMP_COMMAND"
        local size
        size=$(get_file_size "$DB_BACKUP_DIR/${DB_TYPE^}-$DB_NAME-$DATE.tar.gz")
        total_size=$((total_size + size))
    done

    echo $total_size
}

# Функция для резервного копирования одной базы данных
backup_single_database() {
    local DB_NAME="$1"
    local DUMP_COMMAND="$2"

    echo "Начало резервного копирования $DB_TYPE для $DB_NAME..."
    mkdir -p "$DB_BACKUP_DIR"
    local SQL_FILE="$DB_BACKUP_DIR/db_${DB_NAME}.sql"
    local DB_DUMP_NAME="${DB_TYPE^}-$DB_NAME-$DATE.tar.gz"
    local DB_DUMP_PATH="$DB_BACKUP_DIR/$DB_DUMP_NAME"

    if [ "$USE_DOCKER_DB" == 'yes' ]; then
        # Дамп внутри контейнера Docker
        if ! docker exec -i "$DOCKER_CONTAINER_NAME" "$DUMP_COMMAND" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$DB_NAME" > "$SQL_FILE"; then
            echo "Резервное копирование $DB_TYPE для $DB_NAME не удалось!"
            send_telegram_message "❗ Ошибка при создании дампа базы данных <code>$DB_NAME</code>."
            return
        fi
    else
        # Локальный дамп
        if ! "$DUMP_COMMAND" --defaults-file=~/.my.cnf "$DB_NAME" > "$SQL_FILE"; then
            echo "Резервное копирование $DB_TYPE для $DB_NAME не удалось!"
            send_telegram_message "❗ Ошибка при создании дампа базы данных <code>$DB_NAME</code>."
            return
        fi
    fi

    # Архивация SQL-файла
    tar czvf "$DB_DUMP_PATH" -C "$DB_BACKUP_DIR" "$(basename "$SQL_FILE")"
    rm "$SQL_FILE"
    echo "Резервное копирование $DB_TYPE для $DB_NAME завершено!"
}

# Функция для создания архива указанных папок
create_file_archive() {
    # Создание массива аргументов исключений
    local EXCLUDE_ARGS=()
    for EXCLUDE_DIR in "${EXCLUDE_DIRS[@]}"; do
        EXCLUDE_ARGS+=("--exclude=$EXCLUDE_DIR/*")
    done

    # Создание архива
    if ! tar czvf "$ARCHIVE_PATH" "${EXCLUDE_ARGS[@]}" -C / "${SRC_DIRS[@]}"; then
        echo "Ошибка при создании архива файлов."
        send_telegram_message "❗ Ошибка при создании архива файлов."
        exit 1
    fi
}

# Функция для создания комбинированного архива
create_combined_archive() {
    zip -r "$COMBINED_ARCHIVE_PATH" "$ARCHIVE_PATH" "$DB_BACKUP_DIR"
}

# Функция для загрузки файлов с помощью rclone
upload_to_cloud() {
    local file_path="$1"
    local file_name="$2"
    local success_message="$3"
    local failure_message="$4"

    if rclone copy "$file_path" "$TARGET_DIR"; then
        final_message+="$success_message${NL}"
    else
        final_message+="$failure_message${NL}"
    fi
}

# Функция для получения размера файла
get_file_size() {
    local file_path="$1"
    if [ -f "$file_path" ]; then
        stat -c%s "$file_path"
    else
        echo 0
    fi
}

# Функция для ротации бэкапов
rotate_backups() {
    # Оставить бэкапы за последние 7 дней
    rclone delete --min-age 7d "$TARGET_DIR"
}

# ==================== Основной блок выполнения скрипта ====================

install_required_packages

# Создание архива файлов
create_file_archive
archive_size=$(get_file_size "$ARCHIVE_PATH")

# Резервное копирование баз данных
total_db_size=$(backup_databases)
if ! [[ "$total_db_size" =~ ^[0-9]+$ ]]; then
    total_db_size=0
fi

total_size=$((archive_size + total_db_size))

# Подготовка списков для сообщения
folder_list=''
for dir in "${SRC_DIRS[@]}"; do
    folder_list+="➡️ $dir${NL}"
done

db_list=''
for DB_NAME in "${DB_NAMES[@]}"; do
    db_list+="➡️ $DB_NAME${NL}"
done

# Создание комбинированного архива
create_combined_archive

message="✅ Комбинированный архив <code>$COMBINED_ARCHIVE_NAME</code> успешно создан.${NL}${NL}Папки и базы данных в архиве:${NL}Папки:${NL}$folder_list${NL}Базы данных:${NL}$db_list"

# Инициализация итогового сообщения
final_message="${message}${NL}------------${NL}"

# Загрузка комбинированного архива в Cloudflare R2
upload_to_cloud "$COMBINED_ARCHIVE_PATH" "$COMBINED_ARCHIVE_NAME" \
    "✅ Комбинированный архив <code>$COMBINED_ARCHIVE_NAME</code> успешно загружен в Cloudflare R2." \
    "❗ Ошибка при загрузке комбинированного архива <code>$COMBINED_ARCHIVE_NAME</code> в Cloudflare R2."

# Загрузка архива файлов в Cloudflare R2
upload_to_cloud "$ARCHIVE_PATH" "$ARCHIVE_NAME" \
    "✅ Архив <code>$ARCHIVE_NAME</code> успешно загружен в Cloudflare R2." \
    "❗ Ошибка при загрузке архива <code>$ARCHIVE_NAME</code> в Cloudflare R2."

# Удаление локального архива файлов
rm "$ARCHIVE_PATH"

# Загрузка бэкапов баз данных в Cloudflare R2
for DB_NAME in "${DB_NAMES[@]}"; do
    DB_DUMP_NAME="${DB_TYPE^}-$DB_NAME-$DATE.tar.gz"
    DB_DUMP_PATH="$DB_BACKUP_DIR/$DB_DUMP_NAME"
    if [ -f "$DB_DUMP_PATH" ]; then
        upload_to_cloud "$DB_DUMP_PATH" "$DB_DUMP_NAME" \
            "✅ Дамп базы данных <code>$DB_DUMP_NAME</code> успешно загружен в Cloudflare R2." \
            "❗ Ошибка при загрузке дампа базы данных <code>$DB_DUMP_NAME</code> в Cloudflare R2."
        rm "$DB_DUMP_PATH"
    fi
done

final_message+="------------${NL}✅ Все операции успешно выполнены."

# Отправка комбинированного архива в Telegram
send_backup_to_telegram "$COMBINED_ARCHIVE_PATH" "$final_message"

# Удаление комбинированного архива после отправки
rm "$COMBINED_ARCHIVE_PATH"

# Ротация бэкапов в Cloudflare R2
rotate_backups
