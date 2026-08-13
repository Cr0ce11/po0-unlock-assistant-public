
verify_proxy() {
    local http_pid socks_pid http_rc=0 socks_rc=0
    require_root
    active_state >/dev/null
    curl -4 --proxy "${HTTP_PROXY_URL}" -fsS --connect-timeout 8 --max-time 20 \
        -o /dev/null https://deb.debian.org/debian/ &
    http_pid=$!
    curl -4 --proxy "${SOCKS_PROXY_URL}" -fsS --connect-timeout 8 --max-time 20 \
        -o /dev/null https://deb.debian.org/debian/ &
    socks_pid=$!
    wait "${http_pid}" || http_rc=$?
    wait "${socks_pid}" || socks_rc=$?
    (( http_rc == 0 )) || die '国外出口 HTTP 出口验证失败。'
    (( socks_rc == 0 )) || die '国外出口 SOCKS5 出口验证失败。'
}

finalize() {
    local cn_entry_private_ip=${1:-} exit_private_ip=${2:-} state
    require_root
    state=$(active_state)
    [[ ! -e ${state}/closing && ! -L ${state}/closing ]] \
        || die '安装状态正在回滚，拒绝更新代理配置。'
    verify_proxy
    write_proxy_files "${state}" "${cn_entry_private_ip}" "${exit_private_ip}"
    date -u +%Y-%m-%dT%H:%M:%SZ >"${state}/finalized-at"
    log '代理已启用。重新登录 SSH 后，curl/wget/Git 将自动使用国外出口；APT 立即生效。'
}

refresh() {
    local cn_entry_private_ip=${1:-} exit_private_ip=${2:-}
    local state unit failures=0
    require_root
    state=$(active_state)
    [[ ! -e ${state}/closing && ! -L ${state}/closing ]] \
        || die '安装状态正在回滚，拒绝更新代理配置。'
    verify_proxy
    valid_ipv4 "${cn_entry_private_ip}" || die '国内入口连接 IPv4 地址格式无效。'
    valid_ipv4 "${exit_private_ip}" || die '国外出口源 IPv4 地址格式无效。'
    harden_tunnel_authorized_keys
    write_proxy_files "${state}" "${cn_entry_private_ip}" "${exit_private_ip}"
    date -u +%Y-%m-%dT%H:%M:%SZ >"${state}/refresh-attempted-at"
    if [[ -f ${state}/managed-services ]]; then
        while IFS= read -r unit; do
            [[ -n ${unit} ]] || continue
            if ! valid_service_unit "${unit}"; then
                printf '[国内入口] 错误：托管清单中存在无效服务名，已跳过。\n' >&2
                failures=$((failures + 1))
                continue
            fi
            if ! "${HELPER}" refresh-service "${unit}"; then
                printf '[国内入口] 错误：%s 的代理配置更新失败。\n' "${unit}" >&2
                failures=$((failures + 1))
            fi
        done <"${state}/managed-services"
    fi
    (( failures == 0 )) \
        || die "核心代理地址已更新，但有 ${failures} 个托管 Agent 未能安全更新；其旧配置已保留。"
    date -u +%Y-%m-%dT%H:%M:%SZ >"${state}/refreshed-at"
    log '国内入口代理环境和已托管 Agent 的直连例外地址已更新。'
}

refresh_helper_from_state() (
    local state cn_entry_private_ip exit_private_ip no_proxy
    state=$(active_state)
    command -v flock >/dev/null || die '系统缺少 flock，无法安全更新服务代理助手。'
    exec 9>"${state}/service-proxy.lock"
    flock -x 9
    confirm_state_open "${state}" || die '安装状态正在关闭或已经变化，拒绝更新服务代理助手。'
    [[ -r ${state}/cn-entry-private-ip && -r ${state}/overseas-exit-private-ip ]] \
        || die '状态目录缺少两端连接地址，无法更新服务代理助手。'
    cn_entry_private_ip=$(<"${state}/cn-entry-private-ip")
    exit_private_ip=$(<"${state}/overseas-exit-private-ip")
    valid_ipv4 "${cn_entry_private_ip}" || die '状态中的国内入口连接地址无效。'
    valid_ipv4 "${exit_private_ip}" || die '状态中的国外出口源地址无效。'
    no_proxy="localhost,127.0.0.1,::1,${cn_entry_private_ip},${exit_private_ip}"
    write_helper "${no_proxy}"
)

refresh_one_managed_service() {
    local unit=${1:-}
    require_root
    valid_service_unit "${unit}" || die '缺少有效的托管服务名。'
    refresh_helper_from_state
    "${HELPER}" refresh-service "${unit}"
}
