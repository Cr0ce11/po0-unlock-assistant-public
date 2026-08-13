#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEMP_BASE=${TMPDIR:-/tmp}
WORK_ROOT=$(mktemp -d "${TEMP_BASE%/}/po0-install-entry.XXXXXXXX")
LIBRARY=${WORK_ROOT}/setup-library.sh
sed '/^ASSUME_YES=no$/,$d' "${PROJECT_DIR}/setup.sh" >"${LIBRARY}"

cleanup() {
    case "${WORK_ROOT}" in
        "${TEMP_BASE%/}"/po0-install-entry.*) rm -rf -- "${WORK_ROOT}" ;;
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

portable_stat() {
    local format=$2 path=$3
    if /usr/bin/stat -c "${format}" "${path}" >/dev/null 2>&1; then
        /usr/bin/stat -c "${format}" "${path}"
        return
    fi
    case "${format}" in
        %u) /usr/bin/stat -f '%u' "${path}" ;;
        %a) /usr/bin/stat -f '%Lp' "${path}" ;;
        %h) /usr/bin/stat -f '%l' "${path}" ;;
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

new_case() {
    CASE_DIR=$(mktemp -d "${WORK_ROOT}/case.XXXXXXXX")
    # shellcheck disable=SC1090
    source "${LIBRARY}"
    SCRIPT_VERSION=2.3.0
    SCRIPT_PATH=${CASE_DIR}/bootstrap.sh
    SCRIPT_DIR=${CASE_DIR}
    PROGRAM_NAME=bootstrap.sh
    OFFICIAL_SCRIPT_PATH=${CASE_DIR}/usr/local/sbin/po0-unlock
    SHORTCUT_PATH=${CASE_DIR}/usr/local/bin/po0
    LEGACY_SCRIPT_PATH=${CASE_DIR}/root/po0-unlock.sh
    printf '%s\n' '#!/usr/bin/env bash' 'SCRIPT_VERSION=2.3.0' \
        'SCRIPT_EDITION_LABEL=公开版' 'exit 0' >"${SCRIPT_PATH}"
    chmod 0700 "${SCRIPT_PATH}"
    is_root() { return 0; }
    stat() {
        if [[ ${1:-} == -c && ${2:-} == %u ]]; then
            printf '%s\n' 0
        else
            portable_stat "$@"
        fi
    }
    install() { portable_install "$@"; }
    chown() { :; }
    mv() { portable_mv "$@"; }
}

test_stable_config_path() {
    new_case
    assert_eq "${CONFIG_FILE}" /etc/po0-unlock/hosts.conf '正式配置位置不正确'
    assert_eq "${LEGACY_CONFIG_FILE}" /root/hosts.conf '旧配置迁移来源不正确'
}

test_fresh_install_creates_canonical_entry() {
    new_case
    install_official_entry
    cmp -s "${SCRIPT_PATH}" "${OFFICIAL_SCRIPT_PATH}" || fail '正式脚本与安装引导文件不一致'
    assert_eq "$(portable_mode "${OFFICIAL_SCRIPT_PATH}")" 700 '正式脚本权限不正确'
    [[ -L ${SHORTCUT_PATH} ]] || fail '没有创建 po0 快捷命令'
    assert_eq "$(readlink "${SHORTCUT_PATH}")" "${OFFICIAL_SCRIPT_PATH}" 'po0 没有指向正式脚本'
}

test_existing_safe_directory_permissions_are_preserved() {
    new_case
    mkdir -p "${OFFICIAL_SCRIPT_PATH%/*}" "${SHORTCUT_PATH%/*}"
    chmod 0700 "${OFFICIAL_SCRIPT_PATH%/*}" "${SHORTCUT_PATH%/*}"
    install_official_entry
    assert_eq "$(portable_mode "${OFFICIAL_SCRIPT_PATH%/*}")" 700 \
        '安装器修改了既有正式脚本目录权限'
    assert_eq "$(portable_mode "${SHORTCUT_PATH%/*}")" 700 \
        '安装器修改了既有快捷命令目录权限'
}

test_existing_install_is_migrated_and_handed_off() {
    local handoff_path handoff_args
    new_case
    mkdir -p "${LEGACY_SCRIPT_PATH%/*}" "${SHORTCUT_PATH%/*}"
    cp "${SCRIPT_PATH}" "${LEGACY_SCRIPT_PATH}"
    chmod 0700 "${LEGACY_SCRIPT_PATH}"
    SCRIPT_PATH=${LEGACY_SCRIPT_PATH}
    SCRIPT_DIR=${SCRIPT_PATH%/*}
    ln -s "${LEGACY_SCRIPT_PATH}" "${SHORTCUT_PATH}"
    installation_active() { return 0; }
    handoff_to_official_script() {
        printf '%s\n' "${OFFICIAL_SCRIPT_PATH}" "$*" >"${CASE_DIR}/handoff"
    }
    maybe_handoff_to_official_entry status
    [[ -f ${OFFICIAL_SCRIPT_PATH} ]] || fail '现有部署没有自动迁移正式脚本'
    [[ -L ${SHORTCUT_PATH} ]] || fail '现有部署没有自动创建 po0'
    assert_eq "$(readlink "${SHORTCUT_PATH}")" "${OFFICIAL_SCRIPT_PATH}" \
        '现有部署的旧 po0 链接没有切换到正式入口'
    {
        IFS= read -r handoff_path
        IFS= read -r handoff_args
    } <"${CASE_DIR}/handoff"
    assert_eq "${handoff_path}" "${OFFICIAL_SCRIPT_PATH}" '迁移后没有切换到正式脚本'
    assert_eq "${handoff_args}" status '迁移时没有保留原命令参数'
}

test_inactive_bootstrap_stays_in_place() {
    new_case
    installation_active() { return 1; }
    handoff_to_official_script() { fail '未安装状态不应切换系统入口'; }
    maybe_handoff_to_official_entry
    [[ ! -e ${OFFICIAL_SCRIPT_PATH} ]] || fail '仅打开未部署脚本就创建了系统入口'
    [[ ! -e ${SHORTCUT_PATH} ]] || fail '仅打开未部署脚本就创建了快捷命令'
}

test_internal_self_test_never_mutates_server() {
    new_case
    installation_active() { return 0; }
    handoff_to_official_script() { fail '自检不应切换系统入口'; }
    maybe_handoff_to_official_entry self-test
    [[ ! -e ${OFFICIAL_SCRIPT_PATH} ]] || fail '自检意外安装了系统入口'
}

test_conflicting_shortcut_is_rejected() {
    local output
    new_case
    mkdir -p "${SHORTCUT_PATH%/*}"
    printf '%s\n' unrelated >"${SHORTCUT_PATH}"
    if output=$(install_official_entry 2>&1); then
        fail '安装器覆盖或接受了被占用的 po0 命令'
    fi
    [[ ${output} == *'快捷命令 po0 已被其他文件占用'* ]] \
        || fail '快捷命令冲突提示不清楚'
    [[ ! -e ${OFFICIAL_SCRIPT_PATH} ]] || fail '发现快捷命令冲突后仍安装了正式脚本'
}

test_conflicting_official_path_is_rejected() {
    local output
    new_case
    mkdir -p "${OFFICIAL_SCRIPT_PATH%/*}"
    printf '%s\n' unrelated >"${OFFICIAL_SCRIPT_PATH}"
    chmod 0700 "${OFFICIAL_SCRIPT_PATH}"
    if output=$(install_official_entry 2>&1); then
        fail '安装器覆盖或接受了无效的正式脚本'
    fi
    [[ ${output} == *'正式脚本不是可识别的 Po0 正式版本'* ]] \
        || fail '正式脚本冲突提示不清楚'
    [[ $(<"${OFFICIAL_SCRIPT_PATH}") == unrelated ]] || fail '被占用的正式脚本遭到修改'
}

test_pre_23_restore_returns_to_legacy_entry() {
    local backup hash
    new_case
    install_official_entry
    mkdir -p "${LEGACY_SCRIPT_PATH%/*}"
    cp "${SCRIPT_PATH}" "${LEGACY_SCRIPT_PATH}"
    chmod 0700 "${LEGACY_SCRIPT_PATH}"
    SCRIPT_PATH=${OFFICIAL_SCRIPT_PATH}
    SCRIPT_DIR=${SCRIPT_PATH%/*}
    backup=${CASE_DIR}/v2.2.1.backup
    printf '%s\n' '#!/usr/bin/env bash' 'SCRIPT_VERSION=2.2.1' 'exit 0' >"${backup}"
    chmod 0700 "${backup}"
    hash=$(sha256sum "${backup}" | awk '{print $1}')
    restore_legacy_manager_entry "${backup}" "${hash}"
    cmp -s "${backup}" "${LEGACY_SCRIPT_PATH}" || fail '旧版备份没有恢复到原入口'
    assert_eq "$(readlink "${SHORTCUT_PATH}")" "${LEGACY_SCRIPT_PATH}" \
        '撤销到 v2.2 时 po0 没有返回旧版入口'
    [[ -f ${OFFICIAL_SCRIPT_PATH} ]] || fail '跨入口撤销破坏了可再次升级的正式脚本'
}

test_updated_legacy_entry_readopts_canonical_entry() {
    new_case
    install_official_entry
    mkdir -p "${LEGACY_SCRIPT_PATH%/*}"
    cp "${SCRIPT_PATH}" "${LEGACY_SCRIPT_PATH}"
    chmod 0700 "${LEGACY_SCRIPT_PATH}"
    replace_managed_shortcut "${LEGACY_SCRIPT_PATH}"
    SCRIPT_PATH=${LEGACY_SCRIPT_PATH}
    SCRIPT_DIR=${SCRIPT_PATH%/*}
    installation_active() { return 0; }
    handoff_to_official_script() {
        printf '%s\n' "${OFFICIAL_SCRIPT_PATH}" >"${CASE_DIR}/handoff"
    }
    maybe_handoff_to_official_entry status
    assert_eq "$(readlink "${SHORTCUT_PATH}")" "${OFFICIAL_SCRIPT_PATH}" \
        '旧入口重新更新后没有恢复正式 po0 指向'
    assert_eq "$(<"${CASE_DIR}/handoff")" "${OFFICIAL_SCRIPT_PATH}" \
        '旧入口重新更新后没有切回正式脚本'
}

test_missing_exit_private_ip_prompts_for_cn_entry_public_ip() {
    local output
    new_case
    CONFIG_DIR=${CASE_DIR}/etc/po0-unlock
    CONFIG_FILE=${CONFIG_DIR}/hosts.conf
    LEGACY_CONFIG_FILE=${CASE_DIR}/root/hosts.conf
    CN_ENTRY_SSH_USER=root
    CN_ENTRY_PRIVATE_IP=
    CN_ENTRY_SSH_PORT=22
    EXIT_PRIVATE_IP=
    is_public_ipv4() { [[ $1 == 203.0.113.10 ]]; }
    ip() {
        case "$*" in
            '-4 route get 10.0.0.10')
                printf '%s\n' '10.0.0.10 via 198.51.100.1 dev eth0 src 198.51.100.20'
                ;;
            '-4 route get 203.0.113.10')
                printf '%s\n' '203.0.113.10 via 198.51.100.1 dev eth0 src 198.51.100.20'
                ;;
            '-4 route get 203.0.113.10 from 198.51.100.20')
                printf '%s\n' '203.0.113.10 via 198.51.100.1 dev eth0 src 198.51.100.20'
                ;;
            '-4 -o addr show dev eth0 scope global'|'-4 -o addr show scope global'|'-4 -o addr show')
                printf '%s\n' '2: eth0 inet 198.51.100.20/24 scope global eth0'
                ;;
            *) return 1 ;;
        esac
    }

    output=$(configure yes <<'EOF' 2>&1
10.0.0.10
22
192.168.50.10
203.0.113.10
EOF
    )
    [[ ${output} == *'本机没有可用的私网 IPv4'* ]] \
        || fail '未说明私网路径不可用'
    [[ ${output} == *'请填写国内入口公网 IPv4'* ]] \
        || fail '没有请求国内入口公网 IPv4'
    [[ ${output} == *'必须是国内入口的公网 IPv4'* ]] \
        || fail '私网地址被当作公网备用地址接受'
    grep -Fxq 'CN_ENTRY_PRIVATE_IP=203.0.113.10' "${CONFIG_FILE}" \
        || fail '公网备用地址没有保存到连接配置'
    ! grep -Fq 'CN_ENTRY_PRIVATE_IP=10.0.0.10' "${CONFIG_FILE}" \
        || fail '私网路径不可用时仍保存了私网地址'

    load_config
    assert_eq "${CN_ENTRY_PRIVATE_IP}" 203.0.113.10 '重载后没有使用国内入口公网 IPv4'
    assert_eq "${EXIT_PRIVATE_IP}" 198.51.100.20 '没有识别到公网路径的国外出口源地址'
}

test_stable_config_path
test_fresh_install_creates_canonical_entry
test_existing_safe_directory_permissions_are_preserved
test_existing_install_is_migrated_and_handed_off
test_inactive_bootstrap_stays_in_place
test_internal_self_test_never_mutates_server
test_conflicting_shortcut_is_rejected
test_conflicting_official_path_is_rejected
test_pre_23_restore_returns_to_legacy_entry
test_updated_legacy_entry_readopts_canonical_entry
test_missing_exit_private_ip_prompts_for_cn_entry_public_ip

printf '%s\n' 'PASS: 正式系统入口安装与迁移验收测试通过'
