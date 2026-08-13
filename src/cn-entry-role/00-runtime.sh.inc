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

log() { printf '[国内入口] %s\n' "$*"; }
die() { printf '[国内入口] 错误：%s\n' "$*" >&2; exit 1; }
require_root() { [[ ${EUID} -eq 0 ]] || die '必须使用 root 运行。'; }

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
    [[ -r ${ACTIVE_FILE} ]] || die '没有找到有效安装状态。'
    state=$(<"${ACTIVE_FILE}")
    case "${state}" in "${STATE_ROOT}"/*) ;; *) die '安装状态路径无效。' ;; esac
    [[ -d ${state} ]] || die "状态目录不存在：${state}"
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
    local stamp state public_key tunnel_uid
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
