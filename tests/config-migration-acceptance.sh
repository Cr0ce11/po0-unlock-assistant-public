#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEMP_BASE=${TMPDIR:-/tmp}
WORK_ROOT=$(mktemp -d "${TEMP_BASE%/}/po0-config-migration.XXXXXXXX")
LIBRARY=${WORK_ROOT}/setup-library.sh
sed '/^ASSUME_YES=no$/,$d' "${PROJECT_DIR}/setup.sh" >"${LIBRARY}"

cleanup() {
    case "${WORK_ROOT}" in
        "${TEMP_BASE%/}"/po0-config-migration.*) rm -rf -- "${WORK_ROOT}" ;;
    esac
}
trap cleanup EXIT INT TERM HUP

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    [[ $1 == "$2" ]] || fail "$3（实际：$1，预期：$2）"
}

portable_mode() {
    if /usr/bin/stat -c '%a' "$1" >/dev/null 2>&1; then
        /usr/bin/stat -c '%a' "$1"
    else
        /usr/bin/stat -f '%Lp' "$1"
    fi
}

portable_links() {
    if /usr/bin/stat -c '%h' "$1" >/dev/null 2>&1; then
        /usr/bin/stat -c '%h' "$1"
    else
        /usr/bin/stat -f '%l' "$1"
    fi
}

portable_stat() {
    local format=$2 path=$3
    if [[ ${format} == %u ]]; then
        if [[ -n ${TEST_NON_ROOT_PATH:-} && ${path} == "${TEST_NON_ROOT_PATH}" ]]; then
            printf '%s\n' 1000
        else
            printf '%s\n' 0
        fi
        return
    fi
    if [[ ${format} == %h && -n ${TEST_EXTRA_LINK_PATH:-} \
        && ${path} == "${TEST_EXTRA_LINK_PATH}" ]]; then
        printf '%s\n' 2
        return
    fi
    case "${format}" in
        %a) portable_mode "${path}" ;;
        %h) portable_links "${path}" ;;
        *) return 2 ;;
    esac
}

portable_install() {
    local directory_mode=no mode=755 source= destination=
    while (( $# > 0 )); do
        case "$1" in
            -d) directory_mode=yes; shift ;;
            -o|-g) shift 2 ;;
            -m) mode=$2; shift 2 ;;
            --) shift; break ;;
            -*) return 2 ;;
            *) break ;;
        esac
    done
    if [[ ${directory_mode} == yes ]]; then
        mkdir -p -- "$@"
        chmod "${mode}" "$@"
        return
    fi
    [[ $# -eq 2 ]] || return 2
    source=$1
    destination=$2
    cp -- "${source}" "${destination}"
    chmod "${mode}" "${destination}"
}

portable_mv() {
    local -a operands=()
    while (( $# > 0 )); do
        case "$1" in
            -f|-T|-fT|-Tf|--) shift ;;
            *) operands[${#operands[@]}]=$1; shift ;;
        esac
    done
    [[ ${#operands[@]} -eq 2 ]] || return 2
    /bin/mv -f -- "${operands[0]}" "${operands[1]}"
}

write_valid_config() {
    local file=$1 ip=${2:-10.0.0.2} port=${3:-22}
    mkdir -p "${file%/*}"
    {
        printf '%s\n' '# 在国外出口 VPS 上使用；不保存任何 SSH 密码。'
        printf '%s\n' 'CN_ENTRY_SSH_USER=root'
        printf 'CN_ENTRY_PRIVATE_IP=%s\n' "${ip}"
        printf 'CN_ENTRY_SSH_PORT=%s\n' "${port}"
    } >"${file}"
    chmod 0600 "${file}"
}

new_case() {
    CASE_DIR=$(mktemp -d "${WORK_ROOT}/case.XXXXXXXX")
    # shellcheck disable=SC1090
    source "${LIBRARY}"
    SCRIPT_VERSION=2.4.0
    CONFIG_DIR=${CASE_DIR}/etc/po0-unlock
    CONFIG_FILE=${CONFIG_DIR}/hosts.conf
    LEGACY_CONFIG_FILE=${CASE_DIR}/root/hosts.conf
    mkdir -p "${LEGACY_CONFIG_FILE%/*}"
    chmod 0700 "${LEGACY_CONFIG_FILE%/*}"
    TEST_NON_ROOT_PATH=
    TEST_EXTRA_LINK_PATH=
    is_root() { return 0; }
    stat() { portable_stat "$@"; }
    install() { portable_install "$@"; }
    chown() { :; }
    mv() { portable_mv "$@"; }
}

test_legacy_config_moves_to_etc() {
    local before output
    new_case
    write_valid_config "${LEGACY_CONFIG_FILE}"
    before=$(sha256sum "${LEGACY_CONFIG_FILE}" | awk '{print $1}')
    output=$(maybe_migrate_config status)
    [[ ${output} == *"${CONFIG_FILE}"* ]] || fail '迁移完成后没有说明新位置'
    [[ ! -e ${LEGACY_CONFIG_FILE} ]] || fail '迁移成功后 /root 旧配置仍然存在'
    [[ -f ${CONFIG_FILE} && ! -L ${CONFIG_FILE} ]] || fail '没有创建正式配置文件'
    assert_eq "$(sha256sum "${CONFIG_FILE}" | awk '{print $1}')" "${before}" '迁移改变了配置内容'
    assert_eq "$(portable_mode "${CONFIG_DIR}")" 700 '配置目录权限不正确'
    assert_eq "$(portable_mode "${CONFIG_FILE}")" 600 '配置文件权限不正确'
}

test_identical_duplicate_cleans_legacy_copy() {
    new_case
    write_valid_config "${LEGACY_CONFIG_FILE}"
    mkdir -p "${CONFIG_DIR}"
    chmod 0700 "${CONFIG_DIR}"
    cp "${LEGACY_CONFIG_FILE}" "${CONFIG_FILE}"
    chmod 0600 "${CONFIG_FILE}"
    migrate_legacy_config >/dev/null
    [[ ! -e ${LEGACY_CONFIG_FILE} ]] || fail '相同的旧配置没有被清理'
    [[ -f ${CONFIG_FILE} ]] || fail '清理相同旧配置时损坏了新配置'
}

test_different_duplicates_are_preserved_and_rejected() {
    local output
    new_case
    write_valid_config "${LEGACY_CONFIG_FILE}" 10.0.0.2
    mkdir -p "${CONFIG_DIR}"
    chmod 0700 "${CONFIG_DIR}"
    write_valid_config "${CONFIG_FILE}" 10.0.0.3
    if output=$(migrate_legacy_config 2>&1); then
        fail '迁移器擅自选择了两份不同配置'
    fi
    [[ ${output} == *'两份内容不同的连接配置'* ]] || fail '配置冲突提示不清楚'
    [[ -f ${LEGACY_CONFIG_FILE} && -f ${CONFIG_FILE} ]] || fail '配置冲突时删除了文件'
}

test_symlink_and_unsafe_metadata_are_rejected() {
    local output victim
    new_case
    victim=${CASE_DIR}/victim
    write_valid_config "${victim}"
    mkdir -p "${LEGACY_CONFIG_FILE%/*}"
    ln -s "${victim}" "${LEGACY_CONFIG_FILE}"
    if output=$(migrate_legacy_config 2>&1); then fail '迁移器接受了旧配置符号链接'; fi
    [[ ${output} == *'不是可安全读取的普通文件'* ]] || fail '符号链接拒绝提示不清楚'

    new_case
    write_valid_config "${LEGACY_CONFIG_FILE}"
    chmod 0644 "${LEGACY_CONFIG_FILE}"
    if output=$(migrate_legacy_config 2>&1); then fail '迁移器接受了宽松权限'; fi
    [[ ${output} == *'权限必须是 0600'* ]] || fail '宽松权限拒绝提示不清楚'

    new_case
    write_valid_config "${LEGACY_CONFIG_FILE}"
    TEST_NON_ROOT_PATH=${LEGACY_CONFIG_FILE}
    if output=$(migrate_legacy_config 2>&1); then fail '迁移器接受了非 root 配置'; fi
    [[ ${output} == *'不属于 root'* ]] || fail '错误属主拒绝提示不清楚'

    new_case
    write_valid_config "${LEGACY_CONFIG_FILE}"
    TEST_EXTRA_LINK_PATH=${LEGACY_CONFIG_FILE}
    if output=$(migrate_legacy_config 2>&1); then fail '迁移器接受了异常硬链接'; fi
    [[ ${output} == *'异常硬链接'* ]] || fail '异常硬链接拒绝提示不清楚'
}

test_existing_unsafe_config_directory_is_rejected() {
    local output
    new_case
    write_valid_config "${LEGACY_CONFIG_FILE}"
    mkdir -p "${CONFIG_DIR}"
    chmod 0755 "${CONFIG_DIR}"
    if output=$(migrate_legacy_config 2>&1); then fail '迁移器接受了宽松配置目录'; fi
    [[ ${output} == *'配置目录权限必须是 0700'* ]] || fail '配置目录权限提示不清楚'
    [[ -f ${LEGACY_CONFIG_FILE} ]] || fail '配置目录异常时删除了旧配置'
}

test_new_config_symlink_is_rejected_before_write() {
    local output victim
    new_case
    mkdir -p "${CONFIG_DIR}"
    chmod 0700 "${CONFIG_DIR}"
    victim=${CASE_DIR}/victim
    write_valid_config "${victim}"
    ln -s "${victim}" "${CONFIG_FILE}"
    CN_ENTRY_SSH_USER=root
    CN_ENTRY_PRIVATE_IP=10.0.0.2
    CN_ENTRY_SSH_PORT=22
    if output=$(write_config_file 2>&1); then fail '配置写入覆盖了符号链接'; fi
    [[ ${output} == *'不是可安全读取的普通文件'* ]] || fail '新配置符号链接提示不清楚'
    [[ -L ${CONFIG_FILE} ]] || fail '拒绝写入时破坏了配置符号链接'
    [[ -f ${victim} ]] || fail '拒绝写入时破坏了符号链接目标'
}

test_fresh_write_uses_only_etc() {
    new_case
    CN_ENTRY_SSH_USER=root
    CN_ENTRY_PRIVATE_IP=10.0.0.2
    CN_ENTRY_SSH_PORT=22
    write_config_file
    [[ -f ${CONFIG_FILE} ]] || fail '全新写入没有使用正式配置位置'
    [[ ! -e ${LEGACY_CONFIG_FILE} ]] || fail '全新写入仍在 /root 创建配置'
    assert_eq "$(portable_mode "${CONFIG_DIR}")" 700 '全新配置目录权限不正确'
    assert_eq "$(portable_mode "${CONFIG_FILE}")" 600 '全新配置文件权限不正确'
}

test_restore_to_pre_24_returns_config_to_root() {
    local before
    new_case
    mkdir -p "${CONFIG_DIR}"
    chmod 0700 "${CONFIG_DIR}"
    write_valid_config "${CONFIG_FILE}"
    before=$(sha256sum "${CONFIG_FILE}" | awk '{print $1}')
    restore_legacy_config_for_version 2.3.0
    [[ ! -e ${CONFIG_FILE} ]] || fail '撤销到 v2.3 后仍保留新位置配置'
    [[ -f ${LEGACY_CONFIG_FILE} ]] || fail '撤销到 v2.3 没有恢复 /root 配置'
    assert_eq "$(sha256sum "${LEGACY_CONFIG_FILE}" | awk '{print $1}')" "${before}" \
        '撤销版本时改变了配置内容'
    assert_eq "$(portable_mode "${LEGACY_CONFIG_FILE}")" 600 '恢复的旧版配置权限不正确'
}

test_restore_conflict_stops_without_deleting_new_config() {
    local output
    new_case
    mkdir -p "${CONFIG_DIR}"
    chmod 0700 "${CONFIG_DIR}"
    write_valid_config "${CONFIG_FILE}" 10.0.0.2
    write_valid_config "${LEGACY_CONFIG_FILE}" 10.0.0.3
    if output=$(restore_legacy_config_for_version 2.3.0 2>&1); then
        fail '撤销时擅自覆盖了不同的 /root 配置'
    fi
    [[ ${output} == *'已有不同内容'* ]] || fail '撤销配置冲突提示不清楚'
    [[ -f ${CONFIG_FILE} && -f ${LEGACY_CONFIG_FILE} ]] || fail '撤销冲突时删除了配置'
}

test_finalize_cleanup_failure_preserves_compatible_copies() (
    local before
    new_case
    mkdir -p "${CONFIG_DIR}"
    chmod 0700 "${CONFIG_DIR}"
    write_valid_config "${CONFIG_FILE}"
    before=$(sha256sum "${CONFIG_FILE}" | awk '{print $1}')
    prepare_legacy_config_for_version 2.3.0
    rm() {
        local target=
        for target in "$@"; do :; done
        if [[ ${target} == "${CONFIG_FILE}" ]]; then return 1; fi
        /bin/rm "$@"
    }
    ! finalize_legacy_config_for_version 2.3.0 \
        || { fail '模拟新配置清理失败时错误报告成功'; return 1; }
    [[ -f ${CONFIG_FILE} && -f ${LEGACY_CONFIG_FILE} ]] \
        || { fail '新配置清理失败后没有保留两份兼容配置'; return 1; }
    assert_eq "$(sha256sum "${CONFIG_FILE}" | awk '{print $1}')" "${before}" \
        '清理失败改变了新位置配置'
    assert_eq "$(sha256sum "${LEGACY_CONFIG_FILE}" | awk '{print $1}')" "${before}" \
        '清理失败改变了旧位置兼容配置'
)

test_internal_commands_do_not_migrate() {
    new_case
    write_valid_config "${LEGACY_CONFIG_FILE}"
    maybe_migrate_config self-test
    [[ -f ${LEGACY_CONFIG_FILE} ]] || fail 'self-test 意外迁移了配置'
    [[ ! -e ${CONFIG_FILE} ]] || fail 'self-test 意外创建了新配置'
}

test_script_restore_stages_then_finalizes_legacy_config() {
    local body prepare_line pointer_line manager_line move_line first_finalize_line last_finalize_line
    body=$(awk '
        /^perform_script_restore\(\) \($/ {capture=1}
        capture {print}
        capture && /^\)$/ {exit}
    ' "${PROJECT_DIR}/setup.sh")
    prepare_line=$(grep -nF 'prepare_legacy_config_for_version "${backup_version}"' <<<"${body}" | cut -d: -f1)
    pointer_line=$(grep -nF 'write_last_script_backup "${current_backup}"' <<<"${body}" | cut -d: -f1)
    manager_line=$(grep -nF 'restore_legacy_manager_entry "${backup_path}" "${backup_hash}"' <<<"${body}" | cut -d: -f1)
    move_line=$(grep -nF 'mv -fT -- "${replacement}" "${SCRIPT_PATH}"' <<<"${body}" | cut -d: -f1)
    first_finalize_line=$(grep -nF 'finalize_legacy_config_for_version "${backup_version}"' <<<"${body}" | head -1 | cut -d: -f1)
    last_finalize_line=$(grep -nF 'finalize_legacy_config_for_version "${backup_version}"' <<<"${body}" | tail -1 | cut -d: -f1)
    [[ -n ${prepare_line} && -n ${pointer_line} && ${prepare_line} -lt ${pointer_line} ]] \
        || fail '脚本撤销没有在改变备份指针前准备兼容的旧版配置'
    [[ -n ${manager_line} && -n ${first_finalize_line} && ${manager_line} -lt ${first_finalize_line} ]] \
        || fail '跨入口撤销在旧版入口提交前清理了新配置'
    [[ -n ${move_line} && -n ${last_finalize_line} && ${move_line} -lt ${last_finalize_line} ]] \
        || fail '原入口撤销在脚本替换前清理了新配置'
    ! grep -Fq 'restore_legacy_config_for_version "${backup_version}"' <<<"${body}" \
        || fail '脚本撤销仍在提交前执行完整配置迁移'
}

test_legacy_config_moves_to_etc
test_identical_duplicate_cleans_legacy_copy
test_different_duplicates_are_preserved_and_rejected
test_symlink_and_unsafe_metadata_are_rejected
test_existing_unsafe_config_directory_is_rejected
test_new_config_symlink_is_rejected_before_write
test_fresh_write_uses_only_etc
test_restore_to_pre_24_returns_config_to_root
test_restore_conflict_stops_without_deleting_new_config
test_finalize_cleanup_failure_preserves_compatible_copies
test_internal_commands_do_not_migrate
test_script_restore_stages_then_finalizes_legacy_config

printf '%s\n' 'PASS: 连接配置目录迁移与旧版回退验收测试通过'
