#!/usr/bin/env bash
set -euo pipefail

# 在本地构建 AzerothCore server 镜像，并部署到当前 acore-deploy 项目。
# 使用方法:
#   ./scripts/acore-build-deploy.sh [OPTIONS]
#
# 默认读取 acore-deploy/.env 中的配置。
# ACORE_DIR 优先顺序: --acore-dir 参数 > .env 中的 ACORE_DIR
# ACORE_DIR 必须在 .env 中或命令行参数中指定，脚本中不内置任何本地绝对路径。

# 根据脚本位置自动定位 acore-deploy 项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE="$PROJECT_ROOT/.env"
TAG="develop-local"
PLATFORM="linux/arm64"
DEPLOY=true
ACORE_DIR_ARG=""

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --env-file <path>    Path to .env file (default: $ENV_FILE)
  --tag <tag>          Docker image tag (default: $TAG)
  --platform <platform> Docker build platform (default: $PLATFORM)
  --no-deploy          Build image only, do not update .env or recreate containers
  --acore-dir <path>   Path to AzerothCore source directory
                       (default: value of ACORE_DIR in .env)
  -h, --help           Show this help message

Required environment variables (can be set in .env):
  ACORE_DIR            AzerothCore source directory
  REGISTRY             Docker registry, e.g. ccr.ccs.tencentyun.com
  NAMESPACE            Docker namespace, e.g. lokta
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        --tag)
            TAG="$2"
            shift 2
            ;;
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --no-deploy)
            DEPLOY=false
            shift
            ;;
        --acore-dir)
            ACORE_DIR_ARG="$2"
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
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
            value="${value:1:-1}"
        elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
            value="${value:1:-1}"
        fi
        [[ -n "$key" ]] && export "$key=$value"
    done < "$env_file"
}

load_env "$ENV_FILE"

# 解析 ACORE_DIR：--acore-dir 参数 > .env 中的 ACORE_DIR
if [[ -n "$ACORE_DIR_ARG" ]]; then
    ACORE_DIR="$ACORE_DIR_ARG"
elif [[ -z "${ACORE_DIR:-}" ]]; then
    echo "Error: ACORE_DIR is not set." >&2
    echo "Please configure ACORE_DIR in your .env file or pass --acore-dir." >&2
    exit 1
fi

if [[ ! -d "$ACORE_DIR" ]]; then
    echo "Error: AzerothCore directory not found: $ACORE_DIR" >&2
    exit 1
fi

if [[ -z "${REGISTRY:-}" || -z "${NAMESPACE:-}" ]]; then
    echo "Error: REGISTRY and NAMESPACE must be set in $ENV_FILE" >&2
    exit 1
fi

IMAGE_NAME="${REGISTRY}/${NAMESPACE}/azerothcore-server:${TAG}"

echo "Using AzerothCore source: $ACORE_DIR"
echo "Building server image: $IMAGE_NAME"
echo "Platform: $PLATFORM"

cd "$ACORE_DIR"
docker build \
    --platform "$PLATFORM" \
    --target server \
    -t "$IMAGE_NAME" \
    -f apps/docker/Dockerfile .

if [[ "$DEPLOY" == "false" ]]; then
    echo "Build complete. --no-deploy specified, skipping deployment."
    exit 0
fi

# 更新 .env 中的 TAG
if grep -q "^TAG=" "$ENV_FILE"; then
    sed "s|^TAG=.*|TAG=$TAG|" "$ENV_FILE" > "${ENV_FILE}.tmp"
else
    cp "$ENV_FILE" "${ENV_FILE}.tmp"
    echo "TAG=$TAG" >> "${ENV_FILE}.tmp"
fi
mv "${ENV_FILE}.tmp" "$ENV_FILE"

echo "Updated TAG=$TAG in $ENV_FILE"

echo "Recreating containers..."
cd "$PROJECT_ROOT"
docker-compose up -d --force-recreate ac-worldserver ac-authserver

echo "Done."
echo ""
echo "Check status:  docker-compose ps"
echo "View logs:     docker-compose logs --tail=50 -f ac-worldserver"
