
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
# 与角色侧 CN_ENTRY_LOCK_WAIT_SECONDS 同值：helper 是独立脚本，取不到角色的变量。
CN_ENTRY_LOCK_WAIT_SECONDS=30

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
