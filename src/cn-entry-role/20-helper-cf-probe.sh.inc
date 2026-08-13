
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
    local config=$1 ct=$2 cu=$3 cm=$4 bd=$5 directory tmp=
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
    local ct cu cm bd desired_ct desired_cu desired_cm desired_bd original_ct original_cu original_cm original_bd
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

for index in "${!original[@]}"; do
    case "${original[index]}" in
        X-Agent-Version:*) is_report=yes ;;
        https://*) target_index=${index}; target_url=${original[index]} ;;
    esac
done

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

managed_cf_probe_compat_owned() {
    local directory=$1 nc_wrapper=${1}/nc curl_wrapper=${1}/curl go_record=${1}/go-record
    local go_pending=${1}/go-pending go_previous=${1}/go-record.previous expected actual extra=
    [[ -d ${directory} && ! -L ${directory} ]] || return 1
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
