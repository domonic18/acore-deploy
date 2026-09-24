#!/usr/bin/env bash
set -euo pipefail

# worldserver 健康探针（Docker healthcheck 调用，容器内执行）。
# 通过 SOAP 向本机 worldserver 发送只读命令 `server info`：AC 的 SOAP 实现会把命令
# 排队到世界线程执行、应答等待执行完成才返回（ACSoap.cpp ns1__executeCommand），
# 因此拿到 200 应答即代表世界线程真实存活，不受日志活动量、端口 accept 等代理信号误导。
# 凭证取环境变量 AC_SOAP_HEALTHCHECK_AUTH（格式 user:pass，账号需 gmlevel>=3），
# 未配置时直接失败，避免误配置被当成健康。

AUTH="${AC_SOAP_HEALTHCHECK_AUTH:-}"
PORT="${AC_SOAP_HEALTHCHECK_PORT:-7878}"

if [ -z "${AUTH}" ]; then
    echo "healthcheck: AC_SOAP_HEALTHCHECK_AUTH not set"
    exit 1
fi

BODY='<?xml version="1.0" encoding="utf-8"?><SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="urn:AC"><SOAP-ENV:Body><ns1:executeCommand><command>server info</command></ns1:executeCommand></SOAP-ENV:Body></SOAP-ENV:Envelope>'

RESPONSE=$(exec 3<>/dev/tcp/127.0.0.1/"${PORT}" && {
    printf 'POST / HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nContent-Type: text/xml\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
        "${PORT}" "$(printf '%s' "${AUTH}" | base64)" "${#BODY}" "${BODY}" >&3
    cat <&3
}) || exit 1

# 成功判定：HTTP 200 且存在 executeCommandResponse 节点（该节点仅命令执行成功时出现，
# 不受 server info 输出本地化影响）
if echo "${RESPONSE}" | head -1 | grep -q ' 200 ' &&
   echo "${RESPONSE}" | grep -aq 'executeCommandResponse'; then
    echo "healthcheck: ok"
    exit 0
fi

echo "healthcheck: unexpected SOAP response"
echo "${RESPONSE}" | head -3
exit 1
