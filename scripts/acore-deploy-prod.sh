#!/usr/bin/env bash
set -euo pipefail

# 从镜像仓库拉取预构建的 AzerothCore server 镜像并部署到生产环境。
# 使用方法:
#   ./scripts/acore-deploy-prod.sh [OPTIONS]
#
# 默认读取 acore-deploy/.env 中的 REGISTRY、NAMESPACE、TAG。
# 本脚本不会修改 .env 文件；--tag 仅作为临时覆盖。

# 根据脚本位置自动定位 acore-deploy 项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE="$PROJECT_ROOT/.env"
DRY_RUN=false
TAG=""
PULL=true
RECREATE=true

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --dry-run            Preview commands without executing them
  --env-file <path>    Path to .env file (default: $ENV_FILE)
  --tag <tag>          Image tag override (default: value of TAG in .env)
  --no-pull            Skip docker pull, use locally available image
  --no-recreate        Do not force-recreate containers (only restart)
  -h, --help           Show this help message

Required environment variables (can be set in .env):
  REGISTRY             Docker registry, e.g. ccr.ccs.tencentyun.com
  NAMESPACE            Docker namespace, e.g. lokta
  TAG                  Image tag, e.g. master-4eb3baf

Examples:
  # Deploy using TAG from .env
  $0

  # Preview deployment commands
  $0 --dry-run

  # Deploy a specific tag without modifying .env
  $0 --tag master-4eb3baf

  # Use local image without pulling
  $0 --no-pull
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
        --no-pull)
            PULL=false
            shift
            ;;
        --no-recreate)
            RECREATE=false
            shift
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

# 保存命令行传入的 tag，避免被 .env 覆盖
TAG_ARG="$TAG"

load_env "$ENV_FILE"

if [[ -z "${REGISTRY:-}" || -z "${NAMESPACE:-}" ]]; then
    echo "Error: REGISTRY and NAMESPACE must be set in $ENV_FILE" >&2
    exit 1
fi

# 确定镜像标签：--tag 参数 > .env 中的 TAG
if [[ -n "$TAG_ARG" ]]; then
    TAG="$TAG_ARG"
    TAG_SOURCE="command line"
elif [[ -n "${TAG:-}" ]]; then
    TAG_SOURCE="$ENV_FILE"
else
    echo "Error: TAG is not set. Please configure TAG in $ENV_FILE or pass --tag." >&2
    exit 1
fi

IMAGE_NAME="${REGISTRY}/${NAMESPACE}/azerothcore-server:${TAG}"

echo "Deploying image: $IMAGE_NAME"
echo "Tag source: $TAG_SOURCE"
echo "Pull: $PULL"
echo "Force recreate: $RECREATE"

if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "[dry-run] Would execute:"
    if [[ "$PULL" == "true" ]]; then
        echo "  docker pull \"$IMAGE_NAME\""
    else
        echo "  # docker pull skipped (--no-pull)"
    fi
    if [[ "$RECREATE" == "true" ]]; then
        echo "  docker-compose up -d --force-recreate ac-worldserver ac-authserver"
    else
        echo "  docker-compose up -d ac-worldserver ac-authserver"
    fi
    echo "Done."
    exit 0
fi

if [[ "$PULL" == "true" ]]; then
    echo "Pulling image..."
    docker pull "$IMAGE_NAME"
fi

echo "Deploying containers..."
cd "$PROJECT_ROOT"

if [[ "$RECREATE" == "true" ]]; then
    docker-compose up -d --force-recreate ac-worldserver ac-authserver
else
    docker-compose up -d ac-worldserver ac-authserver
fi

echo "Done."
echo ""
echo "Check status:  docker-compose ps"
echo "View logs:     docker-compose logs --tail=50 -f ac-worldserver"
