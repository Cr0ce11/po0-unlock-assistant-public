#!/usr/bin/env bash
set -u
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=${TEST_DIR%/tests}
SETUP_SOURCE=${PROJECT_DIR}/setup.sh
EXIT_SOURCE=${PROJECT_DIR}/overseas-exit-role.sh
CN_SOURCE=${PROJECT_DIR}/cn-entry-role.sh
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
assert_order() {
    local haystack=$1 first=$2 second=$3 message=$4 first_line second_line
    first_line=$(grep -Fn -- "${first}" <<<"${haystack}" | head -1 | cut -d: -f1)
    second_line=$(grep -Fn -- "${second}" <<<"${haystack}" | head -1 | cut -d: -f1)
    [[ -n ${first_line} && -n ${second_line} && ${first_line} -lt ${second_line} ]] \
        || fail "${message}"
}

test_user_interface_contract() {
    local source combined_body
    source=$(<"${SETUP_SOURCE}")
    combined_body=$(sed -n '/^health_check_with_diagnostic_offer() {/,/^}/p' "${SETUP_SOURCE}")
    assert_contains "${source}" '3) 健康检查与问题处理' \
        '主菜单没有面向普通用户展示新功能' || return 1
    assert_contains "${source}" '3) run_cn_entry_operation health_check_with_diagnostic_offer; pause_for_menu' \
        '健康检查与诊断报告没有共享同一操作会话' || return 1
    assert_contains "${combined_body}" 'health_check || offer_diagnostic_report' \
        '发现故障后会退出主菜单' || return 1
    assert_contains "${source}" 'status|health) run_cn_entry_operation health_check' \
        '直接健康检查命令没有接入' || return 1
    assert_contains "${source}" 'raw-status) run_cn_entry_operation status_all' \
        '原始状态输出没有保留给高级排障' || return 1
    assert_contains "${source}" '当前不是交互终端' \
        '交互边界意外缺失' || return 1
}

test_read_only_check_contract() {
    local setup_body exit_body cn_body
    setup_body=$(sed -n '/^health_check_loaded() (/,/^)/p' "${SETUP_SOURCE}")
    exit_body=$(sed -n '/^health() (/,/^)/p' "${EXIT_SOURCE}")
    cn_body=$(sed -n '/^health() (/,/^)/p' "${CN_SOURCE}")
    assert_contains "${setup_body}" '检查阶段不会重启服务或修改配置' \
        '界面没有明确说明只读边界' || return 1
    assert_contains "${setup_body}" 'run_exit_role "${EXIT_CMD_HEALTH}"' \
        '没有检查国外出口' || return 1
    assert_contains "${setup_body}" \
        "ssh_cn_entry_component \"\${CN_ENTRY_TIMEOUT_HEALTH}\" read-only '健康检查'" \
        '没有使用当前内嵌组件检查国内入口' || return 1
    for body in "${exit_body}" "${cn_body}"; do
        assert_not_contains "${body}" 'systemctl restart' '只读检查会重启服务' || return 1
        assert_not_contains "${body}" 'systemctl enable' '只读检查会修改开机启动' || return 1
        assert_not_contains "${body}" 'rm -f' '只读检查会删除文件' || return 1
        assert_not_contains "${body}" 'mv ' '只读检查会移动文件' || return 1
    done
}

test_health_scope_contract() {
    local exit_body cn_body
    exit_body=$(sed -n '/^health() (/,/^)/p' "${EXIT_SOURCE}")
    cn_body=$(sed -n '/^health() (/,/^)/p' "${CN_SOURCE}")
    for needle in \
        '国外出口代理配置' '国外出口代理服务' '代理开机启动' \
        '代理监听端口' '国外出口联网' '反向隧道配置' \
        '反向隧道服务' '隧道开机启动' '连接路由' '国内入口 SSH'; do
        assert_contains "${exit_body}" "${needle}" "国外出口缺少检查：${needle}" || return 1
    done
    for needle in \
        '安装状态' '受限隧道账户' '反向隧道连接' \
        '国内入口代理端口' 'APT 代理配置' '登录环境代理配置' \
        'Agent 管理组件' '国内入口联网' '托管 Agent' '旧版 Komari 组件'; do
        assert_contains "${cn_body}" "${needle}" "国内入口缺少检查：${needle}" || return 1
    done
}

test_health_return_code_contract() {
    local exit_body cn_body setup_body
    exit_body=$(sed -n '/^health() (/,/^)/p' "${EXIT_SOURCE}")
    cn_body=$(sed -n '/^health() (/,/^)/p' "${CN_SOURCE}")
    setup_body=$(sed -n '/^health_check_loaded() (/,/^)/p' "${SETUP_SOURCE}")

    assert_not_contains "${exit_body}" 'warnings' \
        '国外出口健康检查仍保留不可达的提醒计数' || return 1
    assert_not_contains "${exit_body}" 'return 2' \
        '国外出口健康检查仍暴露不可达的提醒返回码' || return 1
    assert_contains "${exit_body}" 'if (( failures == 0 )); then' \
        '国外出口健康检查没有明确的零故障成功条件' || return 1
    assert_not_contains "${setup_body}" '(( exit_rc == 2 ))' \
        '主控仍把国外出口返回码 2 视为有效提醒' || return 1
    assert_contains "${setup_body}" 'exit_rc=$?' \
        '主控没有读取国外出口失败状态' || return 1
    assert_contains "${setup_body}" '(( cn_rc == 2 )) || overall_fail=yes' \
        '主控错误移除了国内入口真实提醒状态' || return 1
    assert_contains "${cn_body}" 'warnings=$((warnings + 1))' \
        '国内入口不再记录真实提醒' || return 1
    assert_contains "${cn_body}" 'return 2' \
        '国内入口真实提醒返回码被错误删除' || return 1
}

test_remote_temp_paths_are_strictly_validated() (
    local install_validator scan_validator install_body temporary_body source path
    local output rc remote_response
    source=$(<"${SETUP_SOURCE}")
    install_validator=$(sed -n '/^valid_cn_entry_install_temp_path() {/,/^}/p' "${SETUP_SOURCE}")
    scan_validator=$(sed -n '/^valid_cn_entry_scan_temp_path() {/,/^}/p' "${SETUP_SOURCE}")
    install_body=$(sed -n '/^upload_cn_entry_role() {/,/^}/p' "${SETUP_SOURCE}")
    temporary_body=$(sed -n '/^upload_temporary_cn_entry_role() {/,/^}/p' "${SETUP_SOURCE}")
    [[ -n ${install_validator} && -n ${scan_validator} ]] \
        || { fail '未能提取远端临时路径校验函数'; return 1; }
    eval "${install_validator}"
    eval "${scan_validator}"
    eval "${install_body}"
    eval "${temporary_body}"

    valid_cn_entry_install_temp_path '/usr/local/libexec/.po0-unlock-cn-entry.Ab12Cd34' \
        || { fail '正式组件校验拒绝了合法 mktemp 路径'; return 1; }
    valid_cn_entry_scan_temp_path '/root/.po0-cn-entry-scan.Ab12Cd34' \
        || { fail '临时组件校验拒绝了合法 mktemp 路径'; return 1; }

    for path in \
        '/root/.po0-cn-entry-scan.Ab12Cd3' \
        '/root/.po0-cn-entry-scan.Ab12Cd345' \
        '/root/.po0-cn-entry-scan.Ab12Cd3_' \
        '/root/.po0-cn-entry-scan.Ab12Cd34/extra' \
        "/root/.po0-cn-entry-scan.Ab12Cd34';touch /tmp/pwn;#" \
        $'/root/.po0-cn-entry-scan.Ab12Cd34\nextra'; do
        ! valid_cn_entry_scan_temp_path "${path}" \
            || { fail "临时组件校验接受了异常路径：${path}"; return 1; }
    done
    for path in \
        '/usr/local/libexec/.po0-unlock-cn-entry.Ab12Cd34/extra' \
        "/usr/local/libexec/.po0-unlock-cn-entry.Ab12Cd34';id;#"; do
        ! valid_cn_entry_install_temp_path "${path}" \
            || { fail "正式组件校验接受了异常路径：${path}"; return 1; }
    done

    assert_contains "${install_body}" 'valid_cn_entry_install_temp_path "${remote_tmp}"' \
        '正式组件上传未使用严格路径校验' || return 1
    assert_order "${temporary_body}" \
        'valid_cn_entry_scan_temp_path "${remote_tmp}"' \
        'printf -v "${output_var}" '\''%s'\'' "${remote_tmp}"' \
        '异常临时路径在验证前已暴露给调用者清理逻辑' || return 1
    assert_not_contains "${source}" '/root/.po0-cn-entry-scan.*)' \
        '源码仍使用可接受命令字符的宽松临时路径 glob' || return 1

    CN_ENTRY_ROLE_LOCAL=${CN_SOURCE}
    EXIT_PRIVATE_IP=10.0.0.2
    ADMIN_KEY=/tmp/test-admin-key
    CN_ENTRY_SSH_PORT=22
    CN_ENTRY_TARGET=root@10.0.0.1
    sha256sum() { printf '%064d  fixture\n' 0; }
    ssh_cn_entry() { printf '%s\n' "${remote_response}"; }
    scp() { printf '%s\n' SCP_CALLED; return 1; }
    die() { printf 'DIE:%s\n' "$*" >&2; exit 1; }

    remote_response="/root/.po0-cn-entry-scan.Ab12Cd34';touch /tmp/pwn;#"
    output=$(upload_temporary_cn_entry_role captured_path 2>&1)
    rc=$?
    [[ ${rc} -ne 0 ]] || { fail '异常临时组件路径没有阻止上传'; return 1; }
    assert_not_contains "${output}" SCP_CALLED \
        '异常临时组件路径仍进入了 scp 上传命令' || return 1

    remote_response="/usr/local/libexec/.po0-unlock-cn-entry.Ab12Cd34';id;#"
    output=$(upload_cn_entry_role 2>&1)
    rc=$?
    [[ ${rc} -ne 0 ]] || { fail '异常正式组件路径没有阻止上传'; return 1; }
    assert_not_contains "${output}" SCP_CALLED \
        '异常正式组件路径仍进入了 scp 上传命令' || return 1
)

test_readable_layout_contract() {
    local setup_body exit_source cn_source
    setup_body=$(sed -n '/^health_check_loaded() (/,/^)/p' "${SETUP_SOURCE}")
    exit_source=$(<"${EXIT_SOURCE}")
    cn_source=$(<"${CN_SOURCE}")

    assert_contains "${setup_body}" '【1/2 国外出口】' \
        '健康检查没有清楚标明第一部分' || return 1
    assert_contains "${setup_body}" '【2/2 国内入口】' \
        '健康检查没有清楚标明第二部分' || return 1
    assert_contains "${setup_body}" '【总体结果】' \
        '健康检查缺少独立总体结果区域' || return 1
    assert_contains "${setup_body}" '无需修复，服务器配置未被修改。' \
        '正常结论没有说明无需操作' || return 1
    assert_contains "${setup_body}" '[进行中] 检查准备：建立连接并选择当前组件' \
        '国内入口慢连接期间没有可见准备进度' || return 1
    assert_contains "${setup_body}" '国内入口检查执行耗时' \
        '国内入口没有显示实际检查耗时' || return 1
    assert_contains "${setup_body}" '国内入口阶段总耗时' \
        '国内入口没有显示阶段总耗时' || return 1

    for source in "${exit_source}" "${cn_source}"; do
        assert_contains "${source}" "printf '    [%s] %s：%s" \
            '检查项没有使用稳定的单行冒号布局' || return 1
        assert_not_contains "${source}" '%-24s' \
            '检查项仍依赖跨终端不稳定的固定列宽' || return 1
    done
    for group in '基础状态' '出口代理' '反向隧道' '连接路径'; do
        assert_contains "${exit_source}" "health_group '${group}'" \
            "国外出口缺少分组：${group}" || return 1
    done
    for group in '基础状态' '隧道与代理' '国内入口组件' '受管 Agent'; do
        assert_contains "${cn_source}" "health_group '${group}'" \
            "国内入口缺少分组：${group}" || return 1
    done
}

test_public_connection_path_uses_generic_copy() (
    local case_dir fixture_state repair_state function_body output rc
    case_dir=$(mktemp -d "${TMPDIR:-/tmp}/po0-public-copy.XXXXXXXX")
    trap 'rm -rf -- "${case_dir}"' EXIT
    fixture_state=${case_dir}/20260804T014000Z
    repair_state=${case_dir}/repair-state
    mkdir -p -- "${fixture_state}" "${repair_state}"
    printf '%s\n' '203.0.113.10' >"${fixture_state}/cn-entry-private-ip"
    printf '%s\n' '198.51.100.20' >"${fixture_state}/overseas-exit-private-ip"
    printf '%s\n' '22' >"${fixture_state}/cn-entry-ssh-port"

    PROXY_CONF=${case_dir}/proxy.conf
    PROXY_UNIT=${case_dir}/proxy.service
    TUNNEL_UNIT=${case_dir}/tunnel.service
    KNOWN_HOSTS=${case_dir}/known-hosts
    KEY_FILE=${case_dir}/tunnel-key
    ACTIVE_FILE=${case_dir}/ACTIVE
    printf '%s\n' 'Listen 127.0.0.1' 'Port 3128' >"${PROXY_CONF}"
    printf 'ExecStart=/usr/bin/tinyproxy -d -c %s\n' "${PROXY_CONF}" >"${PROXY_UNIT}"
    : >"${TUNNEL_UNIT}"
    : >"${KNOWN_HOSTS}"
    : >"${KEY_FILE}"
    printf '%s\n' "${fixture_state}" >"${ACTIVE_FILE}"

    for function_body in \
        "$(sed -n '/^health_line() {/,/^}/p' "${EXIT_SOURCE}")" \
        "$(sed -n '/^health_group() {/,/^}/p' "${EXIT_SOURCE}")" \
        "$(sed -n '/^health() (/,/^)/p' "${EXIT_SOURCE}")"; do
        [[ -n ${function_body} ]] || { fail '未能提取国外出口健康检查函数'; return 1; }
        eval "${function_body}"
    done

    require_root() { :; }
    health_safe_state() { printf '%s\n' "${fixture_state}"; }
    health_regular_root_file() { return 0; }
    valid_ipv4() { return 0; }
    valid_port() { return 0; }
    systemctl() { return 0; }
    ss() { printf '%s\n' 'LISTEN 0 128 127.0.0.1:3128 0.0.0.0:*'; }
    curl() { return 0; }
    local_ipv4_exists() { return 0; }
    ip() { return 0; }
    ssh-keyscan() { return 0; }

    output=$(health) || { fail '公网地址夹具没有通过国外出口健康检查'; return 1; }
    for expected in '连接路径' '连接记录' '连接路由' '已完成 SSH 握手'; do
        assert_contains "${output}" "${expected}" \
            "公网连接的健康检查缺少通用措辞：${expected}" || return 1
    done
    for stale in '私网连接' '私网路由' '私网 SSH'; do
        assert_not_contains "${output}" "${stale}" \
            "公网连接的健康检查仍显示旧私网措辞：${stale}" || return 1
    done

    function_body=$(sed -n '/^status() {/,/^}/p' "${EXIT_SOURCE}")
    [[ -n ${function_body} ]] || { fail '未能提取国外出口状态函数'; return 1; }
    eval "${function_body}"
    active_state() { printf '%s\n' "${fixture_state}"; }
    output=$(status)
    assert_contains "${output}" '[隧道连接端点]' \
        '国外出口状态没有使用通用连接端点标题' || return 1
    assert_not_contains "${output}" '[私网隧道端点]' \
        '国外出口状态仍把公网地址标成私网端点' || return 1

    function_body=$(sed -n '/^status() {/,/^}/p' "${CN_SOURCE}")
    [[ -n ${function_body} ]] || { fail '未能提取国内入口状态函数'; return 1; }
    eval "${function_body}"
    APT_CONF=${case_dir}/apt.conf
    PROFILE_CONF=${case_dir}/profile.conf
    HELPER=${case_dir}/missing-helper
    output=$(status)
    assert_contains "${output}" '[隧道连接地址]' \
        '国内入口状态没有使用通用连接地址标题' || return 1
    assert_not_contains "${output}" '[直连私网地址]' \
        '国内入口状态仍把公网地址标成直连私网' || return 1

    function_body=$(sed -n '/^repair() {/,/^}/p' "${EXIT_SOURCE}")
    [[ -n ${function_body} ]] || { fail '未能提取国外出口修复函数'; return 1; }
    eval "${function_body}"
    health_safe_state() { printf '%s\n' "${repair_state}"; }
    die() { printf '%s\n' "$*" >&2; exit 1; }
    set +e
    output=$(repair 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail '连接记录缺失时修复没有失败'; return 1; }
    assert_contains "${output}" '连接记录不完整' \
        '修复失败没有使用通用连接记录措辞' || return 1
    assert_not_contains "${output}" '私网连接记录不完整' \
        '修复失败仍把公网记录称为私网记录' || return 1
)

# 「安全修复必须先经用户确认」此前只靠源码文本行号先后来断言：把拒绝分支改成空操作
# 也能全绿。这里实跑 health_check_loaded，按修复命令的实际调用次数判定。
po0_pty_available() {
    [[ -x /usr/bin/script ]]
}

po0_run_in_pty() {
    local typescript=$1 driver=$2
    shift 2
    case "$(uname -s)" in
        Darwin) /usr/bin/script -q "${typescript}" /bin/bash "${driver}" "$@" ;;
        *) /usr/bin/script -qec "/bin/bash ${driver} $*" "${typescript}" ;;
    esac
}

# 等待被测进程建立伪终端后再喂入答案：只有子进程写出 ready 标记，
# 才说明伪终端已经就绪，此时写入的内容一定能被 read 读到。
po0_feed_after_ready() {
    local ready=$1 done_marker=$2 answer=$3 waited=0
    while [[ ! -e ${ready} ]]; do
        (( waited < 600 )) || return 1
        sleep 0.05
        waited=$((waited + 1))
    done
    [[ ${answer} == '<eof>' ]] || printf '%s\n' "${answer}"
    waited=0
    while [[ ! -e ${done_marker} ]]; do
        (( waited < 600 )) || return 1
        sleep 0.05
        waited=$((waited + 1))
    done
}

test_safe_repair_confirmation_at_runtime() (
    local case_dir lib driver log ready done_marker function_body
    local allow answer expected expect_text label repair_calls out
    po0_pty_available || { fail '缺少 script 命令，无法建立伪终端'; return 1; }
    case_dir=$(mktemp -d "${TMPDIR:-/tmp}/po0-repair-confirm.XXXXXXXX")
    trap 'rm -rf -- "${case_dir}"' EXIT
    lib=${case_dir}/lib.sh
    driver=${case_dir}/driver.sh

    function_body=$(sed -n '/^health_check_loaded() (/,/^)/p' "${SETUP_SOURCE}")
    [[ -n ${function_body} ]] || { fail '未能提取健康检查函数'; return 1; }
    {
        printf '%s\n' 'C_BLUE= C_RESET= C_GREEN= C_YELLOW= C_RED='
        printf '%s\n' 'EXIT_CMD_HEALTH=health' 'EXIT_CMD_REPAIR=repair'
        printf '%s\n' 'CN_ENTRY_TIMEOUT_HEALTH=60' 'CN_ENTRY_CMD_HEALTH=health'
        # 国外出口健康检查恒定失败，使流程必然走到「发现需要处理的项目」。
        printf '%s\n' 'run_exit_role() { printf "%s\n" "$1" >>"${PO0_TEST_ROLE_LOG}"; [[ $1 != health ]]; }'
        printf '%s\n' 'start_cn_entry_session() { return 0; }'
        printf '%s\n' 'select_current_cn_entry_role() { :; }'
        printf '%s\n' 'ssh_cn_entry_component() { return 0; }'
        printf '%s\n' 'ssh_cn_entry() { return 0; }'
        printf '%s\n' 'upload_cn_entry_role() { printf "upload\n" >>"${PO0_TEST_ROLE_LOG}"; }'
        printf '%s\n' 'valid_cn_entry_scan_temp_path() { return 1; }'
        printf '%s\n' "${function_body}"
    } >"${lib}"
    /bin/bash -n "${lib}" || { fail '健康检查夹具语法错误'; return 1; }
    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -u'
        printf '%s\n' 'library=$1' 'allow=$2' 'ready=$3' 'done_marker=$4'
        printf '%s\n' '# shellcheck disable=SC1090' 'source "${library}"'
        printf '%s\n' ': >"${ready}"' 'health_check_loaded "${allow}" || true' ': >"${done_marker}"'
    } >"${driver}"

    # allow_repair、答案、期望的修复调用次数、用例说明
    while IFS='|' read -r allow answer expected expect_text label; do
        [[ -n ${allow} ]] || continue
        log=${case_dir}/role-${allow}-${answer//[<>]/}.log
        out=${case_dir}/out-${allow}-${answer//[<>]/}.txt
        ready=${case_dir}/ready-${allow}-${answer//[<>]/}
        done_marker=${case_dir}/done-${allow}-${answer//[<>]/}
        : >"${log}"
        export PO0_TEST_ROLE_LOG=${log}
        if [[ ${answer} == '<notty>' ]]; then
            /bin/bash "${driver}" "${lib}" "${allow}" "${ready}" "${done_marker}" \
                >"${out}" 2>&1 </dev/null
        else
            po0_feed_after_ready "${ready}" "${done_marker}" "${answer}" \
                | po0_run_in_pty /dev/null "${driver}" "${lib}" "${allow}" "${ready}" "${done_marker}" \
                >"${out}" 2>&1
        fi
        [[ -e ${done_marker} ]] || { fail "${label}：被测流程没有正常结束"; return 1; }
        repair_calls=$(grep -Fxc repair "${log}" || true)
        [[ ${repair_calls} == "${expected}" ]] \
            || { fail "${label}：修复命令调用了 ${repair_calls} 次，期望 ${expected} 次"; return 1; }
        grep -Fq -- "${expect_text}" "${out}" \
            || { fail "${label}：输出中缺少「${expect_text}」"; return 1; }
    done <<'CASES'
no|<notty>|0|当前仅生成报告，未做修改。|allow_repair=no 且非交互终端
no|<eof>|0|当前仅生成报告，未做修改。|allow_repair=no 但在交互终端下
yes|<notty>|0|当前仅生成报告，未做修改。|允许修复但不是交互终端
yes|n|0|未执行修复。|交互终端下用户回答 n
yes|<eof>|0|未执行修复。|交互终端下读到 EOF
yes|y|1|【执行安全修复】|交互终端下用户确认 y
CASES
)

test_safe_repair_boundary() {
    local setup_body repair_body
    setup_body=$(sed -n '/^health_check_loaded() (/,/^)/p' "${SETUP_SOURCE}")
    repair_body=$(sed -n '/^repair() {/,/^}/p' "${EXIT_SOURCE}")
    assert_order "${setup_body}" '是否尝试安全修复？[y/N]' \
        'run_exit_role "${EXIT_CMD_REPAIR}"' \
        '未获用户确认就执行了修复' || return 1
    assert_contains "${repair_body}" 'health_regular_root_file "${PROXY_UNIT}" 600' \
        '修复代理前没有验证文件归属' || return 1
    assert_contains "${repair_body}" 'health_regular_root_file "${TUNNEL_UNIT}" 644' \
        '修复隧道前没有验证文件归属' || return 1
    assert_contains "${repair_body}" 'repair_service_state po0-unlock-exit-proxy.service' \
        '安全修复没有覆盖自有代理服务' || return 1
    assert_contains "${repair_body}" 'repair_service_state po0-unlock-reverse-tunnel.service' \
        '安全修复没有覆盖自有隧道服务' || return 1
    assert_contains "${repair_body}" \
        'restore_service_state po0-unlock-exit-proxy.service "${proxy_active}" "${proxy_enabled}"' \
        '部分修复失败后不会恢复代理服务原状态' || return 1
    assert_contains "${repair_body}" \
        'restore_service_state po0-unlock-reverse-tunnel.service "${tunnel_active}" "${tunnel_enabled}"' \
        '部分修复失败后不会恢复隧道服务原状态' || return 1
    for forbidden in apt-get iptables nft 'ip route add' 'write_proxy_files' 'refresh-service'; do
        assert_not_contains "${repair_body}" "${forbidden}" \
            "安全修复越界执行：${forbidden}" || return 1
    done
}

test_service_repair_rollback() (
    local function_body active=no enabled=no fail_enable=no
    function_body=$(sed -n '/^repair_service_state() {/,/^}/p' "${EXIT_SOURCE}")
    [[ -n ${function_body} ]] || { fail '未能提取服务修复函数'; return 1; }
    eval "${function_body}"
    systemctl() {
        case "$1" in
            is-active) [[ ${active} == yes ]] ;;
            is-enabled) [[ ${enabled} == yes ]] ;;
            daemon-reload) return 0 ;;
            enable)
                [[ ${fail_enable} == no ]] || return 1
                enabled=yes
                active=yes
                ;;
            disable) enabled=no ;;
            stop) active=no ;;
            *) return 1 ;;
        esac
    }
    repair_service_state example.service \
        || { fail '可恢复服务没有修复成功'; return 1; }
    [[ ${active} == yes && ${enabled} == yes ]] \
        || { fail '修复后服务没有同时运行并启用'; return 1; }

    active=no
    enabled=no
    fail_enable=yes
    ! repair_service_state example.service \
        || { fail '模拟修复失败却返回成功'; return 1; }
    [[ ${active} == no && ${enabled} == no ]] \
        || { fail '修复失败后没有恢复原停止/禁用状态'; return 1; }
)

test_delayed_tunnel_failure_restores_previous_config() (
    local case_dir fixture_state output rc function_body restart_count check_count
    local scan_tmp_fixture unit_tmp_fixture
    case_dir=$(mktemp -d "${TMPDIR:-/tmp}/po0-tunnel-reconfigure.XXXXXXXX")
    trap 'rm -rf -- "${case_dir}"' EXIT
    fixture_state=${case_dir}/state
    install -d "${fixture_state}"
    TUNNEL_UNIT=${case_dir}/po0-unlock-reverse-tunnel.service
    KNOWN_HOSTS=${case_dir}/po0-unlock-tunnel.known_hosts
    KEY_FILE=${case_dir}/po0-unlock-tunnel
    ADMIN_KEY=${case_dir}/po0-unlock-admin
    TUNNEL_USER=po0tunnel
    printf '%s\n' 'old tunnel unit' >"${TUNNEL_UNIT}"
    printf '%s\n' 'old known hosts' >"${KNOWN_HOSTS}"
    chmod 0644 "${TUNNEL_UNIT}"
    chmod 0600 "${KNOWN_HOSTS}"
    printf '%s\n' 'private key fixture' >"${KEY_FILE}"
    printf '%s\n' 'admin key fixture' >"${ADMIN_KEY}"
    printf '%s\n' '10.0.0.10' >"${fixture_state}/cn-entry-private-ip"
    printf '%s\n' '22' >"${fixture_state}/cn-entry-ssh-port"
    printf '%s\n' '10.0.0.20' >"${fixture_state}/overseas-exit-private-ip"
    restart_count=${case_dir}/restart-count
    check_count=${case_dir}/check-count
    scan_tmp_fixture=${case_dir}/host-key.tmp
    unit_tmp_fixture=${case_dir}/tunnel-unit.tmp
    printf '%s\n' 0 >"${restart_count}"
    printf '%s\n' 0 >"${check_count}"

    for function_body in managed_root_file_safe cleanup_role_temp_files_on_exit \
        tunnel_forward_ready restore_reconfigured_tunnel configure_tunnel; do
        function_body=$(sed -n "/^${function_body}() {/,/^}/p" "${EXIT_SOURCE}")
        [[ -n ${function_body} ]] || { fail '未能提取隧道重配置函数'; return 1; }
        eval "${function_body}"
    done

    require_root() { :; }
    active_state() { printf '%s\n' "${fixture_state}"; }
    valid_ipv4() { return 0; }
    valid_port() { return 0; }
    log() { :; }
    die() { printf '%s\n' "$*" >&2; exit 1; }
    sleep() { :; }
    ip() { printf '%s\n' '2: eth0 inet 10.0.0.20/24 scope global eth0'; }
    ssh-keyscan() { printf '%s\n' '10.0.0.30 ssh-ed25519 AAAATEST'; }
    ssh-keygen() { printf '%s\n' '256 SHA256:test fixture (ED25519)'; }
    stat() {
        [[ ${1:-} == -c ]] || return 1
        case "${2:-}" in
            %u) printf '%s\n' 0 ;;
            %a)
                case $(uname -s) in
                    Darwin) /usr/bin/stat -f '%Lp' "$3" ;;
                    *) /usr/bin/stat -c '%a' "$3" ;;
                esac
                ;;
            %h)
                case $(uname -s) in
                    Darwin) /usr/bin/stat -f '%l' "$3" ;;
                    *) /usr/bin/stat -c '%h' "$3" ;;
                esac
                ;;
            *) return 1 ;;
        esac
    }
    mktemp() {
        case "${1:-}" in
            /tmp/po0-cn-entry-host-key.*)
                : >"${scan_tmp_fixture}"
                printf '%s\n' "${scan_tmp_fixture}"
                ;;
            /tmp/po0-unlock-reverse-tunnel-unit.*)
                : >"${unit_tmp_fixture}"
                printf '%s\n' "${unit_tmp_fixture}"
                ;;
            *) command mktemp "$@" ;;
        esac
    }
    remote_tunnel_listeners_ready() {
        local count
        count=$(<"${restart_count}")
        (( count >= 2 ))
    }
    install() {
        local directory=no mode= operand
        local -a operands=()
        while (( $# > 0 )); do
            case "$1" in
                -d) directory=yes; shift ;;
                -o|-g) shift 2 ;;
                -m) mode=$2; shift 2 ;;
                *) operands[${#operands[@]}]=$1; shift ;;
            esac
        done
        if [[ ${directory} == yes ]]; then
            mkdir -p -- "${operands[0]}"
            chmod "${mode:-755}" "${operands[0]}"
        else
            cp -- "${operands[0]}" "${operands[1]}"
            chmod "${mode:-755}" "${operands[1]}"
        fi
    }
    systemctl() {
        local count checks
        case "${1:-}:${2:-}:${3:-}" in
            is-active:--quiet:po0-unlock-exit-proxy.service) return 0 ;;
            restart:po0-unlock-reverse-tunnel.service:)
                count=$(<"${restart_count}")
                count=$((count + 1))
                printf '%s\n' "${count}" >"${restart_count}"
                return 0
                ;;
            is-active:--quiet:po0-unlock-reverse-tunnel.service)
                count=$(<"${restart_count}")
                if (( count == 1 )); then
                    checks=$(<"${check_count}")
                    checks=$((checks + 1))
                    printf '%s\n' "${checks}" >"${check_count}"
                    (( checks == 1 ))
                    return
                fi
                return 0
                ;;
            show:-p:SubState) printf '%s\n' running ;;
            show:-p:MainPID)
                count=$(<"${restart_count}")
                printf '%s\n' "$((1000 + count))"
                ;;
            daemon-reload::|status:po0-unlock-reverse-tunnel.service:*) return 0 ;;
            *) return 1 ;;
        esac
    }

    output=$(configure_tunnel reconfigure SHA256:test 10.0.0.30 2222 10.0.0.20 2>&1)
    rc=$?
    [[ ${rc} -ne 0 ]] || { fail '新隧道延迟失败后重配置仍报告成功'; return 1; }
    assert_contains "${output}" '已恢复旧配置' \
        '延迟失败后没有明确报告恢复结果' || return 1
    [[ $(<"${TUNNEL_UNIT}") == 'old tunnel unit' ]] \
        || { fail '延迟失败后没有恢复旧隧道单元'; return 1; }
    [[ $(<"${KNOWN_HOSTS}") == 'old known hosts' ]] \
        || { fail '延迟失败后没有恢复旧主机密钥'; return 1; }
    [[ $(<"${restart_count}") == 2 ]] \
        || { fail '恢复旧配置后没有重新启动并验证隧道'; return 1; }
    [[ ! -e ${scan_tmp_fixture} && ! -e ${unit_tmp_fixture} ]] \
        || { fail '隧道重配置失败后遗留了临时文件'; return 1; }
    [[ $(<"${fixture_state}/cn-entry-private-ip") == '10.0.0.10' \
        && $(<"${fixture_state}/cn-entry-ssh-port") == 22 \
        && $(<"${fixture_state}/overseas-exit-private-ip") == '10.0.0.20' ]] \
        || { fail '失败重配置覆盖了最后一次有效连接状态'; return 1; }
)

test_exit_managed_files_reject_symlink_and_hardlink() (
    local case_dir function_body managed_file hardlink symlink victim output rc
    case_dir=$(mktemp -d "${TMPDIR:-/tmp}/po0-exit-managed-files.XXXXXXXX")
    trap 'rm -rf -- "${case_dir}"' EXIT
    function_body=$(
        sed -n '/^managed_root_file_safe() {/,/^}/p' "${EXIT_SOURCE}"
        sed -n '/^health_regular_root_file() {/,/^}/p' "${EXIT_SOURCE}"
        sed -n '/^remove_managed_file() {/,/^}/p' "${EXIT_SOURCE}"
    )
    [[ -n ${function_body} ]] || { fail '未能提取国外出口托管文件校验函数'; return 1; }
    eval "${function_body}"
    die() { printf '%s\n' "$*" >&2; exit 1; }

    stat() {
        [[ ${1:-} == -c ]] || return 1
        case "${2:-}" in
            %u) printf '%s\n' 0 ;;
            %a)
                case $(uname -s) in
                    Darwin) /usr/bin/stat -f '%Lp' "$3" ;;
                    *) /usr/bin/stat -c '%a' "$3" ;;
                esac
                ;;
            %h)
                case $(uname -s) in
                    Darwin) /usr/bin/stat -f '%l' "$3" ;;
                    *) /usr/bin/stat -c '%h' "$3" ;;
                esac
                ;;
            *) return 1 ;;
        esac
    }
    managed_file=${case_dir}/managed
    hardlink=${case_dir}/hardlink
    symlink=${case_dir}/symlink
    victim=${case_dir}/victim
    printf '%s\n' original >"${managed_file}"
    chmod 0600 "${managed_file}"
    ln "${managed_file}" "${hardlink}"
    ! managed_root_file_safe "${managed_file}" 600 \
        || { fail '硬链接托管文件被错误视为安全'; return 1; }
    ! health_regular_root_file "${managed_file}" 600 \
        || { fail '健康检查没有拒绝硬链接托管文件'; return 1; }

    printf '%s\n' protected >"${victim}"
    ln -s "${victim}" "${symlink}"
    ! managed_root_file_safe "${symlink}" 600 \
        || { fail '符号链接托管文件被错误视为安全'; return 1; }
    set +e
    output=$( ( remove_managed_file "${symlink}" 600 ) 2>&1 )
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail '回滚删除仍接受符号链接托管文件'; return 1; }
    [[ -L ${symlink} && $(<"${victim}") == protected ]] \
        || { fail '拒绝删除符号链接时破坏了链接目标'; return 1; }
)

test_tunnel_public_key_permissions_are_rollback_compatible() (
    set -Eeuo pipefail
    local case_dir function_body public_key private_key hardlink symlink victim output rc
    case_dir=$(mktemp -d "${TMPDIR:-/tmp}/po0-tunnel-public-mode.XXXXXXXX")
    trap 'rm -rf -- "${case_dir}"' EXIT
    function_body=$(
        sed -n '/^managed_root_file_safe() {/,/^}/p' "${EXIT_SOURCE}"
        sed -n '/^managed_root_public_key_file_safe() {/,/^}/p' "${EXIT_SOURCE}"
        sed -n '/^protect_tunnel_key_pair() {/,/^}/p' "${EXIT_SOURCE}"
        sed -n '/^remove_managed_public_key_file() {/,/^}/p' "${EXIT_SOURCE}"
    )
    [[ ${function_body} == *'managed_root_public_key_file_safe()'* \
        && ${function_body} == *'protect_tunnel_key_pair()'* \
        && ${function_body} == *'remove_managed_public_key_file()'* ]] \
        || { fail '未能提取隧道公钥权限兼容函数'; return 1; }
    eval "${function_body}"
    die() { printf '%s\n' "$*" >&2; exit 1; }
    stat() {
        [[ ${1:-} == -c ]] || return 1
        case "${2:-}" in
            %u) printf '%s\n' 0 ;;
            %a)
                case $(uname -s) in
                    Darwin) /usr/bin/stat -f '%Lp' "$3" ;;
                    *) /usr/bin/stat -c '%a' "$3" ;;
                esac
                ;;
            %h)
                case $(uname -s) in
                    Darwin) /usr/bin/stat -f '%l' "$3" ;;
                    *) /usr/bin/stat -c '%h' "$3" ;;
                esac
                ;;
            *) return 1 ;;
        esac
    }

    private_key=${case_dir}/po0-unlock-tunnel
    public_key=${private_key}.pub
    KEY_FILE=${private_key}
    printf '%s\n' private >"${private_key}"
    printf '%s\n' public >"${public_key}"
    chmod 0600 "${private_key}" "${public_key}"
    protect_tunnel_key_pair
    [[ $(stat -c %a "${private_key}") == 600 \
        && $(stat -c %a "${public_key}") == 644 ]] \
        || { fail '新隧道密钥对没有收紧为私钥 0600、公钥 0644'; return 1; }

    chmod 0600 "${public_key}"
    remove_managed_public_key_file "${public_key}"
    [[ ! -e ${public_key} && ! -L ${public_key} ]] \
        || { fail '安全的旧版 0600 隧道公钥未被回滚删除'; return 1; }
    printf '%s\n' public >"${public_key}"
    chmod 0644 "${public_key}"
    remove_managed_public_key_file "${public_key}"
    [[ ! -e ${public_key} && ! -L ${public_key} ]] \
        || { fail '当前 0644 隧道公钥未被回滚删除'; return 1; }

    printf '%s\n' public >"${public_key}"
    chmod 0666 "${public_key}"
    set +e
    output=$( ( remove_managed_public_key_file "${public_key}" ) 2>&1 )
    rc=$?
    set -e
    [[ ${rc} -ne 0 && -f ${public_key} ]] \
        || { fail '宽松权限的隧道公钥未被拒绝或被删除'; return 1; }

    chmod 0600 "${public_key}"
    hardlink=${case_dir}/public-hardlink
    ln "${public_key}" "${hardlink}"
    set +e
    output=$( ( remove_managed_public_key_file "${public_key}" ) 2>&1 )
    rc=$?
    set -e
    [[ ${rc} -ne 0 && -f ${public_key} && -f ${hardlink} ]] \
        || { fail '额外硬链接的隧道公钥未被拒绝或被删除'; return 1; }
    rm -f -- "${public_key}" "${hardlink}"

    victim=${case_dir}/victim
    symlink=${public_key}
    printf '%s\n' protected >"${victim}"
    ln -s "${victim}" "${symlink}"
    set +e
    output=$( ( remove_managed_public_key_file "${symlink}" ) 2>&1 )
    rc=$?
    set -e
    [[ ${rc} -ne 0 && -L ${symlink} && $(<"${victim}") == protected ]] \
        || { fail '符号链接隧道公钥未被拒绝或链接目标被破坏'; return 1; }
)

test_tunnel_state_commit_is_transactional() (
    local case_dir state output rc fail_mv=yes function_body name path
    case_dir=$(mktemp -d "${TMPDIR:-/tmp}/po0-state-commit.XXXXXXXX")
    trap 'rm -rf -- "${case_dir}"' EXIT
    state=${case_dir}/state
    mkdir -p -- "${state}"
    chmod 0700 "${state}"
    for name in cn-entry-private-ip cn-entry-ssh-port overseas-exit-private-ip tunnel-configured-at; do
        case "${name}" in
            cn-entry-private-ip) printf '%s\n' 10.0.0.10 >"${state}/${name}" ;;
            cn-entry-ssh-port) printf '%s\n' 22 >"${state}/${name}" ;;
            overseas-exit-private-ip) printf '%s\n' 10.0.0.20 >"${state}/${name}" ;;
            tunnel-configured-at) printf '%s\n' 2026-08-05T00:00:00Z >"${state}/${name}" ;;
        esac
        chmod 0600 "${state}/${name}"
    done

    for name in tunnel_state_record_safe restore_tunnel_state_record commit_tunnel_state; do
        function_body=$(sed -n "/^${name}() {/,/^}/p" "${EXIT_SOURCE}")
        [[ -n ${function_body} ]] || { fail "未能提取状态提交函数：${name}"; return 1; }
        eval "${function_body}"
    done

    stat() {
        [[ ${1:-} == -c ]] || return 1
        case "${2:-}" in
            %u) printf '%s\n' 0 ;;
            %a)
                case $(uname -s) in
                    Darwin) /usr/bin/stat -f '%Lp' "$3" ;;
                    *) /usr/bin/stat -c '%a' "$3" ;;
                esac
                ;;
            %h)
                case $(uname -s) in
                    Darwin) /usr/bin/stat -f '%l' "$3" ;;
                    *) /usr/bin/stat -c '%h' "$3" ;;
                esac
                ;;
            *) return 1 ;;
        esac
    }
    install() {
        local mode=755 source= destination= arg
        while (( $# > 0 )); do
            case "$1" in
                -o|-g) shift 2 ;;
                -m) mode=$2; shift 2 ;;
                *) if [[ -z ${source} ]]; then source=$1; else destination=$1; fi; shift ;;
            esac
        done
        cp -p -- "${source}" "${destination}" && chmod "${mode}" "${destination}"
    }
    mv() {
        local source= destination= arg
        for arg in "$@"; do
            [[ ${arg} == -* ]] && continue
            if [[ -z ${source} ]]; then source=${arg}; else destination=${arg}; fi
        done
        if [[ ${fail_mv} == yes \
            && ${destination} == "${state}/overseas-exit-private-ip" \
            && ${source} == */new-overseas-exit-private-ip ]]; then
            return 1
        fi
        command mv "$@"
    }

    set +e
    output=$(commit_tunnel_state "${state}" 10.0.0.30 2222 10.0.0.40 2026-08-05T01:00:00Z 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail '状态提交中途失败仍返回成功'; return 1; }
    [[ $(<"${state}/cn-entry-private-ip") == 10.0.0.10 \
        && $(<"${state}/cn-entry-ssh-port") == 22 \
        && $(<"${state}/overseas-exit-private-ip") == 10.0.0.20 \
        && $(<"${state}/tunnel-configured-at") == 2026-08-05T00:00:00Z ]] \
        || { fail '状态提交失败后没有恢复全部旧值'; return 1; }
    [[ -z $(find "${state}" -maxdepth 1 -name '.tunnel-state-commit.*' -print -quit) ]] \
        || { fail '状态提交失败后残留事务目录'; return 1; }

    fail_mv=no
    commit_tunnel_state "${state}" 10.0.0.30 2222 10.0.0.40 2026-08-05T01:00:00Z \
        || { fail '没有故障注入时状态事务提交失败'; return 1; }
    [[ $(<"${state}/cn-entry-private-ip") == 10.0.0.30 \
        && $(<"${state}/cn-entry-ssh-port") == 2222 \
        && $(<"${state}/overseas-exit-private-ip") == 10.0.0.40 \
        && $(<"${state}/tunnel-configured-at") == 2026-08-05T01:00:00Z ]] \
        || { fail '状态事务成功后没有整体提交新值'; return 1; }
)

test_exit_traps_cleanup_role_temp_files() (
    local case_dir prepare_body configure_body cleanup_body first_tmp second_tmp rc
    case_dir=$(mktemp -d "${TMPDIR:-/tmp}/po0-exit-cleanup.XXXXXXXX")
    trap 'rm -rf -- "${case_dir}"' EXIT
    prepare_body=$(sed -n '/^prepare() {/,/^}/p' "${EXIT_SOURCE}")
    configure_body=$(sed -n '/^configure_tunnel() {/,/^}/p' "${EXIT_SOURCE}")
    cleanup_body=$(sed -n '/^cleanup_role_temp_files_on_exit() {/,/^}/p' "${EXIT_SOURCE}")
    [[ -n ${prepare_body} && -n ${configure_body} && -n ${cleanup_body} ]] \
        || { fail '未能提取国外出口临时文件清理实现'; return 1; }
    assert_contains "${prepare_body}" \
        'trap '\''cleanup_role_temp_files_on_exit "$?"'\'' EXIT' \
        '代理配置临时文件没有接入 EXIT 清理' || return 1
    assert_contains "${configure_body}" \
        'trap '\''cleanup_role_temp_files_on_exit "$?"'\'' EXIT' \
        '隧道临时文件没有接入 EXIT 清理' || return 1
    assert_not_contains "${prepare_body}${configure_body}" "trap 'rm -f" \
        '国外出口临时文件仍使用 RETURN 清理' || return 1
    assert_not_contains "${prepare_body}${configure_body}" ' RETURN' \
        '国外出口临时文件仍依赖 RETURN 陷阱' || return 1
    assert_order "${prepare_body}" \
        'trap '\''cleanup_role_temp_files_on_exit' \
        'ROLE_TEMP_FILE_ONE=$(mktemp /tmp/po0-unlock-exit-proxy.' \
        '代理配置在安装 EXIT 清理前创建了临时文件' || return 1
    assert_order "${configure_body}" \
        'trap '\''cleanup_role_temp_files_on_exit' \
        'ROLE_TEMP_FILE_ONE=$(mktemp /tmp/po0-cn-entry-host-key.' \
        '隧道配置在安装 EXIT 清理前创建了临时文件' || return 1
    eval "${cleanup_body}"

    first_tmp=${case_dir}/first.tmp
    second_tmp=${case_dir}/second.tmp
    : >"${first_tmp}"
    : >"${second_tmp}"
    set +e
    (
        ROLE_TEMP_FILE_ONE=${first_tmp}
        ROLE_TEMP_FILE_TWO=${second_tmp}
        trap 'cleanup_role_temp_files_on_exit "$?"' EXIT
        exit 73
    )
    rc=$?
    set -e
    [[ ${rc} -eq 73 ]] \
        || { fail 'EXIT 清理改变了原始失败状态'; return 1; }
    [[ ! -e ${first_tmp} && ! -e ${second_tmp} ]] \
        || { fail 'EXIT 清理没有删除全部临时文件'; return 1; }
)

test_tunnel_forward_readiness_requires_remote_listeners() (
    local function_body probe_body probe_runtime_body probe_log probe_args
    local mode=stable mock_substate=running
    local probe_count=0
    function_body=$(sed -n '/^tunnel_forward_ready() {/,/^}/p' "${EXIT_SOURCE}")
    probe_body=$(sed -n '/^remote_tunnel_listeners_ready() {/,/^}/p' "${EXIT_SOURCE}")
    [[ -n ${function_body} && -n ${probe_body} ]] \
        || { fail '未能提取隧道就绪验证函数'; return 1; }
    assert_contains "${probe_body}" '127.0.0.1:13128' \
        '就绪验证没有检查远端 HTTP 反向监听' || return 1
    assert_contains "${probe_body}" '127.0.0.1:19080' \
        '就绪验证没有检查远端 SOCKS 反向监听' || return 1
    assert_contains "${probe_body}" 'StrictHostKeyChecking=yes' \
        '远端监听验证没有保持严格主机密钥校验' || return 1
    assert_contains "${probe_body}" 'UserKnownHostsFile="${KNOWN_HOSTS}"' \
        '远端监听验证没有使用隧道专用 known_hosts' || return 1
    assert_contains "${probe_body}" 'GlobalKnownHostsFile=/dev/null' \
        '远端监听验证仍可能读取系统全局 known_hosts' || return 1

    probe_runtime_body=${probe_body//\/usr\/bin\/ssh/ssh}
    eval "${probe_runtime_body}"
    probe_log=$(mktemp "${TMPDIR:-/tmp}/po0-tunnel-probe.XXXXXXXX")
    trap 'rm -f -- "${probe_log}"' EXIT
    ADMIN_KEY=/tmp/po0-unlock-admin
    KNOWN_HOSTS=/tmp/po0-unlock-tunnel.known_hosts
    ssh() { printf '%s\n' "$*" >"${probe_log}"; return 0; }
    remote_tunnel_listeners_ready 10.0.0.30 2222 10.0.0.20
    probe_args=$(<"${probe_log}")
    assert_contains "${probe_args}" 'UserKnownHostsFile=/tmp/po0-unlock-tunnel.known_hosts' \
        '远端监听探测实际调用没有传入隧道专用 known_hosts' || return 1
    assert_contains "${probe_args}" 'GlobalKnownHostsFile=/dev/null' \
        '远端监听探测实际调用仍读取系统全局 known_hosts' || return 1
    eval "${function_body}"

    sleep() { :; }
    systemctl() {
        case "${1:-}:${2:-}:${3:-}" in
            is-active:--quiet:po0-unlock-reverse-tunnel.service) return 0 ;;
            show:-p:SubState) printf '%s\n' "${mock_substate}" ;;
            show:-p:MainPID)
                if [[ ${mode} == restarting ]]; then
                    printf '%s\n' "$((2000 + probe_count))"
                else
                    printf '%s\n' 2000
                fi
                ;;
            *) return 1 ;;
        esac
    }
    remote_tunnel_listeners_ready() {
        probe_count=$((probe_count + 1))
        [[ ${mode} == ready || ${mode} == restarting ]]
    }

    mode=silent
    ! tunnel_forward_ready 10.0.0.30 2222 10.0.0.20 \
        || { fail '远端监听缺失时隧道错误报告就绪'; return 1; }
    [[ ${probe_count} -eq 12 ]] \
        || { fail '静默失败场景没有完成有限次数的远端监听重试'; return 1; }

    mode=restarting
    probe_count=0
    ! tunnel_forward_ready 10.0.0.30 2222 10.0.0.20 \
        || { fail '主进程反复变化时隧道错误报告就绪'; return 1; }

    mode=ready
    probe_count=0
    tunnel_forward_ready 10.0.0.30 2222 10.0.0.20 \
        || { fail '稳定服务与完整远端监听未被识别为就绪'; return 1; }
    [[ ${probe_count} -eq 2 ]] \
        || { fail '没有要求同一隧道进程连续两次通过远端监听验证'; return 1; }

    mock_substate=auto-restart
    probe_count=0
    ! tunnel_forward_ready 10.0.0.30 2222 10.0.0.20 \
        || { fail '自动重启状态被错误识别为就绪'; return 1; }
    [[ ${probe_count} -eq 0 ]] \
        || { fail '服务未进入 running 时仍执行了远端监听探测'; return 1; }
)

test_core_connectivity_checks_do_not_require_nc() (
    local case_dir preflight_body verify_body health_body function_body
    local ssh_marker nc_marker curl_log
    case_dir=$(mktemp -d "${TMPDIR:-/tmp}/po0-no-netcat.XXXXXXXX")
    trap 'rm -rf -- "${case_dir}"' EXIT
    ssh_marker=${case_dir}/ssh-called
    nc_marker=${case_dir}/nc-called
    curl_log=${case_dir}/curl.log

    preflight_body=$(sed -n '/^preflight() {/,/^}/p' "${SETUP_SOURCE}")
    verify_body=$(sed -n '/^verify_proxy() {/,/^}/p' "${CN_SOURCE}")
    health_body=$(sed -n '/^health() (/,/^)/p' "${EXIT_SOURCE}")
    assert_not_contains "${preflight_body}" 'nc -' '安装预检仍依赖 nc' || return 1
    assert_not_contains "${verify_body}" 'nc -' '代理验证仍依赖 nc' || return 1
    assert_not_contains "${health_body}" 'nc -' '健康检查仍依赖 nc' || return 1
    assert_contains "${health_body}" 'ssh-keyscan -4 -T 3 -p "${cn_port}" "${cn_ip}"' \
        '健康检查没有改用 SSH 握手探测' || return 1

    function_body=${preflight_body}
    [[ -n ${function_body} ]] || { fail '未能提取安装预检函数'; return 1; }
    eval "${function_body}"
    EXIT_ROLE=${EXIT_SOURCE}
    CN_ENTRY_ROLE_LOCAL=${CN_SOURCE}
    ADMIN_KEY=${case_dir}/admin-key
    EXIT_PRIVATE_IP=10.0.0.20
    CN_ENTRY_PRIVATE_IP=10.0.0.30
    CN_ENTRY_SSH_PORT=2222
    : >"${ADMIN_KEY}"
    require_root() { :; }
    local_ipv4_exists() { return 0; }
    ip() { return 0; }
    ssh_cn_entry() { : >"${ssh_marker}"; return 0; }
    nc() { : >"${nc_marker}"; return 127; }
    die() { printf '%s\n' "$*" >&2; exit 1; }
    preflight
    [[ -f ${ssh_marker} ]] || { fail '安装预检没有执行真实 SSH 验证'; return 1; }
    [[ ! -e ${nc_marker} ]] || { fail '安装预检仍调用了 nc'; return 1; }

    function_body=${verify_body}
    [[ -n ${function_body} ]] || { fail '未能提取代理验证函数'; return 1; }
    eval "${function_body}"
    HTTP_PROXY_URL=http://127.0.0.1:13128
    SOCKS_PROXY_URL=socks5h://127.0.0.1:19080
    active_state() { printf '%s\n' "${case_dir}/state"; }
    curl() { printf '%s\n' "$*" >>"${curl_log}"; return 0; }
    verify_proxy
    [[ $(wc -l <"${curl_log}" | tr -d '[:space:]') == 2 ]] \
        || { fail '代理验证没有分别执行 HTTP 与 SOCKS 出口请求'; return 1; }
    [[ ! -e ${nc_marker} ]] || { fail '代理验证仍调用了 nc'; return 1; }
)

test_proxy_exit_checks_start_in_parallel() (
    set -Eeuo pipefail
    local case_dir function_body result_log attempt proxy_test_mode=success rc
    case_dir=$(mktemp -d "${TMPDIR:-/tmp}/po0-proxy-parallel.XXXXXXXX")
    trap 'rm -rf -- "${case_dir}"' EXIT
    result_log=${case_dir}/results

    function_body=$(sed -n '/^verify_proxy() {/,/^}/p' "${CN_SOURCE}")
    [[ -n ${function_body} ]] || { fail '未能提取代理出口验证函数'; return 1; }
    eval "${function_body}"
    HTTP_PROXY_URL=http://127.0.0.1:13128
    SOCKS_PROXY_URL=socks5h://127.0.0.1:19080
    require_root() { :; }
    active_state() { printf '%s\n' "${case_dir}/state"; }
    die() { printf 'die:%s\n' "$*" >>"${result_log}"; exit 1; }
    curl() {
        local proxy= kind= arg previous=
        for arg in "$@"; do
            if [[ ${previous} == --proxy ]]; then proxy=${arg}; break; fi
            previous=${arg}
        done
        case "${proxy}" in
            "${HTTP_PROXY_URL}") kind=http ;;
            "${SOCKS_PROXY_URL}") kind=socks ;;
            *) printf '%s\n' unknown >>"${result_log}"; return 2 ;;
        esac
        : >"${case_dir}/${kind}.started"
        for ((attempt=0; attempt<300; attempt++)); do
            if [[ -e ${case_dir}/http.started && -e ${case_dir}/socks.started ]]; then
                if [[ ${proxy_test_mode} == "${kind}-fail" ]]; then
                    printf '%s:failed\n' "${kind}" >>"${result_log}"
                    return 28
                fi
                printf '%s:success\n' "${kind}" >>"${result_log}"
                return 0
            fi
            sleep 0.01
        done
        printf '%s:serial-timeout\n' "${kind}" >>"${result_log}"
        return 28
    }

    set +e
    ( verify_proxy ) >/dev/null 2>&1
    rc=$?
    set -e
    [[ ${rc} -eq 0 ]] || { fail '两条代理出口均成功时验证仍失败'; return 1; }
    assert_contains "$(<"${result_log}")" 'http:success' \
        'HTTP 出口检查没有与 SOCKS 检查并行启动' || return 1
    assert_contains "$(<"${result_log}")" 'socks:success' \
        'SOCKS 出口检查没有与 HTTP 检查并行启动' || return 1
    assert_not_contains "$(<"${result_log}")" 'serial-timeout' \
        '两条代理出口检查仍在串行等待' || return 1

    for proxy_test_mode in http-fail socks-fail; do
        rm -f -- "${case_dir}/http.started" "${case_dir}/socks.started"
        : >"${result_log}"
        set +e
        ( verify_proxy ) >/dev/null 2>&1
        rc=$?
        set -e
        [[ ${rc} -ne 0 ]] \
            || { fail "${proxy_test_mode} 场景没有阻止代理验证通过"; return 1; }
        assert_contains "$(<"${result_log}")" 'http:' \
            "${proxy_test_mode} 场景没有等待 HTTP 检查" || return 1
        assert_contains "$(<"${result_log}")" 'socks:' \
            "${proxy_test_mode} 场景没有等待 SOCKS 检查" || return 1
        case "${proxy_test_mode}" in
            http-fail)
                assert_contains "$(<"${result_log}")" 'die:国外出口 HTTP 出口验证失败。' \
                    'HTTP 检查失败没有返回对应错误' || return 1
                ;;
            socks-fail)
                assert_contains "$(<"${result_log}")" 'die:国外出口 SOCKS5 出口验证失败。' \
                    'SOCKS 检查失败没有返回对应错误' || return 1
                ;;
        esac
    done
)

test_tunnel_key_minimum_forwarding_contract() {
    local runtime refresh health exit_source expected_options
    runtime=$(<"${PROJECT_DIR}/src/cn-entry-role/00-runtime.sh.inc")
    refresh=$(sed -n '/^refresh() {/,/^}/p' \
        "${PROJECT_DIR}/src/cn-entry-role/85-role-install-refresh.sh.inc")
    health=$(<"${PROJECT_DIR}/src/cn-entry-role/95-role-status-rollback.sh.inc")
    exit_source=$(<"${EXIT_SOURCE}")
    expected_options='restrict,port-forwarding,permitopen="255.255.255.255:9",permitlisten="127.0.0.1:13128",permitlisten="127.0.0.1:19080"'

    assert_contains "${runtime}" "TUNNEL_KEY_OPTIONS='${expected_options}'" \
        '隧道公钥没有同时关闭跳板目的地并保留所需反向转发' || return 1
    assert_contains "${runtime}" 'printf '\''%s %s\n'\'' "${TUNNEL_KEY_OPTIONS}" "${public_key}"' \
        '新安装没有使用最小权限授权选项' || return 1
    assert_contains "${runtime}" 'case "${options}" in' \
        '旧安装授权迁移没有限制可接受的原始内容' || return 1
    assert_contains "${runtime}" '"${TUNNEL_KEY_OPTIONS_LEGACY}") ;;' \
        '旧版已知授权格式不能安全迁移' || return 1
    assert_contains "${runtime}" \
        "*) die '专用隧道授权限制存在外部修改，拒绝自动覆盖。' ;;" \
        '外部修改后的授权文件仍可能被自动覆盖' || return 1
    assert_order "${refresh}" 'harden_tunnel_authorized_keys' \
        'write_proxy_files "${state}"' \
        '更新连接配置没有在提交代理配置前补齐隧道账户限制' || return 1
    assert_contains "${health}" 'tunnel_authorized_keys_hardened "${tunnel_uid}"' \
        '健康检查没有验证隧道密钥的转发限制' || return 1
    assert_contains "${exit_source}" \
        '-R 127.0.0.1:13128:127.0.0.1:3128 -R 127.0.0.1:19080' \
        '国外出口不再使用授权白名单对应的两个反向转发' || return 1
}

test_legacy_tunnel_key_hardening_runtime() (
    local case_dir function_body current_uid expected_options legacy_options public_key
    local first_hash second_hash drifted before_drift
    case_dir=$(mktemp -d "${TMPDIR:-/tmp}/po0-tunnel-key.XXXXXXXX")
    trap 'rm -rf -- "${case_dir}"' EXIT
    function_body=$(
        sed -n '/^safe_tunnel_authorized_keys_path() {/,/^}/p' "${CN_SOURCE}"
        sed -n '/^tunnel_authorized_keys_hardened() {/,/^}/p' "${CN_SOURCE}"
        sed -n '/^harden_tunnel_authorized_keys() {/,/^}/p' "${CN_SOURCE}"
    )
    [[ -n ${function_body} ]] || { fail '未能提取隧道授权加固函数'; return 1; }
    eval "${function_body}"

    TUNNEL_USER=$(id -un)
    current_uid=$(id -u)
    TUNNEL_HOME=${case_dir}/po0tunnel
    TUNNEL_AUTHORIZED_KEYS=${TUNNEL_HOME}/.ssh/authorized_keys
    legacy_options='no-agent-forwarding,no-X11-forwarding,no-pty,permitlisten="127.0.0.1:13128",permitlisten="127.0.0.1:19080"'
    expected_options='restrict,port-forwarding,permitopen="255.255.255.255:9",permitlisten="127.0.0.1:13128",permitlisten="127.0.0.1:19080"'
    TUNNEL_KEY_OPTIONS_LEGACY=${legacy_options}
    TUNNEL_KEY_OPTIONS=${expected_options}
    public_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureOnlyPublicKey comment preserved'
    install -d -m 0700 "${TUNNEL_HOME}/.ssh"
    printf '%s %s\n' "${legacy_options}" "${public_key}" >"${TUNNEL_AUTHORIZED_KEYS}"
    chmod 0600 "${TUNNEL_AUTHORIZED_KEYS}"

    require_root() { :; }
    die() { printf '%s\n' "$*" >&2; exit 1; }
    log() { :; }
    ssh-keygen() { cat >/dev/null; return 0; }
    chown() { :; }
    stat() {
        [[ ${1:-} == -c ]] || return 1
        case "${2:-}:${3:-}" in
            %u:*) printf '%s\n' "${current_uid}" ;;
            %a:"${TUNNEL_HOME}/.ssh") printf '%s\n' 700 ;;
            %a:"${TUNNEL_AUTHORIZED_KEYS}") printf '%s\n' 600 ;;
            %h:"${TUNNEL_AUTHORIZED_KEYS}") printf '%s\n' 1 ;;
            *) return 1 ;;
        esac
    }

    harden_tunnel_authorized_keys \
        || { fail '已知旧版授权文件无法安全迁移'; return 1; }
    [[ $(<"${TUNNEL_AUTHORIZED_KEYS}") == "${expected_options} ${public_key}" ]] \
        || { fail '迁移后没有逐字保留公钥并写入最小权限选项'; return 1; }
    first_hash=$(sha256sum "${TUNNEL_AUTHORIZED_KEYS}" | awk '{print $1}')
    harden_tunnel_authorized_keys \
        || { fail '已经加固的授权文件不能安全重复检查'; return 1; }
    second_hash=$(sha256sum "${TUNNEL_AUTHORIZED_KEYS}" | awk '{print $1}')
    [[ ${first_hash} == "${second_hash}" ]] \
        || { fail '重复加固改变了已经正确的授权文件'; return 1; }

    drifted="no-pty,permitlisten=\"127.0.0.1:13128\" ${public_key}"
    printf '%s\n' "${drifted}" >"${TUNNEL_AUTHORIZED_KEYS}"
    before_drift=$(<"${TUNNEL_AUTHORIZED_KEYS}")
    if ( harden_tunnel_authorized_keys ) >/dev/null 2>&1; then
        fail '外部修改后的授权限制被自动覆盖'
        return 1
    fi
    [[ $(<"${TUNNEL_AUTHORIZED_KEYS}") == "${before_drift}" ]] \
        || { fail '拒绝迁移时仍改变了外部授权内容'; return 1; }

    rm -f -- "${TUNNEL_AUTHORIZED_KEYS}"
    printf '%s\n' "${legacy_options} ${public_key}" >"${case_dir}/symlink-target"
    ln -s "${case_dir}/symlink-target" "${TUNNEL_AUTHORIZED_KEYS}"
    if ( harden_tunnel_authorized_keys ) >/dev/null 2>&1; then
        fail '符号链接授权文件被自动迁移'
        return 1
    fi
    [[ $(<"${case_dir}/symlink-target") == "${legacy_options} ${public_key}" ]] \
        || { fail '拒绝符号链接时改变了链接目标'; return 1; }
)

test_prepare_key_validation_has_no_side_effects() (
    local case_dir function_name function_body mode output rc validation_marker mutation_marker
    case_dir=$(mktemp -d "${TMPDIR:-/tmp}/po0-prepare-key.XXXXXXXX")
    trap 'rm -rf -- "${case_dir}"' EXIT
    for function_name in \
        managed_root_file_safe managed_root_directory_safe prepare_root_directory \
        create_install_state_directory commit_initial_active_state valid_install_claim \
        install_claim_record_safe write_install_claim prepare; do
        case "${function_name}" in
            commit_initial_active_state)
                function_body=$(sed -n "/^${function_name}() (/,/^)/p" "${CN_SOURCE}")
                ;;
            *)
                function_body=$(sed -n "/^${function_name}() {/,/^}/p" "${CN_SOURCE}")
                ;;
        esac
        [[ -n ${function_body} ]] \
            || { fail "未能提取国内入口 ${function_name} 函数"; return 1; }
        eval "${function_body}"
    done

    STATE_ROOT=${case_dir}/state
    ACTIVE_FILE=${STATE_ROOT}/ACTIVE
    TUNNEL_USER=po0tunnel
    TUNNEL_HOME=${case_dir}/po0tunnel
    TUNNEL_AUTHORIZED_KEYS=${TUNNEL_HOME}/.ssh/authorized_keys
    TUNNEL_KEY_OPTIONS='fixture-options'
    APT_CONF=${case_dir}/apt.conf
    PROFILE_CONF=${case_dir}/profile.sh
    HELPER=${case_dir}/helper
    validation_marker=${case_dir}/ssh-keygen-called
    mutation_marker=${case_dir}/first-write-called

    require_root() { :; }
    die() { printf '%s\n' "$*" >&2; exit 1; }
    id() { return 1; }
    base64() {
        [[ ${1:-} == -d ]] || return 2
        cat >/dev/null
        case "${KEY_MODE}" in
            invalid-base64) return 1 ;;
            invalid-key) printf '%s' 'not-an-ssh-public-key' ;;
            multiline)
                printf '%s\n%s' \
                    'ssh-ed25519 AAAAFixtureOne' \
                    'ssh-ed25519 AAAAFixtureTwo'
                ;;
            valid) printf '%s' 'ssh-ed25519 AAAAFixtureValid' ;;
            *) return 2 ;;
        esac
    }
    ssh-keygen() {
        cat >/dev/null
        : >"${validation_marker}"
        [[ ${KEY_MODE} == valid ]]
    }
    install() {
        : >"${mutation_marker}"
        exit 77
    }

    for mode in invalid-base64 invalid-key multiline; do
        rm -f -- "${validation_marker}" "${mutation_marker}"
        set +e
        output=$(KEY_MODE=${mode} prepare 'encoded-fixture' \
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 2>&1)
        rc=$?
        set -e
        [[ ${rc} -ne 0 ]] || { fail "${mode} 公钥错误报告成功"; return 1; }
        [[ ! -e ${mutation_marker} && ! -e ${STATE_ROOT} && ! -e ${ACTIVE_FILE} ]] \
            || { fail "${mode} 公钥错误仍创建了安装状态"; return 1; }
        case "${mode}" in
            invalid-base64)
                assert_contains "${output}" 'Base64 编码无效' \
                    '无效 Base64 的错误提示不明确' || return 1
                [[ ! -e ${validation_marker} ]] \
                    || { fail 'Base64 解码失败后仍调用了公钥解析器'; return 1; }
                ;;
            invalid-key)
                assert_contains "${output}" '公钥格式无效' \
                    '无效 SSH 公钥的错误提示不明确' || return 1
                [[ -e ${validation_marker} ]] \
                    || { fail '无效 SSH 公钥没有经过格式验证'; return 1; }
                ;;
            multiline)
                assert_contains "${output}" '唯一一条非空记录' \
                    '多行 SSH 公钥没有被明确拒绝' || return 1
                [[ ! -e ${validation_marker} ]] \
                    || { fail '多行输入仍进入了单条公钥解析'; return 1; }
                ;;
        esac
    done

    rm -f -- "${validation_marker}" "${mutation_marker}"
    set +e
    output=$(KEY_MODE=valid prepare 'encoded-fixture' \
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 2>&1)
    rc=$?
    set -e
    [[ ${rc} -eq 77 && -e ${validation_marker} && -e ${mutation_marker} ]] \
        || { fail '有效公钥没有在通过验证后进入首个写入步骤'; return 1; }
)

test_prepare_rejects_unsafe_initialization_paths_before_writes() (
    set -Eeuo pipefail
    local case_dir function_body output rc mutation_marker victim path

    case_dir=$(mktemp -d "${TMPDIR:-/tmp}/po0-prepare-paths.XXXXXXXX")
    trap 'rm -rf -- "${case_dir}"' EXIT
    mutation_marker=${case_dir}/first-write-called
    victim=${case_dir}/link-target

    require_root() { :; }
    die() { printf '%s\n' "$*" >&2; exit 1; }
    install() { : >"${mutation_marker}"; exit 77; }
    log() { :; }

    function_body=$(sed -n '/^prepare() {/,/^}/p' "${EXIT_SOURCE}")
    [[ -n ${function_body} ]] || { fail '未能提取国外出口 prepare 函数'; return 1; }
    eval "${function_body}"
    STATE_ROOT=${case_dir}/exit-state
    ACTIVE_FILE=${STATE_ROOT}/ACTIVE
    KEY_FILE=${case_dir}/exit-ssh/po0-unlock-tunnel
    ADMIN_KEY=${case_dir}/exit-ssh/po0-unlock-admin
    KNOWN_HOSTS=${case_dir}/exit-ssh/tunnel.known-hosts
    PROXY_CONF=${case_dir}/tinyproxy.conf
    PROXY_UNIT=${case_dir}/proxy.service
    TUNNEL_UNIT=${case_dir}/tunnel.service

    mkdir -p "${STATE_ROOT}" "${KEY_FILE%/*}"
    ln -s "${victim}" "${ACTIVE_FILE}"
    set +e
    output=$(prepare 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail '国外出口接受了悬空 ACTIVE 符号链接'; return 1; }
    [[ ! -e ${mutation_marker} && ! -e ${victim} ]] \
        || { fail '国外出口拒绝悬空 ACTIVE 前已经开始写入'; return 1; }

    rm -f -- "${ACTIVE_FILE}" "${mutation_marker}" "${victim}"
    ln -s "${victim}" "${KEY_FILE}.pub"
    set +e
    output=$(prepare 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail '国外出口接受了悬空隧道公钥路径'; return 1; }
    [[ ! -e ${mutation_marker} && ! -e ${victim} ]] \
        || { fail '国外出口拒绝悬空隧道公钥前已经开始写入'; return 1; }

    unset -f prepare
    function_body=$(sed -n '/^prepare() {/,/^}/p' "${CN_SOURCE}")
    [[ -n ${function_body} ]] || { fail '未能提取国内入口 prepare 函数'; return 1; }
    eval "${function_body}"
    STATE_ROOT=${case_dir}/cn-state
    ACTIVE_FILE=${STATE_ROOT}/ACTIVE
    TUNNEL_USER=po0tunnel
    TUNNEL_HOME=${case_dir}/po0tunnel
    TUNNEL_AUTHORIZED_KEYS=${TUNNEL_HOME}/.ssh/authorized_keys
    TUNNEL_KEY_OPTIONS='fixture-options'
    APT_CONF=${case_dir}/apt.conf
    PROFILE_CONF=${case_dir}/profile.sh
    HELPER=${case_dir}/helper
    valid_install_claim() {
        [[ ${1:-} =~ ^[0-9a-f]{64}$ ]]
    }
    id() { return 1; }
    base64() { cat >/dev/null; printf '%s' 'ssh-ed25519 AAAAFixtureValid'; }
    ssh-keygen() { cat >/dev/null; return 0; }

    mkdir -p "${STATE_ROOT}"
    for path in "${ACTIVE_FILE}" "${APT_CONF}" "${PROFILE_CONF}" "${HELPER}" "${TUNNEL_HOME}"; do
        rm -f -- "${ACTIVE_FILE}" "${APT_CONF}" "${PROFILE_CONF}" "${HELPER}" \
            "${TUNNEL_HOME}" "${mutation_marker}" "${victim}"
        ln -s "${victim}" "${path}"
        set +e
        output=$(prepare 'encoded-fixture' \
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 2>&1)
        rc=$?
        set -e
        [[ ${rc} -ne 0 ]] || { fail "国内入口接受了悬空初始化路径：${path}"; return 1; }
        [[ ! -e ${mutation_marker} && ! -e ${victim} ]] \
            || { fail "国内入口拒绝悬空初始化路径前已经开始写入：${path}"; return 1; }
    done
)

test_initial_active_state_commit_is_atomic_and_protected() (
    set -Eeuo pipefail
    local source label case_dir state function_name function_body output rc residue
    for source in "${EXIT_SOURCE}" "${CN_SOURCE}"; do
        case "${source}" in
            "${EXIT_SOURCE}") label='exit' ;;
            *) label=cn ;;
        esac
        (
            set -Eeuo pipefail
            case_dir=$(mktemp -d "${TMPDIR:-/tmp}/po0-active-${label}.XXXXXXXX")
            trap 'rm -rf -- "${case_dir}"' EXIT
            STATE_ROOT=${case_dir}/state-root
            ACTIVE_FILE=${STATE_ROOT}/ACTIVE
            state=${STATE_ROOT}/20260805T010203Z
            mkdir -p "${state}"
            chmod 0700 "${STATE_ROOT}" "${state}"
            die() { printf '%s\n' "$*" >&2; exit 1; }
            mode_of_path() {
                case $(uname -s) in
                    Darwin) /usr/bin/stat -f '%Lp' "$1" ;;
                    *) /usr/bin/stat -c '%a' "$1" ;;
                esac
            }
            stat() {
                local format file
                [[ ${1:-} == -c ]] || { command stat "$@"; return; }
                format=${2:-}
                file=${3:-}
                case "${format}" in
                    %u) printf '%s\n' 0 ;;
                    %a) mode_of_path "${file}" ;;
                    %h)
                        case $(uname -s) in
                            Darwin) /usr/bin/stat -f '%l' "${file}" ;;
                            *) /usr/bin/stat -c '%h' "${file}" ;;
                        esac
                        ;;
                    *) return 2 ;;
                esac
            }
            MOVE_SHOULD_FAIL=no
            mv() {
                local -a operands=()
                while (( $# > 0 )); do
                    case "$1" in
                        -f|-T|-fT|-Tf|--) shift ;;
                        *) operands[${#operands[@]}]=$1; shift ;;
                    esac
                done
                [[ ${MOVE_SHOULD_FAIL} != yes ]] || return 91
                /bin/mv -f -- "${operands[0]}" "${operands[1]}"
            }
            for function_name in \
                managed_root_file_safe managed_root_directory_safe commit_initial_active_state; do
                case "${function_name}" in
                    commit_initial_active_state)
                        function_body=$(sed -n "/^${function_name}() (/,/^)/p" "${source}")
                        ;;
                    *)
                        function_body=$(sed -n "/^${function_name}() {/,/^}/p" "${source}")
                        ;;
                esac
                [[ -n ${function_body} ]] \
                    || { fail "未能从 ${label} 组件提取 ${function_name}"; exit 1; }
                eval "${function_body}"
            done

            commit_initial_active_state "${state}"
            [[ -f ${ACTIVE_FILE} && ! -L ${ACTIVE_FILE} ]] \
                || { fail "${label} ACTIVE 不是普通文件"; exit 1; }
            [[ $(<"${ACTIVE_FILE}") == "${state}" && $(mode_of_path "${ACTIVE_FILE}") == 600 ]] \
                || { fail "${label} ACTIVE 内容或权限异常"; exit 1; }
            residue=$(find "${STATE_ROOT}" -maxdepth 1 -name '.ACTIVE.*' -print)
            [[ -z ${residue} ]] \
                || { fail "${label} ACTIVE 成功提交后残留临时文件"; exit 1; }

            rm -f -- "${ACTIVE_FILE}"
            MOVE_SHOULD_FAIL=yes
            set +e
            output=$(commit_initial_active_state "${state}" 2>&1)
            rc=$?
            set -e
            [[ ${rc} -ne 0 && ! -e ${ACTIVE_FILE} && ! -L ${ACTIVE_FILE} ]] \
                || { fail "${label} ACTIVE 原子移动失败后仍留下正式状态"; exit 1; }
            residue=$(find "${STATE_ROOT}" -maxdepth 1 -name '.ACTIVE.*' -print)
            [[ -z ${residue} ]] \
                || { fail "${label} ACTIVE 原子移动失败后残留临时文件"; exit 1; }
        ) || return 1
    done
)

test_ipv4_validation_rejects_overflow_segments() (
    local source label function_body ip
    for source in "${SETUP_SOURCE}" "${EXIT_SOURCE}" "${CN_SOURCE}"; do
        case "${source}" in
            "${SETUP_SOURCE}") label='主控脚本' ;;
            "${EXIT_SOURCE}") label='国外出口组件' ;;
            *) label='国内入口组件' ;;
        esac
        function_body=$(sed -n '/^valid_ipv4() {/,/^}/p' "${source}")
        [[ -n ${function_body} ]] \
            || { fail "未能提取${label}的 IPv4 校验函数"; return 1; }
        unset -f valid_ipv4 2>/dev/null || true
        eval "${function_body}"

        for ip in 0.0.0.0 10.0.0.1 255.255.255.255; do
            valid_ipv4 "${ip}" \
                || { fail "${label}拒绝了有效 IPv4：${ip}"; return 1; }
        done
        for ip in \
            18446744073709551617.0.0.1 \
            0000.0.0.1 \
            256.0.0.1 \
            1.2.3 \
            1.2.3.4.; do
            ! valid_ipv4 "${ip}" \
                || { fail "${label}接受了无效 IPv4：${ip}"; return 1; }
        done
    done

    source=${PROJECT_DIR}/src/cn-entry-role/10-helper-identity.sh.inc
    function_body=$(sed -n '/^valid_helper_ipv4() {/,/^}/p' "${source}")
    [[ -n ${function_body} ]] \
        || { fail '未能提取底层助手的 IPv4 校验函数'; return 1; }
    eval "${function_body}"
    valid_helper_ipv4 8.8.8.8 \
        || { fail '底层助手拒绝了有效 IPv4'; return 1; }
    for ip in 18446744073709551617.0.0.1 0000.0.0.1 256.0.0.1; do
        ! valid_helper_ipv4 "${ip}" \
            || { fail "底层助手接受了无效 IPv4：${ip}"; return 1; }
    done
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
    printf '%s\n' '一键健康检查与安全修复验收：'
    run_case '普通用户菜单、直接命令与返回行为' test_user_interface_contract
    run_case '检查阶段保持完全只读' test_read_only_check_contract
    run_case '两端核心连接、配置、Agent 与旧残留检查完整' test_health_scope_contract
    run_case '两端健康返回码只保留真实可达状态' test_health_return_code_contract
    run_case 'SSH 对端临时路径严格限制为 mktemp 固定格式' test_remote_temp_paths_are_strictly_validated
    run_case '检查结果不依赖终端列宽并按职责分组' test_readable_layout_contract
    run_case '公网连接的检查、状态与修复使用通用措辞' test_public_connection_path_uses_generic_copy
    run_case '安全修复的用户确认闸门实跑验证' test_safe_repair_confirmation_at_runtime
    run_case '自动修复严格限制在确认后的自有核心服务' test_safe_repair_boundary
    run_case '服务修复失败会恢复原运行与启用状态' test_service_repair_rollback
    run_case '隧道延迟失败会恢复上一份有效配置' test_delayed_tunnel_failure_restores_previous_config
    run_case '国外出口托管文件拒绝符号链接与硬链接' test_exit_managed_files_reject_symlink_and_hardlink
    run_case '隧道公钥新权限与旧版回滚兼容' test_tunnel_public_key_permissions_are_rollback_compatible
    run_case '隧道连接状态提交具有完整事务回滚' test_tunnel_state_commit_is_transactional
    run_case '异常退出保留状态并清理国外出口临时文件' test_exit_traps_cleanup_role_temp_files
    run_case '隧道就绪要求稳定进程与完整远端监听' test_tunnel_forward_readiness_requires_remote_listeners
    run_case '核心连通性检查不依赖 nc' test_core_connectivity_checks_do_not_require_nc
    run_case 'HTTP 与 SOCKS 出口检查并行启动' test_proxy_exit_checks_start_in_parallel
    run_case '隧道密钥仅允许两个回环反向转发' test_tunnel_key_minimum_forwarding_contract
    run_case '旧版隧道授权可安全迁移且保护外部修改' test_legacy_tunnel_key_hardening_runtime
    run_case '公钥错误在创建安装状态前被拒绝' test_prepare_key_validation_has_no_side_effects
    run_case '初始化路径异常在任何写入前被拒绝' test_prepare_rejects_unsafe_initialization_paths_before_writes
    run_case 'ACTIVE 初始状态受保护并原子提交' test_initial_active_state_commit_is_atomic_and_protected
    run_case '所有组件拒绝超长或越界 IPv4 数字段' test_ipv4_validation_rejects_overflow_segments
    printf '结果：%d 通过，%d 失败\n' "${PASS_COUNT}" "${FAIL_COUNT}"
    (( FAIL_COUNT == 0 ))
}

main "$@"
