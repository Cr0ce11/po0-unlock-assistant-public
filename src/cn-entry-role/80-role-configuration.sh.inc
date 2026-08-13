    sed -i "s|__NO_PROXY__|${no_proxy}|g" "${tmp}"
    install -o root -g root -m 0755 "${tmp}" "${HELPER}"
    rm -f "${tmp}"
}

write_proxy_files() (
    local state=$1 cn_entry_private_ip=$2 exit_private_ip=$3
    local no_proxy config_tmp= profile_tmp=
    valid_ipv4 "${cn_entry_private_ip}" || die '国内入口连接 IPv4 地址格式无效。'
    valid_ipv4 "${exit_private_ip}" || die '国外出口源 IPv4 地址格式无效。'
    command -v flock >/dev/null || die '系统缺少 flock，无法安全写入代理配置。'
    exec 9>"${state}/service-proxy.lock"
    flock -x 9
    confirm_state_open "${state}" || die '安装状态正在关闭或已经变化，拒绝写入代理配置。'

    cleanup_proxy_candidates() {
        local rc=$?
        trap - EXIT INT TERM HUP
        set +e
        [[ -n ${config_tmp} ]] && rm -f -- "${config_tmp}"
        [[ -n ${profile_tmp} ]] && rm -f -- "${profile_tmp}"
        exit "${rc}"
    }
    trap cleanup_proxy_candidates EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    no_proxy="localhost,127.0.0.1,::1,${cn_entry_private_ip},${exit_private_ip}"
    config_tmp=$(mktemp /tmp/po0-cn-entry-apt.XXXXXX)
    profile_tmp=$(mktemp /tmp/po0-cn-entry-profile.XXXXXX)
    cat >"${config_tmp}" <<EOF
Acquire::http::Proxy "${HTTP_PROXY_URL}";
Acquire::https::Proxy "${HTTP_PROXY_URL}";
EOF
    cat >"${profile_tmp}" <<EOF
# 国内入口管理出站：国外出口反向 SSH 代理
export HTTP_PROXY='${HTTP_PROXY_URL}'
export HTTPS_PROXY='${HTTP_PROXY_URL}'
export http_proxy='${HTTP_PROXY_URL}'
export https_proxy='${HTTP_PROXY_URL}'
export ALL_PROXY='${SOCKS_PROXY_URL}'
export all_proxy='${SOCKS_PROXY_URL}'
export NO_PROXY='${no_proxy}'
export no_proxy="\${NO_PROXY}"
EOF
    install -o root -g root -m 0644 "${config_tmp}" "${APT_CONF}"
    install -o root -g root -m 0644 "${profile_tmp}" "${PROFILE_CONF}"
    write_helper "${no_proxy}"
    printf '%s\n' "${cn_entry_private_ip}" >"${state}/cn-entry-private-ip"
    printf '%s\n' "${exit_private_ip}" >"${state}/overseas-exit-private-ip"
    rm -f "${config_tmp}" "${profile_tmp}"
    config_tmp=
    profile_tmp=
    trap - EXIT INT TERM HUP
)
