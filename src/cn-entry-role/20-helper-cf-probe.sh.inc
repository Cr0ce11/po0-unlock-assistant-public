
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
    69f5e13216a45e06273717a9f072a6c103302187
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

# 只解析并校验配置文件路径本身，不要求二进制修订在白名单内。
# 仅供只读取值使用（例如读面板地址）；改写测速目标必须走下面带白名单闸门的版本。
cf_probe_go_config_path_unverified() {
    local unit=$1 pid exe arg next_is_config=no config=/etc/config/cf-probe/config.conf resolved
    local -a args=()
    pid=$(systemctl show -p MainPID --value -- "${unit}" 2>/dev/null || true)
    [[ ${pid} =~ ^[1-9][0-9]*$ && -r /proc/${pid}/cmdline ]] || return 1
    exe=$(cf_probe_go_executable_path "${unit}" "${pid}") || return 1
    cf_probe_go_binary_family "${exe}" || return 1
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

# 带白名单闸门：任何会改写 cf-probe 自身配置的路径都必须经过这里。
cf_probe_go_config_path() {
    local unit=$1 pid exe
    pid=$(systemctl show -p MainPID --value -- "${unit}" 2>/dev/null || true)
    [[ ${pid} =~ ^[1-9][0-9]*$ ]] || return 1
    exe=$(cf_probe_go_executable_path "${unit}" "${pid}") || return 1
    cf_probe_go_binary_contract "${exe}" || return 1
    cf_probe_go_config_path_unverified "${unit}"
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
            # 版本受支持却过不了安全校验，可能意味着配置或启动参数被改动过，仍然拒绝整次配置。
            echo '已识别受支持的官方 Go cf-probe，但运行参数或配置文件未通过安全校验，已停止配置。' >&2
            return 1
        fi
        # 修订不在白名单：不去碰它的配置文件，但国外出口该配还是要配。cf-probe 默认开启
        # 自动更新，上游一发新版就会走到这里；若因此整次拒绝，探针会退回直连而彻底失联。
        echo '当前官方 Go cf-probe 不在 Po0 已审查的正式版本清单中：本次只配置国外出口，不改动它的测速目标。' >&2
        echo '待该版本经过审查并加入清单后，再次执行「检查并更新配置」即可补上测速目标处理。' >&2
        return 3
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

# ---- cf-probe 出站模式：env（默认）与 forward（本地转发）----
# 有些 cf-probe 只让 HTTP 上报读取代理环境变量，实时通道自己直接拨号；境内直连不通时
# HTTP 上报照常、实时通道长期断开，面板看着在线，是典型的假绿灯。forward 模式为这类
# 客户端补一条本地转发：只在该服务自己的挂载命名空间里把面板域名指向本机，由本地监听
# 经国外出口的管理代理转出去，全局 /etc/hosts 不受影响。
# 默认仍是 env 模式，此时不写本节任何文件，既有部署的行为逐字节不变。

CF_PROBE_FORWARD_MARKER='# Managed by Po0 Unlock: CF Probe local forward v1.'
CF_PROBE_FORWARD_LISTEN_ADDRESS=127.0.0.1
CF_PROBE_FORWARD_LISTEN_PORT=443
CF_PROBE_FORWARD_SOCAT=/usr/bin/socat

cf_probe_valid_outbound_mode() {
    case "${1:-}" in env|forward) return 0 ;; esac
    return 1
}

cf_probe_forward_dir() {
    local dropin=$1
    printf '%s/po0-cf-probe-forward\n' "${dropin}"
}

cf_probe_forward_hosts_file() {
    local directory
    directory=$(cf_probe_forward_dir "$1") || return 1
    printf '%s/hosts\n' "${directory}"
}

# 转发模式的受管记录：记下本次转发的面板主机与监听端点，供健康检查与拆除时核对。
cf_probe_forward_record_file() {
    local directory
    directory=$(cf_probe_forward_dir "$1") || return 1
    printf '%s/record\n' "${directory}"
}

# 面板主机名取自 cf-probe 自己的配置；只接受普通主机名，拒绝 IP、端口与路径。
cf_probe_forward_host() {
    local config=$1 line value host
    [[ $(grep -Ec '^WORKER_URL=' "${config}" 2>/dev/null || true) == 1 ]] || return 1
    line=$(grep -E '^WORKER_URL=' "${config}") || return 1
    value=${line#*=}
    if [[ ${value} == \"*\" && ${#value} -ge 2 ]]; then
        value=${value:1:${#value}-2}
    fi
    [[ ${value} == https://* ]] || return 1
    host=${value#https://}
    host=${host%%/*}
    [[ ${#host} -ge 4 && ${#host} -le 253 && ${host} != *:* ]] || return 1
    grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$' \
        <<<"${host}" || return 1
    printf '%s\n' "${host}"
}

# 转发目标就是本角色已有的管理代理，避免出现第二处硬编码地址。
cf_probe_forward_proxy_endpoint() {
    local value=${HTTP_PROXY_URL#http://} host port
    host=${value%%:*}
    port=${value##*:}
    [[ ${host} == 127.0.0.1 && ${port} =~ ^[0-9]{1,5}$ ]] || return 1
    printf '%s %s\n' "${host}" "${port}"
}

cf_probe_forward_unit_name() {
    local unit=$1 digest
    valid_helper_service_unit "${unit}" || return 1
    digest=$(printf '%s' "${unit}" | sha256sum | awk '{print substr($1,1,16)}') || return 1
    [[ ${digest} =~ ^[0-9a-f]{16}$ ]] || return 1
    printf 'po0-unlock-cf-probe-forward-%s.service\n' "${digest}"
}

cf_probe_forward_unit_file() {
    local name root
    name=$(cf_probe_forward_unit_name "$1") || return 1
    root=$(cf_probe_go_systemd_root) || return 1
    printf '%s/%s\n' "${root}" "${name}"
}

cf_probe_forward_unit_content() {
    local unit=$1 host=$2 endpoint proxy_host proxy_port
    endpoint=$(cf_probe_forward_proxy_endpoint) || return 1
    proxy_host=${endpoint%% *}
    proxy_port=${endpoint##* }
    cat <<FORWARD_UNIT
${CF_PROBE_FORWARD_MARKER}
[Unit]
Description=Po0 CF Probe local forward for ${unit}
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
ExecStart=${CF_PROBE_FORWARD_SOCAT} TCP-LISTEN:${CF_PROBE_FORWARD_LISTEN_PORT},bind=${CF_PROBE_FORWARD_LISTEN_ADDRESS},fork,reuseaddr PROXY:${proxy_host}:${host}:${CF_PROBE_FORWARD_LISTEN_PORT},proxyport=${proxy_port}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
FORWARD_UNIT
}

# 该服务专属的 hosts：照抄系统 hosts 再追加一行劫持，首行写标记以便核对归属。
cf_probe_forward_hosts_content() {
    local host=$1
    printf '%s\n' "${CF_PROBE_FORWARD_MARKER}"
    sed -n '1,$p' /etc/hosts || return 1
    printf '%s %s\n' "${CF_PROBE_FORWARD_LISTEN_ADDRESS}" "${host}"
}

cf_probe_forward_record_content() {
    local unit=$1 host=$2
    printf '%s\n' "${CF_PROBE_FORWARD_MARKER}" \
        "UNIT=${unit}" \
        "FORWARD_HOST=${host}" \
        "LISTEN=${CF_PROBE_FORWARD_LISTEN_ADDRESS}:${CF_PROBE_FORWARD_LISTEN_PORT}"
}

cf_probe_forward_record_value() {
    local file=$1 key=$2 line
    [[ $(grep -Ec "^${key}=" "${file}" 2>/dev/null || true) == 1 ]] || return 1
    line=$(grep -E "^${key}=" "${file}") || return 1
    printf '%s\n' "${line#*=}"
}

managed_cf_probe_forward_file() {
    local file=$1
    [[ -f ${file} && ! -L ${file} ]] || return 1
    [[ $(stat -c '%u' "${file}" 2>/dev/null) == 0 \
        && $(stat -c '%h' "${file}" 2>/dev/null) == 1 ]] || return 1
    [[ $(sed -n '1p' "${file}" 2>/dev/null) == "${CF_PROBE_FORWARD_MARKER}" ]]
}

managed_cf_probe_forward_dir() {
    local directory=$1
    [[ -d ${directory} && ! -L ${directory} ]] || return 1
    [[ $(stat -c '%u' "${directory}" 2>/dev/null) == 0 ]] || return 1
    cf_probe_forward_mode_dir_is_safe "${directory}"
}

cf_probe_forward_mode_dir_is_safe() {
    local mode
    mode=$(stat -c '%a' "$1" 2>/dev/null) || return 1
    [[ ${mode} =~ ^[0-7]{3,4}$ ]] || return 1
    (( 8#${mode} & 8#022 )) && return 1
    return 0
}

# 监听端点是全机资源：被别人占着就拒绝启用，绝不覆盖。
cf_probe_forward_listen_available() {
    local expected=${CF_PROBE_FORWARD_LISTEN_ADDRESS}:${CF_PROBE_FORWARD_LISTEN_PORT} listener
    listener=$(ss -tlnH 2>/dev/null | awk -v addr="${expected}" '$4 == addr {print $4; exit}') || return 0
    [[ -z ${listener} ]]
}

cf_probe_forward_dropin_line() {
    local dropin=$1 hosts_file
    hosts_file=$(cf_probe_forward_hosts_file "${dropin}") || return 1
    printf 'BindReadOnlyPaths=%s:/etc/hosts\n' "${hosts_file}"
}

# 启用转发模式。标准输出为 yes/no，表示本次是否新建了转发目录，供事务回滚判断。
prepare_cf_probe_forward_mode() {
    local unit=$1 dropin=$2 directory hosts_file record_file unit_file unit_name
    local config host hosts_content record_content unit_content created=no tmp
    directory=$(cf_probe_forward_dir "${dropin}") || return 1
    hosts_file=$(cf_probe_forward_hosts_file "${dropin}") || return 1
    record_file=$(cf_probe_forward_record_file "${dropin}") || return 1
    unit_file=$(cf_probe_forward_unit_file "${unit}") || return 1
    unit_name=${unit_file##*/}
    [[ -f ${CF_PROBE_FORWARD_SOCAT} && -x ${CF_PROBE_FORWARD_SOCAT} && ! -L ${CF_PROBE_FORWARD_SOCAT} ]] \
        || { echo "转发模式需要 ${CF_PROBE_FORWARD_SOCAT}，本机没有找到可用的它。" >&2; return 1; }
    # 转发模式只从配置里读面板地址，不改写它，因此不要求修订在白名单内。
    config=$(cf_probe_go_config_path_unverified "${unit}") \
        || { echo '无法定位 cf-probe 配置文件，拒绝启用转发模式。' >&2; return 1; }
    host=$(cf_probe_forward_host "${config}") \
        || { echo '无法从 cf-probe 配置中解析出可用的面板主机名，拒绝启用转发模式。' >&2; return 1; }
    if [[ -e ${unit_file} || -L ${unit_file} ]]; then
        managed_cf_probe_forward_file "${unit_file}" \
            || { echo '转发单元已存在且不是本助手写入的，拒绝覆盖。' >&2; return 1; }
    elif ! cf_probe_forward_listen_available; then
        echo "本机 ${CF_PROBE_FORWARD_LISTEN_ADDRESS}:${CF_PROBE_FORWARD_LISTEN_PORT} 已被占用，拒绝启用转发模式。" >&2
        return 1
    fi
    hosts_content=$(cf_probe_forward_hosts_content "${host}") || return 1
    record_content=$(cf_probe_forward_record_content "${unit}" "${host}") || return 1
    unit_content=$(cf_probe_forward_unit_content "${unit}" "${host}") || return 1
    if [[ -e ${directory} || -L ${directory} ]]; then
        managed_cf_probe_forward_dir "${directory}" \
            || { echo '转发工作目录已存在且不是本助手创建的，拒绝复用。' >&2; return 1; }
    else
        install -d -m 0755 "${directory}" || return 1
        created=yes
    fi
    if ! cf_probe_forward_write_file "${hosts_file}" "${hosts_content}" \
        || ! cf_probe_forward_write_file "${record_file}" "${record_content}" \
        || ! cf_probe_write_go_guard_file "${unit_file}" "${unit_content}"; then
        rm -f -- "${hosts_file}" "${record_file}"
        [[ ${created} == no ]] || rmdir -- "${directory}" 2>/dev/null || true
        return 1
    fi
    if ! systemctl daemon-reload || ! systemctl enable --now -- "${unit_name}" >/dev/null; then
        systemctl disable -- "${unit_name}" >/dev/null 2>&1 || true
        rm -f -- "${unit_file}" "${hosts_file}" "${record_file}"
        [[ ${created} == no ]] || rmdir -- "${directory}" 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        echo '转发单元未能启动，已撤销本次转发模式配置。' >&2
        return 1
    fi
    printf '%s\n' "${created}"
}

cf_probe_forward_write_file() {
    local file=$1 content=$2 directory tmp
    directory=${file%/*}
    [[ -d ${directory} && ! -L ${directory} ]] || return 1
    tmp=$(mktemp "${directory}/.po0-cf-probe-forward.XXXXXXXX") || return 1
    if ! printf '%s\n' "${content}" >"${tmp}" \
        || ! chmod 0644 "${tmp}" \
        || ! chown root:root "${tmp}" \
        || ! mv -f -- "${tmp}" "${file}"; then
        rm -f -- "${tmp}"
        return 1
    fi
}

# 刷新时把转发单元收敛到当前版本的期望内容，并重新启用一次。
# 已经落地的单元不会随助手升级而更新：早期版本写出的单元没有 [Install] 段，
# `systemctl enable` 对它只是空转，开机根本不会拉起转发器——实时通道会在重启后
# 静默断开，而 HTTP 上报照常，面板仍显示在线。只有在这里核对重写，既有部署才
# 不必重新纳管一遍。内容一致时不重写，但仍然启用一次，用来补回缺失的开机链接。
reconcile_cf_probe_forward_unit() {
    local unit=$1 dropin=$2 record_file unit_file unit_name host expected actual
    record_file=$(cf_probe_forward_record_file "${dropin}") || return 1
    managed_cf_probe_forward_file "${record_file}" || return 1
    host=$(cf_probe_forward_record_value "${record_file}" FORWARD_HOST) || return 1
    unit_file=$(cf_probe_forward_unit_file "${unit}") || return 1
    unit_name=${unit_file##*/}
    expected=$(cf_probe_forward_unit_content "${unit}" "${host}") || return 1
    managed_cf_probe_forward_file "${unit_file}" || return 1
    actual=$(sed -n '1,$p' "${unit_file}") || return 1
    if [[ ${actual} != "${expected}" ]]; then
        cf_probe_write_go_guard_file "${unit_file}" "${expected}" || return 1
        systemctl daemon-reload || return 1
        # 只重启本来就在跑的转发器；没在跑的交给下面的 enable --now 拉起。
        systemctl try-restart -- "${unit_name}" >/dev/null || return 1
    fi
    systemctl enable --now -- "${unit_name}" >/dev/null || return 1
}

# 拆除转发模式：只动本助手写的东西，任何一处被人工改过都拒绝，避免误删他人文件。
remove_cf_probe_forward_mode() {
    local unit=$1 dropin=$2 directory hosts_file record_file unit_file unit_name
    directory=$(cf_probe_forward_dir "${dropin}") || return 1
    hosts_file=$(cf_probe_forward_hosts_file "${dropin}") || return 1
    record_file=$(cf_probe_forward_record_file "${dropin}") || return 1
    unit_file=$(cf_probe_forward_unit_file "${unit}") || return 1
    unit_name=${unit_file##*/}
    [[ -e ${directory} || -L ${directory} || -e ${unit_file} || -L ${unit_file} ]] || return 0
    if [[ -e ${unit_file} || -L ${unit_file} ]]; then
        managed_cf_probe_forward_file "${unit_file}" || return 1
        systemctl disable --now -- "${unit_name}" >/dev/null 2>&1 || true
        rm -f -- "${unit_file}" || return 1
        systemctl daemon-reload || return 1
        systemctl reset-failed -- "${unit_name}" >/dev/null 2>&1 || true
    fi
    if [[ -e ${hosts_file} || -L ${hosts_file} ]]; then
        managed_cf_probe_forward_file "${hosts_file}" || return 1
        rm -f -- "${hosts_file}" || return 1
    fi
    if [[ -e ${record_file} || -L ${record_file} ]]; then
        managed_cf_probe_forward_file "${record_file}" || return 1
        rm -f -- "${record_file}" || return 1
    fi
    [[ ! -d ${directory} ]] || rmdir -- "${directory}" || return 1
}

cf_probe_forward_mode_active() {
    local dropin=$1 record_file
    record_file=$(cf_probe_forward_record_file "${dropin}") || return 1
    managed_cf_probe_forward_file "${record_file}"
}

# 专属 hosts 是启用时照抄的快照；系统 hosts 之后被改过就会脱节，健康检查要如实报出来。
cf_probe_forward_hosts_in_sync() {
    local file=$1 host=$2
    sed '1d' "${file}" 2>/dev/null \
        | grep -vxF "${CF_PROBE_FORWARD_LISTEN_ADDRESS} ${host}" \
        | diff -q - /etc/hosts >/dev/null 2>&1
}

# 转发模式的健康检查。标准输出首段是等级，其余是给用户看的说明。
cf_probe_forward_health() {
    local unit=$1 dropin=$2 hosts_file record_file unit_name host
    hosts_file=$(cf_probe_forward_hosts_file "${dropin}") \
        || { printf '异常 转发路径无法解析\n'; return 0; }
    record_file=$(cf_probe_forward_record_file "${dropin}") \
        || { printf '异常 转发路径无法解析\n'; return 0; }
    unit_name=$(cf_probe_forward_unit_name "${unit}") \
        || { printf '异常 转发单元名无法解析\n'; return 0; }
    managed_cf_probe_forward_file "${record_file}" \
        || { printf '异常 转发记录缺失或已被修改\n'; return 0; }
    managed_cf_probe_forward_file "${hosts_file}" \
        || { printf '异常 转发用 hosts 缺失或已被修改\n'; return 0; }
    host=$(cf_probe_forward_record_value "${record_file}" FORWARD_HOST) \
        || { printf '异常 转发记录缺少面板主机\n'; return 0; }
    grep -Fxq "${CF_PROBE_FORWARD_LISTEN_ADDRESS} ${host}" "${hosts_file}" \
        || { printf '异常 转发用 hosts 没有指向本机\n'; return 0; }
    systemctl is-active --quiet -- "${unit_name}" \
        || { printf '异常 转发单元没有运行，实时通道已中断\n'; return 0; }
    # 现在跑着不代表重启后还在：早期版本写出的单元没有 [Install]，开机不会被拉起。
    [[ $(systemctl is-enabled -- "${unit_name}" 2>/dev/null) == enabled ]] \
        || { printf '提醒 转发模式正常，但转发单元不会开机自启，重启后实时通道会断，建议执行「检查并更新配置」\n'; return 0; }
    cf_probe_forward_hosts_in_sync "${hosts_file}" "${host}" \
        || { printf '提醒 转发模式正常，但系统 hosts 已变化，建议重新纳管以同步\n'; return 0; }
    printf '正常 配置完整且正在运行（转发模式）\n'
}
