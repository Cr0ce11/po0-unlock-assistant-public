#!/usr/bin/env bash
set -u
set -o pipefail
umask 077

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=${TEST_DIR%/tests}
CN_ENTRY_ROLE=${PROJECT_DIR}/cn-entry-role.sh
TEMP_BASE=${TMPDIR:-/tmp}
TEMP_BASE=${TEMP_BASE%/}
TEMP_BASE=$(cd -P -- "${TEMP_BASE}" && pwd)
WORK_ROOT=$(mktemp -d "${TEMP_BASE}/po0-komari-acceptance.XXXXXXXX")
HELPER_LIBRARY=${WORK_ROOT}/po0-cn-entry-helper-library.sh
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP
    case "${WORK_ROOT}" in
        "${TEMP_BASE}"/po0-komari-acceptance.*) rm -rf -- "${WORK_ROOT}" ;;
        *) printf '拒绝清理异常测试目录：%s\n' "${WORK_ROOT}" >&2 ;;
    esac
    exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

fail() { printf '    失败：%s\n' "$*" >&2; return 1; }
assert_eq() {
    local expected=$1 actual=$2 message=$3
    [[ ${actual} == "${expected}" ]] || fail "${message}（期望=${expected}，实际=${actual}）"
}
assert_contains() {
    local haystack=$1 needle=$2 message=$3
    grep -Fq -- "${needle}" <<<"${haystack}" || fail "${message}（缺少：${needle}）"
}
assert_not_contains() {
    local haystack=$1 needle=$2 message=$3
    ! grep -Fq -- "${needle}" <<<"${haystack}" || fail "${message}（不应包含：${needle}）"
}

make_helper_library() {
    awk '
        index($0, "cat >\"${tmp}\" <<\047EOF\047") { capture=1; next }
        capture && $0 == "case \"${1:-}\" in" { exit }
        capture { print }
    ' "${CN_ENTRY_ROLE}" >"${HELPER_LIBRARY}"
    [[ -s ${HELPER_LIBRARY} ]] || fail '未能提取 po0-cn-entry helper 函数库'
    /bin/bash -n "${HELPER_LIBRARY}" || fail 'helper 函数库语法错误'
    # shellcheck disable=SC1090
    source "${HELPER_LIBRARY}"
}

test_owned_files_and_drift_protection() {
    local state=${WORK_ROOT}/state unit=komari-agent.service record hash
    install -d -m 0700 "${state}" "${WORK_ROOT}/etc" "${WORK_ROOT}/bin"
    LEGACY_KOMARI_LATENCY_CONFIG=${WORK_ROOT}/etc/komari.conf
    LEGACY_KOMARI_LATENCY_FIREWALL=${WORK_ROOT}/bin/firewall
    LEGACY_KOMARI_LATENCY_SERVICE=${WORK_ROOT}/etc/komari.service
    printf '%s\n' "${LEGACY_KOMARI_LATENCY_MARKER}" 'config' >"${LEGACY_KOMARI_LATENCY_CONFIG}"
    printf '%s\n' '#!/usr/bin/env bash' "${LEGACY_KOMARI_LATENCY_MARKER}" 'exit 0' >"${LEGACY_KOMARI_LATENCY_FIREWALL}"
    printf '%s\n' "${LEGACY_KOMARI_LATENCY_MARKER}" '[Service]' >"${LEGACY_KOMARI_LATENCY_SERVICE}"
    chmod 0755 "${LEGACY_KOMARI_LATENCY_FIREWALL}"
    record=$(legacy_komari_latency_record "${state}")
    {
        printf '%s\n' "${unit}"
        for path in \
            "${LEGACY_KOMARI_LATENCY_CONFIG}" \
            "${LEGACY_KOMARI_LATENCY_FIREWALL}" \
            "${LEGACY_KOMARI_LATENCY_SERVICE}"; do
            hash=$(sha256sum "${path}" | awk '{print $1}')
            printf '%s\n' "${hash}"
        done
    } >"${record}"
    chmod 0600 "${record}"
    legacy_komari_latency_owned "${state}" "${unit}" \
        || { fail '旧版助手创建的完整记录未被识别'; return 1; }
    printf '%s\n' 'external change' >>"${LEGACY_KOMARI_LATENCY_CONFIG}"
    ! legacy_komari_latency_owned "${state}" "${unit}" \
        || { fail '外部改动后仍允许自动删除文件'; return 1; }
}

test_legacy_cleanup_contract() {
    local source
    source=$(sed -n '1,$p' "${CN_ENTRY_ROLE}")
    assert_contains "${source}" 'remove_legacy_komari_latency_compat()' \
        '缺少旧版延迟转发清理函数' || return 1
    assert_contains "${source}" 'legacy_komari_latency_owned "${state}" "${unit}"' \
        '清理前没有验证文件归属和内容完整性' || return 1
    assert_contains "${source}" '"${LEGACY_KOMARI_LATENCY_FIREWALL}" delete' \
        '删除旧文件前没有撤销旧防火墙规则' || return 1
    ! grep -Fq 'enable_komari_latency_compat' <<<"${source}" \
        || { fail '仍保留启用 Komari TCP 延迟转发的代码'; return 1; }
    ! grep -Fq 'apt-get install -y redsocks' <<<"${source}" \
        || { fail '仍会自动安装 redsocks'; return 1; }
    ! grep -Fq 'ExecStart=${redsocks_bin}' <<<"${source}" \
        || { fail '仍会生成 redsocks 辅助服务'; return 1; }
    ! grep -Fq 'apt-get purge' <<<"${source}" \
        || { fail '无法确认软件包来源时不应自动卸载 redsocks'; return 1; }
}

test_legacy_cleanup_execution() (
    local state=${WORK_ROOT}/cleanup-state unit=komari-agent.service record hash path
    install -d -m 0700 "${state}" "${WORK_ROOT}/cleanup-etc" "${WORK_ROOT}/cleanup-bin"
    LEGACY_KOMARI_LATENCY_CONFIG=${WORK_ROOT}/cleanup-etc/komari.conf
    LEGACY_KOMARI_LATENCY_FIREWALL=${WORK_ROOT}/cleanup-bin/firewall
    LEGACY_KOMARI_LATENCY_SERVICE=${WORK_ROOT}/cleanup-etc/komari.service
    printf '%s\n' "${LEGACY_KOMARI_LATENCY_MARKER}" 'config' >"${LEGACY_KOMARI_LATENCY_CONFIG}"
    printf '%s\n' '#!/usr/bin/env bash' "${LEGACY_KOMARI_LATENCY_MARKER}" 'exit 0' \
        >"${LEGACY_KOMARI_LATENCY_FIREWALL}"
    printf '%s\n' "${LEGACY_KOMARI_LATENCY_MARKER}" '[Service]' >"${LEGACY_KOMARI_LATENCY_SERVICE}"
    chmod 0755 "${LEGACY_KOMARI_LATENCY_FIREWALL}"
    record=$(legacy_komari_latency_record "${state}")
    {
        printf '%s\n' "${unit}"
        for path in \
            "${LEGACY_KOMARI_LATENCY_CONFIG}" \
            "${LEGACY_KOMARI_LATENCY_FIREWALL}" \
            "${LEGACY_KOMARI_LATENCY_SERVICE}"; do
            hash=$(sha256sum "${path}" | awk '{print $1}')
            printf '%s\n' "${hash}"
        done
    } >"${record}"
    chmod 0600 "${record}"
    systemctl() { return 0; }
    remove_legacy_komari_latency_compat "${state}" "${unit}" >/dev/null \
        || { fail '归属明确的旧版组件未能完成清理'; return 1; }
    for path in \
        "${record}" \
        "${LEGACY_KOMARI_LATENCY_CONFIG}" \
        "${LEGACY_KOMARI_LATENCY_FIREWALL}" \
        "${LEGACY_KOMARI_LATENCY_SERVICE}"; do
        [[ ! -e ${path} && ! -L ${path} ]] \
            || { fail "旧版组件清理后仍残留：${path}"; return 1; }
    done
)

test_legacy_cleanup_failures_preserve_recovery_files() (
    local state=${WORK_ROOT}/cleanup-failure-state unit=komari-agent.service
    local record hash path output rc systemctl_mode=fail
    install -d -m 0700 "${state}" "${WORK_ROOT}/cleanup-failure-etc" \
        "${WORK_ROOT}/cleanup-failure-bin"
    LEGACY_KOMARI_LATENCY_CONFIG=${WORK_ROOT}/cleanup-failure-etc/komari.conf
    LEGACY_KOMARI_LATENCY_FIREWALL=${WORK_ROOT}/cleanup-failure-bin/firewall
    LEGACY_KOMARI_LATENCY_SERVICE=${WORK_ROOT}/cleanup-failure-etc/komari.service
    printf '%s\n' "${LEGACY_KOMARI_LATENCY_MARKER}" 'config' >"${LEGACY_KOMARI_LATENCY_CONFIG}"
    cat >"${LEGACY_KOMARI_LATENCY_FIREWALL}" <<'EOF'
#!/usr/bin/env bash
# Managed by Po0 Komari latency compatibility; do not edit manually.
printf '%s\n' "${1:-}" >>"${PO0_TEST_FIREWALL_LOG}"
exit "${PO0_TEST_FIREWALL_RC:-0}"
EOF
    printf '%s\n' "${LEGACY_KOMARI_LATENCY_MARKER}" '[Service]' >"${LEGACY_KOMARI_LATENCY_SERVICE}"
    chmod 0755 "${LEGACY_KOMARI_LATENCY_FIREWALL}"
    record=$(legacy_komari_latency_record "${state}")
    {
        printf '%s\n' "${unit}"
        for path in \
            "${LEGACY_KOMARI_LATENCY_CONFIG}" \
            "${LEGACY_KOMARI_LATENCY_FIREWALL}" \
            "${LEGACY_KOMARI_LATENCY_SERVICE}"; do
            hash=$(sha256sum "${path}" | awk '{print $1}')
            printf '%s\n' "${hash}"
        done
    } >"${record}"
    chmod 0600 "${record}"
    export PO0_TEST_FIREWALL_LOG=${WORK_ROOT}/cleanup-firewall.log
    export PO0_TEST_FIREWALL_RC=0
    systemctl() {
        if [[ ${1:-} == disable && ${systemctl_mode} == fail ]]; then return 1; fi
        return 0
    }

    set +e
    output=$(remove_legacy_komari_latency_compat "${state}" "${unit}" 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail '旧服务停止失败时清理错误报告成功'; return 1; }
    assert_contains "${output}" '服务停止失败' '旧服务停止失败原因不明确' || return 1
    [[ ! -e ${PO0_TEST_FIREWALL_LOG} ]] \
        || { fail '旧服务未停止时仍执行了防火墙删除脚本'; return 1; }
    for path in \
        "${record}" \
        "${LEGACY_KOMARI_LATENCY_CONFIG}" \
        "${LEGACY_KOMARI_LATENCY_FIREWALL}" \
        "${LEGACY_KOMARI_LATENCY_SERVICE}"; do
        [[ -e ${path} && ! -L ${path} ]] \
            || { fail "旧服务停止失败后恢复材料丢失：${path}"; return 1; }
    done

    systemctl_mode=success
    export PO0_TEST_FIREWALL_RC=23
    set +e
    output=$(remove_legacy_komari_latency_compat "${state}" "${unit}" 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail '防火墙规则撤销失败时清理错误报告成功'; return 1; }
    assert_contains "${output}" '防火墙规则撤销失败' \
        '防火墙规则撤销失败原因不明确' || return 1
    assert_contains "$(<"${PO0_TEST_FIREWALL_LOG}")" delete \
        '测试夹具没有执行到防火墙删除步骤' || return 1
    for path in \
        "${record}" \
        "${LEGACY_KOMARI_LATENCY_CONFIG}" \
        "${LEGACY_KOMARI_LATENCY_FIREWALL}" \
        "${LEGACY_KOMARI_LATENCY_SERVICE}"; do
        [[ -e ${path} && ! -L ${path} ]] \
            || { fail "防火墙撤销失败后恢复材料丢失：${path}"; return 1; }
    done
)

test_internal_service_scan_exclusion() (
    local exclusion_function protected_function
    exclusion_function=$(
        sed -n '/^service_is_excluded() {/,/^}/p' "${CN_ENTRY_ROLE}" \
            | sed 's/${1,,}/${1}/g; s/${2,,}/${2}/g; s/${3,,}/${3}/g; s/${4,,}/${4}/g'
    )
    [[ -n ${exclusion_function} ]] || { fail '未能提取服务扫描排除函数'; return 1; }
    eval "${exclusion_function}"

    service_is_excluded \
        po0-komari-latency.service \
        'Po0 Komari latency proxy compatibility' \
        /etc/systemd/system/po0-komari-latency.service \
        redsocks \
        || { fail '脚本自己的 Komari 延迟辅助服务仍会出现在 Agent 扫描中'; return 1; }
    ! service_is_excluded \
        komari-agent.service \
        'Komari Agent Service' \
        /etc/systemd/system/komari-agent.service \
        agent \
        || { fail '真正的 Komari Agent 被扫描排除规则误伤'; return 1; }
    ! service_is_excluded \
        forwardx-agent.service \
        'ForwardX Agent' \
        /etc/systemd/system/forwardx-agent.service \
        forwardx-agent \
        || { fail 'ForwardX Agent 仍被扫描排除规则禁止'; return 1; }

    protected_function=$(
        sed -n '/^protected_service() {/,/^}/p' "${CN_ENTRY_ROLE}" \
            | sed 's/${unit,,}/${unit}/g; s/${metadata,,}/${metadata}/g'
    )
    [[ -n ${protected_function} ]] || { fail '未能提取受保护服务判断函数'; return 1; }
    eval "${protected_function}"
    systemctl() { :; }
    ! protected_service forwardx-agent.service \
        || { fail 'ForwardX Agent 仍被服务代理安全校验禁止'; return 1; }
)

test_agent_product_candidate_detection() {
    local candidate_function reason
    candidate_function=$(
        sed -n '/^candidate_reason() {/,/^}/p' "${CN_ENTRY_ROLE}" \
            | sed 's/${1,,}/${1}/g; s/${2,,}/${2}/g; s/${3,,}/${3}/g; s/${4,,}/${4}/g'
    )
    [[ -n ${candidate_function} ]] || { fail '未能提取 Agent 候选识别函数'; return 1; }
    eval "${candidate_function}"

    reason=$(candidate_reason \
        forwardx-agent.service \
        'ForwardX Agent' \
        /etc/systemd/system/forwardx-agent.service \
        forwardx-agent) || { fail 'ForwardX Agent 未被识别'; return 1; }
    assert_eq '识别为 ForwardX 转发面板 Agent（是否代理由你确认）' "${reason}" \
        'ForwardX Agent 的识别说明不正确' || return 1

    reason=$(candidate_reason \
        nyanpass.service \
        nyanpass \
        /etc/systemd/system/nyanpass.service \
        bash) || { fail '默认 NyanPass 服务未被识别'; return 1; }
    assert_eq '识别为 NyanPass 转发面板 Agent（是否代理由你确认）' "${reason}" \
        '默认 NyanPass 服务的识别说明不正确' || return 1

    reason=$(candidate_reason \
        custom-node.service \
        nyanpass \
        /etc/systemd/system/custom-node.service \
        bash) || { fail '自定义服务名的 NyanPass 未通过描述识别'; return 1; }
    assert_eq '识别为 NyanPass 转发面板 Agent（是否代理由你确认）' "${reason}" \
        '自定义服务名的 NyanPass 识别说明不正确' || return 1

    ! candidate_reason \
        nypass.service \
        nypass \
        /etc/systemd/system/nypass.service \
        nypass >/dev/null \
        || { fail '未经证实的 nypass 名称被错误识别为 NyanPass'; return 1; }

    ! candidate_reason \
        opaque-node.service \
        'Nezha Agent' \
        /etc/systemd/system/opaque-node.service \
        nezha-agent >/dev/null \
        || { fail '已经移除的哪吒专用识别仍然生效'; return 1; }
}

test_forwardx_control_plane_proxy_profile() (
    local output=${WORK_ROOT}/forwardx-proxy.conf generic_output=${WORK_ROOT}/generic-proxy.conf
    systemctl() {
        case "$*" in
            *forwardx-agent.service*) printf '%s\n' 'ForwardX Agent' ;;
        esac
    }
    write_service_proxy_dropin forwardx-agent.service "${output}" \
        || { fail '无法生成 ForwardX 代理配置'; return 1; }
    assert_contains "$(<"${output}")" 'Environment="HTTP_PROXY=http://127.0.0.1:13128"' \
        'ForwardX 配置缺少 HTTP 控制面代理' || return 1
    assert_contains "$(<"${output}")" 'Environment="HTTPS_PROXY=http://127.0.0.1:13128"' \
        'ForwardX 配置缺少 HTTPS 控制面代理' || return 1
    assert_not_contains "$(<"${output}")" 'ALL_PROXY=' \
        'ForwardX 配置不应注入 SOCKS/ALL_PROXY' || return 1
    write_service_proxy_dropin komari-agent.service "${generic_output}" \
        || { fail '无法生成普通 Agent 代理配置'; return 1; }
    assert_contains "$(<"${generic_output}")" 'Environment="ALL_PROXY=socks5h://127.0.0.1:19080"' \
        '解除 ForwardX 禁止不应改变普通 Agent 的完整代理配置' || return 1
)

test_identity_guard_ownership_and_drift() {
    local directory=${WORK_ROOT}/identity-guard unit=komari-agent.service
    install -d -m 0700 "${directory}"
    komari_identity_guard_content >"${directory}/guard"
    printf '%s\n%s\n%s\n' "${KOMARI_IDENTITY_MARKER}" \
        '/opt/komari/auto-discovery.json' 'https://panel.example.test' >"${directory}/config"
    printf '%s\n%s\n%s\n' "${unit}" \
        "$(sha256sum "${directory}/guard" | awk '{print $1}')" \
        "$(sha256sum "${directory}/config" | awk '{print $1}')" >"${directory}/record"
    chmod 0700 "${directory}/guard"
    chmod 0600 "${directory}/config" "${directory}/record"
    managed_komari_identity_owned "${directory}" "${unit}" \
        || { fail '完整的 Komari 身份守卫所有权记录未被识别'; return 1; }
    printf '%s\n' 'external change' >>"${directory}/config"
    ! managed_komari_identity_owned "${directory}" "${unit}" \
        || { fail '身份守卫配置漂移后仍允许自动删除'; return 1; }
}

test_identity_guard_contract() {
    local source guard
    source=$(sed -n '1,$p' "${CN_ENTRY_ROLE}")
    guard=$(komari_identity_guard_content)
    assert_contains "${guard}" 'chmod 0600 -- "${identity}"' '身份文件没有收紧到 0600' || return 1
    assert_contains "${guard}" '--data-urlencode token@-' '令牌会暴露在 curl 命令行参数中' || return 1
    assert_contains "${guard}" '[[ ${http_status} == 401 ]] || exit 0' '非 401 响应可能误删身份' || return 1
    assert_contains "${guard}" '.message == "Unauthorized."' '没有核验 Komari 明确未授权响应' || return 1
    assert_contains "${guard}" 'http_status=$(' '没有通过只读接口验证缓存身份' || return 1
    assert_contains "${guard}" ') || exit 0' '网络或 TLS 失败时没有保留缓存身份' || return 1
    assert_contains "${guard}" 'quarantine_identity malformed' '损坏的本地身份不会被隔离' || return 1
    assert_contains "${guard}" 'mv -- "${identity}" "${destination}"' '旧身份不是隔离保留而是直接删除' || return 1
    assert_contains "${source}" 'komari_runtime_identity_config' '没有从 Komari 运行参数安全发现配置' || return 1
    assert_contains "${source}" '[[ -z ${expect} && -n ${auto_discovery} ]]' '未限制到启用自动发现的 Komari' || return 1
    assert_contains "${source}" 'ExecStartPre=+%s/guard %s/config' '守卫没有接入 Komari 启动前检查' || return 1
    assert_contains "${source}" 'remove_komari_identity_guard' '停用或失败回滚没有身份守卫清理路径' || return 1
}

test_identity_guard_runtime_behavior() (
    local fixture_root=${WORK_ROOT}/identity-runtime fake_bin bash_env scenario case_dir
    local backup_dir guard config identity curl_log logger_log output rc before_hash
    local quarantined quarantine_reason expected_curl_calls secret='SENTINEL_KOMARI_TOKEN_DO_NOT_PRINT'
    install -d -m 0700 "${fixture_root}"
    fake_bin=${fixture_root}/bin
    install -d -m 0700 "${fake_bin}"
    bash_env=${fixture_root}/bash-env

    cat >"${bash_env}" <<'EOF'
mapfile() {
    local array_name=MAPFILE line quoted index=0
    if [[ ${1:-} == -t ]]; then shift; fi
    [[ $# -le 1 ]] || return 2
    [[ $# -eq 0 ]] || array_name=$1
    eval "${array_name}=()"
    while IFS= read -r line || [[ -n ${line} ]]; do
        printf -v quoted '%q' "${line}"
        eval "${array_name}[${index}]=${quoted}"
        index=$((index + 1))
    done
}
EOF
    chmod 0600 "${bash_env}"

    cat >"${fake_bin}/chmod" <<'EOF'
#!/usr/bin/env bash
args=()
for arg in "$@"; do
    [[ ${arg} == -- ]] || args[${#args[@]}]=${arg}
done
/bin/chmod "${args[@]}"
EOF
    chmod 0700 "${fake_bin}/chmod"
    cat >"${fake_bin}/install" <<'EOF'
#!/usr/bin/env bash
args=()
while (( $# > 0 )); do
    case "$1" in
        -o|-g) shift 2 ;;
        --) shift ;;
        *) args[${#args[@]}]=$1; shift ;;
    esac
done
/usr/bin/install "${args[@]}"
EOF
    chmod 0700 "${fake_bin}/install"
    cat >"${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -u
response=
printf '%s\n' "$@" >"${PO0_TEST_CURL_LOG}"
while (( $# > 0 )); do
    case "$1" in
        -o) response=$2; shift 2 ;;
        -w|--connect-timeout|--max-time|--data-urlencode) shift 2 ;;
        *) shift ;;
    esac
done
cat >/dev/null
case "${PO0_TEST_CURL_MODE}" in
    success)
        printf '%s\n' '{"status":"success"}' >"${response}"
        printf '%s' 200
        ;;
    server-error)
        printf '%s\n' '{"status":"error","message":"Temporary failure."}' >"${response}"
        printf '%s' 500
        ;;
    timeout)
        exit 28
        ;;
    unauthorized)
        printf '%s\n' '{"status":"error","message":"Unauthorized."}' >"${response}"
        printf '%s' 401
        ;;
    ambiguous-401)
        printf '%s\n' '{"status":"error","message":"Try again."}' >"${response}"
        printf '%s' 401
        ;;
    *)
        exit 97
        ;;
esac
EOF
    chmod 0700 "${fake_bin}/curl"
    cat >"${fake_bin}/logger" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${PO0_TEST_LOGGER_LOG}"
EOF
    chmod 0700 "${fake_bin}/logger"

    for scenario in \
        success server-error timeout ambiguous-401 unauthorized malformed-config malformed-identity; do
        case_dir=${fixture_root}/${scenario}
        backup_dir=${case_dir}/backups
        guard=${case_dir}/guard
        config=${case_dir}/config
        identity=${case_dir}/komari/auto-discovery.json
        curl_log=${case_dir}/curl.log
        logger_log=${case_dir}/logger.log
        install -d -m 0700 "${case_dir}" "${identity%/*}"
        komari_identity_guard_content \
            | awk -v backup="${backup_dir}" '
                /^BACKUP_DIR=/ { print "BACKUP_DIR=" backup; next }
                { print }
            ' >"${guard}"
        chmod 0700 "${guard}"
        printf '%s\n%s\n%s\n' "${KOMARI_IDENTITY_MARKER}" \
            "${identity}" 'https://panel.example.test' >"${config}"
        chmod 0600 "${config}"
        case "${scenario}" in
            malformed-config)
                printf '%s\n' "${KOMARI_IDENTITY_MARKER}" "${identity}" >"${config}"
                printf '{"uuid":"node-%s","token":"%s"}\n' "${scenario}" "${secret}" >"${identity}"
                quarantine_reason=none
                expected_curl_calls=0
                ;;
            malformed-identity)
                printf '%s\n' '{"uuid":' >"${identity}"
                quarantine_reason=malformed
                expected_curl_calls=0
                ;;
            *)
                printf '{"uuid":"node-%s","token":"%s"}\n' "${scenario}" "${secret}" >"${identity}"
                quarantine_reason=unauthorized
                expected_curl_calls=1
                ;;
        esac
        before_hash=$(sha256sum "${identity}" | awk '{print $1}')

        set +e
        output=$(
            BASH_ENV="${bash_env}" \
            PATH="${fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin" \
            PO0_TEST_CURL_MODE="${scenario}" \
            PO0_TEST_CURL_LOG="${curl_log}" \
            PO0_TEST_LOGGER_LOG="${logger_log}" \
                /bin/bash "${guard}" "${config}" 2>&1
        )
        rc=$?
        set -e

        [[ ${rc} -eq 0 ]] || { fail "${scenario} 守卫没有保守退出（rc=${rc}）｜输出：${out}"; return 1; }
        assert_not_contains "${output}" "${secret}" "${scenario} 场景输出泄漏身份令牌" || return 1
        if (( expected_curl_calls == 0 )); then
            [[ ! -e ${curl_log} ]] \
                || { fail '损坏身份仍被发送到面板验证'; return 1; }
        else
            [[ -f ${curl_log} ]] \
                || { fail "${scenario} 场景没有执行面板验证"; return 1; }
            assert_not_contains "$(<"${curl_log}")" "${secret}" \
                "${scenario} 场景把身份令牌放进 curl 参数" || return 1
        fi

        case "${scenario}" in
            unauthorized|malformed-identity)
                [[ ! -e ${identity} && ! -L ${identity} ]] \
                    || { fail "${scenario} 场景没有隔离失效身份"; return 1; }
                [[ -d ${backup_dir} && ! -L ${backup_dir} ]] \
                    || { fail "${scenario} 场景没有创建安全备份目录"; return 1; }
                quarantined=$(find "${backup_dir}" -type f \
                    -name "auto-discovery.json.${quarantine_reason}.*" -print)
                [[ -n ${quarantined} && $(grep -c . <<<"${quarantined}") == 1 ]] \
                    || { fail "${scenario} 场景隔离文件数量不正确"; return 1; }
                assert_eq "${before_hash}" "$(sha256sum "${quarantined}" | awk '{print $1}')" \
                    "${scenario} 场景没有完整保留旧身份" || return 1
                ;;
            *)
                [[ -f ${identity} && ! -L ${identity} ]] \
                    || { fail "${scenario} 临时或不明确响应误删了身份"; return 1; }
                assert_eq "${before_hash}" "$(sha256sum "${identity}" | awk '{print $1}')" \
                    "${scenario} 场景改变了缓存身份" || return 1
                [[ ! -e ${backup_dir} ]] \
                    || { fail "${scenario} 场景错误创建了身份隔离备份"; return 1; }
                ;;
        esac
    done
)

# 启用失败时必须撤销本次创建的 Komari 身份守卫。此前只在产物里数字符串出现次数：
# TX_KOMARI_IDENTITY_CREATED 共出现 6 次，删掉两处真正的赋值仍剩 4 次，断言照样通过。
# 展示 IP 是纯装饰性菜单，此时代理已启用、ENABLE 已入日志、单元已进托管清单。
# 该菜单里输错一个字符不应该结束整个组件进程，更不应该让出口侧把已生效的配置报成失败。
test_report_ipv4_menu_invalid_choice_is_not_fatal() (
    local case_dir state function_body rc out
    case_dir=$(mktemp -d "${WORK_ROOT}/report-ip-menu.XXXXXXXX")
    state=${case_dir}/state
    mkdir -p -- "${state}"
    : >"${state}/service-proxy-actions.log"

    function_body=$(sed -n '/^manage_komari_report_ipv4() {/,/^}/p' "${CN_ENTRY_ROLE}")
    [[ -n ${function_body} ]] || { fail '未能提取展示 IP 菜单函数'; return 1; }
    eval "${function_body}"
    refresh_helper_from_state() { :; }
    HELPER=/bin/true
    report_ipv4_for_service() { printf '%s\n' ''; }
    die() { printf 'FATAL:%s\n' "$*" >&2; exit 1; }

    rc=0
    out=$( (manage_komari_report_ipv4 komari-agent.service "${state}" <<<9) 2>&1 ) || rc=$?
    [[ ${rc} -ne 0 ]] || { fail '无效选择没有返回非零'; return 1; }
    assert_not_contains "${out}" 'FATAL:' \
        '展示 IP 菜单的无效选择仍然终结了整个组件进程' || return 1
    assert_contains "${out}" '未做修改' '无效选择没有说明未做修改' || return 1
)

test_enable_rollback_removes_identity_guard() (
    local case_dir log rc
    case_dir=$(mktemp -d "${TEMP_BASE}/po0-identity-rollback.XXXXXXXX")
    trap 'rm -rf -- "${case_dir}"' EXIT
    log=${case_dir}/rollback.log
    : >"${log}"

    eval "$(sed -n '/^enable_transaction_cleanup() {/,/^}/p' "${CN_ENTRY_ROLE}")"
    remove_komari_identity_guard() { printf 'REMOVE_IDENTITY %s %s\n' "$1" "$2" >>"${log}"; }
    remove_cf_probe_go_guard_units() { printf 'REMOVE_GUARD_UNITS\n' >>"${log}"; }
    rollback_cf_probe_go_latency_compat() { :; }
    remove_cf_probe_latency_compat() { :; }
    remove_cf_probe_direct_report_compat() { :; }
    remove_managed_unit() { printf 'REMOVE_MANAGED\n' >>"${log}"; }
    restart_and_verify_running() { :; }
    systemctl() { :; }

    TX_COMMITTED=no
    TX_UNIT=komari-agent.service
    TX_STATE=${case_dir}/state
    TX_DROPIN_DIR=${case_dir}/dropin
    TX_DROPIN_FILE=${TX_DROPIN_DIR}/90-po0-unlock-proxy.conf
    TX_DROPIN_MAY_EXIST=no
    TX_COMPAT_DIR=${case_dir}/compat
    TX_COMPAT_CREATED=no
    TX_COMPAT_CURL_CREATED=no
    TX_CF_GUARD_CREATED=yes
    TX_KOMARI_IDENTITY_CREATED=yes
    TX_KOMARI_IDENTITY_DIR=${case_dir}/identity
    TX_ORIGINAL_RUNNING=no
    TX_LIST_MAY_CHANGE=yes
    rc=0
    ( enable_transaction_cleanup 1 ) >/dev/null 2>&1 || rc=$?

    grep -Fq "REMOVE_IDENTITY ${case_dir}/identity komari-agent.service" "${log}" \
        || { fail '启用失败没有撤销本次创建的 Komari 身份守卫'; return 1; }
    grep -Fxq REMOVE_GUARD_UNITS "${log}" \
        || { fail '启用失败没有撤销本次创建的 cf-probe 动态配置守卫'; return 1; }
    grep -Fxq REMOVE_MANAGED "${log}" \
        || { fail '启用失败没有回退托管清单'; return 1; }

    # 未创建过身份守卫时不得误删他人文件。
    : >"${log}"
    TX_KOMARI_IDENTITY_CREATED=no
    ( enable_transaction_cleanup 1 ) >/dev/null 2>&1 || true
    ! grep -Fq REMOVE_IDENTITY "${log}" \
        || { fail '未创建身份守卫时仍执行了删除'; return 1; }

    # 事务已提交时一律不撤销。
    : >"${log}"
    TX_COMMITTED=yes
    TX_KOMARI_IDENTITY_CREATED=yes
    ( enable_transaction_cleanup 0 ) >/dev/null 2>&1 || true
    [[ ! -s ${log} ]] || { fail '事务已提交仍执行了撤销动作'; return 1; }
)

# 身份守卫在既没有 jq 也没有 python3 时必须保守保留缓存身份，绝不隔离或删除。
# CI 两个作业都装了 jq，这条分支此前从未被执行过，而它属于安全红线。
test_identity_guard_parser_selection() (
    local root fake real case_dir guard config identity logger_log bash_env
    local tool scenario out rc before_hash
    root=${WORK_ROOT}/identity-parser
    install -d -m 0700 "${root}"
    fake=${root}/fake
    real=${root}/real
    install -d -m 0700 "${fake}" "${real}"
    # bash 必须在受控 PATH 里：桩脚本的 #!/usr/bin/env bash 需要按 PATH 找到它。
    for tool in sed readlink mv cat date rm mkdir dirname mktemp bash; do
        command -v "${tool}" >/dev/null 2>&1 \
            || { fail "夹具缺少必需命令：${tool}"; return 1; }
        ln -sf "$(command -v "${tool}")" "${real}/${tool}"
    done
    cat >"${fake}/chmod" <<'EOF'
#!/usr/bin/env bash
args=()
for arg in "$@"; do [[ ${arg} == -- ]] || args[${#args[@]}]=${arg}; done
/bin/chmod "${args[@]}"
EOF
    cat >"${fake}/install" <<'EOF'
#!/usr/bin/env bash
args=()
while (( $# > 0 )); do
    case "$1" in
        -o|-g) shift 2 ;;
        --) shift ;;
        *) args[${#args[@]}]=$1; shift ;;
    esac
done
/usr/bin/install "${args[@]}"
EOF
    cat >"${fake}/logger" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${PO0_TEST_LOGGER_LOG}"
EOF
    cat >"${fake}/curl" <<'EOF'
#!/usr/bin/env bash
printf 'CURL\n' >>"${PO0_TEST_CURL_LOG}"
exit 7
EOF
    chmod 0700 "${fake}/chmod" "${fake}/install" "${fake}/logger" "${fake}/curl"
    # macOS 自带的 bash 3.2 没有 mapfile 内建，用与既有守卫用例相同的垫片补齐。
    bash_env=${root}/bash-env
    cat >"${bash_env}" <<'EOF'
mapfile() {
    local array_name=MAPFILE line quoted index=0
    if [[ ${1:-} == -t ]]; then shift; fi
    [[ $# -le 1 ]] || return 2
    [[ $# -eq 0 ]] || array_name=$1
    eval "${array_name}=()"
    while IFS= read -r line || [[ -n ${line} ]]; do
        printf -v quoted '%q' "${line}"
        eval "${array_name}[${index}]=${quoted}"
        index=$((index + 1))
    done
}
EOF
    chmod 0600 "${bash_env}"

    for scenario in no-parser jq-only python3-only; do
        case_dir=${root}/${scenario}
        guard=${case_dir}/guard
        config=${case_dir}/config
        identity=${case_dir}/komari/auto-discovery.json
        logger_log=${case_dir}/logger.log
        install -d -m 0700 "${case_dir}" "${identity%/*}" "${case_dir}/bin"
        komari_identity_guard_content >"${guard}"
        chmod 0700 "${guard}"
        printf '%s\n%s\n%s\n' "${KOMARI_IDENTITY_MARKER}" "${identity}" \
            'https://panel.example.test' >"${config}"
        chmod 0600 "${config}"
        printf '{"uuid":"node-1","token":"PARSER_SCENARIO_TOKEN"}\n' >"${identity}"
        chmod 0600 "${identity}"
        before_hash=$(sha256sum "${identity}" | awk '{print $1}')
        case "${scenario}" in
            jq-only)
                command -v jq >/dev/null 2>&1 \
                    && ln -sf "$(command -v jq)" "${case_dir}/bin/jq"
                ;;
            python3-only)
                command -v python3 >/dev/null 2>&1 \
                    && ln -sf "$(command -v python3)" "${case_dir}/bin/python3"
                ;;
        esac
        if [[ ${scenario} != no-parser && ! -e ${case_dir}/bin/${scenario%%-only} ]]; then
            printf '    （本机没有 %s，跳过该分支的真实解析）\n' "${scenario%%-only}" >&2
            continue
        fi

        set +e
        out=$(
            BASH_ENV="${bash_env}" \
            PATH="${case_dir}/bin:${fake}:${real}" \
            PO0_TEST_LOGGER_LOG="${logger_log}" \
            PO0_TEST_CURL_LOG="${case_dir}/curl.log" \
                /bin/bash "${guard}" "${config}" 2>&1
        )
        rc=$?
        set -e
        assert_eq 0 "${rc}" "${scenario} 场景守卫没有保守退出" || return 1
        [[ -f ${identity} && ! -L ${identity} ]] \
            || { fail "${scenario} 场景删除了缓存身份"; return 1; }
        assert_eq "${before_hash}" "$(sha256sum "${identity}" | awk '{print $1}')" \
            "${scenario} 场景改动了缓存身份" || return 1
        assert_not_contains "${out}" PARSER_SCENARIO_TOKEN \
            "${scenario} 场景输出泄漏了身份令牌" || return 1
        if [[ ${scenario} == no-parser ]]; then
            [[ ! -e ${case_dir}/curl.log ]] \
                || { fail '没有解析器时仍向面板发起了验证'; return 1; }
            [[ -f ${logger_log} ]] \
                || { fail '没有解析器时没有走保守保留分支（未产生任何系统日志）'; return 1; }
            grep -Fq 'No jq or python3 is available' "${logger_log}" \
                || { fail '没有解析器时没有记录保守保留的原因'; return 1; }
        else
            [[ -f ${case_dir}/curl.log ]] \
                || { fail "${scenario} 场景没有进入面板验证，解析分支未被执行"; return 1; }
        fi
    done
)

test_report_ipv4_validation_and_rewrite() {
    local directory=${WORK_ROOT}/report-ip source_file output_file actual
    install -d -m 0700 "${directory}"
    source_file=${directory}/source.conf
    output_file=${directory}/output.conf

    public_helper_ipv4 1.1.1.1 || { fail '有效公网 IPv4 被拒绝'; return 1; }
    for actual in \
        10.0.0.1 100.64.0.1 127.0.0.1 169.254.1.1 172.16.0.1 \
        192.0.0.1 192.0.2.1 192.168.1.1 198.18.0.1 198.51.100.1 \
        203.0.113.1 224.0.0.1 999.1.1.1 \
        18446744073709551617.0.0.1; do
        ! public_helper_ipv4 "${actual}" \
            || { fail "非公网或无效 IPv4 被接受：${actual}"; return 1; }
    done

    printf '%s\n' \
        "${MANAGED_MARKER}" \
        '[Service]' \
        'Environment="HTTP_PROXY=http://127.0.0.1:13128"' \
        'Environment="AGENT_CUSTOM_IPV4=1.1.1.1"' >"${source_file}"
    assert_eq 1.1.1.1 "$(report_ipv4_from_dropin "${source_file}")" \
        '未能读取已有 Komari 展示 IPv4' || return 1

    write_report_ipv4_dropin "${source_file}" "${output_file}" set 8.8.8.8 \
        || { fail '更新 Komari 展示 IPv4 失败'; return 1; }
    assert_eq 1 "$(grep -Fxc 'Environment="AGENT_CUSTOM_IPV4=8.8.8.8"' "${output_file}")" \
        '更新后展示 IPv4 不是唯一的新值' || return 1
    assert_contains "$(<"${output_file}")" 'Environment="HTTP_PROXY=http://127.0.0.1:13128"' \
        '更新展示 IPv4 时破坏了代理配置' || return 1

    write_report_ipv4_dropin "${output_file}" "${source_file}" clear \
        || { fail '清除 Komari 展示 IPv4 失败'; return 1; }
    ! grep -Fq 'AGENT_CUSTOM_IPV4=' "${source_file}" \
        || { fail '恢复自动检测后仍残留展示 IPv4'; return 1; }
    assert_contains "$(<"${source_file}")" "${MANAGED_MARKER}" \
        '恢复自动检测时破坏了助手所有权标记' || return 1

    ! write_report_ipv4_dropin "${source_file}" "${output_file}" set 192.168.1.1 \
        || { fail '底层写入函数接受了私网 IPv4'; return 1; }
    managed_dropin_owned "${source_file}" \
        || { fail '助手生成的代理文件未被识别'; return 1; }
    sed '1s/.*/external change/' "${source_file}" >"${output_file}"
    ! managed_dropin_owned "${output_file}" \
        || { fail '所有权标记被修改后仍允许自动维护'; return 1; }
}

test_report_ipv4_lifecycle_contracts() {
    local source helper_case refresh_body disable_body scan_body
    source=$(sed -n '1,$p' "${CN_ENTRY_ROLE}")
    helper_case=$(sed -n '/^case "${1:-}" in/,/^esac$/p' "${CN_ENTRY_ROLE}")
    refresh_body=$(sed -n '/^    refresh-service)/,/^        ;;/p' "${CN_ENTRY_ROLE}")
    disable_body=$(sed -n '/^    disable-service)/,/^        ;;/p' "${CN_ENTRY_ROLE}")
    scan_body=$(sed -n '/^manage_komari_report_ipv4() {/,/^}/p' "${CN_ENTRY_ROLE}")

    assert_contains "${helper_case}" 'set-report-ip|clear-report-ip)' \
        '底层助手缺少设置或清除展示 IP 的入口' || return 1
    assert_contains "${helper_case}" 'public_helper_ipv4 "${requested_ip}"' \
        '底层助手没有拒绝非公网 IPv4' || return 1
    assert_contains "${helper_case}" 'write_report_ipv4_dropin "${dropin_file}" "${tmp}" set' \
        '设置展示 IP 没有使用可验证的确定性写入' || return 1
    assert_contains "${helper_case}" 'write_report_ipv4_dropin "${dropin_file}" "${tmp}" clear' \
        '恢复自动检测没有使用可验证的确定性写入' || return 1
    assert_contains "${refresh_body}" 'report_ip=$(report_ipv4_from_dropin "${dropin_file}" || true)' \
        '刷新连接配置前没有保存展示 IP' || return 1
    assert_contains "${refresh_body}" 'Environment="AGENT_CUSTOM_IPV4=%s"' \
        '刷新连接配置时没有恢复展示 IP' || return 1
    assert_contains "${disable_body}" 'rm -f "${dropin_file}"' \
        '停用 Komari 国外出口时没有移除含展示 IP 的配置' || return 1
    assert_contains "${source}" '"${HELPER}" disable-service "${unit}"' \
        '完整回滚没有复用展示 IP 清理路径' || return 1
    assert_contains "${scan_body}" 'while :' \
        '展示 IP 输入错误后不会留在当前流程重新输入' || return 1
    assert_contains "${scan_body}" 'public_ipv4 "${requested_ip}"' \
        '交互入口没有验证公网 IPv4' || return 1
    assert_contains "${scan_body}" '"${HELPER}" set-report-ip "${unit}" "${requested_ip}"' \
        '交互入口没有调用设置展示 IP' || return 1
    assert_contains "${scan_body}" '"${HELPER}" clear-report-ip "${unit}"' \
        '交互入口没有调用恢复自动检测' || return 1
}

test_install_and_lifecycle_contracts() {
    local source helper_case scan_body configured_body rollback_body cleanup_calls
    source=$(sed -n '1,$p' "${CN_ENTRY_ROLE}")
    helper_case=$(sed -n '/^case "${1:-}" in/,/^esac$/p' "${CN_ENTRY_ROLE}")
    scan_body=$(sed -n '/^scan_services() {/,/^}/p' "${CN_ENTRY_ROLE}")
    configured_body=$(sed -n '/^manage_configured_service() {/,/^}/p' "${CN_ENTRY_ROLE}")
    rollback_body=$(sed -n '/^rollback_services() {/,/^}/p' "${CN_ENTRY_ROLE}")
    ! grep -Fq 'redsocks' <<<"$(sed -n '/^ensure_.*dependencies() {/,/^}/p' "${CN_ENTRY_ROLE}")" \
        || { fail '依赖安装流程仍包含 redsocks'; return 1; }
    ! grep -Fq 'enable-komari-latency)' <<<"${helper_case}" \
        || { fail '底层助手仍暴露错误的延迟转发入口'; return 1; }
    assert_contains "${source}" 'TX_KOMARI_IDENTITY_CREATED' '启用失败不会回滚新增身份守卫' || return 1
    cleanup_calls=$(grep -Fc 'remove_legacy_komari_latency_compat "${state}" "${unit}"' <<<"${helper_case}")
    assert_eq 2 "${cleanup_calls}" \
        '刷新与停用连接配置没有同时接入旧版延迟转发清理' || return 1
    assert_contains "${scan_body}" 'manage_configured_service "${unit}" "${reasons[index]}" "${state}"' \
        '扫描旧 Komari 时没有进入已配置服务管理菜单' || return 1
    assert_contains "${configured_body}" '"${HELPER}" refresh-service "${unit}"' \
        '已配置服务菜单不会刷新旧 Komari 身份守卫' || return 1
    assert_contains "${configured_body}" '延迟任务请在 Komari 面板选择 ICMP' \
        '管理 Komari 后没有给出正确的 ICMP 使用说明' || return 1
    assert_contains "${rollback_body}" '"${HELPER}" disable-service "${unit}"' '完整回滚没有复用安全清理路径' || return 1
}

test_agent_scan_cancel_skips_proxy_probe_and_batches_metadata() (
    set -Eeuo pipefail
    local case_dir fixture_state function_body function_name output show_count metadata_count index
    local systemctl_log proxy_log action_log args unit actions rc
    case_dir=$(mktemp -d "${WORK_ROOT}/agent-scan-runtime.XXXXXXXX")
    fixture_state=${case_dir}/state
    systemctl_log=${case_dir}/systemctl.log
    proxy_log=${case_dir}/proxy.log
    action_log=${case_dir}/actions.log
    mkdir -p "${fixture_state}"
    : >"${fixture_state}/managed-services"

    for function_name in \
        service_is_excluded candidate_reason unit_has_proxy_environment sanitize_display_text \
        systemctl_scan verify_agent_proxy_change scan_services; do
        function_body=$(sed -n "/^${function_name}() {/,/^}/p" "${CN_ENTRY_ROLE}")
        [[ -n ${function_body} ]] || { fail "未能提取 ${function_name}"; return 1; }
        function_body=$(sed \
            's/${1,,}/${1}/g; s/${2,,}/${2}/g; s/${3,,}/${3}/g; s/${4,,}/${4}/g; s/${environment,,}/${environment}/g' \
            <<<"${function_body}")
        if [[ ${function_name} == scan_services ]]; then
            function_body=$(awk '
                index($0, "[[ -t 0 ]] || die") { print "    : # acceptance: temporary TTY bypass"; next }
                { print }
            ' <<<"${function_body}")
        fi
        eval "${function_body}"
    done

    HTTP_PROXY_URL=http://127.0.0.1:13128
    SOCKS_PROXY_URL=socks5h://127.0.0.1:19080
    require_root() { :; }
    active_state() { printf '%s\n' "${fixture_state}"; }
    valid_service_unit() { [[ ${1:-} == *.service ]]; }
    report_ipv4_for_service() { return 1; }
    verify_proxy() { printf '%s\n' PROBE >>"${proxy_log}"; }
    die() { printf '%s\n' "$*" >&2; return 1; }
    systemctl() {
        local command_name=${1:-} description fragment exec_start
        shift || true
        printf '%s %s\n' "${command_name}" "$*" >>"${systemctl_log}"
        case "${command_name}" in
            list-units)
                for ((index=1; index<=62; index++)); do
                    printf 'worker-%02d.service loaded active running Worker %02d\n' "${index}" "${index}"
                done
                printf '%s\n' 'forwardx-agent.service loaded active running ForwardX Agent'
                printf '%s\n' 'zz-custom-node.service loaded active running NyanPass Agent'
                ;;
            show)
                args=" $* "
                unit=${!#}
                if [[ ${unit} == forwardx-agent.service ]]; then
                    description='ForwardX Agent'
                    fragment=/etc/systemd/system/forwardx-agent.service
                    exec_start='{ path=/usr/local/bin/forwardx-agent ; argv[]=/usr/local/bin/forwardx-agent ; }'
                elif [[ ${unit} == zz-custom-node.service ]]; then
                    description='nyanpass'
                    fragment=/etc/systemd/system/zz-custom-node.service
                    exec_start='{ path=/opt/nyanpass/agent ; argv[]=/opt/nyanpass/agent ; }'
                else
                    description='Ordinary Worker'
                    fragment="/lib/systemd/system/${unit}"
                    exec_start='{ path=/usr/bin/worker ; argv[]=/usr/bin/worker ; }'
                fi
                if [[ ${args} == *' -p Description '* \
                    && ${args} == *' -p FragmentPath '* \
                    && ${args} == *' -p ExecStart '* ]]; then
                    printf 'Description=%s\nFragmentPath=%s\nExecStart=%s\n' \
                        "${description}" "${fragment}" "${exec_start}"
                elif [[ ${args} == *' -p Description '* ]]; then
                    printf '%s\n' "${description}"
                elif [[ ${args} == *' -p FragmentPath '* ]]; then
                    printf '%s\n' "${fragment}"
                elif [[ ${args} == *' -p ExecStart '* ]]; then
                    printf '%s\n' "${exec_start}"
                elif [[ ${args} == *' -p Environment '* ]]; then
                    printf '\n'
                fi
                ;;
            cat) return 1 ;;
            *) return 2 ;;
        esac
    }

    output=$(scan_services <<<0)
    [[ ! -e ${proxy_log} ]] \
        || { fail '用户只查看并取消扫描时仍执行代理出口探测'; return 1; }
    show_count=$(grep -c '^show ' "${systemctl_log}" || true)
    metadata_count=$(grep -Ec \
        '^show -p Description -p FragmentPath -p ExecStart -- .*\.service$' \
        "${systemctl_log}" || true)
    [[ ${metadata_count} -eq 64 ]] \
        || { fail "64 个服务只有 ${metadata_count} 次完整元数据读取"; return 1; }
    (( show_count >= 64 && show_count <= 66 )) \
        || { fail "64 个服务触发了异常数量的 systemctl show：${show_count}"; return 1; }
    assert_contains "${output}" 'forwardx-agent.service' \
        '批量读取元数据后没有识别 ForwardX Agent' || return 1
    assert_contains "${output}" 'zz-custom-node.service' \
        '没有通过描述和程序元数据识别自定义 NyanPass Agent' || return 1
    assert_contains "${output}" '未做修改' \
        '取消扫描没有安全返回' || return 1
    assert_contains "${output}" '正在读取运行中的服务信息' \
        '服务枚举前没有显示进度' || return 1

    : >"${action_log}"
    verify_proxy() { printf '%s\n' PROBE >>"${action_log}"; }
    refresh_helper_from_state() { printf '%s\n' REFRESH_HELPER >>"${action_log}"; }
    helper_fixture() { printf 'HELPER:%s\n' "$*" >>"${action_log}"; }
    HELPER=helper_fixture
    output=$(scan_services <<< $'1\nn')
    [[ ! -s ${action_log} ]] \
        || { fail '选择服务但在最终确认取消后仍探测代理或修改配置'; return 1; }

    : >"${action_log}"
    output=$(scan_services <<< $'1\ny')
    actions=$(<"${action_log}")
    [[ ${actions} == $'PROBE\nREFRESH_HELPER\nHELPER:enable-service forwardx-agent.service' ]] \
        || { fail "代理验证没有在确认后、修改前执行：${actions}"; return 1; }
    assert_contains "${output}" '正在并行验证 HTTP 与 SOCKS5 国外出口' \
        '确认修改后没有显示代理验证进度' || return 1

    systemctl() {
        case "${1:-}" in
            list-units) printf '%s\n' 'stuck-agent.service loaded active running Stuck Agent' ;;
            show) return 124 ;;
            *) return 1 ;;
        esac
    }
    set +e
    output=$(scan_services <<<0 2>&1)
    rc=$?
    set -e
    [[ ${rc} -eq 0 ]] || { fail '单个 systemd 元数据读取超时后扫描没有安全结束'; return 1; }
    assert_contains "${output}" '读取 systemd 信息失败或超时' \
        'systemd 元数据超时没有显示可诊断提示' || return 1

    systemctl() { return 124; }
    set +e
    output=$(scan_services <<<0 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail 'systemd 服务列表读取超时后扫描仍报告成功'; return 1; }
    assert_contains "${output}" '读取运行中 systemd 服务列表失败或超时' \
        'systemd 服务列表超时没有显示明确结论' || return 1
)

# 托管清单里的条目只能由 disable-service 的成功路径注销。若代理文件被外部删除
# （人工清理、Agent 重装、apt purge），此前该命令直接拒绝，导致完整回滚永久停在
# 这个单元上，产品内也没有别的注销入口。这里实跑 disable-service 分支验证三种情形。
po0_disable_service_fixture() {
    local case_dir=$1 systemd_root=$2 branch
    branch=$(sed -n '/^    disable-service)/,/^        ;;/p' "${CN_ENTRY_ROLE}")
    [[ -n ${branch} ]] || return 1
    # 只把硬编码的 systemd 根目录换成夹具目录，其余逻辑原样保留。
    branch=${branch//\/etc\/systemd\/system/${systemd_root}}
    branch=${branch#*disable-service)}
    branch=${branch%;;}
    {
        printf '%s\n' "MANAGED_MARKER='# Managed by Po0 Unlock; do not edit manually.'"
        sed -n '/^managed_dropin_owned() {/,/^}/p' "${CN_ENTRY_ROLE}"
        sed -n '/^disable_transaction_cleanup() {/,/^}/p' "${CN_ENTRY_ROLE}"
        printf '%s\n' \
            'usage() { echo usage >&2; }' \
            'valid_helper_service_unit() { [[ $1 == *.service ]]; }' \
            "helper_active_state() { printf '%s\\n' \"${case_dir}/state\"; }" \
            'acquire_service_lock() { :; }' \
            'confirm_helper_state_open() { :; }' \
            "cf_probe_compat_dir() { printf '%s\\n' \"\$1/po0-cf-probe-compat\"; }" \
            'managed_cf_probe_compat_owned() { :; }' \
            "komari_identity_compat_dir() { printf '%s\\n' \"\$1/po0-komari-identity\"; }" \
            'managed_komari_identity_owned() { :; }' \
            'service_is_running() { return 1; }' \
            'cf_probe_go_guard_units_present() { return 1; }' \
            'remove_cf_probe_go_guard_units() { :; }' \
            'systemctl() { :; }' \
            'restore_cf_probe_go_original_targets() { :; }' \
            'restore_cf_probe_go_managed_targets() { :; }' \
            'prepare_cf_probe_go_guard_units() { :; }' \
            'restart_and_verify_running() { :; }' \
            'is_komari_service() { return 1; }' \
            'remove_legacy_komari_latency_compat() { :; }' \
            'remove_cf_probe_latency_compat() { :; }' \
            'remove_komari_identity_guard() { :; }' \
            "ensure_managed_unit() { printf '%s\\n' \"\$2\" >>\"\$1/managed-services\"; }"
        printf 'run_disable_service() {\n    set -- disable-service "$1"\n%s\n}\n' "${branch}"
    } >"${case_dir}/fixture.sh"
    /bin/bash -n "${case_dir}/fixture.sh"
}

test_disable_service_handles_externally_removed_dropin() (
    local case_dir systemd_root state dropin_dir dropin_file rc out
    case_dir=$(mktemp -d "${TEMP_BASE}/po0-missing-dropin.XXXXXXXX")
    trap 'rm -rf -- "${case_dir}"' EXIT
    systemd_root=${case_dir}/systemd
    state=${case_dir}/state
    dropin_dir=${systemd_root}/demo-agent.service.d
    dropin_file=${dropin_dir}/90-po0-unlock-proxy.conf
    mkdir -p -- "${systemd_root}" "${state}" "${dropin_dir}"
    po0_disable_service_fixture "${case_dir}" "${systemd_root}" \
        || { fail '未能构造 disable-service 夹具'; return 1; }

    # 情形一：代理文件存在且属于本助手，正常移除并注销。
    printf '%s\n' 'demo-agent.service' 'other-agent.service' >"${state}/managed-services"
    printf '%s\n' '# Managed by Po0 Unlock; do not edit manually.' '[Service]' >"${dropin_file}"
    rc=0
    out=$(/bin/bash -c "source '${case_dir}/fixture.sh'; run_disable_service demo-agent.service" 2>&1) || rc=$?
    [[ ${rc} -eq 0 ]] || { fail "正常移除失败：rc=${rc}｜${out}"; return 1; }
    grep -Fxq 'other-agent.service' "${state}/managed-services" \
        || { fail '正常移除误删了其他托管记录'; return 1; }
    ! grep -Fxq 'demo-agent.service' "${state}/managed-services" \
        || { fail '正常移除后托管记录仍在'; return 1; }
    [[ ! -e ${dropin_file} ]] || { fail '正常移除后代理文件仍在'; return 1; }

    # 情形二：代理文件已被外部删除，必须按已移除处理并注销记录。
    mkdir -p -- "${dropin_dir}"
    printf '%s\n' 'demo-agent.service' 'other-agent.service' >"${state}/managed-services"
    rc=0
    out=$(/bin/bash -c "source '${case_dir}/fixture.sh'; run_disable_service demo-agent.service" 2>&1) || rc=$?
    [[ ${rc} -eq 0 ]] \
        || { fail "代理文件缺失时 disable-service 仍然失败：rc=${rc}｜${out}"; return 1; }
    ! grep -Fxq 'demo-agent.service' "${state}/managed-services" \
        || { fail '代理文件缺失时没有注销托管记录，完整回滚仍会卡住'; return 1; }
    grep -Fxq 'other-agent.service' "${state}/managed-services" \
        || { fail '代理文件缺失的处理误删了其他托管记录'; return 1; }
    grep -Fq '已不存在' <<<"${out}" || { fail '没有说明代理文件已不存在'; return 1; }
    [[ ! -e ${dropin_file} ]] || { fail '代理文件缺失的处理反而重建了文件'; return 1; }

    # 情形三：代理文件存在但已被人工修改，必须继续拒绝。
    mkdir -p -- "${dropin_dir}"
    printf '%s\n' 'demo-agent.service' >"${state}/managed-services"
    printf '%s\n' '# hand edited' '[Service]' >"${dropin_file}"
    rc=0
    out=$(/bin/bash -c "source '${case_dir}/fixture.sh'; run_disable_service demo-agent.service" 2>&1) || rc=$?
    [[ ${rc} -ne 0 ]] || { fail '人工修改过的代理文件被自动删除'; return 1; }
    grep -Fxq 'demo-agent.service' "${state}/managed-services" \
        || { fail '拒绝删除时不应注销托管记录'; return 1; }
    [[ -f ${dropin_file} ]] || { fail '拒绝删除时不应动代理文件'; return 1; }
    grep -Fq '已被人工修改' <<<"${out}" || { fail '拒绝原因不明确'; return 1; }
)

test_managed_agent_action_menu_can_refresh_or_disable() (
    set -Eeuo pipefail
    local function_body output actions rc
    local case_dir state action_log
    case_dir=$(mktemp -d "${WORK_ROOT}/managed-agent-action.XXXXXXXX")
    state=${case_dir}/state
    action_log=${case_dir}/actions.log
    mkdir -p "${state}"

    function_body=$(sed -n '/^manage_configured_service() {/,/^}/p' "${CN_ENTRY_ROLE}")
    [[ -n ${function_body} ]] \
        || { fail '缺少已配置 Agent 的检查或撤销交互入口'; return 1; }
    eval "${function_body}"

    verify_agent_proxy_change() { printf '%s\n' PROBE >>"${action_log}"; }
    refresh_helper_from_state() { printf '%s\n' REFRESH_HELPER >>"${action_log}"; }
    manage_komari_report_ipv4() { printf '%s\n' MANAGE_KOMARI >>"${action_log}"; }
    helper_fixture() {
        printf 'HELPER:%s\n' "$*" >>"${action_log}"
        [[ ${1:-} != fail ]]
    }
    HELPER=helper_fixture

    : >"${action_log}"
    output=$(manage_configured_service forwardx-agent.service \
        '识别为 ForwardX 转发面板 Agent' "${state}" <<<0)
    [[ ! -s ${action_log} ]] \
        || { fail '在已配置服务菜单返回时仍执行了检查或修改'; return 1; }
    assert_contains "${output}" '未做修改' '返回菜单时没有明确说明未修改' || return 1

    : >"${action_log}"
    output=$(manage_configured_service forwardx-agent.service \
        '识别为 ForwardX 转发面板 Agent' "${state}" <<< $'2\nn')
    [[ ! -s ${action_log} ]] \
        || { fail '取消撤销后仍执行了底层修改'; return 1; }
    assert_contains "${output}" '未做修改' '取消撤销后没有明确说明未修改' || return 1

    : >"${action_log}"
    output=$(manage_configured_service forwardx-agent.service \
        '识别为 ForwardX 转发面板 Agent' "${state}" <<< $'2\ny')
    actions=$(<"${action_log}")
    [[ ${actions} == $'REFRESH_HELPER\nHELPER:disable-service forwardx-agent.service' ]] \
        || { fail "撤销没有只调用安全停用路径：${actions}"; return 1; }
    assert_contains "${output}" 'Agent 服务仍保留' '撤销后没有说明 Agent 本体仍保留' || return 1
    assert_contains "${output}" '恢复直接联网' '撤销后没有说明恢复直连' || return 1
    grep -Eq $'DISABLE\tforwardx-agent\.service$' "${state}/service-proxy-actions.log" \
        || { fail '撤销成功没有写入操作记录'; return 1; }

    : >"${action_log}"
    output=$(manage_configured_service forwardx-agent.service \
        '识别为 ForwardX 转发面板 Agent' "${state}" <<<1)
    actions=$(<"${action_log}")
    [[ ${actions} == $'PROBE\nREFRESH_HELPER\nHELPER:refresh-service forwardx-agent.service' ]] \
        || { fail "检查更新没有按验证、刷新、更新的顺序执行：${actions}"; return 1; }
    assert_contains "${output}" '已检查并更新' '检查更新成功后没有明确结果' || return 1

    helper_fixture() {
        printf 'HELPER:%s\n' "$*" >>"${action_log}"
        return 1
    }
    : >"${action_log}"
    set +e
    output=$(manage_configured_service forwardx-agent.service \
        '识别为 ForwardX 转发面板 Agent' "${state}" <<< $'2\ny' 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail '底层撤销失败时交互入口错误报告成功'; return 1; }
    assert_contains "${output}" '原配置' '撤销失败时没有说明原配置已保留或恢复' || return 1
)

run_case() {
    local name=$1 function=$2
    printf '  - %s ... ' "${name}"
    if "${function}"; then
        PASS_COUNT=$((PASS_COUNT + 1)); printf '%s\n' PASS
    else
        FAIL_COUNT=$((FAIL_COUNT + 1)); printf '%s\n' FAIL
    fi
}

main() {
    make_helper_library
    printf '%s\n' 'Komari 兼容能力验收：'
    run_case '旧版延迟文件归属记录与外部改动保护' test_owned_files_and_drift_protection
    run_case '停止创建旧方案并提供安全清理路径' test_legacy_cleanup_contract
    run_case '归属明确的旧版组件可以完整清理' test_legacy_cleanup_execution
    run_case '旧服务或防火墙清理失败时保留恢复材料' test_legacy_cleanup_failures_preserve_recovery_files
    run_case 'Agent 扫描排除旧辅助服务且保留真正 Agent' test_internal_service_scan_exclusion
    run_case '识别 ForwardX 与 NyanPass 转发面板 Agent' test_agent_product_candidate_detection
    run_case 'ForwardX 只使用 HTTP/HTTPS 控制面代理' test_forwardx_control_plane_proxy_profile
    run_case '身份守卫所有权记录与漂移保护' test_identity_guard_ownership_and_drift
    run_case '身份校验、脱敏、保守失败与隔离保留' test_identity_guard_contract
    run_case '身份守卫对面板响应和损坏身份执行保守策略' test_identity_guard_runtime_behavior
    run_case '展示 IPv4 校验、设置、更新、清除与所有权保护' test_report_ipv4_validation_and_rewrite
    run_case '展示 IPv4 刷新保留、停用与完整回滚均已接入' test_report_ipv4_lifecycle_contracts
    run_case 'ICMP 指引、旧方案清理与完整回滚均已接入' test_install_and_lifecycle_contracts
    run_case 'Agent 扫描取消不探测代理且批量读取元数据' test_agent_scan_cancel_skips_proxy_probe_and_batches_metadata
    run_case '已配置 Agent 可从扫描入口检查更新或安全撤销' test_managed_agent_action_menu_can_refresh_or_disable
    run_case '代理文件被外部删除后仍可注销托管记录' test_disable_service_handles_externally_removed_dropin
    run_case '展示 IP 菜单输错不会终结组件进程' test_report_ipv4_menu_invalid_choice_is_not_fatal
    run_case '启用失败会撤销身份守卫与动态配置守卫' test_enable_rollback_removes_identity_guard
    run_case '身份守卫在缺少解析器时保守保留身份' test_identity_guard_parser_selection
    printf '结果：%d 通过，%d 失败\n' "${PASS_COUNT}" "${FAIL_COUNT}"
    (( FAIL_COUNT == 0 ))
}

main "$@"
