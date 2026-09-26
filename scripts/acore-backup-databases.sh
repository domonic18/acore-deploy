#!/usr/bin/env bash
set -euo pipefail

# 数据库备份脚本（每日 cron 调用）：dump 三库 → gzip → 上传 COS → 校验 → 失败推飞书。
# 替代 /workspace/acore-database/scripts/backup-databases.sh（旧版仅本地 dump，无异地副本）。
#
# 流程：
#   1. docker exec acore-mysql mysqldump --single-transaction（InnoDB 一致性快照，不锁表）
#   2. 备份目录 ${ACORE_DB_PROJECT_DIR:-/workspace/acore-database}/backups/YYYYMMDD_HHMMSS/
#   3. 生成 manifest.json（各 .sql.gz 的 size/md5）
#   4. 上传 COS acore-db-backup/{realm}/<timestamp>/（幂等：COS manifest 已存在则跳过，--force 重传）
#   5. 逐对象 stat 校验：size 硬校验（不一致即失败），ETAG==md5 软告警（大对象走分片时 ETAG 非 md5）
#   6. 本地仅保留 DB_BACKUP_KEEP 份，且只清理「已上传 COS」的目录（未上过 COS 的目录永不删除）
#   7. 任一环节失败：飞书 webhook 告警（DB_BACKUP_FEISHU_*，未配置则跳过）+ exit 1
#
# 其他用法：
#   --dir=<path>   上传既有备份目录（不 dump），用于迁移回填/补传
#   --dry-run      只 dump+打包+生成 manifest，不上传不清理，目录保留供检查
#   --test-alert   发送一条测试告警，验证 webhook 链路后退出
#
# 凭证：数据库凭证复用本仓库 .env 的 AC_*_DATABASE_INFO（与游戏服同源账号；
#       AC_LOGIN/AC_WORLD/AC_CHARACTER 三行对应 acore_auth/acore_world/acore_characters，
#       格式 host;port;user;password;database 取第 3/4 段），经 MYSQL_PWD 环境变量注入容器，
#       不落进程命令行；coscli 读取宿主机 ~/.cos.yaml（不入 git）；
#       桶/realm 取本仓库 .env 的 COS_UPLOAD_*。结果落 logs/db-backup-result-<ts>.json（7 天）。

DB_BACKUP_KEEP="${DB_BACKUP_KEEP:-5}"
RESULT_RETENTION_DAYS=7
DATABASES=(acore_auth acore_world acore_characters)

# 常规命令带 --disable-log（coscli 写日志到二进制旁路时权限拒绝会致命）；
# stat 校验需要元数据输出（元数据走日志流，--disable-log 会一并吞掉），
# 改用 --log-path 把日志重定向到可写目录
COSCLI_BIN="${COSCLI_BIN:-$(command -v coscli 2>/dev/null || echo /usr/local/bin/coscli)}"
COSCLI="${COSCLI_BIN} --disable-log"
COSCLI_LOG_DIR="${TMPDIR:-/tmp}/acore-coscli-log"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

DIR_ARG=""
REALM_ARG=""
FORCE=0
DRY_RUN=0
TEST_ALERT=0
for arg in "$@"; do
    case "${arg}" in
        --dir=*) DIR_ARG="${arg#--dir=}" ;;
        --realm=*) REALM_ARG="${arg#--realm=}" ;;
        --force) FORCE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --test-alert) TEST_ALERT=1 ;;
        *) echo "unknown arg: ${arg}" >&2; exit 2 ;;
    esac
done

env_key() {
    grep -E "^${1}=" "${ROOT}/.env" 2>/dev/null | head -1 | cut -d= -f2- || true
}
REALM="${REALM_ARG:-${COS_UPLOAD_REALM:-$(env_key COS_UPLOAD_REALM)}}"
REALM="${REALM:-realm2}"
BUCKET="${COS_UPLOAD_BUCKET:-$(env_key COS_UPLOAD_BUCKET)}"

# --- 飞书告警（加签自定义机器人；文本单行化后仅转义 \ 与 "，不引依赖） ---
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    s="${s//$'\t'/ }"
    printf '%s' "${s}"
}

feishu_alert() {
    local text="$1"
    local url="${DB_BACKUP_FEISHU_WEBHOOK_URL:-$(env_key DB_BACKUP_FEISHU_WEBHOOK_URL)}"
    if [ -z "${url}" ]; then
        echo "  [alert skipped, no webhook] ${text}" >&2
        return 0
    fi
    local secret payload resp
    secret="${DB_BACKUP_FEISHU_WEBHOOK_SECRET:-$(env_key DB_BACKUP_FEISHU_WEBHOOK_SECRET)}"
    if [ -n "${secret}" ]; then
        # 飞书加签：HMAC-SHA256(key= "<ts>\n<secret>", msg="") → base64
        local ts sign
        ts="$(date +%s)"
        sign="$(printf '' | openssl dgst -sha256 -hmac "$(printf '%s\n%s' "${ts}" "${secret}")" -binary | base64)"
        payload="{\"timestamp\":\"${ts}\",\"sign\":\"${sign}\",\"msg_type\":\"text\",\"content\":{\"text\":\"$(json_escape "${text}")\"}}"
    else
        payload="{\"msg_type\":\"text\",\"content\":{\"text\":\"$(json_escape "${text}")\"}}"
    fi
    if resp="$(curl -sS -X POST -H 'Content-Type: application/json' --data "${payload}" "${url}" 2>&1)"; then
        echo "  [alert] feishu: ${resp}"
    else
        echo "  [alert failed] ${resp}" >&2
    fi
}

fail() {
    echo "  [fail] $1" >&2
    feishu_alert "acore-db-backup FAIL on $(hostname): $1 (dir=${BACKUP_DIR:-n/a}, realm=${REALM})"
    exit 1
}

if [ "${TEST_ALERT}" -eq 1 ]; then
    feishu_alert "acore-db-backup TEST alert from $(hostname)：告警链路验证，无需处理"
    echo "test alert sent"
    exit 0
fi

if [ -z "${BUCKET}" ] && [ "${DRY_RUN}" -eq 0 ]; then
    echo "COS_UPLOAD_BUCKET not set (env or .env); required unless --dry-run" >&2
    exit 2
fi

# --- 备份目录 ---
DB_PROJECT_DIR="${ACORE_DB_PROJECT_DIR:-/workspace/acore-database}"
BACKUPS_ROOT="${DB_PROJECT_DIR}/backups"
MYSQL_CONTAINER="${ACORE_MYSQL_CONTAINER:-acore-mysql}"
LOGS_DIR="${ROOT}/logs"
mkdir -p "${LOGS_DIR}" "${COSCLI_LOG_DIR}" 2>/dev/null || true

if [ -n "${DIR_ARG}" ]; then
    BACKUP_DIR="${DIR_ARG}"
    [ -d "${BACKUP_DIR}" ] || { echo "backup dir not found: ${BACKUP_DIR}" >&2; exit 2; }
    ls "${BACKUP_DIR}"/*.sql.gz >/dev/null 2>&1 || { echo "no .sql.gz in ${BACKUP_DIR}" >&2; exit 2; }
else
    TS="$(TZ=Asia/Shanghai date +%Y%m%d_%H%M%S)"
    BACKUP_DIR="${BACKUPS_ROOT}/${TS}"
    mkdir -p "${BACKUP_DIR}" || fail "cannot create backup dir: ${BACKUP_DIR}"
fi
TS="$(basename "${BACKUP_DIR}")"
RESULT_FILE="${LOGS_DIR}/db-backup-result-${TS}.json"

log() {
    echo "$(date '+%F %T') $1" | tee -a "${BACKUP_DIR}/backup.log"
}

# --- 数据库凭证：复用本仓库 .env 的 AC_*_DATABASE_INFO（与游戏服同源），三行对应三库 ---
# $1=db → 输出两行：user、password（连接串第 3/4 段，格式 host;port;user;password;database）
db_creds() {
    local info
    case "$1" in
        acore_auth) info="$(env_key AC_LOGIN_DATABASE_INFO)" ;;
        acore_world) info="$(env_key AC_WORLD_DATABASE_INFO)" ;;
        acore_characters) info="$(env_key AC_CHARACTER_DATABASE_INFO)" ;;
        *) return 1 ;;
    esac
    [ -n "${info}" ] || return 1
    printf '%s\n%s\n' "$(printf '%s' "${info}" | cut -d';' -f3)" "$(printf '%s' "${info}" | cut -d';' -f4)"
}

# --- 双平台工具函数 ---
filesize() {
    if stat -c%s "$1" >/dev/null 2>&1; then stat -c%s "$1"; else stat -f%z "$1"; fi
}
md5_file() {
    if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | awk '{print $1}'; else md5 -q "$1"; fi
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

# $1=key；输出 ETag/Content-Length 元数据文本，rc 同 coscli stat
cos_stat() {
    ${COSCLI_BIN} --log-path "${COSCLI_LOG_DIR}" stat "cos://${BUCKET}/$1" 2>&1
}

COS_BASE="acore-db-backup/${REALM}/${TS}"

# --- 幂等 ---
if [ "${DRY_RUN}" -eq 0 ] && [ "${FORCE}" -eq 0 ]; then
    if ${COSCLI} stat "cos://${BUCKET}/${COS_BASE}/manifest.json" >/dev/null 2>&1; then
        log "${COS_BASE} already on COS, skip (use --force to overwrite)"
        echo "{\"realm\":\"${REALM}\",\"backupDir\":\"${TS}\",\"skipped\":true}" > "${RESULT_FILE}"
        exit 0
    fi
fi

log "backup dir: ${BACKUP_DIR}"

# --- dump ---
if [ -z "${DIR_ARG}" ]; then
    if ! docker ps --format '{{.Names}}' | grep -qx "${MYSQL_CONTAINER}"; then
        fail "mysql container not running: ${MYSQL_CONTAINER}"
    fi
    for db in "${DATABASES[@]}"; do
        creds="$(db_creds "${db}")" || fail "missing AC_*_DATABASE_INFO for ${db} in ${ROOT}/.env"
        db_user="$(printf '%s' "${creds}" | sed -n 1p)"
        db_pass="$(printf '%s' "${creds}" | sed -n 2p)"
        [ -n "${db_user}" ] && [ -n "${db_pass}" ] || fail "cannot parse user/password for ${db}"
        log "dumping ${db} (user=${db_user})..."
        if ! docker exec -e MYSQL_PWD="${db_pass}" "${MYSQL_CONTAINER}" \
                mysqldump --single-transaction --no-tablespaces -u"${db_user}" "${db}" | gzip > "${BACKUP_DIR}/${db}.sql.gz"; then
            rm -f "${BACKUP_DIR}/${db}.sql.gz"
            fail "mysqldump ${db} failed"
        fi
        if ! gzip -t "${BACKUP_DIR}/${db}.sql.gz"; then
            fail "gzip integrity check failed: ${db}.sql.gz"
        fi
        log "dumped ${db}: $(filesize "${BACKUP_DIR}/${db}.sql.gz") bytes"
    done
fi

# --- manifest ---
MANIFEST_FILES=""
RESULT_UPLOADED=()
RESULT_FAILED=()
for f in "${BACKUP_DIR}"/*.sql.gz; do
    db="$(basename "${f}" .sql.gz)"
    size="$(filesize "${f}")"
    md5="$(md5_file "${f}")"
    [ -n "${MANIFEST_FILES}" ] && MANIFEST_FILES="${MANIFEST_FILES},"
    MANIFEST_FILES="${MANIFEST_FILES}{\"database\":\"${db}\",\"file\":\"${db}.sql.gz\",\"size\":${size},\"md5\":\"${md5}\"}"
done
MANIFEST="{\"realm\":\"${REALM}\",\"backupDir\":\"${TS}\",\"generatedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"files\":[${MANIFEST_FILES}]}"
printf '%s\n' "${MANIFEST}" > "${BACKUP_DIR}/manifest.json"

if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[dry-run] manifest: ${MANIFEST}"
    echo "[dry-run] backup dir kept: ${BACKUP_DIR}"
    echo "{\"realm\":\"${REALM}\",\"backupDir\":\"${TS}\",\"finishedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"dryRun\":true,\"uploaded\":[],\"failed\":[]}" > "${RESULT_FILE}"
    exit 0
fi

# --- 上传 ---
log "uploading cos://${BUCKET}/${COS_BASE}/"
for f in "${BACKUP_DIR}"/*.sql.gz; do
    name="$(basename "${f}")"
    key="${COS_BASE}/${name}"
    if cos_upload "${f}" "${key}"; then
        echo "  [ok] ${name} ($(filesize "${f}") bytes)"
        RESULT_UPLOADED+=("\"${name}\"")
    else
        echo "  [fail] ${name} after retries" >&2
        RESULT_FAILED+=("\"${name}\"")
    fi
done
if cos_upload "${BACKUP_DIR}/manifest.json" "${COS_BASE}/manifest.json"; then
    echo "  [ok] manifest.json"
else
    echo "  [fail] manifest.json after retries" >&2
    RESULT_FAILED+=("\"manifest.json\"")
fi

# --- 校验（Content-Length 精确字节硬校验；ETAG==md5 仅告警，分片上传对象 ETAG 非 md5） ---
# 注意：提取管道必须 || true —— grep 无匹配 rc=1 在 pipefail+set -e 下会静默退出
if [ "${#RESULT_FAILED[@]}" -eq 0 ]; then
    for f in "${BACKUP_DIR}"/*.sql.gz "${BACKUP_DIR}/manifest.json"; do
        name="$(basename "${f}")"
        meta="$(cos_stat "${COS_BASE}/${name}")" || fail "verify: ${name} missing on COS"
        cos_size="$(printf '%s\n' "${meta}" | grep -oE 'Content-Length:[[:space:]]*[0-9]+' | awk '{print $NF}' | head -1 || true)"
        local_size="$(filesize "${f}")"
        if [ -z "${cos_size}" ] || [ "${cos_size}" != "${local_size}" ]; then
            fail "verify: ${name} size mismatch (local=${local_size} cos=${cos_size:-n/a})"
        fi
        cos_etag="$(printf '%s\n' "${meta}" | grep -oE '"[0-9a-f]{32}(-[0-9]+)?"' | head -1 | tr -d '"' || true)"
        case "${cos_etag}" in
            "") ;;
            *-[0-9]*) ;;  # 分片上传 ETAG（<md5>-N），与 md5 不同属预期，跳过比对
            *)
                if [ "${cos_etag}" != "$(md5_file "${f}")" ]; then
                    echo "  [verify-warn] ${name} ETAG != md5 (single-part mismatch; size verified OK)" >&2
                fi
                ;;
        esac
    done
    log "verified ${COS_BASE}/* (size match)"
fi

UPLOADED_JSON="[]"
FAILED_JSON="[]"
[ "${#RESULT_UPLOADED[@]}" -gt 0 ] && UPLOADED_JSON="[$(IFS=,; echo "${RESULT_UPLOADED[*]}")]"
[ "${#RESULT_FAILED[@]}" -gt 0 ] && FAILED_JSON="[$(IFS=,; echo "${RESULT_FAILED[*]}")]"

cat > "${RESULT_FILE}" <<EOF
{"realm":"${REALM}","backupDir":"${TS}","finishedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","dryRun":false,"uploaded":${UPLOADED_JSON},"failed":${FAILED_JSON}}
EOF

# --- 本地清理：只删「COS 上已有 manifest」且超出保留份数的目录 ---
if [ "${#RESULT_FAILED[@]}" -eq 0 ]; then
    log "pruning local backups (keep latest ${DB_BACKUP_KEEP}, only COS-verified)..."
    old_dirs="$(ls -td "${BACKUPS_ROOT}"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9] 2>/dev/null | tail -n +$((DB_BACKUP_KEEP + 1)) || true)"
    for d in ${old_dirs}; do
        if ${COSCLI} stat "cos://${BUCKET}/acore-db-backup/${REALM}/$(basename "${d}")/manifest.json" >/dev/null 2>&1; then
            if rm -rf "${d}" 2>/dev/null; then
                echo "  pruned $(basename "${d}")"
            else
                echo "  [keep] cannot delete $(basename "${d}") (permission denied)" >&2
            fi
        else
            echo "  [keep] $(basename "${d}") not on COS yet"
        fi
    done
fi

find "${LOGS_DIR}" -maxdepth 1 -name 'db-backup-result-????????_??????.json' -mtime +"${RESULT_RETENTION_DAYS}" -print -delete 2>/dev/null || true

if [ "${#RESULT_FAILED[@]}" -gt 0 ]; then
    fail "upload/verify incomplete: ${FAILED_JSON}"
fi

log "done, result in ${RESULT_FILE}"
