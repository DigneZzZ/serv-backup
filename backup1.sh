#!/bin/bash

# Переменные для Telegram
TELEGRAM_BOT_TOKEN='YOUR BOT API'
TELEGRAM_CHAT_ID='YOUR CHAT ID'

# Переменные для базы данных
DB_NAMES=('marzban' 'DB2' 'DB3')
DB_BACKUP_DIR='/root/backup' #Место где будет собираться бэкап баз данных

# Папки для архивации
SRC_DIRS=(
    '/root/shm'
    '/opt/marzban-shm'
    '/var/lib/marzban-shm'
    '/var/lib/marzban'
)
EXCLUDE_DIRS=('mysql' 'xray-core') # Директории которые будут исключены из бэкапа
BACKUP_DIR='/root/backup' #Место где будет собираться бэкап файлов

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

# Функция для резервного копирования базы данных MySQL
# Для работы с базой используется локально установленный mysql, не в контейнере. Данные для подключения берутся из файла ~/.my.cnf
backup_mysql() {
    local total_size=0
    for DB_NAME in "${DB_NAMES[@]}"; do
        echo "Starting MySQL backup for $DB_NAME..."
        mkdir -p "$DB_BACKUP_DIR"
        local SQL_FILE="$DB_BACKUP_DIR/db_${DB_NAME}.sql"
        local DB_DUMP_NAME="MySQL-$DB_NAME-$DATE.tar.gz"
        local DB_DUMP_PATH="$DB_BACKUP_DIR/$DB_DUMP_NAME"
        mysqldump --defaults-file=~/.my.cnf "$DB_NAME" > "$SQL_FILE"
        if [ -f "$SQL_FILE" ]; then
            tar czvf "$DB_DUMP_PATH" -C "$DB_BACKUP_DIR" "$(basename "$SQL_FILE")"
            local size=$(stat -c%s "$DB_DUMP_PATH")
            total_size=$((total_size + size))
            rm "$SQL_FILE"
            echo "MySQL backup for $DB_NAME completed!"
        else
            echo "MySQL backup for $DB_NAME failed!"
            send_telegram_message "❗ Ошибка при создании дампа базы данных <code>$DB_NAME</code>."
        fi
    done
    echo $total_size
}

# Создание строки для исключения директорий
EXCLUDE_STRING=""
for EXCLUDE_DIR in "${EXCLUDE_DIRS[@]}"; do
    EXCLUDE_STRING+=" --exclude=$EXCLUDE_DIR/*"
done

# Создание архива файлов с исключением указанных директорий
tar czvf "$ARCHIVE_PATH" -C / $(printf "%s\n" "${SRC_DIRS[@]}" | sed "s:/*\$::g") $(echo "$EXCLUDE_STRING")

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
    DB_DUMP_NAME="MySQL-$DB_NAME-$DATE.tar.gz"
    DB_DUMP_PATH="$DB_BACKUP_DIR/$DB_DUMP_NAME"
    if [ -f "$DB_DUMP_PATH"; then
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
