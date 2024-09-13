#!/bin/bash

# Переменные для Telegram
TELEGRAM_BOT_TOKEN='YOUR BOT API'
TELEGRAM_CHAT_ID='YOUR CHAT ID'

# Переменные для базы данных
DB_NAMES=('marzban' 'DB2' 'DB3')
DB_BACKUP_DIR='/root/backup' # Место где будет собираться бэкап баз данных

# Папки для архивации
SRC_DIRS=(
    '/root/shm'
    '/opt/marzban-shm'
    '/var/lib/marzban-shm'
    '/var/lib/marzban'
)
EXCLUDE_DIRS=('mysql' 'xray-core') # Директории которые будут исключены из бэкапа
BACKUP_DIR='/root/backup' # Место где будет собираться бэкап файлов

# Переменные для Docker MySQL/MariaDB
USE_DOCKER_MYSQL='yes'  # Установите 'yes', если хотите использовать Docker MySQL/MariaDB
DOCKER_CONTAINER_NAME='mysql_container'  # Имя или ID Docker-контейнера MySQL/MariaDB
MYSQL_USER='root'
MYSQL_PASSWORD='your_password'  # Рекомендуется использовать переменные окружения или файл настроек для пароля
DB_TYPE='mysql'  # Установите 'mysql' или 'mariadb'

SERVER_IP=$(curl -s ifconfig.me)

# Папка для хранения архива
DEST_DIR='/root'

# Имя архива с датой и временем
DATE=$(date +'%Y-%m-%d_%H-%M-%S')
ARCHIVE_NAME="MY_backup_$DATE.zip"
ARCHIVE_PATH="$DEST_DIR/$ARCHIVE_NAME"
COMBINED_ARCHIVE_NAME="Combined_Backup_$DATE.zip"
COMBINED_ARCHIVE_PATH="$DEST_DIR/$COMBINED_ARCHIVE_NAME"

# Целевая папка в Cloudflare R2, либо другом месте после настройки Rclone
TARGET_DIR='s3cf:yourdir/'

# Переменная для переноса строки
NL=$'\n'

# Проверка установки утилиты zip
if ! command -v zip &> /dev/null; then
    echo 'zip не установлен. Установка...'
    apt-get update && apt-get install -y zip
fi

# Функция для отправки уведомления в Telegram
send_telegram_message() {
    local MESSAGE="$1"
    local RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" -d chat_id="${TELEGRAM_CHAT_ID}" -d text="${MESSAGE}" -d parse_mode="HTML")
    if ! echo "$RESPONSE" | grep -q '"ok":true'; then
        echo "Failed to send message to Telegram: $RESPONSE"
    fi
}

# Функция для отправки файла в Telegram
send_backup_to_telegram() {
    local file_path="$1"
    local caption="$2"
    local RESPONSE=$(curl -s -F chat_id="${TELEGRAM_CHAT_ID}" -F caption="$caption" -F parse_mode='HTML' -F document=@"$file_path" "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument")
    if ! echo "$RESPONSE" | grep -q '"ok":true'; then
        echo "Failed to send document to Telegram: $RESPONSE"
    fi
}

# Функция для резервного копирования базы данных MySQL/MariaDB
backup_mysql() {
    local total_size=0
    # Определяем команду для дампа в зависимости от типа базы данных
    local DUMP_COMMAND
    local CLIENT_PACKAGE
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

    # Проверка и установка клиента в контейнере
    if [ "$USE_DOCKER_MYSQL" == 'yes' ]; then
        # Проверяем, установлен ли клиент в контейнере
        if ! docker exec "$DOCKER_CONTAINER_NAME" command -v "$DUMP_COMMAND" &> /dev/null; then
            echo "Клиент $DUMP_COMMAND не найден в контейнере. Установка..."
            docker exec "$DOCKER_CONTAINER_NAME" apt-get update
            docker exec "$DOCKER_CONTAINER_NAME" apt-get install -y "$CLIENT_PACKAGE"
        fi
    else
        # Проверяем, установлен ли клиент локально
        if ! command -v "$DUMP_COMMAND" &> /dev/null; then
            echo "Клиент $DUMP_COMMAND не найден локально. Установка..."
            apt-get update
            apt-get install -y "$CLIENT_PACKAGE"
        fi
    fi

    for DB_NAME in "${DB_NAMES[@]}"; do
        echo "Starting $DB_TYPE backup for $DB_NAME..."
        mkdir -p "$DB_BACKUP_DIR"
        local SQL_FILE="$DB_BACKUP_DIR/db_${DB_NAME}.sql"
        local DB_DUMP_NAME="${DB_TYPE^}-$DB_NAME-$DATE.tar.gz"
        local DB_DUMP_PATH="$DB_BACKUP_DIR/$DB_DUMP_NAME"

        if [ "$USE_DOCKER_MYSQL" == 'yes' ]; then
            # Используем команду дампа внутри Docker-контейнера
            docker exec -i "$DOCKER_CONTAINER_NAME" "$DUMP_COMMAND" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$DB_NAME" > "$SQL_FILE"
        else
            # Локальный дамп
            "$DUMP_COMMAND" --defaults-file=~/.my.cnf "$DB_NAME" > "$SQL_FILE"
        fi

        if [ -f "$SQL_FILE" ]; then
            tar czvf "$DB_DUMP_PATH" -C "$DB_BACKUP_DIR" "$(basename "$SQL_FILE")"
            local size=$(stat -c%s "$DB_DUMP_PATH")
            total_size=$((total_size + size))
            rm "$SQL_FILE"
            echo "$DB_TYPE backup for $DB_NAME completed!"
        else
            echo "$DB_TYPE backup for $DB_NAME failed!"
            send_telegram_message "❗ Ошибка при создании дампа базы данных <code>$DB_NAME</code>."
        fi
    done
    echo $total_size
}

# Создание массива с аргументами исключений
EXCLUDE_ARGS=()
for EXCLUDE_DIR in "${EXCLUDE_DIRS[@]}"; do
    EXCLUDE_ARGS+=("--exclude=$EXCLUDE_DIR/*")
done

# Создание архива файлов с исключением указанных директорий
if ! tar czvf "$ARCHIVE_PATH" "${EXCLUDE_ARGS[@]}" -C / "${SRC_DIRS[@]}"; then
    echo "Ошибка при создании архива файлов."
    send_telegram_message "❗ Ошибка при создании архива файлов."
    exit 1
fi

# Проверка размера архива файлов
archive_size=$(stat -c%s "$ARCHIVE_PATH")

# Выполнение резервного копирования баз данных и получение общего размера
total_db_size=$(backup_mysql)

# Проверка, что total_db_size является числом
if ! [[ "$total_db_size" =~ ^[0-9]+$ ]]; then
    total_db_size=0
fi

total_size=$((archive_size + total_db_size))

# Список папок и баз данных для сообщения
folder_list=''
for dir in "${SRC_DIRS[@]}"; do
    folder_list+="➡️ $dir${NL}"
done

db_list=''
for DB_NAME in "${DB_NAMES[@]}"; do
    db_list+="➡️ $DB_NAME${NL}"
done

# Создание комбинированного архива
zip -r "$COMBINED_ARCHIVE_PATH" "$ARCHIVE_PATH" "$DB_BACKUP_DIR"

message="✅ Комбинированный архив <code>$COMBINED_ARCHIVE_NAME</code> успешно создан.${NL}${NL}Папки и базы данных в архиве:${NL}Папки:${NL}$folder_list${NL}Базы данных:${NL}$db_list"

# Переменная для хранения итогового сообщения
final_message="${message}${NL}------------${NL}"

# Загрузка комбинированного архива в Cloudflare R2
if rclone copy "$COMBINED_ARCHIVE_PATH" "$TARGET_DIR"; then
    final_message+="✅ Комбинированный архив <code>$COMBINED_ARCHIVE_NAME</code> успешно загружен в Cloudflare R2.${NL}"
else
    final_message+="❗ Ошибка при загрузке комбинированного архива <code>$COMBINED_ARCHIVE_NAME</code> в Cloudflare R2.${NL}"
fi

# Загрузка архива файлов в Cloudflare R2
if rclone copy "$ARCHIVE_PATH" "$TARGET_DIR"; then
    rm "$ARCHIVE_PATH"
    final_message+="✅ Архив <code>$ARCHIVE_NAME</code> успешно загружен в Cloudflare R2.${NL}"
else
    final_message+="❗ Ошибка при загрузке архива <code>$ARCHIVE_NAME</code> в Cloudflare R2.${NL}"
fi

# Загрузка архивов дампов баз данных в Cloudflare R2
for DB_NAME in "${DB_NAMES[@]}"; do
    DB_DUMP_NAME="${DB_TYPE^}-$DB_NAME-$DATE.tar.gz"
    DB_DUMP_PATH="$DB_BACKUP_DIR/$DB_DUMP_NAME"
    if [ -f "$DB_DUMP_PATH" ]; then
        if rclone copy "$DB_DUMP_PATH" "$TARGET_DIR"; then
            rm "$DB_DUMP_PATH"
            final_message+="✅ Дамп базы данных <code>$DB_DUMP_NAME</code> успешно загружен в Cloudflare R2.${NL}"
        else
            final_message+="❗ Ошибка при загрузке дампа базы данных <code>$DB_DUMP_NAME</code> в Cloudflare R2.${NL}"
        fi
    fi
done

final_message+="------------${NL}✅ Все операции успешно выполнены."
send_backup_to_telegram "$COMBINED_ARCHIVE_PATH" "$final_message"

# Удаление комбинированного архива после отправки
rm "$COMBINED_ARCHIVE_PATH"

# Ротация архивов в Cloudflare R2 (оставить только за последние 7 дней)
rclone delete --min-age 7d "$TARGET_DIR"
