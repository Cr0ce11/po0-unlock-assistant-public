#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

TOOLS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE_DIR=${TOOLS_DIR%/tools}
SETUP_SOURCE=${SOURCE_DIR}/setup.sh
EXIT_SOURCE=${SOURCE_DIR}/overseas-exit-role.sh
CN_ENTRY_SOURCE=${SOURCE_DIR}/cn-entry-role.sh
CN_ENTRY_BUILDER=${TOOLS_DIR}/build-cn-entry-role.sh
OUTPUT=${SOURCE_DIR}/po0-unlock.sh
BACKUP_DIR=${SOURCE_DIR}-backups/bundle-history
BACKUP_RETENTION_LIMIT=10
SCRIPT_VERSION=${1:-2.5.20}

[[ ${SCRIPT_VERSION} =~ ^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$ ]] \
    || { printf '%s\n' '版本号必须使用 x.y.z 格式。' >&2; exit 2; }

[[ -r ${CN_ENTRY_BUILDER} ]] || { printf '缺少国内入口模块构建器：%s\n' "${CN_ENTRY_BUILDER}" >&2; exit 1; }
/bin/bash "${CN_ENTRY_BUILDER}" --build >/dev/null

for source_file in "${SETUP_SOURCE}" "${EXIT_SOURCE}" "${CN_ENTRY_SOURCE}"; do
    [[ -r ${source_file} ]] || { printf '缺少源文件：%s\n' "${source_file}" >&2; exit 1; }
    /bin/bash -n "${source_file}"
done

EXIT_DELIMITER=__PO0_OVERSEAS_EXIT_ROLE_783424F8_PAYLOAD__
CN_ENTRY_DELIMITER=__PO0_CN_ENTRY_ROLE_018D57A1_PAYLOAD__
grep -Fq -- "${EXIT_DELIMITER}" "${EXIT_SOURCE}" \
    && { printf '%s\n' '国外出口组件与内嵌结束标记冲突。' >&2; exit 1; }
grep -Fq -- "${CN_ENTRY_DELIMITER}" "${CN_ENTRY_SOURCE}" \
    && { printf '%s\n' '国内入口组件与内嵌结束标记冲突。' >&2; exit 1; }

EXIT_HASH=$(sha256sum "${EXIT_SOURCE}" | awk '{print $1}')
CN_ENTRY_HASH=$(sha256sum "${CN_ENTRY_SOURCE}" | awk '{print $1}')
[[ ${EXIT_HASH} =~ ^[0-9a-f]{64}$ && ${CN_ENTRY_HASH} =~ ^[0-9a-f]{64}$ ]] \
    || { printf '%s\n' '无法计算组件 SHA-256。' >&2; exit 1; }

candidate=$(mktemp "${OUTPUT}.tmp.XXXXXX")
cleanup_build() {
    local rc=$?
    trap - EXIT INT TERM HUP
    rm -f -- "${candidate:-}"
    exit "${rc}"
}
trap cleanup_build EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

emit_runtime_support() {
    cat <<'RUNTIME_HEAD'

cleanup_runtime() {
    local rc=${1:-0} directory=${RUNTIME_DIR:-}
    trap - EXIT INT TERM HUP
    set +e
    [[ -n ${EXIT_ROLE:-} ]] && rm -f -- "${EXIT_ROLE}" "${EXIT_ROLE}.new"
    [[ -n ${CN_ENTRY_ROLE_LOCAL:-} ]] && rm -f -- "${CN_ENTRY_ROLE_LOCAL}" "${CN_ENTRY_ROLE_LOCAL}.new"
    if [[ -n ${directory} ]]; then
        case "${directory}" in
            /tmp/po0-unlock.*)
                rm -f -- "${directory}/po0-cn-entry-helper.self-test.sh"
                rmdir -- "${directory}" 2>/dev/null || true
                ;;
            *) printf '警告：拒绝清理异常临时目录：%s\n' "${directory}" >&2 ;;
        esac
    fi
    RUNTIME_DIR=
    EXIT_ROLE=
    CN_ENTRY_ROLE_LOCAL=
    return "${rc}"
}

runtime_exit_cleanup() {
    local rc=$?
    cleanup_runtime "${rc}" || true
    exit "${rc}"
}

# 当前 shell 已经装了 EXIT 陷阱时，不能直接覆盖：安装、回滚、重配置和各类远端
# 操作都靠自己的 EXIT 陷阱回滚事务与清理 SSH 控制会话。改为串接：先清理内置组件，
# 再把退出码还原成原值并调用原处理函数。
runtime_chain_exit_cleanup() {
    local rc=$? handler=$1
    cleanup_runtime "${rc}" || true
    ( exit "${rc}" )
    "${handler}"
    exit "${rc}"
}

install_runtime_exit_trap() {
    local existing handler
    existing=$(trap -p EXIT)
    # bash 在 ( ) 子 shell 里会用 trap -p 显示父 shell 的陷阱，但它在子 shell 内并不生效。
    # 只有归属标记与当前 shell 层级一致时，才说明这确实是本层自己装的陷阱、可以串接；
    # 否则串接会让外层清理在子 shell 退出时提前执行（关闭 SSH 主连接、释放操作锁）。
    po0_exit_trap_scope
    if [[ -z ${existing} ]] \
        || [[ ${PO0_EXIT_TRAP_OWNER:-} != "${PO0_EXIT_TRAP_SCOPE}" ]]; then
        trap runtime_exit_cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap 'exit 129' HUP
        # 记下归属：之后本层若再安装自己的 EXIT 陷阱，需要据此判断
        # 「要被覆盖掉的组件清理陷阱确实是本层装的」，先释放组件再换。
        PO0_EXIT_TRAP_OWNER=${PO0_EXIT_TRAP_SCOPE}
        return 0
    fi
    handler=${existing#trap -- \'}
    handler=${handler%\' EXIT}
    if [[ ${handler} =~ ^[a-z_][a-z0-9_]*$ ]] && declare -F "${handler}" >/dev/null; then
        # 这里要的就是立即展开：handler 是当前这一刻读到的处理函数名，
        # 留到触发时再解析反而会拿到被后续 trap 覆盖后的值。名字已限定为标识符。
        # shellcheck disable=SC2064
        trap "runtime_chain_exit_cleanup ${handler}" EXIT
        return 0
    fi
    # 无法安全串接时保留外层陷阱：宁可留下临时目录，也不能让事务回滚失效。
    printf '警告：已有退出处理无法安全串接，内置组件临时目录将保留：%s\n' \
        "${RUNTIME_DIR:-未知}" >&2
}

materialize_roles() {
    local exit_new cn_entry_new exit_actual cn_entry_actual
    if [[ -n ${RUNTIME_DIR:-} && -r ${EXIT_ROLE:-} && -r ${CN_ENTRY_ROLE_LOCAL:-} ]]; then
        return 0
    fi
    command -v sha256sum >/dev/null || die '系统缺少 sha256sum，无法校验内置组件。'
    RUNTIME_DIR=$(mktemp -d /tmp/po0-unlock.XXXXXXXX) \
        || die '无法创建内置组件临时目录。'
    chmod 0700 "${RUNTIME_DIR}"
    EXIT_ROLE=${RUNTIME_DIR}/overseas-exit-role.sh
    CN_ENTRY_ROLE_LOCAL=${RUNTIME_DIR}/cn-entry-role.sh
    exit_new=${EXIT_ROLE}.new
    cn_entry_new=${CN_ENTRY_ROLE_LOCAL}.new
    install_runtime_exit_trap

    cat >"${exit_new}" <<'__PO0_OVERSEAS_EXIT_ROLE_783424F8_PAYLOAD__'
RUNTIME_HEAD
    sed -n '1,$p' "${EXIT_SOURCE}"
    cat <<'RUNTIME_MIDDLE'
__PO0_OVERSEAS_EXIT_ROLE_783424F8_PAYLOAD__
    cat >"${cn_entry_new}" <<'__PO0_CN_ENTRY_ROLE_018D57A1_PAYLOAD__'
RUNTIME_MIDDLE
    sed -n '1,$p' "${CN_ENTRY_SOURCE}"
    cat <<RUNTIME_TAIL
__PO0_CN_ENTRY_ROLE_018D57A1_PAYLOAD__
    chmod 0600 "\${exit_new}" "\${cn_entry_new}"
    exit_actual=\$(sha256sum "\${exit_new}" | awk '{print \$1}')
    cn_entry_actual=\$(sha256sum "\${cn_entry_new}" | awk '{print \$1}')
    [[ \${exit_actual} == '${EXIT_HASH}' ]] || die '国外出口内置组件哈希校验失败。'
    [[ \${cn_entry_actual} == '${CN_ENTRY_HASH}' ]] || die '国内入口内置组件哈希校验失败。'
    /bin/bash -n "\${exit_new}" || die '国外出口内置组件语法检查失败。'
    /bin/bash -n "\${cn_entry_new}" || die '国内入口内置组件语法检查失败。'
    mv "\${exit_new}" "\${EXIT_ROLE}"
    mv "\${cn_entry_new}" "\${CN_ENTRY_ROLE_LOCAL}"
    chmod 0700 "\${EXIT_ROLE}" "\${CN_ENTRY_ROLE_LOCAL}"
}

extract_embedded_role() {
    materialize_roles
    case "\${1:-}" in
        overseas-exit) sed -n '1,\$p' "\${EXIT_ROLE}" ;;
        cn-entry) sed -n '1,\$p' "\${CN_ENTRY_ROLE_LOCAL}" ;;
        *) die '用法：__extract-role overseas-exit|cn-entry' ;;
    esac
}

bundle_self_test() {
    local helper_test helper_shebang
    /bin/bash -n "\${SCRIPT_PATH}" || die '单文件主控语法检查失败。'
    materialize_roles
    helper_test="\${RUNTIME_DIR}/po0-cn-entry-helper.self-test.sh"
    awk 'index(\$0, "cat >\\"\${tmp}\\" <<\\047EOF\\047") {f=1; next} f && \$0=="EOF" {exit} f {print}' \
        "\${CN_ENTRY_ROLE_LOCAL}" >"\${helper_test}"
    [[ -s \${helper_test} ]] || die '未能从国内入口组件提取 po0-cn-entry helper。'
    IFS= read -r helper_shebang <"\${helper_test}"
    [[ \${helper_shebang} == '#!/usr/bin/env bash' ]] \
        || die '国内入口生成的 po0-cn-entry helper 缺少有效 shebang。'
    /bin/bash -n "\${helper_test}" \
        || die '国内入口生成的 po0-cn-entry helper 语法检查失败。'
    rm -f -- "\${helper_test}"
    printf 'Po0 单文件版本=%s\\n' '${SCRIPT_VERSION}'
    printf 'Po0 单文件版本类型=%s\\n' "\${SCRIPT_EDITION_LABEL}"
    printf 'overseas-exit-role SHA-256=%s\\n' '${EXIT_HASH}'
    printf 'cn-entry-role SHA-256=%s\\n' '${CN_ENTRY_HASH}'
    printf '%s\\n' \
        "scan-agents -> cn-entry:\${CN_ENTRY_CMD_SCAN}" \
        "rollback[1] -> cn-entry:\${CN_ENTRY_CMD_ROLLBACK_SERVICES}" \
        "rollback[2] -> overseas-exit:\${EXIT_CMD_ROLLBACK}" \
        "rollback[3] -> cn-entry:\${CN_ENTRY_CMD_ROLLBACK_FINALIZE}" \
        "status -> cn-entry:\${CN_ENTRY_CMD_STATUS}" \
        "status -> overseas-exit:\${EXIT_CMD_STATUS}" \
        "health -> cn-entry:\${CN_ENTRY_CMD_HEALTH}" \
        "health -> overseas-exit:\${EXIT_CMD_HEALTH}" \
        "repair -> overseas-exit:\${EXIT_CMD_REPAIR}"
    printf '%s\\n' 'SELF_TEST=PASS'
}
RUNTIME_TAIL
}

assert_build_pattern_count() {
    local pattern=$1 expected=$2 actual=$3
    [[ ${actual} == "${expected}" ]] || {
        printf '单文件构建匹配计数异常：%s，期望 %s 次，实际 %s 次。\n' \
            "${pattern}" "${expected}" "${actual}" >&2
        exit 1
    }
}

assert_candidate_line_count() {
    local pattern=$1 expected=$2 actual
    actual=$(grep -Fxc -- "${pattern}" "${candidate}" || true)
    [[ ${actual} == "${expected}" ]] || {
        printf '单文件构建语义校验失败：%s，期望 %s 次，实际 %s 次。\n' \
            "${pattern}" "${expected}" "${actual}" >&2
        exit 1
    }
}

assert_candidate_function_materialization() {
    local function_name=$1 opening=$2 closing=$3 body actual
    body=$(awk -v start="${function_name}() ${opening}" -v finish="${closing}" '
        $0 == start {
            starts++
            active=1
        }
        active { print }
        active && $0 == finish {
            active=0
            finishes++
        }
        END {
            if (starts != 1 || finishes != 1 || active) exit 1
        }
    ' "${candidate}") || {
        printf '单文件构建语义校验失败：无法唯一识别 %s 函数体。\n' \
            "${function_name}" >&2
        exit 1
    }
    actual=$(grep -Fxc -- '    materialize_roles' <<<"${body}" || true)
    [[ ${actual} == 1 ]] || {
        printf '单文件构建语义校验失败：%s 函数中的 materialize_roles 期望 1 次，实际 %s 次。\n' \
            "${function_name}" "${actual}" >&2
        exit 1
    }
}

in_preflight=no
in_health_check=no
in_diagnostic_report=no
source_ref='${SCRIPT_DIR}/cn-entry-role.sh'
bundle_ref='${CN_ENTRY_ROLE_LOCAL}'
match_runtime_comment=0
match_script_version=0
match_edition_label=0
match_exit_role=0
match_cn_entry_role=0
match_require_root_definition=0
match_preflight_start=0
match_health_check_start=0
match_diagnostic_report_start=0
match_require_root_call=0
match_usage_authorize=0
match_help_branch=0
while IFS= read -r line || [[ -n ${line} ]]; do
    case "${line}" in
        '# 本脚本必须在国外出口 VPS 上以 root 运行。')
            match_runtime_comment=$((match_runtime_comment + 1))
            printf '%s\n' "${line}"
            ;;
        'SCRIPT_VERSION=${SCRIPT_VERSION:-dev}')
            match_script_version=$((match_script_version + 1))
            printf 'SCRIPT_VERSION=%q\n' "${SCRIPT_VERSION}"
            ;;
        'SCRIPT_EDITION_LABEL=公开版')
            match_edition_label=$((match_edition_label + 1))
            printf '%s\n' 'SCRIPT_EDITION_LABEL=公开版'
            ;;
        'EXIT_ROLE=${SCRIPT_DIR}/overseas-exit-role.sh')
            match_exit_role=$((match_exit_role + 1))
            printf '%s\n' 'RUNTIME_DIR=' 'EXIT_ROLE='
            ;;
        'CN_ENTRY_ROLE_LOCAL=${SCRIPT_DIR}/cn-entry-role.sh')
            match_cn_entry_role=$((match_cn_entry_role + 1))
            printf '%s\n' 'CN_ENTRY_ROLE_LOCAL='
            ;;
        'require_root() '*)
            match_require_root_definition=$((match_require_root_definition + 1))
            printf '%s\n' "${line}"
            emit_runtime_support
            ;;
        'preflight() {')
            match_preflight_start=$((match_preflight_start + 1))
            in_preflight=yes
            printf '%s\n' "${line}"
            ;;
        'health_check() (')
            match_health_check_start=$((match_health_check_start + 1))
            in_health_check=yes
            printf '%s\n' "${line}"
            ;;
        'diagnostic_report() (')
            match_diagnostic_report_start=$((match_diagnostic_report_start + 1))
            in_diagnostic_report=yes
            printf '%s\n' "${line}"
            ;;
        '    require_root')
            match_require_root_call=$((match_require_root_call + 1))
            printf '%s\n' "${line}"
            if [[ ${in_preflight} == yes ]]; then
                printf '%s\n' '    materialize_roles'
                in_preflight=no
            elif [[ ${in_health_check} == yes ]]; then
                printf '%s\n' '    materialize_roles'
                in_health_check=no
            elif [[ ${in_diagnostic_report} == yes ]]; then
                printf '%s\n' '    materialize_roles'
                in_diagnostic_report=no
            fi
            ;;
        '  ./${PROGRAM_NAME} authorize')
            match_usage_authorize=$((match_usage_authorize + 1))
            printf '%s\n' "${line}"
            printf '%s\n' '  ./${PROGRAM_NAME} self-test'
            ;;
        '    help|-h|--help) usage ;;')
            match_help_branch=$((match_help_branch + 1))
            printf '%s\n' '    self-test) bundle_self_test ;;'
            printf '%s\n' '    __extract-role) extract_embedded_role "${2:-}" ;;'
            printf '%s\n' "${line}"
            ;;
        *)
            line=${line//"${source_ref}"/"${bundle_ref}"}
            printf '%s\n' "${line}"
            ;;
    esac
done <"${SETUP_SOURCE}" >"${candidate}"

assert_build_pattern_count '# 本脚本必须在国外出口 VPS 上以 root 运行。' 1 "${match_runtime_comment}"
assert_build_pattern_count 'SCRIPT_VERSION=${SCRIPT_VERSION:-dev}' 1 "${match_script_version}"
assert_build_pattern_count 'SCRIPT_EDITION_LABEL=公开版' 1 "${match_edition_label}"
assert_build_pattern_count 'EXIT_ROLE=${SCRIPT_DIR}/overseas-exit-role.sh' 1 "${match_exit_role}"
assert_build_pattern_count 'CN_ENTRY_ROLE_LOCAL=${SCRIPT_DIR}/cn-entry-role.sh' 1 "${match_cn_entry_role}"
assert_build_pattern_count 'require_root() *' 1 "${match_require_root_definition}"
assert_build_pattern_count 'preflight() {' 1 "${match_preflight_start}"
assert_build_pattern_count 'health_check() (' 1 "${match_health_check_start}"
assert_build_pattern_count 'diagnostic_report() (' 1 "${match_diagnostic_report_start}"
assert_build_pattern_count '    require_root' 11 "${match_require_root_call}"
assert_build_pattern_count '  ./${PROGRAM_NAME} authorize' 1 "${match_usage_authorize}"
assert_build_pattern_count '    help|-h|--help) usage ;;' 1 "${match_help_branch}"

chmod 0700 "${candidate}"
/bin/bash -n "${candidate}"
assert_candidate_function_materialization preflight '{' '}'
assert_candidate_function_materialization health_check '(' ')'
assert_candidate_function_materialization diagnostic_report '(' ')'
assert_candidate_line_count 'RUNTIME_DIR=' 1
assert_candidate_line_count 'EXIT_ROLE=' 1
assert_candidate_line_count 'CN_ENTRY_ROLE_LOCAL=' 1
assert_candidate_line_count '    self-test) bundle_self_test ;;' 1
assert_candidate_line_count '    __extract-role) extract_embedded_role "${2:-}" ;;' 1
/bin/bash "${candidate}" self-test >/dev/null
/bin/bash "${candidate}" __extract-role overseas-exit | cmp -s - "${EXIT_SOURCE}"
/bin/bash "${candidate}" __extract-role cn-entry | cmp -s - "${CN_ENTRY_SOURCE}"

if [[ -f ${OUTPUT} && ! -L ${OUTPUT} ]] && cmp -s "${candidate}" "${OUTPUT}"; then
    rm -f -- "${candidate}"
    candidate=
    trap - EXIT INT TERM HUP
    printf '%s\n' '单文件生成物未变化，未创建备份。'
    printf '版本：%s\n' "${SCRIPT_VERSION}"
    sha256sum "${OUTPUT}"
    exit 0
fi

if [[ -f ${OUTPUT} ]]; then
    install -d -m 0700 "${BACKUP_DIR}"
    managed_rows=()
    newest_sequence=0
    shopt -s nullglob
    for path in "${BACKUP_DIR}"/po0-unlock.managed.*; do
        [[ -f ${path} && ! -L ${path} ]] \
            || { printf '拒绝处理异常受管备份：%s\n' "${path}" >&2; exit 1; }
        name=${path##*/}
        sequence=${name#po0-unlock.managed.}
        sequence=${sequence%%.*}
        [[ ${sequence} =~ ^[0-9]{10,}$ ]] \
            || { printf '受管备份序号无效：%s\n' "${path}" >&2; exit 1; }
        managed_rows+=("${sequence}"$'\t'"${path}")
        (( 10#${sequence} > newest_sequence )) \
            && newest_sequence=$((10#${sequence}))
    done
    shopt -u nullglob

    current_sequence=$(date -u +%s)
    [[ ${current_sequence} =~ ^[0-9]{10,}$ ]] \
        || { printf '%s\n' '无法生成受管备份序号。' >&2; exit 1; }
    if (( current_sequence <= newest_sequence )); then
        current_sequence=$((newest_sequence + 1))
    fi
    previous=$(mktemp \
        "${BACKUP_DIR}/po0-unlock.managed.${current_sequence}.v${SCRIPT_VERSION}.previous.XXXXXXXX")
    cp -p "${OUTPUT}" "${previous}"
    printf '已备份上一单文件版本：%s\n' "${previous}"

    managed_rows+=("${current_sequence}"$'\t'"${previous}")
    remove_count=$((${#managed_rows[@]} - BACKUP_RETENTION_LIMIT))
    if (( remove_count > 0 )); then
        removed=0
        while IFS=$'\t' read -r sequence path; do
            (( removed < remove_count )) || break
            [[ -f ${path} && ! -L ${path} ]] \
                || { printf '拒绝删除异常受管备份：%s\n' "${path}" >&2; exit 1; }
            rm -f -- "${path}"
            removed=$((removed + 1))
        done < <(printf '%s\n' "${managed_rows[@]}" | LC_ALL=C sort -n -k1,1)
        (( removed == remove_count )) \
            || { printf '%s\n' '受管备份保留数量收敛失败。' >&2; exit 1; }
    fi
fi
mv "${candidate}" "${OUTPUT}"
trap - EXIT INT TERM HUP

printf '已生成：%s\n' "${OUTPUT}"
printf '版本：%s\n' "${SCRIPT_VERSION}"
sha256sum "${OUTPUT}"
