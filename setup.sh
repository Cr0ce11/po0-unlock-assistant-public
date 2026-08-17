#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# 本脚本必须在国外出口 VPS 上以 root 运行。
SCRIPT_VERSION=${SCRIPT_VERSION:-dev}
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
EXIT_ROLE=${SCRIPT_DIR}/overseas-exit-role.sh
CN_ENTRY_ROLE_LOCAL=${SCRIPT_DIR}/cn-entry-role.sh
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
        # 只读子命令不得触发任何写路径：从候选副本运行 check 时也不该接管已安装脚本。
        self-test|__extract-role|check) return 0 ;;
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
        # 只读子命令不得触发任何写路径：从候选副本运行 check 时也不该接管已安装脚本。
        self-test|__extract-role|check) return 0 ;;
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

# ——— 只读状态检查入口（供非交互调用方定时巡检） ———
# 只读：不改连接配置、不动服务、不建恢复点、不写任何持久状态；为了检查国内入口，
# 会经由既有流程释放内置组件并建立 SSH 控制会话，这些都是用完即删的临时运行文件。
# 内部用 10/11/12/13 表示结论，再由 run_readonly_check 翻译成对外的 0/1/2/3——
# 这样「检查结论」和 die 的退出码 1 不会混淆。
READONLY_CHECK_OK=10
READONLY_CHECK_WARN=11
READONLY_CHECK_ERROR=12
READONLY_CHECK_TOOL_ERROR=13

readonly_check_json_escape() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\t'/ }
    value=${value//$'\r'/ }
    printf '%s' "${value}"
}

readonly_check_level_key() {
    case "${1:-}" in
        正常) printf 'ok' ;;
        提醒) printf 'warn' ;;
        异常) printf 'error' ;;
        *) printf 'unknown' ;;
    esac
}

readonly_check_report_tool_error() {
    local mode=$1 reason=$2
    if [[ ${mode} == json ]]; then
        printf '{"overall":"tool_error","checked_at":"%s","version":"%s","error":"%s","checks":[]}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SCRIPT_VERSION}" \
            "$(readonly_check_json_escape "${reason}")"
    else
        printf '%s\n' 'Po0 状态：检查未完成'
        printf '原因：%s\n' "${reason}"
    fi
}

readonly_check() (
    local mode=${1:-human} exit_output= entry_output= config_error=
    local remote= remote_temporary=no line level name detail key
    local ok_count=0 warn_count=0 error_count=0 json_items= attention=

    cleanup_readonly_check() {
        if [[ ${remote_temporary} == yes ]] \
            && valid_cn_entry_scan_temp_path "${remote:-}"; then
            ssh_cn_entry "rm -f -- '${remote}'" >/dev/null 2>&1 || true
            remote=
        fi
    }
    po0_install_exit_trap cleanup_readonly_check
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    if ! installation_active; then
        readonly_check_report_tool_error "${mode}" '本机尚未安装 Po0 解锁方案，没有可检查的运行环境。'
        return "${READONLY_CHECK_TOOL_ERROR}"
    fi
    if ! config_error=$( (load_config) 2>&1 ); then
        readonly_check_report_tool_error "${mode}" "无法读取连接配置：${config_error##*: }"
        return "${READONLY_CHECK_TOOL_ERROR}"
    fi
    load_config
    if ! preflight >/dev/null 2>&1; then
        readonly_check_report_tool_error "${mode}" '无法校验国内入口连接或同步组件。'
        return "${READONLY_CHECK_TOOL_ERROR}"
    fi

    exit_output=$(PO0_HEALTH_TSV=yes run_exit_role "${EXIT_CMD_HEALTH}" 2>/dev/null) || true
    if ! grep -q '^PO0LINE' <<<"${exit_output}"; then
        readonly_check_report_tool_error "${mode}" '国外出口检查没有返回可解析的结果。'
        return "${READONLY_CHECK_TOOL_ERROR}"
    fi

    if ! start_cn_entry_session >/dev/null 2>&1; then
        readonly_check_report_tool_error "${mode}" '无法通过专用密钥连接国内入口。'
        return "${READONLY_CHECK_TOOL_ERROR}"
    fi
    select_current_cn_entry_role remote remote_temporary >/dev/null 2>&1 || true
    if [[ -z ${remote} ]]; then
        readonly_check_report_tool_error "${mode}" '无法选择当前国内入口组件。'
        return "${READONLY_CHECK_TOOL_ERROR}"
    fi
    entry_output=$(ssh_cn_entry_component "${CN_ENTRY_TIMEOUT_HEALTH}" read-only '只读状态检查' \
        "PO0_HEALTH_TSV=yes '${remote}' '${CN_ENTRY_CMD_HEALTH}'" 2>/dev/null) || true
    if ! grep -q '^PO0LINE' <<<"${entry_output}"; then
        readonly_check_report_tool_error "${mode}" '国内入口检查没有返回可解析的结果。'
        return "${READONLY_CHECK_TOOL_ERROR}"
    fi

    while IFS=$'\t' read -r _ level name detail; do
        [[ -n ${level} ]] || continue
        key=$(readonly_check_level_key "${level}")
        case "${key}" in
            ok) ok_count=$((ok_count + 1)) ;;
            warn) warn_count=$((warn_count + 1)) ;;
            *) error_count=$((error_count + 1)) ;;
        esac
        # 只对 detail 脱敏：name 是检查项标识（含服务单元名），调用方要靠它定位问题。
        detail=$(printf '%s' "${detail}" | sanitize_diagnostic_stream)
        json_items+="${json_items:+,}{\"name\":\"$(readonly_check_json_escape "${name}")\",\"status\":\"${key}\",\"detail\":\"$(readonly_check_json_escape "${detail}")\"}"
        [[ ${key} == ok ]] \
            || attention+="  [${level}] ${name}：${detail}"$'\n'
    done < <(grep '^PO0LINE' <<<"${exit_output}"$'\n'"${entry_output}")

    if (( error_count > 0 )); then
        key=error
    elif (( warn_count > 0 )); then
        key=warn
    else
        key=ok
    fi

    if [[ ${mode} == json ]]; then
        printf '{"overall":"%s","checked_at":"%s","version":"%s","checks":[%s]}\n' \
            "${key}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SCRIPT_VERSION}" "${json_items}"
    else
        case "${key}" in
            ok) printf '%s\n' 'Po0 状态：正常' ;;
            warn) printf '%s\n' 'Po0 状态：提醒' ;;
            *) printf '%s\n' 'Po0 状态：异常' ;;
        esac
        printf '版本 %s；检查项 %d 项，正常 %d、提醒 %d、异常 %d。\n' \
            "${SCRIPT_VERSION}" "$((ok_count + warn_count + error_count))" \
            "${ok_count}" "${warn_count}" "${error_count}"
        [[ -z ${attention} ]] || { printf '%s\n' '需要关注：'; printf '%s' "${attention}"; }
    fi

    case "${key}" in
        ok) return "${READONLY_CHECK_OK}" ;;
        warn) return "${READONLY_CHECK_WARN}" ;;
        *) return "${READONLY_CHECK_ERROR}" ;;
    esac
)

run_readonly_check() {
    local mode=human rc=0
    case "${1:-}" in
        '') ;;
        --json) mode=json ;;
        *) usage; exit 2 ;;
    esac
    run_cn_entry_operation readonly_check "${mode}" || rc=$?
    case "${rc}" in
        "${READONLY_CHECK_OK}") return 0 ;;
        "${READONLY_CHECK_WARN}") return 1 ;;
        "${READONLY_CHECK_ERROR}") return 2 ;;
        "${READONLY_CHECK_TOOL_ERROR}") return 3 ;;
        *)
            readonly_check_report_tool_error "${mode}" '检查过程未能正常结束。'
            return 3
            ;;
    esac
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
  ./${PROGRAM_NAME} check         只读状态检查，供定时巡检调用（加 --json 输出结构化结果）
  ./${PROGRAM_NAME} diagnose      生成本机脱敏诊断报告（只读）
  ./${PROGRAM_NAME} raw-status    显示原始运行状态
  ./${PROGRAM_NAME} rollback      完整回滚
  ./${PROGRAM_NAME} update        匿名检查公开 Release 并更新脚本
  ./${PROGRAM_NAME} restore-script 恢复上一版助手（不改服务）

高级排障命令：
  ./${PROGRAM_NAME} configure
  ./${PROGRAM_NAME} authorize
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
    check) run_readonly_check "${2:-}" ;;
    diagnose) run_cn_entry_operation diagnostic_report ;;
    raw-status) run_cn_entry_operation status_all ;;
    rollback) run_cn_entry_operation rollback_all direct ;;
    update) run_script_update ;;
    restore-script) run_script_restore ;;
    help|-h|--help) usage ;;
    '') main_menu ;;
    *) usage; exit 2 ;;
esac
