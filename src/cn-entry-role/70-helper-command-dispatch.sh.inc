
usage() {
    cat <<'USAGE'
用法：
  po0-cn-entry status
  po0-cn-entry test
  po0-cn-entry run <命令> [参数...]
  po0-cn-entry enable-service <systemd-unit> [env|forward]
  po0-cn-entry disable-service <systemd-unit>
  po0-cn-entry set-report-ip <komari-unit> <IPv4>
  po0-cn-entry clear-report-ip <komari-unit>

说明：
  run             仅让本次命令通过国外出口。
  enable-service  为指定服务添加代理环境并重启该服务；模式默认 env，forward
                  仅用于 cf-probe，额外加一条本地转发供不读代理环境变量的通道使用。
  disable-service 移除指定服务的代理环境并重启该服务。
  set-report-ip   设置 Komari 在面板展示的 IPv4。
  clear-report-ip 恢复 Komari 自动检测出口 IPv4。
USAGE
}

proxy_env() {
    export HTTP_PROXY="${HTTP_PROXY_URL}" HTTPS_PROXY="${HTTP_PROXY_URL}"
    export http_proxy="${HTTP_PROXY_URL}" https_proxy="${HTTP_PROXY_URL}"
    export ALL_PROXY="${SOCKS_PROXY_URL}" all_proxy="${SOCKS_PROXY_URL}"
    export NO_PROXY='__NO_PROXY__'
    export no_proxy="${NO_PROXY}"
}

case "${1:-}" in
    status)
        ss -lnt | grep -E '127\.0\.0\.1:(13128|19080)' || true
        systemctl is-active ssh
        ;;
    test)
        proxy_env
        curl -4 -fsS --connect-timeout 8 --max-time 20 \
            -o /dev/null -w 'HTTP 状态=%{http_code} 远端=%{remote_ip} 总耗时=%{time_total}s\n' \
            https://deb.debian.org/debian/
        ;;
    run)
        shift
        [[ $# -gt 0 ]] || { usage; exit 2; }
        proxy_env
        exec "$@"
        ;;
    cf-probe-forward-health)
        # 只读入口，供角色脚本的健康检查取转发模式结论。转发模式的判定与检查都写在
        # 组件作用域里，角色脚本取不到那些函数，必须经这里拿结果；不取锁、不改任何状态。
        # 退出码：0 已启用转发模式且标准输出为「等级 说明」；3 该服务未启用转发模式；
        # 其余为无法判定，角色侧据此报异常，绝不退回“看起来正常”。
        unit=${2:-}
        [[ -n ${unit} ]] || { usage; exit 2; }
        valid_helper_service_unit "${unit}" \
            || { echo '服务名必须是合法的 .service 单元名。' >&2; exit 2; }
        dropin="/etc/systemd/system/${unit}.d"
        cf_probe_forward_mode_active "${dropin}" || exit 3
        cf_probe_forward_health "${unit}" "${dropin}"
        ;;
    reconcile-cf-probe)
        unit=${2:-}
        [[ -n ${unit} ]] || { usage; exit 2; }
        valid_helper_service_unit "${unit}" \
            || { echo '服务名必须是合法的 .service 单元名。' >&2; exit 2; }
        state=$(helper_active_state)
        command -v flock >/dev/null \
            || { echo '系统缺少 flock，无法安全恢复 cf-probe 测速目标。' >&2; exit 1; }
        exec 9>"${state}/service-proxy.lock"
        # 拿不到锁时不能静默当成功：守卫由 .path 单元触发，面板的新配置版本号
        # 一旦被接受就不会再变，静默放弃会让安全测速目标长期不恢复。
        flock -w "${CN_ENTRY_LOCK_WAIT_SECONDS}" 9 \
            || { echo '等待服务配置锁超时，未恢复 cf-probe 测速目标。' >&2; exit 1; }
        confirm_helper_state_open "${state}" \
            || { echo '安装状态正在关闭或已经变化，拒绝恢复 cf-probe 测速目标。' >&2; exit 1; }
        [[ -f ${state}/managed-services ]] && grep -Fxq -- "${unit}" "${state}/managed-services" \
            || { echo '该 cf-probe 不在本助手的托管清单中，拒绝自动恢复测速目标。' >&2; exit 1; }
        dropin="/etc/systemd/system/${unit}.d"
        dropin_file="${dropin}/90-po0-unlock-proxy.conf"
        managed_dropin_owned "${dropin_file}" \
            || { echo 'cf-probe 代理文件缺失或已被修改，拒绝自动恢复测速目标。' >&2; exit 1; }
        is_cf_probe_service "${unit}" \
            || { echo '目标服务已不再是可识别的 cf-probe，拒绝自动恢复测速目标。' >&2; exit 1; }
        compat_dir=$(cf_probe_compat_dir "${dropin}")
        managed_cf_probe_compat_owned "${compat_dir}" \
            || { echo 'cf-probe 兼容记录缺失或已被修改，拒绝自动恢复测速目标。' >&2; exit 1; }
        reconcile_cf_probe_go_latency_compat "${unit}" "${compat_dir}"
        ;;
    enable-service)
        unit=${2:-}
        [[ -n ${unit} ]] || { usage; exit 2; }
        # 出站模式：env（默认，仅注入代理环境变量）或 forward（额外加一条本地转发）。
        outbound_mode=${3:-env}
        cf_probe_valid_outbound_mode "${outbound_mode}" \
            || { echo '未知的出站模式，只支持 env 或 forward。' >&2; exit 2; }
        state=$(helper_active_state)
        acquire_service_lock "${state}"
        confirm_helper_state_open "${state}" \
            || { echo '安装状态正在关闭或已经变化，拒绝修改服务。' >&2; exit 1; }
        validate_service_target "${unit}"
        if [[ ${outbound_mode} == forward ]] && ! is_cf_probe_service "${unit}"; then
            echo '转发模式目前只支持 cf-probe，其他服务请使用默认的 env 模式。' >&2
            exit 2
        fi
        dropin="/etc/systemd/system/${unit}.d"
        dropin_file="${dropin}/90-po0-unlock-proxy.conf"
        [[ ! -e ${dropin_file} ]] \
            || { echo "该服务已经存在同名代理配置，拒绝覆盖。" >&2; exit 1; }
        if [[ -f ${state}/managed-services ]] && grep -Fxq -- "${unit}" "${state}/managed-services"; then
            echo '托管清单已含该服务但代理文件不存在，拒绝自动修复。' >&2
            exit 1
        fi
        compat_dir=
        komari_identity_dir=
        komari_identity_created=no
        compat_created=no
        compat_curl_created=no
        install -d -m 0755 "${dropin}"
        tmp=$(mktemp "${dropin}/.90-po0-unlock-proxy.XXXXXX")
        managed_tmp=$(mktemp "${state}/.managed-services.XXXXXX")
        write_service_proxy_dropin "${unit}" "${tmp}"
        { sed -n '1,$p' "${state}/managed-services" 2>/dev/null || true; printf '%s\n' "${unit}"; } \
            | awk 'NF && !seen[$0]++' >"${managed_tmp}"
        chmod 0600 "${managed_tmp}"

        TX_COMMITTED=no
        TX_UNIT=${unit}
        TX_STATE=${state}
        TX_DROPIN_DIR=${dropin}
        TX_DROPIN_FILE=${dropin_file}
        TX_DROPIN_TMP=${tmp}
        TX_MANAGED_TMP=${managed_tmp}
        TX_ORIGINAL_RUNNING=yes
        TX_DROPIN_MAY_EXIST=no
        TX_LIST_MAY_CHANGE=no
        TX_COMPAT_DIR=
        TX_COMPAT_CREATED=no
        TX_COMPAT_CURL_CREATED=no
        TX_CF_GUARD_CREATED=no
        TX_KOMARI_IDENTITY_DIR=
        TX_KOMARI_IDENTITY_CREATED=no
        TX_FORWARD_DROPIN=
        TX_FORWARD_PREPARED=no
        TX_FORWARD_SNAPSHOT=
        TX_FORWARD_MAY_CHANGE=no
        trap 'enable_transaction_cleanup "$?"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap 'exit 129' HUP

        if is_cf_probe_service "${unit}"; then
            compat_dir=$(cf_probe_compat_dir "${dropin}")
            [[ -e ${compat_dir} || -L ${compat_dir} ]] || compat_created=yes
            [[ -e ${compat_dir}/curl || -L ${compat_dir}/curl ]] || compat_curl_created=yes
            TX_COMPAT_DIR=${compat_dir}
            TX_COMPAT_CREATED=${compat_created}
            TX_COMPAT_CURL_CREATED=${compat_curl_created}
            # 修订不在白名单时返回 3：跳过测速目标处理，但继续把国外出口配上，
            # 否则 cf-probe 一自动更新就会退回直连而彻底失联。其余失败仍然整次撤销。
            if compat_dir=$(prepare_cf_probe_latency_compat "${unit}" "${dropin}"); then
                printf 'Environment="PATH=%s:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\n' \
                    "${compat_dir}" >>"${tmp}"
            else
                compat_rc=$?
                (( compat_rc == 3 )) || exit 1
                compat_dir=
                TX_COMPAT_DIR=
                TX_COMPAT_CREATED=no
                TX_COMPAT_CURL_CREATED=no
            fi
            if [[ ${outbound_mode} == forward ]]; then
                TX_FORWARD_DROPIN=${dropin}
                TX_FORWARD_SNAPSHOT=$(snapshot_cf_probe_forward_state_if_complete \
                    "${unit}" "${dropin}" "${state}") \
                    || { echo '既有 cf-probe 转发状态无法建立恢复快照，拒绝复用。' >&2; exit 1; }
                TX_FORWARD_MAY_CHANGE=yes
                # 提前置位：即使收到信号中断在 prepare 中间，清理也会处理本次新建的残片。
                TX_FORWARD_PREPARED=yes
                prepare_cf_probe_forward_mode \
                    "${unit}" "${dropin}" "${TX_FORWARD_SNAPSHOT}" >/dev/null \
                    || { echo 'cf-probe 转发模式配置失败，正在撤销本次服务代理。' >&2; exit 1; }
                cf_probe_forward_dropin_line "${dropin}" >>"${tmp}" \
                    || { echo 'cf-probe 转发模式的挂载配置写入失败，正在撤销本次服务代理。' >&2; exit 1; }
            fi
        fi
        if is_komari_service "${unit}"; then
            komari_identity_dir=$(komari_identity_compat_dir "${dropin}")
            [[ -e ${komari_identity_dir} || -L ${komari_identity_dir} ]] \
                || komari_identity_created=yes
            if prepared_identity_dir=$(prepare_komari_identity_guard "${unit}" "${dropin}"); then
                komari_identity_dir=${prepared_identity_dir}
                TX_KOMARI_IDENTITY_DIR=${komari_identity_dir}
                TX_KOMARI_IDENTITY_CREATED=${komari_identity_created}
                printf 'ExecStartPre=+%s/guard %s/config\n' \
                    "${komari_identity_dir}" "${komari_identity_dir}" >>"${tmp}"
            else
                identity_rc=$?
                if (( identity_rc != 3 )); then
                    echo 'Komari 身份守卫配置失败，正在撤销本次服务代理。' >&2
                    exit 1
                fi
                komari_identity_dir=
                komari_identity_created=no
            fi
        fi
        chmod 0644 "${tmp}"

        TX_DROPIN_MAY_EXIST=yes
        mv "${tmp}" "${dropin_file}"
        if ! systemctl daemon-reload || ! restart_and_verify_running "${unit}"; then
            echo '服务应用代理后未恢复为 active/running，正在撤销本次配置。' >&2
            exit 1
        fi
        if [[ -n ${compat_dir} && -f ${compat_dir}/go-record ]]; then
            reconcile_cf_probe_go_latency_compat "${unit}" "${compat_dir}" \
                || { echo 'cf-probe 面板动态配置未能安全收敛，正在撤销本次配置。' >&2; exit 1; }
            guard_created=$(prepare_cf_probe_go_guard_units "${unit}" "${compat_dir}") \
                || { echo 'cf-probe 动态配置守卫安装失败，正在撤销本次配置。' >&2; exit 1; }
            TX_CF_GUARD_CREATED=${guard_created}
        fi
        if [[ -n ${compat_dir} ]] \
            && ! commit_cf_probe_go_latency_compat "${compat_dir}"; then
            echo 'cf-probe 已恢复运行，但测速目标事务未能安全提交，正在撤销本次配置。' >&2
            exit 1
        fi
        TX_LIST_MAY_CHANGE=yes
        mv "${managed_tmp}" "${state}/managed-services"
        TX_COMMITTED=yes
        trap - EXIT INT TERM HUP
        if [[ -n ${TX_FORWARD_SNAPSHOT} ]]; then
            discard_cf_probe_forward_snapshot "${TX_FORWARD_SNAPSHOT}" \
                || echo "警告：服务代理已启用，但转发事务快照 ${TX_FORWARD_SNAPSHOT} 未能清理。" >&2
        fi
        echo "已为 ${unit} 启用国外出口。"
        [[ -z ${compat_dir} ]] \
            || if [[ -f ${compat_dir}/go-record ]]; then
                echo '已让 Go cf-probe 使用未封禁的国内直连测速端口。'
            else
                echo '已让 cf-probe 保留延迟检测，并优先以国内入口真实来源上报。'
            fi
        [[ -z ${komari_identity_dir} ]] \
            || echo '已启用 Komari 自动发现身份有效性守卫。'
        ;;
    refresh-service)
        unit=${2:-}
        [[ -n ${unit} ]] || { usage; exit 2; }
        valid_helper_service_unit "${unit}" \
            || { echo '服务名必须是合法的 .service 单元名。' >&2; exit 2; }
        state=$(helper_active_state)
        acquire_service_lock "${state}"
        confirm_helper_state_open "${state}" \
            || { echo '安装状态正在关闭或已经变化，拒绝修改服务。' >&2; exit 1; }
        dropin="/etc/systemd/system/${unit}.d"
        dropin_file="${dropin}/90-po0-unlock-proxy.conf"
        [[ -f ${state}/managed-services ]] && grep -Fxq -- "${unit}" "${state}/managed-services" \
            || { echo '该服务不在本助手的托管清单中，拒绝更新。' >&2; exit 1; }
        managed_dropin_owned "${dropin_file}" \
            || { echo '代理文件不存在或已被人工修改，拒绝自动更新。' >&2; exit 1; }
        compat_dir=
        komari_identity_dir=
        komari_identity_created=no
        compat_created=no
        compat_curl_created=no
        forward_active=no
        original_running=no
        service_is_running "${unit}" && original_running=yes
        report_ip=$(report_ipv4_from_dropin "${dropin_file}" || true)
        backup=$(mktemp "${state}/.proxy-dropin.XXXXXX")
        tmp=$(mktemp "${dropin}/.90-po0-unlock-proxy.XXXXXX")
        cp -p "${dropin_file}" "${backup}"
        write_service_proxy_dropin "${unit}" "${tmp}"
        if [[ -n ${report_ip} ]]; then
            printf 'Environment="AGENT_CUSTOM_IPV4=%s"\n' "${report_ip}" >>"${tmp}"
        fi

        TX_COMMITTED=no
        TX_UNIT=${unit}
        TX_DROPIN_DIR=${dropin}
        TX_DROPIN_FILE=${dropin_file}
        TX_DROPIN_TMP=${tmp}
        TX_BACKUP=${backup}
        TX_ORIGINAL_RUNNING=${original_running}
        TX_DROPIN_MAY_CHANGE=no
        TX_COMPAT_DIR=
        TX_COMPAT_CREATED=no
        TX_COMPAT_CURL_CREATED=no
        TX_CF_GUARD_CREATED=no
        TX_KOMARI_IDENTITY_DIR=
        TX_KOMARI_IDENTITY_CREATED=no
        trap 'refresh_transaction_cleanup "$?"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap 'exit 129' HUP

        if is_cf_probe_service "${unit}"; then
            compat_dir=$(cf_probe_compat_dir "${dropin}")
            [[ -e ${compat_dir} || -L ${compat_dir} ]] || compat_created=yes
            [[ -e ${compat_dir}/curl || -L ${compat_dir}/curl ]] || compat_curl_created=yes
            TX_COMPAT_DIR=${compat_dir}
            TX_COMPAT_CREATED=${compat_created}
            TX_COMPAT_CURL_CREATED=${compat_curl_created}
            # 修订不在白名单时返回 3：跳过测速目标处理，但继续把国外出口配上，
            # 否则 cf-probe 一自动更新就会退回直连而彻底失联。其余失败仍然整次撤销。
            if compat_dir=$(prepare_cf_probe_latency_compat "${unit}" "${dropin}"); then
                printf 'Environment="PATH=%s:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\n' \
                    "${compat_dir}" >>"${tmp}"
            else
                compat_rc=$?
                (( compat_rc == 3 )) || exit 1
                compat_dir=
                TX_COMPAT_DIR=
                TX_COMPAT_CREATED=no
                TX_COMPAT_CURL_CREATED=no
            fi
            # 重写 drop-in 会丢掉挂载行，转发模式已启用时必须原样补回，否则静默失效。
            if cf_probe_forward_mode_active "${dropin}"; then
                forward_active=yes
                cf_probe_forward_dropin_line "${dropin}" >>"${tmp}" \
                    || { echo 'cf-probe 转发模式的挂载配置写入失败，正在恢复更新前配置。' >&2; exit 1; }
            fi
        fi
        if is_komari_service "${unit}"; then
            komari_identity_dir=$(komari_identity_compat_dir "${dropin}")
            [[ -e ${komari_identity_dir} || -L ${komari_identity_dir} ]] \
                || komari_identity_created=yes
            if prepared_identity_dir=$(prepare_komari_identity_guard "${unit}" "${dropin}"); then
                komari_identity_dir=${prepared_identity_dir}
                TX_KOMARI_IDENTITY_DIR=${komari_identity_dir}
                TX_KOMARI_IDENTITY_CREATED=${komari_identity_created}
                printf 'ExecStartPre=+%s/guard %s/config\n' \
                    "${komari_identity_dir}" "${komari_identity_dir}" >>"${tmp}"
            else
                identity_rc=$?
                if (( identity_rc != 3 )); then
                    echo 'Komari 身份守卫更新失败，正在恢复更新前配置。' >&2
                    exit 1
                fi
                komari_identity_dir=
                komari_identity_created=no
            fi
        fi
        chmod 0644 "${tmp}"

        TX_DROPIN_MAY_CHANGE=yes
        mv "${tmp}" "${dropin_file}"
        if ! systemctl daemon-reload; then
            echo 'systemd 重新载入失败，正在恢复更新前配置。' >&2
            exit 1
        fi
        if [[ ${original_running} == yes ]] && ! restart_and_verify_running "${unit}"; then
            echo '服务未恢复为 active/running，正在恢复更新前配置。' >&2
            exit 1
        fi
        if [[ -n ${compat_dir} && -f ${compat_dir}/go-record ]]; then
            if [[ ${original_running} == yes ]]; then
                reconcile_cf_probe_go_latency_compat "${unit}" "${compat_dir}" \
                    || { echo 'cf-probe 面板动态配置未能安全收敛，正在恢复更新前配置。' >&2; exit 1; }
            fi
            guard_created=$(prepare_cf_probe_go_guard_units "${unit}" "${compat_dir}") \
                || { echo 'cf-probe 动态配置守卫安装失败，正在恢复更新前配置。' >&2; exit 1; }
            TX_CF_GUARD_CREATED=${guard_created}
        fi
        if [[ -n ${compat_dir} ]] \
            && ! commit_cf_probe_go_latency_compat "${compat_dir}"; then
            echo 'cf-probe 已恢复运行，但测速目标事务未能安全提交，正在恢复更新前配置。' >&2
            exit 1
        fi
        # 把转发单元收敛放到最后一个可能失败的阶段；函数自身会恢复旧 unit 与
        # 启用/运行状态，因此它一旦成功，后面只剩事务提交，不再出现半更新窗口。
        if [[ ${forward_active} == yes ]]; then
            reconcile_cf_probe_forward_unit "${unit}" "${dropin}" \
                || { echo 'cf-probe 转发单元未能收敛到当前版本，正在恢复更新前配置。' >&2; exit 1; }
        fi
        TX_COMMITTED=yes
        trap - EXIT INT TERM HUP
        rm -f "${backup}"
        if is_komari_service "${unit}"; then
            remove_legacy_komari_latency_compat "${state}" "${unit}" \
                || { echo '代理配置已更新，但旧版 Komari 延迟转发未能安全清理。' >&2; exit 1; }
        fi
        if [[ ${original_running} == yes ]]; then
            echo "已更新 ${unit} 的代理例外地址，服务保持 active/running。"
        else
            echo "已更新 ${unit} 的代理例外地址，服务保持原停止状态。"
        fi
        [[ -z ${compat_dir} ]] \
            || if [[ -f ${compat_dir}/go-record ]]; then
                echo '已确认 Go cf-probe 使用未封禁的国内直连测速端口。'
            else
                echo '已确认 cf-probe 保留延迟检测，并优先以国内入口真实来源上报。'
            fi
        [[ -z ${komari_identity_dir} ]] \
            || echo '已确认 Komari 自动发现身份有效性守卫。'
        ;;
    set-report-ip|clear-report-ip)
        mode=${1}
        unit=${2:-}
        requested_ip=${3:-}
        [[ -n ${unit} ]] || { usage; exit 2; }
        valid_helper_service_unit "${unit}" \
            || { echo '服务名必须是合法的 .service 单元名。' >&2; exit 2; }
        if [[ ${mode} == set-report-ip ]]; then
            [[ -n ${requested_ip} ]] || { usage; exit 2; }
            public_helper_ipv4 "${requested_ip}" \
                || { echo '自定义上报 IPv4 必须是有效的公网地址。' >&2; exit 2; }
        fi
        state=$(helper_active_state)
        acquire_service_lock "${state}"
        confirm_helper_state_open "${state}" \
            || { echo '安装状态正在关闭或已经变化，拒绝修改服务。' >&2; exit 1; }
        dropin="/etc/systemd/system/${unit}.d"
        dropin_file="${dropin}/90-po0-unlock-proxy.conf"
        [[ -f ${state}/managed-services ]] && grep -Fxq -- "${unit}" "${state}/managed-services" \
            || { echo '该服务不在本助手的托管清单中，拒绝修改上报 IP。' >&2; exit 1; }
        managed_dropin_owned "${dropin_file}" \
            || { echo '代理文件不存在或已被人工修改，拒绝修改上报 IP。' >&2; exit 1; }
        is_komari_service "${unit}" \
            || { echo '自定义上报 IP 目前只对 Komari Agent 开放。' >&2; exit 1; }
        current_ip=$(report_ipv4_from_dropin "${dropin_file}" || true)
        if [[ ${mode} == clear-report-ip && -z ${current_ip} ]]; then
            echo "${unit} 当前已经使用自动 IP 检测。"
            exit 0
        fi
        if [[ ${mode} == set-report-ip && ${current_ip} == "${requested_ip}" ]]; then
            echo "${unit} 当前已经上报 ${requested_ip}。"
            exit 0
        fi
        original_running=no
        service_is_running "${unit}" && original_running=yes
        backup=$(mktemp "${state}/.proxy-dropin.XXXXXX")
        tmp=$(mktemp "${dropin}/.90-po0-unlock-proxy.XXXXXX")
        cp -p "${dropin_file}" "${backup}"
        if [[ ${mode} == set-report-ip ]]; then
            write_report_ipv4_dropin "${dropin_file}" "${tmp}" set "${requested_ip}"
        else
            write_report_ipv4_dropin "${dropin_file}" "${tmp}" clear
        fi
        chmod 0644 "${tmp}"

        TX_COMMITTED=no
        TX_UNIT=${unit}
        TX_DROPIN_DIR=${dropin}
        TX_DROPIN_FILE=${dropin_file}
        TX_DROPIN_TMP=${tmp}
        TX_BACKUP=${backup}
        TX_ORIGINAL_RUNNING=${original_running}
        TX_DROPIN_MAY_CHANGE=no
        trap 'refresh_transaction_cleanup "$?"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap 'exit 129' HUP

        TX_DROPIN_MAY_CHANGE=yes
        mv "${tmp}" "${dropin_file}"
        if ! systemctl daemon-reload; then
            echo 'systemd 重新载入失败，正在恢复修改前配置。' >&2
            exit 1
        fi
        if [[ ${original_running} == yes ]] && ! restart_and_verify_running "${unit}"; then
            echo '服务未恢复为 active/running，正在恢复修改前配置。' >&2
            exit 1
        fi
        TX_COMMITTED=yes
        trap - EXIT INT TERM HUP
        rm -f "${backup}"
        if [[ ${mode} == set-report-ip ]]; then
            echo "已让 ${unit} 在面板上报 IPv4 ${requested_ip}。"
        else
            echo "已让 ${unit} 恢复自动检测出口 IPv4。"
        fi
        ;;
    disable-service)
        unit=${2:-}
        [[ -n ${unit} ]] || { usage; exit 2; }
        valid_helper_service_unit "${unit}" \
            || { echo '服务名必须是合法的 .service 单元名。' >&2; exit 2; }
        state=$(helper_active_state)
        acquire_service_lock "${state}"
        confirm_helper_state_open "${state}" \
            || { echo '安装状态正在关闭或已经变化，拒绝修改服务。' >&2; exit 1; }
        dropin="/etc/systemd/system/${unit}.d"
        dropin_file="${dropin}/90-po0-unlock-proxy.conf"
        [[ -f ${state}/managed-services ]] && grep -Fxq -- "${unit}" "${state}/managed-services" \
            || { echo '该服务不在本助手的托管清单中，拒绝删除配置。' >&2; exit 1; }
        dropin_missing=no
        if [[ -e ${dropin_file} || -L ${dropin_file} ]]; then
            managed_dropin_owned "${dropin_file}" \
                || { echo '代理文件已被人工修改，拒绝自动删除。' >&2; exit 1; }
        else
            # 代理文件被外部删除（人工清理、Agent 重装、apt purge）后，本助手没有
            # 可撤销的配置。若继续拒绝，托管记录就再也无法通过产品注销，完整回滚
            # 会永久停在这个单元上。此处按已移除处理，继续清理残留并注销记录。
            dropin_missing=yes
            echo "提醒：${unit} 的国外出口配置文件已不存在，按已移除处理并注销托管记录。"
        fi
        compat_dir=$(cf_probe_compat_dir "${dropin}")
        if [[ -e ${compat_dir} || -L ${compat_dir} ]]; then
            managed_cf_probe_compat_owned "${compat_dir}" \
                || { echo 'cf-probe 兼容文件已被外部修改，拒绝自动删除。' >&2; exit 1; }
        fi
        komari_identity_dir=$(komari_identity_compat_dir "${dropin}")
        if [[ -e ${komari_identity_dir} || -L ${komari_identity_dir} ]]; then
            managed_komari_identity_owned "${komari_identity_dir}" "${unit}" \
                || { echo 'Komari 身份守卫文件已被外部修改，拒绝自动删除。' >&2; exit 1; }
        fi
        original_running=no
        service_is_running "${unit}" && original_running=yes
        backup=$(mktemp "${state}/.proxy-dropin.XXXXXX")
        managed_tmp=$(mktemp "${state}/.managed-services.XXXXXX")
        [[ ${dropin_missing} == yes ]] || cp -p "${dropin_file}" "${backup}"
        grep -Fvx -- "${unit}" "${state}/managed-services" >"${managed_tmp}" || true
        chmod 0600 "${managed_tmp}"

        TX_COMMITTED=no
        TX_UNIT=${unit}
        TX_STATE=${state}
        TX_DROPIN_DIR=${dropin}
        TX_DROPIN_FILE=${dropin_file}
        TX_BACKUP=${backup}
        TX_MANAGED_TMP=${managed_tmp}
        TX_ORIGINAL_RUNNING=${original_running}
        TX_COMPAT_DIR=${compat_dir}
        TX_CF_GO_TARGETS_RESTORED=no
        TX_CF_GUARD_REMOVED=no
        TX_DROPIN_MAY_BE_REMOVED=no
        TX_DROPIN_WAS_MISSING=${dropin_missing}
        TX_LIST_MAY_CHANGE=no
        TX_FORWARD_DROPIN=
        TX_FORWARD_SNAPSHOT=
        TX_FORWARD_MAY_CHANGE=no
        trap 'disable_transaction_cleanup "$?"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap 'exit 129' HUP

        if [[ -e ${compat_dir}/go-record || -L ${compat_dir}/go-record ]] \
            && cf_probe_go_guard_units_present "${unit}"; then
            TX_CF_GUARD_REMOVED=yes
            remove_cf_probe_go_guard_units "${unit}" "${compat_dir}" \
                || { echo '无法安全停用 cf-probe 动态配置守卫，国外出口保持不变。' >&2; exit 1; }
        fi
        TX_DROPIN_MAY_BE_REMOVED=yes
        rm -f "${dropin_file}"
        rmdir "${dropin}" 2>/dev/null || true
        if ! systemctl daemon-reload; then
            echo 'systemd 重新载入失败，正在恢复代理配置。' >&2
            exit 1
        fi
        if [[ -e ${compat_dir}/go-record || -L ${compat_dir}/go-record ]]; then
            restore_cf_probe_go_original_targets "${compat_dir}" \
                || { echo '无法在停用前恢复 cf-probe 原测速目标，正在恢复代理配置。' >&2; exit 1; }
            TX_CF_GO_TARGETS_RESTORED=yes
        fi
        if [[ ${original_running} == yes ]] && ! restart_and_verify_running "${unit}"; then
            echo '移除代理后服务未恢复为 active/running，正在恢复代理配置。' >&2
            exit 1
        fi
        if is_komari_service "${unit}"; then
            remove_legacy_komari_latency_compat "${state}" "${unit}" \
                || { echo '旧版 Komari 延迟转发未能安全清理，正在恢复服务代理。' >&2; exit 1; }
        fi
        if cf_probe_forward_mode_present "${unit}" "${dropin}"; then
            TX_FORWARD_DROPIN=${dropin}
            TX_FORWARD_SNAPSHOT=$(snapshot_cf_probe_forward_state_if_complete \
                "${unit}" "${dropin}" "${state}") \
                || { echo 'cf-probe 转发状态无法建立恢复快照，拒绝拆除。' >&2; exit 1; }
            TX_FORWARD_MAY_CHANGE=yes
            remove_cf_probe_forward_mode "${unit}" "${dropin}" "${TX_FORWARD_SNAPSHOT}" \
                || { echo 'cf-probe 转发模式未能安全拆除，正在恢复服务代理。' >&2; exit 1; }
        fi
        TX_LIST_MAY_CHANGE=yes
        mv "${managed_tmp}" "${state}/managed-services"
        TX_COMMITTED=yes
        trap - EXIT INT TERM HUP
        rm -f "${backup}"
        if [[ -n ${TX_FORWARD_SNAPSHOT} ]]; then
            discard_cf_probe_forward_snapshot "${TX_FORWARD_SNAPSHOT}" \
                || echo "警告：国外出口已移除，但转发事务快照 ${TX_FORWARD_SNAPSHOT} 未能清理。" >&2
        fi
        if [[ -e ${compat_dir} || -L ${compat_dir} ]]; then
            remove_cf_probe_latency_compat "${compat_dir}" \
                || echo '警告：国外出口已移除，但 cf-probe 兼容文件未能清理。' >&2
            rmdir "${dropin}" 2>/dev/null || true
        fi
        if [[ -e ${komari_identity_dir} || -L ${komari_identity_dir} ]]; then
            remove_komari_identity_guard "${komari_identity_dir}" "${unit}" \
                || echo '警告：国外出口已移除，但 Komari 身份守卫未能清理。' >&2
            rmdir "${dropin}" 2>/dev/null || true
        fi
        rmdir "${dropin}" 2>/dev/null || true
        if [[ ${original_running} == yes ]]; then
            echo "已移除 ${unit} 的国外出口，服务保持 active/running。"
        else
            echo "已移除 ${unit} 的国外出口，服务保持原停止状态。"
        fi
        ;;
    *) usage; exit 2 ;;
esac
EOF
