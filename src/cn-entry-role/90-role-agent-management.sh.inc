
service_is_excluded() {
    local unit=${1,,} description=${2,,} fragment=${3,,} exec_name=${4,,} text
    case "${unit}" in
        po0-unlock-*|po0-komari-latency.service|ssh*.service|systemd-*|dbus.service|polkit.service|cron.service|rsyslog.service|\
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
    text="${description} ${fragment} ${exec_name}"
    case "${text}" in
        *po0-unlock*|*nfuse*|*sing-box*|*singbox*|*xray*|*v2ray*|*realm*|*gost*|*socat*|\
        *autossh*|*tinyproxy*|*cloudflared*|*tailscale*|*zerotier*|*openvpn*|*wireguard*|*wg-quick*|\
        *qemu-guest*|*spice-vdagent*|*vmtoolsd*|*waagent*|*cloud-init*|*google-guest*|*amazon-ssm*|*oracle-cloud-agent*|\
        *aliyun*|*aegis*|*tencent*|*networkmanager*|*networkd-dispatcher*|*systemd-networkd*|*systemd-resolved*|\
        *dhcpcd*|*dhclient*|*wicked*|*connman*|*nftables*|*iptables*|*firewalld*|*fail2ban*|\
        *docker*|*containerd*|*podman*|*nginx*|*caddy*|*haproxy*|*frpc*|*frps*|*rathole*|*chisel*)
            return 0
            ;;
    esac
    return 1
}

candidate_reason() {
    local unit=${1,,} description=${2,,} fragment=${3,,} exec_name=${4,,} text unit_stem
    text="${unit} ${description} ${fragment} ${exec_name}"
    case "${text}" in
        *cf-probe*|*cf\ server\ monitor\ probe*) printf '%s\n' '识别为 CF Probe 监控 Agent'; return 0 ;;
        *forwardx*) printf '%s\n' '识别为 ForwardX 转发面板 Agent（是否代理由你确认）'; return 0 ;;
        *flux_agent*|*flux-agent*) printf '%s\n' '识别为 Flux 转发面板 Agent（是否代理由你确认）'; return 0 ;;
        *nyanpass*) printf '%s\n' '识别为 NyanPass 转发面板 Agent（是否代理由你确认）'; return 0 ;;
        *komari*) printf '%s\n' '识别为 Komari Agent'; return 0 ;;
        *beszel*) printf '%s\n' '识别为 Beszel Agent'; return 0 ;;
        *serverstatus*|*server-status*|*server_status*) printf '%s\n' '识别为 ServerStatus Agent'; return 0 ;;
        *nodequery*) printf '%s\n' '识别为 NodeQuery Agent'; return 0 ;;
        *netdata*) printf '%s\n' '识别为 Netdata 服务'; return 0 ;;
        *zabbix*agent*) printf '%s\n' '识别为 Zabbix Agent'; return 0 ;;
        *wazuh*agent*) printf '%s\n' '识别为 Wazuh Agent'; return 0 ;;
        *proxy\ service*|*forwarding\ service*|*tunnel\ service*)
            printf '%s\n' '识别为疑似转发面板 Agent（是否代理由你确认）'
            return 0
            ;;
    esac
    unit_stem=${unit%.service}
    if [[ ${unit_stem} =~ (^|[-_.@])(agent|collector|monitor|probe)([-_.@]|$) ]]; then
        printf '%s\n' '服务名包含独立的 Agent/Collector/Monitor/Probe 词段'
        return 0
    fi
    return 1
}

systemctl_scan() {
    if [[ $(type -t systemctl 2>/dev/null || true) == function ]]; then
        systemctl "$@"
        return
    fi
    timeout --kill-after=2s 5s systemctl "$@"
}

unit_has_proxy_environment() {
    local unit=$1 environment unit_definition rc
    if ! environment=$(systemctl_scan show -p Environment --value -- "${unit}" 2>/dev/null); then
        rc=$?
        case "${rc}" in 124|126|127|137) return 0 ;; *) environment= ;; esac
    fi
    if [[ ${environment,,} =~ (^|[^[:alnum:]_])(http_proxy|https_proxy|all_proxy|no_proxy)= ]]; then
        return 0
    fi
    if ! unit_definition=$(systemctl_scan cat -- "${unit}" 2>/dev/null); then
        rc=$?
        case "${rc}" in 124|126|127|137) return 0 ;; *) unit_definition= ;; esac
    fi
    grep -Eiq '(^|[^[:alnum:]_])(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY)[[:space:]]*=' \
        <<<"${unit_definition}"
}

sanitize_display_text() {
    LC_ALL=C tr -d '\000-\010\013\014\016-\037\177'
}

report_ipv4_for_service() {
    local unit=$1 file line ip
    file=/etc/systemd/system/${unit}.d/90-po0-unlock-proxy.conf
    [[ -f ${file} ]] || return 1
    line=$(grep -m 1 -E '^Environment="AGENT_CUSTOM_IPV4=[0-9.]+"$' "${file}" 2>/dev/null || true)
    [[ -n ${line} ]] || return 1
    ip=${line#*AGENT_CUSTOM_IPV4=}
    ip=${ip%\"}
    valid_ipv4 "${ip}" || return 1
    printf '%s\n' "${ip}"
}

verify_agent_proxy_change() {
    local started=${SECONDS}
    printf '\n%s\n' '正在并行验证 HTTP 与 SOCKS5 国外出口（最长约 20 秒）……'
    verify_proxy
    printf '国外出口验证完成（耗时 %d 秒）。\n' "$((SECONDS - started))"
}

manage_komari_report_ipv4() {
    local unit=$1 state=$2 current_ip choice requested_ip answer
    current_ip=$(report_ipv4_for_service "${unit}" || true)
    printf '\n%s\n' '----------- Komari 面板展示 IP -----------'
    if [[ -n ${current_ip} ]]; then
        printf '当前：固定显示 %s\n' "${current_ip}"
    else
        printf '%s\n' '当前：自动检测（因为 Agent 经国外出口联网，通常显示国外出口 IP）'
    fi
    printf '%s\n' '1) 设置或更新 国内入口公网 IPv4'
    printf '%s\n' '2) 恢复自动检测（通常显示国外出口 IP）'
    printf '%s\n' '0) 暂不修改'
    read -r -p '请选择 [0-2]：' choice
    case "${choice}" in
        0|'') printf '%s\n' '面板展示 IP 未修改。'; return 0 ;;
        1)
            while :; do
                requested_ip=
                if [[ -n ${current_ip} ]]; then
                    read -r -p "国内入口公网 IPv4 [${current_ip}]：" requested_ip
                    requested_ip=${requested_ip:-${current_ip}}
                else
                    read -r -p '请输入 国内入口公网 IPv4（不能填写私网地址）：' requested_ip
                fi
                if public_ipv4 "${requested_ip}"; then
                    break
                fi
                printf '%s\n' '输入无效：这里必须填写国内入口的公网 IPv4，请重新输入。' >&2
            done
            printf 'Komari 控制连接仍走国外出口；面板节点 IPv4 将显示为 %s。\n' "${requested_ip}"
            read -r -p '确认应用并重启 Komari？[y/N]：' answer
            case "${answer}" in y|Y|yes|YES|是) ;; *) printf '%s\n' '未做修改。'; return 0 ;; esac
            refresh_helper_from_state
            "${HELPER}" set-report-ip "${unit}" "${requested_ip}"
            printf '%s\tSET_REPORT_IPV4\t%s\t%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${unit}" "${requested_ip}" \
                >>"${state}/service-proxy-actions.log"
            ;;
        2)
            if [[ -z ${current_ip} ]]; then
                printf '%s\n' '当前已经是自动检测，无需修改。'
                return 0
            fi
            printf '%s\n' '恢复后，因 Komari 经国外出口联网，面板通常会再次显示国外出口 IP。'
            read -r -p '确认恢复自动检测并重启 Komari？[y/N]：' answer
            case "${answer}" in y|Y|yes|YES|是) ;; *) printf '%s\n' '未做修改。'; return 0 ;; esac
            refresh_helper_from_state
            "${HELPER}" clear-report-ip "${unit}"
            printf '%s\tCLEAR_REPORT_IPV4\t%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${unit}" \
                >>"${state}/service-proxy-actions.log"
            ;;
        # 这里只是展示 IP 的装饰性菜单，此时代理已启用、单元已进托管清单。
        # 用 die 会结束整个组件进程，让出口侧把「已经成功的配置」报成扫描失败。
        *) printf '%s\n' '选择无效，未做修改。' >&2; return 1 ;;
    esac
}

manage_configured_service() {
    local unit=$1 reason=$2 state=$3 choice answer action
    printf '\n%s\n' '该服务已由 Po0 配置，请选择：'
    printf '%s\n' '1) 检查并更新配置'
    printf '%s\n' '2) 撤销国外出口配置'
    printf '%s\n' '0) 返回'
    read -r -p '请选择 [0-2]：' choice
    case "${choice}" in
        0|'') printf '%s\n' '未做修改。'; return 0 ;;
        1)
            verify_agent_proxy_change
            refresh_helper_from_state
            if ! "${HELPER}" refresh-service "${unit}"; then
                printf '%s\n' '配置检查更新失败；底层事务已保留或恢复原配置。' >&2
                return 1
            fi
            action=REFRESH
            if [[ ${reason} == *Komari* ]]; then
                action=REFRESH_KOMARI
            elif [[ ${reason} == *'CF Probe'* ]]; then
                action=REFRESH_CF_PROBE_LATENCY
            fi
            printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                "${action}" "${unit}" >>"${state}/service-proxy-actions.log"
            if [[ ${reason} == *Komari* ]]; then
                printf '%s\n' '完成：Komari 国外出口、真实 IP 和自动发现身份守卫均已检查。'
                printf '%s\n' '延迟任务请在 Komari 面板选择 ICMP；TCP 延迟不通过代理转发。'
                manage_komari_report_ipv4 "${unit}" "${state}"
            elif [[ ${reason} == *'CF Probe'* ]]; then
                printf '%s\n' '完成：CF Probe 延迟兼容已检查并生效；具体模式以上方提示为准。'
            else
                printf '完成：%s 的国外出口配置已检查并更新。\n' "${unit}"
            fi
            ;;
        2)
            printf '%s\n' '撤销后，Agent 服务仍保留，但会恢复直接联网。'
            printf '%s\n' '如果国内入口仍受服务商限制，该 Agent 可能无法连接面板。'
            read -r -p '确认只撤销这个服务的国外出口配置？[y/N]：' answer
            case "${answer}" in y|Y|yes|YES|是) ;; *) printf '%s\n' '未做修改。'; return 0 ;; esac
            refresh_helper_from_state
            if ! "${HELPER}" disable-service "${unit}"; then
                printf '%s\n' '撤销失败；底层事务已保留或恢复原配置。' >&2
                return 1
            fi
            printf '%s\tDISABLE\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                "${unit}" >>"${state}/service-proxy-actions.log"
            printf '完成：%s 已恢复直接联网；Agent 服务仍保留。\n' "${unit}"
            ;;
        *) printf '%s\n' '选择无效，未做修改。' >&2; return 1 ;;
    esac
}

scan_services() {
    local state unit description fragment exec_data exec_path exec_name reason status selection answer index
    local report_ip managed metadata_line scan_started metadata_output units_output rc
    local -a units=() descriptions=() fragments=() exec_names=() reasons=() proxy_states=() managed_states=()
    require_root
    [[ -t 0 ]] || die '服务扫描需要交互终端。'
    state=$(active_state)
    [[ ! -e ${state}/closing && ! -L ${state}/closing ]] \
        || die '安装状态正在回滚，拒绝扫描或修改 Agent。'

    scan_started=${SECONDS}
    printf '%s\n' '正在读取运行中的服务信息……'
    if units_output=$(systemctl_scan list-units --type=service --state=running --plain --no-legend --no-pager); then
        :
    else
        rc=$?
        printf '读取运行中 systemd 服务列表失败或超时（退出码 %s），本次未做修改。\n' "${rc}" >&2
        return 1
    fi
    while IFS= read -r unit; do
        [[ -n ${unit} ]] || continue
        valid_service_unit "${unit}" || continue
        description=
        fragment=
        exec_data=
        if metadata_output=$(systemctl_scan show \
            -p Description -p FragmentPath -p ExecStart -- "${unit}" 2>/dev/null); then
            :
        else
            rc=$?
            printf '跳过服务 %s：读取 systemd 信息失败或超时（退出码 %s）。\n' \
                "${unit}" "${rc}" >&2
            continue
        fi
        while IFS= read -r metadata_line; do
            case "${metadata_line}" in
                Description=*) description=${metadata_line#Description=} ;;
                FragmentPath=*) fragment=${metadata_line#FragmentPath=} ;;
                ExecStart=*) exec_data=${metadata_line#ExecStart=} ;;
            esac
        done <<<"${metadata_output}"
        exec_path=$(sed -n 's/^[[:space:]]*{[[:space:]]*path=\([^ ;}]*\).*/\1/p; q' <<<"${exec_data}")
        exec_name=${exec_path##*/}
        service_is_excluded "${unit}" "${description}" "${fragment}" "${exec_name}" && continue
        reason=$(candidate_reason "${unit}" "${description}" "${fragment}" "${exec_name}") || continue
        description=$(printf '%s' "${description}" | sanitize_display_text)
        fragment=$(printf '%s' "${fragment}" | sanitize_display_text)
        exec_name=$(printf '%s' "${exec_name}" | sanitize_display_text)
        status=未配置
        managed=no
        if [[ -e /etc/systemd/system/${unit}.d/90-po0-unlock-proxy.conf ]]; then
            if grep -Fxq -- "${unit}" "${state}/managed-services" 2>/dev/null; then
                status=已由本助手配置
                managed=yes
                if [[ ${reason} == *Komari* ]]; then
                    report_ip=$(report_ipv4_for_service "${unit}" || true)
                    if [[ -n ${report_ip} ]]; then
                        status="已配置；展示IP=${report_ip}"
                    else
                        status='已配置；展示IP=自动'
                    fi
                fi
            else
                status=已有同名配置
            fi
        elif grep -Fxq -- "${unit}" "${state}/managed-services" 2>/dev/null; then
            status=托管记录异常
        elif unit_has_proxy_environment "${unit}"; then
            status=已有代理环境
        fi
        units[${#units[@]}]=${unit}
        descriptions[${#descriptions[@]}]=${description:-无描述}
        fragments[${#fragments[@]}]=${fragment:-未知}
        exec_names[${#exec_names[@]}]=${exec_name:-未知}
        reasons[${#reasons[@]}]=${reason}
        proxy_states[${#proxy_states[@]}]=${status}
        managed_states[${#managed_states[@]}]=${managed}
    done < <(awk '{print $1}' <<<"${units_output}" | LC_ALL=C sort -u)
    printf '服务信息读取完成（耗时 %d 秒）。\n' "$((SECONDS - scan_started))"

    printf '\n%s\n' '================ 国内入口 Agent 服务扫描 ================'
    printf '%s\n' '仅列出疑似监控或转发面板 Agent；关键系统及中转服务已排除。'
    if [[ ${#units[@]} -eq 0 ]]; then
        printf '%s\n' '没有发现候选服务。以后安装新 Agent 后可再次扫描。'
        return 0
    fi
    for ((index=0; index<${#units[@]}; index++)); do
        printf '%2d) %-38s [%s]\n' "$((index + 1))" "${units[index]}" "${proxy_states[index]}"
        printf '    描述：%s\n' "${descriptions[index]}"
        printf '    依据：%s；程序：%s\n' "${reasons[index]}" "${exec_names[index]}"
        printf '    单元：%s\n' "${fragments[index]}"
    done
    printf '%s\n' '------------------------------------------------------'
    printf '%s\n' '每次只处理一个服务；如有多个 Agent，完成后再次扫描。'
    printf '%s\n' '输入编号选择，输入 0 取消。'
    read -r -p '请选择：' selection
    [[ ${selection} != 0 && -n ${selection} ]] || { printf '%s\n' '未做修改。'; return 0; }
    [[ ${selection} =~ ^[0-9]+$ ]] || die "无效编号：${selection}"
    (( 10#${selection} >= 1 && 10#${selection} <= ${#units[@]} )) || die "编号超出范围：${selection}"
    index=$((10#${selection} - 1))
    unit=${units[index]}
    if [[ ${managed_states[index]} == yes ]]; then
        manage_configured_service "${unit}" "${reasons[index]}" "${state}"
        return
    fi
    [[ ${proxy_states[index]} == 未配置 ]] \
        || { printf '%s 当前状态为“%s”，未做修改。\n' "${units[index]}" "${proxy_states[index]}"; return 0; }

    printf '\n即将为 %s 添加国外出口并重启一次。\n' "${units[index]}"
    printf '描述：%s\n程序：%s\n单元：%s\n' \
        "${descriptions[index]}" "${exec_names[index]}" "${fragments[index]}"
    printf '%s\n' '若服务不能恢复为 active/running，脚本会立即撤销本次配置。'
    if [[ ${reasons[index]} == *转发* ]]; then
        printf '%s\n' '注意：这是转发面板 Agent。启用代理可能改变其控制连接或转发行为，请仅在你明确需要时确认。'
    fi
    read -r -p '确认只处理这个服务？[y/N]：' answer
    case "${answer}" in y|Y|yes|YES|是) ;; *) printf '%s\n' '未做修改。'; return 0 ;; esac

    verify_agent_proxy_change
    printf '\n[%s] 正在配置……\n' "${unit}"
    refresh_helper_from_state
    if "${HELPER}" enable-service "${unit}"; then
        printf '%s\tENABLE\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${unit}" >>"${state}/service-proxy-actions.log"
        printf '\n完成：已为 %s 启用国外出口。\n' "${unit}"
    else
        printf '%s\n' "${unit} 配置失败，已尝试恢复该服务原配置。" >&2
        return 1
    fi
    if [[ ${reasons[index]} == *Komari* ]]; then
        printf '%s\n' 'Komari 还可以单独指定面板展示的 国内入口公网 IPv4。'
        printf '%s\n' '延迟任务请在 Komari 面板选择 ICMP，以显示国内入口的真实网络延迟。'
        # 展示 IP 只影响面板显示，选择无效或取消都不该让整次配置被判为失败。
        manage_komari_report_ipv4 "${unit}" "${state}" \
            || printf '%s\n' '面板展示 IPv4 未做修改；国外出口配置已经生效。' >&2
    fi
    printf '%s\n' '以后安装新的 Agent，可从 Po0 解锁助手再次扫描。'
}
