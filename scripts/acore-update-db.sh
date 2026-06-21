#!/usr/bin/env bash
set -euo pipefail

# 在本地构建 AzerothCore db-import 镜像，并对远程数据库执行导入/更新。
# 使用方法:
#   ./scripts/acore-update-db.sh [OPTIONS]
#
# 默认读取 acore-deploy/.env 中的配置。
# ACORE_DIR 优先顺序: --acore-dir 参数 > .env 中的 ACORE_DIR
# ACORE_DIR 必须在 .env 中或命令行参数中指定，脚本中不内置任何本地绝对路径。
#
# 支持两种模式：
#   1. 自动更新：运行 dbimport，自动应用 updates 目录下的 SQL
#   2. 单文件导入：通过 --sql-file 和 --database 导入指定 SQL 文件

# 根据脚本位置自动定位 acore-deploy 项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DRY_RUN=false
ENV_FILE="$PROJECT_ROOT/.env"
TAG=""
ACORE_DIR_ARG=""
SQL_FILE=""
TARGET_DB=""

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --dry-run            Preview updates without applying them
  --env-file <path>    Path to .env file (default: $ENV_FILE)
  --tag <tag>          Docker image tag (default: current git short sha)
  --acore-dir <path>   Path to AzerothCore source directory
                       (default: value of ACORE_DIR in .env)
  --sql-file <path>    Import a single SQL file (requires --database)
  --database <name>    Target database for --sql-file
                       (must be one of: acore_auth, acore_characters, acore_world)
  -h, --help           Show this help message

Required environment variables (can be set in .env):
  ACORE_DIR            AzerothCore source directory
  AC_LOGIN_DATABASE_INFO
  AC_WORLD_DATABASE_INFO
  AC_CHARACTER_DATABASE_INFO

Examples:
  # Auto-apply pending updates
  $0

  # Preview pending updates
  $0 --dry-run

  # Import a single SQL file into acore_characters
  $0 --sql-file /path/to/challenge_mode_record.sql --database acore_characters
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        --tag)
            TAG="$2"
            shift 2
            ;;
        --acore-dir)
            ACORE_DIR_ARG="$2"
            shift 2
            ;;
        --sql-file)
            SQL_FILE="$2"
            shift 2
            ;;
        --database)
            TARGET_DB="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: env file not found: $ENV_FILE" >&2
    exit 1
fi

# 安全加载 .env：不执行 shell 解释，支持值中包含 ;、$、空格、= 等特殊字符
load_env() {
    local env_file="$1"
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 去除首尾空白
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        # 跳过空行和注释
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        # 按第一个 = 分割
        key="${line%%=*}"
        value="${line#*=}"
        # 去除 key 的首尾空白
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        # 去除 value 的首尾空白
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        # 去除可能包围的引号
        if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
            value="${value:1:-1}"
        elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
            value="${value:1:-1}"
        fi
        # 仅导出非空 key
        [[ -n "$key" ]] && export "$key=$value"
    done < "$env_file"
}

load_env "$ENV_FILE"

# 根据数据库名解析 .env 中的连接字符串，格式: host;port;user;password;database
# 结果写入全局变量: host, port, user, password, database
parse_db_info() {
    local db_name="$1"
    local conn_var=""
    case "$db_name" in
        acore_auth)       conn_var="AC_LOGIN_DATABASE_INFO" ;;
        acore_characters) conn_var="AC_CHARACTER_DATABASE_INFO" ;;
        acore_world)      conn_var="AC_WORLD_DATABASE_INFO" ;;
        *)
            echo "Error: unknown database '$db_name'." >&2
            echo "Must be one of: acore_auth, acore_characters, acore_world." >&2
            exit 1
            ;;
    esac

    local conn_str="${!conn_var:-}"
    if [[ -z "$conn_str" ]]; then
        echo "Error: $conn_var is not set in $ENV_FILE" >&2
        exit 1
    fi

    IFS=';' read -r host port user password database <<< "$conn_str"
    if [[ -z "${host:-}" || -z "${port:-}" || -z "${user:-}" || -z "${database:-}" ]]; then
        echo "Error: invalid connection string in $conn_var" >&2
        exit 1
    fi
}

# 解析 ACORE_DIR：--acore-dir 参数 > .env 中的 ACORE_DIR
if [[ -n "$ACORE_DIR_ARG" ]]; then
    ACORE_DIR="$ACORE_DIR_ARG"
elif [[ -z "${ACORE_DIR:-}" ]]; then
    echo "Error: ACORE_DIR is not set." >&2
    echo "Please configure ACORE_DIR in your .env file or pass --acore-dir." >&2
    exit 1
fi

CONFIGS_DIR="$PROJECT_ROOT/configs"

if [[ ! -d "$ACORE_DIR" ]]; then
    echo "Error: AzerothCore directory not found: $ACORE_DIR" >&2
    exit 1
fi

if [[ ! -f "$CONFIGS_DIR/dbimport.conf" ]]; then
    if [[ -f "$CONFIGS_DIR/dbimport.conf.dist" ]]; then
        echo "dbimport.conf not found, copying from dbimport.conf.dist..."
        cp "$CONFIGS_DIR/dbimport.conf.dist" "$CONFIGS_DIR/dbimport.conf"
    else
        echo "Error: neither dbimport.conf nor dbimport.conf.dist found in $CONFIGS_DIR" >&2
        exit 1
    fi
fi

if [[ -z "$TAG" ]]; then
    TAG=$(cd "$ACORE_DIR" && git rev-parse --short HEAD)
fi

IMAGE="azerothcore-db-import:$TAG"

echo "Using AzerothCore source: $ACORE_DIR"
echo "Building db-import image: $IMAGE"
cd "$ACORE_DIR"
docker build --target db-import -t "$IMAGE" -f apps/docker/Dockerfile .

# 单文件导入模式
if [[ -n "$SQL_FILE" ]]; then
    if [[ -z "$TARGET_DB" ]]; then
        echo "Error: --database is required when using --sql-file." >&2
        exit 1
    fi

    parse_db_info "$TARGET_DB"

    if [[ ! -f "$SQL_FILE" ]]; then
        echo "Error: SQL file not found: $SQL_FILE" >&2
        exit 1
    fi

    echo "Importing SQL file: $SQL_FILE"
    echo "Target database: $TARGET_DB ($database @ $host:$port)"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[dry-run] Would execute:"
        echo "  docker run --rm --entrypoint mysql \\"
        echo "    -v \"$SQL_FILE:/tmp/import.sql:ro\" \\"
        echo "    -e MYSQL_PWD=\"***\" \\"
        echo "    \"$IMAGE\" \\"
        echo "    -h \"$host\" -P \"$port\" -u \"$user\" \"$database\" \\"
        echo "    -e \"source /tmp/import.sql;\""
        echo "Done."
        exit 0
    fi

    docker run --rm \
        --entrypoint mysql \
        -v "$SQL_FILE:/tmp/import.sql:ro" \
        -e MYSQL_PWD="$password" \
        "$IMAGE" \
        -h "$host" -P "$port" -u "$user" "$database" \
        -e "source /tmp/import.sql;"

    echo "Done."
    exit 0
fi

echo "Running database update..."
DOCKER_ARGS=(
    --rm
    -v "$CONFIGS_DIR/dbimport.conf:/azerothcore/env/dist/etc/dbimport.conf:ro"
    -e AC_LOGIN_DATABASE_INFO
    -e AC_WORLD_DATABASE_INFO
    -e AC_CHARACTER_DATABASE_INFO
)

if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry-run mode enabled"
    docker run "${DOCKER_ARGS[@]}" "$IMAGE" /azerothcore/env/dist/bin/dbimport --dry-run
else
    docker run "${DOCKER_ARGS[@]}" "$IMAGE"
fi

echo "Done."
