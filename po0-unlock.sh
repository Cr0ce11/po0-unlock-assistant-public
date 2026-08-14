#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# 本脚本必须在国外出口 VPS 上以 root 运行。
SCRIPT_VERSION=2.5.22
SCRIPT_EDITION_LABEL=公开版
resolve_script_path() {
    local source=$1 directory target depth=0
    while [[ -L ${source} ]]; do
        depth=$((depth + 1))
        (( depth <= 20 )) || { printf '%s\n' '脚本符号链接层级过深。' >&2; return 1; }
        directory=$(cd -P -- "$(dirname -- "${source}")" && pwd)
        target=$(readlink "${source}")
        if [[ ${target} == /* ]]; then source=${target}; else source=${directory}/${target}; fi
    done
    directory=$(cd -P -- "$(dirname -- "${source}")" && pwd)
    printf '%s/%s\n' "${directory}" "$(basename -- "${source}")"
}

SCRIPT_PATH=$(resolve_script_path "${BASH_SOURCE[0]}")
SCRIPT_DIR=${SCRIPT_PATH%/*}
PROGRAM_NAME=${SCRIPT_PATH##*/}
CONFIG_DIR=/etc/po0-unlock
CONFIG_FILE=${CONFIG_DIR}/hosts.conf
LEGACY_CONFIG_FILE=/root/hosts.conf
CONFIG_RELOCATION_VERSION=2.4.0
OFFICIAL_SCRIPT_PATH=/usr/local/sbin/po0-unlock
SHORTCUT_PATH=/usr/local/bin/po0
LEGACY_SCRIPT_PATH=/root/po0-unlock.sh
CANONICAL_ENTRY_VERSION=2.3.0
ADMIN_KEY=/root/.ssh/po0-unlock-admin
ADMIN_KNOWN_HOSTS=/root/.ssh/po0-unlock-admin.known_hosts
ADMIN_KNOWN_HOSTS_BACKUP=
CN_ENTRY_REMOTE=/usr/local/libexec/po0-unlock-cn-entry
RUNTIME_DIR=
EXIT_ROLE=
CN_ENTRY_ROLE_LOCAL=
CN_ENTRY_CMD_SCAN=scan-services
CN_ENTRY_CMD_STATUS=status
CN_ENTRY_CMD_HEALTH=health
CN_ENTRY_CMD_ROLLBACK_SERVICES=rollback-services
CN_ENTRY_CMD_ROLLBACK_FINALIZE=rollback-finalize
CN_ENTRY_CMD_CLAIM_STATUS=claim-status
CN_ENTRY_CMD_ROLLBACK_SERVICES_CLAIMED=rollback-services-claimed
CN_ENTRY_CMD_ROLLBACK_FINALIZE_CLAIMED=rollback-finalize-claimed
CN_ENTRY_ACTIVE_FILE=/var/lib/po0-unlock/ACTIVE
CN_ENTRY_OCCUPIED_RC=73
# 单次组件调用按工作量设置独立上限：轻量只读检查 15–30 秒，包含网络
# 检查的健康检查 90 秒，单次配置阶段 120 秒，可能逐项重启 Agent 的阶段 300 秒。
CN_ENTRY_TIMEOUT_CLAIM_STATUS=15
CN_ENTRY_TIMEOUT_STATUS=30
CN_ENTRY_TIMEOUT_HEALTH=90
CN_ENTRY_TIMEOUT_PREPARE=120
CN_ENTRY_TIMEOUT_FINALIZE=120
CN_ENTRY_TIMEOUT_REFRESH=300
CN_ENTRY_TIMEOUT_ROLLBACK_SERVICES=300
CN_ENTRY_TIMEOUT_ROLLBACK_FINALIZE=120
EXIT_CMD_STATUS=status
EXIT_CMD_HEALTH=health
EXIT_CMD_REPAIR=repair
EXIT_CMD_ROLLBACK=rollback
UPDATE_REPOSITORY=Cr0ce11/po0-unlock-assistant-public
UPDATE_ASSET=po0-unlock-v2.sh
UPDATE_API_BASE=https://api.github.com/repos/${UPDATE_REPOSITORY}
UPDATE_STATE_ROOT=/var/lib/po0-unlock/updater
UPDATE_BACKUP_DIR=${UPDATE_STATE_ROOT}/backups
UPDATE_LOCK_FILE=${UPDATE_STATE_ROOT}/update.lock
UPDATE_LAST_BACKUP=${UPDATE_STATE_ROOT}/last-backup
UPDATE_BACKUP_KEEP=3
UPDATE_MAX_BYTES=1048576
DIAGNOSTIC_ROOT=/var/lib/po0-unlock/diagnostics
DIAGNOSTIC_LOG_LINES=80
PO0_STATE_ROOT=/var/lib/po0-unlock
CN_ENTRY_CONTROL_BASE=/run
OPERATION_LOCK_DIR=/run/po0-unlock
OPERATION_LOCK_FILE=${OPERATION_LOCK_DIR}/operation.lock
CN_ENTRY_CONTROL_DIR=
CN_ENTRY_CONTROL_PATH=
CN_ENTRY_ATTEMPT_LOG_NAME=initial-attempts
CN_ENTRY_ATTEMPT_LOG_MAX_BYTES=4096
CURL_BIN=/usr/bin/curl

# 首次运行 configure 时使用的默认值；以后以 hosts.conf 为准。
CN_ENTRY_SSH_USER=root
CN_ENTRY_PRIVATE_IP=
CN_ENTRY_SSH_PORT=22
EXIT_PRIVATE_IP=
RECONFIGURE_CONFIG_BACKUP=
RECONFIGURE_CONFIG_HAD_FILE=no
RECONFIGURE_CONFIG_RESTORE=no

if [[ -t 1 ]]; then
    C_BLUE=$'\033[1;34m'
    C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'
    C_RESET=$'\033[0m'
else
    C_BLUE= C_GREEN= C_YELLOW= C_RESET=
fi

# bash 在 ( ) 子 shell 里会用 trap -p 显示父 shell 的 EXIT 陷阱，但该陷阱在子 shell
# 内并不生效。没有这个标记就无法区分「本层自己装的陷阱」和「继承显示出来的陷阱」，
# 误把后者当成前者串接，会让外层清理在子 shell 退出时提前执行：SSH 主连接被关闭、
# 控制目录被删除、操作锁被提前释放。
PO0_EXIT_TRAP_OWNER=

# 结果写进全局变量而不是打印出来：$( ) 命令替换本身就是子 shell，
# 在 bash 4 以上取到的 BASHPID 与 BASH_SUBSHELL 是替换子 shell 的值，
# 两次调用永远对不上，归属判断会失效。
PO0_EXIT_TRAP_SCOPE=

po0_exit_trap_scope() {
    PO0_EXIT_TRAP_SCOPE="${BASHPID:-$$}.${BASH_SUBSHELL}"
}

po0_claim_exit_trap() {
    po0_exit_trap_scope
    # 该变量只被单文件构建器注入的 install_runtime_exit_trap 读取，
    # 静态分析在 setup.sh 内看不到使用点。
    # shellcheck disable=SC2034
    PO0_EXIT_TRAP_OWNER=${PO0_EXIT_TRAP_SCOPE}
}

# 统一的 EXIT 陷阱安装入口：声明归属，并处理「本层此前已装了内置组件清理陷阱」
# 的情况——直接 trap 会把它覆盖掉，导致组件临时目录无人清理。
po0_install_exit_trap() {
    local handler=$1 existing
    existing=$(trap -p EXIT)
    po0_exit_trap_scope
    if [[ ${existing} == *runtime_exit_cleanup* \
        && ${PO0_EXIT_TRAP_OWNER:-} == "${PO0_EXIT_TRAP_SCOPE}" ]] \
        && declare -F cleanup_runtime >/dev/null 2>&1; then
        cleanup_runtime 0 || true
    fi
    po0_claim_exit_trap
    # 这里要的就是立即展开：handler 是调用方此刻指定的处理函数名。
    # shellcheck disable=SC2064
    trap "${handler}" EXIT
}

log() { printf '%s[Po0 解锁助手]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
die() { printf '[Po0 解锁助手] 错误：%s\n' "$*" >&2; exit 1; }
is_root() { [[ ${EUID} -eq 0 ]]; }
require_root() { is_root || die '请在国外出口 VPS 上使用 root 运行。'; }

cleanup_runtime() {
    local rc=${1:-0} directory=${RUNTIME_DIR:-}
    trap - EXIT INT TERM HUP
    set +e
    [[ -n ${EXIT_ROLE:-} ]] && rm -f -- "${EXIT_ROLE}" "${EXIT_ROLE}.new"
    [[ -n ${CN_ENTRY_ROLE_LOCAL:-} ]] && rm -f -- "${CN_ENTRY_ROLE_LOCAL}" "${CN_ENTRY_ROLE_LOCAL}.new"
    if [[ -n ${directory} ]]; then
        case "${directory}" in
            /tmp/po0-unlock.*)
                rm -f -- "${directory}/po0-cn-entry-helper.self-test.sh"
                rmdir -- "${directory}" 2>/dev/null || true
                ;;
            *) printf '警告：拒绝清理异常临时目录：%s\n' "${directory}" >&2 ;;
        esac
    fi
    RUNTIME_DIR=
    EXIT_ROLE=
    CN_ENTRY_ROLE_LOCAL=
    return "${rc}"
}

runtime_exit_cleanup() {
    local rc=$?
    cleanup_runtime "${rc}" || true
    exit "${rc}"
}

# 当前 shell 已经装了 EXIT 陷阱时，不能直接覆盖：安装、回滚、重配置和各类远端
# 操作都靠自己的 EXIT 陷阱回滚事务与清理 SSH 控制会话。改为串接：先清理内置组件，
# 再把退出码还原成原值并调用原处理函数。
runtime_chain_exit_cleanup() {
    local rc=$? handler=$1
    cleanup_runtime "${rc}" || true
    ( exit "${rc}" )
    "${handler}"
    exit "${rc}"
}

install_runtime_exit_trap() {
    local existing handler
    existing=$(trap -p EXIT)
    # bash 在 ( ) 子 shell 里会用 trap -p 显示父 shell 的陷阱，但它在子 shell 内并不生效。
    # 只有归属标记与当前 shell 层级一致时，才说明这确实是本层自己装的陷阱、可以串接；
    # 否则串接会让外层清理在子 shell 退出时提前执行（关闭 SSH 主连接、释放操作锁）。
    po0_exit_trap_scope
    if [[ -z ${existing} ]] \
        || [[ ${PO0_EXIT_TRAP_OWNER:-} != "${PO0_EXIT_TRAP_SCOPE}" ]]; then
        trap runtime_exit_cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap 'exit 129' HUP
        # 记下归属：之后本层若再安装自己的 EXIT 陷阱，需要据此判断
        # 「要被覆盖掉的组件清理陷阱确实是本层装的」，先释放组件再换。
        PO0_EXIT_TRAP_OWNER=${PO0_EXIT_TRAP_SCOPE}
        return 0
    fi
    handler=${existing#trap -- \'}
    handler=${handler%\' EXIT}
    if [[ ${handler} =~ ^[a-z_][a-z0-9_]*$ ]] && declare -F "${handler}" >/dev/null; then
        # 这里要的就是立即展开：handler 是当前这一刻读到的处理函数名，
        # 留到触发时再解析反而会拿到被后续 trap 覆盖后的值。名字已限定为标识符。
        # shellcheck disable=SC2064
        trap "runtime_chain_exit_cleanup ${handler}" EXIT
        return 0
    fi
    # 无法安全串接时保留外层陷阱：宁可留下临时目录，也不能让事务回滚失效。
    printf '警告：已有退出处理无法安全串接，内置组件临时目录将保留：%s\n' \
        "${RUNTIME_DIR:-未知}" >&2
}

materialize_roles() {
    local exit_new cn_entry_new exit_actual cn_entry_actual
    if [[ -n ${RUNTIME_DIR:-} && -r ${EXIT_ROLE:-} && -r ${CN_ENTRY_ROLE_LOCAL:-} ]]; then
        return 0
    fi
    command -v sha256sum >/dev/null || die '系统缺少 sha256sum，无法校验内置组件。'
    RUNTIME_DIR=$(mktemp -d /tmp/po0-unlock.XXXXXXXX) \
        || die '无法创建内置组件临时目录。'
    chmod 0700 "${RUNTIME_DIR}"
    EXIT_ROLE=${RUNTIME_DIR}/overseas-exit-role.sh
    CN_ENTRY_ROLE_LOCAL=${RUNTIME_DIR}/cn-entry-role.sh
    exit_new=${EXIT_ROLE}.new
    cn_entry_new=${CN_ENTRY_ROLE_LOCAL}.new
    install_runtime_exit_trap

    cat >"${exit_new}" <<'__PO0_OVERSEAS_EXIT_ROLE_783424F8_PAYLOAD__'
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

# 反向隧道单元的 ExecStart 只在这里生成，写入与校验共用同一份，避免两边漂移。
# 其中的主机密钥参数属于安全红线：UserKnownHostsFile 与 StrictHostKeyChecking=yes
# 必须逐字节一致，任何改动都应让安全修复拒绝接管。
tunnel_exec_start_line() {
    local exit_private_ip=$1 cn_entry_private_ip=$2 cn_entry_ssh_port=$3
    printf 'ExecStart=/usr/bin/ssh -NT -b %s -i %s -o IdentitiesOnly=yes -o UserKnownHostsFile=%s -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -p %s -R 127.0.0.1:13128:127.0.0.1:3128 -R 127.0.0.1:19080 %s@%s\n' \
        "${exit_private_ip}" "${KEY_FILE}" "${KNOWN_HOSTS}" "${cn_entry_ssh_port}" \
        "${TUNNEL_USER}" "${cn_entry_private_ip}"
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
$(tunnel_exec_start_line "${exit_private_ip}" "${cn_entry_private_ip}" "${cn_entry_ssh_port}")
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

    if [[ -n ${state} \
        && -r ${state}/overseas-exit-private-ip \
        && -r ${state}/cn-entry-private-ip \
        && -r ${state}/cn-entry-ssh-port ]]; then
        exit_ip=$(<"${state}/overseas-exit-private-ip")
        cn_ip=$(<"${state}/cn-entry-private-ip")
        cn_port=$(<"${state}/cn-entry-ssh-port")
    fi

    health_group '反向隧道'
    if health_regular_root_file "${TUNNEL_UNIT}" 644 \
        && health_regular_root_file "${KNOWN_HOSTS}" 600 \
        && health_regular_root_file "${KEY_FILE}" 600; then
        # 只查权限不查内容时，被人工加过 StrictHostKeyChecking=no 的隧道也会被报成
        # 「文件完整」。这里用与写入时同一份模板重建 ExecStart 并逐行精确比对；
        # 不一致时给出的处置是「重新执行连接更新」——安全修复对这种单元同样会拒绝接管。
        if [[ -n ${exit_ip} && -n ${cn_ip} && -n ${cn_port} ]] \
            && [[ $(grep -c '^ExecStart=' "${TUNNEL_UNIT}") -eq 1 ]] \
            && grep -Fqx -- "$(tunnel_exec_start_line "${exit_ip}" "${cn_ip}" "${cn_port}")" \
                "${TUNNEL_UNIT}"; then
            health_line 正常 '反向隧道配置' '文件完整且启动参数未被改动'
        elif [[ -z ${exit_ip} || -z ${cn_ip} || -z ${cn_port} ]]; then
            health_line 异常 '反向隧道配置' '连接记录缺失，无法核对启动参数'
            failures=$((failures + 1))
        else
            health_line 异常 '反向隧道配置' '启动参数与本助手模板不一致，请重新执行连接更新'
            failures=$((failures + 1))
        fi
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
        && [[ $(grep -c '^ExecStart=' "${TUNNEL_UNIT}") -eq 1 ]] \
        && grep -Fqx -- "$(tunnel_exec_start_line "${exit_ip}" "${cn_ip}" "${cn_port}")" "${TUNNEL_UNIT}" \
        || die '反向隧道配置无法确认属于本助手，拒绝自动修复；如确为本助手所建，请重新执行连接更新。'

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
    local state installed_before bin_installed_before active_before enabled_before closed_marker
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
    # 与国内入口的同一步骤对齐：拒绝覆盖已有封存记录，失败必须中止，
    # 否则重跑回滚会静默盖掉上一份记录，或在封存失败后仍然报告「已回滚」。
    closed_marker=${state}/ACTIVE.closed
    [[ ! -e ${closed_marker} && ! -L ${closed_marker} ]] \
        || die '历史状态中已存在 ACTIVE.closed，拒绝覆盖。'
    mv -- "${ACTIVE_FILE}" "${closed_marker}" \
        || die '最终封存 ACTIVE 状态失败；隧道与密钥已清理，可安全重试完整回滚。'
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
__PO0_OVERSEAS_EXIT_ROLE_783424F8_PAYLOAD__
    cat >"${cn_entry_new}" <<'__PO0_CN_ENTRY_ROLE_018D57A1_PAYLOAD__'
#!/usr/bin/env bash
set -Eeuo pipefail
set +x
umask 077

STATE_ROOT=/var/lib/po0-unlock
ACTIVE_FILE=${STATE_ROOT}/ACTIVE
TUNNEL_USER=po0tunnel
TUNNEL_HOME=/var/lib/po0tunnel
TUNNEL_AUTHORIZED_KEYS=${TUNNEL_HOME}/.ssh/authorized_keys
TUNNEL_KEY_OPTIONS_LEGACY='no-agent-forwarding,no-X11-forwarding,no-pty,permitlisten="127.0.0.1:13128",permitlisten="127.0.0.1:19080"'
TUNNEL_KEY_OPTIONS='restrict,port-forwarding,permitopen="255.255.255.255:9",permitlisten="127.0.0.1:13128",permitlisten="127.0.0.1:19080"'
APT_CONF=/etc/apt/apt.conf.d/90-po0-unlock-proxy
PROFILE_CONF=/etc/profile.d/90-po0-unlock-proxy.sh
HELPER=/usr/local/bin/po0-cn-entry
HTTP_PROXY_URL=http://127.0.0.1:13128
SOCKS_PROXY_URL=socks5h://127.0.0.1:19080
CN_ENTRY_LOCK_WAIT_SECONDS=30

log() { printf '[国内入口] %s\n' "$*"; }
die() { printf '[国内入口] 错误：%s\n' "$*" >&2; exit 1; }
require_root() { [[ ${EUID} -eq 0 ]] || die '必须使用 root 运行。'; }

acquire_state_mutation_lock() {
    local state=$1 purpose=${2:-配置操作}
    [[ ${CN_ENTRY_LOCK_WAIT_SECONDS} =~ ^[1-9][0-9]*$ ]] \
        || die '国内入口写锁等待上限无效。'
    command -v flock >/dev/null \
        || die '系统缺少 flock，无法安全修改配置。'
    exec 9>"${state}/service-proxy.lock" \
        || die "无法打开国内入口写锁，已停止${purpose}。"
    if ! flock -w "${CN_ENTRY_LOCK_WAIT_SECONDS}" 9; then
        die "另一个国内入口配置操作持续占用写锁；等待 ${CN_ENTRY_LOCK_WAIT_SECONDS} 秒后已停止${purpose}，不会在无锁状态下继续修改。若这是完整回滚，请在写锁释放后重新运行完整回滚。"
    fi
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

public_ipv4() {
    local ip=$1 a b c d
    valid_ipv4 "${ip}" || return 1
    IFS=. read -r a b c d <<<"${ip}"
    a=$((10#${a})); b=$((10#${b})); c=$((10#${c})); d=$((10#${d}))
    (( a != 0 && a != 10 && a != 127 && a < 224 )) || return 1
    (( a != 169 || b != 254 )) || return 1
    (( a != 172 || b < 16 || b > 31 )) || return 1
    (( a != 192 || b != 168 )) || return 1
    (( a != 100 || b < 64 || b > 127 )) || return 1
    (( a != 198 || b < 18 || b > 19 )) || return 1
    (( a != 192 || b != 0 || c != 0 )) || return 1
    (( a != 192 || b != 0 || c != 2 )) || return 1
    (( a != 192 || b != 88 || c != 99 )) || return 1
    (( a != 198 || b != 51 || c != 100 )) || return 1
    (( a != 203 || b != 0 || c != 113 )) || return 1
}

valid_service_unit() {
    [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_.@:-]*\.service$ ]]
}

managed_root_file_safe() {
    local path=$1 expected_mode=$2
    [[ -f ${path} && ! -L ${path} ]] || return 1
    [[ $(stat -c '%u' "${path}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${path}" 2>/dev/null) == "${expected_mode}" \
        && $(stat -c '%h' "${path}" 2>/dev/null) == 1 ]]
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
    # 与 health_safe_state 和国外出口的同职责函数保持一致的属主、权限与链接校验：
    # 没有这些校验时，被替换成符号链接的状态目录会让回滚与刷新跟随到状态根之外。
    managed_root_file_safe "${ACTIVE_FILE}" 600 || die '没有找到有效安装状态。'
    state=$(<"${ACTIVE_FILE}")
    case "${state}" in "${STATE_ROOT}"/*) ;; *) die '安装状态路径无效。' ;; esac
    # 收紧到状态根的直接子目录，排除 ../ 穿越。
    [[ ${state%/*} == "${STATE_ROOT}" ]] || die '安装状态路径无效。'
    managed_root_directory_safe "${state}" 700 || die "状态目录异常：${state}"
    printf '%s\n' "${state}"
}

valid_install_claim() {
    [[ ${1:-} =~ ^[0-9a-f]{64}$ ]]
}

install_claim_record_safe() {
    local state=$1 claim_file=${1}/install-claim claim
    managed_root_file_safe "${claim_file}" 600 || return 1
    [[ $(wc -l <"${claim_file}" | tr -d '[:space:]') == 1 ]] || return 1
    IFS= read -r claim <"${claim_file}" || return 1
    valid_install_claim "${claim}"
}

write_install_claim() {
    local state=$1 claim=$2 claim_file=${1}/install-claim
    valid_install_claim "${claim}" || die '安装事务标识格式无效。'
    [[ ! -e ${claim_file} && ! -L ${claim_file} ]] \
        || die '安装状态中已经存在事务标识，拒绝覆盖。'
    (set -o noclobber; printf '%s\n' "${claim}" >"${claim_file}") 2>/dev/null \
        || die '无法写入安装事务标识。'
    chmod 0600 "${claim_file}" \
        || die '无法保护安装事务标识。'
    install_claim_record_safe "${state}" \
        || die '安装事务标识写入后复核失败。'
}

active_install_claim_matches() {
    local expected=${1:-} state claim_file claim
    valid_install_claim "${expected}" || return 1
    state=$(active_state) || return 1
    install_claim_record_safe "${state}" || return 1
    claim_file=${state}/install-claim
    IFS= read -r claim <"${claim_file}" || return 1
    [[ ${claim} == "${expected}" ]]
}

confirm_state_open() {
    local expected_state=$1 current_state=
    [[ -r ${ACTIVE_FILE} ]] || return 1
    current_state=$(<"${ACTIVE_FILE}")
    [[ ${current_state} == "${expected_state}" \
        && -d ${expected_state} && ! -L ${expected_state} \
        && ! -e ${expected_state}/closing && ! -L ${expected_state}/closing ]]
}

safe_tunnel_authorized_keys_path() {
    local tunnel_uid=$1
    [[ ${tunnel_uid} =~ ^[0-9]+$ ]] \
        && [[ -d ${TUNNEL_HOME} && ! -L ${TUNNEL_HOME} ]] \
        && [[ $(stat -c '%u' "${TUNNEL_HOME}" 2>/dev/null) == "${tunnel_uid}" ]] \
        && [[ -d ${TUNNEL_HOME}/.ssh && ! -L ${TUNNEL_HOME}/.ssh ]] \
        && [[ $(stat -c '%u' "${TUNNEL_HOME}/.ssh" 2>/dev/null) == "${tunnel_uid}" \
            && $(stat -c '%a' "${TUNNEL_HOME}/.ssh" 2>/dev/null) == 700 ]] \
        && [[ -f ${TUNNEL_AUTHORIZED_KEYS} && ! -L ${TUNNEL_AUTHORIZED_KEYS} ]] \
        && [[ $(stat -c '%u' "${TUNNEL_AUTHORIZED_KEYS}" 2>/dev/null) == "${tunnel_uid}" \
            && $(stat -c '%a' "${TUNNEL_AUTHORIZED_KEYS}" 2>/dev/null) == 600 \
            && $(stat -c '%h' "${TUNNEL_AUTHORIZED_KEYS}" 2>/dev/null) == 1 ]]
}

tunnel_authorized_keys_hardened() {
    local tunnel_uid=$1 line options public_key
    safe_tunnel_authorized_keys_path "${tunnel_uid}" || return 1
    [[ $(wc -l <"${TUNNEL_AUTHORIZED_KEYS}" | tr -d '[:space:]') == 1 ]] || return 1
    IFS= read -r line <"${TUNNEL_AUTHORIZED_KEYS}" || return 1
    options=${line%% *}
    [[ ${options} == "${TUNNEL_KEY_OPTIONS}" && ${line} != "${options}" ]] || return 1
    public_key=${line#* }
    printf '%s\n' "${public_key}" | ssh-keygen -l -f - >/dev/null 2>&1
}

harden_tunnel_authorized_keys() {
    local tunnel_uid tunnel_gid line options public_key original_hash current_hash tmp
    require_root
    tunnel_uid=$(id -u "${TUNNEL_USER}" 2>/dev/null) \
        || die '无法读取专用隧道账户 UID，拒绝更新授权限制。'
    tunnel_gid=$(id -g "${TUNNEL_USER}" 2>/dev/null) \
        || die '无法读取专用隧道账户 GID，拒绝更新授权限制。'
    safe_tunnel_authorized_keys_path "${tunnel_uid}" \
        || die '专用隧道授权文件路径、属主或权限异常，拒绝自动更新。'
    [[ $(wc -l <"${TUNNEL_AUTHORIZED_KEYS}" | tr -d '[:space:]') == 1 ]] \
        || die '专用隧道授权文件不是唯一一条密钥记录，拒绝自动更新。'
    IFS= read -r line <"${TUNNEL_AUTHORIZED_KEYS}" \
        || die '无法读取专用隧道授权文件。'
    options=${line%% *}
    [[ ${line} != "${options}" ]] || die '专用隧道授权记录缺少公钥。'
    public_key=${line#* }
    printf '%s\n' "${public_key}" | ssh-keygen -l -f - >/dev/null 2>&1 \
        || die '专用隧道授权文件中的公钥无效。'
    case "${options}" in
        "${TUNNEL_KEY_OPTIONS}")
            tunnel_authorized_keys_hardened "${tunnel_uid}" \
                || die '专用隧道授权限制复核失败。'
            return 0
            ;;
        "${TUNNEL_KEY_OPTIONS_LEGACY}") ;;
        *) die '专用隧道授权限制存在外部修改，拒绝自动覆盖。' ;;
    esac

    original_hash=$(sha256sum "${TUNNEL_AUTHORIZED_KEYS}" | awk '{print $1}') \
        || die '无法读取专用隧道授权文件摘要。'
    tmp=$(mktemp "${TUNNEL_AUTHORIZED_KEYS}.po0.XXXXXXXX") \
        || die '无法创建专用隧道授权临时文件。'
    if ! printf '%s %s\n' "${TUNNEL_KEY_OPTIONS}" "${public_key}" >"${tmp}" \
        || ! chown "${tunnel_uid}:${tunnel_gid}" "${tmp}" \
        || ! chmod 0600 "${tmp}"; then
        rm -f -- "${tmp}"
        die '无法准备专用隧道授权限制更新。'
    fi
    current_hash=$(sha256sum "${TUNNEL_AUTHORIZED_KEYS}" | awk '{print $1}') || {
        rm -f -- "${tmp}"
        die '无法复核专用隧道授权文件摘要。'
    }
    if [[ ${current_hash} != "${original_hash}" ]] \
        || ! mv -f -- "${tmp}" "${TUNNEL_AUTHORIZED_KEYS}"; then
        rm -f -- "${tmp}"
        die '专用隧道授权文件在更新期间发生变化，原文件已保留。'
    fi
    tunnel_authorized_keys_hardened "${tunnel_uid}" \
        || die '专用隧道授权限制更新后复核失败。'
    log '专用隧道密钥已限制为仅可建立两个回环反向转发。'
}

prepare() {
    local public_key_b64=${1:-} install_claim=${2:-}
    local stamp state public_key tunnel_uid path
    require_root
    [[ -n ${public_key_b64} ]] || die '缺少国外出口隧道公钥。'
    valid_install_claim "${install_claim}" || die '缺少有效的安装事务标识。'
    [[ ! -e ${ACTIVE_FILE} && ! -L ${ACTIVE_FILE} ]] \
        || die '已经存在安装状态或异常 ACTIVE 路径；请先运行 status 或 rollback。'
    id "${TUNNEL_USER}" >/dev/null 2>&1 && die "用户 ${TUNNEL_USER} 已存在，为避免覆盖而中止。"
    for path in "${APT_CONF}" "${PROFILE_CONF}" "${HELPER}"; do
        [[ ! -e ${path} && ! -L ${path} ]] \
            || die "目标文件已存在，为避免覆盖而中止：${path}"
    done
    [[ ! -e ${TUNNEL_HOME} && ! -L ${TUNNEL_HOME} ]] \
        || die "专用隧道家目录已经存在，为避免复用而中止：${TUNNEL_HOME}"
    if ! public_key=$(printf '%s' "${public_key_b64}" | base64 -d 2>/dev/null); then
        die '国外出口公钥的 Base64 编码无效。'
    fi
    [[ -n ${public_key} && ${public_key} != *$'\n'* && ${public_key} != *$'\r'* ]] \
        || die '国外出口公钥必须是唯一一条非空记录。'
    printf '%s\n' "${public_key}" | ssh-keygen -l -f - >/dev/null 2>&1 \
        || die '国外出口公钥格式无效。'

    prepare_root_directory "${STATE_ROOT}" '状态根目录'
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    state=${STATE_ROOT}/${stamp}
    create_install_state_directory "${state}"
    write_install_claim "${state}" "${install_claim}"
    sysctl -a >"${state}/sysctl-before.txt" 2>&1 || true
    tc -s qdisc show >"${state}/qdisc-before.txt" 2>&1 || true
    ss -lntup >"${state}/listeners-before.txt" 2>&1 || true
    systemctl list-unit-files >"${state}/unit-files-before.txt" 2>&1 || true
    cp -a /etc/ssh/sshd_config "${state}/sshd_config"
    commit_initial_active_state "${state}"

    useradd --system --create-home --home-dir "${TUNNEL_HOME}" \
        --shell /usr/sbin/nologin "${TUNNEL_USER}"
    install -d -o "${TUNNEL_USER}" -g "${TUNNEL_USER}" -m 0700 "${TUNNEL_HOME}/.ssh"
    printf '%s %s\n' "${TUNNEL_KEY_OPTIONS}" "${public_key}" >"${TUNNEL_AUTHORIZED_KEYS}"
    chown "${TUNNEL_USER}:${TUNNEL_USER}" "${TUNNEL_AUTHORIZED_KEYS}"
    chmod 0600 "${TUNNEL_AUTHORIZED_KEYS}"
    tunnel_uid=$(id -u "${TUNNEL_USER}") \
        || die '无法读取新建专用隧道账户 UID。'
    tunnel_authorized_keys_hardened "${tunnel_uid}" \
        || die '新建专用隧道授权限制复核失败。'

    sshd -t || die 'sshd 配置检查失败。'
    log "隧道账户已准备，状态目录：${state}"
}

write_helper() (
    local no_proxy=$1 tmp
    # 与项目其他事务一致：临时文件登记进 trap，任一步失败或收到信号都不会
    # 在 /tmp 留下 root 属主的残留文件。
    tmp=$(mktemp /tmp/po0-cn-entry-helper.XXXXXX) \
        || die '无法创建国内入口管理组件临时文件。'
    trap 'rm -f -- "${tmp}"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    cat >"${tmp}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
set +x
umask 077

HTTP_PROXY_URL=http://127.0.0.1:13128
SOCKS_PROXY_URL=socks5h://127.0.0.1:19080
MANAGED_MARKER='# Managed by Po0 Unlock; do not edit manually.'
KOMARI_IDENTITY_MARKER='# Managed by Po0 Komari identity guard; do not edit manually.'
KOMARI_IDENTITY_BACKUP_DIR=/root/komari-identity-backups

valid_helper_service_unit() {
    [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_.@:-]*\.service$ ]]
}

valid_helper_ipv4() {
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

public_helper_ipv4() {
    local ip=$1 a b c d
    valid_helper_ipv4 "${ip}" || return 1
    IFS=. read -r a b c d <<<"${ip}"
    a=$((10#${a})); b=$((10#${b})); c=$((10#${c})); d=$((10#${d}))
    (( a != 0 && a != 10 && a != 127 && a < 224 )) || return 1
    (( a != 169 || b != 254 )) || return 1
    (( a != 172 || b < 16 || b > 31 )) || return 1
    (( a != 192 || b != 168 )) || return 1
    (( a != 100 || b < 64 || b > 127 )) || return 1
    (( a != 198 || b < 18 || b > 19 )) || return 1
    (( a != 192 || b != 0 || c != 0 )) || return 1
    (( a != 192 || b != 0 || c != 2 )) || return 1
    (( a != 192 || b != 88 || c != 99 )) || return 1
    (( a != 198 || b != 51 || c != 100 )) || return 1
    (( a != 203 || b != 0 || c != 113 )) || return 1
}

write_report_ipv4_dropin() {
    local source=$1 output=$2 mode=$3 requested_ip=${4:-}
    case "${mode}" in
        set) public_helper_ipv4 "${requested_ip}" || return 1 ;;
        clear) ;;
        *) return 2 ;;
    esac
    awk '!/^Environment="AGENT_CUSTOM_IPV4=/' "${source}" >"${output}" || return 1
    if [[ ${mode} == set ]]; then
        printf 'Environment="AGENT_CUSTOM_IPV4=%s"\n' "${requested_ip}" >>"${output}"
    fi
}

is_komari_service() {
    local unit=$1 metadata exec_data exec_path exec_name text
    metadata=$(systemctl show -p Description -p FragmentPath --value -- "${unit}" 2>/dev/null | tr '\n' ' ')
    exec_data=$(systemctl show -p ExecStart --value -- "${unit}" 2>/dev/null || true)
    exec_path=$(sed -n 's/^[[:space:]]*{[[:space:]]*path=\([^ ;}]*\).*/\1/p; q' <<<"${exec_data}")
    exec_name=${exec_path##*/}
    text="${unit,,} ${metadata,,} ${exec_name,,}"
    [[ ${text} == *komari* ]]
}

komari_identity_compat_dir() {
    local dropin=$1
    printf '%s/po0-komari-identity-guard\n' "${dropin}"
}

komari_runtime_identity_config() {
    local unit=$1 pid arg endpoint= auto_discovery= executable= identity=
    local expect= value
    local -a args=()
    pid=$(systemctl show -p MainPID --value -- "${unit}" 2>/dev/null || true)
    [[ ${pid} =~ ^[1-9][0-9]*$ && -r /proc/${pid}/cmdline ]] || return 1
    mapfile -d '' -t args <"/proc/${pid}/cmdline" || return 1
    ((${#args[@]} > 0)) || return 1
    for arg in "${args[@]}"; do
        if [[ -n ${expect} ]]; then
            value=${arg}
            case "${expect}" in
                endpoint) endpoint=${value} ;;
                auto-discovery) auto_discovery=${value} ;;
            esac
            expect=
            continue
        fi
        case "${arg}" in
            -e|--endpoint) expect=endpoint ;;
            --endpoint=*) endpoint=${arg#--endpoint=} ;;
            --auto-discovery) expect=auto-discovery ;;
            --auto-discovery=*) auto_discovery=${arg#--auto-discovery=} ;;
        esac
    done
    [[ -z ${expect} && -n ${auto_discovery} ]] || return 1
    [[ ${endpoint} =~ ^https?://(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+)(:[0-9]{1,5})?(/[A-Za-z0-9._~!$&()*+,;=:@%/-]*)?$ \
        && ${endpoint} != *'/../'* && ${endpoint} != */.. ]] || return 1
    endpoint=${endpoint%/}
    executable=$(readlink -f -- "/proc/${pid}/exe" 2>/dev/null || true)
    [[ ${executable} =~ ^/[A-Za-z0-9_./@+-]+$ \
        && ${executable} != *'/../'* && ${executable} != */.. && ${executable} != *'//' \
        && -x ${executable} && ! -L ${executable} ]] || return 1
    [[ $(readlink -f -- "${executable}" 2>/dev/null || true) == "${executable}" ]] || return 1
    identity=${executable%/*}/auto-discovery.json
    [[ ${identity} =~ ^/[A-Za-z0-9_./@+-]+$ \
        && ${identity} != *'/../'* && ${identity} != */.. && ${identity} != *'//' ]] || return 1
    printf '%s\n%s\n' "${identity}" "${endpoint}"
}

komari_identity_guard_content() {
    cat <<'GUARD'
#!/usr/bin/env bash
# Managed by Po0 Komari identity guard; do not edit manually.
set -Eeuo pipefail
set +x
umask 077

BACKUP_DIR=/root/komari-identity-backups
config=${1:-}
[[ ${config} =~ ^/[A-Za-z0-9_./@+-]+$ && -f ${config} && ! -L ${config} ]] || exit 0
mapfile -t settings < <(sed -n '2,3p' "${config}")
((${#settings[@]} == 2)) || exit 0
identity=${settings[0]}
endpoint=${settings[1]}
[[ ${identity} =~ ^/[A-Za-z0-9_./@+-]+/auto-discovery\.json$ \
    && ${identity} != *'/../'* && ${identity} != */.. && ${identity} != *'//' ]] || exit 0
[[ ${endpoint} =~ ^https?://(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+)(:[0-9]{1,5})?(/[A-Za-z0-9._~!$&()*+,;=:@%/-]*)?$ \
    && ${endpoint} != *'/../'* && ${endpoint} != */.. ]] || exit 0
[[ -e ${identity} || -L ${identity} ]] || exit 0
[[ -f ${identity} && ! -L ${identity} \
    && $(readlink -f -- "${identity}" 2>/dev/null || true) == "${identity}" ]] || exit 0
chmod 0600 -- "${identity}" || exit 0

quarantine_identity() {
    local reason=$1 stamp destination
    install -d -o root -g root -m 0700 "${BACKUP_DIR}" || return 1
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    destination=${BACKUP_DIR}/auto-discovery.json.${reason}.${stamp}.$$
    mv -- "${identity}" "${destination}" || return 1
    chmod 0600 -- "${destination}" || true
    logger -t po0-komari-identity \
        "Komari cached identity was quarantined (${reason}); the agent may register again."
}

work=$(mktemp -d /tmp/po0-komari-identity.XXXXXXXX) || exit 0
cleanup() { rm -rf -- "${work}"; }
trap cleanup EXIT INT TERM HUP
parsed=${work}/identity
parse_rc=0
if command -v jq >/dev/null 2>&1; then
    jq -er '
        if (.uuid | type) == "string" and (.uuid | length) > 0
           and (.token | type) == "string" and (.token | length) > 0
        then .uuid, .token else error("invalid identity") end
    ' "${identity}" >"${parsed}" 2>/dev/null || parse_rc=$?
elif command -v python3 >/dev/null 2>&1; then
    python3 - "${identity}" "${parsed}" <<'PYTHON' || parse_rc=$?
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as source:
    data = json.load(source)
uuid = data.get("uuid")
token = data.get("token")
if not isinstance(uuid, str) or not uuid or "\n" in uuid:
    raise ValueError("invalid uuid")
if not isinstance(token, str) or not token or "\n" in token:
    raise ValueError("invalid token")
with open(sys.argv[2], "w", encoding="utf-8") as target:
    target.write(uuid + "\n" + token + "\n")
PYTHON
else
    logger -t po0-komari-identity \
        'No jq or python3 is available; keeping the cached Komari identity.'
    exit 0
fi
if (( parse_rc != 0 )); then
    quarantine_identity malformed || true
    exit 0
fi
mapfile -t values <"${parsed}"
((${#values[@]} == 2)) || { quarantine_identity malformed || true; exit 0; }
token=${values[1]}
response=${work}/response
tasks_url=${endpoint%/}/api/clients/ping/tasks
http_status=$(
    printf '%s' "${token}" \
        | curl -sS --connect-timeout 5 --max-time 12 \
            -o "${response}" -w '%{http_code}' --get \
            --data-urlencode token@- "${tasks_url}"
) || exit 0
[[ ${http_status} =~ ^2[0-9][0-9]$ ]] && exit 0
[[ ${http_status} == 401 ]] || exit 0

unauthorized=no
if command -v jq >/dev/null 2>&1; then
    jq -e '.status == "error" and .message == "Unauthorized."' \
        "${response}" >/dev/null 2>&1 && unauthorized=yes
else
    python3 - "${response}" <<'PYTHON' >/dev/null 2>&1 && unauthorized=yes
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as source:
    data = json.load(source)
if data.get("status") != "error" or data.get("message") != "Unauthorized.":
    raise SystemExit(1)
PYTHON
fi
[[ ${unauthorized} == yes ]] && quarantine_identity unauthorized || true
exit 0
GUARD
}

managed_komari_identity_owned() {
    local directory=$1 unit=$2 record_unit guard_hash config_hash record_lines
    [[ -d ${directory} && ! -L ${directory} \
        && -f ${directory}/guard && ! -L ${directory}/guard \
        && -f ${directory}/config && ! -L ${directory}/config \
        && -f ${directory}/record && ! -L ${directory}/record ]] || return 1
    grep -Fqx -- "${KOMARI_IDENTITY_MARKER}" "${directory}/guard" || return 1
    record_lines=$(wc -l <"${directory}/record" | tr -d '[:space:]')
    [[ ${record_lines} == 3 ]] || return 1
    record_unit=$(sed -n '1p' "${directory}/record")
    guard_hash=$(sed -n '2p' "${directory}/record")
    config_hash=$(sed -n '3p' "${directory}/record")
    [[ ${record_unit} == "${unit}" \
        && ${guard_hash} =~ ^[0-9a-f]{64}$ && ${config_hash} =~ ^[0-9a-f]{64}$ \
        && $(sha256sum "${directory}/guard" | awk '{print $1}') == "${guard_hash}" \
        && $(sha256sum "${directory}/config" | awk '{print $1}') == "${config_hash}" ]]
}

prepare_komari_identity_guard() {
    local unit=$1 dropin=$2 directory runtime identity endpoint candidate
    directory=$(komari_identity_compat_dir "${dropin}")
    runtime=$(komari_runtime_identity_config "${unit}" || true)
    if [[ -z ${runtime} ]]; then
        if [[ -e ${directory} || -L ${directory} ]]; then
            managed_komari_identity_owned "${directory}" "${unit}" \
                || { echo 'Komari 身份守卫文件已被外部修改，拒绝继续。' >&2; return 1; }
            printf '%s\n' "${directory}"
            return 0
        fi
        echo '未检测到运行中的 Komari --auto-discovery 参数；不会启用身份守卫。' >&2
        return 3
    fi
    identity=$(sed -n '1p' <<<"${runtime}")
    endpoint=$(sed -n '2p' <<<"${runtime}")
    if [[ -e ${directory} || -L ${directory} ]]; then
        managed_komari_identity_owned "${directory}" "${unit}" \
            || { echo 'Komari 身份守卫文件已被外部修改，拒绝覆盖。' >&2; return 1; }
        [[ $(sed -n '2p' "${directory}/config") == "${identity}" \
            && $(sed -n '3p' "${directory}/config") == "${endpoint}" ]] \
            || { echo 'Komari 的程序路径或面板地址已经变化；请先停用再重新启用国外出口。' >&2; return 1; }
        printf '%s\n' "${directory}"
        return 0
    fi
    candidate=$(mktemp -d "${dropin}/.po0-komari-identity.XXXXXXXX") || return 1
    chmod 0700 "${candidate}"
    komari_identity_guard_content >"${candidate}/guard"
    printf '%s\n%s\n%s\n' "${KOMARI_IDENTITY_MARKER}" "${identity}" "${endpoint}" \
        >"${candidate}/config"
    printf '%s\n%s\n%s\n' "${unit}" \
        "$(sha256sum "${candidate}/guard" | awk '{print $1}')" \
        "$(sha256sum "${candidate}/config" | awk '{print $1}')" >"${candidate}/record"
    chmod 0700 "${candidate}/guard"
    chmod 0600 "${candidate}/config" "${candidate}/record"
    mv -- "${candidate}" "${directory}"
    managed_komari_identity_owned "${directory}" "${unit}" || return 1
    printf '%s\n' "${directory}"
}

remove_komari_identity_guard() {
    local directory=$1 unit=$2
    [[ -e ${directory} || -L ${directory} ]] || return 0
    managed_komari_identity_owned "${directory}" "${unit}" \
        || { echo 'Komari 身份守卫文件已被外部修改，拒绝自动删除。' >&2; return 1; }
    rm -f -- "${directory}/guard" "${directory}/config" "${directory}/record"
    rmdir -- "${directory}"
}

is_cf_probe_service() {
    local unit=$1 metadata text
    metadata=$(systemctl show -p Description -p FragmentPath -p ExecStart --value -- "${unit}" 2>/dev/null | tr '\n' ' ')
    text="${unit,,} ${metadata,,}"
    [[ ${text} == *cf-probe* || ${text} == *'cf server monitor probe'* ]]
}

cf_probe_script_path() {
    local unit=$1 pid arg resolved
    local -a args=()
    pid=$(systemctl show -p MainPID --value -- "${unit}" 2>/dev/null || true)
    [[ ${pid} =~ ^[1-9][0-9]*$ && -r /proc/${pid}/cmdline ]] || return 1
    mapfile -d '' -t args <"/proc/${pid}/cmdline" || return 1
    for arg in "${args[@]}"; do
        case "${arg}" in
            /*/cf-probe.sh)
                [[ ${arg} =~ ^/[A-Za-z0-9_./@+-]+$ && ${arg} != *'/../'* \
                    && ${arg} != */.. && ${arg} != *'//' ]] || return 1
                [[ -f ${arg} && ! -L ${arg} ]] || return 1
                resolved=$(readlink -f -- "${arg}" 2>/dev/null || true)
                [[ ${resolved} == "${arg}" ]] || return 1
                printf '%s\n' "${arg}"
                return 0
                ;;
        esac
    done
    return 1
}

cf_probe_has_icmp_fallback() {
    local unit=$1 script
    script=$(cf_probe_script_path "${unit}") || return 1
    grep -Fq 'icmp_out=$(ping -c "$count" -W 2 "$host" 2>/dev/null)' "${script}" \
        && grep -Fq 'echo "$avg_rtt $loss"' "${script}"
}

CF_PROBE_FALLBACK_CT=61.153.34.8:53
CF_PROBE_FALLBACK_CU=210.33.80.8:53
CF_PROBE_FALLBACK_CM=210.32.68.3:53
CF_PROBE_FALLBACK_BD=121.192.44.254:53
CF_PROBE_GO_MARKER='# Managed by Po0: CF Probe Go native latency targets v1.'
CF_PROBE_GO_PENDING_MARKER='# Managed by Po0: pending CF Probe Go latency transaction v1.'
CF_PROBE_GO_GUARD_MARKER='# Managed by Po0 Unlock: CF Probe dynamic target guard v1.'
CF_PROBE_GO_SUPPORTED_REVISIONS=(
    3f059d30cc303cba7c9e802f06c7613f621fad0f
    9be2cf70fa5a1ff0e15f79d39b3a6b05f82ec7ff
    3e45aea8b5d0d7b4dd9871114460d29420a178fe
    921edbf104cef96a02c24199c364d4c91b2bfa58
    6ec57acffc428ae8b480d71d52d066ac62066d2b
    440930f816a7e2b78c33e6d9e208b270a8217c9b
    9e92a7876a82d1df923362955feb19c9fc09d02e
)

cf_probe_go_binary_family() {
    local file=$1
    [[ -f ${file} && ! -L ${file} ]] || return 1
    grep -aFq 'github.com/huilang-me/cfsm-agent/cmd/cf-probe' "${file}"
}

cf_probe_go_binary_contract() {
    local file=$1 revision
    cf_probe_go_binary_family "${file}" \
        && grep -aFq 'X-Agent-Config-Md5' "${file}" \
        && grep -aFq 'CT_NODE' "${file}" \
        || return 1
    for revision in "${CF_PROBE_GO_SUPPORTED_REVISIONS[@]}"; do
        grep -aFq "${revision}" "${file}" && return 0
    done
    return 1
}

cf_probe_go_executable_path() {
    local unit=$1 pid=${2:-} exe
    [[ -n ${pid} ]] \
        || pid=$(systemctl show -p MainPID --value -- "${unit}" 2>/dev/null || true)
    [[ ${pid} =~ ^[1-9][0-9]*$ && -r /proc/${pid}/cmdline ]] || return 1
    exe=$(readlink -f -- "/proc/${pid}/exe" 2>/dev/null || true)
    [[ ${exe} =~ ^/[A-Za-z0-9_./@+-]+$ && ${exe} != *'/../'* \
        && ${exe} != */.. && ${exe} != *'//' ]] || return 1
    [[ -f ${exe} && ! -L ${exe} ]] || return 1
    printf '%s\n' "${exe}"
}

cf_probe_go_config_path() {
    local unit=$1 pid exe arg next_is_config=no config=/etc/config/cf-probe/config.conf resolved
    local -a args=()
    pid=$(systemctl show -p MainPID --value -- "${unit}" 2>/dev/null || true)
    [[ ${pid} =~ ^[1-9][0-9]*$ && -r /proc/${pid}/cmdline ]] || return 1
    exe=$(cf_probe_go_executable_path "${unit}" "${pid}") || return 1
    cf_probe_go_binary_contract "${exe}" || return 1
    mapfile -d '' -t args <"/proc/${pid}/cmdline" || return 1
    for arg in "${args[@]}"; do
        if [[ ${next_is_config} == yes ]]; then
            config=${arg}
            next_is_config=no
            continue
        fi
        case "${arg}" in
            -config) next_is_config=yes ;;
            -config=*) config=${arg#-config=} ;;
        esac
    done
    [[ ${next_is_config} == no ]] || return 1
    [[ ${config} =~ ^/[A-Za-z0-9_./@+-]+$ && ${config} != *'/../'* \
        && ${config} != */.. && ${config} != *'//' ]] || return 1
    [[ -f ${config} && ! -L ${config} ]] || return 1
    resolved=$(readlink -f -- "${config}" 2>/dev/null || true)
    [[ ${resolved} == "${config}" ]] || return 1
    [[ $(stat -c '%u' "${config}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${config}" 2>/dev/null) == 600 \
        && $(stat -c '%h' "${config}" 2>/dev/null) == 1 ]] || return 1
    printf '%s\n' "${config}"
}

cf_probe_go_config_value() {
    local config=$1 key=$2 line value
    case "${key}" in CT_NODE|CU_NODE|CM_NODE|BD_NODE) ;; *) return 1 ;; esac
    [[ $(grep -Ec "^${key}=" "${config}" 2>/dev/null || true) == 1 ]] || return 1
    line=$(grep -E "^${key}=" "${config}") || return 1
    value=${line#*=}
    if [[ ${value} == \"*\" && ${#value} -ge 2 ]]; then
        value=${value:1:${#value}-2}
    fi
    [[ ${#value} -le 255 && ${value} != *$'\n'* && ${value} != *$'\r'* \
        && ${value} != *'"'* && ${value} != *'\\'* ]] || return 1
    [[ -z ${value} ]] || grep -Eq '^[][A-Za-z0-9_.:%+*?-]+$' <<<"${value}" || return 1
    printf '%s\n' "${value}"
}

cf_probe_split_target() {
    local target=$1 host= port=
    if [[ ${target} =~ ^\[([0-9A-Fa-f:]+)\]:([0-9]+)$ ]]; then
        host=${BASH_REMATCH[1]}
        port=${BASH_REMATCH[2]}
    elif [[ ${target} =~ ^([A-Za-z0-9_.-]+):([0-9]+)$ ]]; then
        host=${BASH_REMATCH[1]}
        port=${BASH_REMATCH[2]}
    else
        return 1
    fi
    [[ -n ${host} && ${host} != -* && ${port} =~ ^[0-9]+$ ]] || return 1
    (( 10#${port} >= 1 && 10#${port} <= 65535 )) || return 1
    printf '%s\t%s\n' "${host}" "$((10#${port}))"
}

cf_probe_target_uses_allowed_port() {
    local target=$1 split port
    split=$(cf_probe_split_target "${target}") || return 1
    port=${split#*$'\t'}
    case "${port}" in 80|443|1080|8000|8080|8443) return 1 ;; esac
}

cf_probe_target_connectable() {
    local target=$1 split host port
    split=$(cf_probe_split_target "${target}") || return 1
    host=${split%%$'\t'*}
    port=${split#*$'\t'}
    command -v timeout >/dev/null || return 1
    timeout --kill-after=1s 4s /bin/bash -c 'exec 3<>/dev/tcp/$1/$2' \
        po0-cf-probe "${host}" "${port}" 2>/dev/null
}

cf_probe_write_go_targets() {
    local config=$1 ct=$2 cu=$3 cm=$4 bd=$5 directory key tmp=
    [[ -f ${config} && ! -L ${config} ]] || return 1
    [[ $(stat -c '%u' "${config}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${config}" 2>/dev/null) == 600 \
        && $(stat -c '%h' "${config}" 2>/dev/null) == 1 ]] || return 1
    for key in CT_NODE CU_NODE CM_NODE BD_NODE; do
        [[ $(grep -Ec "^${key}=" "${config}" 2>/dev/null || true) == 1 ]] || return 1
    done
    directory=${config%/*}
    tmp=$(mktemp "${directory}/.po0-cf-probe-config.XXXXXXXX") || return 1
    if ! awk -v ct="${ct}" -v cu="${cu}" -v cm="${cm}" -v bd="${bd}" '
        /^CT_NODE=/ { print "CT_NODE=\"" ct "\""; next }
        /^CU_NODE=/ { print "CU_NODE=\"" cu "\""; next }
        /^CM_NODE=/ { print "CM_NODE=\"" cm "\""; next }
        /^BD_NODE=/ { print "BD_NODE=\"" bd "\""; next }
        { print }
    ' "${config}" >"${tmp}" \
        || ! chmod 0600 "${tmp}" \
        || ! chown root:root "${tmp}" \
        || ! cmp -s <(grep -Ev '^(CT_NODE|CU_NODE|CM_NODE|BD_NODE)=' "${config}") \
            <(grep -Ev '^(CT_NODE|CU_NODE|CM_NODE|BD_NODE)=' "${tmp}") \
        || ! mv -f -- "${tmp}" "${config}"; then
        rm -f -- "${tmp}"
        return 1
    fi
}

cf_probe_go_record_value() {
    local file=$1 key=$2 line
    [[ $(grep -Ec "^${key}=" "${file}" 2>/dev/null || true) == 1 ]] || return 1
    line=$(grep -E "^${key}=" "${file}") || return 1
    printf '%s\n' "${line#*=}"
}

cf_probe_valid_record_target() {
    local value=$1
    [[ ${#value} -le 255 && ${value} != *$'\n'* && ${value} != *$'\r'* \
        && ${value} != *'='* && ${value} != *'"'* && ${value} != *'\\'* ]] || return 1
    [[ -z ${value} ]] || grep -Eq '^[][A-Za-z0-9_.:%+*?-]+$' <<<"${value}"
}

managed_cf_probe_go_record() {
    local file=$1 marker config key value extra
    [[ -f ${file} && ! -L ${file} ]] || return 1
    [[ $(stat -c '%u' "${file}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${file}" 2>/dev/null) == 600 \
        && $(stat -c '%h' "${file}" 2>/dev/null) == 1 ]] || return 1
    IFS= read -r marker <"${file}" || return 1
    [[ ${marker} == "${CF_PROBE_GO_MARKER}" ]] || return 1
    [[ $(wc -l <"${file}" | tr -d ' ') == 10 ]] || return 1
    config=$(cf_probe_go_record_value "${file}" CONFIG_PATH) || return 1
    [[ ${config} =~ ^/[A-Za-z0-9_./@+-]+$ && ${config} != *'/../'* \
        && ${config} != */.. && ${config} != *'//' ]] || return 1
    for key in ORIGINAL_CT ORIGINAL_CU ORIGINAL_CM ORIGINAL_BD MANAGED_CT MANAGED_CU MANAGED_CM MANAGED_BD; do
        value=$(cf_probe_go_record_value "${file}" "${key}") || return 1
        cf_probe_valid_record_target "${value}" || return 1
    done
    extra=$(sed -n '11p' "${file}")
    [[ -z ${extra} ]]
}

managed_cf_probe_go_pending() {
    local file=$1 marker config previous key value
    [[ -f ${file} && ! -L ${file} ]] || return 1
    [[ $(stat -c '%u' "${file}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${file}" 2>/dev/null) == 600 \
        && $(stat -c '%h' "${file}" 2>/dev/null) == 1 ]] || return 1
    IFS= read -r marker <"${file}" || return 1
    [[ ${marker} == "${CF_PROBE_GO_PENDING_MARKER}" ]] || return 1
    [[ $(wc -l <"${file}" | tr -d ' ') == 7 ]] || return 1
    config=$(cf_probe_go_record_value "${file}" CONFIG_PATH) || return 1
    [[ ${config} =~ ^/[A-Za-z0-9_./@+-]+$ && ${config} != *'/../'* \
        && ${config} != */.. && ${config} != *'//' ]] || return 1
    previous=$(cf_probe_go_record_value "${file}" PREVIOUS_RECORD) || return 1
    [[ ${previous} == yes || ${previous} == no ]] || return 1
    for key in PREVIOUS_CT PREVIOUS_CU PREVIOUS_CM PREVIOUS_BD; do
        value=$(cf_probe_go_record_value "${file}" "${key}") || return 1
        cf_probe_valid_record_target "${value}" || return 1
    done
}

cf_probe_write_go_record() {
    local file=$1 config=$2 original_ct=$3 original_cu=$4 original_cm=$5 original_bd=$6
    local managed_ct=$7 managed_cu=$8 managed_cm=$9 managed_bd=${10} tmp
    tmp=$(mktemp "${file%/*}/.go-record.XXXXXXXX") || return 1
    if ! printf '%s\n' \
        "${CF_PROBE_GO_MARKER}" \
        "CONFIG_PATH=${config}" \
        "ORIGINAL_CT=${original_ct}" \
        "ORIGINAL_CU=${original_cu}" \
        "ORIGINAL_CM=${original_cm}" \
        "ORIGINAL_BD=${original_bd}" \
        "MANAGED_CT=${managed_ct}" \
        "MANAGED_CU=${managed_cu}" \
        "MANAGED_CM=${managed_cm}" \
        "MANAGED_BD=${managed_bd}" >"${tmp}" \
        || ! chmod 0600 "${tmp}" \
        || ! chown root:root "${tmp}" \
        || ! mv -f -- "${tmp}" "${file}"; then
        rm -f -- "${tmp}"
        return 1
    fi
}

cf_probe_write_go_pending() {
    local file=$1 config=$2 previous_record=$3 ct=$4 cu=$5 cm=$6 bd=$7 tmp
    tmp=$(mktemp "${file%/*}/.go-pending.XXXXXXXX") || return 1
    if ! printf '%s\n' \
        "${CF_PROBE_GO_PENDING_MARKER}" \
        "CONFIG_PATH=${config}" \
        "PREVIOUS_RECORD=${previous_record}" \
        "PREVIOUS_CT=${ct}" \
        "PREVIOUS_CU=${cu}" \
        "PREVIOUS_CM=${cm}" \
        "PREVIOUS_BD=${bd}" >"${tmp}" \
        || ! chmod 0600 "${tmp}" \
        || ! chown root:root "${tmp}" \
        || ! mv -f -- "${tmp}" "${file}"; then
        rm -f -- "${tmp}"
        return 1
    fi
}

rollback_cf_probe_go_latency_compat() {
    local directory=$1 pending=${1}/go-pending record=${1}/go-record previous=${1}/go-record.previous
    local config ct cu cm bd had_record
    [[ ! -e ${pending} && ! -L ${pending} ]] && return 0
    managed_cf_probe_go_pending "${pending}" || return 1
    config=$(cf_probe_go_record_value "${pending}" CONFIG_PATH) || return 1
    had_record=$(cf_probe_go_record_value "${pending}" PREVIOUS_RECORD) || return 1
    ct=$(cf_probe_go_record_value "${pending}" PREVIOUS_CT) || return 1
    cu=$(cf_probe_go_record_value "${pending}" PREVIOUS_CU) || return 1
    cm=$(cf_probe_go_record_value "${pending}" PREVIOUS_CM) || return 1
    bd=$(cf_probe_go_record_value "${pending}" PREVIOUS_BD) || return 1
    cf_probe_write_go_targets "${config}" "${ct}" "${cu}" "${cm}" "${bd}" || return 1
    if [[ ${had_record} == yes ]]; then
        managed_cf_probe_go_record "${previous}" || return 1
        mv -f -- "${previous}" "${record}" || return 1
    else
        rm -f -- "${record}" "${previous}" || return 1
    fi
    rm -f -- "${pending}"
}

commit_cf_probe_go_latency_compat() {
    local directory=$1 pending=${1}/go-pending previous=${1}/go-record.previous
    [[ ! -e ${pending} && ! -L ${pending} ]] && return 0
    managed_cf_probe_go_pending "${pending}" || return 1
    managed_cf_probe_go_record "${directory}/go-record" || return 1
    if [[ -e ${previous} || -L ${previous} ]]; then
        managed_cf_probe_go_record "${previous}" || return 1
    fi
    rm -f -- "${pending}" "${previous}"
}

cf_probe_apply_go_record_targets() {
    local directory=$1 kind=$2 record=${1}/go-record config prefix ct cu cm bd
    managed_cf_probe_go_record "${record}" || return 1
    case "${kind}" in
        original) prefix=ORIGINAL ;;
        managed) prefix=MANAGED ;;
        *) return 1 ;;
    esac
    config=$(cf_probe_go_record_value "${record}" CONFIG_PATH) || return 1
    ct=$(cf_probe_go_record_value "${record}" "${prefix}_CT") || return 1
    cu=$(cf_probe_go_record_value "${record}" "${prefix}_CU") || return 1
    cm=$(cf_probe_go_record_value "${record}" "${prefix}_CM") || return 1
    bd=$(cf_probe_go_record_value "${record}" "${prefix}_BD") || return 1
    cf_probe_write_go_targets "${config}" "${ct}" "${cu}" "${cm}" "${bd}"
}

restore_cf_probe_go_original_targets() {
    cf_probe_apply_go_record_targets "$1" original
}

restore_cf_probe_go_managed_targets() {
    cf_probe_apply_go_record_targets "$1" managed
}

cf_probe_go_record_targets_match() {
    local directory=$1 kind=$2 record=${1}/go-record config prefix key expected actual
    managed_cf_probe_go_record "${record}" || return 1
    case "${kind}" in
        original) prefix=ORIGINAL ;;
        managed) prefix=MANAGED ;;
        *) return 1 ;;
    esac
    config=$(cf_probe_go_record_value "${record}" CONFIG_PATH) || return 1
    for key in CT CU CM BD; do
        expected=$(cf_probe_go_record_value "${record}" "${prefix}_${key}") || return 1
        actual=$(cf_probe_go_config_value "${config}" "${key}_NODE") || return 1
        [[ ${actual} == "${expected}" ]] || return 1
    done
}

reconcile_cf_probe_go_latency_compat() {
    local unit=$1 directory=$2 record=${2}/go-record config observed_config
    managed_cf_probe_go_record "${record}" || return 1
    config=$(cf_probe_go_record_value "${record}" CONFIG_PATH) || return 1
    observed_config=$(cf_probe_go_config_path "${unit}") \
        || { echo '当前 cf-probe 版本或运行配置未通过安全校验，拒绝自动恢复测速目标。' >&2; return 1; }
    [[ ${observed_config} == "${config}" ]] \
        || { echo 'cf-probe 当前配置路径已经变化，拒绝自动恢复测速目标。' >&2; return 1; }
    cf_probe_go_record_targets_match "${directory}" managed && return 0
    restore_cf_probe_go_managed_targets "${directory}" \
        || { echo '无法重新写入 cf-probe 安全测速目标。' >&2; return 1; }
    restart_and_verify_running "${unit}" \
        || { echo '恢复测速目标后 cf-probe 未恢复为 active/running。' >&2; return 1; }
    cf_probe_go_record_targets_match "${directory}" managed \
        || { echo 'cf-probe 重启后测速目标仍被动态配置覆盖。' >&2; return 1; }
}

cf_probe_go_guard_id() {
    local unit=$1 digest
    valid_helper_service_unit "${unit}" || return 1
    digest=$(printf '%s' "${unit}" | sha256sum | awk '{print substr($1,1,16)}') || return 1
    [[ ${digest} =~ ^[0-9a-f]{16}$ ]] || return 1
    printf 'po0-unlock-cf-probe-guard-%s\n' "${digest}"
}

cf_probe_go_systemd_root() {
    printf '%s\n' /etc/systemd/system
}

cf_probe_go_guard_service_file() {
    local id root
    id=$(cf_probe_go_guard_id "$1") || return 1
    root=$(cf_probe_go_systemd_root) || return 1
    printf '%s/%s.service\n' "${root}" "${id}"
}

cf_probe_go_guard_path_file() {
    local id root
    id=$(cf_probe_go_guard_id "$1") || return 1
    root=$(cf_probe_go_systemd_root) || return 1
    printf '%s/%s.path\n' "${root}" "${id}"
}

cf_probe_go_guard_service_content() {
    local unit=$1
    cat <<GUARD_SERVICE
${CF_PROBE_GO_GUARD_MARKER}
[Unit]
Description=Po0 CF Probe dynamic latency target guard for ${unit}
After=${unit}

[Service]
Type=oneshot
ExecStart=/usr/local/bin/po0-cn-entry reconcile-cf-probe ${unit}
GUARD_SERVICE
}

cf_probe_go_guard_path_content() {
    local unit=$1 config=$2 service_file
    service_file=$(cf_probe_go_guard_service_file "${unit}") || return 1
    cat <<GUARD_PATH
${CF_PROBE_GO_GUARD_MARKER}
[Unit]
Description=Watch CF Probe dynamic latency target changes for ${unit}

[Path]
PathChanged=${config}
Unit=${service_file##*/}

[Install]
WantedBy=multi-user.target
GUARD_PATH
}

managed_cf_probe_go_guard_file() {
    local file=$1 expected=$2 actual
    [[ -f ${file} && ! -L ${file} ]] || return 1
    [[ $(stat -c '%u' "${file}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${file}" 2>/dev/null) == 644 \
        && $(stat -c '%h' "${file}" 2>/dev/null) == 1 ]] || return 1
    actual=$(sed -n '1,$p' "${file}") || return 1
    [[ ${actual} == "${expected}" ]]
}

cf_probe_write_go_guard_file() {
    local file=$1 content=$2 directory root tmp
    directory=${file%/*}
    root=$(cf_probe_go_systemd_root) || return 1
    [[ ${directory} == "${root}" && -d ${root} && ! -L ${root} ]] || return 1
    [[ $(stat -c '%u' "${root}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${root}" 2>/dev/null) == 755 ]] || return 1
    tmp=$(mktemp "${directory}/.po0-cf-probe-guard.XXXXXXXX") || return 1
    if ! printf '%s\n' "${content}" >"${tmp}" \
        || ! chmod 0644 "${tmp}" \
        || ! chown root:root "${tmp}" \
        || ! mv -f -- "${tmp}" "${file}"; then
        rm -f -- "${tmp}"
        return 1
    fi
}

cf_probe_go_guard_units_present() {
    local service_file path_file
    service_file=$(cf_probe_go_guard_service_file "$1") || return 1
    path_file=$(cf_probe_go_guard_path_file "$1") || return 1
    [[ -e ${service_file} || -L ${service_file} || -e ${path_file} || -L ${path_file} ]]
}

prepare_cf_probe_go_guard_units() {
    local unit=$1 directory=$2 record=${2}/go-record config service_file path_file
    local service_content path_content service_created=no path_created=no created=no
    managed_cf_probe_go_record "${record}" || return 1
    config=$(cf_probe_go_record_value "${record}" CONFIG_PATH) || return 1
    service_file=$(cf_probe_go_guard_service_file "${unit}") || return 1
    path_file=$(cf_probe_go_guard_path_file "${unit}") || return 1
    service_content=$(cf_probe_go_guard_service_content "${unit}") || return 1
    path_content=$(cf_probe_go_guard_path_content "${unit}" "${config}") || return 1
    if [[ -e ${service_file} || -L ${service_file} ]]; then
        managed_cf_probe_go_guard_file "${service_file}" "${service_content}" || return 1
    else
        cf_probe_write_go_guard_file "${service_file}" "${service_content}" || return 1
        service_created=yes
        created=yes
    fi
    if [[ -e ${path_file} || -L ${path_file} ]]; then
        if ! managed_cf_probe_go_guard_file "${path_file}" "${path_content}"; then
            [[ ${service_created} == no ]] || rm -f -- "${service_file}"
            return 1
        fi
    else
        if ! cf_probe_write_go_guard_file "${path_file}" "${path_content}"; then
            [[ ${service_created} == no ]] || rm -f -- "${service_file}"
            return 1
        fi
        path_created=yes
        created=yes
    fi
    if ! systemctl daemon-reload \
        || ! systemctl enable --now -- "${path_file##*/}" >/dev/null; then
        [[ ${path_created} == no ]] || rm -f -- "${path_file}"
        [[ ${service_created} == no ]] || rm -f -- "${service_file}"
        systemctl daemon-reload >/dev/null 2>&1 || true
        return 1
    fi
    printf '%s\n' "${created}"
}

remove_cf_probe_go_guard_units() {
    local unit=$1 directory=$2 record=${2}/go-record config service_file path_file
    local service_content path_content
    service_file=$(cf_probe_go_guard_service_file "${unit}") || return 1
    path_file=$(cf_probe_go_guard_path_file "${unit}") || return 1
    [[ -e ${service_file} || -L ${service_file} || -e ${path_file} || -L ${path_file} ]] || return 0
    managed_cf_probe_go_record "${record}" || return 1
    config=$(cf_probe_go_record_value "${record}" CONFIG_PATH) || return 1
    service_content=$(cf_probe_go_guard_service_content "${unit}") || return 1
    path_content=$(cf_probe_go_guard_path_content "${unit}" "${config}") || return 1
    [[ ! -e ${service_file} && ! -L ${service_file} ]] \
        || managed_cf_probe_go_guard_file "${service_file}" "${service_content}" || return 1
    [[ ! -e ${path_file} && ! -L ${path_file} ]] \
        || managed_cf_probe_go_guard_file "${path_file}" "${path_content}" || return 1
    if [[ -e ${path_file} || -L ${path_file} ]]; then
        systemctl disable --now -- "${path_file##*/}" >/dev/null 2>&1 || return 1
    fi
    systemctl stop -- "${service_file##*/}" >/dev/null 2>&1 || true
    rm -f -- "${path_file}" "${service_file}" || return 1
    systemctl daemon-reload || return 1
    systemctl reset-failed -- "${path_file##*/}" "${service_file##*/}" >/dev/null 2>&1 || true
}

prepare_cf_probe_go_latency_compat() {
    local unit=$1 dropin=$2 config directory record pending previous directory_created=no had_record=no
    local ct cu cm bd target desired_ct desired_cu desired_cm desired_bd original_ct original_cu original_cm original_bd
    config=$(cf_probe_go_config_path "${unit}") || return 1
    directory=$(cf_probe_compat_dir "${dropin}")
    record=${directory}/go-record
    pending=${directory}/go-pending
    previous=${directory}/go-record.previous
    if [[ -e ${directory} || -L ${directory} ]]; then
        managed_cf_probe_compat_owned "${directory}" || return 1
        if [[ -e ${pending} || -L ${pending} ]]; then
            rollback_cf_probe_go_latency_compat "${directory}" || return 1
        elif [[ -e ${previous} || -L ${previous} ]]; then
            managed_cf_probe_go_record "${previous}" || return 1
            rm -f -- "${previous}" || return 1
        fi
        if [[ -d ${directory} && -z $(find "${directory}" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
            rmdir -- "${directory}" || return 1
        fi
    fi
    ct=$(cf_probe_go_config_value "${config}" CT_NODE) || return 1
    cu=$(cf_probe_go_config_value "${config}" CU_NODE) || return 1
    cm=$(cf_probe_go_config_value "${config}" CM_NODE) || return 1
    bd=$(cf_probe_go_config_value "${config}" BD_NODE) || return 1
    desired_ct=${ct}; desired_cu=${cu}; desired_cm=${cm}; desired_bd=${bd}
    cf_probe_target_uses_allowed_port "${desired_ct}" || desired_ct=${CF_PROBE_FALLBACK_CT}
    cf_probe_target_uses_allowed_port "${desired_cu}" || desired_cu=${CF_PROBE_FALLBACK_CU}
    cf_probe_target_uses_allowed_port "${desired_cm}" || desired_cm=${CF_PROBE_FALLBACK_CM}
    cf_probe_target_uses_allowed_port "${desired_bd}" || desired_bd=${CF_PROBE_FALLBACK_BD}
    for target in "${desired_ct}" "${desired_cu}" "${desired_cm}" "${desired_bd}"; do
        cf_probe_target_uses_allowed_port "${target}" || return 1
    done
    [[ ${desired_ct} == "${ct}" ]] || cf_probe_target_connectable "${desired_ct}" || return 1
    [[ ${desired_cu} == "${cu}" ]] || cf_probe_target_connectable "${desired_cu}" || return 1
    [[ ${desired_cm} == "${cm}" ]] || cf_probe_target_connectable "${desired_cm}" || return 1
    [[ ${desired_bd} == "${bd}" ]] || cf_probe_target_connectable "${desired_bd}" || return 1

    if [[ -e ${directory} || -L ${directory} ]]; then
        managed_cf_probe_compat_owned "${directory}" || return 1
    else
        install -d -m 0755 "${directory}" || return 1
        directory_created=yes
    fi
    if [[ -e ${record} || -L ${record} ]]; then
        managed_cf_probe_go_record "${record}" || return 1
        [[ $(cf_probe_go_record_value "${record}" CONFIG_PATH) == "${config}" ]] || return 1
        original_ct=$(cf_probe_go_record_value "${record}" ORIGINAL_CT) || return 1
        original_cu=$(cf_probe_go_record_value "${record}" ORIGINAL_CU) || return 1
        original_cm=$(cf_probe_go_record_value "${record}" ORIGINAL_CM) || return 1
        original_bd=$(cf_probe_go_record_value "${record}" ORIGINAL_BD) || return 1
        cp -p -- "${record}" "${previous}" || return 1
        had_record=yes
    else
        original_ct=${ct}; original_cu=${cu}; original_cm=${cm}; original_bd=${bd}
    fi
    if ! cf_probe_write_go_pending "${pending}" "${config}" "${had_record}" \
            "${ct}" "${cu}" "${cm}" "${bd}" \
        || ! cf_probe_write_go_targets "${config}" \
            "${desired_ct}" "${desired_cu}" "${desired_cm}" "${desired_bd}" \
        || ! cf_probe_write_go_record "${record}" "${config}" \
            "${original_ct}" "${original_cu}" "${original_cm}" "${original_bd}" \
            "${desired_ct}" "${desired_cu}" "${desired_cm}" "${desired_bd}"; then
        rollback_cf_probe_go_latency_compat "${directory}" 2>/dev/null || true
        if [[ ${directory_created} == yes ]]; then rmdir "${directory}" 2>/dev/null || true; fi
        return 1
    fi
    printf '%s\n' "${directory}"
}

cf_probe_compat_dir() {
    local dropin=$1
    printf '%s/po0-cf-probe-icmp-bin\n' "${dropin}"
}

cf_probe_curl_wrapper_content() {
    cat <<'WRAPPER'
#!/bin/bash
# Managed by Po0: report CF Probe directly on a Cloudflare alternate HTTPS port.
REAL_CURL=${PO0_CF_PROBE_REAL_CURL:-/usr/bin/curl}
original=("$@")
direct=("$@")
is_report=no
target_index=
target_url=

po0_cf_probe_find_report_target() {
    local index
    for index in "${!original[@]}"; do
        case "${original[index]}" in
            X-Agent-Version:*) is_report=yes ;;
            https://*) target_index=${index}; target_url=${original[index]} ;;
        esac
    done
}
po0_cf_probe_find_report_target
unset -f po0_cf_probe_find_report_target

if [[ ${is_report} == yes && -n ${target_index} ]]; then
    remainder=${target_url#https://}
    authority=${remainder%%/*}
    suffix=${remainder#"${authority}"}
    [[ -n ${suffix} ]] || suffix=/
    case "${authority}" in
        *:443) host=${authority%:443} ;;
        *:*) host= ;;
        *) host=${authority} ;;
    esac
    case "${host}" in
        ''|.*|*.|*[!A-Za-z0-9.-]*) host= ;;
    esac
    if [[ -n ${host} ]]; then
        direct[target_index]="https://${host}:8443${suffix}"
        result=$(mktemp "${TMPDIR:-/tmp}/.po0-cf-probe-curl.XXXXXXXX") || result=
        if [[ -n ${result} ]]; then
            if env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
                -u http_proxy -u https_proxy -u all_proxy \
                "${REAL_CURL}" --noproxy '*' "${direct[@]}" >"${result}" 2>/dev/null \
                && grep -Eq '^2[0-9][0-9]$' "${result}"; then
                cat "${result}"
                rm -f -- "${result}"
                exit 0
            fi
            rm -f -- "${result}"
        fi
    fi
fi

exec "${REAL_CURL}" "${original[@]}"
WRAPPER
}

# 归属校验要证明的是"这是本助手的文件、且别人改不了它"，因此权限位不能省。
# 旧版兼容目录的具体权限可能与当前不同，硬钉 0755 会把老部署判成不属于本助手，
# 所以这里只要求 group/other 没有写权限。
cf_probe_compat_mode_safe() {
    local path=$1 mode
    mode=$(stat -c '%a' "${path}" 2>/dev/null) || return 1
    [[ ${mode} =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#${mode} & 8#22) == 0 ))
}

managed_cf_probe_compat_owned() {
    local directory=$1 nc_wrapper=${1}/nc curl_wrapper=${1}/curl go_record=${1}/go-record
    local go_pending=${1}/go-pending go_previous=${1}/go-record.previous expected actual extra=
    [[ -d ${directory} && ! -L ${directory} ]] || return 1
    [[ $(stat -c '%u' "${directory}" 2>/dev/null) == 0 ]] || return 1
    cf_probe_compat_mode_safe "${directory}" || return 1
    if [[ -e ${nc_wrapper} || -L ${nc_wrapper} ]]; then
        [[ -f ${nc_wrapper} && ! -L ${nc_wrapper} && -x ${nc_wrapper} ]] || return 1
        expected=$(printf '%s\n' \
            '#!/bin/sh' \
            '# Managed by Po0: force cf-probe to use its built-in ICMP fallback.' \
            'exit 1')
        actual=$(sed -n '1,$p' "${nc_wrapper}") || return 1
        [[ ${actual} == "${expected}" ]] || return 1
        [[ $(stat -c '%u' "${nc_wrapper}" 2>/dev/null) == 0 \
            && $(stat -c '%h' "${nc_wrapper}" 2>/dev/null) == 1 ]] || return 1
        cf_probe_compat_mode_safe "${nc_wrapper}" || return 1
    else
        [[ -e ${go_record} || -L ${go_record} || -e ${go_pending} || -L ${go_pending} ]] \
            || return 1
    fi
    if [[ -e ${curl_wrapper} || -L ${curl_wrapper} ]]; then
        [[ -e ${nc_wrapper} ]] || return 1
        [[ -f ${curl_wrapper} && ! -L ${curl_wrapper} && -x ${curl_wrapper} ]] || return 1
        expected=$(cf_probe_curl_wrapper_content)
        actual=$(sed -n '1,$p' "${curl_wrapper}") || return 1
        [[ ${actual} == "${expected}" ]] || return 1
        [[ $(stat -c '%u' "${curl_wrapper}" 2>/dev/null) == 0 \
            && $(stat -c '%h' "${curl_wrapper}" 2>/dev/null) == 1 ]] || return 1
        cf_probe_compat_mode_safe "${curl_wrapper}" || return 1
    fi
    if [[ -e ${go_record} || -L ${go_record} ]]; then
        managed_cf_probe_go_record "${go_record}" || return 1
    fi
    if [[ -e ${go_pending} || -L ${go_pending} ]]; then
        managed_cf_probe_go_pending "${go_pending}" || return 1
    fi
    if [[ -e ${go_previous} || -L ${go_previous} ]]; then
        managed_cf_probe_go_record "${go_previous}" || return 1
    fi
    extra=$(find "${directory}" -mindepth 1 -maxdepth 1 \
        ! -name nc ! -name curl ! -name go-record ! -name go-pending \
        ! -name go-record.previous -print -quit 2>/dev/null || true)
    [[ -z ${extra} ]]
}

prepare_cf_probe_latency_compat() {
    local unit=$1 dropin=$2 directory nc_wrapper curl_wrapper nc_tmp= curl_tmp= go_exe=
    if cf_probe_go_config_path "${unit}" >/dev/null 2>&1; then
        prepare_cf_probe_go_latency_compat "${unit}" "${dropin}"
        return
    fi
    go_exe=$(cf_probe_go_executable_path "${unit}" 2>/dev/null || true)
    if [[ -n ${go_exe} ]] && cf_probe_go_binary_family "${go_exe}"; then
        if cf_probe_go_binary_contract "${go_exe}"; then
            echo '已识别受支持的官方 Go cf-probe，但运行参数或配置文件未通过安全校验，已停止配置。' >&2
        else
            echo '当前官方 Go cf-probe 未在 Po0 已审查的正式版本清单中，已停止配置。' >&2
        fi
        return 1
    fi
    command -v ping >/dev/null \
        || { echo '系统缺少 ping，无法为 cf-probe 保留延迟检测。' >&2; return 1; }
    [[ -x /usr/bin/curl ]] \
        || { echo '系统缺少标准 curl，无法为 cf-probe 保留真实上报地区。' >&2; return 1; }
    cf_probe_has_icmp_fallback "${unit}" \
        || { echo '当前 cf-probe 不具备可确认的 ping 回退能力，已停止配置。' >&2; return 1; }
    directory=$(cf_probe_compat_dir "${dropin}")
    nc_wrapper=${directory}/nc
    curl_wrapper=${directory}/curl
    if [[ -e ${directory} || -L ${directory} ]]; then
        managed_cf_probe_compat_owned "${directory}" \
            || { echo 'cf-probe 兼容目录已存在但内容不属于本助手，拒绝覆盖。' >&2; return 1; }
        if [[ ! -e ${curl_wrapper} ]]; then
            curl_tmp=$(mktemp "${directory}/.curl.XXXXXXXX") || return 1
            if ! cf_probe_curl_wrapper_content >"${curl_tmp}" \
                || ! chmod 0755 "${curl_tmp}" \
                || ! mv "${curl_tmp}" "${curl_wrapper}"; then
                rm -f -- "${curl_tmp}"
                return 1
            fi
        fi
        printf '%s\n' "${directory}"
        return 0
    fi
    install -d -m 0755 "${directory}"
    nc_tmp=$(mktemp "${directory}/.nc.XXXXXXXX") || { rmdir "${directory}" 2>/dev/null || true; return 1; }
    if ! printf '%s\n' \
        '#!/bin/sh' \
        '# Managed by Po0: force cf-probe to use its built-in ICMP fallback.' \
        'exit 1' >"${nc_tmp}" \
        || ! chmod 0755 "${nc_tmp}" \
        || ! mv "${nc_tmp}" "${nc_wrapper}"; then
        rm -f -- "${nc_tmp}"
        rmdir "${directory}" 2>/dev/null || true
        return 1
    fi
    curl_tmp=$(mktemp "${directory}/.curl.XXXXXXXX") || {
        rm -f -- "${nc_wrapper}"
        rmdir "${directory}" 2>/dev/null || true
        return 1
    }
    if ! cf_probe_curl_wrapper_content >"${curl_tmp}" \
        || ! chmod 0755 "${curl_tmp}" \
        || ! mv "${curl_tmp}" "${curl_wrapper}"; then
        rm -f -- "${curl_tmp}" "${nc_wrapper}"
        rmdir "${directory}" 2>/dev/null || true
        return 1
    fi
    printf '%s\n' "${directory}"
}

remove_cf_probe_go_latency_compat() {
    local directory=$1 record=${1}/go-record pending=${1}/go-pending previous=${1}/go-record.previous
    [[ ! -e ${record} && ! -L ${record} ]] && return 0
    if [[ -e ${pending} || -L ${pending} ]]; then
        rollback_cf_probe_go_latency_compat "${directory}" || return 1
    fi
    restore_cf_probe_go_original_targets "${directory}" || return 1
    rm -f -- "${record}" "${pending}" "${previous}"
}

remove_cf_probe_latency_compat() {
    local directory=$1
    [[ ! -e ${directory} && ! -L ${directory} ]] && return 0
    managed_cf_probe_compat_owned "${directory}" || return 1
    remove_cf_probe_go_latency_compat "${directory}" || return 1
    rm -f -- "${directory}/nc" "${directory}/curl" && rmdir -- "${directory}"
}

remove_cf_probe_direct_report_compat() {
    local directory=$1
    [[ ! -e ${directory}/curl && ! -L ${directory}/curl ]] && return 0
    managed_cf_probe_compat_owned "${directory}" || return 1
    rm -f -- "${directory}/curl"
}
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

usage() {
    cat <<'USAGE'
用法：
  po0-cn-entry status
  po0-cn-entry test
  po0-cn-entry run <命令> [参数...]
  po0-cn-entry enable-service <systemd-unit>
  po0-cn-entry disable-service <systemd-unit>
  po0-cn-entry set-report-ip <komari-unit> <IPv4>
  po0-cn-entry clear-report-ip <komari-unit>

说明：
  run             仅让本次命令通过国外出口。
  enable-service  为指定服务添加代理环境并重启该服务。
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
        state=$(helper_active_state)
        acquire_service_lock "${state}"
        confirm_helper_state_open "${state}" \
            || { echo '安装状态正在关闭或已经变化，拒绝修改服务。' >&2; exit 1; }
        validate_service_target "${unit}"
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
            compat_dir=$(prepare_cf_probe_latency_compat "${unit}" "${dropin}")
            printf 'Environment="PATH=%s:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\n' \
                "${compat_dir}" >>"${tmp}"
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
            compat_dir=$(prepare_cf_probe_latency_compat "${unit}" "${dropin}")
            printf 'Environment="PATH=%s:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\n' \
                "${compat_dir}" >>"${tmp}"
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
        TX_LIST_MAY_CHANGE=yes
        mv "${managed_tmp}" "${state}/managed-services"
        TX_COMMITTED=yes
        trap - EXIT INT TERM HUP
        rm -f "${backup}"
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
        if [[ ${original_running} == yes ]]; then
            echo "已移除 ${unit} 的国外出口，服务保持 active/running。"
        else
            echo "已移除 ${unit} 的国外出口，服务保持原停止状态。"
        fi
        ;;
    *) usage; exit 2 ;;
esac
EOF
    sed -i "s|__NO_PROXY__|${no_proxy}|g" "${tmp}"
    install -o root -g root -m 0755 "${tmp}" "${HELPER}"
)

write_proxy_files() (
    local state=$1 cn_entry_private_ip=$2 exit_private_ip=$3
    local no_proxy config_tmp= profile_tmp=
    valid_ipv4 "${cn_entry_private_ip}" || die '国内入口连接 IPv4 地址格式无效。'
    valid_ipv4 "${exit_private_ip}" || die '国外出口源 IPv4 地址格式无效。'
    acquire_state_mutation_lock "${state}" '代理配置写入'
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
    acquire_state_mutation_lock "${state}" '服务代理助手更新'
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
                health_line 正常 "Agent ${unit}" '配置完整且正在运行'
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
__PO0_CN_ENTRY_ROLE_018D57A1_PAYLOAD__
    chmod 0600 "${exit_new}" "${cn_entry_new}"
    exit_actual=$(sha256sum "${exit_new}" | awk '{print $1}')
    cn_entry_actual=$(sha256sum "${cn_entry_new}" | awk '{print $1}')
    [[ ${exit_actual} == '25ddcc646b828a0b66f386d4bc55b3fbab3bf41d5d0395ae5bc194bf16fc41f6' ]] || die '国外出口内置组件哈希校验失败。'
    [[ ${cn_entry_actual} == '2155123b023e17e6fa0a2517b9b47b61990278ee3c95834e729f14d406914b58' ]] || die '国内入口内置组件哈希校验失败。'
    /bin/bash -n "${exit_new}" || die '国外出口内置组件语法检查失败。'
    /bin/bash -n "${cn_entry_new}" || die '国内入口内置组件语法检查失败。'
    mv "${exit_new}" "${EXIT_ROLE}"
    mv "${cn_entry_new}" "${CN_ENTRY_ROLE_LOCAL}"
    chmod 0700 "${EXIT_ROLE}" "${CN_ENTRY_ROLE_LOCAL}"
}

extract_embedded_role() {
    materialize_roles
    case "${1:-}" in
        overseas-exit) sed -n '1,$p' "${EXIT_ROLE}" ;;
        cn-entry) sed -n '1,$p' "${CN_ENTRY_ROLE_LOCAL}" ;;
        *) die '用法：__extract-role overseas-exit|cn-entry' ;;
    esac
}

bundle_self_test() {
    local helper_test helper_shebang
    /bin/bash -n "${SCRIPT_PATH}" || die '单文件主控语法检查失败。'
    materialize_roles
    helper_test="${RUNTIME_DIR}/po0-cn-entry-helper.self-test.sh"
    awk 'index($0, "cat >\"${tmp}\" <<\047EOF\047") {f=1; next} f && $0=="EOF" {exit} f {print}'         "${CN_ENTRY_ROLE_LOCAL}" >"${helper_test}"
    [[ -s ${helper_test} ]] || die '未能从国内入口组件提取 po0-cn-entry helper。'
    IFS= read -r helper_shebang <"${helper_test}"
    [[ ${helper_shebang} == '#!/usr/bin/env bash' ]]         || die '国内入口生成的 po0-cn-entry helper 缺少有效 shebang。'
    /bin/bash -n "${helper_test}"         || die '国内入口生成的 po0-cn-entry helper 语法检查失败。'
    rm -f -- "${helper_test}"
    printf 'Po0 单文件版本=%s\n' '2.5.22'
    printf 'Po0 单文件版本类型=%s\n' "${SCRIPT_EDITION_LABEL}"
    printf 'overseas-exit-role SHA-256=%s\n' '25ddcc646b828a0b66f386d4bc55b3fbab3bf41d5d0395ae5bc194bf16fc41f6'
    printf 'cn-entry-role SHA-256=%s\n' '2155123b023e17e6fa0a2517b9b47b61990278ee3c95834e729f14d406914b58'
    printf '%s\n'         "scan-agents -> cn-entry:${CN_ENTRY_CMD_SCAN}"         "rollback[1] -> cn-entry:${CN_ENTRY_CMD_ROLLBACK_SERVICES}"         "rollback[2] -> overseas-exit:${EXIT_CMD_ROLLBACK}"         "rollback[3] -> cn-entry:${CN_ENTRY_CMD_ROLLBACK_FINALIZE}"         "status -> cn-entry:${CN_ENTRY_CMD_STATUS}"         "status -> overseas-exit:${EXIT_CMD_STATUS}"         "health -> cn-entry:${CN_ENTRY_CMD_HEALTH}"         "health -> overseas-exit:${EXIT_CMD_HEALTH}"         "repair -> overseas-exit:${EXIT_CMD_REPAIR}"
    printf '%s\n' 'SELF_TEST=PASS'
}

ui_header() {
    printf '\n%s============================================================%s\n' "${C_BLUE}" "${C_RESET}"
    printf '%s              Po0 解锁助手 v%s（%s）%s\n' \
        "${C_BLUE}" "${SCRIPT_VERSION}" "${SCRIPT_EDITION_LABEL}" "${C_RESET}"
    printf '%s============================================================%s\n' "${C_BLUE}" "${C_RESET}"
}

ui_step() {
    printf '\n%s[%s]%s %s\n' "${C_YELLOW}" "$1" "${C_RESET}" "$2"
}

confirm_yes() {
    local prompt=$1 answer
    if [[ ${ASSUME_YES:-no} == yes ]]; then return 0; fi
    read -r -p "${prompt} [y/N]：" answer
    case "${answer}" in y|Y|yes|YES|是) return 0 ;; *) die '用户取消。' ;; esac
}

valid_release_version() {
    [[ $1 =~ ^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$ ]]
}

version_gt() {
    local left=$1 right=$2 left_major left_minor left_patch right_major right_minor right_patch
    valid_release_version "${left}" && valid_release_version "${right}" || return 1
    IFS=. read -r left_major left_minor left_patch <<<"${left}"
    IFS=. read -r right_major right_minor right_patch <<<"${right}"
    (( 10#${left_major} > 10#${right_major} )) && return 0
    (( 10#${left_major} < 10#${right_major} )) && return 1
    (( 10#${left_minor} > 10#${right_minor} )) && return 0
    (( 10#${left_minor} < 10#${right_minor} )) && return 1
    (( 10#${left_patch} > 10#${right_patch} ))
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

is_private_ipv4() {
    local ip=$1 a b
    local IFS=.
    local -a p
    valid_ipv4 "${ip}" || return 1
    read -r -a p <<<"${ip}"
    a=$((10#${p[0]}))
    b=$((10#${p[1]}))
    (( a == 10 )) && return 0
    (( a == 172 && b >= 16 && b <= 31 )) && return 0
    (( a == 192 && b == 168 )) && return 0
    (( a == 100 && b >= 64 && b <= 127 )) && return 0
    return 1
}

is_public_ipv4() {
    local ip=$1 a b c
    local IFS=.
    local -a p
    valid_ipv4 "${ip}" || return 1
    is_private_ipv4 "${ip}" && return 1
    read -r -a p <<<"${ip}"
    a=$((10#${p[0]}))
    b=$((10#${p[1]}))
    c=$((10#${p[2]}))
    (( a != 0 && a != 127 && a < 224 )) || return 1
    (( a == 169 && b == 254 )) && return 1
    (( a == 192 && b == 0 && (c == 0 || c == 2) )) && return 1
    (( a == 192 && b == 88 && c == 99 )) && return 1
    (( a == 198 && (b == 18 || b == 19) )) && return 1
    (( a == 198 && b == 51 && c == 100 )) && return 1
    (( a == 203 && b == 0 && c == 113 )) && return 1
    return 0
}

ipv4_scope_label() {
    if is_private_ipv4 "$1"; then printf '%s\n' '私网'; else printf '%s\n' '公网'; fi
}

local_ipv4_exists() {
    local ip=$1
    ip -4 -o addr show | awk '{sub(/\/.*/, "", $4); print $4}' | grep -Fx -- "${ip}" >/dev/null
}

private_ipv4_on_device() {
    local device=$1 address
    while IFS= read -r address; do
        is_private_ipv4 "${address}" && printf '%s\n' "${address}"
    done < <(ip -4 -o addr show dev "${device}" scope global | awk '{sub(/\/.*/, "", $4); print $4}')
}

all_private_ipv4() {
    local address
    while IFS= read -r address; do
        is_private_ipv4 "${address}" && printf '%s\n' "${address}"
    done < <(ip -4 -o addr show scope global | awk '{sub(/\/.*/, "", $4); print $4}')
}

detect_exit_source_ip() {
    local peer=$1 route route_source route_device address peer_is_private=no
    local -a candidates=()
    is_private_ipv4 "${peer}" && peer_is_private=yes
    route=$(ip -4 route get "${peer}" 2>/dev/null | sed -n '1p') \
        || die "无法计算到国内入口地址 ${peer} 的路由。"
    [[ -n ${route} ]] || die "没有到国内入口地址 ${peer} 的 IPv4 路由。"
    route_source=$(awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' <<<"${route}")
    route_device=$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<<"${route}")

    if [[ -n ${route_source} ]] && valid_ipv4 "${route_source}" && local_ipv4_exists "${route_source}"; then
        if [[ ${peer_is_private} == no ]] || is_private_ipv4 "${route_source}"; then
            printf '%s\n' "${route_source}"
            return 0
        fi
    fi
    if [[ ${peer_is_private} == yes && -n ${route_device} ]]; then
        candidates=()
        while IFS= read -r address; do
            [[ -n ${address} ]] && candidates[${#candidates[@]}]=${address}
        done < <(private_ipv4_on_device "${route_device}")
        if [[ ${#candidates[@]} -eq 1 ]]; then
            printf '%s\n' "${candidates[0]}"
            return 0
        fi
    fi
    if [[ ${peer_is_private} == yes ]]; then
        candidates=()
        while IFS= read -r address; do
            [[ -n ${address} ]] && candidates[${#candidates[@]}]=${address}
        done < <(all_private_ipv4)
        if [[ ${#candidates[@]} -eq 1 ]]; then
            printf '%s\n' "${candidates[0]}"
            return 0
        fi
        if [[ ${#candidates[@]} -gt 1 ]]; then
            die "发现多个国外出口私网地址，无法安全自动选择：${candidates[*]}"
        fi
    fi
    return 10
}

validate_peer_config() {
    [[ ${CN_ENTRY_SSH_USER} == root ]] || die '国内入口必须允许 root SSH 登录。'
    valid_ipv4 "${CN_ENTRY_PRIVATE_IP}" || die '国内入口连接 IPv4 地址格式无效。'
    { is_private_ipv4 "${CN_ENTRY_PRIVATE_IP}" || is_public_ipv4 "${CN_ENTRY_PRIVATE_IP}"; } \
        || die '国内入口地址必须是受支持的私网或公网 IPv4。'
    valid_port "${CN_ENTRY_SSH_PORT}" || die '国内入口 SSH 端口必须是 1–65535。'
    # 归一化去掉前导零：ssh 与 ssh-keyscan 内部会把 022 当作 22，
    # 若原样保留，known_hosts 的键（[ip]:022）就与实际记录（ip）对不上，
    # 服务器重装后的指纹替换向导将永远无法触发。
    CN_ENTRY_SSH_PORT=$((10#${CN_ENTRY_SSH_PORT}))
}

read_config_file() {
    local file=$1 line value
    local seen_user=no seen_ip=no seen_port=no
    CN_ENTRY_SSH_USER=
    CN_ENTRY_PRIVATE_IP=
    CN_ENTRY_SSH_PORT=
    while IFS= read -r line || [[ -n ${line} ]]; do
        case "${line}" in
            ''|'#'*) continue ;;
            CN_ENTRY_SSH_USER=*)
                [[ ${seen_user} == no ]] || die '连接配置中 CN_ENTRY_SSH_USER 重复。'
                value=${line#CN_ENTRY_SSH_USER=}
                [[ ${value} == root ]] || die '连接配置中的 SSH 用户必须是 root。'
                CN_ENTRY_SSH_USER=${value}
                seen_user=yes
                ;;
            CN_ENTRY_PRIVATE_IP=*)
                [[ ${seen_ip} == no ]] || die '连接配置中 CN_ENTRY_PRIVATE_IP 重复。'
                value=${line#CN_ENTRY_PRIVATE_IP=}
                valid_ipv4 "${value}" || die '连接配置中的国内入口 IPv4 无效。'
                CN_ENTRY_PRIVATE_IP=${value}
                seen_ip=yes
                ;;
            CN_ENTRY_SSH_PORT=*)
                [[ ${seen_port} == no ]] || die '连接配置中 CN_ENTRY_SSH_PORT 重复。'
                value=${line#CN_ENTRY_SSH_PORT=}
                valid_port "${value}" || die '连接配置中的国内入口 SSH 端口无效。'
                CN_ENTRY_SSH_PORT=${value}
                seen_port=yes
                ;;
            *) die '连接配置包含不受支持的字段，已拒绝执行。' ;;
        esac
    done <"${file}"
    [[ ${seen_user} == yes && ${seen_ip} == yes && ${seen_port} == yes ]] \
        || die '连接配置缺少必要字段。'
    validate_peer_config
}

validate_managed_config_file() {
    local file=$1 label=$2 owner mode links
    [[ -f ${file} && ! -L ${file} && -r ${file} ]] \
        || die "${label}不是可安全读取的普通文件：${file}"
    owner=$(stat -c '%u' "${file}") || die "无法读取${label}属主。"
    mode=$(stat -c '%a' "${file}") || die "无法读取${label}权限。"
    links=$(stat -c '%h' "${file}") || die "无法读取${label}链接数。"
    [[ ${owner} == 0 ]] || die "${label}不属于 root，拒绝使用。"
    [[ ${mode} == 600 ]] || die "${label}权限必须是 0600。"
    [[ ${links} == 1 ]] || die "${label}存在异常硬链接，拒绝使用。"
    (read_config_file "${file}") >/dev/null
}

validate_config_directory() {
    local owner mode
    [[ -d ${CONFIG_DIR} && ! -L ${CONFIG_DIR} ]] \
        || die "配置目录不是安全的普通目录：${CONFIG_DIR}"
    owner=$(stat -c '%u' "${CONFIG_DIR}") || die '无法读取配置目录属主。'
    mode=$(stat -c '%a' "${CONFIG_DIR}") || die '无法读取配置目录权限。'
    [[ ${owner} == 0 ]] || die '配置目录不属于 root，拒绝使用。'
    [[ ${mode} == 700 ]] || die '配置目录权限必须是 0700。'
}

prepare_config_directory() {
    if [[ -e ${CONFIG_DIR} || -L ${CONFIG_DIR} ]]; then
        validate_config_directory
        return 0
    fi
    install -d -o root -g root -m 0700 "${CONFIG_DIR}" \
        || die "无法创建配置目录：${CONFIG_DIR}"
    validate_config_directory
}

migrate_legacy_config() {
    local legacy_hash candidate=
    [[ -e ${LEGACY_CONFIG_FILE} || -L ${LEGACY_CONFIG_FILE} ]] || return 0
    validate_managed_config_file "${LEGACY_CONFIG_FILE}" '旧连接配置'
    legacy_hash=$(sha256sum "${LEGACY_CONFIG_FILE}" | awk '{print $1}')
    prepare_config_directory
    if [[ -e ${CONFIG_FILE} || -L ${CONFIG_FILE} ]]; then
        validate_managed_config_file "${CONFIG_FILE}" '新连接配置'
        cmp -s -- "${LEGACY_CONFIG_FILE}" "${CONFIG_FILE}" \
            || die "发现两份内容不同的连接配置；为避免选错，已保留两者并停止：${LEGACY_CONFIG_FILE}、${CONFIG_FILE}"
    else
        candidate=$(mktemp "${CONFIG_DIR}/.hosts.conf.migrate.XXXXXXXX") \
            || die '无法创建连接配置迁移候选。'
        if ! install -o root -g root -m 0600 "${LEGACY_CONFIG_FILE}" "${candidate}" \
            || ! validate_managed_config_file "${candidate}" '连接配置迁移候选' \
            || [[ $(sha256sum "${candidate}" | awk '{print $1}') != "${legacy_hash}" ]] \
            || ! mv -fT -- "${candidate}" "${CONFIG_FILE}"; then
            rm -f -- "${candidate}"
            die '连接配置迁移失败；旧配置仍然保留。'
        fi
        candidate=
    fi
    [[ -f ${LEGACY_CONFIG_FILE} && ! -L ${LEGACY_CONFIG_FILE} \
        && $(sha256sum "${LEGACY_CONFIG_FILE}" | awk '{print $1}') == "${legacy_hash}" ]] \
        || die '清理旧连接配置前发现文件发生变化；两份配置均已保留。'
    rm -- "${LEGACY_CONFIG_FILE}" || die '新配置已经就绪，但旧连接配置暂时无法删除。'
    printf '已将连接配置迁移到 %s；/root 下不再保留 hosts.conf。\n' "${CONFIG_FILE}"
}

maybe_migrate_config() {
    local requested_command=${1:-}
    case "${requested_command}" in
        self-test|__extract-role) return 0 ;;
    esac
    valid_release_version "${SCRIPT_VERSION}" || return 0
    is_root || return 0
    migrate_legacy_config
}

write_config_file() {
    local tmp
    validate_peer_config
    prepare_config_directory
    if [[ -e ${CONFIG_FILE} || -L ${CONFIG_FILE} ]]; then
        validate_managed_config_file "${CONFIG_FILE}" '连接配置'
    fi
    tmp=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")
    if ! {
        {
            printf '# 在国外出口 VPS 上使用；不保存任何 SSH 密码。\n'
            printf '# CN_ENTRY_PRIVATE_IP 字段名为兼容旧版保留；可保存私网或公网连接地址。\n'
            printf 'CN_ENTRY_SSH_USER=root\n'
            printf 'CN_ENTRY_PRIVATE_IP=%s\n' "${CN_ENTRY_PRIVATE_IP}"
            printf 'CN_ENTRY_SSH_PORT=%s\n' "${CN_ENTRY_SSH_PORT}"
        } >"${tmp}"
        chmod 0600 "${tmp}"
        mv "${tmp}" "${CONFIG_FILE}"
    }; then
        rm -f -- "${tmp}"
        die '连接配置写入失败。'
    fi
}

begin_reconfigure_config_transaction() {
    RECONFIGURE_CONFIG_BACKUP=
    RECONFIGURE_CONFIG_HAD_FILE=no
    RECONFIGURE_CONFIG_RESTORE=yes
    if [[ -e ${CONFIG_FILE} || -L ${CONFIG_FILE} ]]; then
        validate_config_directory
        validate_managed_config_file "${CONFIG_FILE}" '连接配置'
        RECONFIGURE_CONFIG_BACKUP=$(mktemp "${CONFIG_DIR}/.hosts.conf.reconfigure.XXXXXXXX") \
            || die '无法创建连接配置事务备份。'
        if ! install -o root -g root -m 0600 "${CONFIG_FILE}" "${RECONFIGURE_CONFIG_BACKUP}" \
            || ! validate_managed_config_file "${RECONFIGURE_CONFIG_BACKUP}" '连接配置事务备份'; then
            rm -f -- "${RECONFIGURE_CONFIG_BACKUP}"
            RECONFIGURE_CONFIG_BACKUP=
            RECONFIGURE_CONFIG_RESTORE=no
            die '连接配置事务备份失败；现有配置未修改。'
        fi
        RECONFIGURE_CONFIG_HAD_FILE=yes
    fi
}

cleanup_reconfigure_config_transaction() {
    local rc=$?
    local backup=${RECONFIGURE_CONFIG_BACKUP:-}
    local had_file=${RECONFIGURE_CONFIG_HAD_FILE:-no}
    local restore=${RECONFIGURE_CONFIG_RESTORE:-no}
    local tmp= rollback_ok=yes
    trap - EXIT INT TERM HUP
    set +e
    if [[ ${restore} == yes ]]; then
        if [[ ${had_file} == yes ]]; then
            if [[ -n ${backup} && -f ${backup} ]]; then
                tmp=$(mktemp "${CONFIG_FILE}.restore.XXXXXXXX" 2>/dev/null || true)
                if [[ -n ${tmp} ]] \
                    && install -o root -g root -m 0600 "${backup}" "${tmp}" \
                    && mv -f -- "${tmp}" "${CONFIG_FILE}"; then
                    tmp=
                else
                    rollback_ok=no
                    printf '[Po0 解锁助手] 警告：连接配置回滚失败；事务备份已保留：%s\n' \
                        "${backup}" >&2
                fi
            else
                rollback_ok=no
                printf '%s\n' '[Po0 解锁助手] 警告：连接配置事务备份丢失，无法自动回滚。' >&2
            fi
        elif [[ -e ${CONFIG_FILE} || -L ${CONFIG_FILE} ]]; then
            rm -f -- "${CONFIG_FILE}" \
                || { rollback_ok=no; printf '%s\n' '[Po0 解锁助手] 警告：无法清理失败事务创建的连接配置。' >&2; }
        fi
    fi
    [[ -z ${tmp} ]] || rm -f -- "${tmp}"
    if [[ -n ${backup} && ! ( ${restore} == yes && ${rollback_ok} != yes ) ]]; then
        rm -f -- "${backup}" \
            || printf '%s\n' '[Po0 解锁助手] 警告：无法清理连接配置事务备份。' >&2
    fi
    exit "${rc}"
}

complete_reconfigure_config_transaction() {
    local backup=${RECONFIGURE_CONFIG_BACKUP:-}
    [[ ${RECONFIGURE_CONFIG_RESTORE:-no} == yes ]] \
        || die '连接配置事务未启动，拒绝提交。'
    RECONFIGURE_CONFIG_RESTORE=no
    trap - EXIT INT TERM HUP
    if [[ -n ${backup} ]]; then
        rm -f -- "${backup}" \
            || printf '%s\n' '[Po0 解锁助手] 警告：无法清理连接配置事务备份。' >&2
    fi
    RECONFIGURE_CONFIG_BACKUP=
    RECONFIGURE_CONFIG_HAD_FILE=no
}

load_config() {
    require_root
    [[ -e ${CONFIG_FILE} || -L ${CONFIG_FILE} ]] \
        || die "缺少 ${CONFIG_FILE}；请先运行 ${PROGRAM_NAME} 并选择一键安装或更新连接配置。"
    validate_managed_config_file "${CONFIG_FILE}" '连接配置'
    read_config_file "${CONFIG_FILE}"
    local detected rc
    if detected=$(detect_exit_source_ip "${CN_ENTRY_PRIVATE_IP}"); then
        EXIT_PRIVATE_IP=${detected}
    else
        rc=$?
        if [[ ${rc} -eq 10 && $(ipv4_scope_label "${CN_ENTRY_PRIVATE_IP}") == 私网 ]]; then
            die '当前配置使用国内入口私网 IPv4，但本机没有可用的私网源地址；请选择“更新连接配置”并填写国内入口公网 IPv4。'
        fi
        [[ ${rc} -ne 10 ]] || die "无法识别到国内入口 ${CN_ENTRY_PRIVATE_IP} 的本机 IPv4 源地址。"
        return "${rc}"
    fi
    CN_ENTRY_TARGET=${CN_ENTRY_SSH_USER}@${CN_ENTRY_PRIVATE_IP}
}

use_current_connection_config() {
    validate_peer_config
    CN_ENTRY_TARGET=${CN_ENTRY_SSH_USER}@${CN_ENTRY_PRIVATE_IP}
}

cn_entry_control_dir_safe() {
    local directory=${1:-} base=${CN_ENTRY_CONTROL_BASE%/} name owner mode
    [[ -n ${directory} && ${directory%/*} == "${base}" ]] || return 1
    name=${directory##*/}
    [[ ${name} =~ ^po0-cn-ssh\.[A-Za-z0-9]{8}$ ]] || return 1
    [[ -d ${directory} && ! -L ${directory} ]] || return 1
    owner=$(stat -c '%u' "${directory}" 2>/dev/null || true)
    mode=$(stat -c '%a' "${directory}" 2>/dev/null || true)
    [[ ${owner} == 0 && ${mode} == 700 ]]
}

cn_entry_attempt_log_safe() {
    local directory=${CN_ENTRY_CONTROL_DIR:-} path owner mode links size
    cn_entry_control_dir_safe "${directory}" || return 1
    path=${directory}/${CN_ENTRY_ATTEMPT_LOG_NAME}
    [[ -f ${path} && ! -L ${path} ]] || return 1
    owner=$(stat -c '%u' "${path}" 2>/dev/null || true)
    mode=$(stat -c '%a' "${path}" 2>/dev/null || true)
    links=$(stat -c '%h' "${path}" 2>/dev/null || true)
    size=$(stat -c '%s' "${path}" 2>/dev/null || true)
    [[ ${owner} == 0 && ${mode} == 600 && ${links} == 1 ]] || return 1
    [[ ${size} =~ ^[0-9]+$ ]] || return 1
    (( 10#${size} <= CN_ENTRY_ATTEMPT_LOG_MAX_BYTES ))
}

initialize_cn_entry_attempt_log() {
    local directory=${CN_ENTRY_CONTROL_DIR:-} path
    cn_entry_control_dir_safe "${directory}" || return 1
    path=${directory}/${CN_ENTRY_ATTEMPT_LOG_NAME}
    if [[ -e ${path} || -L ${path} ]]; then
        cn_entry_attempt_log_safe && return 0
        printf '%s\n' '[Po0 解锁助手] 错误：SSH 建连计数文件权限异常。' >&2
        return 1
    fi
    ( set -o noclobber; : >"${path}" ) 2>/dev/null \
        || { printf '%s\n' '[Po0 解锁助手] 错误：无法创建 SSH 建连计数文件。' >&2; return 1; }
    chmod 0600 "${path}" \
        || { printf '%s\n' '[Po0 解锁助手] 错误：无法保护 SSH 建连计数文件。' >&2; return 1; }
    cn_entry_attempt_log_safe \
        || { printf '%s\n' '[Po0 解锁助手] 错误：SSH 建连计数文件校验失败。' >&2; return 1; }
}

record_cn_entry_initial_attempt() {
    local path
    cn_entry_attempt_log_safe \
        || { printf '%s\n' '[Po0 解锁助手] 错误：拒绝写入异常 SSH 建连计数文件。' >&2; return 1; }
    path=${CN_ENTRY_CONTROL_DIR}/${CN_ENTRY_ATTEMPT_LOG_NAME}
    printf '1\n' >>"${path}" \
        || { printf '%s\n' '[Po0 解锁助手] 错误：无法记录 SSH 初始建连尝试。' >&2; return 1; }
    cn_entry_attempt_log_safe \
        || { printf '%s\n' '[Po0 解锁助手] 错误：SSH 建连计数文件写入后校验失败。' >&2; return 1; }
}

cn_entry_initial_attempt_count() {
    local directory=${CN_ENTRY_CONTROL_DIR:-} path count
    if [[ -z ${directory} ]]; then
        printf '%s\n' 0
        return 0
    fi
    path=${directory}/${CN_ENTRY_ATTEMPT_LOG_NAME}
    if [[ ! -e ${path} && ! -L ${path} ]]; then
        printf '%s\n' 0
        return 0
    fi
    if ! cn_entry_attempt_log_safe; then
        printf '%s\n' '未知'
        return 0
    fi
    if count=$(awk '
        $0 != "1" { invalid=1; exit }
        { count++ }
        END { if (invalid) exit 1; print count + 0 }
    ' "${path}"); then
        printf '%s\n' "${count}"
    else
        printf '%s\n' '未知'
    fi
}

cleanup_cn_entry_session() {
    local rc=$? directory=${CN_ENTRY_CONTROL_DIR:-} path=${CN_ENTRY_CONTROL_PATH:-} attempt_log=
    if [[ -n ${directory} ]]; then
        if cn_entry_control_dir_safe "${directory}"; then
            attempt_log=${directory}/${CN_ENTRY_ATTEMPT_LOG_NAME}
            [[ -z ${path} ]] \
                || ssh -S "${path}" -O exit localhost >/dev/null 2>&1 \
                || true
            [[ -z ${path} || ${path%/*} != "${directory}" ]] \
                || rm -f -- "${path}" \
                || true
            rm -f -- "${attempt_log}" || true
            rmdir -- "${directory}" 2>/dev/null || true
        else
            printf '警告：拒绝清理异常 SSH 控制目录：%s\n' "${directory}" >&2
        fi
    fi
    CN_ENTRY_CONTROL_DIR=
    CN_ENTRY_CONTROL_PATH=
    return "${rc}"
}

prepare_cn_entry_control_dir() {
    local directory
    if cn_entry_control_dir_safe "${CN_ENTRY_CONTROL_DIR:-}" \
        && [[ ${CN_ENTRY_CONTROL_PATH:-} == "${CN_ENTRY_CONTROL_DIR}/control" ]]; then
        if initialize_cn_entry_attempt_log; then return 0; fi
        return 1
    fi
    [[ -z ${CN_ENTRY_CONTROL_DIR:-} ]] \
        || printf '警告：已有 SSH 控制目录不可用，将创建新的临时目录。\n' >&2
    directory=$(mktemp -d "${CN_ENTRY_CONTROL_BASE%/}/po0-cn-ssh.XXXXXXXX") \
        || { printf '%s\n' '[Po0 解锁助手] 错误：无法创建临时 SSH 控制目录。' >&2; return 1; }
    chmod 0700 "${directory}"
    CN_ENTRY_CONTROL_DIR=${directory}
    CN_ENTRY_CONTROL_PATH=${directory}/control
    if ! cn_entry_control_dir_safe "${directory}"; then
        printf '%s\n' '[Po0 解锁助手] 错误：临时 SSH 控制目录权限异常。' >&2
        cleanup_cn_entry_session || true
        return 1
    fi
    if ! initialize_cn_entry_attempt_log; then
        cleanup_cn_entry_session || true
        return 1
    fi
}

cn_entry_control_alive() {
    [[ -S ${CN_ENTRY_CONTROL_PATH:-} ]] || return 1
    ssh -S "${CN_ENTRY_CONTROL_PATH}" -O check "${CN_ENTRY_TARGET}" \
        >/dev/null 2>&1
}

start_cn_entry_session() {
    local attempt
    validate_admin_known_hosts \
        || { printf '%s\n' '[Po0 解锁助手] 错误：国内入口专用 SSH 主机密钥记录缺失或权限异常；请更新连接配置。' >&2; return 255; }
    prepare_cn_entry_control_dir || return $?
    cn_entry_control_alive && return 0

    for attempt in 1 2 3; do
        rm -f -- "${CN_ENTRY_CONTROL_PATH}"
        record_cn_entry_initial_attempt || return $?
        if ssh -MNf -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes \
            -o BindAddress="${EXIT_PRIVATE_IP}" -i "${ADMIN_KEY}" \
            -o GlobalKnownHostsFile=/dev/null \
            -o UserKnownHostsFile="${ADMIN_KNOWN_HOSTS}" -o StrictHostKeyChecking=yes \
            -o ControlMaster=yes -o ControlPath="${CN_ENTRY_CONTROL_PATH}" \
            -o ControlPersist=600 \
            -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
            -p "${CN_ENTRY_SSH_PORT}" "${CN_ENTRY_TARGET}"; then
            return 0
        fi
        if (( attempt < 3 )); then
            printf '[Po0 解锁助手] 国内入口 SSH 建连失败，%d 秒后重试（%d/3）。\n' \
                "${attempt}" "${attempt}" >&2
            sleep "${attempt}"
        fi
    done
    printf '%s\n' '[Po0 解锁助手] 错误：国内入口 SSH 连续 3 次连接均失败；未执行后续远程操作。' >&2
    rm -f -- "${CN_ENTRY_CONTROL_PATH}"
    return 255
}

ssh_cn_entry_command() {
    local timeout_seconds=$1
    shift
    start_cn_entry_session || return $?
    if (( timeout_seconds == 0 )); then
        ssh -S "${CN_ENTRY_CONTROL_PATH}" -o ControlMaster=no \
            -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes \
            -o BindAddress="${EXIT_PRIVATE_IP}" -i "${ADMIN_KEY}" \
            -o GlobalKnownHostsFile=/dev/null \
            -o UserKnownHostsFile="${ADMIN_KNOWN_HOSTS}" -o StrictHostKeyChecking=yes \
            -p "${CN_ENTRY_SSH_PORT}" "${CN_ENTRY_TARGET}" "$@"
        return
    fi
    timeout --foreground --kill-after=5s "${timeout_seconds}s" ssh \
        -S "${CN_ENTRY_CONTROL_PATH}" -o ControlMaster=no \
        -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes \
        -o BindAddress="${EXIT_PRIVATE_IP}" -i "${ADMIN_KEY}" \
        -o GlobalKnownHostsFile=/dev/null \
        -o UserKnownHostsFile="${ADMIN_KNOWN_HOSTS}" -o StrictHostKeyChecking=yes \
        -p "${CN_ENTRY_SSH_PORT}" "${CN_ENTRY_TARGET}" "$@"
}

ssh_cn_entry() {
    ssh_cn_entry_command 0 "$@"
}

# 把任意字符串包成远端 shell 可安全解析的单引号字面量；只用 POSIX 语法，
# 不依赖远端登录 shell 是 bash。
shell_single_quote() {
    local value=$1
    value=${value//\'/\'\\\'\'}
    printf "'%s'" "${value}"
}

ssh_cn_entry_component() {
    local timeout_seconds=${1:-} risk=${2:-} label=${3:-} rc
    shift 3 || {
        printf '%s\n' '[Po0 解锁助手] 错误：国内入口组件调用参数不完整。' >&2
        return 2
    }
    [[ ${timeout_seconds} =~ ^[1-9][0-9]*$ && -n ${label} && $# -gt 0 ]] || {
        printf '%s\n' '[Po0 解锁助手] 错误：国内入口组件调用参数无效。' >&2
        return 2
    }
    case "${risk}" in
        read-only|mutating) ;;
        *)
            printf '%s\n' '[Po0 解锁助手] 错误：国内入口组件调用风险类型无效。' >&2
            return 2
            ;;
    esac
    command -v timeout >/dev/null 2>&1 || {
        printf '%s\n' '[Po0 解锁助手] 错误：国外出口缺少 timeout，拒绝执行无界国内入口组件调用。' >&2
        return 127
    }
    # 上限同时压到远端：只在本地包 timeout 时，超时后本地 ssh 被杀而远端仍在跑，
    # 用户按提示立刻重试就可能撞上尚未退出的孤儿进程。远端先到期，本地留 15 秒余量兜底。
    if ssh_cn_entry_command "$((timeout_seconds + 15))" \
        "command -v timeout >/dev/null 2>&1 || { printf '%s\n' '国内入口缺少 timeout，拒绝执行无界组件调用。' >&2; exit 124; }; timeout --foreground --kill-after=5s ${timeout_seconds}s /bin/bash -c $(shell_single_quote "$*")"; then
        return 0
    else
        rc=$?
    fi
    if (( rc == 124 || rc == 137 )); then
        if [[ ${risk} == read-only ]]; then
            printf '[Po0 解锁助手] 错误：国内入口%s超过 %s 秒；本次只读组件调用未修改国内入口。\n' \
                "${label}" "${timeout_seconds}" >&2
        else
            printf '[Po0 解锁助手] 错误：国内入口%s超过 %s 秒；该命令可能已部分修改国内入口，请运行完整回滚，确认两端状态后再重试。\n' \
                "${label}" "${timeout_seconds}" >&2
        fi
    fi
    return "${rc}"
}

ssh_cn_entry_tty() {
    start_cn_entry_session || return $?
    ssh -tt -S "${CN_ENTRY_CONTROL_PATH}" -o ControlMaster=no \
        -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes \
        -o BindAddress="${EXIT_PRIVATE_IP}" -i "${ADMIN_KEY}" \
        -o GlobalKnownHostsFile=/dev/null \
        -o UserKnownHostsFile="${ADMIN_KNOWN_HOSTS}" -o StrictHostKeyChecking=yes \
        -p "${CN_ENTRY_SSH_PORT}" "${CN_ENTRY_TARGET}" "$@"
}

scp_cn_entry() {
    start_cn_entry_session || return $?
    scp -q -o ControlPath="${CN_ENTRY_CONTROL_PATH}" -o ControlMaster=no \
        -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes \
        -o BindAddress="${EXIT_PRIVATE_IP}" \
        -o GlobalKnownHostsFile=/dev/null \
        -o UserKnownHostsFile="${ADMIN_KNOWN_HOSTS}" -o StrictHostKeyChecking=yes \
        -i "${ADMIN_KEY}" -P "${CN_ENTRY_SSH_PORT}" "$@"
}

operation_lock_dir_safe() {
    local directory=${OPERATION_LOCK_DIR:-}
    [[ -n ${directory} && -d ${directory} && ! -L ${directory} ]] || return 1
    [[ $(stat -c '%u' "${directory}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${directory}" 2>/dev/null) == 700 ]]
}

operation_lock_file_safe() {
    local file=${OPERATION_LOCK_FILE:-}
    [[ -n ${file} && -f ${file} && ! -L ${file} ]] || return 1
    [[ $(stat -c '%u' "${file}" 2>/dev/null) == 0 \
        && $(stat -c '%a' "${file}" 2>/dev/null) == 600 \
        && $(stat -c '%h' "${file}" 2>/dev/null) == 1 ]]
}

acquire_operation_lock() {
    local directory=${OPERATION_LOCK_DIR:-} file=${OPERATION_LOCK_FILE:-}
    [[ -n ${directory} && -n ${file} && ${file} == "${directory}/operation.lock" ]] \
        || die 'Po0 操作锁路径无效。'
    if [[ -e ${directory} || -L ${directory} ]]; then
        operation_lock_dir_safe \
            || die 'Po0 操作锁目录权限异常；为避免并发操作，已停止。'
    else
        install -d -o root -g root -m 0700 "${directory}" \
            || die '无法创建 Po0 操作锁目录。'
        operation_lock_dir_safe \
            || die 'Po0 操作锁目录校验失败。'
    fi
    if [[ -e ${file} || -L ${file} ]]; then
        operation_lock_file_safe \
            || die 'Po0 操作锁文件异常；为避免并发操作，已停止。'
    else
        (set -o noclobber; : >"${file}") 2>/dev/null \
            || die '无法创建 Po0 操作锁文件。'
    fi
    chmod 0600 "${file}" \
        || die '无法保护 Po0 操作锁文件。'
    operation_lock_file_safe \
        || die 'Po0 操作锁文件校验失败。'
    exec 7<>"${file}" \
        || die '无法打开 Po0 操作锁。'
    flock -n 7 \
        || die '另一个 Po0 操作正在进行，请稍后重试。'
}

release_operation_lock() {
    flock -u 7 2>/dev/null || true
    exec 7>&- 2>/dev/null || true
}

cleanup_cn_entry_operation() {
    local rc=$?
    trap - EXIT INT TERM HUP
    cleanup_cn_entry_session || true
    release_operation_lock || true
    exit "${rc}"
}

run_cn_entry_operation() (
    CN_ENTRY_CONTROL_DIR=
    CN_ENTRY_CONTROL_PATH=
    po0_install_exit_trap cleanup_cn_entry_operation
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    acquire_operation_lock
    prepare_cn_entry_control_dir || return $?
    "$@"
)

confirm() {
    local expected=$1 prompt=$2 answer
    if [[ ${ASSUME_YES:-no} == yes ]]; then return 0; fi
    printf '%s\n' "${prompt}"
    while :; do
        read -r -p "请输入 ${expected} 继续，输入 0 返回：" answer || return 1
        case "${answer}" in
            "${expected}") return 0 ;;
            0) return 1 ;;
            *) printf '输入无效，请输入 %s 继续，或输入 0 返回。\n' "${expected}" >&2 ;;
        esac
    done
}

prompt_value() {
    local label=$1 current=$2 result
    # read 读到 EOF 会返回非零且不置值；此时必须失败退出，不能静默沿用默认值。
    # 收到不带换行的末行时 read 同样返回非零，但 result 已有内容，仍按正常输入处理。
    read -r -p "${label} [${current}]：" result || [[ -n ${result} ]] \
        || die "${label}未读取到输入，已停止。"
    printf '%s\n' "${result:-${current}}"
}

prompt_required_value() {
    local label=$1 result
    while [[ -z ${result:-} ]]; do
        read -r -p "${label}（必须填写）：" result || [[ -n ${result} ]] \
            || die "${label}未读取到输入，已停止。"
        [[ -n ${result} ]] || printf '%s不能为空，请重新输入。\n' "${label}" >&2
    done
    printf '%s\n' "${result}"
}

prompt_cn_entry_public_ip() {
    local current=${1:-} result
    while :; do
        if is_public_ipv4 "${current}"; then
            result=$(prompt_value '国内入口公网 IPv4' "${current}") || return 1
        else
            result=$(prompt_required_value '国内入口公网 IPv4') || return 1
        fi
        if is_public_ipv4 "${result}"; then
            printf '%s\n' "${result}"
            return 0
        fi
        printf '%s\n' '必须是国内入口的公网 IPv4，不能填写私网、回环、链路本地或保留地址。' >&2
        current=
    done
}

configure() {
    local require_cn_entry_ip=${1:-no} write_config=${2:-yes}
    local detected rc entry_scope exit_scope
    require_root
    [[ ${write_config} == yes || ${write_config} == no ]] \
        || die '连接配置写入模式无效。'
    command -v ip >/dev/null || die '缺少 ip 命令；请确认正在国外出口 Debian/Ubuntu VPS 上运行。'
    if [[ -e ${CONFIG_FILE} || -L ${CONFIG_FILE} ]]; then
        validate_managed_config_file "${CONFIG_FILE}" '连接配置'
        read_config_file "${CONFIG_FILE}"
    fi
    if [[ ${require_cn_entry_ip} == yes ]]; then
        printf '%s\n' '请亲自填写国内入口的连接信息，优先使用服务商私网。'
        CN_ENTRY_PRIVATE_IP=$(prompt_required_value '国内入口连接 IPv4（私网优先）')
    else
        printf '%s\n' '请输入国内入口的连接信息；直接回车保留方括号中的值。'
        CN_ENTRY_PRIVATE_IP=$(prompt_value '国内入口连接 IPv4（私网优先）' "${CN_ENTRY_PRIVATE_IP}")
    fi
    CN_ENTRY_SSH_PORT=$(prompt_value '国内入口 SSH 端口' "${CN_ENTRY_SSH_PORT}")
    validate_peer_config
    if detected=$(detect_exit_source_ip "${CN_ENTRY_PRIVATE_IP}"); then
        :
    else
        rc=$?
        [[ ${rc} -eq 10 ]] || return "${rc}"
        if is_private_ipv4 "${CN_ENTRY_PRIVATE_IP}"; then
            printf '%s\n' '本机没有可用的私网 IPv4，无法使用国内入口私网路径。请填写国内入口公网 IPv4。' >&2
        else
            printf '%s\n' '当前国内入口公网 IPv4 无法匹配本机出站源地址，请重新填写。' >&2
        fi
        while :; do
            CN_ENTRY_PRIVATE_IP=$(prompt_cn_entry_public_ip "${CN_ENTRY_PRIVATE_IP}") \
                || die '未提供国内入口公网 IPv4，连接配置未修改。'
            if detected=$(detect_exit_source_ip "${CN_ENTRY_PRIVATE_IP}"); then
                break
            fi
            rc=$?
            [[ ${rc} -eq 10 ]] || return "${rc}"
            printf '无法确认本机到国内入口 %s 的 IPv4 源地址，请检查公网 IP 后重试。\n' \
                "${CN_ENTRY_PRIVATE_IP}" >&2
            CN_ENTRY_PRIVATE_IP=
        done
    fi
    EXIT_PRIVATE_IP=${detected}
    CN_ENTRY_TARGET=${CN_ENTRY_SSH_USER}@${CN_ENTRY_PRIVATE_IP}

    if [[ ${write_config} == yes ]]; then
        write_config_file
    fi
    entry_scope=$(ipv4_scope_label "${CN_ENTRY_PRIVATE_IP}")
    exit_scope=$(ipv4_scope_label "${EXIT_PRIVATE_IP}")
    if [[ ${write_config} == yes ]]; then
        log "配置已保存：国内入口${entry_scope} ${CN_ENTRY_PRIVATE_IP}:${CN_ENTRY_SSH_PORT}；自动识别国外出口${exit_scope}源地址 ${EXIT_PRIVATE_IP}。"
    else
        log "新连接配置已准备：国内入口${entry_scope} ${CN_ENTRY_PRIVATE_IP}:${CN_ENTRY_SSH_PORT}；自动识别国外出口${exit_scope}源地址 ${EXIT_PRIVATE_IP}。确认更新完成后才会写入。"
    fi
    log '配置文件不含密码。'
}

admin_key_directory_safe() {
    local directory=$1 owner mode
    [[ -d ${directory} && ! -L ${directory} ]] || return 1
    owner=$(stat -c '%u' "${directory}" 2>/dev/null || true)
    mode=$(stat -c '%a' "${directory}" 2>/dev/null || true)
    [[ ${owner} == 0 && ${mode} == 700 ]]
}

admin_key_file_safe() {
    local file=$1 expected_mode=$2 owner mode links
    [[ -f ${file} && ! -L ${file} && -r ${file} ]] || return 1
    owner=$(stat -c '%u' "${file}" 2>/dev/null || true)
    mode=$(stat -c '%a' "${file}" 2>/dev/null || true)
    links=$(stat -c '%h' "${file}" 2>/dev/null || true)
    [[ ${owner} == 0 && ${mode} == "${expected_mode}" && ${links} == 1 ]]
}

admin_public_key_file_safe() {
    local file=$1 owner mode links
    [[ -f ${file} && ! -L ${file} && -r ${file} ]] || return 1
    owner=$(stat -c '%u' "${file}" 2>/dev/null || true)
    mode=$(stat -c '%a' "${file}" 2>/dev/null || true)
    links=$(stat -c '%h' "${file}" 2>/dev/null || true)
    [[ ${owner} == 0 && ( ${mode} == 600 || ${mode} == 644 ) && ${links} == 1 ]]
}

admin_key_pair_matches() {
    local derived recorded
    derived=$(ssh-keygen -y -P '' -f "${ADMIN_KEY}" 2>/dev/null | awk '
        NR == 1 && NF >= 2 { value=$1 " " $2 }
        END { if (NR != 1 || value == "") exit 1; print value }
    ') || return 1
    recorded=$(awk '
        NR == 1 && NF >= 2 { value=$1 " " $2 }
        END { if (NR != 1 || value == "") exit 1; print value }
    ' "${ADMIN_KEY}.pub") || return 1
    [[ ${recorded} == "${derived}" ]]
}

ensure_admin_key() (
    local directory rc
    ADMIN_KEY_PUBLIC_CANDIDATE=
    cleanup_admin_key_candidate() {
        rc=$?
        trap - EXIT INT TERM HUP
        [[ -z ${ADMIN_KEY_PUBLIC_CANDIDATE:-} ]] \
            || rm -f -- "${ADMIN_KEY_PUBLIC_CANDIDATE}"
        exit "${rc}"
    }
    po0_install_exit_trap cleanup_admin_key_candidate
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    directory=${ADMIN_KEY%/*}
    [[ -n ${directory} && ${directory} != "${ADMIN_KEY}" ]] \
        || die '专用管理密钥路径无效。'
    if [[ -e ${directory} || -L ${directory} ]]; then
        admin_key_directory_safe "${directory}" \
            || die '专用管理密钥目录必须是 root 所有的 0700 普通目录。'
    else
        install -d -o root -g root -m 0700 "${directory}" \
            || die '无法创建专用管理密钥目录。'
        admin_key_directory_safe "${directory}" \
            || die '专用管理密钥目录创建后属性异常。'
    fi

    if [[ -e ${ADMIN_KEY} || -L ${ADMIN_KEY} ]]; then
        admin_key_file_safe "${ADMIN_KEY}" 600 \
            || die '专用管理私钥属性异常，拒绝使用。'
    else
        [[ ! -e ${ADMIN_KEY}.pub && ! -L ${ADMIN_KEY}.pub ]] \
            || die '专用管理公钥路径异常，拒绝创建私钥。'
        ssh-keygen -q -t ed25519 -N '' -C 'po0-unlock-admin' -f "${ADMIN_KEY}" \
            || die '无法创建专用管理密钥。'
        log "已创建国外出口到国内入口的专用管理密钥：${ADMIN_KEY}"
    fi
    admin_key_file_safe "${ADMIN_KEY}" 600 \
        || die '专用管理私钥创建后属性异常。'

    if [[ -e ${ADMIN_KEY}.pub || -L ${ADMIN_KEY}.pub ]]; then
        admin_public_key_file_safe "${ADMIN_KEY}.pub" \
            || die '专用管理公钥属性异常，拒绝使用。'
    else
        ADMIN_KEY_PUBLIC_CANDIDATE=$(mktemp "${ADMIN_KEY}.pub.XXXXXXXX") \
            || die '无法创建专用管理公钥候选。'
        ssh-keygen -y -P '' -f "${ADMIN_KEY}" >"${ADMIN_KEY_PUBLIC_CANDIDATE}" \
            || die '无法从专用管理私钥生成公钥。'
        chmod 0644 "${ADMIN_KEY_PUBLIC_CANDIDATE}"
        [[ ! -e ${ADMIN_KEY}.pub && ! -L ${ADMIN_KEY}.pub ]] \
            || die '专用管理公钥路径在生成期间发生变化。'
        mv -fT -- "${ADMIN_KEY_PUBLIC_CANDIDATE}" "${ADMIN_KEY}.pub" \
            || die '无法原子安装专用管理公钥。'
        ADMIN_KEY_PUBLIC_CANDIDATE=
    fi
    admin_public_key_file_safe "${ADMIN_KEY}.pub" \
        && admin_key_pair_matches \
        || die '专用管理公私钥不匹配或属性异常。'
    trap - EXIT INT TERM HUP
)

admin_known_hosts_file_safe() {
    local file=${1:-} owner mode links
    [[ -n ${file} && -f ${file} && ! -L ${file} && -r ${file} ]] || return 1
    owner=$(stat -c '%u' "${file}" 2>/dev/null || true)
    mode=$(stat -c '%a' "${file}" 2>/dev/null || true)
    links=$(stat -c '%h' "${file}" 2>/dev/null || true)
    [[ ${owner} == 0 && ${mode} == 600 && ${links} == 1 ]]
}

validate_admin_known_hosts() {
    admin_known_hosts_file_safe "${ADMIN_KNOWN_HOSTS:-}"
}

admin_known_hosts_host() {
    if [[ ${CN_ENTRY_SSH_PORT} == 22 ]]; then
        printf '%s\n' "${CN_ENTRY_PRIVATE_IP}"
    else
        printf '[%s]:%s\n' "${CN_ENTRY_PRIVATE_IP}" "${CN_ENTRY_SSH_PORT}"
    fi
}

admin_known_hosts_fingerprints() {
    local host=$1 file=$2 keys fingerprints
    keys=$(mktemp /tmp/po0-admin-known-host.XXXXXXXX) || return 1
    if ! ssh-keygen -F "${host}" -f "${file}" 2>/dev/null \
        | awk '$2 ~ /^(ssh-|ecdsa-)/ {print $2 " " $3}' >"${keys}" \
        || [[ ! -s ${keys} ]]; then
        rm -f -- "${keys}"
        return 1
    fi
    fingerprints=$(ssh-keygen -E sha256 -lf "${keys}" 2>/dev/null \
        | awk '$2 ~ /^SHA256:/ {if (seen[$2]++) next; if (out != "") out=out ","; out=out $2} END {print out}') || true
    rm -f -- "${keys}"
    [[ -n ${fingerprints} ]] || return 1
    printf '%s\n' "${fingerprints}"
}

replace_admin_known_hosts_entry() {
    local host=$1 scan_file=$2 candidate backup
    admin_known_hosts_file_safe "${ADMIN_KNOWN_HOSTS}" || return 1
    candidate=$(mktemp "${ADMIN_KNOWN_HOSTS}.candidate.XXXXXXXX") || return 1
    if ! cp -p -- "${ADMIN_KNOWN_HOSTS}" "${candidate}"; then
        rm -f -- "${candidate}"
        return 1
    fi
    ssh-keygen -f "${candidate}" -R "${host}" >/dev/null 2>&1 || true
    rm -f -- "${candidate}.old"
    if ! cat -- "${scan_file}" >>"${candidate}"; then
        rm -f -- "${candidate}"
        return 1
    fi
    chmod 0600 "${candidate}" || { rm -f -- "${candidate}"; return 1; }
    admin_known_hosts_file_safe "${candidate}" || {
        rm -f -- "${candidate}"
        return 1
    }
    backup=$(mktemp "${ADMIN_KNOWN_HOSTS}.backup.XXXXXXXX") || {
        rm -f -- "${candidate}"
        return 1
    }
    if ! cp -p -- "${ADMIN_KNOWN_HOSTS}" "${backup}"; then
        rm -f -- "${candidate}" "${backup}"
        return 1
    fi
    chmod 0600 "${backup}" || {
        rm -f -- "${candidate}" "${backup}"
        return 1
    }
    admin_known_hosts_file_safe "${backup}" || {
        rm -f -- "${candidate}" "${backup}"
        return 1
    }
    if ! mv -f -- "${candidate}" "${ADMIN_KNOWN_HOSTS}"; then
        rm -f -- "${candidate}" "${backup}"
        return 1
    fi
    admin_known_hosts_file_safe "${ADMIN_KNOWN_HOSTS}" || {
        printf '%s\n' '[Po0 解锁助手] 警告：新主机密钥记录替换后属性异常；旧记录备份仍保留。' >&2
        ADMIN_KNOWN_HOSTS_BACKUP=${backup}
        return 1
    }
    ADMIN_KNOWN_HOSTS_BACKUP=${backup}
    return 0
}

recover_admin_known_hosts_after_reinstall() {
    local host scan_file current_fingerprint old_fingerprints answer
    ADMIN_KNOWN_HOSTS_BACKUP=
    validate_admin_known_hosts \
        || { printf '%s\n' '[Po0 解锁助手] 专用 SSH 主机密钥记录权限异常；旧记录未修改。' >&2; return 1; }
    host=$(admin_known_hosts_host)
    ssh-keygen -F "${host}" -f "${ADMIN_KNOWN_HOSTS}" >/dev/null 2>&1 \
        || return 1
    scan_file=$(mktemp /tmp/po0-admin-host-key.XXXXXXXX) || return 1
    if ! ssh-keyscan -4 -T 8 -t ed25519 -p "${CN_ENTRY_SSH_PORT}" \
        "${CN_ENTRY_PRIVATE_IP}" >"${scan_file}" 2>/dev/null; then
        rm -f -- "${scan_file}"
        printf '%s\n' '[Po0 解锁助手] 无法自动读取当前 SSH 主机指纹；旧记录未修改。' >&2
        return 1
    fi
    chmod 0600 "${scan_file}" || { rm -f -- "${scan_file}"; return 1; }
    if [[ $(awk '$1 !~ /^#/ && $2 == "ssh-ed25519" {count++} END {print count + 0}' \
        "${scan_file}") != 1 ]]; then
        rm -f -- "${scan_file}"
        printf '%s\n' '[Po0 解锁助手] 当前 SSH 主机指纹返回不完整；旧记录未修改。' >&2
        return 1
    fi
    current_fingerprint=$(ssh-keygen -E sha256 -lf "${scan_file}" 2>/dev/null \
        | awk '$2 ~ /^SHA256:/ {print $2; exit}')
    old_fingerprints=$(admin_known_hosts_fingerprints "${host}" "${ADMIN_KNOWN_HOSTS}" || true)
    if [[ -z ${current_fingerprint} || -z ${old_fingerprints} ]]; then
        rm -f -- "${scan_file}"
        printf '%s\n' '[Po0 解锁助手] 无法安全比较新旧 SSH 指纹；旧记录未修改。' >&2
        return 1
    fi
    case ",${old_fingerprints}," in
        *,"${current_fingerprint}",*)
            rm -f -- "${scan_file}"
            return 1
            ;;
    esac
    printf '\n%s\n' '检测到国内入口 SSH 主机指纹发生变化。'
    printf '旧指纹：%s\n' "${old_fingerprints//,/, }"
    printf '新指纹：%s\n' "${current_fingerprint}"
    printf '%s\n' '新指纹只是当前网络扫描得到的候选值，不是可信证明。'
    printf '%s\n' '只有在你已通过服务商控制台确认国内入口确实重装或更换时，才可以继续。'
    printf '%s\n' '自动模式也不能跳过这一步；无法确认时请输入 0。'
    if ! read -r -p '确认后请输入 REPLACE 替换旧指纹：' answer; then
        rm -f -- "${scan_file}"
        return 1
    fi
    if [[ ${answer} != REPLACE ]]; then
        rm -f -- "${scan_file}"
        printf '%s\n' '未确认替换，旧 SSH 主机密钥记录保持不变。' >&2
        return 1
    fi
    if ! replace_admin_known_hosts_entry "${host}" "${scan_file}"; then
        rm -f -- "${scan_file}"
        printf '%s\n' '[Po0 解锁助手] 新 SSH 主机密钥记录替换失败；旧记录或备份仍保留。' >&2
        return 1
    fi
    rm -f -- "${scan_file}"
    printf '已替换国内入口 SSH 主机密钥；旧记录备份：%s\n' \
        "${ADMIN_KNOWN_HOSTS_BACKUP}"
    return 0
}

prepare_admin_known_hosts() {
    local file=${ADMIN_KNOWN_HOSTS:-} directory
    [[ -n ${file} && ${file%/*} != "${file}" ]] \
        || die '专用 SSH 主机密钥记录路径无效。'
    directory=${file%/*}
    install -d -m 0700 "${directory}" \
        || die '无法创建专用 SSH 主机密钥记录目录。'
    if [[ -e ${file} || -L ${file} ]]; then
        validate_admin_known_hosts \
            || die '专用 SSH 主机密钥记录权限异常；为避免绕过校验，已停止。'
        return 0
    fi
    (set -o noclobber; : >"${file}") 2>/dev/null \
        || die '无法创建专用 SSH 主机密钥记录。'
    chmod 0600 "${file}" \
        || die '无法保护专用 SSH 主机密钥记录。'
    validate_admin_known_hosts \
        || die '专用 SSH 主机密钥记录校验失败。'
}

authorize_admin_key_once() {
    local public_key_b64=$1 entry_policy=${2:-require-unclaimed} occupied_guard
    case "${entry_policy}" in
        require-unclaimed)
            occupied_guard="if test -e '${CN_ENTRY_ACTIVE_FILE}' || test -L '${CN_ENTRY_ACTIVE_FILE}'; then printf '%s\\n' '国内入口已经部署 Po0；拒绝添加另一台国外出口的管理密钥。' >&2; exit ${CN_ENTRY_OCCUPIED_RC}; fi"
            ;;
        allow-active) occupied_guard=: ;;
        *) die '国内入口授权占用策略无效。' ;;
    esac
    ssh -o BatchMode=no -o ConnectTimeout=15 -o IdentitiesOnly=yes \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
        -o GlobalKnownHostsFile=/dev/null \
        -o UserKnownHostsFile="${ADMIN_KNOWN_HOSTS}" -o StrictHostKeyChecking=ask \
        -o BindAddress="${EXIT_PRIVATE_IP}" \
        -o PreferredAuthentications=publickey,keyboard-interactive,password \
        -i "${ADMIN_KEY}" -p "${CN_ENTRY_SSH_PORT}" "${CN_ENTRY_TARGET}" \
        "set -eu; ${occupied_guard}; umask 077; install -d -m 0700 \"\$HOME/.ssh\"; touch \"\$HOME/.ssh/authorized_keys\"; key=\$(printf '%s' '${public_key_b64}' | base64 -d); grep -Fqx -- \"\$key\" \"\$HOME/.ssh/authorized_keys\" || printf '\\n%s\\n' \"\$key\" >>\"\$HOME/.ssh/authorized_keys\"; chmod 0600 \"\$HOME/.ssh/authorized_keys\""
}

# 更新连接配置时的入口占用策略：指向同一台入口时沿用 allow-active——自己已有的
# ACTIVE 不该拒绝自己；换到另一台入口则按新装处理，拒绝已被其他出口占用的机器。
# 只比较地址：同一台机器换 SSH 端口是合法操作，不应被当成换机器。
reconfigure_entry_policy() {
    local previous=${1:-} current=${2:-}
    if [[ -n ${previous} && ${current} == "${previous}" ]]; then
        printf '%s\n' allow-active
        return 0
    fi
    printf '%s\n' require-unclaimed
}

authorize() {
    local config_mode=${1:-load} entry_policy=${2:-require-unclaimed}
    local public_key_b64 authorize_rc
    case "${config_mode}" in
        load) load_config ;;
        current) use_current_connection_config ;;
        *) die '国内入口授权使用了无效的连接配置模式。' ;;
    esac
    case "${entry_policy}" in
        require-unclaimed|allow-active) ;;
        *) die '国内入口授权占用策略无效。' ;;
    esac
    ensure_admin_key
    prepare_admin_known_hosts
    public_key_b64=$(base64 -w 0 "${ADMIN_KEY}.pub")
    printf '%s\n' '正在验证国外出口到国内入口的专用 SSH 密钥。'
    printf '%s\n' '如密钥尚未获准，SSH 会提示输入国内入口当前密码；密码不会保存。'
    printf '%s\n' '首次连接或主机密钥变化时，请将 SSH 显示的主机指纹与服务商控制台核对后再确认。'
    if authorize_admin_key_once "${public_key_b64}" "${entry_policy}"; then
        :
    else
        authorize_rc=$?
        if [[ ${entry_policy} == require-unclaimed \
            && ${authorize_rc} -eq ${CN_ENTRY_OCCUPIED_RC} ]]; then
            die '国内入口已经部署 Po0；为避免影响现有出口，未添加本机管理密钥。若确实要改用这台入口，请先在其上完成完整回滚；否则请改用独立的国内入口测试机。'
        fi
        recover_admin_known_hosts_after_reinstall \
            || die '国内入口专用密钥授权失败；若服务器刚重装，请核对新指纹后重试。'
        if authorize_admin_key_once "${public_key_b64}" "${entry_policy}"; then
            :
        else
            authorize_rc=$?
            if [[ ${entry_policy} == require-unclaimed \
                && ${authorize_rc} -eq ${CN_ENTRY_OCCUPIED_RC} ]]; then
                die '新主机指纹已确认，但国内入口已经部署 Po0；未添加本机管理密钥。请改用独立的国内入口测试机。'
            fi
            die "新主机指纹已确认，但专用密钥授权仍失败；新记录已保留，旧记录备份位于 ${ADMIN_KNOWN_HOSTS_BACKUP:-未知位置}。"
        fi
    fi
    ssh_cn_entry true || die '国内入口专用密钥登录验证失败。'
    log '国内入口专用密钥已经验证；SSH 密码没有保存。'
}

cn_entry_installation_claim_state() {
    ssh_cn_entry "
set -eu
active='${CN_ENTRY_ACTIVE_FILE}'
if test ! -e \"\${active}\" && test ! -L \"\${active}\"; then
    printf '%s\\n' UNCLAIMED
elif test -f \"\${active}\" && test ! -L \"\${active}\"; then
    printf '%s\\n' ACTIVE
else
    printf '%s\\n' UNSAFE
fi
"
}

assert_cn_entry_unclaimed() {
    local state
    state=$(cn_entry_installation_claim_state) \
        || die '无法只读确认国内入口是否已被 Po0 占用；未上传组件或修改国内入口。'
    case "${state}" in
        UNCLAIMED) return 0 ;;
        ACTIVE)
            die '国内入口已经由另一套 Po0 部署占用；未上传组件或修改现有部署。请改用独立的国内入口测试机。'
            ;;
        UNSAFE)
            die '国内入口 ACTIVE 路径异常；未上传组件或修改国内入口。请先人工检查。'
            ;;
        *) die '国内入口返回了无法识别的占用状态；未上传组件或修改国内入口。' ;;
    esac
}

new_install_claim() {
    local claim
    command -v od >/dev/null || die '系统缺少 od，无法生成安装事务标识。'
    claim=$(od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]') \
        || die '无法生成安装事务标识。'
    [[ ${claim} =~ ^[0-9a-f]{64}$ ]] \
        || die '生成的安装事务标识格式异常。'
    printf '%s\n' "${claim}"
}

preflight() {
    require_root
    materialize_roles
    [[ -x ${EXIT_ROLE} ]] || die '缺少可执行的 overseas-exit-role.sh。'
    [[ -r ${CN_ENTRY_ROLE_LOCAL} ]] || die '缺少 cn-entry-role.sh。'
    bash -n "${EXIT_ROLE}" || die '国外出口内置组件语法检查失败。'
    bash -n "${CN_ENTRY_ROLE_LOCAL}" || die '国内入口内置组件语法检查失败。'
    [[ -r ${ADMIN_KEY} ]] || die "缺少专用管理密钥；请运行 ${PROGRAM_NAME} 并选择更新连接配置。"
    local_ipv4_exists "${EXIT_PRIVATE_IP}" || die "自动识别的国外出口 IPv4 源地址已不存在：${EXIT_PRIVATE_IP}"
    ip -4 route get "${CN_ENTRY_PRIVATE_IP}" from "${EXIT_PRIVATE_IP}" >/dev/null 2>&1 \
        || die "国外出口源地址 ${EXIT_PRIVATE_IP} 没有到国内入口 ${CN_ENTRY_PRIVATE_IP} 的路由。"
    ssh_cn_entry true || die '无法通过专用密钥连接国内入口；请从主菜单选择更新连接配置。'
}

run_exit_role() {
    /bin/bash "${EXIT_ROLE}" "$@"
}

valid_cn_entry_install_temp_path() {
    [[ ${1:-} =~ ^/usr/local/libexec/\.po0-unlock-cn-entry\.[A-Za-z0-9]{8}$ ]]
}

valid_cn_entry_scan_temp_path() {
    [[ ${1:-} =~ ^/root/\.po0-cn-entry-scan\.[A-Za-z0-9]{8}$ ]]
}

installed_cn_entry_role_is_current() {
    local expected_hash
    expected_hash=$(sha256sum "${CN_ENTRY_ROLE_LOCAL}" | awk '{print $1}')
    [[ ${expected_hash} =~ ^[0-9a-f]{64}$ ]] || return 1
    ssh_cn_entry "
set -eu
path='${CN_ENTRY_REMOTE}'
test -f \"\${path}\" && test ! -L \"\${path}\"
test \"\$(stat -c '%u' \"\${path}\")\" = 0
test \"\$(stat -c '%a' \"\${path}\")\" = 700
test \"\$(stat -c '%h' \"\${path}\")\" = 1
actual=\$(sha256sum \"\${path}\" | awk '{print \$1}')
test \"\${actual}\" = '${expected_hash}'
bash -n \"\${path}\"
" >/dev/null 2>&1
}

select_current_cn_entry_role() {
    local path_var=${1:-} temporary_var=${2:-}
    [[ ${path_var} =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
        && ${temporary_var} =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
        && ${path_var} != "${temporary_var}" ]] \
        || die '当前国内入口组件输出变量无效。'
    if installed_cn_entry_role_is_current; then
        printf -v "${path_var}" '%s' "${CN_ENTRY_REMOTE}"
        printf -v "${temporary_var}" '%s' no
    else
        upload_temporary_cn_entry_role "${path_var}"
        printf -v "${temporary_var}" '%s' yes
    fi
}

upload_cn_entry_role() {
    local expected_hash remote_tmp
    expected_hash=$(sha256sum "${CN_ENTRY_ROLE_LOCAL}" | awk '{print $1}')
    [[ ${expected_hash} =~ ^[0-9a-f]{64}$ ]] || die '无法计算国内入口内置组件哈希。'
    remote_tmp=$(ssh_cn_entry \
        'install -d -m 0755 /usr/local/libexec; umask 077; mktemp /usr/local/libexec/.po0-unlock-cn-entry.XXXXXXXX') \
        || die '无法在国内入口创建组件临时文件。'
    valid_cn_entry_install_temp_path "${remote_tmp}" \
        || die '国内入口返回了无效的组件临时路径。'
    if ! scp_cn_entry \
        "${CN_ENTRY_ROLE_LOCAL}" "${CN_ENTRY_TARGET}:${remote_tmp}"; then
        ssh_cn_entry "rm -f -- '${remote_tmp}'" || true
        die '国内入口组件上传失败；原版本未改动。'
    fi
    if ! ssh_cn_entry "
set -eu
tmp='${remote_tmp}'
trap 'rm -f -- \"\${tmp}\"' EXIT
actual=\$(sha256sum \"\${tmp}\" | awk '{print \$1}')
test \"\${actual}\" = '${expected_hash}'
bash -n \"\${tmp}\"
if test -e '${CN_ENTRY_REMOTE}' || test -L '${CN_ENTRY_REMOTE}'; then
    test -f '${CN_ENTRY_REMOTE}'
    test ! -L '${CN_ENTRY_REMOTE}'
    test \"\$(stat -c '%u' '${CN_ENTRY_REMOTE}')\" = 0
    test \"\$(stat -c '%a' '${CN_ENTRY_REMOTE}')\" = 700
    test \"\$(stat -c '%h' '${CN_ENTRY_REMOTE}')\" = 1
    bash -n '${CN_ENTRY_REMOTE}'
fi
if test -f '${CN_ENTRY_REMOTE}' && cmp -s \"\${tmp}\" '${CN_ENTRY_REMOTE}'; then
    exit 0
fi
if test -f '${CN_ENTRY_REMOTE}'; then
    install -d -m 0700 /var/lib/po0-unlock/role-backups
    backup=\$(mktemp /var/lib/po0-unlock/role-backups/cn-entry-role.XXXXXXXX)
    cp -p '${CN_ENTRY_REMOTE}' \"\${backup}\"
fi
chmod 0700 \"\${tmp}\"
mv \"\${tmp}\" '${CN_ENTRY_REMOTE}'
test -f '${CN_ENTRY_REMOTE}'
test ! -L '${CN_ENTRY_REMOTE}'
test \"\$(stat -c '%u' '${CN_ENTRY_REMOTE}')\" = 0
test \"\$(stat -c '%a' '${CN_ENTRY_REMOTE}')\" = 700
test \"\$(stat -c '%h' '${CN_ENTRY_REMOTE}')\" = 1
actual=\$(sha256sum '${CN_ENTRY_REMOTE}' | awk '{print \$1}')
test \"\${actual}\" = '${expected_hash}'
bash -n '${CN_ENTRY_REMOTE}'
trap - EXIT
"; then
        die '国内入口组件校验或原子安装失败；原版本已保留。'
    fi
}

upload_temporary_cn_entry_role() {
    local output_var=${1:-} expected_hash remote_tmp
    [[ ${output_var} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
        || die '临时扫描组件输出变量无效。'
    printf -v "${output_var}" '%s' ''
    expected_hash=$(sha256sum "${CN_ENTRY_ROLE_LOCAL}" | awk '{print $1}')
    [[ ${expected_hash} =~ ^[0-9a-f]{64}$ ]] || die '无法计算国内入口内置组件哈希。'
    remote_tmp=$(ssh_cn_entry 'umask 077; mktemp /root/.po0-cn-entry-scan.XXXXXXXX') \
        || die '无法在国内入口创建临时扫描组件。'
    valid_cn_entry_scan_temp_path "${remote_tmp}" \
        || die '国内入口返回了无效的临时扫描组件路径。'
    printf -v "${output_var}" '%s' "${remote_tmp}"
    if ! scp_cn_entry \
        "${CN_ENTRY_ROLE_LOCAL}" "${CN_ENTRY_TARGET}:${remote_tmp}"; then
        ssh_cn_entry "rm -f -- '${remote_tmp}'" || true
        die '国内入口临时扫描组件上传失败；现有版本未改动。'
    fi
    if ! ssh_cn_entry "
set -eu
tmp='${remote_tmp}'
actual=\$(sha256sum \"\${tmp}\" | awk '{print \$1}')
test \"\${actual}\" = '${expected_hash}'
bash -n \"\${tmp}\"
chmod 0700 \"\${tmp}\"
"; then
        ssh_cn_entry "rm -f -- '${remote_tmp}'" || true
        die '国内入口临时扫描组件校验失败；现有版本未改动。'
    fi
}

install_core() {
    local public_key_b64 host_fingerprint install_claim prepare_rc
    local cn_entry_prepared=no exit_prepared=no
    load_config
    preflight
    assert_cn_entry_unclaimed
    install_claim=$(new_install_claim)
    upload_cn_entry_role

    cleanup_on_error() {
        local rc=${1:-$?} exit_stopped=yes
        trap - ERR
        printf '[Po0 解锁助手] 安装中断，开始回滚已经完成的阶段。\n' >&2
        if [[ ${cn_entry_prepared} == yes ]]; then
            ssh_cn_entry_component "${CN_ENTRY_TIMEOUT_ROLLBACK_SERVICES}" mutating 'Agent 回滚阶段' \
                "'${CN_ENTRY_REMOTE}' '${CN_ENTRY_CMD_ROLLBACK_SERVICES_CLAIMED}' '${install_claim}'" || true
        fi
        if [[ ${exit_prepared} == yes ]] && ! run_exit_role "${EXIT_CMD_ROLLBACK}"; then exit_stopped=no; fi
        if [[ ${cn_entry_prepared} == yes && ${exit_stopped} == yes ]]; then
            if ! ssh_cn_entry_component "${CN_ENTRY_TIMEOUT_ROLLBACK_FINALIZE}" mutating '最终回滚阶段' \
                "'${CN_ENTRY_REMOTE}' '${CN_ENTRY_CMD_ROLLBACK_FINALIZE_CLAIMED}' '${install_claim}'"; then
                printf '[Po0 解锁助手] 国内入口最终清理未完成；请修正提示的问题后重新运行本助手并选择完整回滚。\n' >&2
            fi
        elif [[ ${cn_entry_prepared} == yes ]]; then
            printf '[Po0 解锁助手] 国外出口隧道未确认停止，已保留国内入口专用账户和 ACTIVE 状态。\n' >&2
        fi
        exit "${rc}"
    }
    trap cleanup_on_error ERR

    log '准备国外出口本地代理和专用隧道密钥。'
    exit_prepared=yes
    run_exit_role prepare
    public_key_b64=$(run_exit_role public-key-b64)
    [[ -n ${public_key_b64} ]] || die '未取得国外出口隧道公钥。'

    log '准备国内入口受限隧道账户。'
    if ssh_cn_entry_component "${CN_ENTRY_TIMEOUT_PREPARE}" mutating '安装准备' \
        "'${CN_ENTRY_REMOTE}' prepare '${public_key_b64}' '${install_claim}'"; then
        cn_entry_prepared=yes
    else
        prepare_rc=$?
        if ssh_cn_entry_component "${CN_ENTRY_TIMEOUT_CLAIM_STATUS}" read-only '安装事务确认' \
            "'${CN_ENTRY_REMOTE}' '${CN_ENTRY_CMD_CLAIM_STATUS}' '${install_claim}'" \
            >/dev/null 2>&1; then
            cn_entry_prepared=yes
        fi
        cleanup_on_error "${prepare_rc}"
    fi
    host_fingerprint=$(ssh_cn_entry "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print \$2}'")
    [[ ${host_fingerprint} == SHA256:* ]] || die '未取得国内入口 SSH 主机指纹。'

    log "通过国外出口 ${EXIT_PRIVATE_IP} 启动到国内入口 ${CN_ENTRY_PRIVATE_IP}:${CN_ENTRY_SSH_PORT} 的反向隧道。"
    run_exit_role start "${host_fingerprint}" "${CN_ENTRY_PRIVATE_IP}" "${CN_ENTRY_SSH_PORT}" "${EXIT_PRIVATE_IP}"

    log '验证出口并启用国内入口 APT 与登录 shell 代理。'
    ssh_cn_entry_component "${CN_ENTRY_TIMEOUT_FINALIZE}" mutating '安装收尾' \
        "'${CN_ENTRY_REMOTE}' finalize '${CN_ENTRY_PRIVATE_IP}' '${EXIT_PRIVATE_IP}'"
    ssh_cn_entry 'apt-get update'

    trap - ERR
    log '部署完成。'
    status_all_loaded reuse-installed
    printf '%s\n' '请重新登录国内入口。之后 apt、curl、wget、Git 和大多数安装脚本可直接使用。'
    printf '%s\n' '针对不读取代理变量的 systemd Agent，可在国内入口运行：po0-cn-entry enable-service <服务名.service>'
}

status_all_loaded() (
    local role_mode=${1:-select-current} status_remote status_remote_temporary=no
    cleanup_status_remote() {
        if [[ ${status_remote_temporary} == yes ]] \
            && valid_cn_entry_scan_temp_path "${status_remote:-}"; then
            ssh_cn_entry "rm -f -- '${status_remote}'" >/dev/null 2>&1 || true
            status_remote=
        elif [[ ${status_remote_temporary} == yes && -n ${status_remote:-} ]]; then
            printf '警告：拒绝清理异常临时状态组件路径：%s\n' "${status_remote}" >&2
        fi
    }
    po0_install_exit_trap cleanup_status_remote
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    case "${role_mode}" in
        reuse-installed)
            status_remote=${CN_ENTRY_REMOTE}
            ;;
        select-current)
            preflight
            select_current_cn_entry_role status_remote status_remote_temporary
            ;;
        *) die "未知的状态检查组件模式：${role_mode}" ;;
    esac
    printf '%s\n' "[连接路径] 国外出口 ${EXIT_PRIVATE_IP} -> 国内入口 ${CN_ENTRY_PRIVATE_IP}:${CN_ENTRY_SSH_PORT}"
    printf '%s\n' '===== 国内入口 ====='
    ssh_cn_entry_component "${CN_ENTRY_TIMEOUT_STATUS}" read-only '状态检查' \
        "'${status_remote}' '${CN_ENTRY_CMD_STATUS}'"
    printf '%s\n' '===== 国外出口 ====='
    run_exit_role "${EXIT_CMD_STATUS}"
)

status_all() {
    load_config
    status_all_loaded
}

health_check_loaded() (
    local allow_repair=${1:-yes} health_remote= health_remote_temporary=no
    local exit_rc=0 cn_rc=0 overall_fail=no answer entry_started phase_started
    cleanup_health_remote() {
        if [[ ${health_remote_temporary} == yes ]] \
            && valid_cn_entry_scan_temp_path "${health_remote:-}"; then
            ssh_cn_entry "rm -f -- '${health_remote}'" >/dev/null 2>&1 || true
            health_remote=
        elif [[ ${health_remote_temporary} == yes && -n ${health_remote:-} ]]; then
            printf '警告：拒绝清理异常临时健康检查路径：%s\n' "${health_remote}" >&2
        fi
    }
    po0_install_exit_trap cleanup_health_remote
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    printf '\n%s============================================================%s\n' "${C_BLUE}" "${C_RESET}"
    printf '%s  一键健康检查%s\n' "${C_BLUE}" "${C_RESET}"
    printf '%s============================================================%s\n' "${C_BLUE}" "${C_RESET}"
    printf '%s\n' '说明：检查阶段不会重启服务或修改配置，只读取当前状态。'
    printf '\n%s【1/2 国外出口】%s\n' "${C_BLUE}" "${C_RESET}"
    if run_exit_role "${EXIT_CMD_HEALTH}"; then
        exit_rc=0
    else
        exit_rc=$?
        overall_fail=yes
    fi

    printf '\n%s【2/2 国内入口】%s\n' "${C_BLUE}" "${C_RESET}"
    entry_started=${SECONDS}
    phase_started=${SECONDS}
    printf '%s\n' '    [进行中] 检查准备：建立连接并选择当前组件'
    if ! start_cn_entry_session; then
        printf '%s\n' '    [异常] 国内入口连接：无法通过专用 SSH 密钥连接'
        printf '\n%s\n' '  小结：[异常] 国内入口无法完成检查'
        cn_rc=1
        overall_fail=yes
    else
        select_current_cn_entry_role health_remote health_remote_temporary
        printf '    [完成] 检查准备：耗时 %d 秒\n' "$((SECONDS - phase_started))"
        phase_started=${SECONDS}
        if ssh_cn_entry_component "${CN_ENTRY_TIMEOUT_HEALTH}" read-only '健康检查' \
            "'${health_remote}' '${CN_ENTRY_CMD_HEALTH}'"; then
            cn_rc=0
        else
            cn_rc=$?
            (( cn_rc == 2 )) || overall_fail=yes
        fi
        printf '\n  国内入口检查执行耗时：%d 秒\n' "$((SECONDS - phase_started))"
    fi
    printf '  国内入口阶段总耗时：%d 秒\n' "$((SECONDS - entry_started))"

    printf '\n%s【总体结果】%s\n' "${C_BLUE}" "${C_RESET}"
    if [[ ${overall_fail} == no && ${exit_rc} -eq 0 && ${cn_rc} -eq 0 ]]; then
        printf '%s\n' '  [正常] 所有核心检查均已通过'
        printf '%s\n' '  无需修复，服务器配置未被修改。'
        return 0
    fi
    if [[ ${overall_fail} == no ]]; then
        printf '%s\n' '  [提醒] 核心连接正常，但有项目需要留意'
        printf '%s\n' '  服务器配置未被修改。'
        return 0
    fi
    printf '%s\n' '  [异常] 发现需要处理的项目'
    printf '%s\n' '  安全修复只会恢复本项目自己的核心服务和国内入口组件。'
    printf '%s\n' '  不会修改连接地址、SSH 配置、系统路由、Agent 配置或第三方文件。'
    if [[ ${allow_repair} != yes || ! -t 0 ]]; then
        printf '%s\n' '  当前仅生成报告，未做修改。'
        return 1
    fi
    read -r -p '是否尝试安全修复？[y/N]：' answer
    case "${answer}" in
        y|Y|yes|YES|是) ;;
        *) printf '%s\n' '未执行修复。'; return 1 ;;
    esac

    printf '\n%s【执行安全修复】%s\n' "${C_YELLOW}" "${C_RESET}"
    run_exit_role "${EXIT_CMD_REPAIR}" \
        || { printf '%s\n' '国外出口核心服务未能全部恢复，已经保留修复前的启用/停止状态。' >&2; return 1; }
    if ssh_cn_entry true >/dev/null 2>&1; then
        upload_cn_entry_role
        printf '%s\n' '国内入口管理组件已经校验，旧文件如有变化已先备份。'
    else
        printf '%s\n' '国内入口仍无法连接，未修改国内入口。' >&2
        return 1
    fi
    cleanup_health_remote
    trap - EXIT INT TERM HUP
    printf '\n%s修复完成，正在重新检查……%s\n' "${C_GREEN}" "${C_RESET}"
    health_check_loaded no
)

health_check() (
    local config_error config_hash
    require_root
    materialize_roles
    if ! installation_active; then
        printf '%s\n' '尚未安装 Po0 解锁方案，没有可检查的运行环境。'
        printf '%s\n' '请从主菜单选择“一键安装”。'
        return 0
    fi
    if [[ ! -f ${CONFIG_FILE} || -L ${CONFIG_FILE} || ! -r ${CONFIG_FILE} ]]; then
        printf '%s\n' '[异常] 连接配置缺失或不是安全的普通文件。'
        printf '%s\n' '请从主菜单选择“更新连接配置”；脚本不会猜测地址。'
        return 1
    fi
    config_hash=$(sha256sum "${CONFIG_FILE}" | awk '{print $1}')
    if ! config_error=$( (load_config) 2>&1); then
        printf '%s\n' '[异常] 连接配置无法读取：'
        printf '  %s\n' "${config_error##*: }"
        printf '%s\n' '请从主菜单选择“更新连接配置”。'
        return 1
    fi
    load_config
    [[ $(sha256sum "${CONFIG_FILE}" | awk '{print $1}') == "${config_hash}" ]] \
        || die '健康检查期间连接配置发生变化，请重新运行。'
    health_check_loaded yes
)

sanitize_diagnostic_stream() {
    sed -E \
        -e 's#("(token|password|passwd|secret|key|authorization)"[[:space:]]*:[[:space:]]*")[^"]*"#\1[已隐藏敏感内容]"#gI' \
        -e 's#(https?|wss?|tcp|udp|ssh)://[^[:space:]]+#[已隐藏地址]#gI' \
        -e 's#([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})#[已隐藏账号]@[已隐藏域名]#g' \
        -e 's#([A-Za-z0-9-]+\.)+[A-Za-z]{2,}#[已隐藏域名]#g' \
        -e ':ip' \
        -e 's#(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9.]|$)#\1[已隐藏地址]\3#' \
        -e 't ip' \
        -e 's#([[:xdigit:]]{0,4}:){2,7}[[:xdigit:]]{0,4}#[已隐藏地址]#g' \
        -e 's#/home/[^/[:space:]]+#/home/[已隐藏账号]#g' \
        -e 's#(root|user|username|account|账号|用户)[=: ][^[:space:]]+#\1=[已隐藏账号]#gI' \
        -e 's#(token|password|passwd|secret|authorization|bearer|private[_ -]?key|密钥|令牌|密码)[=: ][^[:space:]]+#\1=[已隐藏敏感内容]#gI' \
        -e 's#SHA256:[A-Za-z0-9+/=]+#[已隐藏指纹]#g' \
        -e 's#[A-Za-z0-9+/=_-]{48,}#[已隐藏长内容]#g' \
        -e 's#:[0-9]{1,5}([^0-9]|$)#:[已隐藏端口]\1#g'
}

diagnostic_service_summary() {
    local label=$1 unit=$2 active enabled restarts result
    active=$(systemctl is-active "${unit}" 2>/dev/null || true)
    enabled=$(systemctl is-enabled "${unit}" 2>/dev/null || true)
    restarts=$(systemctl show -p NRestarts --value -- "${unit}" 2>/dev/null || true)
    result=$(systemctl show -p Result --value -- "${unit}" 2>/dev/null || true)
    printf '%s：运行=%s，开机启动=%s，重启次数=%s，结果=%s\n' \
        "${label}" "${active:-未知}" "${enabled:-未知}" "${restarts:-未知}" "${result:-未知}"
}

diagnostic_regular_root_file() {
    local path=$1 expected_mode=$2 max_bytes=$3 owner mode links size
    [[ -f ${path} && ! -L ${path} && -r ${path} ]] || return 1
    owner=$(stat -c '%u' "${path}" 2>/dev/null || true)
    mode=$(stat -c '%a' "${path}" 2>/dev/null || true)
    links=$(stat -c '%h' "${path}" 2>/dev/null || true)
    size=$(stat -c '%s' "${path}" 2>/dev/null || true)
    [[ ${owner} == 0 && ${mode} == "${expected_mode}" && ${links} == 1 ]] || return 1
    [[ ${size} =~ ^[0-9]+$ ]] || return 1
    (( 10#${size} <= max_bytes ))
}

diagnostic_root_directory() {
    local path=$1 expected_mode=$2 owner mode
    [[ -d ${path} && ! -L ${path} ]] || return 1
    owner=$(stat -c '%u' "${path}" 2>/dev/null || true)
    mode=$(stat -c '%a' "${path}" 2>/dev/null || true)
    [[ ${owner} == 0 && ${mode} == "${expected_mode}" ]]
}

diagnostic_active_state() {
    local root=${PO0_STATE_ROOT%/} active state state_name line_count
    active=${root}/ACTIVE
    diagnostic_root_directory "${root}" 700 || return 1
    diagnostic_regular_root_file "${active}" 600 1024 || return 1
    line_count=$(awk 'END { print NR + 0 }' "${active}" 2>/dev/null || true)
    [[ ${line_count} == 1 ]] || return 1
    state=$(sed -n '1p' "${active}" 2>/dev/null || true)
    [[ ${state%/*} == "${root}" ]] || return 1
    state_name=${state##*/}
    [[ ${state_name} =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || return 1
    diagnostic_root_directory "${state}" 700 || return 1
    printf '%s\n' "${state}"
}

diagnostic_tunnel_configured_at() {
    local state confirmed_state marker timestamp line_count year month day hour minute second max_day
    if ! state=$(diagnostic_active_state); then
        printf '%s\n' '未知'
        return 0
    fi
    marker=${state}/tunnel-configured-at
    if ! diagnostic_regular_root_file "${marker}" 600 128; then
        printf '%s\n' '未知'
        return 0
    fi
    line_count=$(awk 'END { print NR + 0 }' "${marker}" 2>/dev/null || true)
    timestamp=$(sed -n '1p' "${marker}" 2>/dev/null || true)
    if [[ ${line_count} != 1 \
        || ! ${timestamp} =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$ ]]; then
        printf '%s\n' '未知'
        return 0
    fi
    year=$((10#${timestamp:0:4}))
    month=$((10#${timestamp:5:2}))
    day=$((10#${timestamp:8:2}))
    hour=$((10#${timestamp:11:2}))
    minute=$((10#${timestamp:14:2}))
    second=$((10#${timestamp:17:2}))
    case "${month}" in
        1|3|5|7|8|10|12) max_day=31 ;;
        4|6|9|11) max_day=30 ;;
        2)
            max_day=28
            if (( year % 400 == 0 || (year % 4 == 0 && year % 100 != 0) )); then max_day=29; fi
            ;;
        *) printf '%s\n' '未知'; return 0 ;;
    esac
    if (( day > max_day || hour > 23 || minute > 59 || second > 59 )); then
        printf '%s\n' '未知'
        return 0
    fi
    if ! confirmed_state=$(diagnostic_active_state) || [[ ${confirmed_state} != "${state}" ]]; then
        printf '%s\n' '未知'
        return 0
    fi
    printf '%s\n' "${timestamp//:/}"
}

diagnostic_local_snapshot() {
    local os_name=未知 disk_use=未知 uptime_seconds=未知
    if [[ -r /etc/os-release ]]; then
        os_name=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | head -1 | tr -d '"')
    fi
    disk_use=$(df -P / 2>/dev/null | awk 'NR==2 {print $5}' || true)
    uptime_seconds=$(cut -d. -f1 /proc/uptime 2>/dev/null || true)
    printf '系统：%s\n' "${os_name:-未知}"
    printf '运行时长（秒）：%s\n' "${uptime_seconds:-未知}"
    printf '根分区使用率：%s\n' "${disk_use:-未知}"
    if installation_active; then
        printf '%s\n' '安装记录：存在'
    else
        printf '%s\n' '安装记录：不存在'
    fi
    printf '当前隧道配置生效时间（UTC）：%s\n' "$(diagnostic_tunnel_configured_at)"
    diagnostic_service_summary '国外出口代理' po0-unlock-exit-proxy.service
    diagnostic_service_summary '反向连接通道' po0-unlock-reverse-tunnel.service
}

diagnostic_remote_snapshot() {
    ssh_cn_entry '
set -u
os_name=未知
if test -r /etc/os-release; then
    os_name=$(sed -n "s/^PRETTY_NAME=//p" /etc/os-release | head -1 | tr -d "\"")
fi
disk_use=$(df -P / 2>/dev/null | awk "NR==2 {print \$5}" || true)
uptime_seconds=$(cut -d. -f1 /proc/uptime 2>/dev/null || true)
if test -r /var/lib/po0-unlock/ACTIVE; then
    install_state=存在
    state=$(sed -n "1p" /var/lib/po0-unlock/ACTIVE)
else
    install_state=不存在
    state=
fi
managed_count=0
managed_active=0
managed_failed=0
case "${state}" in
    /var/lib/po0-unlock/*)
        if test -s "${state}/managed-services"; then
            while IFS= read -r unit; do
                case "${unit}" in
                    ""|*[!A-Za-z0-9_.@:-]*) continue ;;
                esac
                managed_count=$((managed_count + 1))
                if systemctl is-active --quiet -- "${unit}" 2>/dev/null; then
                    managed_active=$((managed_active + 1))
                elif systemctl is-failed --quiet -- "${unit}" 2>/dev/null; then
                    managed_failed=$((managed_failed + 1))
                fi
            done <"${state}/managed-services"
        fi
        ;;
esac
printf "系统：%s\n" "${os_name:-未知}"
printf "运行时长（秒）：%s\n" "${uptime_seconds:-未知}"
printf "根分区使用率：%s\n" "${disk_use:-未知}"
printf "安装记录：%s\n" "${install_state}"
printf "托管 Agent：总数=%s，运行=%s，失败=%s\n" \
    "${managed_count}" "${managed_active}" "${managed_failed}"
'
}

diagnostic_report() (
    local raw_file report_tmp report_file stamp config_error config_ready=no
    local diagnostic_started phase_started config_seconds=0 local_snapshot_seconds=0
    local health_seconds=未执行 remote_snapshot_seconds=未执行 journal_seconds=0
    local connection_attempts=未知 total_seconds=0
    require_root
    materialize_roles
    if [[ -L ${DIAGNOSTIC_ROOT} ]]; then
        printf '%s\n' '[Po0 解锁助手] 错误：诊断报告目录不能是快捷链接。' >&2
        return 1
    fi
    if [[ -e ${DIAGNOSTIC_ROOT} && ! -d ${DIAGNOSTIC_ROOT} ]]; then
        printf '%s\n' '[Po0 解锁助手] 错误：诊断报告路径不是目录。' >&2
        return 1
    fi
    install -d -o root -g root -m 0700 "${DIAGNOSTIC_ROOT}" \
        || { printf '%s\n' '[Po0 解锁助手] 错误：无法创建受保护的诊断报告目录。' >&2; return 1; }
    [[ $(stat -c '%u' "${DIAGNOSTIC_ROOT}") == 0 ]] \
        || { printf '%s\n' '[Po0 解锁助手] 错误：诊断报告目录不属于 root。' >&2; return 1; }
    chmod 0700 "${DIAGNOSTIC_ROOT}"
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    raw_file=$(mktemp "${DIAGNOSTIC_ROOT}/.raw.${stamp}.XXXXXXXX") || return 1
    report_tmp=$(mktemp "${DIAGNOSTIC_ROOT}/.report.${stamp}.XXXXXXXX") || {
        rm -f -- "${raw_file}"
        return 1
    }
    cleanup_diagnostic() {
        rm -f -- "${raw_file:-}" "${report_tmp:-}"
    }
    po0_install_exit_trap cleanup_diagnostic
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    chmod 0600 "${raw_file}" "${report_tmp}"

    diagnostic_started=${SECONDS}
    phase_started=${SECONDS}
    if config_error=$( (load_config) 2>&1); then
        config_ready=yes
        load_config
    fi
    config_seconds=$((SECONDS - phase_started))
    {
        printf '%s\n' 'Po0 解锁助手脱敏诊断报告'
        printf '脚本版本：%s\n' "${SCRIPT_VERSION}"
        printf '生成时间（UTC）：%s\n' "${stamp}"
        printf '%s\n' '说明：本报告只读取状态；地址、域名、账号、端口和敏感内容会被隐藏。'
        printf '\n%s\n' '===== 国外出口概况 ====='
        phase_started=${SECONDS}
        diagnostic_local_snapshot
        local_snapshot_seconds=$((SECONDS - phase_started))
        if [[ ${config_ready} == yes ]]; then
            printf '%s\n' '连接配置：格式有效'
            printf '\n%s\n' '===== 完整健康检查 ====='
            phase_started=${SECONDS}
            health_check_loaded no || true
            health_seconds=$((SECONDS - phase_started))
            printf '\n%s\n' '===== 国内入口概况 ====='
            phase_started=${SECONDS}
            if ssh_cn_entry true >/dev/null 2>&1; then
                diagnostic_remote_snapshot || printf '%s\n' '国内入口概况：读取失败'
            else
                printf '%s\n' '国内入口概况：无法连接'
            fi
            remote_snapshot_seconds=$((SECONDS - phase_started))
        else
            printf '连接配置：无法读取（%s）\n' "${config_error##*: }"
        fi
        printf '\n%s\n' '===== 国外出口近期错误 ====='
        phase_started=${SECONDS}
        journalctl --no-pager -o cat -p warning \
            -u po0-unlock-exit-proxy.service \
            -u po0-unlock-reverse-tunnel.service \
            -n "${DIAGNOSTIC_LOG_LINES}" 2>&1 || true
        journal_seconds=$((SECONDS - phase_started))
        connection_attempts=$(cn_entry_initial_attempt_count)
        total_seconds=$((SECONDS - diagnostic_started))
        printf '\n%s\n' '===== 诊断采集摘要 ====='
        printf '连接配置读取耗时（秒）：%s\n' "${config_seconds}"
        printf '国外出口概况耗时（秒）：%s\n' "${local_snapshot_seconds}"
        printf '完整健康检查耗时（秒）：%s\n' "${health_seconds}"
        printf '国内入口概况耗时（秒）：%s\n' "${remote_snapshot_seconds}"
        printf '近期错误采集耗时（秒）：%s\n' "${journal_seconds}"
        printf '本次操作国内入口 SSH 初始建连尝试次数：%s\n' "${connection_attempts}"
        printf '原始诊断采集总耗时（秒）：%s\n' "${total_seconds}"
    } >"${raw_file}"

    sanitize_diagnostic_stream <"${raw_file}" >"${report_tmp}" \
        || { printf '%s\n' '[Po0 解锁助手] 错误：诊断报告脱敏失败，原始内容已删除。' >&2; return 1; }
    report_file=${DIAGNOSTIC_ROOT}/po0-diagnostic-${stamp}.txt
    [[ ! -e ${report_file} ]] \
        || { printf '%s\n' '[Po0 解锁助手] 错误：同名诊断报告已经存在。' >&2; return 1; }
    mv -- "${report_tmp}" "${report_file}"
    report_tmp=
    rm -f -- "${raw_file}"
    raw_file=
    chmod 0600 "${report_file}"
    trap - EXIT INT TERM HUP
    printf '\n%s诊断报告已生成。%s\n' "${C_GREEN}" "${C_RESET}"
    printf '保存位置：%s\n' "${report_file}"
    printf '%s\n' '报告不会自动上传；发送给他人前仍建议自行快速查看一遍。'
)

offer_diagnostic_report() {
    local answer
    [[ -t 0 ]] || return 0
    read -r -p '是否生成一份已隐藏敏感信息的诊断报告？[y/N]：' answer
    case "${answer}" in
        y|Y|yes|YES|是) diagnostic_report ;;
        *) printf '%s\n' '未生成诊断报告。' ;;
    esac
}

health_check_with_diagnostic_offer() {
    health_check || offer_diagnostic_report
}

installation_active() {
    [[ -r ${PO0_STATE_ROOT}/ACTIVE ]]
}

scan_agent_services_inner() (
    local scan_remote scan_remote_temporary=no scan_rc phase_started
    cleanup_scan_remote() {
        if valid_cn_entry_scan_temp_path "${scan_remote:-}"; then
            ssh_cn_entry "rm -f -- '${scan_remote}'" >/dev/null 2>&1 || true
            scan_remote=
        elif [[ ${scan_remote_temporary} == yes && -n ${scan_remote:-} ]]; then
            printf '警告：拒绝清理异常临时扫描路径：%s\n' "${scan_remote}" >&2
        fi
    }
    po0_install_exit_trap cleanup_scan_remote
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    phase_started=${SECONDS}
    printf '%s\n' '[组件准备] 正在选择当前国内入口组件……'
    select_current_cn_entry_role scan_remote scan_remote_temporary \
        || { scan_rc=$?; return "${scan_rc}"; }
    case "${scan_remote_temporary}" in
        no)
            [[ ${scan_remote} == "${CN_ENTRY_REMOTE}" ]] \
                || die '已安装扫描组件路径无效。'
            printf '[组件准备] 已复用已安装组件（耗时 %d 秒）。\n' "$((SECONDS - phase_started))"
            ;;
        yes)
            valid_cn_entry_scan_temp_path "${scan_remote}" \
                || die '临时扫描组件路径无效。'
            printf '[组件准备] 已校验临时组件（耗时 %d 秒）。\n' "$((SECONDS - phase_started))"
            ;;
        *) die '国内入口扫描组件状态无效。' ;;
    esac
    printf '\n%s正在扫描 国内入口上运行中的监控或转发面板 Agent……%s\n' "${C_BLUE}" "${C_RESET}"
    if ssh_cn_entry_tty "
set -eu
tmp='${scan_remote}'
temporary='${scan_remote_temporary}'
cleanup() {
    if test \"\${temporary}\" = yes; then rm -f -- \"\${tmp}\"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
command -v timeout >/dev/null 2>&1 \
    || { printf '%s\\n' '国内入口缺少 timeout，拒绝执行无界服务扫描。' >&2; exit 124; }
timeout --foreground --kill-after=5s 60s /bin/bash \"\${tmp}\" '${CN_ENTRY_CMD_SCAN}'
"; then
        scan_rc=0
    else
        scan_rc=$?
    fi
    return "${scan_rc}"
)

scan_agent_services() (
    local phase_started
    require_root
    [[ -t 0 ]] || die '扫描服务需要交互终端，请直接登录国外出口 VPS 后运行 Po0 解锁助手。'
    load_config
    phase_started=${SECONDS}
    printf '%s\n' '[扫描准备] 正在校验国内入口连接……'
    preflight
    printf '[扫描准备] 连接校验完成（耗时 %d 秒）。\n' "$((SECONDS - phase_started))"
    scan_agent_services_inner
)

reconfigure_core() {
    local config_mode=${1:-load} host_fingerprint phase_started
    case "${config_mode}" in
        load) load_config ;;
        current) use_current_connection_config ;;
        *) die '连接更新使用了无效的连接配置模式。' ;;
    esac

    phase_started=${SECONDS}
    log '阶段 1/4：校验连接并同步国内入口组件。'
    preflight
    upload_cn_entry_role
    log "阶段 1/4 完成（耗时 $((SECONDS - phase_started)) 秒）。"

    phase_started=${SECONDS}
    log '阶段 2/4：重建反向隧道并等待稳定。'
    host_fingerprint=$(ssh_cn_entry "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print \$2}'")
    [[ ${host_fingerprint} == SHA256:* ]] || die '未取得国内入口 SSH 主机指纹。'
    run_exit_role reconfigure "${host_fingerprint}" "${CN_ENTRY_PRIVATE_IP}" "${CN_ENTRY_SSH_PORT}" "${EXIT_PRIVATE_IP}"
    complete_reconfigure_config_transaction
    log "阶段 2/4 完成（耗时 $((SECONDS - phase_started)) 秒）。"

    phase_started=${SECONDS}
    log '阶段 3/4：验证代理出口并刷新托管 Agent。'
    ssh_cn_entry_component "${CN_ENTRY_TIMEOUT_REFRESH}" mutating '代理与 Agent 刷新' \
        "'${CN_ENTRY_REMOTE}' refresh '${CN_ENTRY_PRIVATE_IP}' '${EXIT_PRIVATE_IP}'"
    log "阶段 3/4 完成（耗时 $((SECONDS - phase_started)) 秒）。"

    phase_started=${SECONDS}
    log '阶段 4/4：执行最终状态检查。'
    status_all_loaded reuse-installed
    log "阶段 4/4 完成（耗时 $((SECONDS - phase_started)) 秒）。"
    log '两端连接地址与国内入口 SSH 端口重配置完成。'
}

show_connection_summary() {
    local operation=$1 load_current=${2:-yes} entry_scope exit_scope
    case "${load_current}" in
        yes) load_config ;;
        no) use_current_connection_config ;;
        *) die '执行摘要使用了无效的连接配置模式。' ;;
    esac
    entry_scope=$(ipv4_scope_label "${CN_ENTRY_PRIVATE_IP}")
    exit_scope=$(ipv4_scope_label "${EXIT_PRIVATE_IP}")
    printf '\n%s---------------------- 执行摘要 ----------------------%s\n' "${C_BLUE}" "${C_RESET}"
    printf '操作：%s\n' "${operation}"
    printf '国外出口%s源地址：%s（自动识别）\n' "${exit_scope}" "${EXIT_PRIVATE_IP}"
    printf '国内入口%s：%s\n' "${entry_scope}" "${CN_ENTRY_PRIVATE_IP}"
    printf '国内入口 SSH：root@%s:%s\n' "${CN_ENTRY_PRIVATE_IP}" "${CN_ENTRY_SSH_PORT}"
    printf '密码保存：否\n'
    printf '公网监听：不新增\n'
    printf '路由/sysctl：不修改\n'
    printf '%s------------------------------------------------------%s\n' "${C_BLUE}" "${C_RESET}"
}

guided_install() {
    require_root
    ui_header
    if installation_active; then
        printf '%s\n' '[Po0 解锁助手] 提示：检测到本方案已经安装。请从主菜单选择“更新连接配置”或“查看运行状态”。'
        return 0
    fi
    validate_official_entry_paths
    ui_step '第 1/4 步' '填写国内入口连接信息并自动识别国外出口源地址'
    configure yes
    show_connection_summary '首次一键安装'
    confirm_yes '确认按以上信息开始部署吗？'

    ui_step '第 2/4 步' '建立免密码管理连接'
    authorize load require-unclaimed

    ui_step '第 3/4 步' '安装代理、建立隧道并验证出口'
    install_core
    install_official_entry
    if [[ -t 0 && ${ASSUME_YES:-no} != yes ]]; then
        ui_step '第 4/4 步' '扫描现有 Agent，并由你选择需要国外出口的服务'
        if ! scan_agent_services; then
            printf '%s安装已经完成，但 Agent 扫描未完成；可稍后从主菜单选 4 重试。%s\n' \
                "${C_YELLOW}" "${C_RESET}" >&2
        fi
    else
        ui_step '第 4/4 步' '非交互模式：跳过 Agent 扫描'
        printf '%s\n' '安装已完成；以后可在交互终端打开 Po0 解锁助手并选择 Agent 扫描。'
    fi
    printf '\n%s一键安装全部完成。%s\n' "${C_GREEN}" "${C_RESET}"
    printf '%s\n' '以后直接输入 po0 即可；首次上传到 /root 的脚本现在可以删除。'
}

guided_reconfigure() (
    local previous_entry_ip= entry_policy
    require_root
    ui_header
    [[ -r /var/lib/po0-unlock/ACTIVE ]] \
        || die '尚未检测到有效安装，请从主菜单选择“一键安装”。'
    if [[ -e ${CONFIG_FILE} || -L ${CONFIG_FILE} ]]; then
        validate_managed_config_file "${CONFIG_FILE}" '当前连接配置'
        read_config_file "${CONFIG_FILE}"
        previous_entry_ip=${CN_ENTRY_PRIVATE_IP}
    fi
    ui_step '第 1/3 步' '更新国内入口连接信息并重新识别国外出口源地址'
    configure yes no
    show_connection_summary '更新现有隧道' no
    confirm_yes '确认按以上信息更新现有隧道吗？'
    begin_reconfigure_config_transaction
    po0_install_exit_trap cleanup_reconfigure_config_transaction
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    write_config_file

    ui_step '第 2/3 步' '验证或重新授权国内入口 SSH'
    entry_policy=$(reconfigure_entry_policy "${previous_entry_ip}" "${CN_ENTRY_PRIVATE_IP}")
    if [[ ${entry_policy} == require-unclaimed ]]; then
        log '检测到更换国内入口；将按新装处理，拒绝已被其他国外出口占用的入口。'
    fi
    authorize current "${entry_policy}"

    ui_step '第 3/3 步' '更新隧道并验证代理出口'
    reconfigure_core current
    printf '\n%s连接配置更新完成。%s\n' "${C_GREEN}" "${C_RESET}"
)

github_public_request() (
    local url=${1:-} output=${2:-}
    local -a curl_args=(
        -q --config - --silent --show-error --fail
        --proto '=https' --tlsv1.2
        --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 1
        --max-filesize "${UPDATE_MAX_BYTES}"
    )
    case "${url}" in
        "${UPDATE_API_BASE}/releases/latest") ;;
        *) return 1 ;;
    esac
    if [[ -n ${output} ]]; then curl_args+=(--output "${output}"); fi
    {
        printf 'url = "%s"\n' "${url}"
        printf '%s\n' 'header = "Accept: application/vnd.github+json"'
        printf '%s\n' 'header = "X-GitHub-Api-Version: 2022-11-28"'
    } | "${CURL_BIN}" "${curl_args[@]}"
)

github_download_public_asset() (
    local url=${1:-} output=${2:-}
    case "${url}" in
        https://github.com/Cr0ce11/po0-unlock-assistant-public/releases/download/*/po0-unlock-v2.sh) ;;
        https://release-assets.githubusercontent.com/*) ;;
        *) return 1 ;;
    esac
    [[ ${url} != *'"'* && ${url} != *'\\'* \
        && ${url} != *$'\r'* && ${url} != *$'\n'* ]] || return 1
    (( ${#url} <= 8192 )) || return 1
    [[ -f ${output} && ! -L ${output} ]] || return 1
    {
        printf 'url = "%s"\n' "${url}"
    } | "${CURL_BIN}" -q --config - --silent --show-error --fail --location \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 120 --retry 2 --retry-delay 1 \
        --max-redirs 3 --max-filesize "${UPDATE_MAX_BYTES}" --output "${output}"
)

prepare_update_state_root() {
    [[ ! -L ${UPDATE_STATE_ROOT} ]] || die '更新状态目录不能是符号链接。'
    if [[ -e ${UPDATE_STATE_ROOT} ]]; then
        [[ -d ${UPDATE_STATE_ROOT} ]] || die '更新状态路径不是目录。'
        [[ $(stat -c '%u' "${UPDATE_STATE_ROOT}") == 0 ]] || die '更新状态目录不属于 root。'
        chmod 0700 "${UPDATE_STATE_ROOT}" || die '无法保护更新状态目录。'
    else
        install -d -o root -g root -m 0700 "${UPDATE_STATE_ROOT}" \
            || die '无法创建更新状态目录。'
    fi
}

ensure_update_core_dependencies() {
    local command_name
    [[ -x ${CURL_BIN} && ! -L ${CURL_BIN} ]] || die "更新器缺少可信 curl：${CURL_BIN}"
    for command_name in sha256sum stat sed awk grep timeout flock install chmod chown mktemp mv cp; do
        command -v "${command_name}" >/dev/null || die "更新器缺少命令：${command_name}"
    done
}

ensure_update_dependencies() {
    ensure_update_core_dependencies
    if ! command -v jq >/dev/null; then
        confirm_yes '匿名更新器需要 jq 解析 GitHub Release，是否现在自动安装？'
        apt-get update || die '更新软件索引失败，尚未修改 助手脚本。'
        apt-get install -y jq || die '安装 jq 失败，尚未修改 助手脚本。'
    fi
}

validate_update_target() {
    local target_owner target_mode target_links directory_owner directory_mode target_edition
    require_root
    [[ ${SCRIPT_EDITION_LABEL} == 公开版 ]] \
        || die '匿名在线更新只适用于 Po0 公开版。'
    valid_release_version "${SCRIPT_VERSION}" \
        || die '当前是开发源码或版本号不规范；只有正式单文件版本可以在线更新。'
    [[ -f ${SCRIPT_PATH} && ! -L ${SCRIPT_PATH} ]] || die '当前脚本目标不是普通文件，拒绝更新。'
    target_owner=$(stat -c '%u' "${SCRIPT_PATH}") || die '无法读取当前脚本属主。'
    target_mode=$(stat -c '%a' "${SCRIPT_PATH}") || die '无法读取当前脚本权限。'
    target_links=$(stat -c '%h' "${SCRIPT_PATH}") || die '无法读取当前脚本链接数。'
    [[ ${target_owner} == 0 ]] || die '当前脚本不属于 root，拒绝更新。'
    [[ ${target_mode} =~ ^[0-7]{3,4}$ ]] || die '当前脚本权限格式异常。'
    (( (8#${target_mode} & 8#022) == 0 )) || die '当前脚本可被其他用户写入，拒绝更新。'
    [[ ${target_links} == 1 ]] || die '当前脚本存在异常硬链接，拒绝更新。'
    target_edition=$(static_script_edition "${SCRIPT_PATH}" || true)
    [[ ${target_edition} == 公开版 ]] || die '当前脚本不是可识别的 Po0 公开版，拒绝匿名更新。'
    [[ -d ${SCRIPT_DIR} && ! -L ${SCRIPT_DIR} ]] || die '当前脚本目录异常，拒绝更新。'
    directory_owner=$(stat -c '%u' "${SCRIPT_DIR}") || die '无法读取当前脚本目录属主。'
    directory_mode=$(stat -c '%a' "${SCRIPT_DIR}") || die '无法读取当前脚本目录权限。'
    [[ ${directory_owner} == 0 ]] || die '当前脚本目录不属于 root，拒绝更新。'
    [[ ${directory_mode} =~ ^[0-7]{3,4}$ ]] || die '当前脚本目录权限格式异常。'
    (( (8#${directory_mode} & 8#022) == 0 )) || die '当前脚本目录可被其他用户写入，拒绝更新。'
    [[ -w ${SCRIPT_DIR} ]] || die '当前脚本目录不可写，无法原子更新。'
}

acquire_script_update_lock() {
    prepare_update_state_root
    [[ ! -L ${UPDATE_BACKUP_DIR} ]] || die '更新备份目录不能是符号链接。'
    if [[ -e ${UPDATE_BACKUP_DIR} ]]; then
        [[ -d ${UPDATE_BACKUP_DIR} ]] || die '更新备份路径不是目录。'
        [[ $(stat -c '%u' "${UPDATE_BACKUP_DIR}") == 0 ]] || die '更新备份目录不属于 root。'
        chmod 0700 "${UPDATE_BACKUP_DIR}" || die '无法保护更新备份目录。'
    else
        install -d -o root -g root -m 0700 "${UPDATE_BACKUP_DIR}" \
            || die '无法创建更新备份目录。'
    fi
    [[ ! -L ${UPDATE_LOCK_FILE} ]] || die '更新锁文件不能是符号链接。'
    if [[ -e ${UPDATE_LOCK_FILE} ]]; then
        [[ -f ${UPDATE_LOCK_FILE} ]] || die '更新锁路径不是普通文件。'
        [[ $(stat -c '%u' "${UPDATE_LOCK_FILE}") == 0 ]] || die '更新锁文件不属于 root。'
        [[ $(stat -c '%h' "${UPDATE_LOCK_FILE}") == 1 ]] || die '更新锁文件存在异常硬链接。'
    fi
    exec 8>"${UPDATE_LOCK_FILE}" || die '无法打开更新锁。'
    chmod 0600 "${UPDATE_LOCK_FILE}" || die '无法保护更新锁。'
    flock -n 8 || die '另一个脚本更新或恢复操作正在进行，请稍后重试。'
}

static_script_version() {
    [[ $# -eq 1 ]] || return 1
    local file=$1 line declared_version=
    [[ -f ${file} && ! -L ${file} && -r ${file} ]] || return 1
    while IFS= read -r line || [[ -n ${line} ]]; do
        case "${line}" in
            SCRIPT_VERSION=*)
                [[ -z ${declared_version} ]] || return 1
                line=${line#SCRIPT_VERSION=}
                valid_release_version "${line}" || return 1
                declared_version=${line}
                ;;
        esac
    done <"${file}"
    [[ -n ${declared_version} ]] || return 1
    printf '%s\n' "${declared_version}"
}

static_script_edition() {
    [[ $# -eq 1 ]] || return 1
    local file=$1 line declared_edition=
    [[ -f ${file} && ! -L ${file} && -r ${file} ]] || return 1
    while IFS= read -r line || [[ -n ${line} ]]; do
        case "${line}" in
            SCRIPT_EDITION_LABEL=*)
                [[ -z ${declared_edition} ]] || return 1
                line=${line#SCRIPT_EDITION_LABEL=}
                case "${line}" in 公开版|私有版|分享版) ;; *) return 1 ;; esac
                declared_edition=${line}
                ;;
        esac
    done <"${file}"
    [[ -n ${declared_edition} ]] || return 1
    printf '%s\n' "${declared_edition}"
}

validate_uploaded_public_candidate() {
    local candidate=$1 expected_version=$2 expected_hash=$3
    local owner mode links directory directory_owner directory_mode
    local declared_version declared_edition actual_hash output
    [[ -f ${candidate} && ! -L ${candidate} && -r ${candidate} ]] \
        || { printf '%s\n' '上传的候选脚本不是可安全读取的普通文件。' >&2; return 1; }
    owner=$(stat -c '%u' "${candidate}") || return 1
    mode=$(stat -c '%a' "${candidate}") || return 1
    links=$(stat -c '%h' "${candidate}") || return 1
    [[ ${owner} == 0 && ${mode} =~ ^[0-7]{3,4}$ && ${links} == 1 ]] \
        || { printf '%s\n' '上传的候选脚本属主、权限或链接数异常。' >&2; return 1; }
    (( (8#${mode} & 8#022) == 0 )) \
        || { printf '%s\n' '上传的候选脚本不能被其他用户写入。' >&2; return 1; }
    directory=${candidate%/*}
    [[ ${directory} != "${candidate}" ]] || directory=.
    [[ -d ${directory} && ! -L ${directory} ]] \
        || { printf '%s\n' '上传的候选脚本所在目录异常。' >&2; return 1; }
    directory_owner=$(stat -c '%u' "${directory}") || return 1
    directory_mode=$(stat -c '%a' "${directory}") || return 1
    [[ ${directory_owner} == 0 && ${directory_mode} =~ ^[0-7]{3,4}$ ]] \
        || { printf '%s\n' '上传的候选脚本所在目录属主或权限异常。' >&2; return 1; }
    (( (8#${directory_mode} & 8#022) == 0 )) \
        || { printf '%s\n' '上传的候选脚本所在目录不能被其他用户写入。' >&2; return 1; }
    declared_version=$(static_script_version "${candidate}" || true)
    [[ ${declared_version} == "${expected_version}" ]] \
        || { printf '%s\n' '上传的候选脚本版本声明不一致。' >&2; return 1; }
    declared_edition=$(static_script_edition "${candidate}" || true)
    [[ ${declared_edition} == 公开版 ]] \
        || { printf '%s\n' '上传文件不是可识别的 Po0 公开版。' >&2; return 1; }
    actual_hash=$(sha256sum "${candidate}" | awk '{print $1}') || return 1
    [[ ${actual_hash} == "${expected_hash}" ]] \
        || { printf '%s\n' '上传的候选脚本在校验期间发生变化。' >&2; return 1; }
    /bin/bash -n "${candidate}" \
        || { printf '%s\n' '上传的候选脚本语法检查失败。' >&2; return 1; }
    output=$(env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 \
        timeout --kill-after=5s 30s /bin/bash "${candidate}" self-test 2>&1) \
        || { printf '%s\n' '上传的候选脚本自检失败。' >&2; return 1; }
    [[ $(grep -Fxc "Po0 单文件版本=${expected_version}" <<<"${output}" || true) -eq 1 \
        && $(grep -Fxc 'Po0 单文件版本类型=公开版' <<<"${output}" || true) -eq 1 \
        && $(grep -Fxc 'SELF_TEST=PASS' <<<"${output}" || true) -eq 1 ]] \
        || { printf '%s\n' '上传的候选脚本自检结果不完整。' >&2; return 1; }
}

confirm_same_version_local_repair() {
    local answer
    printf '%s\n' '同版本文件摘要不同；只有在你已从可信来源取得文件并核对 SHA-256 后才能继续。'
    read -r -p '请输入 REPAIR 确认同版本安全修复，其他输入取消：' answer \
        || return 1
    [[ ${answer} == REPAIR ]]
}

perform_uploaded_local_upgrade() (
    local installed_version=$1 installed_edition=${2:-未标识} operation=${3:-upgrade}
    local candidate_hash installed_hash rc command_name
    LOCAL_UPGRADE_REPLACEMENT=
    LOCAL_UPGRADE_BACKUP=
    local pointer_replacement=
    LOCAL_UPGRADE_BACKUP_IS_PERSISTENT=no
    LOCAL_UPGRADE_KEEP_PERSISTENT_BACKUP=no
    LOCAL_UPGRADE_POINTER_SNAPSHOT=
    LOCAL_UPGRADE_POINTER_PREVIOUS_STATE=absent
    LOCAL_UPGRADE_RESTORE_POINTER=no
    LOCAL_UPGRADE_UPDATE_LOCK=no
    cleanup_local_upgrade() {
        rc=$?
        trap - EXIT INT TERM HUP
        case "${LOCAL_UPGRADE_REPLACEMENT:-}" in
            "${OFFICIAL_SCRIPT_PATH}.local-upgrade."*) rm -f -- "${LOCAL_UPGRADE_REPLACEMENT}" ;;
        esac
        if [[ ${LOCAL_UPGRADE_RESTORE_POINTER:-no} == yes ]]; then
            if [[ ${LOCAL_UPGRADE_POINTER_PREVIOUS_STATE:-absent} == present ]]; then
                pointer_replacement=$(mktemp "${UPDATE_STATE_ROOT}/.handoff-pointer-restore.XXXXXXXX" 2>/dev/null || true)
                if [[ -n ${pointer_replacement} ]] \
                    && install -o root -g root -m 0600 \
                        "${LOCAL_UPGRADE_POINTER_SNAPSHOT}" "${pointer_replacement}" \
                    && mv -fT -- "${pointer_replacement}" "${UPDATE_LAST_BACKUP}"; then
                        pointer_replacement=
                else
                    LOCAL_UPGRADE_KEEP_PERSISTENT_BACKUP=yes
                    printf '%s\n' '警告：本地升级失败后未能恢复原脚本备份指针。' >&2
                fi
            elif [[ ! -L ${UPDATE_LAST_BACKUP} ]]; then
                rm -f -- "${UPDATE_LAST_BACKUP}" \
                    || { LOCAL_UPGRADE_KEEP_PERSISTENT_BACKUP=yes; printf '%s\n' '警告：本地升级失败后未能清理新脚本备份指针。' >&2; }
            else
                LOCAL_UPGRADE_KEEP_PERSISTENT_BACKUP=yes
                printf '%s\n' '警告：本地升级失败后脚本备份指针路径异常，未自动清理。' >&2
            fi
        fi
        case "${pointer_replacement:-}" in
            "${UPDATE_STATE_ROOT}/.handoff-pointer-restore."*) rm -f -- "${pointer_replacement}" ;;
        esac
        case "${LOCAL_UPGRADE_POINTER_SNAPSHOT:-}" in
            "${UPDATE_STATE_ROOT}/.handoff-pointer-before."*) rm -f -- "${LOCAL_UPGRADE_POINTER_SNAPSHOT}" ;;
        esac
        if [[ ${LOCAL_UPGRADE_BACKUP_IS_PERSISTENT:-no} == yes \
            && ${LOCAL_UPGRADE_KEEP_PERSISTENT_BACKUP:-no} != yes ]]; then
            case "${LOCAL_UPGRADE_BACKUP:-}" in
                "${UPDATE_BACKUP_DIR}/po0-unlock.v"*.backup.*) rm -f -- "${LOCAL_UPGRADE_BACKUP}" ;;
            esac
        fi
        flock -u 9 2>/dev/null || true
        exec 9>&-
        if [[ ${LOCAL_UPGRADE_UPDATE_LOCK:-no} == yes ]]; then
            flock -u 8 2>/dev/null || true
            exec 8>&-
        fi
        exit "${rc}"
    }
    po0_install_exit_trap cleanup_local_upgrade
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    [[ ${SCRIPT_EDITION_LABEL} == 公开版 ]] || die '本地上传升级只适用于 Po0 公开版。'
    valid_release_version "${SCRIPT_VERSION}" || die '上传候选的版本号无效。'
    case "${operation}" in
        upgrade)
            version_gt "${SCRIPT_VERSION}" "${installed_version}" \
                || die '上传的候选脚本不是更高版本，已安装脚本不会改变。'
            ;;
        repair)
            [[ ${SCRIPT_VERSION} == "${installed_version}" \
                && ${installed_edition} == 公开版 ]] \
                || die '同版本安全修复只适用于已安装的公开版。'
            ;;
        *) die '本地上传升级使用了无效的操作类型。' ;;
    esac
    for command_name in sha256sum stat awk grep timeout flock install chmod chown mktemp mv; do
        command -v "${command_name}" >/dev/null || die "本地上传升级缺少命令：${command_name}"
    done
    validate_official_entry_paths
    candidate_hash=$(sha256sum "${SCRIPT_PATH}" | awk '{print $1}') \
        || die '无法计算上传候选脚本的 SHA-256。'
    validate_uploaded_public_candidate "${SCRIPT_PATH}" "${SCRIPT_VERSION}" "${candidate_hash}" \
        || die '上传候选未通过本地升级校验；已安装版本未改动。'
    installed_hash=$(sha256sum "${OFFICIAL_SCRIPT_PATH}" | awk '{print $1}') \
        || die '无法计算已安装脚本的 SHA-256。'

    if [[ ${operation} == repair ]]; then
        if [[ ${candidate_hash} == "${installed_hash}" ]]; then
            printf '%s\n' '上传文件与已安装版本内容完全相同，无需执行同版本修复。'
            return 0
        fi
        printf '\n检测到 Po0 公开版同版本安全修复：\n'
        printf '  已安装：v%s（%s）\n' "${installed_version}" "${installed_edition}"
        printf '  修复文件：v%s（公开版）\n' "${SCRIPT_VERSION}"
        printf '  已安装 SHA-256：%s\n' "${installed_hash}"
        printf '  修复文件 SHA-256：%s\n' "${candidate_hash}"
        confirm_same_version_local_repair \
            || die '未确认同版本安全修复；已安装脚本保持不变。'
    else
        printf '\n检测到手动上传的 Po0 公开版新版本：\n'
        printf '  已安装：v%s（%s）\n' "${installed_version}" "${installed_edition}"
        printf '  将安装：v%s（公开版）\n' "${SCRIPT_VERSION}"
        if [[ ${installed_edition} != 公开版 ]]; then
            printf '%s\n' '  提醒：这会切换为无需令牌的公开 Release 匿名更新渠道。'
            printf '%s\n' '  旧版保存的 GitHub 令牌不会被读取或自动删除；接管后请手工撤销。'
        fi
        confirm_yes '确认校验并替换 /usr/local/sbin/po0-unlock 吗？'
    fi

    ensure_update_core_dependencies
    acquire_script_update_lock
    LOCAL_UPGRADE_UPDATE_LOCK=yes
    exec 9<"${OFFICIAL_SCRIPT_PATH}" || die '无法锁定已安装脚本。'
    flock -n 9 || die '另一个本地脚本升级正在进行，请稍后重试。'
    [[ $(sha256sum "${SCRIPT_PATH}" | awk '{print $1}') == "${candidate_hash}" ]] \
        || die '确认期间上传的候选脚本发生变化，已停止升级。'
    [[ $(sha256sum "${OFFICIAL_SCRIPT_PATH}" | awk '{print $1}') == "${installed_hash}" ]] \
        || die '确认期间已安装脚本发生变化，已停止升级。'

    LOCAL_UPGRADE_REPLACEMENT=$(mktemp "${OFFICIAL_SCRIPT_PATH}.local-upgrade.XXXXXXXX") \
        || die '无法创建本地升级候选。'
    install -o root -g root -m 0700 "${SCRIPT_PATH}" "${LOCAL_UPGRADE_REPLACEMENT}" \
        || die '无法写入本地升级候选。'
    if [[ -e ${UPDATE_LAST_BACKUP} || -L ${UPDATE_LAST_BACKUP} ]]; then
        [[ -f ${UPDATE_LAST_BACKUP} && ! -L ${UPDATE_LAST_BACKUP} \
            && $(stat -c '%u' "${UPDATE_LAST_BACKUP}") == 0 \
            && $(stat -c '%a' "${UPDATE_LAST_BACKUP}") == 600 \
            && $(stat -c '%h' "${UPDATE_LAST_BACKUP}") == 1 ]] \
            || die '原脚本备份指针的类型、属主、权限或链接数异常。'
        LOCAL_UPGRADE_POINTER_SNAPSHOT=$(mktemp "${UPDATE_STATE_ROOT}/.handoff-pointer-before.XXXXXXXX") \
            || die '无法保存原脚本备份指针。'
        install -o root -g root -m 0600 \
            "${UPDATE_LAST_BACKUP}" "${LOCAL_UPGRADE_POINTER_SNAPSHOT}" \
            || die '无法保存原脚本备份指针。'
        LOCAL_UPGRADE_POINTER_PREVIOUS_STATE=present
    fi
    LOCAL_UPGRADE_BACKUP=$(create_script_backup "${OFFICIAL_SCRIPT_PATH}" "${installed_version}") \
        || die '无法建立接管前脚本备份。'
    LOCAL_UPGRADE_BACKUP_IS_PERSISTENT=yes
    [[ $(sha256sum "${LOCAL_UPGRADE_BACKUP}" | awk '{print $1}') == "${installed_hash}" ]] \
        || die '接管前脚本备份哈希异常。'
    LOCAL_UPGRADE_RESTORE_POINTER=yes
    write_last_script_backup "${LOCAL_UPGRADE_BACKUP}" \
        || die '无法登记接管前脚本，已安装版本尚未替换。'
    [[ $(sha256sum "${LOCAL_UPGRADE_REPLACEMENT}" | awk '{print $1}') == "${candidate_hash}" \
        && $(sha256sum "${LOCAL_UPGRADE_BACKUP}" | awk '{print $1}') == "${installed_hash}" ]] \
        || die '本地升级候选或临时备份哈希异常。'
    validate_uploaded_public_candidate \
        "${LOCAL_UPGRADE_REPLACEMENT}" "${SCRIPT_VERSION}" "${candidate_hash}" \
        || die '本地升级候选未通过最终校验。'

    mv -fT -- "${LOCAL_UPGRADE_REPLACEMENT}" "${OFFICIAL_SCRIPT_PATH}" \
        || die '无法原子安装上传的候选脚本。'
    LOCAL_UPGRADE_REPLACEMENT=
    if ! validate_uploaded_public_candidate \
        "${OFFICIAL_SCRIPT_PATH}" "${SCRIPT_VERSION}" "${candidate_hash}"; then
        LOCAL_UPGRADE_REPLACEMENT=$(mktemp "${OFFICIAL_SCRIPT_PATH}.local-upgrade.XXXXXXXX") \
            || die '安装后校验失败，且无法创建恢复候选。'
        if install -o root -g root -m 0700 \
            "${LOCAL_UPGRADE_BACKUP}" "${LOCAL_UPGRADE_REPLACEMENT}" \
            && mv -fT -- "${LOCAL_UPGRADE_REPLACEMENT}" "${OFFICIAL_SCRIPT_PATH}" \
            && [[ $(sha256sum "${OFFICIAL_SCRIPT_PATH}" | awk '{print $1}') == "${installed_hash}" ]]; then
            LOCAL_UPGRADE_REPLACEMENT=
            die '公开版安装后校验失败，已经恢复原安装副本。'
        fi
        if [[ ${LOCAL_UPGRADE_BACKUP_IS_PERSISTENT} == yes ]]; then
            LOCAL_UPGRADE_KEEP_PERSISTENT_BACKUP=yes
            LOCAL_UPGRADE_RESTORE_POINTER=no
        fi
        die "公开版安装后校验失败，自动恢复也未能完成；旧脚本备份保留在：${LOCAL_UPGRADE_BACKUP}"
    fi
    LOCAL_UPGRADE_KEEP_PERSISTENT_BACKUP=yes
    LOCAL_UPGRADE_RESTORE_POINTER=no
    if [[ -n ${LOCAL_UPGRADE_POINTER_SNAPSHOT} ]]; then
        rm -f -- "${LOCAL_UPGRADE_POINTER_SNAPSHOT}" \
            || printf '%s\n' '提醒：公开版已接管，但原备份指针临时副本未能安全清理。' >&2
    fi
    LOCAL_UPGRADE_POINTER_SNAPSHOT=
    prune_script_backups "${LOCAL_UPGRADE_BACKUP}" \
        || printf '%s\n' '提醒：公开版已接管，但旧备份未能安全整理；现有备份均已保留。' >&2
    if [[ ${operation} == repair ]]; then
        printf '\n已使用手动上传文件完成 Po0 公开版 v%s 同版本安全修复；未访问任何更新服务器。\n' \
            "${SCRIPT_VERSION}"
    else
        printf '\n已从手动上传文件升级到 Po0 公开版 v%s；未访问任何更新服务器。\n' \
            "${SCRIPT_VERSION}"
    fi
)

validate_official_entry_directory() {
    local directory=$1 owner mode
    [[ ! -L ${directory} ]] || die "系统入口目录不能是快捷链接：${directory}"
    [[ ! -e ${directory} || -d ${directory} ]] || die "系统入口目录被其他文件占用：${directory}"
    [[ -e ${directory} ]] || return 0
    owner=$(stat -c '%u' "${directory}") || die "无法读取系统入口目录信息：${directory}"
    mode=$(stat -c '%a' "${directory}") || die "无法读取系统入口目录权限：${directory}"
    [[ ${owner} == 0 ]] || die "系统入口目录不属于 root：${directory}"
    [[ ${mode} =~ ^[0-7]{3,4}$ ]] || die "系统入口目录权限格式异常：${directory}"
    (( (8#${mode} & 8#022) == 0 )) || die "系统入口目录可被其他用户写入：${directory}"
}

validate_existing_official_script() {
    local owner mode links declared_version
    [[ -f ${OFFICIAL_SCRIPT_PATH} && ! -L ${OFFICIAL_SCRIPT_PATH} ]] \
        || die "正式脚本位置被其他文件占用：${OFFICIAL_SCRIPT_PATH}"
    owner=$(stat -c '%u' "${OFFICIAL_SCRIPT_PATH}") || die '无法读取正式脚本属主。'
    mode=$(stat -c '%a' "${OFFICIAL_SCRIPT_PATH}") || die '无法读取正式脚本权限。'
    links=$(stat -c '%h' "${OFFICIAL_SCRIPT_PATH}") || die '无法读取正式脚本链接数。'
    [[ ${owner} == 0 ]] || die '正式脚本不属于 root，拒绝使用。'
    [[ ${mode} =~ ^[0-7]{3,4}$ ]] || die '正式脚本权限格式异常。'
    (( (8#${mode} & 8#022) == 0 )) || die '正式脚本可被其他用户写入，拒绝使用。'
    [[ ${links} == 1 ]] || die '正式脚本存在异常硬链接，拒绝使用。'
    declared_version=$(static_script_version "${OFFICIAL_SCRIPT_PATH}" || true)
    valid_release_version "${declared_version}" || die '正式脚本不是可识别的 Po0 正式版本。'
}

validate_official_entry_paths() {
    validate_official_entry_directory "${OFFICIAL_SCRIPT_PATH%/*}"
    validate_official_entry_directory "${SHORTCUT_PATH%/*}"
    if [[ -e ${OFFICIAL_SCRIPT_PATH} || -L ${OFFICIAL_SCRIPT_PATH} ]]; then
        validate_existing_official_script
    fi
    if [[ -e ${SHORTCUT_PATH} || -L ${SHORTCUT_PATH} ]]; then
        [[ -L ${SHORTCUT_PATH} ]] || die "快捷命令 po0 已被其他文件占用：${SHORTCUT_PATH}"
        case "$(readlink -- "${SHORTCUT_PATH}")" in
            "${OFFICIAL_SCRIPT_PATH}") ;;
            "${LEGACY_SCRIPT_PATH}")
                [[ ${SCRIPT_PATH} == "${LEGACY_SCRIPT_PATH}" ]] \
                    || die "快捷命令 po0 仍指向旧版入口：${SHORTCUT_PATH}"
                validate_existing_legacy_script
                ;;
            *) die "快捷命令 po0 已指向其他位置：${SHORTCUT_PATH}" ;;
        esac
    fi
}

prepare_official_entry_directories() {
    local directory
    for directory in "${OFFICIAL_SCRIPT_PATH%/*}" "${SHORTCUT_PATH%/*}"; do
        if [[ ! -e ${directory} ]]; then
            install -d -o root -g root -m 0755 "${directory}" \
                || die "无法创建系统入口目录：${directory}"
        fi
    done
}

ensure_official_shortcut() {
    if [[ -e ${SHORTCUT_PATH} || -L ${SHORTCUT_PATH} ]]; then
        [[ -L ${SHORTCUT_PATH} && $(readlink -- "${SHORTCUT_PATH}") == "${OFFICIAL_SCRIPT_PATH}" ]] \
            || die "快捷命令 po0 已被其他文件占用：${SHORTCUT_PATH}"
        return 0
    fi
    ln -s -- "${OFFICIAL_SCRIPT_PATH}" "${SHORTCUT_PATH}" \
        || die '无法创建 po0 快捷命令。'
}

replace_managed_shortcut() {
    local target=$1 temporary=${SHORTCUT_PATH}.switch.$$
    case "${target}" in
        "${OFFICIAL_SCRIPT_PATH}"|"${LEGACY_SCRIPT_PATH}") ;;
        *) die '拒绝把 po0 指向未知位置。' ;;
    esac
    if [[ -e ${SHORTCUT_PATH} || -L ${SHORTCUT_PATH} ]]; then
        [[ -L ${SHORTCUT_PATH} ]] || die "快捷命令 po0 已被其他文件占用：${SHORTCUT_PATH}"
        case "$(readlink -- "${SHORTCUT_PATH}")" in
            "${OFFICIAL_SCRIPT_PATH}"|"${LEGACY_SCRIPT_PATH}") ;;
            *) die "快捷命令 po0 已指向其他位置：${SHORTCUT_PATH}" ;;
        esac
    fi
    [[ ! -e ${temporary} && ! -L ${temporary} ]] || die '快捷命令临时路径已被占用。'
    ln -s -- "${target}" "${temporary}" || die '无法创建 po0 快捷命令候选。'
    if ! mv -fT -- "${temporary}" "${SHORTCUT_PATH}"; then
        rm -f -- "${temporary}"
        die '无法切换 po0 快捷命令。'
    fi
}

install_official_entry() {
    local candidate=
    require_root
    valid_release_version "${SCRIPT_VERSION}" \
        || die '当前是开发源码；只有正式单文件版本可以安装系统入口。'
    validate_official_entry_paths
    prepare_official_entry_directories
    if [[ ${SCRIPT_PATH} != "${OFFICIAL_SCRIPT_PATH}" && ! -e ${OFFICIAL_SCRIPT_PATH} ]]; then
        candidate=$(mktemp "${OFFICIAL_SCRIPT_PATH}.install.XXXXXXXX") \
            || die '无法创建正式脚本候选文件。'
        if ! install -o root -g root -m 0700 "${SCRIPT_PATH}" "${candidate}" \
            || ! /bin/bash -n "${candidate}" \
            || ! cmp -s -- "${SCRIPT_PATH}" "${candidate}" \
            || ! mv -fT -- "${candidate}" "${OFFICIAL_SCRIPT_PATH}"; then
            rm -f -- "${candidate}"
            die '无法安全安装正式脚本；现有业务服务未被回滚。'
        fi
        candidate=
    fi
    validate_existing_official_script
    if [[ -L ${SHORTCUT_PATH} \
        && $(readlink -- "${SHORTCUT_PATH}") == "${LEGACY_SCRIPT_PATH}" ]]; then
        replace_managed_shortcut "${OFFICIAL_SCRIPT_PATH}"
    else
        ensure_official_shortcut
    fi
}

validate_existing_legacy_script() {
    local owner mode links declared_version
    [[ -f ${LEGACY_SCRIPT_PATH} && ! -L ${LEGACY_SCRIPT_PATH} ]] \
        || die "旧版脚本位置被其他文件占用：${LEGACY_SCRIPT_PATH}"
    owner=$(stat -c '%u' "${LEGACY_SCRIPT_PATH}") || die '无法读取旧版脚本属主。'
    mode=$(stat -c '%a' "${LEGACY_SCRIPT_PATH}") || die '无法读取旧版脚本权限。'
    links=$(stat -c '%h' "${LEGACY_SCRIPT_PATH}") || die '无法读取旧版脚本链接数。'
    [[ ${owner} == 0 ]] || die '旧版脚本不属于 root，拒绝覆盖。'
    [[ ${mode} =~ ^[0-7]{3,4}$ ]] || die '旧版脚本权限格式异常。'
    (( (8#${mode} & 8#022) == 0 )) || die '旧版脚本可被其他用户写入，拒绝覆盖。'
    [[ ${links} == 1 ]] || die '旧版脚本存在异常硬链接，拒绝覆盖。'
    declared_version=$(static_script_version "${LEGACY_SCRIPT_PATH}" || true)
    valid_release_version "${declared_version}" || die '旧版脚本位置不是可识别的 Po0 正式版本。'
}

restore_legacy_manager_entry() {
    local backup_path=$1 expected_hash=$2 replacement=
    [[ ${SCRIPT_PATH} == "${OFFICIAL_SCRIPT_PATH}" ]] \
        || die '跨系统入口撤销只能从正式助手执行。'
    validate_official_entry_directory "${LEGACY_SCRIPT_PATH%/*}"
    if [[ -e ${LEGACY_SCRIPT_PATH} || -L ${LEGACY_SCRIPT_PATH} ]]; then
        validate_existing_legacy_script
    fi
    replacement=$(mktemp "${LEGACY_SCRIPT_PATH}.restore.XXXXXXXX") \
        || die '无法创建旧版入口恢复候选。'
    if ! install -o root -g root -m 0700 "${backup_path}" "${replacement}" \
        || [[ $(sha256sum "${replacement}" | awk '{print $1}') != "${expected_hash}" ]] \
        || ! mv -fT -- "${replacement}" "${LEGACY_SCRIPT_PATH}"; then
        rm -f -- "${replacement}"
        die '无法恢复旧版脚本入口；正式助手仍然保留。'
    fi
    replacement=
    replace_managed_shortcut "${LEGACY_SCRIPT_PATH}"
}

prepare_legacy_config_for_version() {
    local target_version=$1 config_hash candidate=
    version_gt "${CONFIG_RELOCATION_VERSION}" "${target_version}" || return 0
    validate_config_directory
    validate_managed_config_file "${CONFIG_FILE}" '当前连接配置'
    config_hash=$(sha256sum "${CONFIG_FILE}" | awk '{print $1}')
    if [[ -e ${LEGACY_CONFIG_FILE} || -L ${LEGACY_CONFIG_FILE} ]]; then
        validate_managed_config_file "${LEGACY_CONFIG_FILE}" '旧版连接配置位置'
        cmp -s -- "${CONFIG_FILE}" "${LEGACY_CONFIG_FILE}" \
            || die '旧版连接配置位置已有不同内容，拒绝撤销脚本更新。'
    else
        candidate=$(mktemp "${LEGACY_CONFIG_FILE}.restore.XXXXXXXX") \
            || die '无法创建旧版连接配置恢复候选。'
        if ! install -o root -g root -m 0600 "${CONFIG_FILE}" "${candidate}" \
            || ! validate_managed_config_file "${candidate}" '旧版连接配置恢复候选' \
            || [[ $(sha256sum "${candidate}" | awk '{print $1}') != "${config_hash}" ]] \
            || ! mv -fT -- "${candidate}" "${LEGACY_CONFIG_FILE}"; then
            rm -f -- "${candidate}"
            die '无法为旧版脚本恢复连接配置；当前脚本和新配置均未改动。'
        fi
        candidate=
    fi
}

finalize_legacy_config_for_version() (
    local target_version=$1
    version_gt "${CONFIG_RELOCATION_VERSION}" "${target_version}" || return 0
    (
        validate_config_directory
        validate_managed_config_file "${CONFIG_FILE}" '当前连接配置'
        validate_managed_config_file "${LEGACY_CONFIG_FILE}" '旧版连接配置位置'
    ) >/dev/null 2>&1 || return 1
    cmp -s -- "${CONFIG_FILE}" "${LEGACY_CONFIG_FILE}" || return 1
    rm -- "${CONFIG_FILE}" || return 1
    rmdir -- "${CONFIG_DIR}" 2>/dev/null || true
)

restore_legacy_config_for_version() {
    local target_version=$1
    prepare_legacy_config_for_version "${target_version}"
    finalize_legacy_config_for_version "${target_version}" \
        || die '旧版连接配置已经准备完成，但新配置暂时无法安全清理。'
}

exec_script_preserving_mode() {
    local script=$1
    shift
    if [[ ${ASSUME_YES:-no} == yes ]]; then
        exec /bin/bash "${script}" --yes "$@"
    fi
    exec /bin/bash "${script}" "$@"
}

handoff_to_official_script() {
    exec_script_preserving_mode "${OFFICIAL_SCRIPT_PATH}" "$@"
}

maybe_handoff_to_official_entry() {
    local requested_command=${1:-} installed_version installed_edition
    case "${requested_command}" in
        self-test|__extract-role) return 0 ;;
    esac
    valid_release_version "${SCRIPT_VERSION}" || return 0
    is_root || return 0
    if [[ ${SCRIPT_PATH} == "${OFFICIAL_SCRIPT_PATH}" ]]; then
        validate_official_entry_paths
        ensure_official_shortcut
        return 0
    fi
    if [[ -e ${OFFICIAL_SCRIPT_PATH} || -L ${OFFICIAL_SCRIPT_PATH} ]]; then
        validate_official_entry_paths
        installed_version=$(static_script_version "${OFFICIAL_SCRIPT_PATH}" || true)
        valid_release_version "${installed_version}" \
            || die '已安装脚本没有可识别的正式版本号。'
        installed_edition=$(static_script_edition "${OFFICIAL_SCRIPT_PATH}" || true)
        case "${installed_edition}" in
            公开版|私有版|分享版) ;;
            *) die '已安装脚本没有可识别的 Po0 版本类型。' ;;
        esac
        if version_gt "${SCRIPT_VERSION}" "${installed_version}"; then
            perform_uploaded_local_upgrade \
                "${installed_version}" "${installed_edition}" upgrade \
                || die '公开版本地上传升级未完成；已安装脚本保持原状。'
            if [[ -L ${SHORTCUT_PATH} \
                && $(readlink -- "${SHORTCUT_PATH}") == "${LEGACY_SCRIPT_PATH}" ]]; then
                replace_managed_shortcut "${OFFICIAL_SCRIPT_PATH}"
            else
                ensure_official_shortcut
            fi
            handoff_to_official_script "$@"
            return 0
        elif [[ ${SCRIPT_VERSION} == "${installed_version}" \
            && ${installed_edition} == 公开版 ]] \
            && ! cmp -s -- "${SCRIPT_PATH}" "${OFFICIAL_SCRIPT_PATH}"; then
            perform_uploaded_local_upgrade \
                "${installed_version}" "${installed_edition}" repair \
                || die '公开版同版本安全修复未完成；已安装脚本保持原状。'
            ensure_official_shortcut
            handoff_to_official_script "$@"
            return 0
        fi
        if [[ ${SCRIPT_PATH} == "${LEGACY_SCRIPT_PATH}" \
            && -L ${SHORTCUT_PATH} \
            && $(readlink -- "${SHORTCUT_PATH}") == "${LEGACY_SCRIPT_PATH}" ]]; then
            validate_official_entry_directory "${OFFICIAL_SCRIPT_PATH%/*}"
            validate_official_entry_directory "${SHORTCUT_PATH%/*}"
            validate_existing_official_script
            replace_managed_shortcut "${OFFICIAL_SCRIPT_PATH}"
            handoff_to_official_script "$@"
            return 0
        fi
        validate_official_entry_paths
        ensure_official_shortcut
        handoff_to_official_script "$@"
        return 0
    fi
    installation_active || return 0
    install_official_entry
    printf '%s\n' '已将现有安装迁移到正式系统入口；以后直接输入 po0 即可。'
    handoff_to_official_script "$@"
}

validate_script_candidate() {
    local file=$1 expected_version=$2 expected_hash=$3 expected_edition=${4:-公开版}
    local actual_hash declared_version declared_edition self_test_output reported_version reported_edition
    local size
    case "${expected_edition}" in 公开版|私有版|分享版) ;; *) return 1 ;; esac
    [[ -f ${file} && ! -L ${file} ]] || { printf '%s\n' '候选脚本不是普通文件。' >&2; return 1; }
    size=$(stat -c '%s' "${file}")
    (( size > 0 && size <= UPDATE_MAX_BYTES )) \
        || { printf '%s\n' '候选脚本大小异常。' >&2; return 1; }
    actual_hash=$(sha256sum "${file}" | awk '{print $1}')
    [[ ${actual_hash} == "${expected_hash}" ]] \
        || { printf '%s\n' '候选脚本 SHA-256 与 GitHub Release 摘要不一致。' >&2; return 1; }
    declared_version=$(static_script_version "${file}" || true)
    [[ ${declared_version} == "${expected_version}" ]] \
        || { printf 'Release 标签与脚本版本不一致：%s != %s\n' "${expected_version}" "${declared_version:-未知}" >&2; return 1; }
    declared_edition=$(static_script_edition "${file}" || true)
    [[ ${declared_edition} == "${expected_edition}" ]] \
        || { printf '候选脚本版本类型不一致：%s != %s\n' "${expected_edition}" "${declared_edition:-未知}" >&2; return 1; }
    /bin/bash -n "${file}" || { printf '%s\n' '候选脚本语法检查失败。' >&2; return 1; }
    if ! self_test_output=$(env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 \
        timeout --kill-after=5s 30s /bin/bash "${file}" self-test 2>&1); then
        printf '%s\n' '候选脚本自检失败或超时。' >&2
        return 1
    fi
    [[ $(grep -Fxc 'SELF_TEST=PASS' <<<"${self_test_output}" || true) -eq 1 ]] \
        || { printf '%s\n' '候选脚本没有返回唯一的 SELF_TEST=PASS。' >&2; return 1; }
    reported_version=$(sed -n 's/^Po0 单文件版本=//p' <<<"${self_test_output}")
    [[ ${reported_version} == "${expected_version}" ]] \
        || { printf '%s\n' '候选脚本自检报告的版本不正确。' >&2; return 1; }
    reported_edition=$(sed -n 's/^Po0 单文件版本类型=//p' <<<"${self_test_output}")
    [[ ${reported_edition} == "${expected_edition}" ]] \
        || { printf '%s\n' '候选脚本自检报告的版本类型不正确。' >&2; return 1; }
}

create_script_backup() {
    local source=$1 version=$2 backup
    valid_release_version "${version}" || return 1
    backup=$(mktemp "${UPDATE_BACKUP_DIR}/po0-unlock.v${version}.backup.XXXXXXXX") || return 1
    if ! cp -p -- "${source}" "${backup}" \
        || ! chmod 0700 "${backup}" \
        || ! chown root:root "${backup}"; then
        rm -f -- "${backup}"
        return 1
    fi
    printf '%s\n' "${backup}"
}

write_last_script_backup() {
    local backup=$1 name hash tmp
    name=${backup##*/}
    [[ ${name} =~ ^po0-unlock\.v(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.backup\.[A-Za-z0-9]+$ ]] \
        || return 1
    hash=$(sha256sum "${backup}" | awk '{print $1}') || return 1
    [[ ${hash} =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ ! -L ${UPDATE_LAST_BACKUP} ]] || return 1
    if [[ -e ${UPDATE_LAST_BACKUP} ]]; then
        [[ -f ${UPDATE_LAST_BACKUP} ]] || return 1
        [[ $(stat -c '%u' "${UPDATE_LAST_BACKUP}") == 0 ]] || return 1
        [[ $(stat -c '%h' "${UPDATE_LAST_BACKUP}") == 1 ]] || return 1
    fi
    tmp=$(mktemp "${UPDATE_STATE_ROOT}/.last-backup.XXXXXXXX") || return 1
    if ! printf '%s %s\n' "${hash}" "${name}" >"${tmp}" \
        || ! chmod 0600 "${tmp}" \
        || ! chown root:root "${tmp}" \
        || ! mv -fT -- "${tmp}" "${UPDATE_LAST_BACKUP}"; then
        rm -f -- "${tmp}"
        return 1
    fi
}

# 改写"上一版"指针前先快照，供替换失败时原样还原。
# 指针原本不存在时输出 absent；成功时输出快照文件路径。
snapshot_last_script_backup() {
    local snapshot
    if [[ ! -e ${UPDATE_LAST_BACKUP} && ! -L ${UPDATE_LAST_BACKUP} ]]; then
        printf '%s\n' absent
        return 0
    fi
    [[ -f ${UPDATE_LAST_BACKUP} && ! -L ${UPDATE_LAST_BACKUP} \
        && $(stat -c '%u' "${UPDATE_LAST_BACKUP}") == 0 \
        && $(stat -c '%a' "${UPDATE_LAST_BACKUP}") == 600 \
        && $(stat -c '%h' "${UPDATE_LAST_BACKUP}") == 1 ]] \
        || return 1
    snapshot=$(mktemp "${UPDATE_STATE_ROOT}/.last-backup-before.XXXXXXXX") || return 1
    if ! install -o root -g root -m 0600 "${UPDATE_LAST_BACKUP}" "${snapshot}"; then
        rm -f -- "${snapshot}"
        return 1
    fi
    printf '%s\n' "${snapshot}"
}

# 把"上一版"指针还原成快照时的内容；快照值为 absent 时删除指针。
restore_last_script_backup_pointer() {
    local snapshot=${1:-} pointer_replacement=
    [[ -n ${snapshot} ]] || return 1
    if [[ ${snapshot} == absent ]]; then
        [[ ! -L ${UPDATE_LAST_BACKUP} ]] || return 1
        rm -f -- "${UPDATE_LAST_BACKUP}" || return 1
        return 0
    fi
    [[ -f ${snapshot} && ! -L ${snapshot} ]] || return 1
    [[ ! -L ${UPDATE_LAST_BACKUP} ]] || return 1
    pointer_replacement=$(mktemp "${UPDATE_STATE_ROOT}/.last-backup-restore.XXXXXXXX") || return 1
    if install -o root -g root -m 0600 "${snapshot}" "${pointer_replacement}" \
        && mv -fT -- "${pointer_replacement}" "${UPDATE_LAST_BACKUP}"; then
        return 0
    fi
    rm -f -- "${pointer_replacement}"
    return 1
}

# 指针已还原后，本次新建的备份就成了没人引用的孤儿，删掉以免占用保留额度。
discard_orphan_script_backup() {
    local backup=${1:-}
    case "${backup}" in
        "${UPDATE_BACKUP_DIR}"/po0-unlock.v*.backup.*) rm -f -- "${backup}" || return 1 ;;
        *) return 1 ;;
    esac
}

prune_script_backups() (
    local protected=$1 path name owner links mtime oldest_mtime oldest_path= oldest_index= index
    local remaining=0 allowed_nonprotected=$((UPDATE_BACKUP_KEEP - 1))
    local -a candidates=()
    (( UPDATE_BACKUP_KEEP >= 1 )) || return 1
    [[ -d ${UPDATE_BACKUP_DIR} && ! -L ${UPDATE_BACKUP_DIR} ]] || return 1
    [[ $(stat -c '%u' "${UPDATE_BACKUP_DIR}") == 0 \
        && $(stat -c '%a' "${UPDATE_BACKUP_DIR}") == 700 ]] || return 1
    case "${protected}" in "${UPDATE_BACKUP_DIR}"/po0-unlock.v*.backup.*) ;; *) return 1 ;; esac
    name=${protected##*/}
    [[ ${name} =~ ^po0-unlock\.v(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.backup\.[A-Za-z0-9]+$ ]] \
        || return 1
    [[ -f ${protected} && ! -L ${protected} ]] || return 1
    [[ $(stat -c '%u' "${protected}") == 0 \
        && $(stat -c '%h' "${protected}") == 1 ]] || return 1

    shopt -s nullglob
    for path in "${UPDATE_BACKUP_DIR}"/po0-unlock.v*.backup.*; do
        name=${path##*/}
        [[ ${name} =~ ^po0-unlock\.v(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.backup\.[A-Za-z0-9]+$ ]] \
            || continue
        [[ -f ${path} && ! -L ${path} ]] || return 1
        owner=$(stat -c '%u' "${path}") || return 1
        links=$(stat -c '%h' "${path}") || return 1
        [[ ${owner} == 0 && ${links} == 1 ]] || return 1
        [[ ${path} == "${protected}" ]] && continue
        candidates[${#candidates[@]}]=${path}
        remaining=$((remaining + 1))
    done
    shopt -u nullglob

    while (( remaining > allowed_nonprotected )); do
        oldest_path=
        oldest_mtime=
        oldest_index=
        for index in "${!candidates[@]}"; do
            path=${candidates[${index}]}
            [[ -n ${path} ]] || continue
            mtime=$(stat -c '%Y' "${path}") || return 1
            [[ ${mtime} =~ ^-?[0-9]+$ ]] || return 1
            if [[ -z ${oldest_path} ]] \
                || (( mtime < oldest_mtime )) \
                || { (( mtime == oldest_mtime )) && [[ ${path} < ${oldest_path} ]]; }; then
                    oldest_path=${path}
                    oldest_mtime=${mtime}
                    oldest_index=${index}
            fi
        done
        [[ -n ${oldest_path} && -n ${oldest_index} ]] || return 1
        [[ -f ${oldest_path} && ! -L ${oldest_path} ]] || return 1
        [[ $(stat -c '%u' "${oldest_path}") == 0 \
            && $(stat -c '%h' "${oldest_path}") == 1 ]] || return 1
        rm -f -- "${oldest_path}" || return 1
        unset "candidates[${oldest_index}]"
        remaining=$((remaining - 1))
    done
)

perform_script_update() (
    set +x
    ulimit -c 0 2>/dev/null || true
    local release_json metadata tag latest_version asset_url expected_hash current_hash candidate= backup= installed_hash
    local answer rc pointer_snapshot= restore_pointer=no keep_orphan_backup=no
    UPDATE_TRANSACTION_CANDIDATE=
    cleanup_update_transaction() {
        rc=$?
        trap - EXIT INT TERM HUP
        case "${UPDATE_TRANSACTION_CANDIDATE:-}" in
            "${SCRIPT_PATH}.update."*) rm -f -- "${UPDATE_TRANSACTION_CANDIDATE}" ;;
        esac
        UPDATE_TRANSACTION_CANDIDATE=
        # 替换没有真正完成时，把"上一版"指针还原成本次改写前的内容，
        # 否则本次新建的备份会顶掉真正的恢复点，"恢复上一版助手"将永远回答无需撤销。
        if [[ ${restore_pointer:-no} == yes ]]; then
            if restore_last_script_backup_pointer "${pointer_snapshot}"; then
                if [[ ${keep_orphan_backup:-no} != yes && -n ${backup:-} ]]; then
                    discard_orphan_script_backup "${backup}" \
                        || printf '%s\n' '提醒：更新失败后未能清理本次新建的脚本备份。' >&2
                fi
            else
                printf '%s\n' '警告：更新失败后未能还原原脚本备份指针；请人工核对 /var/lib/po0-unlock/updater 下的备份。' >&2
            fi
        fi
        case "${pointer_snapshot:-}" in
            "${UPDATE_STATE_ROOT}/.last-backup-before."*) rm -f -- "${pointer_snapshot}" ;;
        esac
        exit "${rc}"
    }
    po0_install_exit_trap cleanup_update_transaction
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    validate_update_target
    [[ -x ${CURL_BIN} && ! -L ${CURL_BIN} ]] || die '匿名更新器缺少可信 curl。'
    ensure_update_core_dependencies
    acquire_script_update_lock
    ensure_update_dependencies

    release_json=$(github_public_request "${UPDATE_API_BASE}/releases/latest") \
        || die '无法读取最新正式 Release；请确认仓库已经发布正式版本。'
    metadata=$(jq -cer --arg asset_name "${UPDATE_ASSET}" '
        select(.draft == false and .prerelease == false) |
        ([.assets[]? | select(.name == $asset_name)] | if length == 1 then .[0] else empty end) as $asset |
        {
            tag: (.tag_name // ""),
            url: ($asset.browser_download_url // ""),
            digest: (($asset.digest // "") | sub("^sha256:"; ""))
        }
    ' <<<"${release_json}") || die '最新 Release 元数据不完整或发行资产不唯一。'
    tag=$(jq -r '.tag' <<<"${metadata}")
    asset_url=$(jq -r '.url' <<<"${metadata}")
    expected_hash=$(jq -r '.digest' <<<"${metadata}" | tr 'A-F' 'a-f')
    [[ ${tag} == v* ]] || die '最新 Release 标签格式无效。'
    latest_version=${tag#v}
    valid_release_version "${latest_version}" || die '最新 Release 版本号不是严格的 x.y.z 格式。'
    [[ ${asset_url} == "https://github.com/${UPDATE_REPOSITORY}/releases/download/${tag}/${UPDATE_ASSET}" ]] \
        || die '最新 Release 资产地址不属于指定仓库。'
    [[ ${expected_hash} =~ ^[0-9a-f]{64}$ ]] || die '最新 Release 缺少可信 SHA-256 digest。'

    current_hash=$(sha256sum "${SCRIPT_PATH}" | awk '{print $1}')
    if version_gt "${SCRIPT_VERSION}" "${latest_version}"; then
        die "当前版本 ${SCRIPT_VERSION} 高于最新正式版 ${latest_version}，拒绝自动降级。"
    fi
    if [[ ${SCRIPT_VERSION} == "${latest_version}" && ${current_hash} == "${expected_hash}" ]]; then
        printf '当前已经是最新正式版 v%s，脚本内容也完全一致。\n' "${SCRIPT_VERSION}"
        return 0
    fi

    candidate=$(mktemp "${SCRIPT_PATH}.update.XXXXXXXX") || die '无法在脚本目录创建更新候选。'
    UPDATE_TRANSACTION_CANDIDATE=${candidate}
    github_download_public_asset "${asset_url}" "${candidate}" \
        || die '最新脚本下载失败；当前版本未改动。'
    validate_script_candidate "${candidate}" "${latest_version}" "${expected_hash}" \
        || die '最新脚本未通过安全校验；当前版本未改动。'

    printf '\n当前脚本：v%s\n最新正式版：v%s\nSHA-256：%s\n' \
        "${SCRIPT_VERSION}" "${latest_version}" "${expected_hash}"
    if [[ ${SCRIPT_VERSION} == "${latest_version}" ]]; then
        printf '%s\n' '版本号相同但本机脚本内容不同；继续会用正式 Release 修复本机脚本。'
    fi
    if [[ ${ASSUME_YES:-no} != yes ]]; then
        read -r -p '确认备份当前脚本并更新？[y/N]：' answer
        case "${answer}" in y|Y|yes|YES|是) ;; *) printf '%s\n' '已取消更新。'; return 0 ;; esac
    fi

    [[ $(sha256sum "${SCRIPT_PATH}" | awk '{print $1}') == "${current_hash}" ]] \
        || die '确认期间当前脚本发生变化，已停止更新。'
    backup=$(create_script_backup "${SCRIPT_PATH}" "${SCRIPT_VERSION}") \
        || die '无法备份当前脚本，已停止更新。'
    [[ $(sha256sum "${backup}" | awk '{print $1}') == "${current_hash}" ]] \
        || die '当前脚本备份哈希异常，已停止更新。'
    pointer_snapshot=$(snapshot_last_script_backup) \
        || die '无法保存原脚本备份指针，已停止更新；当前脚本尚未替换。'
    restore_pointer=yes
    write_last_script_backup "${backup}" \
        || die '无法登记更新前脚本，已停止更新；当前脚本尚未替换。'
    chmod 0700 "${candidate}" || die '无法设置候选脚本权限。'
    chown root:root "${candidate}" || die '无法设置候选脚本属主。'
    [[ $(sha256sum "${candidate}" | awk '{print $1}') == "${expected_hash}" ]] \
        || die '安装前候选脚本哈希发生变化，已停止更新。'
    mv -fT -- "${candidate}" "${SCRIPT_PATH}" \
        || die '原子替换失败；当前脚本未改动，原有的恢复上一版入口仍然可用。'
    candidate=
    UPDATE_TRANSACTION_CANDIDATE=
    installed_hash=$(sha256sum "${SCRIPT_PATH}" | awk '{print $1}')
    if [[ ${installed_hash} != "${expected_hash}" ]]; then
        candidate=$(mktemp "${SCRIPT_PATH}.update.XXXXXXXX") || die '更新后校验失败，且无法创建恢复候选。'
        UPDATE_TRANSACTION_CANDIDATE=${candidate}
        if install -o root -g root -m 0700 "${backup}" "${candidate}" \
            && mv -fT -- "${candidate}" "${SCRIPT_PATH}" \
            && [[ $(sha256sum "${SCRIPT_PATH}" | awk '{print $1}') == "${current_hash}" ]]; then
            candidate=
            UPDATE_TRANSACTION_CANDIDATE=
            die '更新后哈希校验失败，已经恢复旧脚本。'
        fi
        # 目标脚本既不是新版也没能恢复成旧版，用户要靠这个备份人工恢复，不能删。
        keep_orphan_backup=yes
        die '更新后哈希校验失败，自动恢复也未能完成；请使用保留的备份人工恢复。'
    fi
    restore_pointer=no
    prune_script_backups "${backup}" \
        || printf '%s\n' '提醒：脚本已经更新成功，但旧备份未能安全整理；现有备份均已保留。' >&2
    printf '\n脚本已安全更新到 v%s；备份已保留。\n' "${latest_version}"
    return 20
)

perform_script_restore() (
    local backup_name backup_path backup_version backup_edition backup_hash recorded_hash extra current_hash current_backup= replacement= answer rc
    local pointer_snapshot= restore_pointer=no
    cleanup_restore_transaction() {
        rc=$?
        trap - EXIT INT TERM HUP
        case "${replacement:-}" in "${SCRIPT_PATH}.restore."*) rm -f -- "${replacement}" ;; esac
        # 撤销没有真正完成时还原"上一版"指针，否则这台机器再也无法通过助手退回旧版。
        if [[ ${restore_pointer:-no} == yes ]]; then
            if restore_last_script_backup_pointer "${pointer_snapshot}"; then
                if [[ -n ${current_backup:-} ]]; then
                    discard_orphan_script_backup "${current_backup}" \
                        || printf '%s\n' '提醒：撤销失败后未能清理本次新建的脚本备份。' >&2
                fi
            else
                printf '%s\n' '警告：撤销失败后未能还原原脚本备份指针；请人工核对 /var/lib/po0-unlock/updater 下的备份。' >&2
            fi
        fi
        case "${pointer_snapshot:-}" in
            "${UPDATE_STATE_ROOT}/.last-backup-before."*) rm -f -- "${pointer_snapshot}" ;;
        esac
        exit "${rc}"
    }
    po0_install_exit_trap cleanup_restore_transaction
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    validate_update_target
    if [[ ! -r ${UPDATE_LAST_BACKUP} ]]; then
        printf '%s\n' '还没有可用于撤销最近一次更新的脚本备份。'
        return 0
    fi
    acquire_script_update_lock
    [[ -f ${UPDATE_LAST_BACKUP} && ! -L ${UPDATE_LAST_BACKUP} ]] || die '脚本更新备份记录格式异常。'
    [[ $(stat -c '%u' "${UPDATE_LAST_BACKUP}") == 0 \
        && $(stat -c '%a' "${UPDATE_LAST_BACKUP}") == 600 \
        && $(stat -c '%h' "${UPDATE_LAST_BACKUP}") == 1 ]] \
        || die '脚本更新备份记录的权限或属主异常。'
    IFS=' ' read -r recorded_hash backup_name extra <"${UPDATE_LAST_BACKUP}" \
        || die '无法读取脚本更新备份记录。'
    [[ ${recorded_hash} =~ ^[0-9a-f]{64}$ && -z ${extra} ]] \
        || die '脚本更新备份记录缺少可信 SHA-256。'
    [[ ${backup_name} =~ ^po0-unlock\.v(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.backup\.[A-Za-z0-9]+$ ]] \
        || die '脚本更新备份名称无效。'
    backup_path=${UPDATE_BACKUP_DIR}/${backup_name}
    [[ -f ${backup_path} && ! -L ${backup_path} ]] || die '脚本更新备份不存在或不是普通文件。'
    [[ $(stat -c '%u' "${backup_path}") == 0 \
        && $(stat -c '%h' "${backup_path}") == 1 ]] \
        || die '脚本更新备份的属主或链接数异常。'
    backup_version=$(static_script_version "${backup_path}" || true)
    valid_release_version "${backup_version}" || die '脚本更新备份缺少有效版本号。'
    backup_edition=$(static_script_edition "${backup_path}" || true)
    case "${backup_edition}" in 公开版|私有版|分享版) ;; *) die '脚本更新备份缺少有效版本类型。' ;; esac
    backup_hash=$(sha256sum "${backup_path}" | awk '{print $1}')
    [[ ${backup_hash} == "${recorded_hash}" ]] || die '脚本更新备份的 SHA-256 与创建时记录不一致。'
    validate_script_candidate "${backup_path}" "${backup_version}" "${recorded_hash}" "${backup_edition}" \
        || die '脚本更新备份未通过安全校验，无法撤销更新。'
    current_hash=$(sha256sum "${SCRIPT_PATH}" | awk '{print $1}')
    if [[ ${current_hash} == "${backup_hash}" ]]; then
        printf '%s\n' '当前脚本已经与更新前的备份相同，无需撤销。'
        return 0
    fi
    printf '\n当前脚本：v%s\n撤销后版本：v%s\n' "${SCRIPT_VERSION}" "${backup_version}"
    printf '%s\n' '这里只恢复上一版助手，不会修改代理、隧道或 Agent 服务。'
    if [[ ${ASSUME_YES:-no} != yes ]]; then
        read -r -p '确认恢复上一版助手？[y/N]：' answer
        case "${answer}" in y|Y|yes|YES|是) ;; *) printf '%s\n' '已取消恢复。'; return 0 ;; esac
    fi
    [[ $(sha256sum "${SCRIPT_PATH}" | awk '{print $1}') == "${current_hash}" ]] \
        || die '确认期间当前脚本发生变化，已停止撤销。'
    current_backup=$(create_script_backup "${SCRIPT_PATH}" "${SCRIPT_VERSION}") \
        || die '无法备份当前脚本，已停止撤销。'
    [[ $(sha256sum "${current_backup}" | awk '{print $1}') == "${current_hash}" ]] \
        || die '当前脚本备份哈希异常，已停止撤销。'
    prepare_legacy_config_for_version "${backup_version}"
    pointer_snapshot=$(snapshot_last_script_backup) \
        || die '无法保存原脚本备份指针，已停止撤销；当前脚本尚未替换。'
    restore_pointer=yes
    write_last_script_backup "${current_backup}" \
        || die '无法登记撤销前的脚本，已停止撤销；当前脚本尚未替换。'
    if [[ ${SCRIPT_PATH} == "${OFFICIAL_SCRIPT_PATH}" ]] \
        && version_gt "${CANONICAL_ENTRY_VERSION}" "${backup_version}"; then
            restore_legacy_manager_entry "${backup_path}" "${backup_hash}"
            restore_pointer=no
            finalize_legacy_config_for_version "${backup_version}" \
                || printf '%s\n' '提醒：助手已经恢复成功，旧版配置可正常使用，但新位置的相同配置未能安全清理。' >&2
            prune_script_backups "${current_backup}" \
                || printf '%s\n' '提醒：助手已经恢复成功，但旧备份未能安全整理；现有备份均已保留。' >&2
            printf '\n已撤销到 v%s，并恢复该版本使用的旧版脚本入口。\n' "${backup_version}"
            return 20
    fi
    replacement=$(mktemp "${SCRIPT_PATH}.restore.XXXXXXXX") || die '无法创建撤销更新候选。'
    install -o root -g root -m 0700 "${backup_path}" "${replacement}" \
        || die '无法写入撤销更新候选。'
    [[ $(sha256sum "${replacement}" | awk '{print $1}') == "${backup_hash}" ]] \
        || die '撤销更新候选哈希异常。'
    mv -fT -- "${replacement}" "${SCRIPT_PATH}" \
        || die '撤销脚本更新失败；当前脚本未改动，原有的恢复上一版入口仍然可用。'
    replacement=
    restore_pointer=no
    finalize_legacy_config_for_version "${backup_version}" \
        || printf '%s\n' '提醒：助手已经恢复成功，旧版配置可正常使用，但新位置的相同配置未能安全清理。' >&2
    prune_script_backups "${current_backup}" \
        || printf '%s\n' '提醒：助手已经恢复成功，但旧备份未能安全整理；现有备份均已保留。' >&2
    printf '\n已恢复上一版助手，当前版本为 v%s。\n' "${backup_version}"
    return 20
)

run_script_update() {
    local mode=${1:-direct} rc
    case "${mode}" in direct|menu) ;; *) die "未知的脚本更新调用方式：${mode}" ;; esac
    if perform_script_update; then return 0; else rc=$?; fi
    if [[ ${rc} -eq 20 ]]; then
        [[ ${mode} == menu && -t 0 && -t 1 ]] || return 0
        printf '%s\n' '正在切换到新版本进程……'
        exec_script_preserving_mode "${SCRIPT_PATH}"
    fi
    return "${rc}"
}

run_script_restore() {
    local mode=${1:-direct} rc
    case "${mode}" in direct|menu) ;; *) die "未知的脚本恢复调用方式：${mode}" ;; esac
    if perform_script_restore; then return 0; else rc=$?; fi
    if [[ ${rc} -eq 20 ]]; then
        [[ ${mode} == menu && -t 0 && -t 1 ]] || return 0
        printf '%s\n' '正在切换到撤销更新后的脚本进程……'
        if [[ -L ${SHORTCUT_PATH} \
            && $(readlink -- "${SHORTCUT_PATH}") == "${LEGACY_SCRIPT_PATH}" ]]; then
            exec_script_preserving_mode "${LEGACY_SCRIPT_PATH}"
        fi
        exec_script_preserving_mode "${SCRIPT_PATH}"
    fi
    return "${rc}"
}

release_script_update_lock() {
    flock -u 8 2>/dev/null || true
    exec 8>&-
}

pause_for_key() {
    local prompt=$1 ignored
    if [[ -t 0 ]]; then
        printf '%s' "${prompt}"
        # ShellCheck SC2034：read 需要接收变量名，但暂停流程有意忽略读取值。
        # shellcheck disable=SC2034
        IFS= read -r -s -n 1 ignored || true
        printf '\n'
    fi
}

pause_for_update_menu() {
    pause_for_key '按任意键返回脚本更新与恢复……'
}

manage_script_update() {
    local choice
    while :; do
        printf '\n脚本更新与恢复\n'
        printf '%s\n' '  1) 检查并更新脚本' '  2) 恢复上一版助手（不改服务）' '  0) 返回主菜单'
        read -r -p '请选择 [0-2]：' choice
        case "${choice}" in
            1)
                if ! run_script_update menu; then
                    printf '%s\n' '脚本更新未完成。' >&2
                fi
                pause_for_update_menu
                ;;
            2)
                if ! run_script_restore menu; then
                    printf '%s\n' '恢复上一版助手未完成。' >&2
                fi
                pause_for_update_menu
                ;;
            0) return 0 ;;
            *) printf '%s\n' '选择无效，请重新选择。' >&2 ;;
        esac
    done
}

rollback_all() {
    local mode=${1:-direct} cn_entry_state
    case "${mode}" in direct|menu) ;; *) die "未知的完整回滚调用方式：${mode}" ;; esac
    if ! confirm ROLLBACK '将停止本机反向隧道，移除国内入口代理配置和受限账户，并恢复国外出口 Tinyproxy 原状态。'; then
        printf '%s\n' '已取消完整回滚，服务器未做任何修改。'
        return 0
    fi
    load_config
    preflight
    upload_cn_entry_role
    if ! cn_entry_state=$(ssh_cn_entry "if test -r /var/lib/po0-unlock/ACTIVE; then printf ACTIVE; else printf NONE; fi"); then
        die '无法确认国内入口回滚状态，未停止国外出口隧道。'
    fi
    case "${cn_entry_state}" in ACTIVE|NONE) ;; *) die '国内入口返回了无法识别的回滚状态。' ;; esac

    if [[ ${cn_entry_state} == ACTIVE ]]; then
        ssh_cn_entry_component "${CN_ENTRY_TIMEOUT_ROLLBACK_SERVICES}" mutating 'Agent 回滚阶段' \
            "'${CN_ENTRY_REMOTE}' '${CN_ENTRY_CMD_ROLLBACK_SERVICES}'"
    else
        log '国内入口已无 ACTIVE 状态，跳过 Agent 回滚阶段。'
    fi
    if [[ -r /var/lib/po0-unlock/ACTIVE ]]; then
        run_exit_role "${EXIT_CMD_ROLLBACK}"
    else
        log '国外出口已无 ACTIVE 状态，跳过国外出口隧道回滚并继续完成国内入口清理。'
    fi
    if [[ ${cn_entry_state} == ACTIVE ]]; then
        ssh_cn_entry_component "${CN_ENTRY_TIMEOUT_ROLLBACK_FINALIZE}" mutating '最终回滚阶段' \
            "'${CN_ENTRY_REMOTE}' '${CN_ENTRY_CMD_ROLLBACK_FINALIZE}'"
    fi
    ssh_cn_entry "rm -f '${CN_ENTRY_REMOTE}'"
    log '两端均已回滚。备份状态目录仍保留。'
    if [[ ${mode} == menu ]]; then
        pause_for_menu
    fi
}

pause_for_menu() {
    pause_for_key '按任意键返回主菜单……'
}

main_menu() {
    local choice state_text
    require_root
    [[ -t 0 ]] || die "当前不是交互终端；请使用 ${PROGRAM_NAME} help 查看直接命令。"
    while :; do
        if installation_active; then
            state_text="${C_GREEN}已安装${C_RESET}"
        else
            state_text="${C_YELLOW}未安装${C_RESET}"
        fi
        ui_header
        printf '当前状态：%b\n\n' "${state_text}"
        printf '  %s1)%s 一键安装（填写信息 + SSH 授权 + 自动安装）\n' "${C_GREEN}" "${C_RESET}"
        printf '  %s2)%s 更新连接配置（地址/端口变化时使用）\n' "${C_BLUE}" "${C_RESET}"
        printf '  3) 健康检查与问题处理\n'
        printf '  %s4)%s 扫描 Agent 服务并配置国外出口\n' "${C_GREEN}" "${C_RESET}"
        printf '  5) 完整回滚\n'
        printf '  %s6)%s 脚本更新与恢复\n' "${C_BLUE}" "${C_RESET}"
        printf '  0) 退出\n\n'
        read -r -p '请选择 [0-6]：' choice
        case "${choice}" in
            1) run_cn_entry_operation guided_install; pause_for_menu ;;
            2) run_cn_entry_operation guided_reconfigure; pause_for_menu ;;
            3) run_cn_entry_operation health_check_with_diagnostic_offer; pause_for_menu ;;
            4)
                if ! run_cn_entry_operation scan_agent_services; then
                    printf '%sAgent 扫描未完成；请检查上方提示，稍后可从主菜单选 4 重试。%s\n' \
                        "${C_YELLOW}" "${C_RESET}" >&2
                fi
                pause_for_menu
                ;;
            5) run_cn_entry_operation rollback_all menu ;;
            6) manage_script_update ;;
            0) printf '已退出。\n'; return 0 ;;
            *) printf '%s\n' '选择无效，请重新选择。' >&2; pause_for_menu ;;
        esac
    done
}

usage() {
    cat <<EOF
推荐用法（中文菜单）：
  ./${PROGRAM_NAME}

也可以直接运行单个操作：
  ./${PROGRAM_NAME} install       一次完成配置、授权和首次安装
  ./${PROGRAM_NAME} reconfigure   一次完成配置、授权和隧道更新
  ./${PROGRAM_NAME} scan-agents   扫描 Agent 服务并按编号配置代理
  ./${PROGRAM_NAME} status        健康检查（非交互时只读）
  ./${PROGRAM_NAME} diagnose      生成本机脱敏诊断报告（只读）
  ./${PROGRAM_NAME} raw-status    显示原始运行状态
  ./${PROGRAM_NAME} rollback      完整回滚
  ./${PROGRAM_NAME} update        匿名检查公开 Release 并更新脚本
  ./${PROGRAM_NAME} restore-script 恢复上一版助手（不改服务）

高级排障命令：
  ./${PROGRAM_NAME} configure
  ./${PROGRAM_NAME} authorize
  ./${PROGRAM_NAME} self-test
EOF
}

ASSUME_YES=no
if [[ ${1:-} == --yes ]]; then ASSUME_YES=yes; shift; fi

maybe_handoff_to_official_entry "$@"
maybe_migrate_config "$@"

case "${1:-}" in
    configure) configure ;;
    authorize) run_cn_entry_operation authorize ;;
    install) run_cn_entry_operation guided_install ;;
    reconfigure) run_cn_entry_operation guided_reconfigure ;;
    scan-agents) run_cn_entry_operation scan_agent_services ;;
    status|health) run_cn_entry_operation health_check ;;
    diagnose) run_cn_entry_operation diagnostic_report ;;
    raw-status) run_cn_entry_operation status_all ;;
    rollback) run_cn_entry_operation rollback_all direct ;;
    update) run_script_update ;;
    restore-script) run_script_restore ;;
    self-test) bundle_self_test ;;
    __extract-role) extract_embedded_role "${2:-}" ;;
    help|-h|--help) usage ;;
    '') main_menu ;;
    *) usage; exit 2 ;;
esac
