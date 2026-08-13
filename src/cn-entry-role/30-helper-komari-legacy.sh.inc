LEGACY_KOMARI_LATENCY_MARKER='# Managed by Po0 Komari latency compatibility; do not edit manually.'
LEGACY_KOMARI_LATENCY_UNIT=po0-komari-latency.service
LEGACY_KOMARI_LATENCY_CONFIG=/etc/redsocks/po0-komari-latency.conf
LEGACY_KOMARI_LATENCY_FIREWALL=/usr/local/libexec/po0-komari-latency-firewall
LEGACY_KOMARI_LATENCY_SERVICE=/etc/systemd/system/${LEGACY_KOMARI_LATENCY_UNIT}

legacy_komari_latency_record() {
    local state=$1
    printf '%s/komari-latency-unit\n' "${state}"
}

legacy_komari_latency_owned() {
    local state=$1 unit=$2 record first second recorded_unit
    local config_hash firewall_hash service_hash
    record=$(legacy_komari_latency_record "${state}")
    [[ -f ${record} && ! -L ${record} ]] || return 1
    [[ $(wc -l <"${record}" | tr -d ' ') == 4 ]] || return 1
    recorded_unit=$(sed -n '1p' "${record}")
    config_hash=$(sed -n '2p' "${record}")
    firewall_hash=$(sed -n '3p' "${record}")
    service_hash=$(sed -n '4p' "${record}")
    [[ ${recorded_unit} == "${unit}" ]] || return 1
    [[ -f ${LEGACY_KOMARI_LATENCY_CONFIG} && ! -L ${LEGACY_KOMARI_LATENCY_CONFIG} \
        && -f ${LEGACY_KOMARI_LATENCY_FIREWALL} && ! -L ${LEGACY_KOMARI_LATENCY_FIREWALL} \
        && -x ${LEGACY_KOMARI_LATENCY_FIREWALL} \
        && -f ${LEGACY_KOMARI_LATENCY_SERVICE} && ! -L ${LEGACY_KOMARI_LATENCY_SERVICE} ]] \
        || return 1
    { IFS= read -r first; IFS= read -r second; } <"${LEGACY_KOMARI_LATENCY_FIREWALL}" || true
    [[ ${first} == '#!/usr/bin/env bash' \
        && ${second} == "${LEGACY_KOMARI_LATENCY_MARKER}" ]] || return 1
    IFS= read -r first <"${LEGACY_KOMARI_LATENCY_SERVICE}" || true
    [[ ${first} == "${LEGACY_KOMARI_LATENCY_MARKER}" ]] || return 1
    [[ $(sha256sum "${LEGACY_KOMARI_LATENCY_CONFIG}" | awk '{print $1}') == "${config_hash}" \
        && $(sha256sum "${LEGACY_KOMARI_LATENCY_FIREWALL}" | awk '{print $1}') == "${firewall_hash}" \
        && $(sha256sum "${LEGACY_KOMARI_LATENCY_SERVICE}" | awk '{print $1}') == "${service_hash}" ]]
}

remove_legacy_komari_latency_compat() {
    local state=$1 unit=$2 record path artifacts=no
    record=$(legacy_komari_latency_record "${state}")
    for path in \
        "${record}" \
        "${LEGACY_KOMARI_LATENCY_CONFIG}" \
        "${LEGACY_KOMARI_LATENCY_FIREWALL}" \
        "${LEGACY_KOMARI_LATENCY_SERVICE}"; do
        if [[ -e ${path} || -L ${path} ]]; then
            artifacts=yes
            break
        fi
    done
    [[ ${artifacts} == yes ]] || return 0
    legacy_komari_latency_owned "${state}" "${unit}" \
        || { echo '旧版 Komari 延迟转发文件不完整或已被外部修改，拒绝自动删除。' >&2; return 1; }
    systemctl disable --now "${LEGACY_KOMARI_LATENCY_UNIT}" >/dev/null \
        || { echo '旧版 Komari 延迟转发服务停止失败；防火墙脚本与配置均已保留。' >&2; return 1; }
    "${LEGACY_KOMARI_LATENCY_FIREWALL}" delete \
        || { echo '旧版 Komari 延迟转发防火墙规则撤销失败；恢复脚本与配置均已保留。' >&2; return 1; }
    rm -f -- \
        "${LEGACY_KOMARI_LATENCY_SERVICE}" \
        "${LEGACY_KOMARI_LATENCY_FIREWALL}" \
        "${LEGACY_KOMARI_LATENCY_CONFIG}" \
        "${record}" \
        || { echo '旧版 Komari 延迟转发规则已撤销，但部分文件未能删除。' >&2; return 1; }
    for path in \
        "${LEGACY_KOMARI_LATENCY_SERVICE}" \
        "${LEGACY_KOMARI_LATENCY_FIREWALL}" \
        "${LEGACY_KOMARI_LATENCY_CONFIG}" \
        "${record}"; do
        [[ ! -e ${path} && ! -L ${path} ]] \
            || { echo "旧版 Komari 延迟转发文件仍有残留：${path}" >&2; return 1; }
    done
    systemctl daemon-reload \
        || { echo '旧版 Komari 延迟转发文件已删除，但 systemd 重新载入失败。' >&2; return 1; }
    echo '已移除旧版 Komari TCP 延迟转发；请在 Komari 面板使用 ICMP 延迟任务。'
}
