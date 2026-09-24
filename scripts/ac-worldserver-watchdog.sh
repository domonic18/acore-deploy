#!/usr/bin/env bash
set -euo pipefail

# worldserver 看门狗（宿主机 cron 每分钟调用）。
# 职责唯一：执行 Docker healthcheck 的判决。进程退出类故障（崩溃、每日 04:00
# ServerAutoShutdown 关服）由 Docker restart: unless-stopped 原生拉起，本脚本不插手；
# 只有进程存活但世界线程卡死（healthcheck 转 unhealthy，Docker 无能为力）才重启。
# 刻意不含「容器不存在则拉起」分支：该场景与 Docker 策略重叠，且会与停服检修冲突
# （compose stop 后被本脚本拉回）。存活信号见 scripts/soap-probe.sh。

CONTAINER="ac-worldserver"

cd /workspace/acore-deploy

STATUS=$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER}" 2>/dev/null || echo unknown)

case "${STATUS}" in
    healthy|starting)
        echo "$(date '+%F %T') ${CONTAINER} ${STATUS}, OK"
        ;;
    *)
        echo "$(date '+%F %T') ${CONTAINER} ${STATUS}, restarting..."
        docker compose restart "${CONTAINER}"
        ;;
esac
