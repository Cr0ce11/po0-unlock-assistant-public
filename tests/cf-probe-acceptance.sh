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
WORK_ROOT=$(mktemp -d "${TEMP_BASE}/po0-cf-probe-acceptance.XXXXXXXX")
WORK_ROOT=$(cd -P -- "${WORK_ROOT}" && pwd)
HELPER_LIBRARY=${WORK_ROOT}/po0-cn-entry-helper-library.sh
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP
    case "${WORK_ROOT}" in
        "${TEMP_BASE}"/po0-cf-probe-acceptance.*) rm -rf -- "${WORK_ROOT}" ;;
        *) printf '拒绝清理异常测试目录：%s\n' "${WORK_ROOT}" >&2 ;;
    esac
    exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

fail() {
    printf '    失败：%s\n' "$*" >&2
    return 1
}

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
    ! grep -Fq -- "${needle}" <<<"${haystack}" || fail "${message}（不该出现：${needle}）"
}

make_helper_library() {
    awk '
        index($0, "cat >\"${tmp}\" <<\047EOF\047") { capture=1; next }
        capture && $0 == "case \"${1:-}\" in" { exit }
        capture { print }
    ' "${CN_ENTRY_ROLE}" >"${HELPER_LIBRARY}"
    [[ -s ${HELPER_LIBRARY} ]] || { fail '未能提取 po0-cn-entry helper 函数库'; return 1; }
    /bin/bash -n "${HELPER_LIBRARY}" || { fail 'helper 函数库语法错误'; return 1; }
    # shellcheck disable=SC1090
    source "${HELPER_LIBRARY}"
}

# 产品逻辑要求兼容文件必须由 root 持有。测试夹具位于普通用户临时目录，
# 因此只为被测函数提供等价的属主与硬链接数结果。
stat() {
    if [[ $# -eq 3 && $1 == -c ]]; then
        case "$2" in
            '%u') printf '%s\n' 0; return 0 ;;
            '%h') printf '%s\n' 1; return 0 ;;
            '%a')
                if [[ $(uname -s) == Darwin ]]; then
                    command stat -f '%Lp' "$3"
                else
                    command stat -c '%a' "$3"
                fi
                return
                ;;
        esac
    fi
    command stat "$@"
}

chown() {
    if [[ ${1:-} == root:root ]]; then return 0; fi
    command chown "$@"
}

test_agent_contract_detection() {
    local valid=${WORK_ROOT}/cf-probe.sh invalid=${WORK_ROOT}/cf-probe-invalid.sh
    printf '%s\n' \
        'icmp_out=$(ping -c "$count" -W 2 "$host" 2>/dev/null)' \
        'echo "$avg_rtt $loss"' >"${valid}"
    printf '%s\n' 'echo "null 100"' >"${invalid}"
    CF_PROBE_FIXTURE=${valid}
    cf_probe_script_path() { printf '%s\n' "${CF_PROBE_FIXTURE}"; }
    cf_probe_has_icmp_fallback cf-probe.service \
        || { fail '未识别 Agent 已有的 ICMP 回退能力'; return 1; }
    CF_PROBE_FIXTURE=${invalid}
    ! cf_probe_has_icmp_fallback cf-probe.service \
        || { fail '缺少 ICMP 回退的 Agent 被错误接受'; return 1; }
}

test_go_agent_contract_detection() {
    local v100=${WORK_ROOT}/cf-probe-go-v1.0.0
    local v101=${WORK_ROOT}/cf-probe-go-v1.0.1
    local v102=${WORK_ROOT}/cf-probe-go-v1.0.2
    local v103=${WORK_ROOT}/cf-probe-go-v1.0.3
    local v104=${WORK_ROOT}/cf-probe-go-v1.0.4
    local v105=${WORK_ROOT}/cf-probe-go-v1.0.5
    local v106=${WORK_ROOT}/cf-probe-go-v1.0.6
    local v109=${WORK_ROOT}/cf-probe-go-v1.0.9
    local invalid=${WORK_ROOT}/cf-probe-go-invalid
    local snapshot=${WORK_ROOT}/cf-probe-go-snapshot
    local unknown=${WORK_ROOT}/cf-probe-go-unknown
    printf '%s\n' \
        'github.com/huilang-me/cfsm-agent/cmd/cf-probe' \
        'X-Agent-Config-Md5' \
        'CT_NODE' \
        '3f059d30cc303cba7c9e802f06c7613f621fad0f' >"${v100}"
    printf '%s\n' \
        'github.com/huilang-me/cfsm-agent/cmd/cf-probe' \
        'X-Agent-Config-Md5' \
        'CT_NODE' \
        '9be2cf70fa5a1ff0e15f79d39b3a6b05f82ec7ff' >"${v101}"
    printf '%s\n' \
        'github.com/huilang-me/cfsm-agent/cmd/cf-probe' \
        'X-Agent-Config-Md5' \
        'CT_NODE' \
        '3e45aea8b5d0d7b4dd9871114460d29420a178fe' >"${v102}"
    printf '%s\n' \
        'github.com/huilang-me/cfsm-agent/cmd/cf-probe' \
        'X-Agent-Config-Md5' \
        'CT_NODE' \
        '921edbf104cef96a02c24199c364d4c91b2bfa58' >"${v103}"
    printf '%s\n' \
        'github.com/huilang-me/cfsm-agent/cmd/cf-probe' \
        'X-Agent-Config-Md5' \
        'CT_NODE' \
        '6ec57acffc428ae8b480d71d52d066ac62066d2b' >"${v104}"
    printf '%s\n' \
        'github.com/huilang-me/cfsm-agent/cmd/cf-probe' \
        'X-Agent-Config-Md5' \
        'CT_NODE' \
        '440930f816a7e2b78c33e6d9e208b270a8217c9b' >"${v105}"
    printf '%s\n' \
        'github.com/huilang-me/cfsm-agent/cmd/cf-probe' \
        'X-Agent-Config-Md5' \
        'CT_NODE' \
        '9e92a7876a82d1df923362955feb19c9fc09d02e' >"${v106}"
    printf '%s\n' \
        'github.com/huilang-me/cfsm-agent/cmd/cf-probe' \
        'X-Agent-Config-Md5' \
        'CT_NODE' \
        '69f5e13216a45e06273717a9f072a6c103302187' >"${v109}"
    printf '%s\n' \
        'github.com/huilang-me/cfsm-agent/cmd/cf-probe' \
        'X-Agent-Config-Md5' \
        'CT_NODE' \
        '2d30633f552d343e5d70acb589105b6165a466fa' >"${snapshot}"
    printf '%s\n' \
        'github.com/huilang-me/cfsm-agent/cmd/cf-probe' \
        'X-Agent-Config-Md5' \
        'CT_NODE' \
        'unknown-revision' >"${unknown}"
    printf '%s\n' 'unrelated probe binary' >"${invalid}"
    cf_probe_go_binary_contract "${v100}" \
        || { fail '未识别官方 Go CF Probe v1.0.0 二进制契约'; return 1; }
    cf_probe_go_binary_contract "${v101}" \
        || { fail '未识别官方 Go CF Probe v1.0.1 二进制契约'; return 1; }
    cf_probe_go_binary_contract "${v102}" \
        || { fail '未识别官方 Go CF Probe v1.0.2 二进制契约'; return 1; }
    cf_probe_go_binary_contract "${v103}" \
        || { fail '未识别官方 Go CF Probe v1.0.3 二进制契约'; return 1; }
    cf_probe_go_binary_contract "${v104}" \
        || { fail '未识别官方 Go CF Probe v1.0.4 二进制契约'; return 1; }
    cf_probe_go_binary_contract "${v105}" \
        || { fail '未识别官方 Go CF Probe v1.0.5 二进制契约'; return 1; }
    cf_probe_go_binary_contract "${v106}" \
        || { fail '未识别官方 Go CF Probe v1.0.6 二进制契约'; return 1; }
    cf_probe_go_binary_contract "${v109}" \
        || { fail '未识别官方 Go CF Probe v1.0.9 二进制契约'; return 1; }
    ! cf_probe_go_binary_contract "${snapshot}" \
        || { fail '官方快照版 Go CF Probe 被错误接受'; return 1; }
    ! cf_probe_go_binary_contract "${unknown}" \
        || { fail '未知修订版 Go CF Probe 被错误接受'; return 1; }
    ! cf_probe_go_binary_contract "${invalid}" \
        || { fail '无关二进制被错误识别为官方 Go CF Probe'; return 1; }
}

test_go_agent_rejection_explains_reason() {
    local rc supported=${WORK_ROOT}/cf-probe-go-supported
    local unknown=${WORK_ROOT}/cf-probe-go-unknown-reason output
    printf '%s\n' \
        'github.com/huilang-me/cfsm-agent/cmd/cf-probe' \
        'X-Agent-Config-Md5' \
        'CT_NODE' \
        '3e45aea8b5d0d7b4dd9871114460d29420a178fe' >"${supported}"
    printf '%s\n' \
        'github.com/huilang-me/cfsm-agent/cmd/cf-probe' \
        'X-Agent-Config-Md5' \
        'CT_NODE' \
        'unknown-revision' >"${unknown}"
    cf_probe_go_config_path() { return 1; }
    cf_probe_go_executable_path() { printf '%s\n' "${CF_PROBE_GO_EXE_FIXTURE}"; }

    CF_PROBE_GO_EXE_FIXTURE=${unknown}
    rc=0
    output=$(prepare_cf_probe_latency_compat cf-probe.service "${WORK_ROOT}/unknown.d" 2>&1) || rc=$?
    # 未知修订不再整次拒绝：返回 3 表示只跳过测速目标处理，国外出口照配。
    # cf-probe 默认开启自动更新，上游一发新版就会走到这里。
    assert_eq 3 "${rc}" '未知 Go Agent 修订版没有返回可跳过的状态' || return 1
    assert_contains "${output}" '不在 Po0 已审查的正式版本清单中' \
        '未知 Go Agent 没有显示准确原因' || return 1
    assert_contains "${output}" '只配置国外出口' \
        '没有说明这次仍然会配置国外出口' || return 1
    assert_contains "${output}" '检查并更新配置' \
        '没有告诉用户版本进入清单后该怎么补上' || return 1

    CF_PROBE_GO_EXE_FIXTURE=${supported}
    rc=0
    output=$(prepare_cf_probe_latency_compat cf-probe.service "${WORK_ROOT}/unsafe.d" 2>&1) || rc=$?
    # 版本受支持却过不了安全校验，可能意味着被改动过，必须仍然整次拒绝而不是跳过。
    assert_eq 1 "${rc}" '受支持版本的安全校验失败被降级成了可跳过' || return 1
    assert_contains "${output}" '运行参数或配置文件未通过安全校验' \
        '受支持 Go Agent 的配置安全失败原因不准确' || return 1
}

test_jinhua_fallback_targets() {
    local target
    assert_eq '61.153.34.8:53' "${CF_PROBE_FALLBACK_CT}" \
        '第一备用测速目标不是金华公开权威 DNS' || return 1
    assert_eq '210.33.80.8:53' "${CF_PROBE_FALLBACK_CU}" \
        '第二备用测速目标不是金华公开权威 DNS' || return 1
    assert_eq '210.32.68.3:53' "${CF_PROBE_FALLBACK_CM}" \
        '第三备用测速目标不是金华公开权威 DNS' || return 1
    assert_eq '121.192.44.254:53' "${CF_PROBE_FALLBACK_BD}" \
        '第四备用测速目标不是金华公开权威 DNS' || return 1
    for target in \
        "${CF_PROBE_FALLBACK_CT}" \
        "${CF_PROBE_FALLBACK_CU}" \
        "${CF_PROBE_FALLBACK_CM}" \
        "${CF_PROBE_FALLBACK_BD}"; do
        cf_probe_target_uses_allowed_port "${target}" \
            || { fail "备用测速目标没有使用安全端口：${target}"; return 1; }
    done
}

test_go_agent_native_targets_and_rollback() {
    local dropin=${WORK_ROOT}/cf-probe-go.service.d config=${WORK_ROOT}/config.conf
    local directory output before_secret
    install -d -m 0755 "${dropin}"
    cat >"${config}" <<'CONFIG'
SERVER_ID="fixture-server"
SECRET="fixture-secret-never-real"
WORKER_URL="https://worker.invalid/update"
COLLECT_INTERVAL="1"
REPORT_INTERVAL="30"
CT_NODE="ct-default.invalid"
CU_NODE="cu-default.invalid:80"
CM_NODE="cm-default.invalid:8443"
BD_NODE="bd-custom.invalid:53"
INTERFACE=""
RESET_DAY="1"
AUTO_UPDATE="0"
UPDATE_PROXY=""
CONFIG_MD5="00000000000000000000000000000000"
CONFIG
    chmod 0600 "${config}"
    before_secret=$(grep '^SECRET=' "${config}")
    CF_PROBE_FALLBACK_CT=ct-safe.invalid:53
    CF_PROBE_FALLBACK_CU=cu-safe.invalid:53
    CF_PROBE_FALLBACK_CM=cm-safe.invalid:53
    CF_PROBE_FALLBACK_BD=bd-safe.invalid:53
    CF_PROBE_CONFIG_FIXTURE=${config}
    cf_probe_go_config_path() { printf '%s\n' "${CF_PROBE_CONFIG_FIXTURE}"; }
    cf_probe_target_connectable() { return 0; }
    cf_probe_has_icmp_fallback() { return 1; }

    directory=$(prepare_cf_probe_latency_compat cf-probe.service "${dropin}") \
        || { fail 'Go Agent 原生测速目标兼容准备失败'; return 1; }
    assert_eq "${dropin}/po0-cf-probe-icmp-bin" "${directory}" 'Go Agent 兼容目录位置变化' || return 1
    grep -qx 'CT_NODE="ct-safe.invalid:53"' "${config}" \
        || { fail '缺少端口的 CT 目标没有改用安全端口'; return 1; }
    grep -qx 'CU_NODE="cu-safe.invalid:53"' "${config}" \
        || { fail '命中 80 的 CU 目标没有改用安全端口'; return 1; }
    grep -qx 'CM_NODE="cm-safe.invalid:53"' "${config}" \
        || { fail '命中 8443 的 CM 目标没有改用安全端口'; return 1; }
    grep -qx 'BD_NODE="bd-custom.invalid:53"' "${config}" \
        || { fail '用户已有的安全 BD 目标被错误覆盖'; return 1; }
    assert_eq "${before_secret}" "$(grep '^SECRET=' "${config}")" '敏感配置被测速兼容改写' || return 1
    [[ -f ${directory}/go-record && -f ${directory}/go-pending ]] \
        || { fail 'Go Agent 兼容没有留下可回滚事务记录'; return 1; }
    managed_cf_probe_compat_owned "${directory}" \
        || { fail 'Go Agent 兼容目录未被安全所有权检查接受'; return 1; }
    commit_cf_probe_go_latency_compat "${directory}" \
        || { fail 'Go Agent 兼容事务无法提交'; return 1; }
    [[ ! -e ${directory}/go-pending && ! -e ${directory}/go-record.previous ]] \
        || { fail 'Go Agent 兼容提交后仍有事务残留'; return 1; }
    restore_cf_probe_go_original_targets "${directory}" \
        || { fail 'Go Agent 停用前无法暂存恢复原测速目标'; return 1; }
    grep -qx 'CT_NODE="ct-default.invalid"' "${config}" \
        || { fail '停用事务没有在重启前恢复原测速目标'; return 1; }
    restore_cf_probe_go_managed_targets "${directory}" \
        || { fail 'Go Agent 停用失败后无法恢复安全测速目标'; return 1; }
    grep -qx 'CT_NODE="ct-safe.invalid:53"' "${config}" \
        || { fail '停用回滚没有重新应用安全测速目标'; return 1; }

    sed 's/^CT_NODE=.*/CT_NODE="panel-reset.invalid:80"/' "${config}" >"${config}.tmp"
    mv "${config}.tmp" "${config}"
    chmod 0600 "${config}"
    output=$(prepare_cf_probe_latency_compat cf-probe.service "${dropin}") \
        || { fail 'Go Agent 面板覆盖后无法重新准备兼容'; return 1; }
    assert_eq "${directory}" "${output}" 'Go Agent 重复准备改变了兼容目录' || return 1
    grep -qx 'CT_NODE="ct-safe.invalid:53"' "${config}" \
        || { fail '面板恢复封禁端口后 Po0 没有重新应用安全目标'; return 1; }
    rollback_cf_probe_go_latency_compat "${directory}" \
        || { fail 'Go Agent 服务失败时无法回滚本轮目标变化'; return 1; }
    grep -qx 'CT_NODE="panel-reset.invalid:80"' "${config}" \
        || { fail 'Go Agent 回滚没有恢复本轮修改前目标'; return 1; }

    output=$(prepare_cf_probe_latency_compat cf-probe.service "${dropin}") \
        || { fail 'Go Agent 回滚后无法再次准备兼容'; return 1; }
    commit_cf_probe_go_latency_compat "${directory}" || return 1
    remove_cf_probe_latency_compat "${directory}" \
        || { fail '停用代理时无法恢复 Go Agent 原测速目标'; return 1; }
    grep -qx 'CT_NODE="ct-default.invalid"' "${config}" \
        || { fail '停用后没有恢复原 CT 目标'; return 1; }
    grep -qx 'CU_NODE="cu-default.invalid:80"' "${config}" \
        || { fail '停用后没有恢复原 CU 目标'; return 1; }
    grep -qx 'CM_NODE="cm-default.invalid:8443"' "${config}" \
        || { fail '停用后没有恢复原 CM 目标'; return 1; }
    grep -qx 'BD_NODE="bd-custom.invalid:53"' "${config}" \
        || { fail '停用后没有恢复原 BD 目标'; return 1; }
    [[ ! -e ${directory} ]] || { fail '停用后 Go Agent 兼容目录仍残留'; return 1; }
}

test_go_agent_fallback_failure_keeps_config() {
    local dropin=${WORK_ROOT}/cf-probe-go-fail.service.d config=${WORK_ROOT}/config-fail.conf
    local before
    install -d -m 0755 "${dropin}"
    cat >"${config}" <<'CONFIG'
SERVER_ID="fixture-server"
SECRET="fixture-secret-never-real"
WORKER_URL="https://worker.invalid/update"
CT_NODE="blocked.invalid:80"
CU_NODE="safe.invalid:53"
CM_NODE="safe.invalid:53"
BD_NODE="safe.invalid:53"
CONFIG_MD5="00000000000000000000000000000000"
CONFIG
    chmod 0600 "${config}"
    before=$(sha256sum "${config}" | awk '{print $1}')
    CF_PROBE_FALLBACK_CT=unreachable.invalid:53
    CF_PROBE_CONFIG_FIXTURE=${config}
    cf_probe_go_config_path() { printf '%s\n' "${CF_PROBE_CONFIG_FIXTURE}"; }
    cf_probe_target_connectable() { return 1; }
    cf_probe_has_icmp_fallback() { return 1; }
    ! prepare_cf_probe_latency_compat cf-probe.service "${dropin}" >/dev/null 2>&1 \
        || { fail '安全备用节点不可达时仍修改了 Go Agent'; return 1; }
    assert_eq "${before}" "$(sha256sum "${config}" | awk '{print $1}')" \
        '备用节点失败后 Go Agent 配置发生变化' || return 1
    [[ ! -e ${dropin}/po0-cf-probe-icmp-bin ]] \
        || { fail '备用节点失败后留下了不完整兼容目录'; return 1; }
}

test_go_agent_stale_first_transaction_recovery() {
    local dropin=${WORK_ROOT}/cf-probe-go-stale.service.d config=${WORK_ROOT}/config-stale.conf
    local directory output
    install -d -m 0755 "${dropin}"
    cat >"${config}" <<'CONFIG'
SERVER_ID="fixture-server"
SECRET="fixture-secret-never-real"
WORKER_URL="https://worker.invalid/update"
CT_NODE="ct-original.invalid"
CU_NODE="cu-original.invalid:80"
CM_NODE="cm-original.invalid:8443"
BD_NODE="bd-original.invalid:53"
CONFIG_MD5="00000000000000000000000000000000"
CONFIG
    chmod 0600 "${config}"
    CF_PROBE_FALLBACK_CT=ct-safe-stale.invalid:53
    CF_PROBE_FALLBACK_CU=cu-safe-stale.invalid:53
    CF_PROBE_FALLBACK_CM=cm-safe-stale.invalid:53
    CF_PROBE_FALLBACK_BD=bd-safe-stale.invalid:53
    CF_PROBE_CONFIG_FIXTURE=${config}
    cf_probe_go_config_path() { printf '%s\n' "${CF_PROBE_CONFIG_FIXTURE}"; }
    cf_probe_target_connectable() { return 0; }
    directory=${dropin}/po0-cf-probe-icmp-bin
    install -d -m 0755 "${directory}"
    cf_probe_write_go_pending "${directory}/go-pending" "${config}" no \
        ct-original.invalid cu-original.invalid:80 cm-original.invalid:8443 bd-original.invalid:53 \
        || { fail '无法创建首次事务中断夹具'; return 1; }
    cf_probe_write_go_targets "${config}" \
        ct-safe-stale.invalid:53 cu-safe-stale.invalid:53 \
        cm-safe-stale.invalid:53 bd-original.invalid:53 \
        || { fail '无法模拟首次事务中断后的配置'; return 1; }

    output=$(prepare_cf_probe_latency_compat cf-probe.service "${dropin}") \
        || { fail '首次事务中断后无法自动恢复并重试'; return 1; }
    assert_eq "${directory}" "${output}" '首次事务恢复后兼容目录变化' || return 1
    commit_cf_probe_go_latency_compat "${directory}" || return 1
    remove_cf_probe_latency_compat "${directory}" || return 1
    grep -qx 'CT_NODE="ct-original.invalid"' "${config}" \
        || { fail '首次事务恢复后丢失原 CT 目标'; return 1; }
    grep -qx 'CU_NODE="cu-original.invalid:80"' "${config}" \
        || { fail '首次事务恢复后丢失原 CU 目标'; return 1; }
}

test_go_agent_dynamic_config_guard() {
    local dropin=${WORK_ROOT}/cf-probe-go-guard.service.d config=${WORK_ROOT}/config-guard.conf
    local directory output restart_count=0 systemd_root=${WORK_ROOT}/systemd
    local service_file path_file
    install -d -m 0755 "${dropin}" "${systemd_root}"
    cat >"${config}" <<'CONFIG'
SERVER_ID="fixture-server"
SECRET="fixture-secret-never-real"
WORKER_URL="https://worker.invalid/update"
COLLECT_INTERVAL="1"
REPORT_INTERVAL="30"
CT_NODE="ct-default.invalid:80"
CU_NODE="cu-default.invalid:80"
CM_NODE="cm-default.invalid:8443"
BD_NODE="bd-default.invalid:443"
INTERFACE=""
RESET_DAY="1"
AUTO_UPDATE="0"
UPDATE_PROXY=""
CONFIG_MD5="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
CONFIG
    chmod 0600 "${config}"
    CF_PROBE_FALLBACK_CT=ct-safe-guard.invalid:53
    CF_PROBE_FALLBACK_CU=cu-safe-guard.invalid:53
    CF_PROBE_FALLBACK_CM=cm-safe-guard.invalid:53
    CF_PROBE_FALLBACK_BD=bd-safe-guard.invalid:53
    CF_PROBE_CONFIG_FIXTURE=${config}
    CF_PROBE_SYSTEMD_ROOT_FIXTURE=${systemd_root}
    cf_probe_go_systemd_root() { printf '%s\n' "${CF_PROBE_SYSTEMD_ROOT_FIXTURE}"; }
    cf_probe_go_config_path() { printf '%s\n' "${CF_PROBE_CONFIG_FIXTURE}"; }
    cf_probe_target_connectable() { return 0; }
    restart_and_verify_running() { restart_count=$((restart_count + 1)); return 0; }
    systemctl() { printf '%s\n' "$*" >>"${WORK_ROOT}/guard-systemctl.log"; }

    directory=$(prepare_cf_probe_latency_compat cf-probe.service "${dropin}") \
        || { fail '无法准备动态配置守卫夹具'; return 1; }
    commit_cf_probe_go_latency_compat "${directory}" || return 1

    # 模拟面板在 Agent 启动后下发新 MD5，并把测速目标恢复为封禁端口。
    cf_probe_write_go_targets "${config}" \
        panel-ct.invalid:80 panel-cu.invalid:80 panel-cm.invalid:8443 panel-bd.invalid:443 \
        || { fail '无法模拟面板动态配置覆盖'; return 1; }
    sed 's/^CONFIG_MD5=.*/CONFIG_MD5="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"/' \
        "${config}" >"${config}.tmp"
    mv "${config}.tmp" "${config}"
    chmod 0600 "${config}"

    reconcile_cf_probe_go_latency_compat cf-probe.service "${directory}" \
        || { fail '动态配置覆盖后没有自动恢复 Po0 测速目标'; return 1; }
    assert_eq 1 "${restart_count}" '恢复动态配置后没有且仅有一次重启 Agent' || return 1
    grep -qx 'CT_NODE="ct-safe-guard.invalid:53"' "${config}" \
        || { fail '动态配置守卫没有恢复 CT 测速目标'; return 1; }
    grep -qx 'BD_NODE="bd-safe-guard.invalid:53"' "${config}" \
        || { fail '动态配置守卫没有恢复 BD 测速目标'; return 1; }
    grep -qx 'CONFIG_MD5="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "${config}" \
        || { fail '动态配置守卫错误回退了面板的新配置版本'; return 1; }
    grep -qx 'SECRET="fixture-secret-never-real"' "${config}" \
        || { fail '动态配置守卫改动了 Agent 密钥'; return 1; }

    reconcile_cf_probe_go_latency_compat cf-probe.service "${directory}" || return 1
    assert_eq 1 "${restart_count}" '测速目标已正确时动态守卫仍重复重启 Agent' || return 1

    output=$(prepare_cf_probe_go_guard_units cf-probe.service "${directory}") \
        || { fail '无法安装 CF Probe 动态配置守卫单元'; return 1; }
    assert_eq yes "${output}" '首次安装动态配置守卫没有报告新增文件' || return 1
    service_file=$(cf_probe_go_guard_service_file cf-probe.service)
    path_file=$(cf_probe_go_guard_path_file cf-probe.service)
    [[ -f ${service_file} && -f ${path_file} ]] \
        || { fail '动态配置守卫缺少 service 或 path 单元'; return 1; }
    grep -Fqx 'ExecStart=/usr/local/bin/po0-cn-entry reconcile-cf-probe cf-probe.service' \
        "${service_file}" || { fail '动态配置守卫没有调用受管 Helper'; return 1; }
    grep -Fqx "PathChanged=${config}" "${path_file}" \
        || { fail '动态配置守卫没有监视实际配置文件'; return 1; }
    grep -Fqx "Unit=$(basename "${service_file}")" "${path_file}" \
        || { fail '动态配置路径单元没有绑定对应守卫服务'; return 1; }
    output=$(prepare_cf_probe_go_guard_units cf-probe.service "${directory}") || return 1
    assert_eq no "${output}" '重复安装动态配置守卫不具备幂等性' || return 1
    remove_cf_probe_go_guard_units cf-probe.service "${directory}" \
        || { fail '无法安全移除动态配置守卫单元'; return 1; }
    [[ ! -e ${service_file} && ! -e ${path_file} ]] \
        || { fail '停用后仍残留动态配置守卫单元'; return 1; }
}

test_wrapper_lifecycle_and_scope() {
    local dropin=${WORK_ROOT}/cf-probe.service.d directory output resolved fake_curl curl_log
    local fake_bin=${WORK_ROOT}/fake-bin fake_ping ping_log ping_output
    install -d -m 0755 "${dropin}" "${fake_bin}"
    fake_ping=${fake_bin}/ping
    ping_log=${WORK_ROOT}/ping.log
    cat >"${fake_ping}" <<'FAKE_PING'
#!/bin/sh
printf '%s\n' "$*" >>"${FAKE_PING_LOG}"
printf '%s\n' \
    'PING fixture.example (192.0.2.1): 56 data bytes' \
    '64 bytes from 192.0.2.1: icmp_seq=0 ttl=64 time=12.345 ms' \
    '--- fixture.example ping statistics ---' \
    '1 packets transmitted, 1 packets received, 0.0% packet loss' \
    'round-trip min/avg/max/stddev = 12.345/12.345/12.345/0.000 ms'
FAKE_PING
    chmod 0755 "${fake_ping}"
    PATH="${fake_bin}:/usr/bin:/bin"
    resolved=$(command -v ping)
    assert_eq "${fake_ping}" "${resolved}" '测试没有使用自带的 ping 夹具' || return 1
    ping_output=$(FAKE_PING_LOG="${ping_log}" ping -c 1 -W 2 fixture.example)
    assert_contains "${ping_output}" '12.345/12.345/12.345' \
        '自带 ping 夹具没有返回确定性延迟结果' || return 1
    assert_contains "$(<"${ping_log}")" '-c 1 -W 2 fixture.example' \
        '自带 ping 夹具没有收到 Agent 回退参数' || return 1

    cf_probe_has_icmp_fallback() { return 0; }
    directory=$(prepare_cf_probe_latency_compat cf-probe.service "${dropin}") \
        || { fail '无法创建 cf-probe 延迟兼容文件'; return 1; }
    assert_eq "${dropin}/po0-cf-probe-icmp-bin" "${directory}" '兼容目录不在目标服务范围内' || return 1
    managed_cf_probe_compat_owned "${directory}" || { fail '新建兼容文件未被识别为助手所有'; return 1; }
    [[ -x ${directory}/nc ]] || { fail '兼容 nc 不可执行'; return 1; }
    [[ -x ${directory}/curl ]] || { fail '直连上报 curl 不可执行'; return 1; }

    output=$(prepare_cf_probe_latency_compat cf-probe.service "${dropin}") \
        || { fail '重复准备兼容文件不具备幂等性'; return 1; }
    assert_eq "${directory}" "${output}" '重复准备改变了兼容目录' || return 1

    remove_cf_probe_direct_report_compat "${directory}" \
        || { fail '无法单独撤销新增的直连上报兼容文件'; return 1; }
    [[ -x ${directory}/nc && ! -e ${directory}/curl ]] \
        || { fail '单独撤销直连上报时破坏了原延迟兼容文件'; return 1; }
    managed_cf_probe_compat_owned "${directory}" \
        || { fail '旧版仅含 nc 的兼容目录不再受安全管理'; return 1; }
    output=$(prepare_cf_probe_latency_compat cf-probe.service "${dropin}") \
        || { fail '无法为旧版兼容目录增量加入直连上报'; return 1; }
    [[ -x ${directory}/curl ]] || { fail '旧版兼容目录没有完成增量迁移'; return 1; }

    resolved=$(PATH="${directory}:${PATH}" command -v nc)
    assert_eq "${directory}/nc" "${resolved}" '服务专用 PATH 没有优先命中兼容 nc' || return 1
    ! PATH="${directory}:${PATH}" nc -h >/dev/null 2>&1 \
        || { fail '兼容 nc 没有触发 Agent 的 ping 回退条件'; return 1; }

    fake_curl=${WORK_ROOT}/fake-curl
    curl_log=${WORK_ROOT}/curl.log
    cat >"${fake_curl}" <<'FAKE_CURL'
#!/bin/bash
printf 'proxy=%s args=%s\n' "${HTTPS_PROXY-unset}" "$*" >>"${FAKE_CURL_LOG}"
if [[ " $* " == *':8443'* ]]; then
    [[ ${FAKE_CURL_MODE:-success} == success ]] || exit 28
    printf '%s' 204
    exit 0
fi
printf '%s' 204
FAKE_CURL
    chmod 0755 "${fake_curl}"

    : >"${curl_log}"
    output=$(FAKE_CURL_LOG="${curl_log}" FAKE_CURL_MODE=success \
        PO0_CF_PROBE_REAL_CURL="${fake_curl}" HTTPS_PROXY=http://127.0.0.1:13128 \
        "${directory}/curl" -sS -w '%{http_code}' -X POST \
        -H 'X-Agent-Version: 1.3.2' -d '{}' https://monitor.example/update)
    assert_eq 204 "${output}" '直连成功时没有原样返回面板状态码' || return 1
    assert_eq 1 "$(wc -l <"${curl_log}" | tr -d ' ')" '直连成功后仍重复经过代理上报' || return 1
    assert_contains "$(<"${curl_log}")" 'proxy=unset' '直连上报没有清除服务代理环境' || return 1
    assert_contains "$(<"${curl_log}")" 'https://monitor.example:8443/update' '直连上报没有改用备用 HTTPS 端口' || return 1

    : >"${curl_log}"
    output=$(FAKE_CURL_LOG="${curl_log}" FAKE_CURL_MODE=fail \
        PO0_CF_PROBE_REAL_CURL="${fake_curl}" HTTPS_PROXY=http://127.0.0.1:13128 \
        "${directory}/curl" -sS -w '%{http_code}' -X POST \
        -H 'X-Agent-Version: 1.3.2' -d '{}' https://monitor.example/update)
    assert_eq 204 "${output}" '直连失败后没有返回代理重试结果' || return 1
    assert_eq 2 "$(wc -l <"${curl_log}" | tr -d ' ')" '直连失败后没有且仅有一次代理重试' || return 1
    assert_contains "$(tail -1 "${curl_log}")" 'proxy=http://127.0.0.1:13128' '代理重试没有保留原服务代理环境' || return 1

    : >"${curl_log}"
    output=$(FAKE_CURL_LOG="${curl_log}" FAKE_CURL_MODE=success \
        PO0_CF_PROBE_REAL_CURL="${fake_curl}" HTTPS_PROXY=http://127.0.0.1:13128 \
        "${directory}/curl" -sS -w '%{http_code}' https://example.com/status)
    assert_eq 204 "${output}" '普通 curl 请求结果被兼容层改变' || return 1
    assert_eq 1 "$(wc -l <"${curl_log}" | tr -d ' ')" '普通 curl 请求被重复执行' || return 1
    assert_contains "$(<"${curl_log}")" 'proxy=http://127.0.0.1:13128' '普通 curl 请求错误绕过了代理' || return 1

    printf '%s\n' 'external change' >"${directory}/unexpected"
    ! managed_cf_probe_compat_owned "${directory}" \
        || { fail '带外部文件的兼容目录仍被判定为可安全删除'; return 1; }
    ! remove_cf_probe_latency_compat "${directory}" \
        || { fail '外部修改后的兼容目录被自动删除'; return 1; }
    rm -f "${directory}/unexpected"
    remove_cf_probe_latency_compat "${directory}" || { fail '无法清理助手自己的兼容目录'; return 1; }
    [[ ! -e ${directory} ]] || { fail '停用后兼容目录仍残留'; return 1; }
}

# cf-probe 的测速目标改写发生在 drop-in 落盘之前（TX_DROPIN_MAY_EXIST 置位更晚）。
# 补偿动作若嵌在该标志的判断里，窗口内失败就会整块跳过：目标已被改写却未进托管清单，
# go-pending 与兼容目录残留，健康检查看不到，停用也会以「不在托管清单」拒绝清理。
# 归属校验此前只查属主和硬链接数，不查权限位：包装脚本被放宽成人人可写后
# 仍会被判为「属于本助手」，而它们会被注入服务 PATH 的最前面。
# reconcile-cf-probe 由 .path 单元触发。拿不到锁时若静默 exit 0，面板推送的新配置
# 版本号已被接受、.path 不会再触发，安全测速目标可能长期不恢复。必须有界等待并明确失败。
test_reconcile_cf_probe_waits_for_lock() (
    local case_dir branch flock_log rc out
    case_dir=$(mktemp -d "${TMPDIR:-/tmp}/po0-reconcile-lock.XXXXXXXX")
    trap 'rm -rf -- "${case_dir}"' EXIT
    flock_log=${case_dir}/flock.log
    mkdir -p -- "${case_dir}/state"
    : >"${flock_log}"

    branch=$(sed -n '/^    reconcile-cf-probe)/,/^        ;;/p' "${CN_ENTRY_ROLE}")
    [[ -n ${branch} ]] || { fail '未能提取 reconcile-cf-probe 分支'; return 1; }
    branch=${branch#*reconcile-cf-probe)}
    branch=${branch%;;}
    eval "run_reconcile() { set -- reconcile-cf-probe \"\$1\"; ${branch} }"

    CN_ENTRY_LOCK_WAIT_SECONDS=30
    usage() { :; }
    valid_helper_service_unit() { return 0; }
    helper_active_state() { printf '%s\n' "${case_dir}/state"; }
    confirm_helper_state_open() { :; }
    managed_dropin_owned() { :; }
    # 记录真实调用参数，并模拟等待超时。
    flock() { printf '%s\n' "$*" >>"${flock_log}"; return 1; }
    command() {
        if [[ ${1:-} == -v ]]; then return 0; fi
        builtin command "$@"
    }

    rc=0
    out=$( (run_reconcile cf-probe.service) 2>&1 ) || rc=$?
    [[ ${rc} -ne 0 ]] \
        || { fail '拿不到服务配置锁时守卫静默当成功退出'; return 1; }
    assert_contains "${out}" '等待服务配置锁超时' '锁等待超时没有给出明确原因' || return 1
    assert_contains "$(<"${flock_log}")" '-w 30' \
        '守卫没有使用有界等待（应为 -w ${CN_ENTRY_LOCK_WAIT_SECONDS}）' || return 1
    ! grep -Fq -- '-n' "${flock_log}" \
        || { fail '守卫仍在使用非阻塞锁'; return 1; }
)

test_cf_probe_compat_ownership_checks_mode() (
    local case_dir compat nc_content rc
    case_dir=$(mktemp -d "${TMPDIR:-/tmp}/po0-compat-mode.XXXXXXXX")
    trap 'rm -rf -- "${case_dir}"' EXIT
    compat=${case_dir}/po0-cf-probe-compat
    mkdir -p -- "${compat}"
    chmod 0755 "${compat}"
    nc_content=$(printf '%s\n' '#!/bin/sh' \
        '# Managed by Po0: force cf-probe to use its built-in ICMP fallback.' \
        'exit 1')
    printf '%s\n' "${nc_content}" >"${compat}/nc"
    chmod 0755 "${compat}/nc"

    eval "$(sed -n '/^cf_probe_compat_mode_safe() {/,/^}/p' "${CN_ENTRY_ROLE}")"
    eval "$(sed -n '/^managed_cf_probe_compat_owned() {/,/^}/p' "${CN_ENTRY_ROLE}")"
    eval "$(sed -n '/^managed_cf_probe_go_record() {/,/^}/p' "${CN_ENTRY_ROLE}")"
    eval "$(sed -n '/^managed_cf_probe_go_pending() {/,/^}/p' "${CN_ENTRY_ROLE}")"

    managed_cf_probe_compat_owned "${compat}" \
        || { fail '正常权限的兼容目录被判为不属于本助手'; return 1; }

    chmod 0757 "${compat}/nc"
    rc=0
    managed_cf_probe_compat_owned "${compat}" || rc=$?
    [[ ${rc} -ne 0 ]] || { fail '人人可写的 nc 包装仍被判为属于本助手'; return 1; }
    chmod 0755 "${compat}/nc"

    chmod 0777 "${compat}"
    rc=0
    managed_cf_probe_compat_owned "${compat}" || rc=$?
    [[ ${rc} -ne 0 ]] || { fail '人人可写的兼容目录仍被判为属于本助手'; return 1; }
    chmod 0755 "${compat}"

    # 旧部署可能是 0750 之类的更严格权限，不能被误判为异常。
    chmod 0750 "${compat}"
    chmod 0750 "${compat}/nc"
    managed_cf_probe_compat_owned "${compat}" \
        || { fail '更严格权限的旧兼容目录被误判为不属于本助手'; return 1; }
)

test_enable_rollback_compensates_before_dropin_flag() (
    local case_dir compat_dir log rc
    case_dir=$(mktemp -d "${TMPDIR:-/tmp}/po0-enable-rollback.XXXXXXXX")
    trap 'rm -rf -- "${case_dir}"' EXIT
    compat_dir=${case_dir}/po0-cf-probe-compat
    log=${case_dir}/compensation.log
    mkdir -p -- "${compat_dir}"
    : >"${compat_dir}/go-pending"
    : >"${log}"

    eval "$(sed -n '/^enable_transaction_cleanup() {/,/^}/p' "${CN_ENTRY_ROLE}")"
    rollback_cf_probe_go_latency_compat() { printf 'ROLLBACK_TARGETS\n' >>"${log}"; }
    remove_cf_probe_latency_compat() { printf 'REMOVE_COMPAT\n' >>"${log}"; }
    remove_cf_probe_direct_report_compat() { printf 'REMOVE_CURL_COMPAT\n' >>"${log}"; }
    remove_cf_probe_go_guard_units() { :; }
    remove_komari_identity_guard() { :; }
    remove_managed_unit() { :; }
    restart_and_verify_running() { :; }
    systemctl() { :; }

    # 失败发生在 TX_DROPIN_MAY_EXIST 置位之前：这是本用例要守住的窗口。
    TX_COMMITTED=no
    TX_UNIT=demo-agent.service
    TX_STATE=${case_dir}/state
    TX_DROPIN_DIR=${case_dir}/dropin
    TX_DROPIN_FILE=${TX_DROPIN_DIR}/90-po0-unlock-proxy.conf
    TX_DROPIN_MAY_EXIST=no
    TX_COMPAT_DIR=${compat_dir}
    TX_COMPAT_CREATED=yes
    TX_COMPAT_CURL_CREATED=no
    TX_CF_GUARD_CREATED=no
    TX_KOMARI_IDENTITY_CREATED=no
    TX_ORIGINAL_RUNNING=no
    TX_LIST_MAY_CHANGE=no
    rc=0
    ( enable_transaction_cleanup 1 ) >/dev/null 2>&1 || rc=$?

    grep -Fxq ROLLBACK_TARGETS "${log}" \
        || { fail 'drop-in 落盘前失败没有恢复 cf-probe 本轮测速目标'; return 1; }
    grep -Fxq REMOVE_COMPAT "${log}" \
        || { fail 'drop-in 落盘前失败没有清理本次创建的 cf-probe 兼容文件'; return 1; }

    # 事务已提交时不得执行任何补偿。
    : >"${log}"
    TX_COMMITTED=yes
    ( enable_transaction_cleanup 0 ) >/dev/null 2>&1 || true
    [[ ! -s ${log} ]] || { fail '事务已提交仍执行了回滚补偿'; return 1; }
)

test_source_lifecycle_contracts() {
    local source helper_case disable_body scan_body configured_body
    source=$(sed -n '1,$p' "${CN_ENTRY_ROLE}")
    helper_case=$(sed -n '/^case "${1:-}" in/,/^esac$/p' "${CN_ENTRY_ROLE}")
    disable_body=$(sed -n '/^    disable-service)/,/^        ;;/p' "${CN_ENTRY_ROLE}")
    scan_body=$(sed -n '/^scan_services() {/,/^}/p' "${CN_ENTRY_ROLE}")
    configured_body=$(sed -n '/^manage_configured_service() {/,/^}/p' "${CN_ENTRY_ROLE}")
    assert_contains "${source}" "识别为 CF Probe 监控 Agent" '服务扫描没有明确识别 CF Probe' \
        || return 1
    assert_eq 2 "$(grep -Fc 'compat_dir=$(prepare_cf_probe_latency_compat "${unit}" "${dropin}")' <<<"${helper_case}")" \
        '启用与刷新没有同时准备延迟兼容层' || return 1
    assert_contains "${source}" 'TX_COMPAT_CREATED=${compat_created}' '事务未记录新建兼容目录' \
        || return 1
    assert_contains "${source}" 'remove_cf_probe_latency_compat "${TX_COMPAT_DIR}"' '失败回滚不会清理新建兼容目录' \
        || return 1
    assert_contains "${source}" 'TX_COMPAT_CURL_CREATED=${compat_curl_created}' '事务未记录增量新增的直连上报文件' \
        || return 1
    assert_contains "${source}" 'remove_cf_probe_direct_report_compat "${TX_COMPAT_DIR}"' '失败回滚不会撤销增量直连上报文件' \
        || return 1
    assert_contains "${helper_case}" 'remove_cf_probe_latency_compat "${compat_dir}"' '停用服务不会清理兼容目录' \
        || return 1
    assert_contains "${scan_body}" 'manage_configured_service "${unit}" "${reasons[index]}" "${state}"' \
        '已托管 CF Probe 没有进入配置管理菜单' || return 1
    assert_contains "${configured_body}" 'REFRESH_CF_PROBE_LATENCY' '已托管 CF Probe 无法通过扫描补齐修复' \
        || return 1
    assert_contains "${source}" '__refresh-managed-service) refresh_one_managed_service "${2:-}"' \
        '缺少定向迁移已托管服务的内部入口' || return 1
    assert_contains "${helper_case}" 'Environment="PATH=%s:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' \
        '服务配置没有限定兼容 PATH' || return 1
    assert_contains "${source}" 'rollback_cf_probe_go_latency_compat "${TX_COMPAT_DIR}"' \
        '服务失败回滚没有恢复 Go Agent 本轮测速目标' || return 1
    assert_contains "${source}" 'restore_cf_probe_go_managed_targets "${TX_COMPAT_DIR}"' \
        '停用失败回滚没有重新应用 Go Agent 安全测速目标' || return 1
    assert_contains "${helper_case}" 'commit_cf_probe_go_latency_compat "${compat_dir}"' \
        '服务成功后没有提交 Go Agent 测速兼容事务' || return 1
    assert_eq 3 "$(grep -Fc 'reconcile_cf_probe_go_latency_compat "${unit}" "${compat_dir}"' <<<"${helper_case}")" \
        '启用、刷新与持久守卫没有共同收敛面板动态配置' || return 1
    assert_eq 2 "$(grep -Fc 'prepare_cf_probe_go_guard_units "${unit}" "${compat_dir}"' <<<"${helper_case}")" \
        '启用与刷新没有安装持久动态配置守卫' || return 1
    # 转发模式：启用与刷新都必须写挂载行，否则刷新会把它抹掉、实时通道静默失效
    assert_eq 2 "$(grep -Fc 'cf_probe_forward_dropin_line "${dropin}" >>"${tmp}"' <<<"${helper_case}")" \
        '启用与刷新没有同时写入转发模式的挂载行' || return 1
    assert_contains "${helper_case}" 'prepare_cf_probe_forward_mode "${unit}" "${dropin}"' \
        '启用路径没有接入转发模式' || return 1
    # 刷新是既有部署拿到新版转发单元的唯一入口，断了这条线老部署永远不会开机自启
    assert_contains "${helper_case}" 'reconcile_cf_probe_forward_unit "${unit}" "${dropin}"' \
        '刷新路径没有核对转发单元，既有部署补不上开机自启' || return 1
    assert_eq 2 "$(grep -Fc '(( compat_rc == 3 )) || exit 1' <<<"${helper_case}")" \
        '启用与刷新没有同时处理「跳过测速目标但继续配置」的返回码' || return 1
    assert_contains "${source}" 'enable_args+=("${outbound_mode}")' \
        '扫描菜单没有把选定的出站方式传给底层' || return 1
    assert_contains "${source}" '[[ ${outbound_mode} == env ]] || enable_args+=' \
        '默认模式仍然改变了既有服务的调用形态' || return 1
    assert_contains "${source}" 'switch_cf_probe_outbound_mode "${unit}" "${state}"' \
        '已托管菜单没有提供切换出站方式' || return 1
    assert_contains "${source}" 'remove_cf_probe_forward_mode "${TX_UNIT}" "${TX_FORWARD_DROPIN}"' \
        '启用失败回滚不会拆除转发模式' || return 1
    assert_contains "${source}" 'restore_cf_probe_forward_snapshot "${TX_UNIT}" "${TX_FORWARD_DROPIN}" "${TX_FORWARD_SNAPSHOT}"' \
        '服务事务失败时不会从快照恢复既有转发状态' || return 1
    assert_eq 2 "$(grep -Fc 'TX_FORWARD_SNAPSHOT=$(create_cf_probe_forward_snapshot "${unit}" "${dropin}" "${state}")' <<<"${helper_case}")" \
        '启用与停用没有在改动转发状态前把快照接入外层服务事务' || return 1
    assert_contains "${disable_body}" 'remove_cf_probe_forward_mode "${unit}" "${dropin}"' \
        '停用服务不会拆除转发模式' || return 1
    awk '
        /remove_cf_probe_forward_mode "\$\{unit\}" "\$\{dropin\}"/ { removed=NR }
        /TX_COMMITTED=yes/ { committed=NR }
        END { exit !(removed && committed && removed < committed) }
    ' <<<"${disable_body}" \
        || { fail '停用服务在拆除转发模式前就提交并注销了托管记录'; return 1; }
    assert_contains "${source}" 'cf_probe_forward_health "${unit}"' \
        '健康检查没有覆盖转发模式' || return 1
    # 转发模式的判定只在组件作用域里，角色侧必须经组件的只读入口取结论
    assert_contains "${helper_case}" 'cf-probe-forward-health)' \
        '组件没有提供转发模式健康结论的只读入口' || return 1
    assert_contains "${source}" '"${HELPER}" cf-probe-forward-health "${unit}"' \
        '角色侧的健康检查没有经组件入口取转发模式结论' || return 1
    assert_contains "${helper_case}" 'reconcile-cf-probe)' \
        'Helper 缺少动态配置守卫内部入口' || return 1
    assert_contains "${helper_case}" 'remove_cf_probe_go_guard_units "${unit}" "${compat_dir}"' \
        '停用服务没有先移除动态配置守卫' || return 1
    assert_contains "${helper_case}" 'restore_cf_probe_go_original_targets "${compat_dir}"' \
        '停用服务没有在重启前恢复 Go Agent 原测速目标' || return 1
    assert_contains "${source}" '完成：CF Probe 延迟兼容已检查并生效；具体模式以上方提示为准。' \
        'Agent 扫描完成提示没有区分 Shell 与 Go 兼容模式' || return 1
    ! grep -Fq '完成：CF Probe 延迟检测和真实地区上报已生效。' <<<"${source}" \
        || { fail 'Go Agent 扫描仍会误报真实地区上报已生效'; return 1; }
    awk '
        /restore_cf_probe_go_original_targets "\$\{compat_dir\}"/ { restored=NR }
        /restart_and_verify_running "\$\{unit\}"/ && !restarted { restarted=NR }
        END { exit !(restored && restarted && restored < restarted) }
    ' <<<"${disable_body}" \
        || { fail '停用服务在恢复 Go Agent 原测速目标前就重启了服务'; return 1; }
}

# ---- 转发模式（forward）----
# 这类客户端只有 HTTP 读代理环境变量，实时通道自己直接拨号；转发模式给它补一条本地转发。
forward_fixture() {
    local case_dir=$1 host=$2
    mkdir -p "${case_dir}/systemd" "${case_dir}/etc" "${case_dir}/dropin"
    chmod 0755 "${case_dir}/systemd" "${case_dir}/dropin"
    printf '%s\n' "WORKER_URL=\"https://${host}\"" 'SERVER_ID="fixture"' \
        >"${case_dir}/etc/config.conf"
    printf '%s\n' '#!/bin/sh' 'exit 0' >"${case_dir}/socat"
    chmod 0755 "${case_dir}/socat"
    : >"${case_dir}/ss.out"
    # 单元的运行状态与开机自启状态由这两个文件表达，用例改文件即可，不必重定义 systemctl
    printf '%s\n' 0 >"${case_dir}/is-active.rc"
    printf '%s\n' enabled >"${case_dir}/is-enabled.out"
    : >"${case_dir}/systemctl-fail-next"
    CF_PROBE_FORWARD_SOCAT=${case_dir}/socat
    cf_probe_go_systemd_root() { printf '%s\n' "${case_dir}/systemd"; }
    cf_probe_go_config_path_unverified() { printf '%s\n' "${case_dir}/etc/config.conf"; }
    systemctl() {
        printf '%s\n' "$*" >>"${case_dir}/systemctl.log"
        if [[ -s ${case_dir}/systemctl-fail-next ]] \
            && grep -Fxq -- "$*" "${case_dir}/systemctl-fail-next"; then
            : >"${case_dir}/systemctl-fail-next"
            printf 'fixture systemctl failure: %s\n' "$*" >&2
            return 1
        fi
        case "${1:-}" in
            is-active) return "$(cat "${case_dir}/is-active.rc")" ;;
            is-enabled) cat "${case_dir}/is-enabled.out" ;;
            show)
                if [[ $(cat "${case_dir}/is-active.rc") == 0 ]]; then
                    printf '%s\n' active
                else
                    printf '%s\n' inactive
                fi
                ;;
            enable)
                printf '%s\n' enabled >"${case_dir}/is-enabled.out"
                [[ $* != *'--now'* ]] || printf '%s\n' 0 >"${case_dir}/is-active.rc"
                ;;
            disable)
                printf '%s\n' disabled >"${case_dir}/is-enabled.out"
                [[ $* != *'--now'* ]] || printf '%s\n' 3 >"${case_dir}/is-active.rc"
                ;;
            start|restart) printf '%s\n' 0 >"${case_dir}/is-active.rc" ;;
            stop) printf '%s\n' 3 >"${case_dir}/is-active.rc" ;;
        esac
        return 0
    }
    ss() { cat "${case_dir}/ss.out" 2>/dev/null; return 0; }
}

forward_fail_next_systemctl() {
    local case_dir=$1
    shift
    printf '%s\n' "$*" >"${case_dir}/systemctl-fail-next"
}

# 启用后要生成受管目录、专属 hosts、受管记录与转发单元，并给出挂载行；拆除后一件不剩。
test_forward_mode_lifecycle() (
    local case_dir unit host dropin hosts record unit_file created line
    unit=cf-probe.service
    host=panel.example.invalid
    case_dir=$(mktemp -d "${WORK_ROOT}/forward-life.XXXXXX") || return 1
    forward_fixture "${case_dir}" "${host}"
    dropin=${case_dir}/dropin
    hosts=$(cf_probe_forward_hosts_file "${dropin}") || return 1
    record=$(cf_probe_forward_record_file "${dropin}") || return 1
    unit_file=$(cf_probe_forward_unit_file "${unit}") || return 1

    created=$(prepare_cf_probe_forward_mode "${unit}" "${dropin}") \
        || { fail '启用转发模式失败'; return 1; }
    assert_eq yes "${created}" '启用没有报告新建了转发目录' || return 1
    [[ -f ${hosts} && -f ${record} && -f ${unit_file} ]] \
        || { fail '转发模式没有生成完整的三件套'; return 1; }
    grep -Fxq "127.0.0.1 ${host}" "${hosts}" \
        || { fail '专属 hosts 没有把面板域名指向本机'; return 1; }
    grep -Fq 'PROXY:127.0.0.1:'"${host}"':443,proxyport=13128' "${unit_file}" \
        || { fail '转发单元没有经管理代理转发'; return 1; }
    assert_eq "${host}" "$(cf_probe_forward_record_value "${record}" FORWARD_HOST)" \
        '受管记录里的面板主机不正确' || return 1
    cf_probe_forward_mode_active "${dropin}" \
        || { fail '受管记录存在却判定为未启用转发模式'; return 1; }
    line=$(cf_probe_forward_dropin_line "${dropin}") || return 1
    assert_eq "BindReadOnlyPaths=${hosts}:/etc/hosts" "${line}" \
        '挂载行不正确' || return 1
    # 专属 hosts 必须是系统 hosts 的超集，否则会破坏服务里的其他解析
    assert_eq 0 "$(sed '1d' "${hosts}" | grep -vxF "127.0.0.1 ${host}" \
        | diff -q - /etc/hosts >/dev/null 2>&1; echo $?)" \
        '专属 hosts 与系统 hosts 的其余内容不一致' || return 1

    remove_cf_probe_forward_mode "${unit}" "${dropin}" \
        || { fail '拆除转发模式失败'; return 1; }
    [[ ! -e ${hosts} && ! -e ${record} && ! -e ${unit_file} ]] \
        || { fail '拆除后仍有转发模式残留'; return 1; }
    [[ ! -d $(cf_probe_forward_dir "${dropin}") ]] \
        || { fail '拆除后转发目录仍然存在'; return 1; }
    cf_probe_forward_mode_active "${dropin}" \
        && { fail '拆除后仍被判定为转发模式'; return 1; }
    remove_cf_probe_forward_mode "${unit}" "${dropin}" \
        || { fail '重复拆除不应报错'; return 1; }
)

# 转发单元必须能开机自启：新写出的带 [Install] 且被启用；早期版本落下的缺 [Install]
# 单元要在刷新时被重写并重新启用，否则重启后转发器不起、实时通道静默断开。
test_forward_unit_boot_enable_and_reconcile() (
    local case_dir unit host dropin unit_file unit_name legacy log output
    unit=cf-probe.service
    host=panel.example.invalid
    case_dir=$(mktemp -d "${WORK_ROOT}/forward-boot.XXXXXX") || return 1
    forward_fixture "${case_dir}" "${host}"
    dropin=${case_dir}/dropin
    unit_file=$(cf_probe_forward_unit_file "${unit}") || return 1
    unit_name=$(cf_probe_forward_unit_name "${unit}") || return 1
    log=${case_dir}/systemctl.log

    prepare_cf_probe_forward_mode "${unit}" "${dropin}" >/dev/null \
        || { fail '启用转发模式失败'; return 1; }
    assert_contains "$(cat "${unit_file}")" '[Install]' \
        '新写出的转发单元没有 [Install] 段，systemctl enable 只会空转' || return 1
    assert_contains "$(cat "${unit_file}")" 'WantedBy=multi-user.target' \
        '新写出的转发单元没有声明开机自启目标' || return 1
    assert_contains "$(cat "${log}")" "enable --now -- ${unit_name}" \
        '启用转发模式时没有启用转发单元' || return 1

    # 造出早期版本落地的单元：首行标记仍是本助手的，但没有 [Install] 段
    legacy=$(grep -vxF '[Install]' "${unit_file}" | grep -vxF 'WantedBy=multi-user.target')
    printf '%s\n' "${legacy}" >"${unit_file}"
    assert_not_contains "$(cat "${unit_file}")" 'WantedBy=' \
        '夹具没有造出缺开机自启的旧单元' || return 1
    : >"${log}"
    reconcile_cf_probe_forward_unit "${unit}" "${dropin}" \
        || { fail '刷新没有收敛旧版转发单元'; return 1; }
    assert_contains "$(cat "${unit_file}")" 'WantedBy=multi-user.target' \
        '刷新没有把旧版转发单元重写成带开机自启的版本' || return 1
    assert_contains "$(cat "${log}")" 'daemon-reload' \
        '重写转发单元后没有让 systemd 重新载入' || return 1
    assert_contains "$(cat "${log}")" "try-restart -- ${unit_name}" \
        '重写转发单元后没有让在跑的转发器用上新内容' || return 1
    assert_contains "$(cat "${log}")" "enable --now -- ${unit_name}" \
        '刷新没有重新启用转发单元' || return 1

    # 内容已经一致：不再重写，但仍要启用一次，用来补回缺失的开机链接
    : >"${log}"
    reconcile_cf_probe_forward_unit "${unit}" "${dropin}" \
        || { fail '内容一致时刷新不应失败'; return 1; }
    assert_not_contains "$(cat "${log}")" 'daemon-reload' \
        '内容已经一致却仍然重写了转发单元' || return 1
    assert_contains "$(cat "${log}")" "enable --now -- ${unit_name}" \
        '内容一致时没有补回开机启用' || return 1

    # 同名单元不是本助手写的：刷新必须拒绝，且一个字都不许改
    printf '%s\n' '# hand written' >"${unit_file}"
    output=$(reconcile_cf_probe_forward_unit "${unit}" "${dropin}" 2>&1) \
        && { fail '转发单元不是本助手所写时刷新没有拒绝'; return 1; }
    assert_eq '# hand written' "$(cat "${unit_file}")" \
        '拒绝时改动了他人的单元文件' || return 1
)

# 既有转发三件套可能来自上一次未完成的服务事务。再次启用若启动失败，必须把
# 旧 unit、hosts、record 与原服务状态完整还原，不能把原本可用的配置当作新文件删除。
test_forward_prepare_failure_restores_reused_state() (
    local case_dir unit host dropin directory hosts record unit_file unit_name snapshot output
    unit=cf-probe.service
    host=panel.example.invalid
    case_dir=$(mktemp -d "${WORK_ROOT}/forward-prepare-rollback.XXXXXX") || return 1
    forward_fixture "${case_dir}" "${host}"
    dropin=${case_dir}/dropin
    directory=$(cf_probe_forward_dir "${dropin}") || return 1
    hosts=$(cf_probe_forward_hosts_file "${dropin}") || return 1
    record=$(cf_probe_forward_record_file "${dropin}") || return 1
    unit_file=$(cf_probe_forward_unit_file "${unit}") || return 1
    unit_name=$(cf_probe_forward_unit_name "${unit}") || return 1

    prepare_cf_probe_forward_mode "${unit}" "${dropin}" >/dev/null \
        || { fail '建立既有转发夹具失败'; return 1; }
    # 保持首行归属标记，但造出与当前模板不同的旧版内容，确保重试确实发生过改写。
    printf '%s\n' "${CF_PROBE_FORWARD_MARKER}" 'legacy hosts content' >"${hosts}"
    printf '%s\n' "${CF_PROBE_FORWARD_MARKER}" \
        "UNIT=${unit}" "FORWARD_HOST=${host}" 'LISTEN=127.0.0.1:443' 'LEGACY=yes' >"${record}"
    printf '%s\n' "${CF_PROBE_FORWARD_MARKER}" '[Unit]' 'Description=legacy forward unit' >"${unit_file}"
    snapshot=${case_dir}/before
    mkdir -p "${snapshot}"
    cp -p -- "${hosts}" "${record}" "${unit_file}" "${snapshot}/"

    forward_fail_next_systemctl "${case_dir}" enable --now -- "${unit_name}"
    output=$(prepare_cf_probe_forward_mode "${unit}" "${dropin}" 2>&1) \
        && { fail '复用既有配置时启动失败却返回成功'; return 1; }
    assert_contains "${output}" '转发单元未能启动' '启动失败没有给出明确原因' || return 1
    [[ -d ${directory} ]] || { fail '启动失败后删除了既有转发目录'; return 1; }
    cmp -s "${snapshot}/hosts" "${hosts}" \
        || { fail '启动失败后没有恢复既有 hosts'; return 1; }
    cmp -s "${snapshot}/record" "${record}" \
        || { fail '启动失败后没有恢复既有 record'; return 1; }
    cmp -s "${snapshot}/${unit_file##*/}" "${unit_file}" \
        || { fail '启动失败后没有恢复既有转发 unit'; return 1; }
)

# 刷新旧 unit 的三个 systemd 阶段都可能失败；每个阶段都必须恢复刷新前的逐字节内容。
test_forward_reconcile_failures_restore_unit() (
    local command case_dir unit host dropin unit_file unit_name before output
    unit=cf-probe.service
    host=panel.example.invalid
    for command in daemon-reload try-restart enable; do
        case_dir=$(mktemp -d "${WORK_ROOT}/forward-reconcile-${command}.XXXXXX") || return 1
        forward_fixture "${case_dir}" "${host}"
        dropin=${case_dir}/dropin
        unit_file=$(cf_probe_forward_unit_file "${unit}") || return 1
        unit_name=$(cf_probe_forward_unit_name "${unit}") || return 1
        prepare_cf_probe_forward_mode "${unit}" "${dropin}" >/dev/null \
            || { fail "建立 ${command} 失败夹具失败"; return 1; }
        printf '%s\n' "${CF_PROBE_FORWARD_MARKER}" '[Unit]' \
            "Description=legacy before ${command}" >"${unit_file}"
        before=${case_dir}/before-unit
        cp -p -- "${unit_file}" "${before}"
        case "${command}" in
            daemon-reload) forward_fail_next_systemctl "${case_dir}" daemon-reload ;;
            try-restart) forward_fail_next_systemctl "${case_dir}" try-restart -- "${unit_name}" ;;
            enable) forward_fail_next_systemctl "${case_dir}" enable --now -- "${unit_name}" ;;
        esac
        output=$(reconcile_cf_probe_forward_unit "${unit}" "${dropin}" 2>&1) \
            && { fail "${command} 失败时刷新仍返回成功"; return 1; }
        cmp -s "${before}" "${unit_file}" \
            || { fail "${command} 失败后没有恢复旧转发 unit"; return 1; }
        assert_contains "${output}" 'fixture systemctl failure' \
            "${command} 的 systemd 错误没有保留" || return 1
    done
)

# 拆除必须先确认转发单元真的停下；停用失败时不得删文件。若后续服务事务失败，
# 已拆除的转发状态与托管清单也必须能从事务快照恢复。
test_forward_disable_failure_and_transaction_restore() (
    local case_dir unit host dropin hosts record unit_file unit_name state snapshot output rc
    unit=cf-probe.service
    host=panel.example.invalid
    case_dir=$(mktemp -d "${WORK_ROOT}/forward-disable-rollback.XXXXXX") || return 1
    forward_fixture "${case_dir}" "${host}"
    dropin=${case_dir}/dropin
    hosts=$(cf_probe_forward_hosts_file "${dropin}") || return 1
    record=$(cf_probe_forward_record_file "${dropin}") || return 1
    unit_file=$(cf_probe_forward_unit_file "${unit}") || return 1
    unit_name=$(cf_probe_forward_unit_name "${unit}") || return 1
    prepare_cf_probe_forward_mode "${unit}" "${dropin}" >/dev/null \
        || { fail '建立拆除夹具失败'; return 1; }

    forward_fail_next_systemctl "${case_dir}" disable --now -- "${unit_name}"
    output=$(remove_cf_probe_forward_mode "${unit}" "${dropin}" 2>&1) \
        && { fail '转发单元停用失败时拆除仍返回成功'; return 1; }
    assert_contains "${output}" 'fixture systemctl failure' '停用失败的 systemd 原因被吞掉' || return 1
    [[ -f ${hosts} && -f ${record} && -f ${unit_file} ]] \
        || { fail '停用失败时仍删除了转发材料'; return 1; }

    state=${case_dir}/state
    mkdir -p "${state}"
    chmod 0700 "${state}"
    printf '%s\n' "${unit}" >"${state}/managed-services"
    snapshot=$(create_cf_probe_forward_snapshot "${unit}" "${dropin}" "${state}") \
        || { fail '无法建立转发事务快照'; return 1; }
    remove_cf_probe_forward_mode "${unit}" "${dropin}" \
        || { fail '正常拆除转发模式失败'; return 1; }
    [[ ! -e ${hosts} && ! -e ${record} && ! -e ${unit_file} ]] \
        || { fail '正常拆除后仍有转发材料'; return 1; }

    TX_COMMITTED=no
    TX_UNIT=${unit}
    TX_STATE=${state}
    TX_DROPIN_MAY_BE_REMOVED=no
    TX_LIST_MAY_CHANGE=yes
    TX_FORWARD_DROPIN=${dropin}
    TX_FORWARD_SNAPSHOT=${snapshot}
    TX_FORWARD_MAY_CHANGE=yes
    TX_CF_GUARD_REMOVED=no
    TX_ORIGINAL_RUNNING=no
    rc=0
    ( disable_transaction_cleanup 1 ) >/dev/null 2>&1 || rc=$?
    assert_eq 1 "${rc}" '事务清理没有保留原失败退出码' || return 1
    [[ -f ${hosts} && -f ${record} && -f ${unit_file} ]] \
        || { fail '服务事务失败后没有恢复转发材料'; return 1; }
    grep -Fxq -- "${unit}" "${state}/managed-services" \
        || { fail '服务事务失败后没有恢复托管记录'; return 1; }
    [[ ! -e ${snapshot} ]] || { fail '事务恢复后仍遗留转发快照'; return 1; }
)

# 角色侧的健康检查完全依赖这条组件入口的退出码：3 表示未启用转发模式（照旧显示正常），
# 0 表示给出了结论，其余一律被当成「无法确认」而报异常。所以退出码要真跑一遍，不能只看源码。
test_forward_health_entry_exit_codes() (
    local case_dir unit host dropin component out rc
    unit=cf-probe.service
    host=panel.example.invalid
    case_dir=$(mktemp -d "${WORK_ROOT}/forward-entry.XXXXXX") || return 1
    forward_fixture "${case_dir}" "${host}"
    mkdir -p "${case_dir}/systemd/${unit}.d" || return 1
    dropin=${case_dir}/systemd/${unit}.d
    # 组件里 drop-in 路径写死为 /etc/systemd/system，整体换成夹具目录后按真脚本执行
    component=${case_dir}/po0-cn-entry
    helper_region | sed "s|/etc/systemd/system|${case_dir}/systemd|g" >"${component}"
    /bin/bash -n "${component}" || { fail '改写后的组件语法错误'; return 1; }

    # 未启用转发模式：必须以 3 退出且不输出任何结论
    rc=0
    # shellcheck disable=SC1090
    out=$( ( source "${component}" cf-probe-forward-health "${unit}" ) 2>/dev/null ) || rc=$?
    assert_eq 3 "${rc}" '未启用转发模式时组件入口没有返回 3' || return 1
    [[ -z ${out} ]] || { fail "未启用转发模式却输出了结论：${out}"; return 1; }

    # 启用之后：以 0 退出，并给出「等级 说明」
    prepare_cf_probe_forward_mode "${unit}" "${dropin}" >/dev/null \
        || { fail '启用转发模式失败'; return 1; }
    rc=0
    # shellcheck disable=SC1090
    out=$( ( source "${component}" cf-probe-forward-health "${unit}" ) 2>/dev/null ) || rc=$?
    assert_eq 0 "${rc}" '已启用转发模式时组件入口没有返回 0' || return 1
    assert_eq 正常 "${out%% *}" '组件入口没有给出正常等级' || return 1
    assert_contains "${out}" '转发模式' '组件入口的说明没有点出转发模式' || return 1

    # 转发单元停了：等级必须变成异常，且仍以 0 退出（0 表示「问出了结论」）
    printf '%s\n' 3 >"${case_dir}/is-active.rc"
    rc=0
    # shellcheck disable=SC1090
    out=$( ( source "${component}" cf-probe-forward-health "${unit}" ) 2>/dev/null ) || rc=$?
    assert_eq 0 "${rc}" '转发单元停止时组件入口没有返回 0' || return 1
    assert_eq 异常 "${out%% *}" '转发单元停止时组件入口没有给出异常等级' || return 1
    printf '%s\n' 0 >"${case_dir}/is-active.rc"

    # 服务名非法：返回 2，不能被角色侧误当成「未启用转发模式」
    rc=0
    # shellcheck disable=SC1090
    out=$( ( source "${component}" cf-probe-forward-health 'not a unit' ) 2>/dev/null ) || rc=$?
    assert_eq 2 "${rc}" '非法服务名没有返回 2' || return 1
)

# 护栏：缺 socat、监听口被占、配置无法解析、单元非本助手所写，四种都必须拒绝且不留残留。
test_forward_mode_guards_refuse_unsafe() (
    local case_dir unit host dropin unit_file output
    unit=cf-probe.service
    host=panel.example.invalid
    dropin=

    case_dir=$(mktemp -d "${WORK_ROOT}/forward-nosocat.XXXXXX") || return 1
    forward_fixture "${case_dir}" "${host}"
    dropin=${case_dir}/dropin
    rm -f "${case_dir}/socat"
    output=$(prepare_cf_probe_forward_mode "${unit}" "${dropin}" 2>&1) \
        && { fail '缺少 socat 时没有拒绝'; return 1; }
    assert_contains "${output}" 'socat' '缺少 socat 的拒绝理由不明确' || return 1
    [[ ! -d $(cf_probe_forward_dir "${dropin}") ]] \
        || { fail '拒绝后仍留下了转发目录'; return 1; }

    case_dir=$(mktemp -d "${WORK_ROOT}/forward-busy.XXXXXX") || return 1
    forward_fixture "${case_dir}" "${host}"
    dropin=${case_dir}/dropin
    printf '%s\n' 'LISTEN 0 128 127.0.0.1:443 0.0.0.0:*' >"${case_dir}/ss.out"
    output=$(prepare_cf_probe_forward_mode "${unit}" "${dropin}" 2>&1) \
        && { fail '监听口被占用时没有拒绝'; return 1; }
    assert_contains "${output}" '已被占用' '端口占用的拒绝理由不明确' || return 1
    [[ ! -d $(cf_probe_forward_dir "${dropin}") ]] \
        || { fail '端口占用被拒后仍留下了转发目录'; return 1; }

    case_dir=$(mktemp -d "${WORK_ROOT}/forward-badurl.XXXXXX") || return 1
    forward_fixture "${case_dir}" "${host}"
    dropin=${case_dir}/dropin
    printf '%s\n' 'WORKER_URL="http://panel.example.invalid"' >"${case_dir}/etc/config.conf"
    output=$(prepare_cf_probe_forward_mode "${unit}" "${dropin}" 2>&1) \
        && { fail '非 https 的面板地址没有被拒绝'; return 1; }
    assert_contains "${output}" '面板主机名' '面板地址无法解析的拒绝理由不明确' || return 1

    case_dir=$(mktemp -d "${WORK_ROOT}/forward-foreign.XXXXXX") || return 1
    forward_fixture "${case_dir}" "${host}"
    dropin=${case_dir}/dropin
    unit_file=$(cf_probe_forward_unit_file "${unit}") || return 1
    printf '%s\n' '# hand written' >"${unit_file}"
    chmod 0644 "${unit_file}"
    output=$(prepare_cf_probe_forward_mode "${unit}" "${dropin}" 2>&1) \
        && { fail '同名单元不是本助手所写时没有拒绝'; return 1; }
    assert_contains "${output}" '拒绝覆盖' '拒绝覆盖他人单元的理由不明确' || return 1
    assert_eq '# hand written' "$(cat "${unit_file}")" '拒绝时改动了他人的单元文件' || return 1

    # 人工改过专属 hosts 后，拆除必须拒绝，不许误删
    case_dir=$(mktemp -d "${WORK_ROOT}/forward-tamper.XXXXXX") || return 1
    forward_fixture "${case_dir}" "${host}"
    dropin=${case_dir}/dropin
    prepare_cf_probe_forward_mode "${unit}" "${dropin}" >/dev/null || return 1
    printf '%s\n' 'hand edited' >"$(cf_probe_forward_hosts_file "${dropin}")"
    remove_cf_probe_forward_mode "${unit}" "${dropin}" \
        && { fail '专属 hosts 被人工改过时拆除没有拒绝'; return 1; }
    [[ -f $(cf_probe_forward_hosts_file "${dropin}") ]] \
        || { fail '拒绝拆除时仍删掉了被改过的文件'; return 1; }
)

# 健康检查要能区分：正常、转发单元没跑（异常）、hosts 被改（异常）、系统 hosts 变化（提醒）。
test_forward_mode_health_reports() (
    local case_dir unit host dropin hosts status
    unit=cf-probe.service
    host=panel.example.invalid
    case_dir=$(mktemp -d "${WORK_ROOT}/forward-health.XXXXXX") || return 1
    forward_fixture "${case_dir}" "${host}"
    dropin=${case_dir}/dropin
    hosts=$(cf_probe_forward_hosts_file "${dropin}") || return 1
    prepare_cf_probe_forward_mode "${unit}" "${dropin}" >/dev/null || return 1

    status=$(cf_probe_forward_health "${unit}" "${dropin}")
    assert_eq 正常 "${status%% *}" '一切正常时健康检查没有报正常' || return 1
    assert_contains "${status}" '转发模式' '正常文案没有说明处于转发模式' || return 1

    # 单元现在跑着，但没有开机自启：重启后实时通道会断，属于要提醒的隐患
    printf '%s\n' static >"${case_dir}/is-enabled.out"
    status=$(cf_probe_forward_health "${unit}" "${dropin}")
    assert_eq 提醒 "${status%% *}" '转发单元不会开机自启时没有报提醒' || return 1
    assert_contains "${status}" '开机自启' '提醒没有点出隐患本身' || return 1
    assert_contains "${status}" '检查并更新配置' '提醒没有给出可执行的处置' || return 1
    # 对照：同一份部署只把开机自启补上，就必须回到正常，否则说明是别的东西坏了
    printf '%s\n' enabled >"${case_dir}/is-enabled.out"
    status=$(cf_probe_forward_health "${unit}" "${dropin}")
    assert_eq 正常 "${status%% *}" '补上开机自启后没有回到正常' || return 1

    printf '%s\n' 3 >"${case_dir}/is-active.rc"
    status=$(cf_probe_forward_health "${unit}" "${dropin}")
    assert_eq 异常 "${status%% *}" '转发单元没运行时没有报异常' || return 1
    assert_contains "${status}" '实时通道' '转发单元停止的说明没有点出后果' || return 1
    printf '%s\n' 0 >"${case_dir}/is-active.rc"

    printf '%s\n' 'hand edited' >"${hosts}"
    status=$(cf_probe_forward_health "${unit}" "${dropin}")
    assert_eq 异常 "${status%% *}" '专属 hosts 被改后没有报异常' || return 1

    # 系统 hosts 变化：专属 hosts 仍合法，但正文与系统的已经对不上
    {
        printf '%s\n' "${CF_PROBE_FORWARD_MARKER}"
        printf '%s\n' '127.0.0.1 localhost'
        printf '%s\n' '10.0.0.9 stale.example.invalid'
        printf '%s %s\n' 127.0.0.1 "${host}"
    } >"${hosts}"
    status=$(cf_probe_forward_health "${unit}" "${dropin}")
    assert_eq 提醒 "${status%% *}" '系统 hosts 变化后没有报提醒' || return 1
    assert_contains "${status}" '重新纳管' '提醒没有给出可执行的处置' || return 1
)

# 出站方式的选择菜单：回车与 1 都是默认模式，2 才是转发，其他输入不得当成有效选择。
test_outbound_mode_prompt_choices() (
    local body out rc
    body=$(sed -n '/^prompt_cf_probe_outbound_mode() {/,/^}/p' "${CN_ENTRY_ROLE}")
    [[ -n ${body} ]] || { fail '未能提取出站方式选择函数'; return 1; }
    eval "${body}"

    assert_eq env "$(prompt_cf_probe_outbound_mode <<<'' 2>/dev/null)" \
        '直接回车没有落到默认模式' || return 1
    assert_eq env "$(prompt_cf_probe_outbound_mode <<<'1' 2>/dev/null)" \
        '选 1 没有落到默认模式' || return 1
    assert_eq forward "$(prompt_cf_probe_outbound_mode <<<'2' 2>/dev/null)" \
        '选 2 没有落到转发模式' || return 1

    rc=0
    out=$(prompt_cf_probe_outbound_mode <<<'9' 2>/dev/null) || rc=$?
    [[ ${rc} -ne 0 ]] || { fail '无效选择没有返回非零'; return 1; }
    [[ -z ${out} ]] || { fail "无效选择仍然输出了模式：${out}"; return 1; }
    assert_contains "$(prompt_cf_probe_outbound_mode <<<'9' 2>&1 >/dev/null)" '选择无效' \
        '无效输入没有说明是输入错误' || return 1

    # 主动取消必须是被支持的出路，且不能被当成输入错误
    assert_contains "$(prompt_cf_probe_outbound_mode <<<'0' 2>&1 >/dev/null)" '0) 取消' \
        '选项里没有提供取消' || return 1
    rc=0
    out=$(prompt_cf_probe_outbound_mode <<<'0' 2>/dev/null) || rc=$?
    [[ ${rc} -ne 0 ]] || { fail '取消没有返回非零，会被当成选定了模式'; return 1; }
    [[ -z ${out} ]] || { fail "取消仍然输出了模式：${out}"; return 1; }
    assert_not_contains "$(prompt_cf_probe_outbound_mode <<<'0' 2>&1 >/dev/null)" '选择无效' \
        '主动取消被误报成输入错误' || return 1
)

# 切换出站方式必须先撤销再重新纳管；任一步失败都要说清楚服务当前处于什么状态。
test_switch_outbound_mode_paths() (
    local body case_dir state log out rc
    body=$(sed -n '/^prompt_cf_probe_outbound_mode() {/,/^}/p' "${CN_ENTRY_ROLE}")
    body=${body}$'\n'$(sed -n '/^switch_cf_probe_outbound_mode() {/,/^}/p' "${CN_ENTRY_ROLE}")
    [[ ${body} == *switch_cf_probe_outbound_mode* ]] || { fail '未能提取切换函数'; return 1; }
    eval "${body}"
    refresh_helper_from_state() { :; }

    case_dir=$(mktemp -d "${WORK_ROOT}/switch.XXXXXX") || return 1
    state=${case_dir}/state
    log=${case_dir}/helper.log
    mkdir -p -- "${state}"
    : >"${state}/service-proxy-actions.log"
    printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >>"$HELPER_LOG"' 'exit 0' >"${case_dir}/helper"
    chmod 0755 "${case_dir}/helper"
    HELPER=${case_dir}/helper
    export HELPER_LOG=${log}

    # 正常切换：先 disable，再带着新模式 enable
    : >"${log}"
    out=$(switch_cf_probe_outbound_mode cf-probe.service "${state}" <<<$'2\ny' 2>&1) \
        || { fail '正常切换返回了非零'; return 1; }
    assert_eq 'disable-service cf-probe.service' "$(sed -n '1p' "${log}")" \
        '切换没有先撤销原配置' || return 1
    assert_eq 'enable-service cf-probe.service forward' "$(sed -n '2p' "${log}")" \
        '切换没有按新模式重新纳管' || return 1
    assert_contains "${out}" 'forward' '完成提示没有说明切换后的方式' || return 1
    assert_eq 2 "$(grep -c . "${state}/service-proxy-actions.log")" \
        '切换没有把撤销与启用都写进操作日志' || return 1

    # 用户不确认：一次 helper 都不该被调用
    : >"${log}"
    switch_cf_probe_outbound_mode cf-probe.service "${state}" <<<$'2\nn' >/dev/null 2>&1 \
        || { fail '用户取消时返回了非零'; return 1; }
    assert_eq 0 "$(grep -c . "${log}" || true)" '用户取消后仍然调用了底层命令' || return 1

    # 撤销失败：不得继续启用新模式
    : >"${log}"
    printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >>"$HELPER_LOG"' \
        'case "$1" in disable-service) exit 1 ;; esac' 'exit 0' >"${case_dir}/helper"
    rc=0
    out=$(switch_cf_probe_outbound_mode cf-probe.service "${state}" <<<$'2\ny' 2>&1) || rc=$?
    [[ ${rc} -ne 0 ]] || { fail '撤销失败时切换没有返回非零'; return 1; }
    assert_eq 1 "$(grep -c . "${log}")" '撤销失败后仍然尝试了启用新模式' || return 1
    assert_contains "${out}" '未做切换' '撤销失败的提示没有说明未做切换' || return 1

    # 启用失败：必须点明服务当前是直接联网状态，而不是含糊带过
    : >"${log}"
    printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >>"$HELPER_LOG"' \
        'case "$1" in enable-service) exit 1 ;; esac' 'exit 0' >"${case_dir}/helper"
    rc=0
    out=$(switch_cf_probe_outbound_mode cf-probe.service "${state}" <<<$'2\ny' 2>&1) || rc=$?
    [[ ${rc} -ne 0 ]] || { fail '启用失败时切换没有返回非零'; return 1; }
    assert_contains "${out}" '直接联网' '启用失败没有说明服务当前的真实状态' || return 1
    assert_contains "${out}" '重新纳管' '启用失败没有给出可执行的处置' || return 1
)

# helper 是独立脚本，取不到角色侧的函数与变量。这两条守卫存在的原因：
# acquire_state_mutation_lock 从 v2.5.18 起就只定义在角色侧却被 helper 调用，
# enable-service / disable-service / refresh-service 因此一直失败，直到有人真的去增删
# Agent 才会暴露——六个版本没被发现。
helper_region() {
    awk '
        index($0, "cat >\"${tmp}\" <<\047EOF\047") { capture=1; next }
        capture && $0 == "EOF" { exit }
        capture { print }
    ' "${CN_ENTRY_ROLE}"
}

role_region() {
    awk '
        index($0, "cat >\"${tmp}\" <<\047EOF\047") { capture=1; next }
        capture && $0 == "EOF" { capture=0; next }
        !capture { print }
    ' "${CN_ENTRY_ROLE}"
}

test_helper_library_defines_every_function_it_calls() (
    local helper role name violations=0
    helper=$(helper_region); role=$(role_region)
    [[ -n ${helper} && -n ${role} ]] || { fail '未能切分 helper 与角色区间'; return 1; }
    while IFS= read -r name; do
        [[ -n ${name} ]] || continue
        # 只看命令位置的引用：注释、case 标签、JSON 字段名和说明文字都不算调用
        if awk -v fn="${name}" '
            /^[[:space:]]*#/ { next }
            {
                line=$0
                sub(/^[[:space:]]+/, "", line)
                sub(/^(if|!|then|else|while|until|do)[[:space:]]+/, "", line)
                sub(/^(&&|\|\|)[[:space:]]+/, "", line)
                if (line ~ "^" fn "([[:space:]]|$)") { found=1 }
                if (index(line, "$(" fn " ")) { found=1 }
            }
            END { exit(found ? 0 : 1) }
        ' <<<"${helper}"; then
            fail "helper 调用了只在角色侧定义的函数 ${name}；helper 是独立脚本，运行时会报 command not found"
            violations=$((violations + 1))
        fi
    done < <(comm -23 \
        <(grep -oE '^[a-z_][a-z0-9_]*\(\)' <<<"${role}" | tr -d '()' | sort -u) \
        <(grep -oE '^[a-z_][a-z0-9_]*\(\)' <<<"${helper}" | tr -d '()' | sort -u))
    (( violations == 0 )) || return 1
)

# 方向相反的同一类守卫：角色脚本同样取不到只写在组件 heredoc 里的函数。
# BUG-019 就是这样溜进去的——健康检查从角色侧调用组件独有的转发模式判定，
# 运行时 command not found，条件为假，于是永远走「一切正常」那条分支。
test_role_does_not_call_helper_only_functions() (
    local helper role name violations=0
    helper=$(helper_region); role=$(role_region)
    [[ -n ${helper} && -n ${role} ]] || { fail '未能切分 helper 与角色区间'; return 1; }
    while IFS= read -r name; do
        [[ -n ${name} ]] || continue
        if awk -v fn="${name}" '
            /^[[:space:]]*#/ { next }
            {
                line=$0
                sub(/^[[:space:]]+/, "", line)
                sub(/^(if|!|then|else|while|until|do)[[:space:]]+/, "", line)
                sub(/^(&&|\|\|)[[:space:]]+/, "", line)
                if (line ~ "^" fn "([[:space:]]|$)") { found=1 }
                if (index(line, "$(" fn " ")) { found=1 }
            }
            END { exit(found ? 0 : 1) }
        ' <<<"${role}"; then
            fail "角色脚本调用了只在组件里定义的函数 ${name}；组件写在 heredoc 里，角色运行时会报 command not found 并静默走错分支"
            violations=$((violations + 1))
        fi
    done < <(comm -23 \
        <(grep -oE '^[a-z_][a-z0-9_]*\(\)' <<<"${helper}" | tr -d '()' | sort -u) \
        <(grep -oE '^[a-z_][a-z0-9_]*\(\)' <<<"${role}" | tr -d '()' | sort -u))
    (( violations == 0 )) || return 1
)

test_helper_library_assigns_every_constant_it_reads() (
    local helper name allow violations=0
    helper=$(helper_region)
    [[ -n ${helper} ]] || { fail '未能提取 helper 区间'; return 1; }
    # 带默认值的引用（${X:-...}）在 set -u 下不会失败，且多半属于写给别的脚本的载荷，故排除；
    # 由运行环境或 bash 自身提供的变量也不在此列
    allow='^(PATH|HOME|EUID|IFS|PWD|OLDPWD|LANG|LC_ALL|LC_CTYPE|TMPDIR|SHELL|USER|LOGNAME|TERM|BASHPID|BASH_SUBSHELL|BASH_SOURCE|BASH_REMATCH|RANDOM|SECONDS|OPTARG|OPTIND|FUNCNAME|PIPESTATUS|SHLVL|HOSTNAME|SSH_CONNECTION|DEBIAN_FRONTEND|GLOBIGNORE|COLUMNS|LINES)$'
    while IFS= read -r name; do
        [[ -n ${name} ]] || continue
        [[ ${name} =~ ${allow} ]] && continue
        fail "helper 读取了自己没有赋值的常量 ${name}；helper 取不到角色侧的变量，set -u 下会直接失败"
        violations=$((violations + 1))
    done < <(comm -23 \
        <(grep -oE '\$\{?[A-Z][A-Z0-9_]{2,}[^A-Za-z0-9_]?' <<<"${helper}" \
            | grep -vE '[:+-]$' \
            | sed -E 's/^\$\{?//; s/[^A-Za-z0-9_]$//' | sort -u) \
        <(grep -oE '^[[:space:]]*(export[[:space:]]+)?[A-Z][A-Z0-9_]{2,}=' <<<"${helper}" \
            | sed -E 's/^[[:space:]]*(export[[:space:]]+)?//; s/=$//' | sort -u))
    (( violations == 0 )) || return 1
)

# 写锁必须能在 helper 自己的作用域里真正跑起来，并保持有界等待。
test_helper_service_lock_runs_in_helper_scope() (
    local case_dir state log
    case_dir=$(mktemp -d "${WORK_ROOT}/helper-lock.XXXXXX") || return 1
    state=${case_dir}/state
    log=${case_dir}/flock.log
    mkdir -p -- "${state}"
    printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >>"$FLOCK_LOG"' 'exit 0' >"${case_dir}/flock"
    chmod 0755 "${case_dir}/flock"
    export FLOCK_LOG=${log}
    PATH=${case_dir}:${PATH}

    acquire_service_lock "${state}" || { fail '在 helper 作用域里取写锁失败'; return 1; }
    [[ -f ${state}/service-proxy.lock ]] || { fail '没有创建写锁文件'; return 1; }
    assert_contains "$(<"${log}")" '-w 30' '写锁没有使用 30 秒有界等待' || return 1
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
        PASS_COUNT=$((PASS_COUNT + 1))
        printf '%s\n' PASS
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf '%s\n' FAIL
    fi
}

main() {
    make_helper_library
    printf '%s\n' 'CF Probe 延迟兼容验收：'
    run_case '识别 Agent 的 ping 回退能力' test_agent_contract_detection
    run_case '识别官方 Go Agent 二进制契约' test_go_agent_contract_detection
    run_case 'Go Agent 拒绝原因准确可诊断' test_go_agent_rejection_explains_reason
    run_case '备用测速目标固定落在金华节点' test_jinhua_fallback_targets
    run_case 'Go Agent 原生安全端口可应用、重试、回滚和停用恢复' test_go_agent_native_targets_and_rollback
    run_case 'Go Agent 备用节点失败时保持原配置' test_go_agent_fallback_failure_keeps_config
    run_case 'Go Agent 首次事务中断后可自动恢复' test_go_agent_stale_first_transaction_recovery
    run_case 'Go Agent 面板动态配置覆盖可持续收敛' test_go_agent_dynamic_config_guard
    run_case '服务专用兼容文件可直连上报、失败回退并安全清理' test_wrapper_lifecycle_and_scope
    run_case '测速目标守卫拿不到锁时有界等待并明确失败' test_reconcile_cf_probe_waits_for_lock
    run_case 'cf-probe 兼容文件归属校验包含权限位' test_cf_probe_compat_ownership_checks_mode
    run_case '启用事务在 drop-in 落盘前失败也会补偿 cf-probe' test_enable_rollback_compensates_before_dropin_flag
    run_case '启用、刷新、失败回滚、停用和扫描路径均已接入' test_source_lifecycle_contracts
    run_case '转发模式可启用、可核对、可完整拆除' test_forward_mode_lifecycle
    run_case '转发单元开机自启，旧单元在刷新时被收敛' test_forward_unit_boot_enable_and_reconcile
    run_case '复用既有转发状态失败时逐字节恢复' test_forward_prepare_failure_restores_reused_state
    run_case '刷新转发单元各阶段失败时恢复旧内容' test_forward_reconcile_failures_restore_unit
    run_case '停用失败不删除且服务事务可恢复转发状态' test_forward_disable_failure_and_transaction_restore
    run_case '组件转发健康入口的退出码实跑覆盖' test_forward_health_entry_exit_codes
    run_case '转发模式的护栏拒绝不安全前提' test_forward_mode_guards_refuse_unsafe
    run_case '转发模式健康检查区分正常、异常与提醒' test_forward_mode_health_reports
    run_case '出站方式选择菜单的取值与拒绝' test_outbound_mode_prompt_choices
    run_case '切换出站方式的正常、取消与两种失败路径' test_switch_outbound_mode_paths
    run_case 'helper 不调用只在角色侧定义的函数' test_helper_library_defines_every_function_it_calls
    run_case '角色脚本不调用只在组件里定义的函数' test_role_does_not_call_helper_only_functions
    run_case 'helper 不读取自己没赋值的常量' test_helper_library_assigns_every_constant_it_reads
    run_case '服务写锁在 helper 作用域内可用且有界' test_helper_service_lock_runs_in_helper_scope
    printf '结果：%d 通过，%d 失败\n' "${PASS_COUNT}" "${FAIL_COUNT}"
    (( FAIL_COUNT == 0 ))
}

main "$@"
