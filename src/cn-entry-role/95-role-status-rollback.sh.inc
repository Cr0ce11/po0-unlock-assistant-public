
status() {
    require_root
    printf '%s\n' '[国内入口安装状态]'
    if [[ -r ${ACTIVE_FILE} ]]; then printf 'ACTIVE %s\n' "$(<"${ACTIVE_FILE}")"; else printf 'NONE\n'; fi
    printf '%s\n' '[本地代理监听]'
    ss -lnt | grep -E '127\.0\.0\.1:(13128|19080)' || true
    printf '%s\n' '[配置文件]'
    ls -l "${APT_CONF}" "${PROFILE_CONF}" "${HELPER}" 2>/dev/null || true
    if [[ -r ${ACTIVE_FILE} ]]; then
        local state
        state=$(active_state)
        if [[ -r ${state}/cn-entry-private-ip && -r ${state}/overseas-exit-private-ip ]]; then
            printf '[隧道连接地址]\n国内入口=%s 国外出口=%s\n' \
                "$(<"${state}/cn-entry-private-ip")" "$(<"${state}/overseas-exit-private-ip")"
        fi
        printf '%s\n' '[已配置国外出口的服务]'
        if [[ -s ${state}/managed-services ]]; then
            sed -n '1,80p' "${state}/managed-services"
        else
            printf '%s\n' 'NONE'
        fi
    fi
    if [[ -x ${HELPER} ]]; then "${HELPER}" test || true; fi
}

health_line() {
    local level=$1 name=$2 detail=$3
    # 机器可读模式只供只读检查入口使用：输出制表符分隔的结构化行，便于调用方
    # 直接取字段，而不是去解析给人看的界面文本。默认输出逐字节不变。
    if [[ ${PO0_HEALTH_TSV:-no} == yes ]]; then
        printf 'PO0LINE\t%s\t%s\t%s\n' "${level}" "${name}" "${detail}"
        return 0
    fi
    printf '    [%s] %s：%s\n' "${level}" "${name}" "${detail}"
}

health_group() {
    printf '\n  %s\n' "$1"
}

health_safe_state() {
    local state
    [[ -f ${ACTIVE_FILE} && ! -L ${ACTIVE_FILE} && -r ${ACTIVE_FILE} ]] || return 1
    [[ $(stat -c '%u' "${ACTIVE_FILE}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${ACTIVE_FILE}" 2>/dev/null) == 600 ]] || return 1
    state=$(<"${ACTIVE_FILE}")
    case "${state}" in "${STATE_ROOT}"/*) ;; *) return 1 ;; esac
    [[ -d ${state} && ! -L ${state} \
        && $(stat -c '%u' "${state}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${state}" 2>/dev/null) == 700 ]] || return 1
    printf '%s\n' "${state}"
}

health_regular_root_file() {
    local path=$1 expected_mode=$2
    [[ -f ${path} && ! -L ${path} ]] || return 1
    [[ $(stat -c '%u' "${path}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${path}" 2>/dev/null) == "${expected_mode}" ]]
}

health() (
    local state= failures=0 warnings=0 unit dropin load_state tunnel_uid=
    local forward_status= forward_rc=0
    local managed_marker='# Managed by Po0 Unlock; do not edit manually.'
    require_root
    health_group '基础状态'

    if state=$(health_safe_state); then
        health_line 正常 '安装记录' '完整'
        if [[ -e ${state}/closing || -L ${state}/closing ]]; then
            health_line 异常 '安装状态' '检测到未完成的完整回滚'
            failures=$((failures + 1))
        else
            health_line 正常 '安装状态' '没有未完成事务'
        fi
    else
        health_line 异常 '安装记录' '缺失、损坏或指向了无效目录'
        failures=$((failures + 1))
    fi

    health_group '隧道与代理'
    tunnel_uid=$(id -u "${TUNNEL_USER}" 2>/dev/null || true)
    if [[ ${tunnel_uid} =~ ^[0-9]+$ ]] \
        && tunnel_authorized_keys_hardened "${tunnel_uid}"; then
        health_line 正常 '受限隧道账户' '账户、授权文件和转发限制完整'
    else
        health_line 异常 '受限隧道账户' '账户或授权限制异常；可通过“更新连接配置”安全补齐'
        failures=$((failures + 1))
    fi
    if pgrep -u "${TUNNEL_USER}" >/dev/null 2>&1; then
        health_line 正常 '反向隧道连接' '国外出口已经连入'
    else
        health_line 异常 '反向隧道连接' '没有发现国外出口连接'
        failures=$((failures + 1))
    fi
    if ss -H -lnt 2>/dev/null | awk '$4 == "127.0.0.1:13128" {a=1} $4 == "127.0.0.1:19080" {b=1} END {exit !(a && b)}'; then
        health_line 正常 '国内入口代理端口' 'HTTP 与 SOCKS 端口均已建立'
    else
        health_line 异常 '国内入口代理端口' 'HTTP 或 SOCKS 端口缺失'
        failures=$((failures + 1))
    fi

    if health_regular_root_file "${APT_CONF}" 644 \
        && grep -Fqx -- "Acquire::http::Proxy \"${HTTP_PROXY_URL}\";" "${APT_CONF}" \
        && grep -Fqx -- "Acquire::https::Proxy \"${HTTP_PROXY_URL}\";" "${APT_CONF}"; then
        health_line 正常 'APT 代理配置' '完整'
    else
        health_line 异常 'APT 代理配置' '文件缺失、权限异常或内容已变化'
        failures=$((failures + 1))
    fi
    if health_regular_root_file "${PROFILE_CONF}" 644 \
        && grep -Fqx -- '# 国内入口管理出站：国外出口反向 SSH 代理' "${PROFILE_CONF}" \
        && grep -Fqx -- "export ALL_PROXY='${SOCKS_PROXY_URL}'" "${PROFILE_CONF}"; then
        health_line 正常 '登录环境代理配置' '完整'
    else
        health_line 异常 '登录环境代理配置' '文件缺失、权限异常或内容已变化'
        failures=$((failures + 1))
    fi

    health_group '国内入口组件'
    if health_regular_root_file "${HELPER}" 755 && bash -n "${HELPER}"; then
        health_line 正常 'Agent 管理组件' '文件和语法正常'
    else
        health_line 异常 'Agent 管理组件' '文件缺失、权限异常或语法错误'
        failures=$((failures + 1))
    fi
    if curl -4 --proxy "${SOCKS_PROXY_URL}" -fsS --connect-timeout 5 --max-time 12 \
        -o /dev/null https://deb.debian.org/debian/; then
        health_line 正常 '国内入口联网' '可以通过国外出口访问外部网络'
    else
        health_line 异常 '国内入口联网' '无法通过国外出口访问外部网络'
        failures=$((failures + 1))
    fi

    health_group '受管 Agent'
    if [[ -n ${state} && -s ${state}/managed-services ]]; then
        while IFS= read -r unit; do
            [[ -n ${unit} ]] || continue
            if ! valid_service_unit "${unit}"; then
                health_line 异常 '托管 Agent' '清单中存在无效服务名'
                failures=$((failures + 1))
                continue
            fi
            load_state=$(systemctl show -p LoadState --value -- "${unit}" 2>/dev/null || true)
            dropin=/etc/systemd/system/${unit}.d/90-po0-unlock-proxy.conf
            if [[ ${load_state} != loaded ]]; then
                health_line 异常 "Agent ${unit}" '服务已经不存在'
                failures=$((failures + 1))
            elif [[ ! -f ${dropin} || -L ${dropin} ]] \
                || [[ $(sed -n '1p' "${dropin}" 2>/dev/null) != "${managed_marker}" ]]; then
                health_line 异常 "Agent ${unit}" '国外出口配置缺失或已被修改'
                failures=$((failures + 1))
            elif systemctl is-active --quiet "${unit}"; then
                # 转发模式的判定与检查都只在组件作用域里定义，角色脚本取不到那些函数，
                # 必须经组件的只读入口取结论。退出码 3 表示该服务没有启用转发模式；
                # 其余非零一律报异常，不能退回“看起来正常”，否则又是一次假绿灯。
                forward_rc=0
                forward_status=$("${HELPER}" cf-probe-forward-health "${unit}" 2>/dev/null) \
                    || forward_rc=$?
                if (( forward_rc == 3 )); then
                    health_line 正常 "Agent ${unit}" '配置完整且正在运行'
                elif (( forward_rc != 0 )); then
                    health_line 异常 "Agent ${unit}" '无法确认转发模式状态'
                    failures=$((failures + 1))
                else
                    case "${forward_status%% *}" in
                        正常)
                            health_line 正常 "Agent ${unit}" "${forward_status#* }"
                            ;;
                        提醒)
                            health_line 提醒 "Agent ${unit}" "${forward_status#* }"
                            warnings=$((warnings + 1))
                            ;;
                        异常)
                            health_line 异常 "Agent ${unit}" "${forward_status#* }"
                            failures=$((failures + 1))
                            ;;
                        *)
                            health_line 异常 "Agent ${unit}" '转发模式状态无法解析'
                            failures=$((failures + 1))
                            ;;
                    esac
                fi
            else
                health_line 提醒 "Agent ${unit}" '配置完整，但服务当前没有运行'
                warnings=$((warnings + 1))
            fi
        done <"${state}/managed-services"
    else
        health_line 正常 '托管 Agent' '当前没有需要检查的 Agent'
    fi

    if [[ -e /etc/systemd/system/po0-komari-latency.service \
        || -e /etc/redsocks/po0-komari-latency.conf \
        || -e /usr/local/libexec/po0-komari-latency-firewall ]]; then
        health_line 提醒 '旧版 Komari 组件' '仍有旧文件，请从 Agent 扫描中再次选择 Komari'
        warnings=$((warnings + 1))
    else
        health_line 正常 '旧版组件' '没有发现已知残留'
    fi

    if (( failures == 0 && warnings == 0 )); then
        printf '\n%s\n' '  小结：[正常] 国内入口全部检查通过'
        return 0
    fi
    if (( failures == 0 )); then
        printf '\n  小结：[提醒] 国内入口有 %d 项需要留意\n' "${warnings}"
        return 2
    fi
    printf '\n  小结：[异常] 国内入口有 %d 项需要处理，另有 %d 项提醒\n' \
        "${failures}" "${warnings}"
    return 1
)

rollback_services() {
    local state unit failures=0 closing current_state
    require_root
    state=$(active_state)
    closing=${state}/closing
    [[ ! -L ${closing} ]] || die '安装状态的 closing 标记异常，完整回滚已暂停。'
    if [[ -e ${closing} ]]; then
        [[ -f ${closing} ]] || die '安装状态的 closing 标记不是普通文件。'
        acquire_state_mutation_lock "${state}" 'Agent 回滚状态复核'
        [[ -r ${ACTIVE_FILE} ]] || die 'ACTIVE 状态已经变化，完整回滚已暂停。'
        current_state=$(<"${ACTIVE_FILE}")
        [[ ${current_state} == "${state}" ]] || die 'ACTIVE 状态已经切换，完整回滚已暂停。'
        [[ ! -s ${state}/managed-services ]] \
            || die '安装状态已锁定但托管清单非空，需要人工检查。'
        log '托管 Agent 已清空，安装状态已锁定；可以继续完成国外出口与国内入口回滚。'
        return 0
    fi
    if [[ -s ${state}/managed-services ]]; then
        refresh_helper_from_state
        while IFS= read -r unit; do
            [[ -n ${unit} ]] || continue
            if ! valid_service_unit "${unit}"; then
                printf '[国内入口] 错误：托管清单中存在无效服务名，完整回滚已暂停。\n' >&2
                failures=$((failures + 1))
                continue
            fi
            if ! "${HELPER}" disable-service "${unit}"; then
                printf '[国内入口] 错误：%s 未能安全移除代理配置。\n' "${unit}" >&2
                failures=$((failures + 1))
            fi
        done <"${state}/managed-services"
        (( failures == 0 )) \
            || die "仍有 ${failures} 个托管服务未安全回滚；核心隧道与 ACTIVE 状态已保留。"
    fi
    acquire_state_mutation_lock "${state}" 'Agent 回滚状态封存'
    [[ -r ${ACTIVE_FILE} ]] || die 'ACTIVE 状态已经变化，完整回滚已暂停。'
    current_state=$(<"${ACTIVE_FILE}")
    [[ ${current_state} == "${state}" ]] || die 'ACTIVE 状态已经切换，完整回滚已暂停。'
    [[ ! -e ${closing} && ! -L ${closing} ]] || die '安装状态在回滚期间被其他流程锁定。'
    [[ ! -s ${state}/managed-services ]] \
        || die '回滚确认期间又出现托管 Agent；尚未拆除核心隧道，请重新执行完整回滚。'
    printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${closing}"
    chmod 0600 "${closing}"
    log '已安全移除全部托管 Agent 并锁定安装状态；核心隧道暂时保留。'
}

record_tunnel_user_uid() {
    local state=$1 uid=$2 record=${1}/tunnel-user-uid existing=
    [[ ${uid} =~ ^[0-9]+$ ]] || return 1
    if [[ -e ${record} || -L ${record} ]]; then
        existing=$(read_recorded_tunnel_user_uid "${state}") || return 1
        [[ ${existing} == "${uid}" ]]
        return
    fi
    printf '%s\n' "${uid}" >"${record}" || return 1
    if ! chmod 0600 "${record}" || [[ $(read_recorded_tunnel_user_uid "${state}") != "${uid}" ]]; then
        rm -f -- "${record}"
        return 1
    fi
}

read_recorded_tunnel_user_uid() {
    local state=$1 record=${1}/tunnel-user-uid uid
    [[ -f ${record} && ! -L ${record} && -r ${record} ]] || return 1
    [[ $(stat -c '%u' "${record}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${record}" 2>/dev/null) == 600 \
        && $(stat -c '%h' "${record}" 2>/dev/null) == 1 ]] || return 1
    [[ $(wc -l <"${record}" | tr -d '[:space:]') == 1 ]] || return 1
    IFS= read -r uid <"${record}" || return 1
    [[ ${uid} =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${uid}"
}

rollback_finalize() {
    local state attempt current_state closing account_home closed_marker path
    local tunnel_uid= home_owner uid_recorded=
    require_root
    state=$(active_state)
    acquire_state_mutation_lock "${state}" '最终回滚清理'
    [[ -r ${ACTIVE_FILE} ]] || die 'ACTIVE 状态已经变化，拒绝继续最终清理。'
    current_state=$(<"${ACTIVE_FILE}")
    [[ ${current_state} == "${state}" ]] || die 'ACTIVE 状态已经切换，拒绝继续最终清理。'
    closing=${state}/closing
    [[ -f ${closing} && ! -L ${closing} ]] \
        || die '安装状态尚未由 Agent 回滚阶段安全锁定，拒绝最终清理。'

    [[ ! -s ${state}/managed-services ]] \
        || die '托管 Agent 清单仍非空，拒绝进入最终清理阶段。'
    if id "${TUNNEL_USER}" >/dev/null 2>&1; then
        tunnel_uid=$(id -u "${TUNNEL_USER}") \
            || die '无法读取专用隧道账户 UID，拒绝自动删除。'
        [[ ${tunnel_uid} =~ ^[0-9]+$ ]] \
            || die '专用隧道账户 UID 异常，拒绝自动删除。'
        account_home=$(getent passwd "${TUNNEL_USER}" | awk -F: 'NR == 1 { print $6 }')
        [[ ${account_home} == "${TUNNEL_HOME}" ]] \
            || die '专用隧道账户的家目录已变化，拒绝自动删除。'
        [[ ! -L ${TUNNEL_HOME} ]] || die '专用隧道家目录是符号链接，拒绝自动删除。'
        if [[ -e ${TUNNEL_HOME} ]]; then
            [[ -d ${TUNNEL_HOME} ]] || die '专用隧道家目录不是普通目录，拒绝自动删除。'
            home_owner=$(stat -c '%u' "${TUNNEL_HOME}" 2>/dev/null) \
                || die '无法读取专用隧道家目录属主，拒绝自动删除。'
            [[ ${home_owner} == "${tunnel_uid}" ]] \
                || die '专用隧道家目录属主已变化，拒绝自动删除。'
        fi
        record_tunnel_user_uid "${state}" "${tunnel_uid}" \
            || die '无法安全记录专用隧道账户 UID，拒绝自动删除。'
        if pgrep -u "${TUNNEL_USER}" >/dev/null 2>&1; then
            log '正在等待国外出口反向隧道安全退出（最长 30 秒）。'
        fi
        for (( attempt = 1; attempt <= 30; attempt++ )); do
            pgrep -u "${TUNNEL_USER}" >/dev/null 2>&1 || break
            sleep 1
        done
        pgrep -u "${TUNNEL_USER}" >/dev/null 2>&1 \
            && die '国外出口反向隧道仍占用专用账户，拒绝形成半回滚状态。'
        userdel "${TUNNEL_USER}" || die '专用隧道账户删除失败，ACTIVE 状态已保留。'
    fi
    ! id "${TUNNEL_USER}" >/dev/null 2>&1 \
        || die '专用隧道账户仍然存在，拒绝提交完整回滚。'
    if [[ -e ${TUNNEL_HOME} || -L ${TUNNEL_HOME} ]]; then
        [[ -d ${TUNNEL_HOME} && ! -L ${TUNNEL_HOME} ]] \
            || die '专用隧道家目录残留不是安全的普通目录，拒绝自动删除。'
        if [[ -z ${tunnel_uid} ]]; then
            tunnel_uid=$(read_recorded_tunnel_user_uid "${state}") \
                || die '缺少可信的专用隧道账户 UID 记录，无法安全清理残留家目录。'
        else
            uid_recorded=$(read_recorded_tunnel_user_uid "${state}") \
                || die '专用隧道账户 UID 记录异常，无法安全清理残留家目录。'
            [[ ${uid_recorded} == "${tunnel_uid}" ]] \
                || die '专用隧道账户 UID 记录发生变化，无法安全清理残留家目录。'
        fi
        home_owner=$(stat -c '%u' "${TUNNEL_HOME}" 2>/dev/null) \
            || die '无法读取残留专用隧道家目录属主。'
        [[ ${home_owner} == "${tunnel_uid}" ]] \
            || die '残留专用隧道家目录属主与记录不符，拒绝自动删除。'
        command -v mountpoint >/dev/null \
            || die '系统缺少 mountpoint，无法安全清理残留家目录。'
        ! mountpoint -q "${TUNNEL_HOME}" \
            || die '专用隧道家目录是挂载点，拒绝自动删除。'
        rm -rf --one-file-system -- "${TUNNEL_HOME}" \
            || die '专用隧道家目录清理失败，ACTIVE 状态已保留；修正占用后可重试完整回滚。'
    fi
    [[ ! -e ${TUNNEL_HOME} && ! -L ${TUNNEL_HOME} ]] \
        || die '专用隧道家目录仍有残留，拒绝提交完整回滚。'

    rm -f -- "${APT_CONF}" "${PROFILE_CONF}" "${HELPER}" \
        || die '代理配置文件删除失败，ACTIVE 状态已保留。'
    for path in "${APT_CONF}" "${PROFILE_CONF}" "${HELPER}"; do
        [[ ! -e ${path} && ! -L ${path} ]] \
            || die "代理配置路径仍有残留，拒绝提交完整回滚：${path}"
    done
    date -u +%Y-%m-%dT%H:%M:%SZ >"${state}/rolled-back-at"
    closed_marker=${state}/ACTIVE.closed
    [[ ! -e ${closed_marker} && ! -L ${closed_marker} ]] \
        || die '历史状态中已存在 ACTIVE.closed，拒绝覆盖。'
    mv -- "${ACTIVE_FILE}" "${closed_marker}" \
        || die '最终提交 ACTIVE 状态失败；可安全重试完整回滚。'
    log "国内入口已回滚，历史状态保留在：${state}"
}

rollback() {
    rollback_services
    rollback_finalize
}

claim_status() {
    local install_claim=${1:-}
    require_root
    active_install_claim_matches "${install_claim}" \
        || die '安装事务标识不匹配。'
}

rollback_services_claimed() {
    local install_claim=${1:-}
    require_root
    active_install_claim_matches "${install_claim}" \
        || die '安装事务标识不匹配，拒绝回滚其他部署。'
    rollback_services
}

rollback_finalize_claimed() {
    local install_claim=${1:-}
    require_root
    active_install_claim_matches "${install_claim}" \
        || die '安装事务标识不匹配，拒绝回滚其他部署。'
    rollback_finalize
}

case "${1:-}" in
    prepare) prepare "${2:-}" "${3:-}" ;;
    finalize) finalize "${2:-}" "${3:-}" ;;
    refresh) refresh "${2:-}" "${3:-}" ;;
    __refresh-managed-service) refresh_one_managed_service "${2:-}" ;;
    cf-probe-outbound-capability) current_component_cf_probe_outbound_capability "${2:-}" ;;
    scan-services) scan_services ;;
    rollback-services) rollback_services ;;
    rollback-finalize) rollback_finalize ;;
    claim-status) claim_status "${2:-}" ;;
    rollback-services-claimed) rollback_services_claimed "${2:-}" ;;
    rollback-finalize-claimed) rollback_finalize_claimed "${2:-}" ;;
    status) status ;;
    health) health ;;
    rollback) rollback ;;
    *) die '用法：cn-entry-role.sh prepare <公钥base64> <安装事务标识> | finalize/refresh <国内入口连接IPv4> <国外出口源IPv4> | scan-services | status | health | rollback-services | rollback-finalize' ;;
esac
