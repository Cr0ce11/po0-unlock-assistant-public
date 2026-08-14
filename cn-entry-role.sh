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
        flock -n 9 || exit 0
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
        *) die '选择无效，请重新运行扫描。' ;;
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
        manage_komari_report_ipv4 "${unit}" "${state}"
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
