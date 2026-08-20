#!/usr/bin/env bash
set -euo pipefail

CONTAINER="ac-worldserver"
LOG_PATH="/azerothcore/env/dist/logs/Server.log"
MAX_IDLE_SECONDS=1000  # 约 16 分钟无日志更新即判定为卡死

cd /workspace/acore-deploy

# 容器没运行，直接拉起
if ! docker ps -q --filter "name=^/${CONTAINER}$" | grep -q .; then
    echo "$(date '+%F %T') ${CONTAINER} not running, starting..."
    docker compose up -d ac-worldserver
    exit 0
fi

# 获取日志文件最后修改时间（秒）
last_modify=$(docker exec "${CONTAINER}" stat -c %Y "${LOG_PATH}" 2>/dev/null || echo 0)
now=$(date +%s)
idle=$((now - last_modify))

if [ "${idle}" -gt "${MAX_IDLE_SECONDS}" ]; then
    echo "$(date '+%F %T') ${CONTAINER} idle ${idle}s, restarting..."
    docker compose restart "${CONTAINER}"
else
    echo "$(date '+%F %T') ${CONTAINER} idle ${idle}s, OK"
fi
