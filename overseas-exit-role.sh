#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STATE_ROOT=/var/lib/po0-unlock
ACTIVE_FILE=${STATE_ROOT}/ACTIVE
KEY_FILE=/root/.ssh/po0-unlock-tunnel
ADMIN_KEY=/root/.ssh/po0-unlock-admin
KNOWN_HOSTS=/root/.ssh/po0-unlock-tunnel.known_hosts
PROXY_CONF=/etc/tinyproxy/po0-unlock-exit-proxy.conf
PROXY_UNIT=/etc/systemd/system/po0-unlock-exit-proxy.service
TUNNEL_UNIT=/etc/systemd/system/po0-unlock-reverse-tunnel.service
TUNNEL_USER=po0tunnel
ROLE_TEMP_FILE_ONE=
ROLE_TEMP_FILE_TWO=
ROLE_STATE_TX_DIR=

log() { printf '[国外出口] %s\n' "$*"; }
die() { printf '[国外出口] 错误：%s\n' "$*" >&2; exit 1; }
require_root() { [[ ${EUID} -eq 0 ]] || die '必须使用 root 运行。'; }

cleanup_role_temp_files_on_exit() {
    local rc=$1 path
    trap - EXIT INT TERM HUP
    set +e
    for path in "${ROLE_TEMP_FILE_ONE:-}" "${ROLE_TEMP_FILE_TWO:-}"; do
        [[ -n ${path} ]] && rm -f -- "${path}"
    done
    if [[ -n ${STATE_ROOT:-} ]]; then
        case "${ROLE_STATE_TX_DIR:-}" in
            "${STATE_ROOT}"/*/.tunnel-state-commit.*)
                printf '警告：隧道连接状态事务未完成，事务备份已保留：%s\n' "${ROLE_STATE_TX_DIR}" >&2
                ;;
        esac
    fi
    exit "${rc}"
}

valid_port() {
    [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_ipv4() {
    local ip=$1 part
    local IFS=.
    local -a parts
    [[ ${ip} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    read -r -a parts <<<"${ip}"
    [[ ${#parts[@]} -eq 4 ]] || return 1
    for part in "${parts[@]}"; do
        [[ ${part} =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#${part} >= 0 && 10#${part} <= 255 )) || return 1
    done
}

local_ipv4_exists() {
    local ip=$1
    ip -4 -o addr show | awk '{sub(/\/.*/, "", $4); print $4}' | grep -Fx -- "${ip}" >/dev/null
}

managed_root_file_safe() {
    local path=$1 expected_mode=$2
    [[ -f ${path} && ! -L ${path} ]] || return 1
    [[ $(stat -c '%u' "${path}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${path}" 2>/dev/null) == "${expected_mode}" \
        && $(stat -c '%h' "${path}" 2>/dev/null) == 1 ]]
}

managed_root_public_key_file_safe() {
    local path=$1
    managed_root_file_safe "${path}" 600 \
        || managed_root_file_safe "${path}" 644
}

protect_tunnel_key_pair() {
    chmod 0600 "${KEY_FILE}" \
        && chmod 0644 "${KEY_FILE}.pub" \
        || die '无法保护国外出口隧道密钥权限。'
    managed_root_file_safe "${KEY_FILE}" 600 \
        && managed_root_file_safe "${KEY_FILE}.pub" 644 \
        || die '国外出口隧道密钥属性异常。'
}

managed_root_directory_safe() {
    local path=$1 expected_mode=$2
    [[ -d ${path} && ! -L ${path} ]] || return 1
    [[ $(stat -c '%u' "${path}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${path}" 2>/dev/null) == "${expected_mode}" ]]
}

prepare_root_directory() {
    local path=$1 label=$2
    if [[ -e ${path} || -L ${path} ]]; then
        managed_root_directory_safe "${path}" 700 \
            || die "${label}不是 root 所有的 0700 普通目录：${path}"
        return 0
    fi
    install -d -o root -g root -m 0700 "${path}" \
        || die "无法创建${label}：${path}"
    managed_root_directory_safe "${path}" 700 \
        || die "${label}创建后属性异常：${path}"
}

create_install_state_directory() {
    local state=$1
    [[ ! -e ${state} && ! -L ${state} ]] \
        || die "安装状态目录已经存在，拒绝复用：${state}"
    install -d -o root -g root -m 0700 "${state}" \
        || die "无法创建安装状态目录：${state}"
    managed_root_directory_safe "${state}" 700 \
        || die "安装状态目录创建后属性异常：${state}"
}

commit_initial_active_state() (
    local state=$1 rc
    INITIAL_ACTIVE_TEMP=
    cleanup_initial_active_state() {
        rc=$?
        trap - EXIT INT TERM HUP
        [[ -z ${INITIAL_ACTIVE_TEMP:-} ]] || rm -f -- "${INITIAL_ACTIVE_TEMP}"
        exit "${rc}"
    }
    trap cleanup_initial_active_state EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    managed_root_directory_safe "${STATE_ROOT}" 700 \
        && managed_root_directory_safe "${state}" 700 \
        || die '安装状态目录属性异常，拒绝写入 ACTIVE。'
    [[ ! -e ${ACTIVE_FILE} && ! -L ${ACTIVE_FILE} ]] \
        || die 'ACTIVE 路径已经存在，拒绝覆盖。'
    INITIAL_ACTIVE_TEMP=$(mktemp "${STATE_ROOT}/.ACTIVE.XXXXXXXX") \
        || die '无法创建 ACTIVE 临时文件。'
    printf '%s\n' "${state}" >"${INITIAL_ACTIVE_TEMP}"
    chmod 0600 "${INITIAL_ACTIVE_TEMP}"
    [[ ! -e ${ACTIVE_FILE} && ! -L ${ACTIVE_FILE} ]] \
        || die 'ACTIVE 路径在提交期间发生变化，拒绝覆盖。'
    mv -fT -- "${INITIAL_ACTIVE_TEMP}" "${ACTIVE_FILE}" \
        || die '无法原子提交 ACTIVE 安装状态。'
    INITIAL_ACTIVE_TEMP=
    managed_root_file_safe "${ACTIVE_FILE}" 600 \
        && [[ $(<"${ACTIVE_FILE}") == "${state}" ]] \
        || die 'ACTIVE 安装状态提交后复核失败。'
    trap - EXIT INT TERM HUP
)

active_state() {
    local state
    managed_root_file_safe "${ACTIVE_FILE}" 600 \
        || die '安装状态标记缺失或属性异常。'
    state=$(<"${ACTIVE_FILE}")
    case "${state}" in "${STATE_ROOT}"/*) ;; *) die '安装状态路径无效。' ;; esac
    [[ -d ${state} && ! -L ${state} \
        && \
        $(stat -c '%u' "${state}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${state}" 2>/dev/null) == 700 ]] \
        || die "状态目录不存在或属性异常：${state}"
    printf '%s\n' "${state}"
}

prepare() {
    local stamp state key_directory path installed_before=no bin_installed_before=no active_before=no enabled_before=no tmp=
    require_root
    [[ ! -e ${ACTIVE_FILE} && ! -L ${ACTIVE_FILE} ]] \
        || die '已经存在安装状态或异常 ACTIVE 路径；请先运行 status 或 rollback。'
    for path in "${KEY_FILE}" "${KEY_FILE}.pub" "${KNOWN_HOSTS}" "${PROXY_CONF}" "${PROXY_UNIT}" "${TUNNEL_UNIT}"; do
        [[ ! -e ${path} && ! -L ${path} ]] \
            || die "目标文件已存在，为避免覆盖而中止：${path}"
    done
    key_directory=${KEY_FILE%/*}
    prepare_root_directory "${STATE_ROOT}" '状态根目录'
    prepare_root_directory "${key_directory}" '隧道密钥目录'

    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    state=${STATE_ROOT}/${stamp}
    create_install_state_directory "${state}"
    if dpkg-query -W -f='${db:Status-Abbrev}' tinyproxy 2>/dev/null | grep -q '^ii'; then
        installed_before=yes
    fi
    if dpkg-query -W -f='${db:Status-Abbrev}' tinyproxy-bin 2>/dev/null | grep -q '^ii'; then
        bin_installed_before=yes
    fi
    if systemctl is-active --quiet tinyproxy.service 2>/dev/null; then active_before=yes; fi
    if systemctl is-enabled --quiet tinyproxy.service 2>/dev/null; then enabled_before=yes; fi
    printf '%s\n' "${installed_before}" >"${state}/tinyproxy-installed-before"
    printf '%s\n' "${bin_installed_before}" >"${state}/tinyproxy-bin-installed-before"
    printf '%s\n' "${active_before}" >"${state}/tinyproxy-active-before"
    printf '%s\n' "${enabled_before}" >"${state}/tinyproxy-enabled-before"
    dpkg-query -W >"${state}/packages-before.txt" 2>&1 || true
    ss -lntup >"${state}/listeners-before.txt" 2>&1 || true
    systemctl list-unit-files >"${state}/unit-files-before.txt" 2>&1 || true
    commit_initial_active_state "${state}"

    if [[ ${installed_before} == no ]]; then systemctl mask tinyproxy.service; fi
    apt-get update
    apt-get install -y tinyproxy
    if [[ ${installed_before} == no ]]; then systemctl unmask tinyproxy.service; fi
    systemctl disable --now tinyproxy.service 2>/dev/null || true

    ROLE_TEMP_FILE_ONE=
    ROLE_TEMP_FILE_TWO=
    trap 'cleanup_role_temp_files_on_exit "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    ROLE_TEMP_FILE_ONE=$(mktemp /tmp/po0-unlock-exit-proxy.XXXXXX) \
        || die '无法创建国外出口代理配置临时文件。'
    tmp=${ROLE_TEMP_FILE_ONE}
    cat >"${tmp}" <<'EOF'
User tinyproxy
Group tinyproxy
Port 3128
Listen 127.0.0.1
Timeout 600
Syslog On
LogLevel Info
MaxClients 100
Allow 127.0.0.1
ViaProxyName "po0-unlock"
EOF
    install -o root -g root -m 0644 "${tmp}" "${PROXY_CONF}"

    cat >"${PROXY_UNIT}" <<EOF
[Unit]
Description=国内入口管理出站 HTTP 代理
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/tinyproxy -d -c ${PROXY_CONF}
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF

    ssh-keygen -q -t ed25519 -N '' -C 'po0-unlock' -f "${KEY_FILE}"
    protect_tunnel_key_pair
    systemctl daemon-reload
    systemctl enable --now po0-unlock-exit-proxy.service
    systemctl is-active --quiet po0-unlock-exit-proxy.service \
        || die '国外出口本地 HTTP 代理启动失败。'
    curl -4 --proxy http://127.0.0.1:3128 -fsS --connect-timeout 8 --max-time 20 \
        -o /dev/null https://deb.debian.org/debian/ \
        || die '国外出口本地 HTTP 代理联网验证失败。'
    rm -f -- "${tmp}" || die '国外出口代理配置临时文件清理失败。'
    tmp=
    ROLE_TEMP_FILE_ONE=
    trap - EXIT INT TERM HUP
    log "代理和隧道密钥已准备，状态目录：${state}"
}

public_key_b64() {
    require_root
    active_state >/dev/null
    base64 -w 0 "${KEY_FILE}.pub"
    printf '\n'
}

remote_tunnel_listeners_ready() {
    local cn_entry_private_ip=$1 cn_entry_ssh_port=$2 exit_private_ip=$3
    /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 \
        -o IdentitiesOnly=yes -o GlobalKnownHostsFile=/dev/null \
        -o UserKnownHostsFile="${KNOWN_HOSTS}" -o StrictHostKeyChecking=yes \
        -b "${exit_private_ip}" -i "${ADMIN_KEY}" -p "${cn_entry_ssh_port}" \
        "root@${cn_entry_private_ip}" \
        "ss -H -lnt | awk '\$4 == \"127.0.0.1:13128\" {http=1} \$4 == \"127.0.0.1:19080\" {socks=1} END {exit !(http && socks)}'"
}

tunnel_forward_ready() {
    local cn_entry_private_ip=$1 cn_entry_ssh_port=$2 exit_private_ip=$3
    local attempt main_pid previous_pid= substate consecutive_ready=0
    for (( attempt = 1; attempt <= 12; attempt++ )); do
        sleep 1
        if ! systemctl is-active --quiet po0-unlock-reverse-tunnel.service; then
            previous_pid=
            consecutive_ready=0
            continue
        fi
        substate=$(systemctl show -p SubState --value \
            po0-unlock-reverse-tunnel.service 2>/dev/null || true)
        main_pid=$(systemctl show -p MainPID --value \
            po0-unlock-reverse-tunnel.service 2>/dev/null || true)
        if [[ ${substate} != running || ! ${main_pid} =~ ^[1-9][0-9]*$ ]]; then
            previous_pid=
            consecutive_ready=0
            continue
        fi
        if [[ -n ${previous_pid} && ${main_pid} != "${previous_pid}" ]]; then
            consecutive_ready=0
        fi
        previous_pid=${main_pid}
        if remote_tunnel_listeners_ready \
            "${cn_entry_private_ip}" "${cn_entry_ssh_port}" "${exit_private_ip}"; then
            consecutive_ready=$((consecutive_ready + 1))
            (( consecutive_ready >= 2 )) && return 0
        else
            consecutive_ready=0
        fi
    done
    return 1
}

restore_reconfigured_tunnel() {
    local backup_dir=$1 state=$2 cn_entry_private_ip cn_entry_ssh_port exit_private_ip
    local backup_tunnel backup_known path
    [[ -d ${backup_dir} && ! -L ${backup_dir} \
        && \
        $(stat -c '%u' "${backup_dir}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${backup_dir}" 2>/dev/null) == 700 ]] || return 1
    backup_tunnel=${backup_dir}/$(basename "${TUNNEL_UNIT}")
    backup_known=${backup_dir}/$(basename "${KNOWN_HOSTS}")
    managed_root_file_safe "${backup_tunnel}" 644 \
        && managed_root_file_safe "${backup_known}" 600 || return 1
    for path in "${TUNNEL_UNIT}" "${KNOWN_HOSTS}"; do
        if [[ -e ${path} || -L ${path} ]]; then
            case "${path}" in
                "${TUNNEL_UNIT}") managed_root_file_safe "${path}" 644 || return 1 ;;
                "${KNOWN_HOSTS}") managed_root_file_safe "${path}" 600 || return 1 ;;
            esac
        fi
    done
    [[ -r ${state}/cn-entry-private-ip \
        && -r ${state}/cn-entry-ssh-port \
        && -r ${state}/overseas-exit-private-ip ]] || return 1
    cn_entry_private_ip=$(<"${state}/cn-entry-private-ip")
    cn_entry_ssh_port=$(<"${state}/cn-entry-ssh-port")
    exit_private_ip=$(<"${state}/overseas-exit-private-ip")
    valid_ipv4 "${cn_entry_private_ip}" \
        && valid_port "${cn_entry_ssh_port}" \
        && valid_ipv4 "${exit_private_ip}" || return 1
    cp -a "${backup_tunnel}" "${TUNNEL_UNIT}" || return 1
    cp -a "${backup_known}" "${KNOWN_HOSTS}" || return 1
    systemctl daemon-reload || return 1
    systemctl restart po0-unlock-reverse-tunnel.service || return 1
    tunnel_forward_ready "${cn_entry_private_ip}" "${cn_entry_ssh_port}" "${exit_private_ip}"
}

tunnel_state_record_safe() {
    local path=$1
    [[ -f ${path} && ! -L ${path} ]] || return 1
    [[ $(stat -c '%u' "${path}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${path}" 2>/dev/null) == 600 \
        && $(stat -c '%h' "${path}" 2>/dev/null) == 1 ]]
}

restore_tunnel_state_record() {
    local state=$1 tx_dir=$2 name=$3 had=$4 path=${1}/${3} restore_tmp=
    if [[ ${had} == yes ]]; then
        restore_tmp=$(mktemp "${path}.restore.XXXXXXXX") || return 1
        if ! install -o root -g root -m 0600 \
            "${tx_dir}/before-${name}" "${restore_tmp}" \
            || ! mv -f -- "${restore_tmp}" "${path}"; then
            rm -f -- "${restore_tmp}"
            return 1
        fi
    else
        rm -f -- "${path}" || return 1
    fi
}

commit_tunnel_state() {
    local state=$1 cn_entry_private_ip=$2 cn_entry_ssh_port=$3 exit_private_ip=$4 configured_at=$5
    local tx_dir path name candidate restore_tmp restore_ok=yes had_cn=no had_port=no had_exit=no had_time=no
    [[ -d ${state} && ! -L ${state} \
        && $(stat -c '%u' "${state}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${state}" 2>/dev/null) == 700 ]] || return 1
    tx_dir=$(mktemp -d "${state}/.tunnel-state-commit.XXXXXXXX") || return 1
    chmod 0700 "${tx_dir}" || { rm -rf -- "${tx_dir}"; return 1; }
    ROLE_STATE_TX_DIR=${tx_dir}

    for name in cn-entry-private-ip cn-entry-ssh-port overseas-exit-private-ip tunnel-configured-at; do
        path=${state}/${name}
        if [[ -e ${path} || -L ${path} ]]; then
            tunnel_state_record_safe "${path}" || { rm -rf -- "${tx_dir}"; ROLE_STATE_TX_DIR=; return 1; }
            cp -p -- "${path}" "${tx_dir}/before-${name}" || {
                rm -rf -- "${tx_dir}"
                ROLE_STATE_TX_DIR=
                return 1
            }
            case "${name}" in
                cn-entry-private-ip) had_cn=yes ;;
                cn-entry-ssh-port) had_port=yes ;;
                overseas-exit-private-ip) had_exit=yes ;;
                tunnel-configured-at) had_time=yes ;;
            esac
        fi
    done

    printf '%s\n' "${cn_entry_private_ip}" >"${tx_dir}/new-cn-entry-private-ip"
    printf '%s\n' "${cn_entry_ssh_port}" >"${tx_dir}/new-cn-entry-ssh-port"
    printf '%s\n' "${exit_private_ip}" >"${tx_dir}/new-overseas-exit-private-ip"
    printf '%s\n' "${configured_at}" >"${tx_dir}/new-tunnel-configured-at"
    for name in cn-entry-private-ip cn-entry-ssh-port overseas-exit-private-ip tunnel-configured-at; do
        candidate=${tx_dir}/new-${name}
        chmod 0600 "${candidate}" || { rm -rf -- "${tx_dir}"; ROLE_STATE_TX_DIR=; return 1; }
        tunnel_state_record_safe "${candidate}" || {
            rm -rf -- "${tx_dir}"
            ROLE_STATE_TX_DIR=
            return 1
        }
    done

    for name in cn-entry-private-ip cn-entry-ssh-port overseas-exit-private-ip tunnel-configured-at; do
        candidate=${tx_dir}/new-${name}
        if ! mv -f -- "${candidate}" "${state}/${name}"; then
            restore_tunnel_state_record "${state}" "${tx_dir}" cn-entry-private-ip "${had_cn}" \
                || restore_ok=no
            restore_tunnel_state_record "${state}" "${tx_dir}" cn-entry-ssh-port "${had_port}" \
                || restore_ok=no
            restore_tunnel_state_record "${state}" "${tx_dir}" overseas-exit-private-ip "${had_exit}" \
                || restore_ok=no
            restore_tunnel_state_record "${state}" "${tx_dir}" tunnel-configured-at "${had_time}" \
                || restore_ok=no
            if [[ ${restore_ok} == yes ]]; then
                rm -rf -- "${tx_dir}"
            else
                printf '警告：隧道连接状态回滚未完成，事务备份已保留：%s\n' "${tx_dir}" >&2
            fi
            ROLE_STATE_TX_DIR=
            return 1
        fi
    done
    rm -rf -- "${tx_dir}" || true
    ROLE_STATE_TX_DIR=
}

configure_tunnel() {
    local mode=$1 expected_fingerprint=${2:-} cn_entry_private_ip=${3:-} cn_entry_ssh_port=${4:-} exit_private_ip=${5:-}
    local state scan_tmp= unit_tmp= actual_fingerprint backup_dir configured_at
    require_root
    state=$(active_state)
    [[ -n ${expected_fingerprint} ]] || die '缺少国内入口 SSH 主机密钥指纹。'
    valid_ipv4 "${cn_entry_private_ip}" || die '国内入口连接 IPv4 地址格式无效。'
    valid_port "${cn_entry_ssh_port}" || die '国内入口 SSH 端口必须是 1–65535。'
    valid_ipv4 "${exit_private_ip}" || die '国外出口源 IPv4 地址格式无效。'
    ip -4 -o addr show | awk '{sub(/\/.*/, "", $4); print $4}' | grep -Fx -- "${exit_private_ip}" >/dev/null \
        || die "国外出口本机不存在地址 ${exit_private_ip}。"
    [[ -r ${KEY_FILE} ]] || die '隧道私钥不存在。'
    [[ -r ${ADMIN_KEY} ]] || die '专用管理密钥不存在，无法验证国内入口反向监听。'
    systemctl is-active --quiet po0-unlock-exit-proxy.service \
        || die '国外出口本地 HTTP 代理未运行。'
    if [[ ${mode} == reconfigure ]]; then
        managed_root_file_safe "${TUNNEL_UNIT}" 644 \
            && managed_root_file_safe "${KNOWN_HOSTS}" 600 \
            || die '现有隧道配置属性异常，不能执行重配置。'
        backup_dir=${state}/reconfigure-$(date -u +%Y%m%dT%H%M%SZ)
        install -d -m 0700 "${backup_dir}"
        cp -a "${TUNNEL_UNIT}" "${KNOWN_HOSTS}" "${backup_dir}/"
    fi

    ROLE_TEMP_FILE_ONE=
    ROLE_TEMP_FILE_TWO=
    trap 'cleanup_role_temp_files_on_exit "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    ROLE_TEMP_FILE_ONE=$(mktemp /tmp/po0-cn-entry-host-key.XXXXXX) \
        || die '无法创建国内入口主机密钥临时文件。'
    scan_tmp=${ROLE_TEMP_FILE_ONE}
    ROLE_TEMP_FILE_TWO=$(mktemp /tmp/po0-unlock-reverse-tunnel-unit.XXXXXX) \
        || die '无法创建反向隧道服务临时文件。'
    unit_tmp=${ROLE_TEMP_FILE_TWO}
    ssh-keyscan -T 8 -t ed25519 -p "${cn_entry_ssh_port}" \
        "${cn_entry_private_ip}" >"${scan_tmp}" 2>/dev/null \
        || die '无法读取国内入口 SSH 主机密钥。'
    actual_fingerprint=$(ssh-keygen -lf "${scan_tmp}" | awk 'NR==1 {print $2}')
    [[ ${actual_fingerprint} == "${expected_fingerprint}" ]] \
        || die "国内入口 SSH 主机指纹不匹配：期望 ${expected_fingerprint}，实际 ${actual_fingerprint}"

    cat >"${unit_tmp}" <<EOF
[Unit]
Description=国外出口到国内入口的反向管理出站隧道
After=network-online.target po0-unlock-exit-proxy.service
Wants=network-online.target
Requires=po0-unlock-exit-proxy.service

[Service]
Type=simple
ExecStart=/usr/bin/ssh -NT -b ${exit_private_ip} -i ${KEY_FILE} -o IdentitiesOnly=yes -o UserKnownHostsFile=${KNOWN_HOSTS} -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -p ${cn_entry_ssh_port} -R 127.0.0.1:13128:127.0.0.1:3128 -R 127.0.0.1:19080 ${TUNNEL_USER}@${cn_entry_private_ip}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    if [[ ${mode} == start ]]; then
        install -o root -g root -m 0600 "${scan_tmp}" "${KNOWN_HOSTS}"
        install -o root -g root -m 0644 "${unit_tmp}" "${TUNNEL_UNIT}"
        systemctl daemon-reload
        if ! systemctl enable --now po0-unlock-reverse-tunnel.service \
            || ! tunnel_forward_ready \
                "${cn_entry_private_ip}" "${cn_entry_ssh_port}" "${exit_private_ip}"; then
            systemctl status po0-unlock-reverse-tunnel.service --no-pager -l || true
            die '反向 SSH 隧道未能建立并确认两个国内入口回环监听。'
        fi
    else
        if ! install -o root -g root -m 0600 "${scan_tmp}" "${KNOWN_HOSTS}" \
            || ! install -o root -g root -m 0644 "${unit_tmp}" "${TUNNEL_UNIT}" \
            || ! systemctl daemon-reload \
            || ! systemctl restart po0-unlock-reverse-tunnel.service \
            || ! tunnel_forward_ready \
                "${cn_entry_private_ip}" "${cn_entry_ssh_port}" "${exit_private_ip}"; then
            systemctl status po0-unlock-reverse-tunnel.service --no-pager -l || true
            if restore_reconfigured_tunnel "${backup_dir}" "${state}"; then
                die "新隧道未能建立并确认远端监听，已恢复旧配置；备份位于 ${backup_dir}。"
            fi
            die "新隧道未能建立并确认远端监听，旧配置也未能自动恢复；请使用备份 ${backup_dir} 人工恢复。"
        fi
    fi
    configured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if ! commit_tunnel_state "${state}" "${cn_entry_private_ip}" "${cn_entry_ssh_port}" \
        "${exit_private_ip}" "${configured_at}"; then
        if [[ ${mode} == reconfigure ]] \
            && restore_reconfigured_tunnel "${backup_dir}" "${state}"; then
            die "隧道已经启动，但连接状态提交失败；已恢复旧配置，备份位于 ${backup_dir}。"
        fi
        die '隧道已经启动，但连接状态提交失败；未能自动恢复旧配置，请检查状态目录和隧道备份。'
    fi
    rm -f -- "${scan_tmp}" "${unit_tmp}" || die '反向隧道临时文件清理失败。'
    scan_tmp=
    unit_tmp=
    ROLE_TEMP_FILE_ONE=
    ROLE_TEMP_FILE_TWO=
    trap - EXIT INT TERM HUP
    if [[ ${mode} == start ]]; then
        log "反向 SSH 隧道已经启动：${cn_entry_private_ip}:${cn_entry_ssh_port}。"
    else
        log "反向 SSH 隧道已经更新：${cn_entry_private_ip}:${cn_entry_ssh_port}。"
    fi
}

start_tunnel() {
    configure_tunnel start "${1:-}" "${2:-}" "${3:-}" "${4:-}"
}

reconfigure_tunnel() {
    configure_tunnel reconfigure "${1:-}" "${2:-}" "${3:-}" "${4:-}"
}

status() {
    require_root
    printf '%s\n' '[国外出口安装状态]'
    if [[ -r ${ACTIVE_FILE} ]]; then printf 'ACTIVE %s\n' "$(<"${ACTIVE_FILE}")"; else printf 'NONE\n'; fi
    printf '%s\n' '[服务]'
    systemctl is-active po0-unlock-exit-proxy.service 2>/dev/null || true
    systemctl is-active po0-unlock-reverse-tunnel.service 2>/dev/null || true
    printf '%s\n' '[本地代理监听]'
    ss -lntp | grep '127.0.0.1:3128' || true
    if [[ -r ${ACTIVE_FILE} ]]; then
        local state
        state=$(active_state)
        if [[ -r ${state}/overseas-exit-private-ip && -r ${state}/cn-entry-private-ip && -r ${state}/cn-entry-ssh-port ]]; then
            printf '[隧道连接端点]\n国外出口=%s 国内入口=%s:%s\n' \
                "$(<"${state}/overseas-exit-private-ip")" \
                "$(<"${state}/cn-entry-private-ip")" "$(<"${state}/cn-entry-ssh-port")"
        fi
    fi
}

health_line() {
    local level=$1 name=$2 detail=$3
    printf '    [%s] %s：%s\n' "${level}" "${name}" "${detail}"
}

health_group() {
    printf '\n  %s\n' "$1"
}

health_safe_state() {
    local state
    managed_root_file_safe "${ACTIVE_FILE}" 600 || return 1
    state=$(<"${ACTIVE_FILE}")
    case "${state}" in "${STATE_ROOT}"/*) ;; *) return 1 ;; esac
    [[ -d ${state} && ! -L ${state} \
        && $(stat -c '%u' "${state}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${state}" 2>/dev/null) == 700 ]] || return 1
    printf '%s\n' "${state}"
}

health_regular_root_file() {
    local path=$1 expected_mode=$2
    managed_root_file_safe "${path}" "${expected_mode}"
}

health() (
    local state= failures=0 exit_ip= cn_ip= cn_port=
    require_root
    health_group '基础状态'

    if state=$(health_safe_state); then
        health_line 正常 '安装记录' '完整'
    else
        health_line 异常 '安装记录' '缺失、损坏或指向了无效目录'
        failures=$((failures + 1))
    fi

    health_group '出口代理'
    if health_regular_root_file "${PROXY_CONF}" 644 \
        && health_regular_root_file "${PROXY_UNIT}" 600 \
        && grep -Fqx -- "ExecStart=/usr/bin/tinyproxy -d -c ${PROXY_CONF}" "${PROXY_UNIT}" \
        && grep -Fqx -- 'Listen 127.0.0.1' "${PROXY_CONF}" \
        && grep -Fqx -- 'Port 3128' "${PROXY_CONF}"; then
        health_line 正常 '国外出口代理配置' '文件完整'
    else
        health_line 异常 '国外出口代理配置' '文件缺失、权限异常或内容已变化'
        failures=$((failures + 1))
    fi

    if systemctl is-active --quiet po0-unlock-exit-proxy.service; then
        health_line 正常 '国外出口代理服务' '正在运行'
    else
        health_line 异常 '国外出口代理服务' '没有运行，可尝试安全修复'
        failures=$((failures + 1))
    fi
    if systemctl is-enabled --quiet po0-unlock-exit-proxy.service; then
        health_line 正常 '代理开机启动' '已启用'
    else
        health_line 异常 '代理开机启动' '未启用，可尝试安全修复'
        failures=$((failures + 1))
    fi
    if ss -H -lnt 2>/dev/null | awk '$4 == "127.0.0.1:3128" {found=1} END {exit !found}'; then
        health_line 正常 '代理监听端口' '仅监听本机'
    else
        health_line 异常 '代理监听端口' '没有发现本机监听'
        failures=$((failures + 1))
    fi
    if curl -4 --proxy http://127.0.0.1:3128 -fsS --connect-timeout 5 --max-time 12 \
        -o /dev/null https://deb.debian.org/debian/; then
        health_line 正常 '国外出口联网' '代理可以访问外部网络'
    else
        health_line 异常 '国外出口联网' '代理无法访问外部网络'
        failures=$((failures + 1))
    fi

    health_group '反向隧道'
    if health_regular_root_file "${TUNNEL_UNIT}" 644 \
        && health_regular_root_file "${KNOWN_HOSTS}" 600 \
        && health_regular_root_file "${KEY_FILE}" 600; then
        health_line 正常 '反向隧道配置' '文件完整'
    else
        health_line 异常 '反向隧道配置' '文件缺失或权限异常'
        failures=$((failures + 1))
    fi
    if systemctl is-active --quiet po0-unlock-reverse-tunnel.service; then
        health_line 正常 '反向隧道服务' '正在运行'
    else
        health_line 异常 '反向隧道服务' '没有运行，可尝试安全修复'
        failures=$((failures + 1))
    fi
    if systemctl is-enabled --quiet po0-unlock-reverse-tunnel.service; then
        health_line 正常 '隧道开机启动' '已启用'
    else
        health_line 异常 '隧道开机启动' '未启用，可尝试安全修复'
        failures=$((failures + 1))
    fi

    if [[ -n ${state} \
        && -r ${state}/overseas-exit-private-ip \
        && -r ${state}/cn-entry-private-ip \
        && -r ${state}/cn-entry-ssh-port ]]; then
        exit_ip=$(<"${state}/overseas-exit-private-ip")
        cn_ip=$(<"${state}/cn-entry-private-ip")
        cn_port=$(<"${state}/cn-entry-ssh-port")
    fi
    health_group '连接路径'
    if valid_ipv4 "${exit_ip}" && valid_ipv4 "${cn_ip}" && valid_port "${cn_port}"; then
        health_line 正常 '连接记录' '地址和端口格式有效'
        if local_ipv4_exists "${exit_ip}" \
            && ip -4 route get "${cn_ip}" from "${exit_ip}" >/dev/null 2>&1; then
            health_line 正常 '连接路由' '国外出口可以找到国内入口'
        else
            health_line 异常 '连接路由' '记录的国外出口地址不存在或路由失效'
            failures=$((failures + 1))
        fi
        if command -v ssh-keyscan >/dev/null \
            && ssh-keyscan -4 -T 3 -p "${cn_port}" "${cn_ip}" >/dev/null 2>&1; then
            health_line 正常 '国内入口 SSH' '已完成 SSH 握手'
        else
            health_line 异常 '国内入口 SSH' '无法完成 SSH 握手'
            failures=$((failures + 1))
        fi
    else
        health_line 异常 '连接记录' '缺失或格式无效'
        failures=$((failures + 1))
    fi

    if (( failures == 0 )); then
        printf '\n%s\n' '  小结：[正常] 国外出口全部检查通过'
        return 0
    fi
    printf '\n  小结：[异常] 国外出口有 %d 项需要处理\n' "${failures}"
    return 1
)

repair_service_state() {
    local unit=$1 original_active=no original_enabled=no
    systemctl is-active --quiet "${unit}" && original_active=yes
    systemctl is-enabled --quiet "${unit}" && original_enabled=yes
    if systemctl daemon-reload \
        && systemctl enable --now "${unit}" \
        && systemctl is-active --quiet "${unit}" \
        && systemctl is-enabled --quiet "${unit}"; then
        return 0
    fi
    [[ ${original_enabled} == yes ]] || systemctl disable "${unit}" >/dev/null 2>&1 || true
    [[ ${original_active} == yes ]] || systemctl stop "${unit}" >/dev/null 2>&1 || true
    return 1
}

restore_service_state() {
    local unit=$1 original_active=$2 original_enabled=$3
    if [[ ${original_enabled} == yes ]]; then
        systemctl enable "${unit}" >/dev/null 2>&1 || return 1
    else
        systemctl disable "${unit}" >/dev/null 2>&1 || return 1
    fi
    if [[ ${original_active} == yes ]]; then
        systemctl start "${unit}" >/dev/null 2>&1 || return 1
    else
        systemctl stop "${unit}" >/dev/null 2>&1 || return 1
    fi
}

repair() {
    local state exit_ip cn_ip cn_port
    local proxy_active=no proxy_enabled=no tunnel_active=no tunnel_enabled=no
    require_root
    state=$(health_safe_state) || die '安装记录异常，不能自动修复。'
    [[ -r ${state}/overseas-exit-private-ip \
        && -r ${state}/cn-entry-private-ip \
        && -r ${state}/cn-entry-ssh-port ]] \
        || die '连接记录不完整，不能自动修复。'
    exit_ip=$(<"${state}/overseas-exit-private-ip")
    cn_ip=$(<"${state}/cn-entry-private-ip")
    cn_port=$(<"${state}/cn-entry-ssh-port")

    health_regular_root_file "${PROXY_CONF}" 644 \
        && health_regular_root_file "${PROXY_UNIT}" 600 \
        && grep -Fqx -- "ExecStart=/usr/bin/tinyproxy -d -c ${PROXY_CONF}" "${PROXY_UNIT}" \
        && grep -Fqx -- 'Listen 127.0.0.1' "${PROXY_CONF}" \
        && grep -Fqx -- 'Port 3128' "${PROXY_CONF}" \
        || die '国外出口代理配置无法确认属于本助手，拒绝自动修复。'

    valid_ipv4 "${exit_ip}" && valid_ipv4 "${cn_ip}" && valid_port "${cn_port}" \
        && health_regular_root_file "${TUNNEL_UNIT}" 644 \
        && health_regular_root_file "${KNOWN_HOSTS}" 600 \
        && health_regular_root_file "${KEY_FILE}" 600 \
        && grep -Fq -- "ExecStart=/usr/bin/ssh -NT -b ${exit_ip} " "${TUNNEL_UNIT}" \
        && grep -Fq -- "-p ${cn_port} -R 127.0.0.1:13128:127.0.0.1:3128 -R 127.0.0.1:19080 ${TUNNEL_USER}@${cn_ip}" \
            "${TUNNEL_UNIT}" \
        || die '反向隧道配置无法确认属于本助手，拒绝自动修复。'

    systemctl is-active --quiet po0-unlock-exit-proxy.service && proxy_active=yes
    systemctl is-enabled --quiet po0-unlock-exit-proxy.service && proxy_enabled=yes
    systemctl is-active --quiet po0-unlock-reverse-tunnel.service && tunnel_active=yes
    systemctl is-enabled --quiet po0-unlock-reverse-tunnel.service && tunnel_enabled=yes

    if repair_service_state po0-unlock-exit-proxy.service \
        && repair_service_state po0-unlock-reverse-tunnel.service; then
        log '国外出口代理与反向隧道服务已经检查并恢复。'
        return 0
    fi
    log '安全修复未全部成功，正在恢复两个核心服务的原状态。'
    restore_service_state po0-unlock-exit-proxy.service "${proxy_active}" "${proxy_enabled}" \
        || log '警告：国外出口代理服务未能完全恢复原状态。'
    restore_service_state po0-unlock-reverse-tunnel.service "${tunnel_active}" "${tunnel_enabled}" \
        || log '警告：反向隧道服务未能完全恢复原状态。'
    return 1
}

remove_managed_file() {
    local path=$1 expected_mode=$2
    if [[ -e ${path} || -L ${path} ]]; then
        managed_root_file_safe "${path}" "${expected_mode}" \
            || die "托管文件属性异常，拒绝删除：${path}"
        rm -f -- "${path}" || die "删除托管文件失败：${path}"
    fi
}

remove_managed_public_key_file() {
    local path=$1
    if [[ -e ${path} || -L ${path} ]]; then
        managed_root_public_key_file_safe "${path}" \
            || die "托管公钥属性异常，拒绝删除：${path}"
        rm -f -- "${path}" || die "删除托管公钥失败：${path}"
    fi
}

rollback() {
    local state installed_before bin_installed_before active_before enabled_before
    require_root
    state=$(active_state)
    installed_before=$(<"${state}/tinyproxy-installed-before")
    bin_installed_before=$(<"${state}/tinyproxy-bin-installed-before")
    active_before=$(<"${state}/tinyproxy-active-before")
    enabled_before=$(<"${state}/tinyproxy-enabled-before")
    systemctl disable --now po0-unlock-reverse-tunnel.service 2>/dev/null || true
    systemctl disable --now po0-unlock-exit-proxy.service 2>/dev/null || true
    remove_managed_file "${TUNNEL_UNIT}" 644
    remove_managed_file "${PROXY_UNIT}" 600
    remove_managed_file "${PROXY_CONF}" 644
    remove_managed_file "${KEY_FILE}" 600
    remove_managed_public_key_file "${KEY_FILE}.pub"
    remove_managed_file "${KNOWN_HOSTS}" 600
    systemctl daemon-reload
    systemctl unmask tinyproxy.service 2>/dev/null || true
    if [[ ${installed_before} == no ]]; then
        apt-get purge -y tinyproxy
    else
        if [[ ${enabled_before} == yes ]]; then systemctl enable tinyproxy.service; fi
        if [[ ${active_before} == yes ]]; then systemctl start tinyproxy.service; fi
    fi
    if [[ ${bin_installed_before} == no ]]; then apt-get purge -y tinyproxy-bin; fi
    date -u +%Y-%m-%dT%H:%M:%SZ >"${state}/rolled-back-at"
    mv "${ACTIVE_FILE}" "${state}/ACTIVE.closed"
    log "国外出口已回滚，历史状态保留在：${state}"
}

case "${1:-}" in
    prepare) prepare ;;
    public-key-b64) public_key_b64 ;;
    start) start_tunnel "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
    reconfigure) reconfigure_tunnel "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
    status) status ;;
    health) health ;;
    repair) repair ;;
    rollback) rollback ;;
    *) die '用法：overseas-exit-role.sh prepare | public-key-b64 | start/reconfigure <国内入口主机指纹> <国内入口连接IPv4> <国内入口SSH端口> <国外出口源IPv4> | status | health | repair | rollback' ;;
esac
