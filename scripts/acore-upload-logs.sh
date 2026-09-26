#!/usr/bin/env bash
set -euo pipefail

# 日志外发脚本（生产宿主机 cron 每日 04:30 调用）：归档前一日四类日志并上传 COS，
# 供 acore-manager 的 SCF 巡检 Job（06:00）拉取分析。
#
# 归档依赖 worldserver.conf/authserver.conf 的 Appender flags=39（含 0x20 USE_DATE）：
# 日志进程内零点自动按日滚动为 <name>_YYYY-MM-DD.log，因此本脚本不做 copytruncate，
# 直接按确定性日期取文件。crash 类无文件，用 docker logs 按当日时间窗导出。
#
# 上传契约须与消费端 acore-manager backend/src/agent/tools/log-tools/log-workspace.ts
# 及 manifest-tool.ts 逐字段一致：
#   key:  acore-logs/{realm}/{date}/{type}.tar.gz + manifest.json
#         type ∈ {worldserver, authserver, anticheat, crash}，单包上限 200MB（超限仅告警）
#   manifest: {realm, date, generatedAt, files:[{type, file, size, md5, lines}]}
#         md5/size 为归档文件字节，lines 为日志非空行数；tar 内文件位于根级原名
# 幂等：COS 上当日 manifest 已存在则整批跳过（--force 强制重传）。
# 本地按日日志仅保留 LOG_RETENTION_DAYS 天，且仅在本批上传全部成功后清理
# （避免上传持续失败期间把从未上传成功的日志删掉）。
# 凭证：coscli 读取宿主机 ~/.cos.yaml（不入 git），桶名/ realm 取环境变量 COS_UPLOAD_*
# 或 .env 同名键。执行结果落 logs/upload-result-<date>.json。

MAX_ARCHIVE_BYTES=209715200  # 200MB，对齐消费端 MAX_ARCHIVE_BYTES
LOG_RETENTION_DAYS=7         # 本地按日日志保留天数
COSCLI="${COSCLI:-coscli}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

DATE_ARG=""
REALM_ARG=""
FORCE=0
DRY_RUN=0
for arg in "$@"; do
    case "${arg}" in
        --date=*) DATE_ARG="${arg#--date=}" ;;
        --realm=*) REALM_ARG="${arg#--realm=}" ;;
        --force) FORCE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        *) echo "unknown arg: ${arg}" >&2; exit 2 ;;
    esac
done

# GNU date（生产 Linux）与 BSD date（macOS 本地调试）双实现；$2 为 ±N 天。
# GNU 分支必须走 epoch 算术：`-d "${1} 12:00 -1 day"` 的 "-1" 会被解析为
# 时区偏移而非天数（生产实测 +1/-1 算反），带时间成分的相对天数不可用
shift_day() {
    if date -d 'yesterday' +%F >/dev/null 2>&1; then
        TZ=Asia/Shanghai date -d @$(( $(TZ=Asia/Shanghai date -d "${1}" +%s) + ${2} * 86400 )) +%F
    else
        TZ=Asia/Shanghai date -j -f '%Y-%m-%d' -v"${2}d" "${1}" +%F
    fi
}

if [ -n "${DATE_ARG}" ]; then
    if ! [[ "${DATE_ARG}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "--date must be YYYY-MM-DD" >&2; exit 2
    fi
    D="${DATE_ARG}"
else
    D="$(shift_day "$(TZ=Asia/Shanghai date +%F)" -1)"
fi
NEXT="$(shift_day "${D}" +1)"

# 不直接 source .env：其中 AC_* 连接串含未引用分号，sourcing 会当命令执行；
# 末尾 || true 吞掉 grep 无匹配的退出码，避免赋值命令替换在 pipefail 下中断脚本
env_key() {
    grep -E "^${1}=" "${ROOT}/.env" 2>/dev/null | head -1 | cut -d= -f2- || true
}
REALM="${REALM_ARG:-${COS_UPLOAD_REALM:-$(env_key COS_UPLOAD_REALM)}}"
REALM="${REALM:-realm2}"
BUCKET="${COS_UPLOAD_BUCKET:-$(env_key COS_UPLOAD_BUCKET)}"
if [ -z "${BUCKET}" ] && [ "${DRY_RUN}" -eq 0 ]; then
    echo "COS_UPLOAD_BUCKET not set (env or .env); required unless --dry-run" >&2
    exit 2
fi

LOGS_DIR="${ROOT}/logs"
WORK="$(mktemp -d /tmp/acore-upload-logs.XXXXXX)"
RESULT_FILE="${LOGS_DIR}/upload-result-${D}.json"
mkdir -p "${LOGS_DIR}"

if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[dry-run] workdir kept for inspection: ${WORK}"
else
    trap 'rm -rf "${WORK}"' EXIT
fi

MANIFEST_KEY="acore-logs/${REALM}/${D}/manifest.json"
if [ "${DRY_RUN}" -eq 0 ] && [ "${FORCE}" -eq 0 ]; then
    if ${COSCLI} stat "cos://${BUCKET}/${MANIFEST_KEY}" >/dev/null 2>&1; then
        echo "$(date '+%F %T') ${MANIFEST_KEY} already exists, skip (use --force to overwrite)"
        echo "{\"realm\":\"${REALM}\",\"date\":\"${D}\",\"skipped\":true}" > "${RESULT_FILE}"
        exit 0
    fi
fi

# 计数非空行；grep 在 0 行时 exit 1，需吞掉以满足 pipefail
nonempty_lines() {
    cat "$@" 2>/dev/null | grep -c . || true
}

filesize() {
    if stat -c%s "$1" >/dev/null 2>&1; then stat -c%s "$1"; else stat -f%z "$1"; fi
}

# $1=type，其余=日志文件列表（可能不存在，逐个跳过）；已在 WORK 预置的文件直接采用
build_archive() {
    local type="$1"; shift
    local copied=() f lines=0
    for f in "$@"; do
        if [ -f "${WORK}/${f}" ]; then
            copied+=("${f}")
        elif [ -f "${LOGS_DIR}/${f}" ]; then
            cp "${LOGS_DIR}/${f}" "${WORK}/${f}"
            copied+=("${f}")
        else
            echo "  [missing] ${type}: ${f}" >&2
        fi
    done
    if [ "${#copied[@]}" -eq 0 ]; then return 1; fi
    for f in "${copied[@]}"; do
        lines=$(( lines + $(nonempty_lines "${WORK}/${f}") ))
    done
    tar -czf "${WORK}/${type}.tar.gz" -C "${WORK}" "${copied[@]}"
    rm -f "${copied[@]/#/${WORK}/}"
    echo "${lines}"
}

# $1=local $2=key；指数退避重试 3 次
cos_upload() {
    local attempt=1
    while [ "${attempt}" -le 3 ]; do
        if ${COSCLI} cp "$1" "cos://${BUCKET}/$2"; then return 0; fi
        echo "  upload $2 failed (attempt ${attempt})" >&2
        sleep $((2 ** attempt))
        attempt=$((attempt + 1))
    done
    return 1
}

echo "$(date '+%F %T') uploading acore-logs/${REALM}/${D}/"

MANIFEST_FILES=""
RESULT_UPLOADED=()
RESULT_FAILED=()

collect() {  # $1=type 其余=文件
    local type="$1"; shift
    local lines
    if ! lines="$(build_archive "${type}" "$@")"; then
        echo "  [skip type] ${type}: no files for ${D}"
        return 0
    fi
    local archive="${WORK}/${type}.tar.gz"
    local size md5
    size="$(filesize "${archive}")"
    md5="$(md5sum "${archive}" | awk '{print $1}')"
    if [ "${size}" -gt "${MAX_ARCHIVE_BYTES}" ]; then
        echo "  [warn] ${type}.tar.gz ${size} bytes exceeds consumer limit 200MB" >&2
    fi
    local entry="\"type\":\"${type}\",\"file\":\"${type}.tar.gz\",\"size\":${size},\"md5\":\"${md5}\",\"lines\":${lines}"
    [ -n "${MANIFEST_FILES}" ] && MANIFEST_FILES="${MANIFEST_FILES},"
    MANIFEST_FILES="${MANIFEST_FILES}{${entry}}"
    if [ "${DRY_RUN}" -eq 1 ]; then
        echo "  [dry-run] would upload ${type}.tar.gz (size=${size}, lines=${lines})"
        RESULT_UPLOADED+=("\"${type}\"")
    elif cos_upload "${archive}" "acore-logs/${REALM}/${D}/${type}.tar.gz"; then
        echo "  [ok] ${type}.tar.gz (size=${size}, lines=${lines})"
        RESULT_UPLOADED+=("\"${type}\"")
    else
        echo "  [fail] ${type}.tar.gz after retries" >&2
        RESULT_FAILED+=("\"${type}\"")
    fi
}

collect worldserver "Server_${D}.log" "Errors_${D}.log" "gm_${D}.log"
collect authserver "Auth_${D}.log"
collect anticheat "anticheat_${D}.log"

# crash 类无日志文件：从 docker 容器日志按当日 CST 时间窗导出
CRASH_FILE="docker_worldserver_${D}.log"
if docker logs ac-worldserver --since "${D}T00:00:00+08:00" --until "${NEXT}T00:00:00+08:00" > "${WORK}/${CRASH_FILE}" 2>&1; then
    collect crash "${CRASH_FILE}"
else
    echo "  [skip type] crash: docker logs unavailable (container removed?)"
fi

MANIFEST="{\"realm\":\"${REALM}\",\"date\":\"${D}\",\"generatedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"files\":[${MANIFEST_FILES}]}"
printf '%s\n' "${MANIFEST}" > "${WORK}/manifest.json"

MANIFEST_OK=1
if [ "${DRY_RUN}" -eq 1 ]; then
    echo "  [dry-run] would upload manifest.json"
    echo "  manifest: ${MANIFEST}"
elif cos_upload "${WORK}/manifest.json" "${MANIFEST_KEY}"; then
    echo "  [ok] manifest.json"
else
    echo "  [fail] manifest.json after retries" >&2
    MANIFEST_OK=0
fi

UPLOADED_JSON="[]"
FAILED_JSON="[]"
[ "${#RESULT_UPLOADED[@]}" -gt 0 ] && UPLOADED_JSON="[$(IFS=,; echo "${RESULT_UPLOADED[*]}")]"
[ "${#RESULT_FAILED[@]}" -gt 0 ] && FAILED_JSON="[$(IFS=,; echo "${RESULT_FAILED[*]}")]"

cat > "${RESULT_FILE}" <<EOF
{"realm":"${REALM}","date":"${D}","finishedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","dryRun":$([ "${DRY_RUN}" -eq 1 ] && echo true || echo false),"manifestOk":${MANIFEST_OK},"uploaded":${UPLOADED_JSON},"failed":${FAILED_JSON}}
EOF

# 清理超过保留期的按日日志（-print 便于 cron 日志留痕；只匹配 <name>_YYYY-MM-DD.log，
# 不触碰 Server.log 等当前活跃/遗留文件）。按日日志的清理以上传全部成功为前提；
# upload-result-*.json 是运维留痕，与本次成败无关，按保留期无条件清理。
if [ "${DRY_RUN}" -eq 0 ]; then
    if [ "${#RESULT_FAILED[@]}" -eq 0 ] && [ "${MANIFEST_OK}" -eq 1 ]; then
        echo "pruning daily logs older than ${LOG_RETENTION_DAYS} days:"
        find "${LOGS_DIR}" -maxdepth 1 -name '*_????-??-??.log' -mtime +"${LOG_RETENTION_DAYS}" -print -delete
    fi
    find "${LOGS_DIR}" -maxdepth 1 -name 'upload-result-????-??-??.json' -mtime +"${LOG_RETENTION_DAYS}" -print -delete
fi

echo "$(date '+%F %T') done, result in ${RESULT_FILE}"

[ "${DRY_RUN}" -eq 1 ] && exit 0
[ "${#RESULT_FAILED[@]}" -eq 0 ] && [ "${MANIFEST_OK}" -eq 1 ] || exit 1
