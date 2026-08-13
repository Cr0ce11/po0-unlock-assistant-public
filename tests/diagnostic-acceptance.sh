#!/usr/bin/env bash
set -u
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=${TEST_DIR%/tests}
SETUP_SOURCE=${PROJECT_DIR}/setup.sh
BUNDLE=${PROJECT_DIR}/po0-unlock.sh
PASS_COUNT=0
FAIL_COUNT=0

fail() { printf '    失败：%s\n' "$*" >&2; return 1; }
assert_contains() {
    local haystack=$1 needle=$2 message=$3
    grep -Fq -- "${needle}" <<<"${haystack}" || fail "${message}（缺少：${needle}）"
}
assert_not_contains() {
    local haystack=$1 needle=$2 message=$3
    ! grep -Fq -- "${needle}" <<<"${haystack}" || fail "${message}（不应包含：${needle}）"
}
assert_matches() {
    local haystack=$1 pattern=$2 message=$3
    grep -Eq -- "${pattern}" <<<"${haystack}" || fail "${message}（格式：${pattern}）"
}

extract_function() {
    local name=$1
    sed -n "/^${name}() {/,/^}/p" "${SETUP_SOURCE}"
}

test_integrated_user_interface() {
    local source bundle_report combined_body
    source=$(<"${SETUP_SOURCE}")
    combined_body=$(sed -n '/^health_check_with_diagnostic_offer() {/,/^}/p' "${SETUP_SOURCE}")
    assert_contains "${source}" '3) 健康检查与问题处理' \
        '诊断能力没有归入现有健康检查菜单' || return 1
    assert_contains "${source}" '3) run_cn_entry_operation health_check_with_diagnostic_offer; pause_for_menu' \
        '健康检查与诊断报告没有共享同一操作会话' || return 1
    assert_contains "${combined_body}" 'health_check || offer_diagnostic_report' \
        '健康检查异常后没有提供诊断报告' || return 1
    assert_contains "${source}" 'diagnose) run_cn_entry_operation diagnostic_report' \
        '没有保留直接诊断入口' || return 1
    [[ $(grep -Fxc '        printf '\''  3) 健康检查与问题处理\n'\''' "${SETUP_SOURCE}") -eq 1 ]] \
        || { fail '主菜单中的问题处理入口不是唯一一项'; return 1; }
    bundle_report=$(sed -n '/^diagnostic_report() (/,/^)/p' "${BUNDLE}")
    assert_contains "${bundle_report}" '    materialize_roles' \
        '单文件诊断入口没有先解开内置组件' || return 1
}

test_read_only_and_local_only_contract() {
    local report_body
    report_body=$(sed -n '/^diagnostic_report() (/,/^)/p' "${SETUP_SOURCE}")
    assert_contains "${report_body}" 'health_check_loaded no' \
        '报告没有强制使用只读健康检查' || return 1
    assert_contains "${report_body}" '报告不会自动上传' \
        '界面没有说明本地保存边界' || return 1
    for forbidden in \
        'systemctl restart' 'systemctl start' 'systemctl enable' \
        'apt-get' 'curl ' 'scp ' 'upload_cn_entry_role' \
        'run_exit_role "${EXIT_CMD_REPAIR}"'; do
        assert_not_contains "${report_body}" "${forbidden}" \
            "诊断报告越界执行：${forbidden}" || return 1
    done
}

test_protected_atomic_output_contract() {
    local report_body
    report_body=$(sed -n '/^diagnostic_report() (/,/^)/p' "${SETUP_SOURCE}")
    for needle in \
        '[[ -L ${DIAGNOSTIC_ROOT} ]]' \
        'install -d -o root -g root -m 0700 "${DIAGNOSTIC_ROOT}"' \
        'chmod 0600 "${raw_file}" "${report_tmp}"' \
        'sanitize_diagnostic_stream <"${raw_file}" >"${report_tmp}"' \
        'mv -- "${report_tmp}" "${report_file}"' \
        'chmod 0600 "${report_file}"'; do
        assert_contains "${report_body}" "${needle}" \
            "报告文件保护缺失：${needle}" || return 1
    done
}

test_redaction_examples() (
    local sanitizer sample output
    sanitizer=$(extract_function sanitize_diagnostic_stream)
    [[ -n ${sanitizer} ]] || { fail '未能提取脱敏函数'; return 1; }
    eval "${sanitizer}"
    sample=$'server=https://panel.example.com:443/api\nipv4=203.0.113.24:45222\nipv6=2001:db8::1234\nuser=root@example.com\npassword=VisibleSecret\nfingerprint=SHA256:abcdefghijklmnop\n{"token":"TokenValueShouldDisappear"}\n/home/alice/config\nadjacent-spaces=192.0.2.1 198.51.100.2\nthree-adjacent=192.0.2.3 198.51.100.4 203.0.113.5\nadjacent-comma=192.0.2.6,198.51.100.7\nadjacent-port=192.0.2.8 198.51.100.9:45123'
    output=$(sanitize_diagnostic_stream <<<"${sample}")
    for secret in \
        'panel.example.com' '203.0.113.24' '45222' '2001:db8::1234' \
        'root@example.com' 'VisibleSecret' 'abcdefghijklmnop' \
        'TokenValueShouldDisappear' '/home/alice' \
        '192.0.2.1' '198.51.100.2' \
        '192.0.2.3' '198.51.100.4' '203.0.113.5' \
        '192.0.2.6' '198.51.100.7' \
        '192.0.2.8' '198.51.100.9' '45123'; do
        assert_not_contains "${output}" "${secret}" \
            "脱敏后仍包含：${secret}" || return 1
    done
    for marker in '[已隐藏地址]' '[已隐藏账号]' '[已隐藏敏感内容]' '[已隐藏指纹]'; do
        assert_contains "${output}" "${marker}" \
            "脱敏输出缺少标记：${marker}" || return 1
    done
    for expected in \
        'adjacent-spaces=[已隐藏地址] [已隐藏地址]' \
        'three-adjacent=[已隐藏地址] [已隐藏地址] [已隐藏地址]' \
        'adjacent-comma=[已隐藏地址],[已隐藏地址]' \
        'adjacent-port=[已隐藏地址] [已隐藏地址]:[已隐藏端口]'; do
        assert_contains "${output}" "${expected}" \
            "同行相邻地址没有按预期逐个隐藏：${expected}" || return 1
    done
)

test_bounded_diagnostics() {
    local source
    source=$(<"${SETUP_SOURCE}")
    assert_contains "${source}" 'DIAGNOSTIC_LOG_LINES=80' \
        '日志数量没有固定上限' || return 1
    assert_contains "${source}" '-n "${DIAGNOSTIC_LOG_LINES}"' \
        '收集日志时没有使用数量上限' || return 1
    assert_contains "${source}" '托管 Agent：总数=' \
        '国内入口没有使用汇总方式保护 Agent 名称' || return 1
}

test_safe_observability_metadata() (
    local function_name function_body output state_root state marker attempt_dir attempt_log fixture_nonroot_path=
    local linked_marker escaped_state
    state_root=$(mktemp -d)
    trap 'rm -rf -- "${state_root}"' EXIT

    for function_name in \
        diagnostic_regular_root_file \
        diagnostic_root_directory \
        diagnostic_active_state \
        diagnostic_tunnel_configured_at \
        diagnostic_local_snapshot \
        cn_entry_control_dir_safe \
        cn_entry_attempt_log_safe \
        cn_entry_initial_attempt_count; do
        function_body=$(extract_function "${function_name}")
        [[ -n ${function_body} ]] \
            || { fail "未能提取诊断元数据函数：${function_name}"; return 1; }
        eval "${function_body}"
    done

    fixture_mode() {
        case $(uname -s) in
            Darwin) /usr/bin/stat -f '%Lp' "$1" ;;
            *) /usr/bin/stat -c '%a' "$1" ;;
        esac
    }
    fixture_links() {
        case $(uname -s) in
            Darwin) /usr/bin/stat -f '%l' "$1" ;;
            *) /usr/bin/stat -c '%h' "$1" ;;
        esac
    }
    fixture_size() {
        case $(uname -s) in
            Darwin) /usr/bin/stat -f '%z' "$1" ;;
            *) /usr/bin/stat -c '%s' "$1" ;;
        esac
    }
    stat() {
        [[ ${1:-} == -c ]] || return 1
        case "${2:-}" in
            %u)
                if [[ ${3:-} == "${fixture_nonroot_path}" ]]; then printf '%s\n' 1000; else printf '%s\n' 0; fi
                ;;
            %a) fixture_mode "${3:-}" ;;
            %h) fixture_links "${3:-}" ;;
            %s) fixture_size "${3:-}" ;;
            *) return 1 ;;
        esac
    }

    PO0_STATE_ROOT=${state_root}/runtime
    state=${PO0_STATE_ROOT}/20260804T014000Z
    marker=${state}/tunnel-configured-at
    mkdir -p -- "${state}"
    chmod 0700 "${PO0_STATE_ROOT}" "${state}"
    printf '%s\n' "${state}" >"${PO0_STATE_ROOT}/ACTIVE"
    printf '%s\n' '2026-08-04T01:44:23Z' >"${marker}"
    chmod 0600 "${PO0_STATE_ROOT}/ACTIVE" "${marker}"

    output=$(diagnostic_tunnel_configured_at)
    [[ ${output} == '2026-08-04T014423Z' ]] \
        || { fail "合法隧道生效时间没有安全转换为紧凑 UTC 格式：${output}"; return 1; }

    installation_active() { return 0; }
    diagnostic_service_summary() { :; }
    output=$(diagnostic_local_snapshot)
    assert_contains "${output}" '当前隧道配置生效时间（UTC）：2026-08-04T014423Z' \
        '国外出口概况没有展示当前隧道配置生效时间' || return 1

    printf '%s\n' '2026-08-04T25:61:61Z' >"${marker}"
    [[ $(diagnostic_tunnel_configured_at) == 未知 ]] \
        || { fail '非法 UTC 时间没有被拒绝'; return 1; }
    printf '%s\n' '2026-08-04T01:44:23Z' >"${marker}"

    ln "${PO0_STATE_ROOT}/ACTIVE" "${state_root}/active-link"
    [[ $(diagnostic_tunnel_configured_at) == 未知 ]] \
        || { fail '额外硬链接的 ACTIVE 文件没有被拒绝'; return 1; }
    rm -f -- "${state_root}/active-link"

    linked_marker=${state_root}/linked-marker
    ln "${marker}" "${linked_marker}"
    [[ $(diagnostic_tunnel_configured_at) == 未知 ]] \
        || { fail '额外硬链接的隧道时间文件没有被拒绝'; return 1; }
    rm -f -- "${linked_marker}"

    chmod 0644 "${marker}"
    [[ $(diagnostic_tunnel_configured_at) == 未知 ]] \
        || { fail '权限异常的隧道时间文件没有被拒绝'; return 1; }
    chmod 0600 "${marker}"
    fixture_nonroot_path=${marker}
    [[ $(diagnostic_tunnel_configured_at) == 未知 ]] \
        || { fail '非 root 所有的隧道时间文件没有被拒绝'; return 1; }
    fixture_nonroot_path=

    rm -f -- "${marker}"
    printf '%s\n' '2026-08-04T01:44:23Z' >"${state_root}/marker-target"
    chmod 0600 "${state_root}/marker-target"
    ln -s "${state_root}/marker-target" "${marker}"
    [[ $(diagnostic_tunnel_configured_at) == 未知 ]] \
        || { fail '符号链接隧道时间文件没有被拒绝'; return 1; }
    rm -f -- "${marker}"
    printf '%s\n' '2026-08-04T01:44:23Z' >"${marker}"
    chmod 0600 "${marker}"

    escaped_state=${state_root}/escaped
    mkdir -p -- "${escaped_state}"
    chmod 0700 "${escaped_state}"
    printf '%s\n' '2026-08-04T01:44:23Z' >"${escaped_state}/tunnel-configured-at"
    chmod 0600 "${escaped_state}/tunnel-configured-at"
    printf '%s\n' "${PO0_STATE_ROOT}/../escaped" >"${PO0_STATE_ROOT}/ACTIVE"
    [[ $(diagnostic_tunnel_configured_at) == 未知 ]] \
        || { fail 'ACTIVE 路径穿越没有被拒绝'; return 1; }
    printf '%s\n%s\n' "${state}" "${escaped_state}" >"${PO0_STATE_ROOT}/ACTIVE"
    [[ $(diagnostic_tunnel_configured_at) == 未知 ]] \
        || { fail '多行 ACTIVE 状态没有被拒绝'; return 1; }
    printf '%s\n' "${state}" >"${PO0_STATE_ROOT}/ACTIVE"
    chmod 0600 "${PO0_STATE_ROOT}/ACTIVE"

    CN_ENTRY_CONTROL_BASE=${state_root}/run
    CN_ENTRY_ATTEMPT_LOG_NAME=initial-attempts
    CN_ENTRY_ATTEMPT_LOG_MAX_BYTES=4096
    attempt_dir=${CN_ENTRY_CONTROL_BASE}/po0-cn-ssh.Ab12Cd34
    attempt_log=${attempt_dir}/initial-attempts
    mkdir -p -- "${attempt_dir}"
    chmod 0700 "${attempt_dir}"
    CN_ENTRY_CONTROL_DIR=${attempt_dir}
    : >"${attempt_log}"
    chmod 0600 "${attempt_log}"
    [[ $(cn_entry_initial_attempt_count) == 0 ]] \
        || { fail '空建连记录没有返回 0'; return 1; }
    printf '1\n1\n1\n' >"${attempt_log}"
    [[ $(cn_entry_initial_attempt_count) == 3 ]] \
        || { fail '建连记录没有返回真实尝试次数'; return 1; }
    chmod 0644 "${attempt_log}"
    [[ $(cn_entry_initial_attempt_count) == 未知 ]] \
        || { fail '权限异常的建连记录没有被拒绝'; return 1; }
    chmod 0600 "${attempt_log}"
    ln "${attempt_log}" "${state_root}/attempt-link"
    [[ $(cn_entry_initial_attempt_count) == 未知 ]] \
        || { fail '额外硬链接的建连记录没有被拒绝'; return 1; }
    rm -f -- "${state_root}/attempt-link"
    printf '1\ninvalid\n' >"${attempt_log}"
    [[ $(cn_entry_initial_attempt_count) == 未知 ]] \
        || { fail '异常建连记录内容没有被拒绝'; return 1; }
    rm -f -- "${attempt_log}"
    [[ $(cn_entry_initial_attempt_count) == 0 ]] \
        || { fail '缺失建连记录没有安全回退为 0'; return 1; }
)

test_report_generation_flow() (
    local function_name function_body output report report_content
    local sandbox
    sandbox=$(mktemp -d)
    cleanup() { rm -rf -- "${sandbox}"; }
    trap cleanup EXIT

    for function_name in sanitize_diagnostic_stream diagnostic_report; do
        if [[ ${function_name} == diagnostic_report ]]; then
            function_body=$(sed -n '/^diagnostic_report() (/,/^)/p' "${SETUP_SOURCE}")
        else
            function_body=$(extract_function "${function_name}")
        fi
        [[ -n ${function_body} ]] || { fail "未能提取函数：${function_name}"; return 1; }
        eval "${function_body}"
    done

    DIAGNOSTIC_ROOT=${sandbox}/diagnostics
    DIAGNOSTIC_LOG_LINES=80
    SCRIPT_VERSION=2.2.0-test
    C_GREEN= C_RESET=
    require_root() { return 0; }
    install() {
        local last=
        for last in "$@"; do :; done
        command install -d -m 0700 "${last}"
    }
    stat() {
        if [[ ${1:-} == -c && ${2:-} == '%u' ]]; then
            printf '%s\n' 0
        else
            command stat "$@"
        fi
    }
    load_config() { return 0; }
    diagnostic_local_snapshot() {
        printf '%s\n' \
            'local=203.0.113.9:3128 token=LocalTokenMustDisappear' \
            '当前隧道配置生效时间（UTC）：2026-08-04T014423Z'
    }
    health_check_loaded() {
        printf '%s\n' 'health=https://panel.example.com:443 password=HealthSecret'
        return 1
    }
    ssh_cn_entry() { return 0; }
    diagnostic_remote_snapshot() {
        printf '%s\n' 'remote=2001:db8::42 user=root@example.net'
    }
    journalctl() {
        printf '%s\n' '{"token":"JournalSecret"} ssh://admin@host.example.org:22'
    }
    cn_entry_initial_attempt_count() { printf '%s\n' 2; }

    output=$(diagnostic_report) || { fail '模拟诊断报告生成失败'; return 1; }
    report=$(find "${DIAGNOSTIC_ROOT}" -maxdepth 1 -type f -name 'po0-diagnostic-*.txt' -print)
    [[ -n ${report} && -f ${report} ]] \
        || { fail '没有生成最终诊断报告'; return 1; }
    [[ $(find "${DIAGNOSTIC_ROOT}" -maxdepth 1 -type f -name '.*' | wc -l | tr -d ' ') -eq 0 ]] \
        || { fail '生成后残留了含原始信息的临时文件'; return 1; }
    assert_contains "${output}" '报告不会自动上传' \
        '完成提示没有说明本地保存边界' || return 1
    report_content=$(<"${report}")
    assert_contains "${report_content}" '===== 诊断采集摘要 =====' \
        '最终报告缺少诊断采集摘要' || return 1
    for label in \
        '连接配置读取耗时（秒）' \
        '国外出口概况耗时（秒）' \
        '完整健康检查耗时（秒）' \
        '国内入口概况耗时（秒）' \
        '近期错误采集耗时（秒）' \
        '原始诊断采集总耗时（秒）'; do
        assert_matches "${report_content}" "^${label}：[0-9]+$" \
            "最终报告的${label}不是非负整数" || return 1
    done
    assert_contains "${report_content}" '本次操作国内入口 SSH 初始建连尝试次数：2' \
        '最终报告没有记录本次 SSH 初始建连次数' || return 1
    assert_contains "${report_content}" \
        '当前隧道配置生效时间（UTC）：2026-08-04T014423Z' \
        '隧道生效时间没有完整通过脱敏流程' || return 1
    for secret in \
        '203.0.113.9' '3128' 'LocalTokenMustDisappear' \
        'panel.example.com' 'HealthSecret' '2001:db8::42' \
        'root@example.net' 'JournalSecret' 'host.example.org' 'admin@'; do
        assert_not_contains "${report_content}" "${secret}" \
            "最终报告仍包含：${secret}" || return 1
    done

    DIAGNOSTIC_ROOT=${sandbox}/diagnostics-without-config
    load_config() { printf '%s\n' 'fixture config unavailable' >&2; return 1; }
    ssh_cn_entry() { : >"${sandbox}/unexpected-ssh"; return 1; }
    output=$(diagnostic_report) || { fail '无配置时诊断报告生成失败'; return 1; }
    report=$(find "${DIAGNOSTIC_ROOT}" -maxdepth 1 -type f -name 'po0-diagnostic-*.txt' -print)
    report_content=$(<"${report}")
    assert_contains "${report_content}" '完整健康检查耗时（秒）：未执行' \
        '无配置时把健康检查误报为已执行' || return 1
    assert_contains "${report_content}" '国内入口概况耗时（秒）：未执行' \
        '无配置时把国内入口采集误报为已执行' || return 1
    [[ ! -e ${sandbox}/unexpected-ssh ]] \
        || { fail '无配置时仍尝试连接国内入口'; return 1; }
)

run_case() {
    local name=$1 function=$2 rc had_errexit=no
    printf '  - %s ... ' "${name}"
    [[ $- == *e* ]] && had_errexit=yes
    set +e
    ( set -Eeuo pipefail; "${function}" )
    rc=$?
    [[ ${had_errexit} == yes ]] && set -e
    if [[ ${rc} -eq 0 ]]; then
        PASS_COUNT=$((PASS_COUNT + 1)); printf '%s\n' PASS
    else
        FAIL_COUNT=$((FAIL_COUNT + 1)); printf '%s\n' FAIL
    fi
}

main() {
    printf '%s\n' '脱敏诊断报告验收：'
    run_case '与健康检查合并且不增加一级菜单' test_integrated_user_interface
    run_case '报告保持只读并仅保存到本机' test_read_only_and_local_only_contract
    run_case '报告目录、临时文件和最终文件受保护' test_protected_atomic_output_contract
    run_case '常见地址、账号和敏感内容会被隐藏' test_redaction_examples
    run_case '日志有上限且 Agent 只显示汇总' test_bounded_diagnostics
    run_case '诊断元数据只从受保护状态安全读取' test_safe_observability_metadata
    run_case '完整生成流程不残留原始内容' test_report_generation_flow
    printf '结果：%d 通过，%d 失败\n' "${PASS_COUNT}" "${FAIL_COUNT}"
    (( FAIL_COUNT == 0 ))
}

main "$@"
