#!/usr/bin/env bash
set -euo pipefail

# 将 wow-dbc 中的 DBC 源文件同步到 acore-deploy/data/dbc/
# 使用方法:
#   ./scripts/acore-update-dbc.sh [OPTIONS]
#
# 默认从 acore-deploy/wow-dbc/src/dbc/ 同步（Git submodule）。
# 生产环境可通过 --local-path 指向手动放置的 wow-dbc 目录。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE="$PROJECT_ROOT/.env"
DRY_RUN=false
PULL=false
LOCAL_PATH=""

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --dry-run            Preview sync without copying files
  --pull               Update wow-dbc submodule before syncing
  --local-path <path>  Sync from a local path instead of submodule
                       Example: /path/to/wow-dbc/src/dbc
  --env-file <path>   Path to .env file (default: $ENV_FILE)
  -h, --help           Show this help message

Default behavior:
  Sync DBC from wow-dbc/src/dbc/ (Git submodule) to data/dbc/.

Examples:
  # Sync from submodule
  $0

  # Update submodule to latest, then sync
  $0 --pull

  # Sync from manually downloaded directory (production)
  $0 --local-path /opt/wow-dbc/src/dbc

  # Preview only
  $0 --dry-run
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --pull)
            PULL=true
            shift
            ;;
        --local-path)
            LOCAL_PATH="$2"
            shift 2
            ;;
        --env-file)
            ENV_FILE="$2"
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

if [[ -f "$ENV_FILE" ]]; then
    load_env "$ENV_FILE"
fi

# 确定 DBC 源目录
if [[ -n "$LOCAL_PATH" ]]; then
    SRC_DIR="$LOCAL_PATH"
elif [[ -n "${WOW_DBC:-}" ]]; then
    SRC_DIR="$WOW_DBC"
else
    SRC_DIR="$PROJECT_ROOT/wow-dbc/src/dbc"
fi

DST_DIR="$PROJECT_ROOT/data/dbc"
VERSION_FILE="$PROJECT_ROOT/configs/dbc-version.json"

if [[ ! -d "$SRC_DIR" ]]; then
    echo "Error: DBC source directory not found: $SRC_DIR" >&2
    echo "Run with --local-path or ensure the wow-dbc submodule is initialized:" >&2
    echo "  git submodule update --init" >&2
    exit 1
fi

# 如需更新 submodule
if [[ "$PULL" == "true" ]]; then
    if [[ -e "$PROJECT_ROOT/wow-dbc/.git" ]]; then
        echo "Updating wow-dbc submodule..."
        git -C "$PROJECT_ROOT" submodule update --remote wow-dbc
    else
        echo "Warning: --pull specified but wow-dbc is not a submodule, skipping pull." >&2
    fi
fi

# 尝试定位 wow-dbc 仓库根目录
REPO_DIR=""
if [[ "$SRC_DIR" == "$PROJECT_ROOT/wow-dbc/src/dbc" ]]; then
    REPO_DIR="$PROJECT_ROOT/wow-dbc"
else
    # 对于自定义路径，尝试向上推断仓库根目录
    REPO_DIR="$(cd "$SRC_DIR" && cd ../.. 2>/dev/null && pwd)" || REPO_DIR=""
fi

# 收集版本信息
COMMIT="unknown"
BRANCH="unknown"
if [[ -e "$REPO_DIR/.git" ]]; then
    COMMIT="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
    BRANCH="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
fi

SYNC_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
FILE_COUNT="$(find "$SRC_DIR" -maxdepth 1 -type f -name '*.dbc' | wc -l | tr -d ' ')"

echo "Using DBC source: $SRC_DIR"
echo "Repository:       ${REPO_DIR:-unknown}"
echo "Commit:           $COMMIT"
echo "Branch:           $BRANCH"
echo "DBC files:        $FILE_COUNT"
echo "Target:           $DST_DIR"

if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "[dry-run] Would sync DBC files:"
    if command -v rsync &>/dev/null; then
        rsync -av --delete --dry-run "$SRC_DIR/" "$DST_DIR/" | sed 's/^/  /'
    else
        find "$SRC_DIR" -maxdepth 1 -type f -name '*.dbc' | sed 's/^/  copy: /'
        echo "  (rsync not available, dry-run details limited)"
    fi
    echo ""
    echo "[dry-run] Would write version file: $VERSION_FILE"
    echo "Done."
    exit 0
fi

mkdir -p "$DST_DIR"

if command -v rsync &>/dev/null; then
    echo ""
    echo "Syncing DBC files with rsync..."
    rsync -av --delete "$SRC_DIR/" "$DST_DIR/"
else
    echo ""
    echo "Syncing DBC files with cp..."
    find "$SRC_DIR" -maxdepth 1 -type f -name '*.dbc' -exec cp -v {} "$DST_DIR/" \;
    find "$DST_DIR" -maxdepth 1 -type f -name '*.dbc' | while read -r dst_file; do
        base="$(basename "$dst_file")"
        if [[ ! -f "$SRC_DIR/$base" ]]; then
            rm -v "$dst_file"
        fi
    done
fi

mkdir -p "$(dirname "$VERSION_FILE")"
cat > "$VERSION_FILE" <<EOF
{
  "source": "$SRC_DIR",
  "repository": "${REPO_DIR:-unknown}",
  "commit": "$COMMIT",
  "branch": "$BRANCH",
  "synced_at": "$SYNC_TIME",
  "file_count": $FILE_COUNT
}
EOF

echo ""
echo "Updated version file: $VERSION_FILE"
echo "Done."
