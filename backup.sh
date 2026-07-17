#!/usr/bin/env bash
set -euo pipefail

# 样式文件
ST_RED_BOLD="\033[1;31m"    # 红色 + 加粗
ST_GREEN="\033[0;32m"       # 绿色
ST_CYAN="\033[0;36m"        # 青色
ST_YELLOW_BOLD="\033[1;33m" # 黄色 + 加粗

ST_BOLD="\033[1m"      # 加粗
ST_UNDERLINE="\033[4m" # 下划线
# ST_UNDERLINE_BOLD="\033[1;4m" # 下划线 + 加粗

ST_RESET="\033[0m"
CH_CLIENT_OPTS=(--max_execution_time=1800 --connect_timeout=180)

# 核心函数: 复制数据到备份数据库
function copy_backup_db() {
  DATABASE_NAME="$1"
  BACKUP_DATABASE_NAME="backup_${DATABASE_NAME}"
  echo -e "${ST_GREEN}[INFO]${ST_RESET} Load Database ${DATABASE_NAME} ==> ${BACKUP_DATABASE_NAME}"

  # 表列表
  mapfile -t TABLES < <(
    clickhouse-client "${CH_CLIENT_OPTS[@]}" --query "
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
    # 是否修改过表 DDL
    DIFF_COUNT=$(clickhouse-client "${CH_CLIENT_OPTS[@]}" --query "
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
    # 如果表 DDL 存在 差异
    if [ "$DIFF_COUNT" -gt 0 ]; then
      echo -e "${ST_GREEN}[INFO]${ST_RESET} Table ${table} execute DDL .."
      # 获取建表语句
      DDL_SQL=$(clickhouse-client "${CH_CLIENT_OPTS[@]}" --query "
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

      # 判断备份表是否存在
      EXISTS=$(clickhouse-client "${CH_CLIENT_OPTS[@]}" --query "
        SELECT count()
        FROM system.tables
        WHERE database = '${BACKUP_DATABASE_NAME}'
          AND name = '${table}'
      ")

      # 如果存在则重命名
      if [ "$EXISTS" -gt 0 ]; then
        SUFFIX=$(date +"%Y_%m_%d_%H_%M_%S")
        clickhouse-client "${CH_CLIENT_OPTS[@]}" --query "
          RENAME TABLE ${BACKUP_DATABASE_NAME}.${table}
          TO ${BACKUP_DATABASE_NAME}.z_backup_${table}_${SUFFIX}
        "
      fi

      # 创建表
      clickhouse-client "${CH_CLIENT_OPTS[@]}" --query "$DDL_SQL"
    fi

    # 复制数据
    echo ""
    echo -e "${ST_GREEN}[INFO]${ST_RESET} Table ${table} execute Copy .."
    clickhouse-client "${CH_CLIENT_OPTS[@]}" --query "
      INSERT INTO ${BACKUP_DATABASE_NAME}.${table}
      SELECT * FROM ${DATABASE_NAME}.${table}
    "
    # 优化
    echo ""
    echo -e "${ST_GREEN}[INFO]${ST_RESET} Table ${table} execute Optimize .."
    clickhouse-client "${CH_CLIENT_OPTS[@]}" --query "
      OPTIMIZE TABLE ${BACKUP_DATABASE_NAME}.${table} FINAL
    "
  done
}

# 核心函数: 复制数据到 AWS_S3 存储
function backup_s3() {
  DATABASE_NAME="$1"
  # TODO 请设置默认的环境变量
  # S3_ENDPOINT=""
  # S3_ACCESS_KEY=""
  # S3_SECRET_KEY=""
  S3_PATH=$(date +"%Y.%m.%d.%H")
  echo -e "${ST_GREEN}[INFO]${ST_RESET} Backup S3 Database $DATABASE_NAME ==> S3"

  # 表列表
  mapfile -t TABLES < <(
    clickhouse-client "${CH_CLIENT_OPTS[@]}" --query "
      SELECT name
      FROM system.tables
      WHERE database = '${DATABASE_NAME}'
        AND engine = 'ReplacingMergeTree'
      ORDER BY name
      FORMAT TSV
    "
  )

  # 循环备份表
  for table in "${TABLES[@]}"; do
    TARGET_ENDPOINT="${S3_ENDPOINT}/clickhouse/${DATABASE_NAME}/${S3_PATH}/${table}.parquet"
    echo -e "${ST_GREEN}[INFO]${ST_RESET} Save ${ST_UNDERLINE} ${DATABASE_NAME}.${table} ${ST_RESET} ==> S3(${TARGET_ENDPOINT})"
    # 获取列信息
    COLUMNS_RAW=$(clickhouse-client "${CH_CLIENT_OPTS[@]}" --query "
      SELECT name, type
      FROM system.columns
      WHERE database = '${DATABASE_NAME}'
        AND table = '${table}'
        AND default_kind = ''
      FORMAT TSV
    ")

    # 解析列
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
    clickhouse-client "${CH_CLIENT_OPTS[@]}" --query "$SQL"
  done
}

# Clickhouse 客户端
if ! command -v clickhouse-client >/dev/null 2>&1; then
  echo -e "${ST_RED_BOLD}[ERROR]${ST_RESET} 未检测到 clickhouse-client，请联系运维管理员安装必要客户端 .."
  echo -e "${ST_GREEN}[HELP] ${ST_RESET} 请先安装 ClickHouse 客户端：https://clickhouse.com/docs/en/interfaces/cli"
  echo ""
  exit 1
fi

# 授权认证文件
CK_CONFIG_DIR="$HOME/.clickhouse-client"
CK_CONFIG_FILE="$CK_CONFIG_DIR/config.xml"
if [ ! -f "$CK_CONFIG_FILE" ]; then
  # 创建目录
  mkdir -p "$CK_CONFIG_DIR"
  read -r -p "请输入 ClickHouse 服务器地址: " host
  read -r -p "请输入端口 (默认 9000): " port
  port=${port:-9000}
  read -r -p "请输入用户名 (默认 default): " user
  user=${user:-default}
  read -r -s -p "请输入密码: " password
  # 写入 JSON
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

# 数据库列表
mapfile -t DATABASES < <(
clickhouse-client "${CH_CLIENT_OPTS[@]}" \
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
  echo -e "${ST_RED_BOLD}[ERROR]${ST_RESET} 未获取到数据库列表！"
  exit 1
fi

echo -e "${ST_CYAN}[QUES] 请选择数据库：${ST_RESET}"
select db in "${DATABASES[@]}"; do
  if [ -n "$db" ]; then
    echo -e "${ST_GREEN}[OK]${ST_RESET} 选择的数据库是: ${ST_UNDERLINE} $db ${ST_RESET}"
    SELECT_DB="$db"
    break
  else
    echo -e "${ST_YELLOW_BOLD}[WARN]${ST_RESET} 无效选择，请重新输入！"
    exit 1
  fi
done

# 执行的操作
echo ""
echo -e "${ST_CYAN}[QUES] 请选择要执行的操作：${ST_RESET}"
select action in "复制数据库到备份库" "备份到S3存储" "退出"; do
  case "$action" in
  "复制数据库到备份库")
    echo ""
    echo -e "${ST_GREEN}[OK]${ST_RESET} 已选择：${ST_UNDERLINE} 复制数据库到备份库 ${ST_RESET}"
    ACTION="copy_backup_db"
    break
    ;;
  "备份到S3存储")
    echo ""
    echo -e "${ST_GREEN}[OK]${ST_RESET} 已选择：${ST_UNDERLINE} 备份到S3存储 ${ST_RESET}"
    ACTION="backup_s3"
    break
    ;;
  "退出")
    echo ""
    echo -e "${ST_RED_BOLD}[EXIT]${ST_RESET} 已退出"
    exit 0
    ;;
  *)
    echo ""
    echo -e "${ST_YELLOW_BOLD}[WARN]${ST_RESET} 无效选择，请重新输入"
    exit 1
    ;;
  esac
done

# 执行命令
case "$ACTION" in
copy_backup_db)
  copy_backup_db "${SELECT_DB}"
  ;;
backup_s3)
  backup_s3 "${SELECT_DB}"
  ;;
*)
  exit 1
  ;;
esac
