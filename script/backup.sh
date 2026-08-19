#!/usr/bin/env bash
set -euo pipefail

# Example: run in background with prefilled menu choices
# nohup bash -c "printf '%s\n' '12' '3' | bash ./a.sh" > a.log 2>&1 < /dev/null &
# Notes:
# - 12 = database menu index
# - 3  = operation menu index
# - If ~/.clickhouse-client/config.xml does not exist, the script still prompts for connection info

# Text styles
ST_RED_BOLD="\033[1;31m"    # Red + bold
ST_GREEN="\033[0;32m"       # Green
ST_CYAN="\033[0;36m"        # Cyan
ST_YELLOW_BOLD="\033[1;33m" # Yellow + bold

ST_BOLD="\033[1m"      # Bold
ST_UNDERLINE="\033[4m" # Underline
# ST_UNDERLINE_BOLD="\033[1;4m" # Underline + bold

ST_RESET="\033[0m"
# CK Options Timeout
CK_CLIENT_OPTS=(--max_execution_time=1800 --connect_timeout=180)

# Core function: Copy data to the backup database
function copy_backup_db() {
  DATABASE_NAME="$1"
  BACKUP_DATABASE_NAME="backup_${DATABASE_NAME}"
  echo -e "${ST_GREEN}[INFO]${ST_RESET} Load Database ${DATABASE_NAME} ==> ${BACKUP_DATABASE_NAME}"

  # Table List
  mapfile -t TABLES < <(
    clickhouse-client "${CK_CLIENT_OPTS[@]}" --query "
      SELECT name
      FROM system.tables
      WHERE database = '${DATABASE_NAME}'
        AND engine = 'ReplacingMergeTree'
      ORDER BY name
      FORMAT TSV
    "
  )

  for table in "${TABLES[@]}"; do
    echo "=================================================="
    echo -e "${ST_GREEN}[INFO]${ST_RESET} ${ST_BOLD}Ready table ${table} ${ST_RESET}.."
    # Check whether the table DDL has changed
    DIFF_COUNT=$(clickhouse-client "${CK_CLIENT_OPTS[@]}" --query "
      SELECT count()
      FROM (
        SELECT coalesce(a.name, b.name) AS column_name,
               a.type AS old_type,
               b.type AS new_type
        FROM
          (SELECT name, type
           FROM system.columns
           WHERE database = '${DATABASE_NAME}'
             AND table = '${table}'
             AND default_kind = '') a
        FULL OUTER JOIN
          (SELECT name, type
           FROM system.columns
           WHERE database = '${BACKUP_DATABASE_NAME}'
             AND table = '${table}'
             AND default_kind = '') b
        ON a.name = b.name
        WHERE a.type != b.type OR a.name IS NULL OR b.name IS NULL
      )
    ")
    # If the table DDL differs
    if [ "$DIFF_COUNT" -gt 0 ]; then
      echo -e "${ST_GREEN}[INFO]${ST_RESET} Table ${table} execute DDL .."
      # Get the CREATE TABLE statement
      DDL_SQL=$(clickhouse-client "${CK_CLIENT_OPTS[@]}" --query "
        SELECT replace(
          create_table_query,
          'CREATE TABLE ${DATABASE_NAME}.',
          'CREATE TABLE IF NOT EXISTS ${BACKUP_DATABASE_NAME}.'
        )
        FROM system.tables
        WHERE database = '${DATABASE_NAME}'
          AND name = '${table}'
        LIMIT 1
        FORMAT Raw
      ")
      if [ -z "$DDL_SQL" ]; then
        continue
      fi

      # Check whether the backup table exists
      EXISTS=$(clickhouse-client "${CK_CLIENT_OPTS[@]}" --query "
        SELECT count()
        FROM system.tables
        WHERE database = '${BACKUP_DATABASE_NAME}'
          AND name = '${table}'
      ")

      # Rename it if it exists
      if [ "$EXISTS" -gt 0 ]; then
        SUFFIX=$(date +"%Y_%m_%d_%H_%M_%S")
        clickhouse-client "${CK_CLIENT_OPTS[@]}" --query "
          RENAME TABLE ${BACKUP_DATABASE_NAME}.${table}
          TO ${BACKUP_DATABASE_NAME}.z_backup_${table}_${SUFFIX}
        "
      fi

      # Create the table
      clickhouse-client "${CK_CLIENT_OPTS[@]}" --query "$DDL_SQL"
    fi

    # Copy the data
    echo ""
    echo -e "${ST_GREEN}[INFO]${ST_RESET} Table ${table} execute Copy .."
    clickhouse-client "${CK_CLIENT_OPTS[@]}" --query "
      INSERT INTO ${BACKUP_DATABASE_NAME}.${table}
      SELECT * FROM ${DATABASE_NAME}.${table}
    "
    # Optimize the table
    echo ""
    echo -e "${ST_GREEN}[INFO]${ST_RESET} Table ${table} execute Optimize .."
    clickhouse-client "${CK_CLIENT_OPTS[@]}" --query "
      OPTIMIZE TABLE ${BACKUP_DATABASE_NAME}.${table} FINAL
    "
  done
}

# Core function: Copy data to AWS S3 storage
function backup_s3() {
  DATABASE_NAME="$1"
  S3_PATH=$(date +"%Y.%m.%d.%H")
  echo -e "${ST_GREEN}[INFO]${ST_RESET} Backup S3 Database $DATABASE_NAME ==> S3"

  # Table list
  mapfile -t TABLES < <(
    clickhouse-client "${CK_CLIENT_OPTS[@]}" --query "
      SELECT name
      FROM system.tables
      WHERE database = '${DATABASE_NAME}'
        AND engine = 'ReplacingMergeTree'
      ORDER BY name
      FORMAT TSV
    "
  )

  # Back up each table
  for table in "${TABLES[@]}"; do
    TARGET_ENDPOINT="${S3_ENDPOINT}/clickhouse/${DATABASE_NAME}/${S3_PATH}/${table}.parquet"
    echo -e "${ST_GREEN}[INFO]${ST_RESET} Save ${ST_UNDERLINE} ${DATABASE_NAME}.${table} ${ST_RESET} ==> S3(${TARGET_ENDPOINT})"
    # Get column information
    COLUMNS_RAW=$(clickhouse-client "${CK_CLIENT_OPTS[@]}" --query "
      SELECT name, type
      FROM system.columns
      WHERE database = '${DATABASE_NAME}'
        AND table = '${table}'
        AND default_kind = ''
      FORMAT TSV
    ")

    # Parse the columns
    SOURCE_COLUMNS=""
    TARGET_COLUMNS=""
    while IFS=$'\t' read -r col_name col_type; do
      SOURCE_COLUMNS+="\`${col_name}\`,"
      TARGET_COLUMNS+="${col_name} ${col_type},"
    done <<<"$COLUMNS_RAW"
    SOURCE_COLUMNS="${SOURCE_COLUMNS%,}"
    TARGET_COLUMNS="${TARGET_COLUMNS%,}"

    # SQL
    SQL="
      INSERT INTO FUNCTION s3(
        '${TARGET_ENDPOINT}',
        '${S3_ACCESS_KEY}',
        '${S3_SECRET_KEY}',
        'Parquet',
        '${TARGET_COLUMNS}'
      )
      SELECT ${SOURCE_COLUMNS}
      FROM ${DATABASE_NAME}.${table}
    "
    clickhouse-client "${CK_CLIENT_OPTS[@]}" --query "$SQL"
  done
}

# Core function: Backup DuckDB
function backup_duckdb() {
  DATABASE_NAME="$1"
  echo -e "${ST_GREEN}[INFO]${ST_RESET} Backup Database $DATABASE_NAME ==> DuckDB file: ${DATABASE_NAME}_backup.duckdb"

  # Table list
  mapfile -t TABLES < <(
    clickhouse-client "${CK_CLIENT_OPTS[@]}" --query "
      SELECT name
      FROM system.tables
      WHERE database = '${DATABASE_NAME}'
        AND engine = 'ReplacingMergeTree'
      ORDER BY name
      FORMAT TSV
    "
  )

  for table in "${TABLES[@]}"; do
    echo -e "${ST_GREEN}[INFO]${ST_RESET} Exporting ${DATABASE_NAME}.${table}"

    parquet_file="$(mktemp "/tmp/clickhouse_${table//[^a-zA-Z0-9_.-]/_}_XXXXXX.parquet")"

    clickhouse_table="${DATABASE_NAME}.${table}"

    clickhouse-client "${CK_CLIENT_OPTS[@]}" \
      --query "SELECT * FROM ${clickhouse_table} FORMAT Parquet" |
      pv -f \
      >"$parquet_file"

    duckdb -dark-mode -batch "${DATABASE_NAME}_backup.duckdb" <<SQL
BEGIN;
DROP TABLE IF EXISTS ${table};
CREATE TABLE ${table} AS
SELECT *
FROM read_parquet("${parquet_file}");
COMMIT;
SQL

    rm -f -- "$parquet_file"

    echo -e "${ST_GREEN}[INFO]${ST_RESET} Imported ${table} into ${DATABASE_NAME}_backup.duckdb"
  done
}

# ClickHouse client
if ! command -v clickhouse-client >/dev/null 2>&1; then
  echo -e "${ST_RED_BOLD}[ERROR]${ST_RESET} clickhouse-client was not found. Contact your system administrator to install the required client."
  echo -e "${ST_GREEN}[HELP] ${ST_RESET} Install the ClickHouse client first: https://clickhouse.com/docs/en/interfaces/cli"
  echo ""
  exit 1
fi

# Duck client
if ! command -v duckdb >/dev/null 2>&1; then
  echo -e "${ST_RED_BOLD}[ERROR]${ST_RESET} duckdb was not found. Please install the DuckDB CLI first."
  echo -e "${ST_GREEN}[HELP] ${ST_RESET} DuckDB CLI installation: https://duckdb.org/install/"
  echo ""
  exit 1
fi

# Authentication configuration file
CK_CONFIG_DIR="$HOME/.clickhouse-client"
CK_CONFIG_FILE="$CK_CONFIG_DIR/config.xml"
if [ ! -f "$CK_CONFIG_FILE" ]; then
  # Create the directory
  mkdir -p "$CK_CONFIG_DIR"
  read -r -p "Enter the ClickHouse server address: " host
  read -r -p "Enter the port (default: 9000): " port
  port=${port:-9000}
  read -r -p "Enter the username (default: default): " user
  user=${user:-default}
  read -r -s -p "Enter the password: " password
  # Write the XML configuration
  cat >"$CK_CONFIG_FILE" <<EOF
<clickhouse>
  <host>${host}</host>
  <port>${port}</port>
  <user>${user}</user>
  <password>${password}</password>
</clickhouse>
EOF
fi
echo ""

# Database list
mapfile -t DATABASES < <(
  clickhouse-client "${CK_CLIENT_OPTS[@]}" \
    --query "
    SELECT name
    FROM system.databases
    WHERE name NOT LIKE 'backup%'
      AND name NOT IN (
        'system',
        'information_schema',
        'INFORMATION_SCHEMA',
        'default'
      )
    FORMAT TSV
  "
)

if [ ${#DATABASES[@]} -eq 0 ]; then
  echo -e "${ST_RED_BOLD}[ERROR]${ST_RESET} No databases were found."
  exit 1
fi

CK_SERVER_VERSION=$(clickhouse-client "${CK_CLIENT_OPTS[@]}" --query "SELECT version()")
echo -e "${ST_GREEN}[INFO]${ST_RESET} ClickHouse server version: ${ST_BOLD}${CK_SERVER_VERSION}${ST_RESET}"
echo -e "${ST_CYAN}[QUES] Select a database:${ST_RESET}"
select db in "${DATABASES[@]}"; do
  if [ -n "$db" ]; then
    echo -e "${ST_GREEN}[OK]${ST_RESET} Selected database: ${ST_UNDERLINE} $db ${ST_RESET}"
    SELECT_DB="$db"
    break
  else
    echo -e "${ST_YELLOW_BOLD}[WARN]${ST_RESET} Invalid selection. Try again."
    exit 1
  fi
done

# Operation to perform
echo ""
echo -e "${ST_CYAN}[QUES] Select an operation:${ST_RESET}"
select action in "Copy database to backup database" "Back up to S3 storage" "Back up to DuckDB storage" "Exit"; do
  case "$action" in
  "Copy database to backup database")
    echo ""
    echo -e "${ST_GREEN}[OK]${ST_RESET} Selected: ${ST_UNDERLINE} Copy database to backup database ${ST_RESET}"
    ACTION="copy_backup_db"
    break
    ;;
  "Back up to S3 storage")
    echo ""
    echo -e "${ST_GREEN}[OK]${ST_RESET} Selected: ${ST_UNDERLINE} Back up to S3 storage ${ST_RESET}"
    ACTION="backup_s3"
    break
    ;;
  "Back up to DuckDB storage")
    echo ""
    echo -e "${ST_GREEN}[OK]${ST_RESET} Selected: ${ST_UNDERLINE} Back up to DuckDB storage ${ST_RESET}"
    ACTION="backup_duckdb"
    break
    ;;
  "Exit")
    echo ""
    echo -e "${ST_RED_BOLD}[EXIT]${ST_RESET} Exited"
    exit 0
    ;;
  *)
    echo ""
    echo -e "${ST_YELLOW_BOLD}[WARN]${ST_RESET} Invalid selection. Try again."
    exit 1
    ;;
  esac
done

# Execute the selected operation
case "$ACTION" in
copy_backup_db)
  copy_backup_db "${SELECT_DB}"
  ;;
backup_s3)
  backup_s3 "${SELECT_DB}"
  ;;
backup_duckdb)
  backup_duckdb "${SELECT_DB}"
  ;;
*)
  exit 1
  ;;
esac
