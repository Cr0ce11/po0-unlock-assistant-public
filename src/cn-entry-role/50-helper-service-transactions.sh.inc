
report_ipv4_from_dropin() {
    local file=$1 line ip
    [[ -f ${file} ]] || return 1
    line=$(grep -m 1 -E '^Environment="AGENT_CUSTOM_IPV4=[0-9.]+"$' "${file}" 2>/dev/null || true)
    [[ -n ${line} ]] || return 1
    ip=${line#*AGENT_CUSTOM_IPV4=}
    ip=${ip%\"}
    valid_helper_ipv4 "${ip}" || return 1
    printf '%s\n' "${ip}"
}

is_forwardx_service() {
    local unit=$1 metadata text
    metadata=$(systemctl show -p Description -p FragmentPath -p ExecStart --value -- "${unit}" 2>/dev/null \
        | tr '\n' ' ')
    text=$(printf '%s %s' "${unit}" "${metadata}" | tr '[:upper:]' '[:lower:]')
    [[ ${text} == *forwardx* ]]
}

write_service_proxy_dropin() {
    local unit=$1 output=$2
    if is_forwardx_service "${unit}"; then
        cat >"${output}" <<DROPIN
${MANAGED_MARKER}
[Service]
Environment="HTTP_PROXY=${HTTP_PROXY_URL}"
Environment="HTTPS_PROXY=${HTTP_PROXY_URL}"
Environment="http_proxy=${HTTP_PROXY_URL}"
Environment="https_proxy=${HTTP_PROXY_URL}"
Environment="NO_PROXY=__NO_PROXY__"
Environment="no_proxy=__NO_PROXY__"
DROPIN
        return
    fi
    cat >"${output}" <<DROPIN
${MANAGED_MARKER}
[Service]
Environment="HTTP_PROXY=${HTTP_PROXY_URL}"
Environment="HTTPS_PROXY=${HTTP_PROXY_URL}"
Environment="http_proxy=${HTTP_PROXY_URL}"
Environment="https_proxy=${HTTP_PROXY_URL}"
Environment="ALL_PROXY=${SOCKS_PROXY_URL}"
Environment="all_proxy=${SOCKS_PROXY_URL}"
Environment="NO_PROXY=__NO_PROXY__"
Environment="no_proxy=__NO_PROXY__"
DROPIN
}

helper_active_state() {
    local state
    # 与 active_state 保持同一套校验：属主、权限、链接数与状态根的直接子目录。
    [[ -f /var/lib/po0-unlock/ACTIVE && ! -L /var/lib/po0-unlock/ACTIVE \
        && $(stat -c '%u' /var/lib/po0-unlock/ACTIVE 2>/dev/null) == 0 \
        && $(stat -c '%a' /var/lib/po0-unlock/ACTIVE 2>/dev/null) == 600 \
        && $(stat -c '%h' /var/lib/po0-unlock/ACTIVE 2>/dev/null) == 1 ]] \
        || { echo '没有找到有效安装状态。' >&2; return 1; }
    state=$(</var/lib/po0-unlock/ACTIVE)
    case "${state}" in
        /var/lib/po0-unlock/*) ;;
        *) echo '安装状态路径无效。' >&2; return 1 ;;
    esac
    [[ ${state%/*} == /var/lib/po0-unlock ]] \
        || { echo '安装状态路径无效。' >&2; return 1; }
    [[ -d ${state} && ! -L ${state} \
        && $(stat -c '%u' "${state}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${state}" 2>/dev/null) == 700 ]] \
        || { echo '安装状态目录异常。' >&2; return 1; }
    printf '%s\n' "${state}"
}

protected_service() {
    local unit=$1 metadata text
    case "${unit,,}" in
        po0-unlock-*|ssh*.service|systemd-*|dbus.service|polkit.service|cron.service|rsyslog.service|\
        networking.service|network-manager.service|networkmanager.service|networkd-dispatcher.service|\
        dhcpcd*.service|dhclient*.service|wicked*.service|connman*.service|ifup@*|ifdown@*|\
        nftables.service|iptables.service|\
        firewalld.service|ufw.service|fail2ban.service|docker.service|containerd.service|podman.service|\
        qemu-guest-agent.service|*guest-agent*.service|google-*agent*.service|amazon-*agent*.service|waagent.service|\
        cloud-init*.service|aliyun*.service|aegis*.service|tencent*.service|salt-minion.service|puppet.service|chef-client.service|\
        tailscaled.service|zerotier*.service|openvpn*.service|wg-quick@*.service|cloudflared.service|\
        sing-box*.service|singbox*.service|xray*.service|v2ray*.service|realm*.service|gost*.service|socat*.service|\
        nfuse*.service|frp*.service|rathole*.service|brook*.service|chisel*.service|\
        nginx.service|caddy.service|haproxy.service|tinyproxy.service)
            return 0
            ;;
    esac
    metadata=$(systemctl show -p Description -p FragmentPath -p ExecStart --value -- "${unit}" 2>/dev/null | tr '\n' ' ')
    text="${unit,,} ${metadata,,}"
    case "${text}" in
        *po0-unlock*|*nfuse*|*socat*|*sing-box*|*singbox*|*xray*|*v2ray*|*realm*|*gost*|\
        *autossh*|*sshd*|*tinyproxy*|*cloudflared*|*tailscale*|*zerotier*|*openvpn*|*wireguard*|*wg-quick*|\
        *qemu-guest*|*spice-vdagent*|*vmtoolsd*|*waagent*|*cloud-init*|*google-guest*|*amazon-ssm*|*oracle-cloud-agent*|\
        *aliyun*|*aegis*|*tencent*|*networkmanager*|*networkd-dispatcher*|*systemd-networkd*|*systemd-resolved*|\
        *dhcpcd*|*dhclient*|*wicked*|*connman*|\
        *nftables*|*iptables*|*firewalld*|*fail2ban*|*docker*|*containerd*|*podman*|\
        *nginx*|*caddy*|*haproxy*|*frpc*|*frps*|*rathole*|*brook*|*chisel*) return 0 ;;
    esac
    return 1
}

service_owns_proxy_listener() {
    local unit=$1 listeners main_pid cgroup pid
    listeners=$(ss -H -lntp 2>/dev/null \
        | awk '$4 ~ /127\.0\.0\.1:(13128|19080)$/ {print}')
    [[ -n ${listeners} ]] || return 1
    main_pid=$(systemctl show -p MainPID --value -- "${unit}" 2>/dev/null || true)
    if [[ ${main_pid} =~ ^[0-9]+$ ]] && (( main_pid > 0 )) \
        && [[ ${listeners} == *"pid=${main_pid},"* ]]; then
        return 0
    fi
    cgroup=$(systemctl show -p ControlGroup --value -- "${unit}" 2>/dev/null || true)
    if [[ ${cgroup} == /* && ${cgroup} != *..* && -r /sys/fs/cgroup${cgroup}/cgroup.procs ]]; then
        while IFS= read -r pid; do
            [[ ${pid} =~ ^[0-9]+$ ]] || continue
            [[ ${listeners} == *"pid=${pid},"* ]] && return 0
        done <"/sys/fs/cgroup${cgroup}/cgroup.procs"
    fi
    return 1
}

has_proxy_environment() {
    local unit=$1 environment unit_definition
    environment=$(systemctl show -p Environment --value -- "${unit}" 2>/dev/null || true)
    if [[ ${environment,,} =~ (^|[^[:alnum:]_])(http_proxy|https_proxy|all_proxy|no_proxy)= ]]; then
        return 0
    fi
    unit_definition=$(systemctl cat -- "${unit}" 2>/dev/null || true)
    grep -Eiq '(^|[^[:alnum:]_])(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY)[[:space:]]*=' \
        <<<"${unit_definition}"
}

validate_service_target() {
    local unit=$1 load active sub type refuse fragment
    valid_helper_service_unit "${unit}" \
        || { echo '服务名必须是合法的 .service 单元名。' >&2; return 1; }
    systemctl cat -- "${unit}" >/dev/null || return 1
    protected_service "${unit}" \
        && { echo "拒绝为关键系统、网络或中转服务 ${unit} 添加代理。" >&2; return 1; }
    service_owns_proxy_listener "${unit}" \
        && { echo "拒绝为代理链监听进程 ${unit} 添加代理。" >&2; return 1; }
    load=$(systemctl show -p LoadState --value -- "${unit}")
    active=$(systemctl show -p ActiveState --value -- "${unit}")
    sub=$(systemctl show -p SubState --value -- "${unit}")
    type=$(systemctl show -p Type --value -- "${unit}")
    refuse=$(systemctl show -p RefuseManualStop --value -- "${unit}")
    fragment=$(systemctl show -p FragmentPath --value -- "${unit}")
    [[ ${load} == loaded && ${active} == active && ${sub} == running ]] \
        || { echo '只允许配置当前 active/running 的常驻服务。' >&2; return 1; }
    [[ ${type} != oneshot && ${refuse} != yes && ${fragment} != /run/systemd/transient/* ]] \
        || { echo '拒绝配置 oneshot、临时或禁止手动停止的服务。' >&2; return 1; }
    if has_proxy_environment "${unit}"; then
        echo '该服务已经存在代理环境，为避免覆盖而拒绝自动配置。' >&2
        return 1
    fi
}

service_is_running() {
    local unit=$1 active sub
    active=$(systemctl show -p ActiveState --value -- "${unit}" 2>/dev/null || true)
    sub=$(systemctl show -p SubState --value -- "${unit}" 2>/dev/null || true)
    [[ ${active} == active && ${sub} == running ]]
}

restart_and_verify_running() {
    local unit=$1
    systemctl restart -- "${unit}" && sleep 2 && service_is_running "${unit}"
}

managed_dropin_owned() {
    local file=$1 first_line=
    [[ -f ${file} ]] || return 1
    IFS= read -r first_line <"${file}" || true
    [[ ${first_line} == "${MANAGED_MARKER}" ]]
}

acquire_service_lock() {
    local state=$1
    acquire_state_mutation_lock "${state}" '服务配置操作'
}

confirm_helper_state_open() {
    local expected_state=$1 current_state=
    [[ -r /var/lib/po0-unlock/ACTIVE ]] || return 1
    current_state=$(</var/lib/po0-unlock/ACTIVE)
    [[ ${current_state} == "${expected_state}" \
        && -d ${expected_state} && ! -L ${expected_state} \
        && ! -e ${expected_state}/closing && ! -L ${expected_state}/closing ]]
}

remove_managed_unit() {
    local state=$1 unit=$2 list_tmp
    list_tmp=$(mktemp "${state}/.managed-services.cleanup.XXXXXX") || return 1
    if [[ -f ${state}/managed-services ]]; then
        grep -Fvx -- "${unit}" "${state}/managed-services" >"${list_tmp}" || true
    else
        printf '' >"${list_tmp}"
    fi
    chmod 0600 "${list_tmp}"
    mv "${list_tmp}" "${state}/managed-services"
}

ensure_managed_unit() {
    local state=$1 unit=$2 list_tmp
    list_tmp=$(mktemp "${state}/.managed-services.cleanup.XXXXXX") || return 1
    { sed -n '1,$p' "${state}/managed-services" 2>/dev/null || true; printf '%s\n' "${unit}"; } \
        | awk 'NF && !seen[$0]++' >"${list_tmp}"
    chmod 0600 "${list_tmp}"
    mv "${list_tmp}" "${state}/managed-services"
}

enable_transaction_cleanup() {
    local rc=${1:-1} reload_ok=no
    trap - EXIT INT TERM HUP
    set +e
    rm -f "${TX_DROPIN_TMP:-}" "${TX_MANAGED_TMP:-}"
    if [[ ${TX_COMMITTED:-no} != yes ]]; then
        if [[ ${TX_CF_GUARD_CREATED:-no} == yes \
            && -n ${TX_COMPAT_DIR:-} ]]; then
            remove_cf_probe_go_guard_units "${TX_UNIT}" "${TX_COMPAT_DIR}" \
                || echo '警告：未能清理 cf-probe 动态配置守卫，请人工检查。' >&2
        fi
        if [[ ${TX_KOMARI_IDENTITY_CREATED:-no} == yes \
            && -n ${TX_KOMARI_IDENTITY_DIR:-} ]]; then
            remove_komari_identity_guard "${TX_KOMARI_IDENTITY_DIR}" "${TX_UNIT}" \
                || echo '警告：未能清理 Komari 身份守卫，请人工检查。' >&2
        fi
        # cf-probe 的测速目标改写与兼容文件创建都发生在 drop-in 落盘之前，
        # 补偿不能挂在 TX_DROPIN_MAY_EXIST 上：该标志置位前失败会整块跳过，
        # 留下已被改写却未进托管清单的目标和 go-pending 残留。与刷新事务的写法保持一致。
        if [[ -n ${TX_COMPAT_DIR:-} \
            && ( -e ${TX_COMPAT_DIR}/go-pending || -L ${TX_COMPAT_DIR}/go-pending ) ]]; then
            rollback_cf_probe_go_latency_compat "${TX_COMPAT_DIR}" \
                || echo '警告：未能恢复 cf-probe 本轮测速目标，请人工检查。' >&2
        fi
        if [[ ${TX_COMPAT_CREATED:-no} == yes && -n ${TX_COMPAT_DIR:-} ]]; then
            if ! rmdir "${TX_COMPAT_DIR}" 2>/dev/null; then
                remove_cf_probe_latency_compat "${TX_COMPAT_DIR}" \
                    || echo '警告：未能清理 cf-probe 兼容文件，请人工检查。' >&2
            fi
        elif [[ ${TX_COMPAT_CURL_CREATED:-no} == yes && -n ${TX_COMPAT_DIR:-} ]]; then
            remove_cf_probe_direct_report_compat "${TX_COMPAT_DIR}" \
                || echo '警告：未能清理 cf-probe 真实地区上报兼容文件，请人工检查。' >&2
        fi
        if [[ ${TX_DROPIN_MAY_EXIST:-no} == yes ]]; then
            rm -f "${TX_DROPIN_FILE}"
            rmdir "${TX_DROPIN_DIR}" 2>/dev/null || true
            if systemctl daemon-reload; then reload_ok=yes; fi
            if [[ ${TX_ORIGINAL_RUNNING:-no} == yes ]]; then
                if [[ ${reload_ok} == yes ]] && restart_and_verify_running "${TX_UNIT}"; then
                    echo "已撤销本次配置并恢复 ${TX_UNIT} 为 active/running。" >&2
                else
                    echo "严重警告：已撤销代理文件，但 ${TX_UNIT} 未恢复为 active/running，请立即检查。" >&2
                fi
            fi
        fi
        if [[ ${TX_LIST_MAY_CHANGE:-no} == yes ]]; then
            remove_managed_unit "${TX_STATE}" "${TX_UNIT}" \
                || echo '警告：清理托管清单失败，请人工检查。' >&2
        fi
    fi
    exit "${rc}"
}

disable_transaction_cleanup() {
    local rc=${1:-1} restored=no reload_ok=no
    trap - EXIT INT TERM HUP
    set +e
    rm -f "${TX_MANAGED_TMP:-}"
    if [[ ${TX_COMMITTED:-no} != yes ]]; then
        if [[ ${TX_DROPIN_MAY_BE_REMOVED:-no} == yes ]]; then
            if [[ ${TX_CF_GO_TARGETS_RESTORED:-no} == yes \
                && -n ${TX_COMPAT_DIR:-} ]]; then
                restore_cf_probe_go_managed_targets "${TX_COMPAT_DIR}" \
                    || echo '严重警告：无法重新应用 cf-probe 安全测速目标，请立即检查。' >&2
            fi
            if [[ ${TX_DROPIN_WAS_MISSING:-no} == yes ]]; then
                # 代理文件在事务开始前就已经不存在，回滚不需要也不应该重建它。
                echo "${TX_UNIT} 的代理配置原本就不存在，回滚未重建任何文件。" >&2
            else
                install -d -m 0755 "${TX_DROPIN_DIR}"
                if [[ -f ${TX_BACKUP:-} ]] && mv "${TX_BACKUP}" "${TX_DROPIN_FILE}"; then
                    restored=yes
                else
                    echo "严重警告：无法恢复 ${TX_DROPIN_FILE}；备份保留在 ${TX_BACKUP:-未知位置}。" >&2
                fi
                if [[ ${restored} == yes ]] && systemctl daemon-reload; then reload_ok=yes; fi
                if [[ ${TX_ORIGINAL_RUNNING:-no} == yes ]]; then
                    if [[ ${reload_ok} == yes ]] && restart_and_verify_running "${TX_UNIT}"; then
                        echo "已恢复 ${TX_UNIT} 的代理配置和 active/running 状态。" >&2
                    else
                        echo "严重警告：${TX_UNIT} 的代理配置已尝试恢复，但服务未恢复为 active/running。" >&2
                    fi
                elif [[ ${restored} == yes ]]; then
                    echo "已恢复 ${TX_UNIT} 的代理配置，并保持原停止状态。" >&2
                fi
            fi
        fi
        if [[ ${TX_CF_GUARD_REMOVED:-no} == yes \
            && -n ${TX_COMPAT_DIR:-} ]]; then
            prepare_cf_probe_go_guard_units "${TX_UNIT}" "${TX_COMPAT_DIR}" >/dev/null \
                || echo '严重警告：无法恢复 cf-probe 动态配置守卫，请立即检查。' >&2
        fi
        if [[ ${TX_LIST_MAY_CHANGE:-no} == yes ]]; then
            ensure_managed_unit "${TX_STATE}" "${TX_UNIT}" \
                || echo '警告：恢复托管清单失败，请人工检查。' >&2
        fi
    fi
    if [[ ${TX_COMMITTED:-no} == yes || ${TX_DROPIN_MAY_BE_REMOVED:-no} != yes ]]; then
        rm -f "${TX_BACKUP:-}"
    fi
    exit "${rc}"
}

refresh_transaction_cleanup() {
    local rc=${1:-1} restored=no reload_ok=no
    trap - EXIT INT TERM HUP
    set +e
    rm -f "${TX_DROPIN_TMP:-}"
    if [[ ${TX_COMMITTED:-no} != yes && ${TX_CF_GUARD_CREATED:-no} == yes \
        && -n ${TX_COMPAT_DIR:-} ]]; then
        remove_cf_probe_go_guard_units "${TX_UNIT}" "${TX_COMPAT_DIR}" \
            || echo '警告：未能清理 cf-probe 动态配置守卫，请人工检查。' >&2
    fi
    if [[ ${TX_COMMITTED:-no} != yes && ${TX_KOMARI_IDENTITY_CREATED:-no} == yes \
        && -n ${TX_KOMARI_IDENTITY_DIR:-} ]]; then
        remove_komari_identity_guard "${TX_KOMARI_IDENTITY_DIR}" "${TX_UNIT}" \
            || echo '警告：未能清理 Komari 身份守卫，请人工检查。' >&2
    fi
    if [[ ${TX_COMMITTED:-no} != yes && -n ${TX_COMPAT_DIR:-} \
        && ( -e ${TX_COMPAT_DIR}/go-pending || -L ${TX_COMPAT_DIR}/go-pending ) ]]; then
        rollback_cf_probe_go_latency_compat "${TX_COMPAT_DIR}" \
            || echo '警告：未能恢复 cf-probe 本轮测速目标，请人工检查。' >&2
    fi
    if [[ ${TX_COMMITTED:-no} != yes && ${TX_COMPAT_CREATED:-no} == yes \
        && -n ${TX_COMPAT_DIR:-} ]]; then
        if ! rmdir "${TX_COMPAT_DIR}" 2>/dev/null; then
            remove_cf_probe_latency_compat "${TX_COMPAT_DIR}" \
                || echo '警告：未能清理 cf-probe 兼容文件，请人工检查。' >&2
        fi
        rmdir "${TX_DROPIN_DIR:-}" 2>/dev/null || true
    elif [[ ${TX_COMMITTED:-no} != yes && ${TX_COMPAT_CURL_CREATED:-no} == yes \
        && -n ${TX_COMPAT_DIR:-} ]]; then
        remove_cf_probe_direct_report_compat "${TX_COMPAT_DIR}" \
            || echo '警告：未能清理 cf-probe 真实地区上报兼容文件，请人工检查。' >&2
    fi
    if [[ ${TX_COMMITTED:-no} != yes && ${TX_DROPIN_MAY_CHANGE:-no} == yes ]]; then
        install -d -m 0755 "${TX_DROPIN_DIR}"
        if [[ -f ${TX_BACKUP:-} ]] && mv "${TX_BACKUP}" "${TX_DROPIN_FILE}"; then
            restored=yes
        else
            echo "严重警告：无法恢复 ${TX_DROPIN_FILE}；备份保留在 ${TX_BACKUP:-未知位置}。" >&2
        fi
        if [[ ${restored} == yes ]] && systemctl daemon-reload; then reload_ok=yes; fi
        if [[ ${TX_ORIGINAL_RUNNING:-no} == yes ]]; then
            if [[ ${reload_ok} == yes ]] && restart_and_verify_running "${TX_UNIT}"; then
                echo "已恢复 ${TX_UNIT} 更新前的代理配置和 active/running 状态。" >&2
            else
                echo "严重警告：${TX_UNIT} 未恢复为 active/running，请立即检查。" >&2
            fi
        elif [[ ${restored} == yes ]]; then
            echo "已恢复 ${TX_UNIT} 更新前的代理配置，并保持原停止状态。" >&2
        fi
    fi
    if [[ ${TX_COMMITTED:-no} == yes || ${TX_DROPIN_MAY_CHANGE:-no} != yes ]]; then
        rm -f "${TX_BACKUP:-}"
    fi
    exit "${rc}"
}
