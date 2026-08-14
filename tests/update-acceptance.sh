#!/usr/bin/env bash
set -u
set -o pipefail
umask 077

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=${TEST_DIR%/tests}
SETUP_SOURCE=${PROJECT_DIR}/setup.sh
BUILD_SOURCE=${PROJECT_DIR}/tools/build-single-file.sh
CN_ENTRY_BUILD_SOURCE=${PROJECT_DIR}/tools/build-cn-entry-role.sh
TEMP_BASE=${TMPDIR:-/tmp}
TEMP_BASE=${TEMP_BASE%/}
WORK_ROOT=$(mktemp -d "${TEMP_BASE}/po0-update-acceptance.XXXXXXXX")
WORK_ROOT=$(cd -P -- "${WORK_ROOT}" && pwd)
LIBRARY=${WORK_ROOT}/setup-library.sh
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP
    rm -rf -- "${WORK_ROOT}"
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
    ! grep -Fq -- "${needle}" <<<"${haystack}" || fail "${message}（意外出现敏感内容）"
}

assert_file_eq() {
    local expected=$1 actual=$2 message=$3
    cmp -s -- "${expected}" "${actual}" || fail "${message}"
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

mode_of() {
    case $(uname -s) in
        Darwin) /usr/bin/stat -f '%Lp' "$1" ;;
        *) /usr/bin/stat -c '%a' "$1" ;;
    esac
}

inode_of() {
    case $(uname -s) in
        Darwin) /usr/bin/stat -f '%i' "$1" ;;
        *) /usr/bin/stat -c '%i' "$1" ;;
    esac
}

make_library() {
    awk '
        /^ASSUME_YES=no$/ { exit }
        index($0, "[[ -t 0 ]] || die") {
            print "    : # acceptance harness: bypass TTY guard only in temporary copy"
            next
        }
        { print }
    ' "${SETUP_SOURCE}" >"${LIBRARY}"
    /bin/bash -n "${LIBRARY}"
}

portable_stat() {
    local format=${2:-} file=${3:-}
    [[ ${1:-} == -c ]] || { /usr/bin/stat "$@"; return; }
    case "${format}" in
        %u) printf '%s\n' 0 ;;
        %a) mode_of "${file}" ;;
        %h)
            case $(uname -s) in
                Darwin) /usr/bin/stat -f '%l' "${file}" ;;
                *) /usr/bin/stat -c '%h' "${file}" ;;
            esac
            ;;
        %Y)
            case $(uname -s) in
                Darwin) /usr/bin/stat -f '%m' "${file}" ;;
                *) /usr/bin/stat -c '%Y' "${file}" ;;
            esac
            ;;
        %s) wc -c <"${file}" | tr -d '[:space:]'; printf '\n' ;;
        *) return 2 ;;
    esac
}

portable_install() {
    local directory=no mode=755
    local -a operands=()
    while (( $# > 0 )); do
        case "$1" in
            -d) directory=yes; shift ;;
            -o|-g) shift 2 ;;
            -m) mode=$2; shift 2 ;;
            --) shift; while (( $# > 0 )); do operands[${#operands[@]}]=$1; shift; done ;;
            *) operands[${#operands[@]}]=$1; shift ;;
        esac
    done
    if [[ ${directory} == yes ]]; then
        local path
        for path in "${operands[@]}"; do mkdir -p -- "${path}"; chmod "${mode}" "${path}"; done
        return 0
    fi
    [[ ${#operands[@]} -eq 2 ]] || return 2
    cp -p -- "${operands[0]}" "${operands[1]}"
    chmod "${mode}" "${operands[1]}"
}

write_fixture_script() {
    local file=$1 version=$2 behavior=${3:-good} marker=${4:-fixture} edition=${5:-公开版}
    case "${behavior}" in
        syntax)
            printf '%s\n' '#!/usr/bin/env bash' "SCRIPT_VERSION=${version}" \
                "SCRIPT_EDITION_LABEL=${edition}" 'if true; then' >"${file}"
            ;;
        *)
            {
                printf '%s\n' '#!/usr/bin/env bash' "SCRIPT_VERSION=${version}" \
                    "SCRIPT_EDITION_LABEL=${edition}" "FIXTURE_MARKER=${marker}"
                printf '%s\n' 'case "${1:-}" in' '  self-test)'
                case "${behavior}" in
                    good)
                        printf '    printf '\''Po0 单文件版本=%%s\\n'\'' '\''%s'\''\n' "${version}"
                        printf '    printf '\''Po0 单文件版本类型=%%s\\n'\'' '\''%s'\''\n' "${edition}"
                        printf '%s\n' "    printf '%s\\n' 'SELF_TEST=PASS'" '    ;;'
                        ;;
                    bad-report)
                        printf '%s\n' "    printf '%s\\n' 'Po0 单文件版本=9.9.9'" \
                            "    printf '%s\\n' 'Po0 单文件版本类型=${edition}'" \
                            "    printf '%s\\n' 'SELF_TEST=PASS'" '    ;;'
                        ;;
                    self-fail)
                        printf '%s\n' "    printf '%s\\n' 'Po0 单文件版本=${version}'" \
                            "    printf '%s\\n' 'Po0 单文件版本类型=${edition}'" '    exit 7' '    ;;'
                        ;;
                    no-pass)
                        printf '%s\n' "    printf '%s\\n' 'Po0 单文件版本=${version}'" \
                            "    printf '%s\\n' 'Po0 单文件版本类型=${edition}'" '    ;;'
                        ;;
                    duplicate-pass)
                        printf '%s\n' "    printf '%s\\n' 'Po0 单文件版本=${version}'" \
                            "    printf '%s\\n' 'Po0 单文件版本类型=${edition}'" \
                            "    printf '%s\\n' 'SELF_TEST=PASS' 'SELF_TEST=PASS'" '    ;;'
                        ;;
                    *) return 2 ;;
                esac
                printf '%s\n' '  *) exit 0 ;;' 'esac'
            } >"${file}"
            ;;
    esac
    chmod 0700 "${file}"
}

make_release_json() {
    local version=$1 hash=$2
    printf '{"draft":false,"prerelease":false,"tag_name":"v%s","assets":[{"name":"po0-unlock-v2.sh","browser_download_url":"https://github.com/Cr0ce11/po0-unlock-assistant-public/releases/download/v%s/po0-unlock-v2.sh","digest":"sha256:%s"}]}\n' \
        "${version}" "${version}" "${hash}"
}

load_harness() {
    local version=$1
    CASE_DIR=$(mktemp -d "${WORK_ROOT}/case.XXXXXXXX")
    SCRIPT_VERSION=${version}
    # shellcheck disable=SC1090
    source "${LIBRARY}"
    SCRIPT_VERSION=${version}
    SCRIPT_PATH=${CASE_DIR}/po0-unlock.sh
    SCRIPT_DIR=${CASE_DIR}
    PROGRAM_NAME=po0-unlock.sh
    # 更新器通用测试使用 1.x 夹具；配置目录跨版本回退由独立验收覆盖。
    CONFIG_RELOCATION_VERSION=0.0.0
    UPDATE_STATE_ROOT=${CASE_DIR}/state
    UPDATE_BACKUP_DIR=${UPDATE_STATE_ROOT}/backups
    UPDATE_LOCK_FILE=${UPDATE_STATE_ROOT}/update.lock
    UPDATE_LAST_BACKUP=${UPDATE_STATE_ROOT}/last-backup
    UPDATE_REPOSITORY=Cr0ce11/po0-unlock-assistant-public
    UPDATE_API_BASE=https://api.github.com/repos/${UPDATE_REPOSITORY}
    UPDATE_ASSET=po0-unlock-v2.sh
    UPDATE_MAX_BYTES=1048576
    ASSUME_YES=yes
    TEST_RELEASE_JSON=
    TEST_ASSET_FILE=
    TEST_REQUEST_LOG=${CASE_DIR}/request.log
    TEST_SYSTEMCTL_LOG=${CASE_DIR}/systemctl.log
    TEST_FLOCK_LOG=${CASE_DIR}/flock.log

    require_root() { :; }
    stat() { portable_stat "$@"; }
    install() { portable_install "$@"; }
    chown() { :; }
    mv() {
        local -a operands=()
        while (( $# > 0 )); do
            case "$1" in
                -f|-T|-fT|-Tf|--) shift ;;
                *) operands[${#operands[@]}]=$1; shift ;;
            esac
        done
        [[ ${#operands[@]} -eq 2 ]] || return 2
        /bin/mv -f "${operands[0]}" "${operands[1]}"
    }
    flock() { printf '%s\n' "$*" >>"${TEST_FLOCK_LOG}"; return 0; }
    timeout() {
        while [[ ${1:-} == --* ]]; do shift; done
        [[ $# -gt 0 ]] || return 2
        shift
        "$@"
    }
    env() {
        if [[ ${1:-} == -i ]]; then
            shift
            while [[ ${1:-} == *=* ]]; do shift; done
        fi
        "$@"
    }
    systemctl() { printf '%s\n' "$*" >>"${TEST_SYSTEMCTL_LOG}"; return 99; }
    eval "$(declare -f github_public_request | sed '1s/^github_public_request /real_github_public_request /')"
    eval "$(declare -f github_download_public_asset | sed '1s/^github_download_public_asset /real_github_download_public_asset /')"
    github_public_request() (
        local url=$1 output=${2:-}
        printf 'request %s\n' "${url}" >>"${TEST_REQUEST_LOG}"
        case "${url}" in
            "${UPDATE_API_BASE}/releases/latest")
                if [[ -n ${output} ]]; then
                    printf '%s\n' "${TEST_RELEASE_JSON}" >"${output}"
                else
                    printf '%s\n' "${TEST_RELEASE_JSON}"
                fi
                ;;
            *) return 22 ;;
        esac
    )
    github_download_public_asset() {
        local url=$1 output=$2
        printf 'download %s\n' "${url}" >>"${TEST_REQUEST_LOG}"
        [[ ${url} == https://github.com/Cr0ce11/po0-unlock-assistant-public/releases/download/v*/po0-unlock-v2.sh ]] \
            || return 22
        [[ -f ${TEST_ASSET_FILE} ]] || return 1
        cp -- "${TEST_ASSET_FILE}" "${output}"
    }
    ensure_update_core_dependencies() { :; }
    ensure_update_dependencies() { :; }
}

assert_no_transaction_residue() {
    local prefix=$1 residue
    residue=$(find "${SCRIPT_DIR}" -maxdepth 1 -name "${prefix}.*" -print)
    [[ -z ${residue} ]] || fail "发现未清理的事务临时文件：${residue}"
}

test_build_and_bundle_self_test() {
    local tree=${WORK_ROOT}/build-tree first_hash second_hash output expected_role
    mkdir -p "${tree}/tools" "${tree}/src/cn-entry-role"
    cp "${PROJECT_DIR}/setup.sh" "${PROJECT_DIR}/overseas-exit-role.sh" \
        "${PROJECT_DIR}/cn-entry-role.sh" "${tree}/"
    cp "${BUILD_SOURCE}" "${CN_ENTRY_BUILD_SOURCE}" "${tree}/tools/"
    cp "${PROJECT_DIR}"/src/cn-entry-role/*.sh.inc "${tree}/src/cn-entry-role/"
    /bin/bash "${tree}/tools/build-cn-entry-role.sh" --check >/dev/null
    printf '%s\n' '# unregistered test module' >"${tree}/src/cn-entry-role/99-unregistered.sh.inc"
    ! /bin/bash "${tree}/tools/build-cn-entry-role.sh" --check >/dev/null 2>&1 \
        || fail '模块检查没有拒绝未登记的国内入口模块'
    rm -f "${tree}/src/cn-entry-role/99-unregistered.sh.inc"
    expected_role=${tree}/cn-entry-role.expected
    cp "${tree}/cn-entry-role.sh" "${expected_role}"
    printf '\n' >>"${tree}/cn-entry-role.sh"
    ! /bin/bash "${tree}/tools/build-cn-entry-role.sh" --check >/dev/null 2>&1 \
        || fail '模块检查没有拒绝过期的国内入口生成文件'
    /bin/bash "${tree}/tools/build-cn-entry-role.sh" --build >/dev/null
    assert_file_eq "${expected_role}" "${tree}/cn-entry-role.sh" \
        '国内入口模块未能确定性恢复生成文件'
    output=$(/bin/bash "${tree}/tools/build-single-file.sh" 1.1.0)
    assert_contains "${output}" '版本：1.1.0' '构建器没有报告目标版本'
    /bin/bash -n "${tree}/po0-unlock.sh"
    output=$(/bin/bash "${tree}/po0-unlock.sh" self-test)
    assert_contains "${output}" 'Po0 单文件版本=1.1.0' '单文件自检版本错误'
    assert_contains "${output}" 'SELF_TEST=PASS' '单文件自检未通过'
    /bin/bash "${tree}/po0-unlock.sh" __extract-role overseas-exit | cmp -s - "${tree}/overseas-exit-role.sh"
    /bin/bash "${tree}/po0-unlock.sh" __extract-role cn-entry | cmp -s - "${tree}/cn-entry-role.sh"
    first_hash=$(sha256_file "${tree}/po0-unlock.sh")
    /bin/bash "${tree}/tools/build-single-file.sh" 1.1.0 >/dev/null
    second_hash=$(sha256_file "${tree}/po0-unlock.sh")
    assert_eq "${first_hash}" "${second_hash}" '相同源码和版本未能确定性构建'
}

test_single_public_edition_contract() {
    local source edition_count marker_count obsolete
    source=$(sed -n '1,$p' "${SETUP_SOURCE}")
    edition_count=$(grep -Fxc 'SCRIPT_EDITION_LABEL=公开版' "${SETUP_SOURCE}" || true)
    marker_count=$(grep -Ec '^# (>>>|<<<) online_updater$' "${SETUP_SOURCE}" || true)

    assert_eq 1 "${edition_count}" '源码没有唯一固定为公开版' || return 1
    assert_eq 0 "${marker_count}" '源码仍保留双版本裁剪标记' || return 1
    assert_not_contains "${source}" 'SCRIPT_EDITION_LABEL=${SCRIPT_EDITION_LABEL:-公开版}' \
        '公开版类型仍可被运行环境覆盖' || return 1

    for obsolete in \
        tools/build-public.sh \
        tests/public-edition-acceptance.sh \
        po0-unlock-public.sh; do
        [[ ! -e ${PROJECT_DIR}/${obsolete} && ! -L ${PROJECT_DIR}/${obsolete} ]] \
            || { fail "单版本仓库仍包含已废弃的双版本文件：${obsolete}"; return 1; }
    done
}

test_strict_versions() {
    local value duplicate wrong_edition extracted_edition
    load_harness 1.1.0
    for value in 0.0.0 1.10.0 999999.999999.999999; do
        valid_release_version "${value}" || fail "合法版本被拒绝：${value}"
    done
    for value in 01.0.0 1.01.0 1.0.01 1.0 1.0.0-rc1 v1.0.0 1000000.0.0; do
        ! valid_release_version "${value}" || fail "非法版本被接受：${value}"
    done
    version_gt 1.10.0 1.9.9 || fail '数值版本比较错误'
    ! version_gt 1.9.9 1.10.0 || fail '反向版本比较错误'
    duplicate=${CASE_DIR}/duplicate.sh
    write_fixture_script "${duplicate}" 1.1.0 good duplicate
    printf '%s\n' 'SCRIPT_VERSION=1.1.0' >>"${duplicate}"
    ! static_script_version "${duplicate}" >/dev/null || fail '静态版本解析接受了重复声明'

    wrong_edition=${CASE_DIR}/wrong-edition.sh
    write_fixture_script "${wrong_edition}" 1.1.0 good private-edition 私有版
    extracted_edition=$(static_script_edition "${wrong_edition}") \
        || fail '静态版本类型解析未能识别私有版迁移来源'
    assert_eq 私有版 "${extracted_edition}" '静态版本类型解析结果错误'
    printf '%s\n' 'SCRIPT_EDITION_LABEL=公开版' >>"${wrong_edition}"
    ! static_script_edition "${wrong_edition}" >/dev/null || fail '静态版本类型解析接受了重复声明'
}

test_mawk_static_version_compatibility() {
    local good duplicate invalid extracted
    load_harness 1.1.0
    good=${CASE_DIR}/mawk-good.sh
    duplicate=${CASE_DIR}/mawk-duplicate.sh
    invalid=${CASE_DIR}/mawk-invalid.sh
    write_fixture_script "${good}" 1.1.0 good mawk-good
    cp "${good}" "${duplicate}"
    printf '%s\n' 'SCRIPT_VERSION=1.1.0' >>"${duplicate}"
    printf '%s\n' '#!/usr/bin/env bash' 'SCRIPT_VERSION=01.1.0' >"${invalid}"

    # Debian 12 的 mawk 不保证支持 ERE 区间量词。只在这项测试中模拟
    # 该行为；一旦实现重新依赖 {m,n}，合法正式版本会提取失败。
    awk() {
        local program=${1:-}
        if [[ ${program} == *'{0,5}'* || ${program} == *'{1,}'* || ${program} == *'{1,6}'* ]]; then
            return 0
        fi
        command awk "$@"
    }

    extracted=$(static_script_version "${good}") \
        || fail 'static_script_version 依赖 mawk 不兼容的区间量词，无法识别 v1.1.0'
    assert_eq 1.1.0 "${extracted}" 'mawk 兼容模式提取的正式版本错误'
    ! static_script_version "${duplicate}" >/dev/null || fail 'mawk 兼容模式接受了重复版本声明'
    ! static_script_version "${invalid}" >/dev/null || fail 'mawk 兼容模式接受了前导零版本'
}

expect_candidate_failure() {
    local file=$1 version=$2 hash=$3 expected_message=$4 output
    if output=$(validate_script_candidate "${file}" "${version}" "${hash}" 2>&1); then
        fail "候选异常未被拒绝：${expected_message}"
    fi
    assert_contains "${output}" "${expected_message}" '候选失败原因不明确'
}

test_candidate_validation_failures() {
    local good wrong_version wrong_edition syntax self_fail no_pass duplicate_pass bad_report hash
    load_harness 1.0.0
    good=${CASE_DIR}/good.sh
    wrong_version=${CASE_DIR}/wrong-version.sh
    syntax=${CASE_DIR}/syntax.sh
    self_fail=${CASE_DIR}/self-fail.sh
    no_pass=${CASE_DIR}/no-pass.sh
    duplicate_pass=${CASE_DIR}/duplicate-pass.sh
    bad_report=${CASE_DIR}/bad-report.sh
    write_fixture_script "${good}" 1.1.0 good good
    hash=$(sha256_file "${good}")
    validate_script_candidate "${good}" 1.1.0 "${hash}"
    expect_candidate_failure "${good}" 1.1.0 "$(printf '0%.0s' {1..64})" 'SHA-256'
    write_fixture_script "${wrong_version}" 1.1.1 good mismatch
    expect_candidate_failure "${wrong_version}" 1.1.0 "$(sha256_file "${wrong_version}")" 'Release 标签与脚本版本不一致'
    wrong_edition=${CASE_DIR}/wrong-edition.sh
    write_fixture_script "${wrong_edition}" 1.1.0 good wrong-edition 私有版
    expect_candidate_failure "${wrong_edition}" 1.1.0 "$(sha256_file "${wrong_edition}")" '版本类型'
    write_fixture_script "${syntax}" 1.1.0 syntax syntax
    expect_candidate_failure "${syntax}" 1.1.0 "$(sha256_file "${syntax}")" '候选脚本语法检查失败'
    write_fixture_script "${self_fail}" 1.1.0 self-fail fail
    expect_candidate_failure "${self_fail}" 1.1.0 "$(sha256_file "${self_fail}")" '候选脚本自检失败或超时'
    write_fixture_script "${no_pass}" 1.1.0 no-pass no-pass
    expect_candidate_failure "${no_pass}" 1.1.0 "$(sha256_file "${no_pass}")" '唯一的 SELF_TEST=PASS'
    write_fixture_script "${duplicate_pass}" 1.1.0 duplicate-pass duplicate
    expect_candidate_failure "${duplicate_pass}" 1.1.0 "$(sha256_file "${duplicate_pass}")" '唯一的 SELF_TEST=PASS'
    write_fixture_script "${bad_report}" 1.1.0 bad-report report
    expect_candidate_failure "${bad_report}" 1.1.0 "$(sha256_file "${bad_report}")" '自检报告的版本不正确'
}

test_candidate_size_gate_preserves_target() {
    local case_name candidate candidate_hash old_hash output rc actual_size
    for case_name in empty oversized; do
        load_harness 1.0.0
        write_fixture_script "${SCRIPT_PATH}" 1.0.0 good "size-gate-${case_name}-old"
        chmod 0700 "${SCRIPT_PATH}"
        old_hash=$(sha256_file "${SCRIPT_PATH}")
        candidate=${CASE_DIR}/${case_name}.sh
        case "${case_name}" in
            empty)
                : >"${candidate}"
                ;;
            oversized)
                dd if=/dev/zero of="${candidate}" bs="${UPDATE_MAX_BYTES}" count=1 2>/dev/null \
                    || fail '无法创建超限更新候选夹具'
                printf 'x' >>"${candidate}"
                actual_size=$(stat -c '%s' "${candidate}")
                assert_eq "$((UPDATE_MAX_BYTES + 1))" "${actual_size}" \
                    '超限更新候选夹具大小不正确' || return 1
                ;;
        esac
        candidate_hash=$(sha256_file "${candidate}")
        TEST_ASSET_FILE=${candidate}
        TEST_RELEASE_JSON=$(make_release_json 1.1.0 "${candidate_hash}")
        set +e
        output=$(perform_script_update 2>&1)
        rc=$?
        set -e

        [[ ${rc} -ne 0 && ${rc} -ne 20 ]] \
            || { fail "${case_name} 更新候选没有被拒绝"; return 1; }
        assert_contains "${output}" '候选脚本大小异常。' \
            "${case_name} 更新候选拒绝原因不明确" || return 1
        assert_eq "${old_hash}" "$(sha256_file "${SCRIPT_PATH}")" \
            "${case_name} 更新候选改变了当前脚本" || return 1
        [[ ! -d ${UPDATE_BACKUP_DIR} ]] \
            || ! find "${UPDATE_BACKUP_DIR}" -type f -name '*.backup.*' -print | grep -q . \
            || { fail "${case_name} 更新候选在校验前创建了脚本备份"; return 1; }
        assert_no_transaction_residue 'po0-unlock.sh.update' || return 1
    done
}

test_release_metadata_failures_leave_target_unchanged() {
    local old_hash output rc
    load_harness 1.0.0
    write_fixture_script "${SCRIPT_PATH}" 1.0.0 good old
    old_hash=$(sha256_file "${SCRIPT_PATH}")
    TEST_RELEASE_JSON=$(make_release_json 01.1.0 "$(printf '0%.0s' {1..64})")
    set +e
    output=$(perform_script_update 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 && ${rc} -ne 20 ]] || fail '非法 Release 版本没有失败'
    assert_contains "${output}" '严格的 x.y.z' '非法 Release 版本错误不明确'
    assert_eq "${old_hash}" "$(sha256_file "${SCRIPT_PATH}")" '非法 Release 版本改变了脚本'
    [[ ! -d ${UPDATE_BACKUP_DIR} ]] || ! find "${UPDATE_BACKUP_DIR}" -type f -name '*.backup.*' -print | grep -q . \
        || fail '非法 Release 版本产生了脚本备份'

    TEST_RELEASE_JSON=$(make_release_json 1.1.0 not-a-digest)
    set +e
    output=$(perform_script_update 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 && ${rc} -ne 20 ]] || fail '非法 Release 摘要没有失败'
    assert_contains "${output}" '缺少可信 SHA-256 digest' '非法摘要错误不明确'
    assert_eq "${old_hash}" "$(sha256_file "${SCRIPT_PATH}")" '非法摘要改变了脚本'
    assert_no_transaction_residue 'po0-unlock.sh.update'
}

test_latest_noop_and_downgrade_refusal() {
    local target_hash output rc asset
    load_harness 1.1.0
    write_fixture_script "${SCRIPT_PATH}" 1.1.0 good latest
    target_hash=$(sha256_file "${SCRIPT_PATH}")
    TEST_ASSET_FILE=${SCRIPT_PATH}
    TEST_RELEASE_JSON=$(make_release_json 1.1.0 "${target_hash}")
    output=$(perform_script_update 2>&1)
    assert_contains "${output}" '当前已经是最新正式版 v1.1.0' '同版同摘要没有按无操作处理'
    assert_eq "${target_hash}" "$(sha256_file "${SCRIPT_PATH}")" '最新版检查改变了当前脚本'
    [[ ! -d ${UPDATE_BACKUP_DIR} ]] || ! find "${UPDATE_BACKUP_DIR}" -type f -name '*.backup.*' -print | grep -q . \
        || fail '最新版检查产生了脚本备份'
    [[ $(grep -Fc 'download ' "${TEST_REQUEST_LOG}" || true) -eq 0 ]] \
        || fail '最新版检查仍下载了发行资产'

    load_harness 1.2.0
    write_fixture_script "${SCRIPT_PATH}" 1.2.0 good newer-local
    asset=${CASE_DIR}/older-release.sh
    write_fixture_script "${asset}" 1.1.0 good older-release
    target_hash=$(sha256_file "${SCRIPT_PATH}")
    TEST_ASSET_FILE=${asset}
    TEST_RELEASE_JSON=$(make_release_json 1.1.0 "$(sha256_file "${asset}")")
    set +e
    output=$(perform_script_update 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 && ${rc} -ne 20 ]] || fail '降级 Release 没有被拒绝'
    assert_contains "${output}" '拒绝自动降级' '降级拒绝错误不明确'
    assert_eq "${target_hash}" "$(sha256_file "${SCRIPT_PATH}")" '降级检查改变了当前脚本'
    [[ ! -d ${UPDATE_BACKUP_DIR} ]] || ! find "${UPDATE_BACKUP_DIR}" -type f -name '*.backup.*' -print | grep -q . \
        || fail '降级检查产生了脚本备份'
    assert_no_transaction_residue 'po0-unlock.sh.update'
}

test_anonymous_public_requests_have_no_credentials() (
    local mock_curl request_log candidate captured public_asset_url
    load_harness 1.0.0
    mock_curl=${CASE_DIR}/mock-public-curl
    request_log=${CASE_DIR}/public-curl.log
    candidate=${CASE_DIR}/downloaded-public-asset
    public_asset_url=https://github.com/Cr0ce11/po0-unlock-assistant-public/releases/download/v1.1.0/po0-unlock-v2.sh
    : >"${candidate}"
    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail'
        printf '%s\n' \
            'request_config=$(cat)' \
            'printf "%s\\n" "--- request ---" "${request_config}" >>"${PO0_PUBLIC_CURL_LOG}"' \
            'output_file=' \
            'while (( $# > 0 )); do' \
            '    printf "arg=%s\\n" "$1" >>"${PO0_PUBLIC_CURL_LOG}"' \
            '    if [[ $1 == --output ]]; then output_file=$2; shift 2; else shift; fi' \
            'done' \
            'if [[ -n ${output_file} ]]; then' \
            '    printf "%s\\n" public-release-asset >"${output_file}"' \
            'else' \
            '    printf "%s\\n" "{}"' \
            'fi'
    } >"${mock_curl}"
    chmod 0700 "${mock_curl}"
    export PO0_PUBLIC_CURL_LOG=${request_log}
    CURL_BIN=${mock_curl}

    real_github_public_request "${UPDATE_API_BASE}/releases/latest" >/dev/null \
        || fail '公开 Release 匿名请求失败'
    real_github_download_public_asset "${public_asset_url}" "${candidate}" \
        || fail '公开 Release 资产匿名下载失败'
    assert_eq public-release-asset "$(<"${candidate}")" '公开资产下载内容错误' || return 1

    captured=$(<"${request_log}")
    if grep -Eiq 'authorization|token' <<<"${captured}"; then
        fail '公开 Release 匿名请求携带了认证头或令牌参数'
        return 1
    fi
    ! real_github_public_request \
        'https://api.github.com/repos/Cr0ce11/po0-unlock-assistant/releases/latest' >/dev/null 2>&1 \
        || fail '匿名请求接受了非公开更新仓库'
    ! real_github_download_public_asset \
        'https://github.com/Cr0ce11/po0-unlock-assistant/releases/download/v1.1.0/po0-unlock-v2.sh' \
        "${candidate}" >/dev/null 2>&1 \
        || fail '匿名下载接受了非公开更新仓库'
)

# 项目所有者的 GitHub 账号从 DTB201 改名为 Cr0ce11 后，旧账号名可被任何人重新注册。
# 更新器必须只认当前账号下的公开仓库，并拒绝改名前的旧地址。
test_updater_rejects_previous_owner_repository() (
    local mock_curl candidate
    load_harness 1.0.0
    mock_curl=${CASE_DIR}/mock-owner-curl
    candidate=${CASE_DIR}/owner-asset-candidate
    : >"${candidate}"
    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail'
        printf '%s\n' \
            'cat >/dev/null' \
            'output_file=' \
            'while (( $# > 0 )); do' \
            '    if [[ $1 == --output ]]; then output_file=$2; shift 2; else shift; fi' \
            'done' \
            'if [[ -n ${output_file} ]]; then' \
            '    printf "%s\\n" current-owner-asset >"${output_file}"' \
            'else' \
            '    printf "%s\\n" "{}"' \
            'fi'
    } >"${mock_curl}"
    chmod 0700 "${mock_curl}"
    CURL_BIN=${mock_curl}

    # 夹具会覆盖 UPDATE_REPOSITORY，因此默认值另行按源码常量核对；
    # 下面的接受与拒绝断言仍然运行真实的请求与下载守卫。
    assert_eq 'UPDATE_REPOSITORY=Cr0ce11/po0-unlock-assistant-public' \
        "$(grep -m1 '^UPDATE_REPOSITORY=' "${SETUP_SOURCE}")" \
        'setup.sh 的默认更新仓库不是当前 GitHub 账号下的公开仓库' || return 1
    real_github_public_request "${UPDATE_API_BASE}/releases/latest" >/dev/null \
        || fail '当前账号公开仓库的 Release 查询被拒绝'
    real_github_download_public_asset \
        'https://github.com/Cr0ce11/po0-unlock-assistant-public/releases/download/v1.1.0/po0-unlock-v2.sh' \
        "${candidate}" || fail '当前账号公开仓库的资产下载被拒绝'
    assert_eq current-owner-asset "$(<"${candidate}")" '当前账号资产下载内容错误' || return 1

    ! real_github_public_request \
        'https://api.github.com/repos/DTB201/po0-unlock-assistant-public/releases/latest' >/dev/null 2>&1 \
        || fail '匿名请求接受了改名前账号下的旧仓库地址'
    ! real_github_download_public_asset \
        'https://github.com/DTB201/po0-unlock-assistant-public/releases/download/v1.1.0/po0-unlock-v2.sh' \
        "${candidate}" >/dev/null 2>&1 \
        || fail '匿名下载接受了改名前账号下的旧仓库地址'
)

test_public_candidate_edition_gate() {
    local current public_candidate private_candidate share_candidate rejected current_hash output rc
    load_harness 2.5.16
    current=${SCRIPT_PATH}
    public_candidate=${CASE_DIR}/public-candidate.sh
    private_candidate=${CASE_DIR}/private-candidate.sh
    share_candidate=${CASE_DIR}/share-candidate.sh
    write_fixture_script "${current}" 2.5.16 good edition-current 公开版
    write_fixture_script "${public_candidate}" 2.5.17 good edition-public 公开版
    write_fixture_script "${private_candidate}" 2.5.17 good edition-private 私有版
    write_fixture_script "${share_candidate}" 2.5.17 good edition-share 分享版

    validate_script_candidate \
        "${public_candidate}" 2.5.17 "$(sha256_file "${public_candidate}")" \
        || fail '公开 Release 的公开版候选被拒绝'
    for rejected in "${private_candidate}" "${share_candidate}"; do
        if output=$(validate_script_candidate \
            "${rejected}" 2.5.17 "$(sha256_file "${rejected}")" 2>&1); then
            fail '公开 Release 接受了历史版本类型候选'
            return 1
        fi
        assert_contains "${output}" '版本类型' '跨版本类型候选拒绝原因不明确' || return 1
    done

    current_hash=$(sha256_file "${current}")
    TEST_ASSET_FILE=${private_candidate}
    TEST_RELEASE_JSON=$(make_release_json 2.5.17 "$(sha256_file "${private_candidate}")")
    set +e
    output=$(perform_script_update 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 && ${rc} -ne 20 ]] || fail '私有版 Release 资产触发了公开版更新'
    assert_eq "${current_hash}" "$(sha256_file "${current}")" \
        '跨版本类型候选改变了当前脚本'
    [[ ! -e ${TEST_SYSTEMCTL_LOG} ]] || fail '跨版本类型候选失败时调用了 systemctl'
    assert_no_transaction_residue 'po0-unlock.sh.update'
}

assert_legacy_edition_takeover_and_restore() (
    local legacy_edition=$1
    local uploaded installed shortcut old_hash new_hash output rc pointer_hash backup_name backup_path
    load_harness 2.5.17
    uploaded=${CASE_DIR}/uploaded-public.sh
    installed=${CASE_DIR}/usr/local/sbin/po0-unlock
    shortcut=${CASE_DIR}/usr/local/bin/po0
    mkdir -p -- "${installed%/*}" "${shortcut%/*}" "${CASE_DIR}/root"
    chmod 0700 "${installed%/*}" "${shortcut%/*}" "${CASE_DIR}/root"
    write_fixture_script "${uploaded}" 2.5.17 good manual-public 公开版
    write_fixture_script "${installed}" 2.5.16 good installed-legacy "${legacy_edition}"
    ln -s -- "${installed}" "${shortcut}"
    old_hash=$(sha256_file "${installed}")
    new_hash=$(sha256_file "${uploaded}")

    SCRIPT_VERSION=2.5.17
    SCRIPT_EDITION_LABEL=公开版
    SCRIPT_PATH=${uploaded}
    SCRIPT_DIR=${CASE_DIR}
    OFFICIAL_SCRIPT_PATH=${installed}
    SHORTCUT_PATH=${shortcut}
    LEGACY_SCRIPT_PATH=${CASE_DIR}/root/po0-unlock.sh
    set +e
    output=$(perform_uploaded_local_upgrade 2.5.16 "${legacy_edition}" upgrade 2>&1)
    rc=$?
    set -e
    assert_eq 0 "${rc}" "${legacy_edition}没有被公开版高版本手动接管" || return 1
    assert_file_eq "${uploaded}" "${installed}" '手动接管没有安装精确的公开版候选' || return 1
    assert_eq "${new_hash}" "$(sha256_file "${installed}")" '手动接管后脚本摘要错误' || return 1
    [[ -r ${UPDATE_LAST_BACKUP} ]] || fail "手动接管没有登记可恢复的${legacy_edition}备份"
    IFS=' ' read -r pointer_hash backup_name <"${UPDATE_LAST_BACKUP}"
    backup_path=${UPDATE_BACKUP_DIR}/${backup_name}
    assert_eq "${old_hash}" "${pointer_hash}" "手动接管记录的${legacy_edition}备份摘要错误" || return 1
    assert_eq "${legacy_edition}" "$(static_script_edition "${backup_path}")" \
        "手动接管备份没有保留${legacy_edition}类型" || return 1

    SCRIPT_PATH=${installed}
    SCRIPT_DIR=${installed%/*}
    SCRIPT_VERSION=2.5.17
    set +e
    output=$(perform_script_restore 2>&1)
    rc=$?
    set -e
    assert_eq 20 "${rc}" "公开版接管后无法恢复上一版${legacy_edition}" || return 1
    assert_eq "${old_hash}" "$(sha256_file "${installed}")" "恢复结果不是接管前的${legacy_edition}" || return 1
    assert_eq "${legacy_edition}" "$(static_script_edition "${installed}")" "恢复后没有回到${legacy_edition}" || return 1
    [[ ! -e ${TEST_SYSTEMCTL_LOG} ]] || fail '手动接管或恢复过程中调用了 systemctl'
)

test_legacy_editions_to_public_manual_takeover_and_restore() {
    assert_legacy_edition_takeover_and_restore 私有版 || return 1
    assert_legacy_edition_takeover_and_restore 分享版 || return 1
}

assert_same_version_legacy_edition_does_not_replace() (
    local legacy_edition=$1
    local uploaded installed shortcut installed_hash handoff_count=0
    load_harness 2.5.17
    uploaded=${CASE_DIR}/same-version-public.sh
    installed=${CASE_DIR}/usr/local/sbin/po0-unlock
    shortcut=${CASE_DIR}/usr/local/bin/po0
    mkdir -p -- "${installed%/*}" "${shortcut%/*}" "${CASE_DIR}/root"
    chmod 0700 "${installed%/*}" "${shortcut%/*}" "${CASE_DIR}/root"
    write_fixture_script "${uploaded}" 2.5.17 good same-public 公开版
    write_fixture_script "${installed}" 2.5.17 good same-legacy "${legacy_edition}"
    ln -s -- "${installed}" "${shortcut}"
    installed_hash=$(sha256_file "${installed}")

    SCRIPT_VERSION=2.5.17
    SCRIPT_EDITION_LABEL=公开版
    SCRIPT_PATH=${uploaded}
    SCRIPT_DIR=${CASE_DIR}
    OFFICIAL_SCRIPT_PATH=${installed}
    SHORTCUT_PATH=${shortcut}
    LEGACY_SCRIPT_PATH=${CASE_DIR}/root/po0-unlock.sh
    is_root() { return 0; }
    handoff_to_official_script() { handoff_count=$((handoff_count + 1)); }
    maybe_handoff_to_official_entry status

    assert_eq "${installed_hash}" "$(sha256_file "${installed}")" \
        '同版本跨类型上传替换了已安装脚本' || return 1
    assert_eq "${legacy_edition}" "$(static_script_edition "${installed}")" \
        '同版本跨类型上传改变了已安装版本类型' || return 1
    assert_eq 1 "${handoff_count}" '同版本跨类型上传没有继续交接到已安装脚本' || return 1
    [[ ! -e ${UPDATE_STATE_ROOT} ]] || fail '同版本跨类型上传创建了更新状态'
    [[ ! -e ${TEST_SYSTEMCTL_LOG} ]] || fail '同版本跨类型上传调用了 systemctl'
)

test_same_version_cross_edition_does_not_replace() {
    assert_same_version_legacy_edition_does_not_replace 私有版 || return 1
    assert_same_version_legacy_edition_does_not_replace 分享版 || return 1
}

test_manual_takeover_failure_preserves_private_install() {
    local uploaded installed shortcut installed_hash history history_backup pointer_before
    local backup_count_before backup_count_after output rc
    load_harness 2.5.17
    uploaded=${CASE_DIR}/failing-public.sh
    installed=${CASE_DIR}/usr/local/sbin/po0-unlock
    shortcut=${CASE_DIR}/usr/local/bin/po0
    mkdir -p -- "${installed%/*}" "${shortcut%/*}" "${CASE_DIR}/root"
    chmod 0700 "${installed%/*}" "${shortcut%/*}" "${CASE_DIR}/root"
    write_fixture_script "${uploaded}" 2.5.17 good takeover-pointer-failure 公开版
    write_fixture_script "${installed}" 2.5.16 good takeover-private 私有版
    ln -s -- "${installed}" "${shortcut}"
    installed_hash=$(sha256_file "${installed}")

    SCRIPT_VERSION=2.5.17
    SCRIPT_EDITION_LABEL=公开版
    SCRIPT_PATH=${uploaded}
    SCRIPT_DIR=${CASE_DIR}
    OFFICIAL_SCRIPT_PATH=${installed}
    SHORTCUT_PATH=${shortcut}
    LEGACY_SCRIPT_PATH=${CASE_DIR}/root/po0-unlock.sh
    acquire_script_update_lock
    release_script_update_lock
    history=${CASE_DIR}/previous-public.sh
    write_fixture_script "${history}" 2.5.15 good previous-public 公开版
    history_backup=$(create_script_backup "${history}" 2.5.15) \
        || fail '无法创建接管失败前的既有恢复点'
    write_last_script_backup "${history_backup}" || fail '无法登记接管失败前的既有恢复点'
    pointer_before=$(<"${UPDATE_LAST_BACKUP}")
    backup_count_before=$(find "${UPDATE_BACKUP_DIR}" -type f -name '*.backup.*' | wc -l | tr -d '[:space:]')

    eval "$(declare -f validate_uploaded_public_candidate \
        | sed '1s/^validate_uploaded_public_candidate /real_validate_uploaded_public_candidate /')"
    VALIDATE_UPLOADED_CALLS=0
    validate_uploaded_public_candidate() {
        VALIDATE_UPLOADED_CALLS=$((VALIDATE_UPLOADED_CALLS + 1))
        (( VALIDATE_UPLOADED_CALLS != 2 )) || return 1
        real_validate_uploaded_public_candidate "$@"
    }
    set +e
    output=$(perform_uploaded_local_upgrade 2.5.16 私有版 upgrade 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 && ${rc} -ne 20 ]] || fail '接管最终校验失败后仍报告成功'
    assert_eq "${installed_hash}" "$(sha256_file "${installed}")" \
        '接管失败改变了原私有版脚本' || return 1
    assert_eq 私有版 "$(static_script_edition "${installed}")" \
        '接管失败改变了原脚本版本类型' || return 1
    assert_eq "${pointer_before}" "$(<"${UPDATE_LAST_BACKUP}")" \
        '接管失败没有恢复原脚本备份指针' || return 1
    backup_count_after=$(find "${UPDATE_BACKUP_DIR}" -type f -name '*.backup.*' | wc -l | tr -d '[:space:]')
    assert_eq "${backup_count_before}" "${backup_count_after}" \
        '接管失败留下了新的长期备份' || return 1
    [[ -f ${history_backup} ]] || fail '接管失败删除了原恢复点'
    [[ ! -e ${TEST_SYSTEMCTL_LOG} ]] || fail '接管失败时调用了 systemctl'
    ! find "${installed%/*}" -maxdepth 1 \
        \( -name 'po0-unlock.local-upgrade.*' -o -name 'po0-unlock.previous.*' \) -print | grep -q . \
        || fail '接管失败留下了事务临时文件'
}

test_valid_update_backup_and_restore() {
    local old=${CASE_DIR:-} new old_hash new_hash release output rc backup_name backup_path old_inode updated_inode
    load_harness 1.0.0
    old=${CASE_DIR}/old.sh
    new=${CASE_DIR}/new.sh
    write_fixture_script "${old}" 1.0.0 good old
    write_fixture_script "${new}" 1.1.0 good new
    cp -p "${old}" "${SCRIPT_PATH}"
    chmod 0700 "${SCRIPT_PATH}"
    old_hash=$(sha256_file "${SCRIPT_PATH}")
    old_inode=$(inode_of "${SCRIPT_PATH}")
    new_hash=$(sha256_file "${new}")
    TEST_ASSET_FILE=${new}
    TEST_RELEASE_JSON=$(make_release_json 1.1.0 "${new_hash}")
    set +e
    output=$(perform_script_update 2>&1)
    rc=$?
    set -e
    assert_eq 20 "${rc}" '有效更新没有返回切换进程状态'
    assert_file_eq "${new}" "${SCRIPT_PATH}" '有效更新没有安装精确候选'
    assert_eq 700 "$(mode_of "${SCRIPT_PATH}")" '更新后脚本权限错误'
    updated_inode=$(inode_of "${SCRIPT_PATH}")
    [[ ${updated_inode} != "${old_inode}" ]] || fail '更新没有通过替换文件完成'
    IFS=' ' read -r pointer_hash backup_name <"${UPDATE_LAST_BACKUP}"
    backup_path=${UPDATE_BACKUP_DIR}/${backup_name}
    assert_eq "${old_hash}" "${pointer_hash}" '上一版指针哈希错误'
    assert_file_eq "${old}" "${backup_path}" '更新备份与旧脚本不一致'
    assert_no_transaction_residue 'po0-unlock.sh.update'
    [[ ! -e ${TEST_SYSTEMCTL_LOG} ]] || fail '更新脚本时调用了 systemctl'

    SCRIPT_VERSION=1.1.0
    set +e
    output=$(perform_script_restore 2>&1)
    rc=$?
    set -e
    assert_eq 20 "${rc}" '恢复没有返回切换进程状态'
    assert_file_eq "${old}" "${SCRIPT_PATH}" '恢复结果与上一版不一致'
    assert_eq 700 "$(mode_of "${SCRIPT_PATH}")" '恢复后脚本权限错误'
    IFS=' ' read -r pointer_hash backup_name <"${UPDATE_LAST_BACKUP}"
    backup_path=${UPDATE_BACKUP_DIR}/${backup_name}
    assert_eq "${new_hash}" "${pointer_hash}" '恢复后没有把新版本登记为上一版'
    assert_file_eq "${new}" "${backup_path}" '恢复前的新版本备份不正确'
    assert_no_transaction_residue 'po0-unlock.sh.restore'
    [[ ! -e ${TEST_SYSTEMCTL_LOG} ]] || fail '恢复脚本时调用了 systemctl'
}

test_restore_pre_24_script_and_config_together() {
    local old new output rc config_hash
    load_harness 2.3.0
    CONFIG_RELOCATION_VERSION=2.4.0
    CONFIG_DIR=${CASE_DIR}/etc/po0-unlock
    CONFIG_FILE=${CONFIG_DIR}/hosts.conf
    LEGACY_CONFIG_FILE=${CASE_DIR}/root/hosts.conf
    old=${CASE_DIR}/old.sh
    new=${CASE_DIR}/new.sh
    write_fixture_script "${old}" 2.3.0 good config-restore-old
    write_fixture_script "${new}" 2.4.0 good config-restore-new
    cp -p "${old}" "${SCRIPT_PATH}"
    chmod 0700 "${SCRIPT_PATH}"
    TEST_ASSET_FILE=${new}
    TEST_RELEASE_JSON=$(make_release_json 2.4.0 "$(sha256_file "${new}")")
    set +e
    perform_script_update >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq 20 "${rc}" '配置回退夹具未能先更新到 v2.4'

    mkdir -p "${CONFIG_DIR}" "${LEGACY_CONFIG_FILE%/*}"
    chmod 0700 "${CONFIG_DIR}" "${LEGACY_CONFIG_FILE%/*}"
    {
        printf '%s\n' '# 在国外出口 VPS 上使用；不保存任何 SSH 密码。'
        printf '%s\n' 'CN_ENTRY_SSH_USER=root'
        printf '%s\n' 'CN_ENTRY_PRIVATE_IP=10.0.0.2'
        printf '%s\n' 'CN_ENTRY_SSH_PORT=22'
    } >"${CONFIG_FILE}"
    chmod 0600 "${CONFIG_FILE}"
    config_hash=$(sha256_file "${CONFIG_FILE}")

    SCRIPT_VERSION=2.4.0
    eval "$(declare -f write_last_script_backup | sed '1s/^write_last_script_backup /real_write_last_script_backup /')"
    write_last_script_backup() { return 1; }
    set +e
    output=$(perform_script_restore 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 && ${rc} -ne 20 ]] || fail '恢复指针失败时没有停止提交'
    assert_contains "${output}" '当前脚本尚未替换' '恢复指针失败提示不明确'
    assert_file_eq "${new}" "${SCRIPT_PATH}" '恢复指针失败后改变了当前脚本'
    [[ -f ${CONFIG_FILE} && -f ${LEGACY_CONFIG_FILE} ]] \
        || fail '恢复指针失败后没有同时保留新旧版本可用配置'
    assert_eq "${config_hash}" "$(sha256_file "${CONFIG_FILE}")" \
        '恢复指针失败后改变了当前版本配置'
    assert_eq "${config_hash}" "$(sha256_file "${LEGACY_CONFIG_FILE}")" \
        '恢复指针失败后旧版兼容配置与当前配置不一致'
    eval "$(declare -f real_write_last_script_backup | sed '1s/^real_write_last_script_backup /write_last_script_backup /')"

    set +e
    output=$(perform_script_restore 2>&1)
    rc=$?
    set -e
    assert_eq 20 "${rc}" '撤销到 v2.3 没有返回切换进程状态'
    assert_file_eq "${old}" "${SCRIPT_PATH}" '撤销没有恢复 v2.3 脚本'
    [[ ! -e ${CONFIG_FILE} ]] || fail '撤销到 v2.3 后仍保留新配置位置'
    [[ -f ${LEGACY_CONFIG_FILE} ]] || fail '撤销到 v2.3 没有恢复 /root 配置'
    assert_eq "${config_hash}" "$(sha256_file "${LEGACY_CONFIG_FILE}")" \
        '脚本撤销过程中改变了连接配置'
}

test_pointer_failure_never_replaces_target() {
    local old new old_hash new_hash output rc pointer_before target_before output_file
    load_harness 1.0.0
    old=${CASE_DIR}/old.sh
    new=${CASE_DIR}/new.sh
    write_fixture_script "${old}" 1.0.0 good pointer-update-old
    write_fixture_script "${new}" 1.1.0 good pointer-update-new
    cp -p "${old}" "${SCRIPT_PATH}"
    chmod 0700 "${SCRIPT_PATH}"
    old_hash=$(sha256_file "${SCRIPT_PATH}")
    new_hash=$(sha256_file "${new}")
    TEST_ASSET_FILE=${new}
    TEST_RELEASE_JSON=$(make_release_json 1.1.0 "${new_hash}")
    write_last_script_backup() { return 1; }
    output_file=${CASE_DIR}/update-pointer-failure.out
    set +e
    perform_script_update >"${output_file}" 2>&1
    rc=$?
    set -e
    output=$(<"${output_file}")
    [[ ${rc} -ne 0 && ${rc} -ne 20 ]] || fail '指针写失败时更新没有停止'
    assert_contains "${output}" '当前脚本尚未替换' '更新指针故障错误不明确'
    assert_eq "${old_hash}" "$(sha256_file "${SCRIPT_PATH}")" '指针写失败后更新仍替换了目标'
    assert_file_eq "${old}" "${SCRIPT_PATH}" '指针写失败后目标内容异常'
    assert_no_transaction_residue 'po0-unlock.sh.update'

    load_harness 1.0.0
    old=${CASE_DIR}/old.sh
    new=${CASE_DIR}/new.sh
    write_fixture_script "${old}" 1.0.0 good pointer-restore-old
    write_fixture_script "${new}" 1.1.0 good pointer-restore-new
    cp -p "${old}" "${SCRIPT_PATH}"
    chmod 0700 "${SCRIPT_PATH}"
    TEST_ASSET_FILE=${new}
    TEST_RELEASE_JSON=$(make_release_json 1.1.0 "$(sha256_file "${new}")")
    set +e
    perform_script_update >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq 20 "${rc}" '恢复指针故障夹具未能先完成更新'
    SCRIPT_VERSION=1.1.0
    pointer_before=$(sha256_file "${UPDATE_LAST_BACKUP}")
    target_before=$(sha256_file "${SCRIPT_PATH}")
    write_last_script_backup() { return 1; }
    output_file=${CASE_DIR}/restore-pointer-failure.out
    set +e
    perform_script_restore >"${output_file}" 2>&1
    rc=$?
    set -e
    output=$(<"${output_file}")
    [[ ${rc} -ne 0 && ${rc} -ne 20 ]] || fail '指针写失败时恢复没有停止'
    assert_contains "${output}" '当前脚本尚未替换' '恢复指针故障错误不明确'
    assert_eq "${target_before}" "$(sha256_file "${SCRIPT_PATH}")" '指针写失败后恢复仍替换了目标'
    assert_file_eq "${new}" "${SCRIPT_PATH}" '恢复指针写失败后目标内容异常'
    assert_eq "${pointer_before}" "$(sha256_file "${UPDATE_LAST_BACKUP}")" '恢复指针写失败改坏了原指针'
    assert_no_transaction_residue 'po0-unlock.sh.restore'
}

test_restore_confirmation_change_is_rejected() {
    local old new changed output rc backup_count_before backup_count_after
    load_harness 1.0.0
    old=${CASE_DIR}/old.sh
    new=${CASE_DIR}/new.sh
    changed=${CASE_DIR}/changed-during-confirmation.sh
    write_fixture_script "${old}" 1.0.0 good confirmation-old
    write_fixture_script "${new}" 1.1.0 good confirmation-new
    write_fixture_script "${changed}" 1.1.0 good confirmation-tampered
    cp -p "${old}" "${SCRIPT_PATH}"
    chmod 0700 "${SCRIPT_PATH}"
    TEST_ASSET_FILE=${new}
    TEST_RELEASE_JSON=$(make_release_json 1.1.0 "$(sha256_file "${new}")")
    set +e
    perform_script_update >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq 20 "${rc}" '确认竞态夹具未能先完成更新'
    SCRIPT_VERSION=1.1.0
    ASSUME_YES=no
    backup_count_before=$(find "${UPDATE_BACKUP_DIR}" -type f -name '*.backup.*' | wc -l | tr -d '[:space:]')
    read() {
        local argument output_var=
        if [[ $* == *'确认恢复上一版助手'* ]]; then
            cp -p -- "${changed}" "${SCRIPT_PATH}"
            for argument in "$@"; do output_var=${argument}; done
            printf -v "${output_var}" '%s' y
            return 0
        fi
        builtin read "$@"
    }
    set +e
    output=$(perform_script_restore 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 && ${rc} -ne 20 ]] || fail '确认期间目标变化未被拒绝'
    assert_contains "${output}" '确认期间当前脚本发生变化' '恢复确认竞态错误不明确'
    assert_file_eq "${changed}" "${SCRIPT_PATH}" '恢复器覆盖了确认期间发生的外部变化'
    backup_count_after=$(find "${UPDATE_BACKUP_DIR}" -type f -name '*.backup.*' | wc -l | tr -d '[:space:]')
    assert_eq "${backup_count_before}" "${backup_count_after}" '确认竞态拒绝后仍创建了恢复前备份'
    assert_no_transaction_residue 'po0-unlock.sh.restore'
}

test_world_writable_target_is_rejected() {
    local target_hash output rc
    load_harness 1.0.0
    write_fixture_script "${SCRIPT_PATH}" 1.0.0 good world-writable
    chmod 0777 "${SCRIPT_PATH}"
    target_hash=$(sha256_file "${SCRIPT_PATH}")
    set +e
    output=$(perform_script_update 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 && ${rc} -ne 20 ]] || fail '0777 目标脚本没有被拒绝'
    assert_contains "${output}" '可被其他用户写入' '0777 目标拒绝原因不明确'
    assert_eq 777 "$(mode_of "${SCRIPT_PATH}")" '拒绝检查改变了目标权限'
    assert_eq "${target_hash}" "$(sha256_file "${SCRIPT_PATH}")" '0777 目标拒绝后内容改变'
    [[ ! -e ${UPDATE_STATE_ROOT} ]] || fail '0777 目标拒绝后创建了更新状态'
    [[ ! -e ${TEST_REQUEST_LOG} ]] || fail '0777 目标拒绝后仍访问了 GitHub'
}

test_zero_paths_have_no_side_effects() {
    local target_hash output before_tree after_tree
    load_harness 1.0.0
    C_BLUE= C_GREEN= C_YELLOW= C_RED= C_RESET=
    write_fixture_script "${SCRIPT_PATH}" 1.0.0 good zero
    target_hash=$(sha256_file "${SCRIPT_PATH}")
    before_tree=$(find "${CASE_DIR}" -mindepth 1 -maxdepth 2 -print | LC_ALL=C sort)
    output=$(main_menu <<< '0')
    assert_contains "${output}" '已退出' '主菜单 0 未直接退出'
    assert_contains "${output}" '6) 脚本更新与恢复' '主菜单没有显示合并后的脚本管理入口'
    assert_not_contains "${output}" '管理 GitHub 更新令牌' '公开版主菜单仍显示令牌管理入口'
    after_tree=$(find "${CASE_DIR}" -mindepth 1 -maxdepth 2 -print | LC_ALL=C sort)
    assert_eq "${before_tree}" "${after_tree}" '主菜单 0 创建或删除了文件'
    assert_eq "${target_hash}" "$(sha256_file "${SCRIPT_PATH}")" '主菜单 0 改变了脚本'
    [[ ! -e ${TEST_REQUEST_LOG} ]] || fail '主菜单 0 发起了网络请求'
    [[ ! -e ${TEST_SYSTEMCTL_LOG} ]] || fail '主菜单 0 调用了 systemctl'

    before_tree=$(find "${CASE_DIR}" -mindepth 1 -maxdepth 2 -print | LC_ALL=C sort)
    output=$(manage_script_update <<< '0')
    assert_contains "${output}" '1) 检查并更新脚本' '脚本管理菜单缺少更新入口'
    assert_contains "${output}" '2) 恢复上一版助手（不改服务）' '脚本管理菜单缺少上一版恢复入口'
    assert_contains "${output}" '0) 返回主菜单' '脚本管理菜单没有显示返回入口'
    after_tree=$(find "${CASE_DIR}" -mindepth 1 -maxdepth 2 -print | LC_ALL=C sort)
    assert_eq "${before_tree}" "${after_tree}" '脚本管理菜单 0 产生了文件副作用'
    assert_eq "${target_hash}" "$(sha256_file "${SCRIPT_PATH}")" '脚本管理菜单 0 改变了脚本'
    [[ ! -e ${TEST_REQUEST_LOG} ]] || fail '脚本管理菜单 0 发起了网络请求'

}

test_agent_scan_failure_returns_to_main_menu() {
    local output_file output rc scan_calls=0 pause_calls=0 error_count
    load_harness 2.4.4
    output_file=${CASE_DIR}/main-menu-output

    installation_active() { return 1; }
    scan_agent_services() {
        scan_calls=$((scan_calls + 1))
        if (( scan_calls == 1 )); then return 23; fi
        printf '%s\n' 'Agent 扫描重试成功。'
    }
    pause_for_menu() {
        local ignored
        pause_calls=$((pause_calls + 1))
        IFS= read -r -n 1 ignored
    }
    run_cn_entry_operation() { "$@"; }

    set +e
    main_menu <<< $'4\nx4\ny0' >"${output_file}" 2>&1
    rc=$?
    set -e
    output=$(<"${output_file}")
    error_count=$(grep -Fc -- 'Agent 扫描未完成；请检查上方提示，稍后可从主菜单选 4 重试。' \
        "${output_file}" || true)

    assert_eq 0 "${rc}" 'Agent 扫描失败仍终止了主菜单' || return 1
    assert_eq 2 "${scan_calls}" 'Agent 扫描失败后不能从主菜单重试' || return 1
    assert_eq 2 "${pause_calls}" 'Agent 扫描完成后没有正常等待返回主菜单' || return 1
    assert_eq 1 "${error_count}" 'Agent 扫描错误提示次数不正确' || return 1
    assert_contains "${output}" 'Agent 扫描重试成功。' 'Agent 扫描失败后没有执行成功重试' || return 1
    assert_contains "${output}" '已退出。' 'Agent 扫描完成后不能正常退出主菜单' || return 1
}

test_user_visible_branding_terms() {
    local forbidden file path matches
    local -a user_visible_files=(
        README.md
        '使用说明.md'
        setup.sh
        overseas-exit-role.sh
        cn-entry-role.sh
        tools/build-single-file.sh
        po0-unlock.sh
    )

    for forbidden in '香港' '上海' '对端'; do
        for file in "${user_visible_files[@]}"; do
            path=${PROJECT_DIR}/${file}
            [[ -r ${path} ]] || fail "缺少用户可见产物：${file}"
            if matches=$(grep -Fn -- "${forbidden}" "${path}"); then
                fail "用户可见产物 ${file} 重新出现禁用字样：${matches}"
            fi
        done
    done
}

test_legacy_runtime_identifiers_absent() {
    local file path matches pattern
    local region_a='shang''hai' region_b='hong''kong' helper_a='hk-''egress'
    local updater_a='/var/lib/po0-''updater' prefix_a='S''H_' prefix_b='H''K_'
    local -a active_files=(
        README.md
        '使用说明.md'
        setup.sh
        overseas-exit-role.sh
        cn-entry-role.sh
        tools/build-cn-entry-role.sh
        tools/build-single-file.sh
        tests/update-acceptance.sh
        tests/cf-probe-acceptance.sh
        tests/komari-acceptance.sh
        .github/workflows/ci-release.yml
        po0-unlock.sh
    )
    pattern="${region_a}|${region_b}|${helper_a}|${updater_a}|(^|[^[:alnum:]_])(${prefix_a}|${prefix_b})"

    for file in "${active_files[@]}"; do
        path=${PROJECT_DIR}/${file}
        [[ -r ${path} ]] || fail "缺少旧名称检查文件：${file}"
        if matches=$(grep -Ein -- "${pattern}" "${path}"); then
            fail "活动文件 ${file} 仍含 v1 旧名称：${matches}"
        fi
    done
    if matches=$(grep -Erin --include='*.sh.inc' \
        "${pattern}" \
        "${PROJECT_DIR}/src/cn-entry-role"); then
        fail "国内入口模块仍含 v1 旧名称：${matches}"
    fi
}

test_v2_runtime_naming_contract() {
    local setup_source exit_source cn_source workflow asset
    setup_source=$(sed -n '1,$p' "${SETUP_SOURCE}")
    exit_source=$(sed -n '1,$p' "${PROJECT_DIR}/overseas-exit-role.sh")
    cn_source=$(sed -n '1,$p' "${PROJECT_DIR}/cn-entry-role.sh")
    workflow=$(sed -n '1,$p' "${PROJECT_DIR}/.github/workflows/ci-release.yml")

    assert_contains "${setup_source}" 'CN_ENTRY_REMOTE=/usr/local/libexec/po0-unlock-cn-entry' \
        '国内入口固定组件路径未使用 v2 标准名称'
    assert_contains "${setup_source}" 'ADMIN_KEY=/root/.ssh/po0-unlock-admin' \
        '管理密钥未使用 v2 标准名称'
    assert_contains "${setup_source}" 'UPDATE_ASSET=po0-unlock-v2.sh' \
        'v2 没有使用独立 Release 资产'
    assert_contains "${setup_source}" 'UPDATE_STATE_ROOT=/var/lib/po0-unlock/updater' \
        '更新状态未归入 v2 状态目录'
    assert_contains "${setup_source}" 'CN_ENTRY_PRIVATE_IP=' \
        '主控配置缺少国内入口标准字段'

    assert_contains "${exit_source}" 'STATE_ROOT=/var/lib/po0-unlock' \
        '国外出口状态目录未使用 v2 标准名称'
    assert_contains "${exit_source}" 'PROXY_UNIT=/etc/systemd/system/po0-unlock-exit-proxy.service' \
        '国外出口代理服务未使用 v2 标准名称'
    assert_contains "${exit_source}" 'TUNNEL_UNIT=/etc/systemd/system/po0-unlock-reverse-tunnel.service' \
        '反向隧道服务未使用 v2 标准名称'
    assert_contains "${exit_source}" 'TUNNEL_USER=po0tunnel' \
        '专用隧道账户未使用 v2 标准名称'

    assert_contains "${cn_source}" 'STATE_ROOT=/var/lib/po0-unlock' \
        '国内入口状态目录未使用 v2 标准名称'
    assert_contains "${cn_source}" 'HELPER=/usr/local/bin/po0-cn-entry' \
        '国内入口辅助命令未使用 v2 标准名称'
    assert_contains "${cn_source}" 'APT_CONF=/etc/apt/apt.conf.d/90-po0-unlock-proxy' \
        'APT 代理配置未使用 v2 标准名称'
    for asset in \
        dist/po0-unlock-v2.sh \
        dist/po0-unlock-v2.sh.sha256; do
        assert_contains "${workflow}" "${asset}" \
            "公开发布流程缺少 v2 发行资产：${asset}" || return 1
    done
}

test_rollback_waits_for_tunnel_drain() {
    local cn_source rollback_body
    cn_source=$(sed -n '1,$p' "${PROJECT_DIR}/cn-entry-role.sh")
    rollback_body=$(sed -n '/^rollback_finalize() {/,/^}/p' "${PROJECT_DIR}/cn-entry-role.sh")

    assert_contains "${rollback_body}" '正在等待国外出口反向隧道安全退出（最长 30 秒）。' \
        '完整回滚没有向用户说明正在等待隧道退出'
    assert_contains "${rollback_body}" 'for (( attempt = 1; attempt <= 30; attempt++ )); do' \
        '完整回滚没有为正常的 SSH 退出延迟保留 30 秒等待窗口'
    assert_contains "${rollback_body}" 'pgrep -u "${TUNNEL_USER}" >/dev/null 2>&1 || break' \
        '完整回滚等待期间没有在隧道退出后立即继续'
    assert_contains "${cn_source}" \
        "&& die '国外出口反向隧道仍占用专用账户，拒绝形成半回滚状态。'" \
        '超出等待时间后不再保留安全失败保护'
}

test_unfinalized_install_can_begin_rollback() (
    local case_dir fixture_state function_body refresh_marker
    case_dir=$(mktemp -d "${WORK_ROOT}/rollback-unfinalized.XXXXXXXX")
    fixture_state=${case_dir}/state
    mkdir -p "${fixture_state}"
    ACTIVE_FILE=${case_dir}/ACTIVE
    printf '%s\n' "${fixture_state}" >"${ACTIVE_FILE}"
    refresh_marker=${case_dir}/refresh-called

    for function_name in acquire_state_mutation_lock rollback_services; do
        function_body=$(sed -n "/^${function_name}() {/,/^}/p" \
            "${PROJECT_DIR}/cn-entry-role.sh")
        [[ -n ${function_body} ]] \
            || { fail "未能提取 ${function_name}"; return 1; }
        eval "${function_body}"
    done

    CN_ENTRY_LOCK_WAIT_SECONDS=30
    require_root() { :; }
    active_state() { printf '%s\n' "${fixture_state}"; }
    refresh_helper_from_state() {
        : >"${refresh_marker}"
        return 1
    }
    flock() { :; }
    log() { :; }
    die() { printf '%s\n' "$*" >&2; exit 1; }

    rollback_services
    [[ -f ${fixture_state}/closing && ! -L ${fixture_state}/closing ]] \
        || { fail '未完成 finalize 的安装没有进入可继续回滚状态'; return 1; }
    [[ ! -e ${refresh_marker} ]] \
        || { fail '没有托管 Agent 时仍错误刷新了尚未生成的 helper'; return 1; }
)

test_tunnel_home_cleanup_is_safely_retryable() (
    local case_dir fixture_state function_name function_body account_marker
    local fail_cleanup_marker first_output second_output first_rc second_rc arg targets_home
    case_dir=$(mktemp -d "${WORK_ROOT}/rollback-home.XXXXXXXX")
    fixture_state=${case_dir}/state
    mkdir -p "${fixture_state}"
    ACTIVE_FILE=${case_dir}/ACTIVE
    TUNNEL_USER=po0tunnel
    TUNNEL_HOME=${case_dir}/po0tunnel
    APT_CONF=${case_dir}/apt.conf
    PROFILE_CONF=${case_dir}/profile.sh
    HELPER=${case_dir}/helper
    mkdir -p "${TUNNEL_HOME}/.ssh"
    printf '%s\n' "${fixture_state}" >"${ACTIVE_FILE}"
    : >"${fixture_state}/closing"
    : >"${fixture_state}/managed-services"
    : >"${APT_CONF}"
    : >"${PROFILE_CONF}"
    : >"${HELPER}"
    account_marker=${case_dir}/account-present
    fail_cleanup_marker=${case_dir}/fail-cleanup-once
    : >"${account_marker}"
    : >"${fail_cleanup_marker}"

    for function_name in \
        acquire_state_mutation_lock record_tunnel_user_uid \
        read_recorded_tunnel_user_uid rollback_finalize; do
        function_body=$(sed -n "/^${function_name}() {/,/^}/p" "${PROJECT_DIR}/cn-entry-role.sh")
        [[ -n ${function_body} ]] || { fail "未能提取 ${function_name}"; return 1; }
        eval "${function_body}"
    done

    CN_ENTRY_LOCK_WAIT_SECONDS=30
    require_root() { :; }
    active_state() { printf '%s\n' "${fixture_state}"; }
    flock() { :; }
    log() { :; }
    die() { printf '%s\n' "$*" >&2; exit 1; }
    id() {
        if [[ ${1:-} == -u ]]; then
            [[ -e ${account_marker} ]] || return 1
            printf '%s\n' 1234
            return 0
        fi
        [[ ${1:-} == "${TUNNEL_USER}" && -e ${account_marker} ]]
    }
    getent() {
        [[ ${1:-} == passwd && ${2:-} == "${TUNNEL_USER}" ]] || return 1
        printf '%s:x:1234:1234::%s:/usr/sbin/nologin\n' "${TUNNEL_USER}" "${TUNNEL_HOME}"
    }
    pgrep() { return 1; }
    userdel() {
        if [[ ${1:-} == "${TUNNEL_USER}" ]]; then
            command rm -f -- "${account_marker}"
            return 0
        fi
        return 1
    }
    stat() {
        if [[ ${1:-} == -c && ${3:-} == "${TUNNEL_HOME}" && ${2:-} == '%u' ]]; then
            printf '%s\n' 1234
            return 0
        fi
        if [[ ${1:-} == -c && ${3:-} == "${fixture_state}/tunnel-user-uid" ]]; then
            case "${2:-}" in
                '%u') printf '%s\n' 0 ;;
                '%a') printf '%s\n' 600 ;;
                '%h') printf '%s\n' 1 ;;
                *) return 1 ;;
            esac
            return 0
        fi
        command stat "$@"
    }
    mountpoint() { return 1; }
    rm() {
        targets_home=no
        for arg in "$@"; do
            [[ ${arg} == "${TUNNEL_HOME}" ]] && targets_home=yes
        done
        if [[ ${targets_home} == yes ]]; then
            if [[ -e ${fail_cleanup_marker} ]]; then
                command rm -f -- "${fail_cleanup_marker}"
                return 1
            fi
            command rm -rf -- "${TUNNEL_HOME}"
            return
        fi
        command rm "$@"
    }

    set +e
    first_output=$(rollback_finalize 2>&1)
    first_rc=$?
    set -e
    [[ ${first_rc} -ne 0 ]] || { fail '模拟家目录占用时回滚错误报告成功'; return 1; }
    assert_contains "${first_output}" '修正占用后可重试完整回滚' \
        '首次清理失败没有提供可重试提示' || return 1
    [[ -f ${fixture_state}/tunnel-user-uid ]] \
        || { fail '删除账户前没有保存 UID 恢复记录'; return 1; }
    [[ -e ${ACTIVE_FILE} && -d ${TUNNEL_HOME} ]] \
        || { fail '首次清理失败后没有保留可重试状态'; return 1; }
    [[ ! -e ${account_marker} ]] \
        || { fail '测试夹具没有模拟到账户已删除、家目录仍残留'; return 1; }

    set +e
    second_output=$(rollback_finalize 2>&1)
    second_rc=$?
    set -e
    assert_eq 0 "${second_rc}" "第二次完整回滚没有成功：${second_output}"
    [[ ! -e ${TUNNEL_HOME} && ! -L ${TUNNEL_HOME} ]] \
        || { fail '重试后专用隧道家目录仍然残留'; return 1; }
    [[ ! -e ${ACTIVE_FILE} && -f ${fixture_state}/ACTIVE.closed ]] \
        || { fail '重试成功后没有提交 ACTIVE.closed'; return 1; }
)

test_status_uses_current_embedded_role() {
    local function_body selector_body validator_body
    function_body=$(sed -n '/^status_all_loaded() (/,/^)/p' "${SETUP_SOURCE}")
    selector_body=$(sed -n '/^select_current_cn_entry_role() {/,/^}/p' "${SETUP_SOURCE}")
    validator_body=$(sed -n '/^installed_cn_entry_role_is_current() {/,/^}/p' "${SETUP_SOURCE}")
    assert_contains "${function_body}" 'select_current_cn_entry_role status_remote status_remote_temporary' \
        '状态检查没有安全选择当前脚本对应的国内入口组件'
    assert_contains "${function_body}" \
        "ssh_cn_entry_component \"\${CN_ENTRY_TIMEOUT_STATUS}\" read-only '状态检查'" \
        '状态检查没有调用当前脚本内嵌的国内入口组件'
    assert_contains "${selector_body}" 'upload_temporary_cn_entry_role "${path_var}"' \
        '已安装组件不一致时不会回退到当前内嵌组件' || return 1
    assert_contains "${validator_body}" 'expected_hash=$(sha256sum "${CN_ENTRY_ROLE_LOCAL}"' \
        '复用已安装组件前没有以当前内嵌组件计算预期哈希' || return 1
}

test_installed_install_returns_to_menu() {
    local output rc
    load_harness 1.1.5
    installation_active() { return 0; }
    configure() { fail '已安装提示后仍进入了安装配置'; }
    set +e
    output=$(guided_install 2>&1)
    rc=$?
    set -e
    assert_eq 0 "${rc}" '已安装时再次选择一键安装仍然退出脚本'
    assert_contains "${output}" '检测到本方案已经安装' '已安装时没有显示明确提示'
    assert_contains "${output}" '更新连接配置' '已安装提示没有给出下一步操作'
}

test_rollback_confirmation_returns_safely() {
    local output rc
    load_harness 2.4.1
    ASSUME_YES=no
    load_config() { fail '取消完整回滚后仍读取连接配置'; }
    pause_for_menu() { fail '取消完整回滚后仍要求再次按键'; }
    preflight() { fail '取消完整回滚后仍进入预检'; }
    upload_cn_entry_role() { fail '取消完整回滚后仍上传组件'; }

    set +e
    output=$(rollback_all menu <<< $'误触\n0' 2>&1)
    rc=$?
    set -e
    assert_eq 0 "${rc}" '输入 0 取消完整回滚没有正常返回'
    assert_contains "${output}" '输入无效，请输入 ROLLBACK 继续，或输入 0 返回。' \
        '无效输入没有留在完整回滚确认界面'
    assert_contains "${output}" '已取消完整回滚，服务器未做任何修改。' \
        '输入 0 后没有明确说明服务器未被修改'
    assert_not_contains "${output}" '[Po0 解锁助手] 错误：用户取消。' \
        '取消完整回滚仍被当作脚本错误'

    set +e
    confirm ROLLBACK '确认测试' <<< 'ROLLBACK' >/dev/null 2>&1
    rc=$?
    set -e
    assert_eq 0 "${rc}" '精确输入 ROLLBACK 不再允许继续'
}

test_confirmation_eof_is_safe_cancel() {
    local output_file output rc read_calls=0
    load_harness 2.4.4
    ASSUME_YES=no
    output_file=${CASE_DIR}/confirm-output

    read() {
        read_calls=$((read_calls + 1))
        if (( read_calls == 1 )); then return 1; fi
        printf -v answer '%s' 0
        return 0
    }

    set +e
    confirm ROLLBACK '确认测试' >"${output_file}" 2>&1
    rc=$?
    set -e
    unset -f read
    output=$(<"${output_file}")

    assert_eq 1 "${rc}" '确认输入遇到 EOF 没有按取消返回' || return 1
    assert_eq 1 "${read_calls}" '确认输入遇到 EOF 后仍继续读取' || return 1
    assert_not_contains "${output}" '输入无效' '确认输入把 EOF 误报为无效输入' || return 1
}

test_script_backup_retention() {
    local source protected pointer_name manual_dir unsafe rc index count
    local -a backups=()
    load_harness 2.4.2
    acquire_script_update_lock
    manual_dir=${UPDATE_STATE_ROOT}/manual-candidates
    mkdir -p -- "${manual_dir}"
    printf '%s\n' '人工候选不得自动清理' >"${manual_dir}/po0-unlock.manual.backup"

    for index in 0 1 2 3 4; do
        source=${CASE_DIR}/source-${index}.sh
        write_fixture_script "${source}" "1.0.${index}" good "retention-${index}"
        backups[${index}]=$(create_script_backup "${source}" "1.0.${index}") \
            || fail "无法创建第 ${index} 份轮换测试备份"
        touch -t "20260101010${index}.00" "${backups[${index}]}"
    done
    protected=${backups[0]}
    write_last_script_backup "${protected}" || fail '无法登记轮换测试恢复点'
    prune_script_backups "${protected}" || fail '正常备份轮换失败'

    count=$(find "${UPDATE_BACKUP_DIR}" -maxdepth 1 -type f -name '*.backup.*' | wc -l | tr -d '[:space:]')
    assert_eq 3 "${count}" '正常更新备份没有限制为 3 份'
    [[ -f ${protected} ]] || fail '当前菜单恢复点被备份轮换删除'
    [[ -f ${backups[3]} && -f ${backups[4]} ]] || fail '备份轮换没有保留最新的两份普通备份'
    [[ ! -e ${backups[1]} && ! -e ${backups[2]} ]] || fail '备份轮换没有删除最旧的普通备份'
    IFS=' ' read -r _ pointer_name <"${UPDATE_LAST_BACKUP}"
    assert_eq "${protected##*/}" "${pointer_name}" '备份轮换改变了当前恢复点记录'
    [[ -f ${manual_dir}/po0-unlock.manual.backup ]] || fail '备份轮换误删人工候选目录'

    source=${CASE_DIR}/source-extra.sh
    write_fixture_script "${source}" 1.0.5 good retention-extra
    backups[5]=$(create_script_backup "${source}" 1.0.5) || fail '无法创建异常保护测试备份'
    unsafe=${UPDATE_BACKUP_DIR}/po0-unlock.v9.9.9.backup.symlink
    ln -s -- "${source}" "${unsafe}"
    set +e
    prune_script_backups "${protected}"
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || fail '备份目录中的符号链接没有阻止自动清理'
    count=$(find "${UPDATE_BACKUP_DIR}" -maxdepth 1 -type f -name '*.backup.*' | wc -l | tr -d '[:space:]')
    assert_eq 4 "${count}" '发现异常备份后仍删除了普通备份'
    [[ -L ${unsafe} ]] || fail '异常备份保护擅自删除了符号链接'
    [[ -f ${manual_dir}/po0-unlock.manual.backup ]] || fail '异常备份保护影响了人工候选目录'
}

test_any_key_return_copy() {
    local source
    source=$(<"${SETUP_SOURCE}")
    assert_contains "${source}" "pause_for_key '按任意键返回主菜单……'" \
        '主菜单仍未使用任意键返回'
    assert_contains "${source}" "pause_for_key '按任意键返回脚本更新与恢复……'" \
        '脚本管理菜单仍未使用任意键返回'
    assert_contains "${source}" 'IFS= read -r -s -n 1 ignored' \
        '任意键返回没有读取单个按键'
    assert_not_contains "${source}" '按回车返回' '源码仍残留按回车返回提示'
}

test_direct_update_and_restore_do_not_open_menu() {
    local output rc
    load_harness 1.2.3

    perform_script_update() { return 20; }
    perform_script_restore() { return 20; }

    set +e
    output=$(run_script_update 2>&1)
    rc=$?
    set -e
    assert_eq 0 "${rc}" '直接更新成功后没有正常结束'
    assert_not_contains "${output}" '正在切换到新版本进程' \
        '直接更新成功后仍尝试打开交互菜单'

    set +e
    output=$(run_script_restore 2>&1)
    rc=$?
    set -e
    assert_eq 0 "${rc}" '直接恢复成功后没有正常结束'
    assert_not_contains "${output}" '正在切换到撤销更新后的脚本进程' \
        '直接恢复成功后仍尝试打开交互菜单'

    assert_contains "$(<"${SETUP_SOURCE}")" 'run_script_update menu' \
        '交互菜单更新没有保留切换新版本界面的调用方式'
    assert_contains "$(<"${SETUP_SOURCE}")" 'run_script_restore menu' \
        '交互菜单恢复没有保留切换恢复后界面的调用方式'
}

test_reentry_preserves_assume_yes() {
    local target output handoff_body update_body restore_body
    load_harness 1.2.3
    target=${CASE_DIR}/reentry-target.sh
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "<%s>\n" "$@"' >"${target}"

    ASSUME_YES=yes
    output=$(exec_script_preserving_mode "${target}" status 'two words')
    assert_eq $'<--yes>\n<status>\n<two words>' "${output}" \
        '无人值守模式在脚本重入时没有保留 --yes 或原参数边界' || return 1

    ASSUME_YES=no
    output=$(exec_script_preserving_mode "${target}" status)
    assert_eq '<status>' "${output}" \
        '普通模式在脚本重入时意外增加了 --yes' || return 1

    handoff_body=$(sed -n '/^handoff_to_official_script() {/,/^}/p' "${SETUP_SOURCE}")
    update_body=$(sed -n '/^run_script_update() {/,/^}/p' "${SETUP_SOURCE}")
    restore_body=$(sed -n '/^run_script_restore() {/,/^}/p' "${SETUP_SOURCE}")
    assert_contains "${handoff_body}" 'exec_script_preserving_mode "${OFFICIAL_SCRIPT_PATH}" "$@"' \
        '正式入口交接绕过了运行模式保留函数' || return 1
    assert_contains "${update_body}" 'exec_script_preserving_mode "${SCRIPT_PATH}"' \
        '更新后的菜单重入绕过了运行模式保留函数' || return 1
    assert_contains "${restore_body}" 'exec_script_preserving_mode "${LEGACY_SCRIPT_PATH}"' \
        '恢复旧入口后的菜单重入绕过了运行模式保留函数' || return 1
    assert_contains "${restore_body}" 'exec_script_preserving_mode "${SCRIPT_PATH}"' \
        '恢复当前入口后的菜单重入绕过了运行模式保留函数' || return 1
}

test_admin_ssh_bootstrap_uses_dedicated_host_key_policy() (
    local output args log rc
    load_harness 2.5.4
    ADMIN_KEY=${CASE_DIR}/admin-key
    ADMIN_KNOWN_HOSTS=${CASE_DIR}/admin-known-hosts
    printf '%s\n' 'fixture private key' >"${ADMIN_KEY}"
    printf '%s\n' 'ssh-ed25519 AAAATEST po0-test' >"${ADMIN_KEY}.pub"
    chmod 0600 "${ADMIN_KEY}"
    chmod 0644 "${ADMIN_KEY}.pub"
    CN_ENTRY_PRIVATE_IP=10.0.0.30
    CN_ENTRY_SSH_PORT=2222
    EXIT_PRIVATE_IP=10.0.0.20
    log=${CASE_DIR}/authorize-ssh.log
    ensure_admin_key() { :; }
    ssh() { printf '%s\n' "$*" >"${log}"; return 0; }
    ssh_cn_entry() { return 0; }

    output=$(authorize current 2>&1)
    args=$(<"${log}")
    assert_contains "${args}" 'StrictHostKeyChecking=ask' \
        '首次授权没有要求用户确认 SSH 主机密钥' || return 1
    assert_contains "${args}" "UserKnownHostsFile=${ADMIN_KNOWN_HOSTS}" \
        '首次授权没有使用项目专用 known_hosts' || return 1
    assert_contains "${args}" 'GlobalKnownHostsFile=/dev/null' \
        '首次授权仍可能读取系统全局 known_hosts' || return 1
    assert_contains "${args}" 'IdentitiesOnly=yes' \
        '首次授权没有限制为项目专用管理密钥' || return 1
    assert_not_contains "${args}" 'IdentitiesOnly=no' \
        '首次授权仍允许尝试其他本地密钥' || return 1
    assert_contains "${output}" '主机指纹' \
        '首次授权没有提示用户核对主机指纹' || return 1
    assert_eq 600 "$(mode_of "${ADMIN_KNOWN_HOSTS}")" \
        '项目专用 known_hosts 权限不是 0600' || return 1
)

test_fresh_install_refuses_claimed_entry_before_authorization() (
    local output rc remote_home
    load_harness 2.5.13
    ADMIN_KEY=${CASE_DIR}/admin-key
    ADMIN_KNOWN_HOSTS=${CASE_DIR}/admin-known-hosts
    CN_ENTRY_ACTIVE_FILE=${CASE_DIR}/remote-state/ACTIVE
    remote_home=${CASE_DIR}/remote-root
    mkdir -p -- "${CN_ENTRY_ACTIVE_FILE%/*}" "${remote_home}"
    printf '%s\n' '/var/lib/po0-unlock/existing-state' >"${CN_ENTRY_ACTIVE_FILE}"
    printf '%s\n' 'fixture private key' >"${ADMIN_KEY}"
    printf '%s\n' 'ssh-ed25519 AAAATEST po0-test' >"${ADMIN_KEY}.pub"
    chmod 0600 "${ADMIN_KEY}"
    chmod 0644 "${ADMIN_KEY}.pub"
    CN_ENTRY_PRIVATE_IP=10.0.0.30
    CN_ENTRY_SSH_PORT=2222
    EXIT_PRIVATE_IP=10.0.0.20
    ensure_admin_key() { :; }
    recover_admin_known_hosts_after_reinstall() {
        fail '入口已被占用时仍错误进入了 SSH 指纹恢复流程'
    }
    ssh_cn_entry() { fail '入口已被占用时仍建立了后续管理会话'; }
    ssh() {
        HOME=${remote_home} /bin/bash -c "${!#}"
    }

    set +e
    output=$(authorize current require-unclaimed 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail '新出口机仍可授权到已有 ACTIVE 的国内入口'; return 1; }
    [[ ! -e ${remote_home}/.ssh/authorized_keys ]] \
        || { fail '拒绝已占用入口前仍追加了新出口机管理密钥'; return 1; }
    assert_contains "${output}" '已经部署 Po0' \
        '入口占用拒绝没有给出明确原因' || return 1
)

test_install_rechecks_entry_claim_before_any_component_write() (
    local output rc write_log=${WORK_ROOT}/claimed-entry-write.log
    load_harness 2.5.13
    CN_ENTRY_ACTIVE_FILE=/var/lib/po0-unlock/ACTIVE
    CN_ENTRY_PRIVATE_IP=192.0.2.10
    CN_ENTRY_SSH_PORT=2222
    EXIT_PRIVATE_IP=192.0.2.20
    : >"${write_log}"
    load_config() { :; }
    preflight() { :; }
    ssh_cn_entry() {
        case "$*" in
            *"${CN_ENTRY_ACTIVE_FILE}"*) printf '%s\n' ACTIVE ;;
            *) printf 'SSH-WRITE:%s\n' "$*" >>"${write_log}"; return 91 ;;
        esac
    }
    upload_cn_entry_role() { printf '%s\n' UPLOAD >>"${write_log}"; }
    run_exit_role() { printf 'EXIT-WRITE:%s\n' "$*" >>"${write_log}"; }

    set +e
    output=$(install_core 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail '组件写入前发现已有 ACTIVE 仍继续安装'; return 1; }
    [[ ! -s ${write_log} ]] \
        || { fail "入口占用复核前后发生了写操作：$(<"${write_log}")"; return 1; }
    assert_contains "${output}" '已经由另一套 Po0 部署占用' \
        '组件写入前的入口占用复核没有给出明确提示' || return 1
)

test_claimed_install_cleanup_cannot_rollback_another_deployment() (
    local case_dir fixture_state function_name function_body output rc marker
    local owner_claim other_claim
    load_harness 2.5.13
    case_dir=${CASE_DIR}/claimed-cleanup
    fixture_state=${case_dir}/state/20260805T010203Z
    STATE_ROOT=${case_dir}/state
    ACTIVE_FILE=${STATE_ROOT}/ACTIVE
    marker=${case_dir}/rollback-called
    owner_claim=$(printf 'a%.0s' {1..64})
    other_claim=$(printf 'b%.0s' {1..64})
    mkdir -p -- "${fixture_state}"
    chmod 0700 "${STATE_ROOT}" "${fixture_state}"
    printf '%s\n' "${fixture_state}" >"${ACTIVE_FILE}"
    printf '%s\n' "${owner_claim}" >"${fixture_state}/install-claim"
    chmod 0600 "${ACTIVE_FILE}" "${fixture_state}/install-claim"

    for function_name in \
        managed_root_file_safe active_state valid_install_claim install_claim_record_safe \
        active_install_claim_matches \
        rollback_services_claimed; do
        function_body=$(sed -n "/^${function_name}() {/,/^}/p" "${PROJECT_DIR}/cn-entry-role.sh")
        [[ -n ${function_body} ]] \
            || { fail "未能提取国内入口 ${function_name} 函数"; return 1; }
        eval "${function_body}"
    done
    require_root() { :; }
    die() { printf '%s\n' "$*" >&2; exit 1; }
    rollback_services() { : >"${marker}"; }

    set +e
    output=$(rollback_services_claimed "${other_claim}" 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 && ! -e ${marker} ]] \
        || { fail '错误事务标识仍触发了其他部署的 Agent 回滚'; return 1; }
    assert_contains "${output}" '事务标识不匹配' \
        '错误事务标识没有给出所有权拒绝原因' || return 1

    rollback_services_claimed "${owner_claim}"
    [[ -e ${marker} ]] \
        || { fail '正确事务标识不能继续清理本次安装'; return 1; }
)

test_concurrent_install_failure_never_uses_unclaimed_rollback() (
    local output rc log claim
    load_harness 2.5.13
    log=${CASE_DIR}/concurrent-install.log
    claim=$(printf 'c%.0s' {1..64})
    CN_ENTRY_PRIVATE_IP=192.0.2.10
    CN_ENTRY_SSH_PORT=2222
    EXIT_PRIVATE_IP=192.0.2.20
    CN_ENTRY_REMOTE=/usr/local/libexec/po0-unlock-cn-entry
    : >"${log}"
    load_config() { :; }
    preflight() { :; }
    assert_cn_entry_unclaimed() { :; }
    new_install_claim() { printf '%s\n' "${claim}"; }
    upload_cn_entry_role() { printf '%s\n' UPLOAD >>"${log}"; }
    run_exit_role() {
        printf 'EXIT:%s\n' "$*" >>"${log}"
        case "${1:-}" in
            public-key-b64) printf '%s\n' Zml4dHVyZS1wdWJsaWMta2V5 ;;
        esac
    }
    ssh_cn_entry() {
        printf 'SSH:%s\n' "$*" >>"${log}"
        case "$*" in
            *"'${CN_ENTRY_REMOTE}' prepare "*) return 81 ;;
            *"'${CN_ENTRY_REMOTE}' '${CN_ENTRY_CMD_CLAIM_STATUS}' "*) return 1 ;;
            *) return 0 ;;
        esac
    }
    ssh_cn_entry_component() { shift 3; ssh_cn_entry "$@"; }

    set +e
    output=$(install_core 2>&1)
    rc=$?
    set -e
    [[ ${rc} -eq 81 ]] \
        || { fail "并发 prepare 失败没有保留原退出状态：${rc}，${output}"; return 1; }
    assert_contains "$(<"${log}")" "'${CN_ENTRY_CMD_CLAIM_STATUS}' '${claim}'" \
        'prepare 结果不确定时没有只读确认本次事务所有权' || return 1
    assert_not_contains "$(<"${log}")" "'${CN_ENTRY_CMD_ROLLBACK_SERVICES}'" \
        '并发安装失败仍调用了无事务保护的 Agent 回滚' || return 1
    assert_not_contains "$(<"${log}")" "'${CN_ENTRY_CMD_ROLLBACK_FINALIZE}'" \
        '并发安装失败仍调用了无事务保护的最终回滚' || return 1
    assert_not_contains "$(<"${log}")" "'${CN_ENTRY_CMD_ROLLBACK_SERVICES_CLAIMED}'" \
        '事务标识不属于本次安装时仍尝试国内入口回滚' || return 1
    assert_contains "$(<"${log}")" 'EXIT:rollback' \
        '并发安装失败没有回滚本机已准备的国外出口' || return 1

    : >"${log}"
    ssh_cn_entry() {
        printf 'SSH:%s\n' "$*" >>"${log}"
        case "$*" in
            *"'${CN_ENTRY_REMOTE}' prepare "*) return 82 ;;
            *"'${CN_ENTRY_REMOTE}' '${CN_ENTRY_CMD_CLAIM_STATUS}' "*) return 0 ;;
            *) return 0 ;;
        esac
    }
    set +e
    output=$(install_core 2>&1)
    rc=$?
    set -e
    [[ ${rc} -eq 82 ]] \
        || { fail "本次 prepare 已提交时没有保留原退出状态：${rc}，${output}"; return 1; }
    assert_contains "$(<"${log}")" \
        "'${CN_ENTRY_CMD_ROLLBACK_SERVICES_CLAIMED}' '${claim}'" \
        '确认属于本次事务后没有使用带所有权保护的 Agent 回滚' || return 1
    assert_contains "$(<"${log}")" \
        "'${CN_ENTRY_CMD_ROLLBACK_FINALIZE_CLAIMED}' '${claim}'" \
        '确认属于本次事务后没有使用带所有权保护的最终回滚' || return 1
    assert_not_contains "$(<"${log}")" "'${CN_ENTRY_CMD_ROLLBACK_SERVICES}'" \
        '本次事务失败清理仍退回了无保护回滚' || return 1
)

test_reinstalled_host_key_uses_explicit_recovery_wizard() (
    local output rc host old_public new_public ssh_log backup old_fingerprint new_fingerprint
    load_harness 2.5.12
    ADMIN_KEY=${CASE_DIR}/admin-key
    ADMIN_KNOWN_HOSTS=${CASE_DIR}/admin-known-hosts
    printf '%s\n' 'fixture private key' >"${ADMIN_KEY}"
    printf '%s\n' 'ssh-ed25519 AAAATEST po0-test' >"${ADMIN_KEY}.pub"
    chmod 0600 "${ADMIN_KEY}"
    chmod 0644 "${ADMIN_KEY}.pub"
    CN_ENTRY_PRIVATE_IP=10.0.0.30
    CN_ENTRY_SSH_PORT=2222
    EXIT_PRIVATE_IP=10.0.0.20
    host='[10.0.0.30]:2222'
    ssh_log=${CASE_DIR}/authorize-ssh.log
    ssh-keygen -q -t ed25519 -N '' -f "${CASE_DIR}/old-host"
    ssh-keygen -q -t ed25519 -N '' -f "${CASE_DIR}/new-host"
    old_public=$(<"${CASE_DIR}/old-host.pub")
    new_public=$(<"${CASE_DIR}/new-host.pub")
    printf '%s %s\n' "${host}" "${old_public}" >"${ADMIN_KNOWN_HOSTS}"
    chmod 0600 "${ADMIN_KNOWN_HOSTS}"
    ssh-keyscan() { printf '%s %s\n' "${host}" "${new_public}"; }
    ssh() {
        printf '%s\n' "$*" >>"${ssh_log}"
        if grep -Fq -- "${old_public}" "${ADMIN_KNOWN_HOSTS}"; then return 255; fi
        return 0
    }
    ssh_cn_entry() { return 0; }
    ensure_admin_key() { :; }

    set +e
    output=$(authorize current </dev/null 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail '没有确认 REPLACE 时重装指纹向导仍继续'; return 1; }
    assert_contains "${output}" '检测到国内入口 SSH 主机指纹发生变化' \
        '重装指纹变化时没有进入显式恢复向导' || return 1
    assert_contains "${output}" '自动模式也不能跳过这一步' \
        '重装指纹向导没有明确禁止 --yes 绕过人工核验' || return 1
    assert_contains "$(<"${ADMIN_KNOWN_HOSTS}")" "${old_public}" \
        '取消重装指纹恢复后旧记录被改写' || return 1

    set +e
    output=$(printf '%s\n' 0 | authorize current 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail '输入 0 后重装指纹向导仍继续'; return 1; }
    assert_contains "${output}" '旧 SSH 主机密钥记录保持不变' \
        '取消重装指纹恢复后没有明确保留旧记录' || return 1

    : >"${ssh_log}"
    output=$(printf '%s\n' REPLACE | authorize current 2>&1)
    assert_contains "${output}" '旧指纹：' \
        '重装指纹向导没有显示旧指纹' || return 1
    assert_contains "${output}" '新指纹：' \
        '重装指纹向导没有显示新指纹' || return 1
    assert_contains "${output}" '旧记录备份：' \
        '重装指纹替换后没有显示备份路径' || return 1
    assert_contains "$(<"${ADMIN_KNOWN_HOSTS}")" "${new_public}" \
        '确认重装指纹恢复后没有写入新主机密钥' || return 1
    assert_not_contains "$(<"${ADMIN_KNOWN_HOSTS}")" "${old_public}" \
        '确认重装指纹恢复后仍保留旧主机密钥' || return 1
    backup=$(find "${CASE_DIR}" -maxdepth 1 -name 'admin-known-hosts.backup.*' -type f -print -quit)
    [[ -n ${backup} ]] || { fail '重装指纹恢复没有生成旧 known_hosts 备份'; return 1; }
    printf '%s %s\n' "${host}" "${old_public}" >"${CASE_DIR}/expected-old-known-hosts"
    assert_file_eq "${CASE_DIR}/expected-old-known-hosts" "${backup}" \
        '重装指纹恢复生成的备份不是替换前的完整记录' || return 1
    [[ $(grep -Fc -- 'StrictHostKeyChecking=ask' "${ssh_log}") -eq 2 ]] \
        || { fail '重装指纹恢复没有先失败再使用新记录重试授权'; return 1; }
    old_fingerprint=$(ssh-keygen -E sha256 -lf "${CASE_DIR}/old-host.pub" | awk '$2 ~ /^SHA256:/ {print $2}')
    new_fingerprint=$(ssh-keygen -E sha256 -lf "${CASE_DIR}/new-host.pub" | awk '$2 ~ /^SHA256:/ {print $2}')
    assert_contains "${output}" "${old_fingerprint}" \
        '重装指纹向导显示的旧指纹不正确' || return 1
    assert_contains "${output}" "${new_fingerprint}" \
        '重装指纹向导显示的新指纹不正确' || return 1

    assert_contains "$(<"${SETUP_SOURCE}")" '自动模式也不能跳过这一步' \
        '源码没有保留 --yes 不得绕过重装指纹核验的安全约束' || return 1
    assert_contains "$(<"${SETUP_SOURCE}")" 'ssh-keyscan -4 -T 8 -t ed25519' \
        '源码没有使用限定类型和超时的 SSH 指纹候选扫描' || return 1
)

test_cn_entry_session_requires_trusted_host_key_file() (
    local output rc master_attempts=0
    load_harness 2.5.4
    CN_ENTRY_CONTROL_BASE=${CASE_DIR}/run
    mkdir -p -- "${CN_ENTRY_CONTROL_BASE}"
    ADMIN_KEY=${CASE_DIR}/admin-key
    ADMIN_KNOWN_HOSTS=${CASE_DIR}/missing-known-hosts
    : >"${ADMIN_KEY}"
    CN_ENTRY_PRIVATE_IP=10.0.0.30
    CN_ENTRY_SSH_PORT=2222
    EXIT_PRIVATE_IP=10.0.0.20
    CN_ENTRY_TARGET=root@10.0.0.30
    ssh() {
        master_attempts=$((master_attempts + 1))
        return 0
    }

    set +e
    output=$(start_cn_entry_session 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail '缺少专用 known_hosts 时仍建立了国内入口 SSH 会话'; return 1; }
    [[ ${master_attempts} -eq 0 ]] \
        || { fail '缺少专用 known_hosts 时仍尝试 SSH 建连'; return 1; }
    assert_contains "${output}" '主机密钥记录缺失或权限异常' \
        '缺少专用 known_hosts 时错误提示不明确' || return 1
    [[ -z $(find "${CN_ENTRY_CONTROL_BASE}" -mindepth 1 -maxdepth 1 -print -quit) ]] \
        || { fail '拒绝不受信主机时创建了临时 SSH 控制目录'; return 1; }
)

test_cn_entry_session_retries_and_reuses_transport() (
    local output rc master_attempts=0 control_checks=0 remote_commands=0 scp_calls=0
    local control_exits=0 sleep_log=${WORK_ROOT}/ssh-session-sleep.log last_scp_args=
    local session_live=no
    load_harness 2.5.1
    CN_ENTRY_CONTROL_BASE=${CASE_DIR}/run
    OPERATION_LOCK_DIR=${CASE_DIR}/operation-lock
    OPERATION_LOCK_FILE=${OPERATION_LOCK_DIR}/operation.lock
    mkdir -p -- "${CN_ENTRY_CONTROL_BASE}"
    CN_ENTRY_SSH_USER=root
    CN_ENTRY_PRIVATE_IP=192.0.2.10
    CN_ENTRY_SSH_PORT=2222
    EXIT_PRIVATE_IP=192.0.2.20
    CN_ENTRY_TARGET=root@192.0.2.10
    ADMIN_KEY=${CASE_DIR}/admin-key
    ADMIN_KNOWN_HOSTS=${CASE_DIR}/admin-known-hosts
    : >"${ADMIN_KEY}"
    : >"${ADMIN_KNOWN_HOSTS}"
    chmod 0600 "${ADMIN_KNOWN_HOSTS}"

    ssh() {
        case " $* " in
            *' -MNf '*)
                master_attempts=$((master_attempts + 1))
                if (( master_attempts >= 3 )); then session_live=yes; return 0; fi
                return 1
                ;;
            *' -O check '*)
                control_checks=$((control_checks + 1))
                return 0
                ;;
            *' -O exit '*)
                control_exits=$((control_exits + 1))
                return 0
                ;;
            *)
                remote_commands=$((remote_commands + 1))
                return 0
                ;;
        esac
    }
    cn_entry_control_alive() {
        [[ ${session_live} == yes ]] || return 1
        ssh -S "${CN_ENTRY_CONTROL_PATH}" -O check "${CN_ENTRY_TARGET}" >/dev/null 2>&1
    }
    scp() {
        scp_calls=$((scp_calls + 1))
        last_scp_args=$*
        return 0
    }
    sleep() { printf '%s\n' "$1" >>"${sleep_log}"; }

    ssh_cn_entry 'touch /fixture/remote-command'
    scp_cn_entry "${ADMIN_KEY}" root@192.0.2.10:/fixture/upload
    ssh_cn_entry true

    [[ ${master_attempts} -eq 3 ]] \
        || { fail "首次会话没有在两次连接失败后进行第三次尝试（实际 ${master_attempts}）"; return 1; }
    [[ ${remote_commands} -eq 2 ]] \
        || { fail "建连重试导致远端命令重复或丢失（实际 ${remote_commands}）"; return 1; }
    [[ ${scp_calls} -eq 1 ]] \
        || { fail "文件上传没有复用同一连接会话（实际 ${scp_calls}）"; return 1; }
    assert_contains "${last_scp_args}" "ControlPath=${CN_ENTRY_CONTROL_PATH}" \
        '文件上传没有使用当前 SSH 控制路径' || return 1
    assert_contains "${last_scp_args}" 'ControlMaster=no' \
        '文件上传可能绕过已验证会话自行建立连接' || return 1
    assert_contains "${last_scp_args}" "UserKnownHostsFile=${ADMIN_KNOWN_HOSTS}" \
        '文件上传没有使用项目专用 known_hosts' || return 1
    assert_contains "${last_scp_args}" 'StrictHostKeyChecking=yes' \
        '文件上传没有保持严格主机密钥校验' || return 1
    [[ ${control_checks} -eq 2 ]] \
        || { fail "复用连接前没有检查控制会话（实际 ${control_checks}）"; return 1; }
    [[ $(tr '\n' ',' <"${sleep_log}") == '1,2,' ]] \
        || { fail '建连失败没有使用有上限的 1 秒、2 秒退避'; return 1; }
    [[ $(cn_entry_initial_attempt_count) == 3 ]] \
        || { fail '两次失败、第三次成功没有记录为 3 次初始建连'; return 1; }

    control_dir=${CN_ENTRY_CONTROL_DIR}
    cleanup_cn_entry_session
    [[ ${control_exits} -eq 1 && ! -e ${control_dir} ]] \
        || { fail '操作结束没有关闭控制会话并清理临时目录'; return 1; }

    wrapper_log=${CASE_DIR}/nested-session.log
    ssh() {
        case " $* " in
            *' -MNf '*) printf '%s\n' MASTER >>"${wrapper_log}"; : >"${CN_ENTRY_CONTROL_PATH}" ;;
            *' -O check '*) printf '%s\n' CHECK >>"${wrapper_log}" ;;
            *' -O exit '*) printf '%s\n' EXIT >>"${wrapper_log}" ;;
            *) printf '%s\n' REMOTE >>"${wrapper_log}" ;;
        esac
        return 0
    }
    cn_entry_control_alive() {
        [[ -e ${CN_ENTRY_CONTROL_PATH:-} ]] || return 1
        ssh -S "${CN_ENTRY_CONTROL_PATH}" -O check "${CN_ENTRY_TARGET}" >/dev/null 2>&1
    }
    nested_remote_action() (
        ssh_cn_entry 'touch /fixture/nested-command'
        printf 'COUNT=%s\n' "$(cn_entry_initial_attempt_count)" >>"${wrapper_log}"
    )
    run_cn_entry_operation nested_remote_action
    [[ $(grep -Fc MASTER "${wrapper_log}") -eq 1 \
        && $(grep -Fc REMOTE "${wrapper_log}") -eq 1 \
        && $(grep -Fc EXIT "${wrapper_log}") -eq 1 \
        && $(grep -Fxc COUNT=1 "${wrapper_log}") -eq 1 ]] \
        || { fail '嵌套健康检查式操作没有复用并清理父级会话'; return 1; }
    [[ -z $(find "${CN_ENTRY_CONTROL_BASE}" -mindepth 1 -maxdepth 1 -print -quit) ]] \
        || { fail '嵌套操作结束后残留 SSH 控制目录'; return 1; }

    master_attempts=0
    remote_commands=0
    session_live=no
    ssh() {
        case " $* " in
            *' -MNf '*) master_attempts=$((master_attempts + 1)); return 255 ;;
            *' -O exit '*) return 0 ;;
            *) remote_commands=$((remote_commands + 1)); return 0 ;;
        esac
    }
    set +e
    ssh_cn_entry 'touch /fixture/must-not-run' >"${CASE_DIR}/failed-session.log" 2>&1
    rc=$?
    set -e
    output=$(<"${CASE_DIR}/failed-session.log")
    [[ ${rc} -ne 0 && ${master_attempts} -eq 3 && ${remote_commands} -eq 0 ]] \
        || { fail '三次建连均失败后仍执行了远端命令'; return 1; }
    assert_contains "${output}" '连续 3 次连接均失败' \
        '建连耗尽后没有给出明确结论' || return 1
    [[ $(cn_entry_initial_attempt_count) == 3 ]] \
        || { fail '三次建连全部失败时没有保留完整尝试次数'; return 1; }
    control_dir=${CN_ENTRY_CONTROL_DIR}
    cleanup_cn_entry_session
    [[ ! -e ${control_dir} ]] \
        || { fail '建连失败后的计数记录或控制目录没有清理'; return 1; }
)

test_operation_lock_serializes_and_rejects_unsafe_path() (
    set -Eeuo pipefail
    local output rc action_log=${WORK_ROOT}/operation-lock-actions.log
    local victim=${WORK_ROOT}/operation-lock-victim lock_mode=free
    load_harness 2.5.7
    OPERATION_LOCK_DIR=${CASE_DIR}/operation-lock
    OPERATION_LOCK_FILE=${OPERATION_LOCK_DIR}/operation.lock
    : >"${action_log}"
    prepare_cn_entry_control_dir() { :; }
    cleanup_cn_entry_session() { :; }
    operation_action() { printf '%s\n' ACTION >>"${action_log}"; }

    run_cn_entry_operation operation_action
    assert_eq 1 "$(grep -Fc ACTION "${action_log}")" \
        '持有操作锁后没有执行操作' || return 1
    operation_lock_file_safe \
        || { fail '操作锁释放后文件没有保持安全属性'; return 1; }
    assert_eq 600 "$(mode_of "${OPERATION_LOCK_FILE}")" \
        '操作锁文件权限不是 0600' || return 1
    assert_contains "$(<"${TEST_FLOCK_LOG}")" '-n 7' \
        '操作入口没有以非阻塞方式获取互斥锁' || return 1
    assert_contains "$(<"${TEST_FLOCK_LOG}")" '-u 7' \
        '操作结束没有释放互斥锁' || return 1

    lock_mode=held
    flock() {
        if [[ ${1:-} == -u ]]; then return 0; fi
        [[ ${lock_mode} != held ]]
    }
    : >"${action_log}"
    set +e
    output=$(run_cn_entry_operation operation_action 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail '已有操作占用锁时仍然继续执行'; return 1; }
    [[ ! -s ${action_log} ]] || { fail '已有操作占用锁时执行了远端操作'; return 1; }
    assert_contains "${output}" '另一个 Po0 操作正在进行' \
        '操作锁占用时没有给出明确提示' || return 1

    lock_mode=free
    rm -f -- "${OPERATION_LOCK_FILE}"
    printf '%s\n' unchanged >"${victim}"
    ln -s -- "${victim}" "${OPERATION_LOCK_FILE}"
    set +e
    output=$(run_cn_entry_operation operation_action 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail '操作锁符号链接没有被拒绝'; return 1; }
    [[ -L ${OPERATION_LOCK_FILE} && $(<"${victim}") == unchanged ]] \
        || { fail '拒绝操作锁符号链接时改变了链接目标'; return 1; }
    [[ ! -s ${action_log} ]] || { fail '操作锁异常时仍执行了远端操作'; return 1; }
)

test_remote_component_timeout_is_bounded_and_releases_operation_lock() (
    set -Eeuo pipefail
    local output rc timeout_log=${WORK_ROOT}/component-timeout.log
    load_harness 2.5.17
    OPERATION_LOCK_DIR=${CASE_DIR}/operation-lock
    OPERATION_LOCK_FILE=${OPERATION_LOCK_DIR}/operation.lock
    CN_ENTRY_CONTROL_PATH=${CASE_DIR}/control/socket
    CN_ENTRY_TARGET=root@192.0.2.10
    CN_ENTRY_SSH_PORT=2222
    EXIT_PRIVATE_IP=192.0.2.20
    ADMIN_KEY=${CASE_DIR}/admin-key
    ADMIN_KNOWN_HOSTS=${CASE_DIR}/known-hosts
    : >"${timeout_log}"

    prepare_cn_entry_control_dir() { :; }
    cleanup_cn_entry_session() { :; }
    start_cn_entry_session() { :; }
    ssh() { printf '%s\n' UNEXPECTED_SSH >>"${timeout_log}"; return 0; }
    timeout() { printf '%s\n' "$*" >>"${timeout_log}"; return 124; }
    read_only_action() {
        ssh_cn_entry_component 30 read-only '状态检查' \
            "'/usr/local/libexec/po0-unlock-cn-entry' status"
    }
    mutating_action() {
        ssh_cn_entry_component 120 mutating '安装准备' \
            "'/usr/local/libexec/po0-unlock-cn-entry' prepare fixture fixture"
    }

    set +e
    output=$(run_cn_entry_operation read_only_action 2>&1)
    rc=$?
    set -e
    [[ ${rc} -eq 124 ]] \
        || { fail "只读组件超时没有保留 124 返回码（实际 ${rc}）"; return 1; }
    assert_contains "${output}" '本次只读组件调用未修改国内入口' \
        '只读组件超时没有明确说明入口侧未修改' || return 1
    assert_contains "$(<"${timeout_log}")" '--foreground --kill-after=5s 30s ssh' \
        '只读组件没有使用保持前台的 30 秒调用上限' || return 1
    assert_not_contains "$(<"${timeout_log}")" UNEXPECTED_SSH \
        '超时夹具错误执行了 SSH 命令' || return 1
    assert_contains "$(<"${TEST_FLOCK_LOG}")" '-u 7' \
        '只读组件超时后没有释放国外出口操作锁' || return 1

    : >"${timeout_log}"
    : >"${TEST_FLOCK_LOG}"
    set +e
    output=$(run_cn_entry_operation mutating_action 2>&1)
    rc=$?
    set -e
    [[ ${rc} -eq 124 ]] \
        || { fail "修改型组件超时没有保留 124 返回码（实际 ${rc}）"; return 1; }
    assert_contains "${output}" '可能已部分修改国内入口' \
        '修改型组件超时没有说明可能存在部分修改' || return 1
    assert_contains "${output}" '完整回滚' \
        '修改型组件超时没有给出完整回滚指引' || return 1
    assert_contains "$(<"${timeout_log}")" '--foreground --kill-after=5s 120s ssh' \
        '修改型组件没有使用保持前台的 120 秒调用上限' || return 1
    assert_contains "$(<"${TEST_FLOCK_LOG}")" '-u 7' \
        '修改型组件超时后没有释放国外出口操作锁' || return 1
)

test_cn_entry_lock_timeout_is_bounded_and_preserves_config() (
    set -Eeuo pipefail
    local function_body output rc role_source lock_log=${WORK_ROOT}/entry-lock-timeout.log
    local state=${WORK_ROOT}/entry-lock-state
    mkdir -p "${state}"
    APT_CONF=${state}/apt.conf
    PROFILE_CONF=${state}/profile.sh
    HELPER=${state}/helper
    printf '%s\n' apt-original >"${APT_CONF}"
    printf '%s\n' profile-original >"${PROFILE_CONF}"
    printf '%s\n' helper-original >"${HELPER}"
    CN_ENTRY_LOCK_WAIT_SECONDS=30
    HTTP_PROXY_URL=http://127.0.0.1:13128
    SOCKS_PROXY_URL=socks5h://127.0.0.1:19080
    : >"${lock_log}"

    function_body=$(sed -n '/^acquire_state_mutation_lock() {/,/^}/p' \
        "${PROJECT_DIR}/cn-entry-role.sh")
    [[ -n ${function_body} ]] \
        || { fail '未能提取国内入口有界写锁助手'; return 1; }
    eval "${function_body}"
    function_body=$(sed -n '/^write_proxy_files() (/,/^)/p' \
        "${PROJECT_DIR}/cn-entry-role.sh")
    [[ -n ${function_body} ]] \
        || { fail '未能提取国内入口代理写入函数'; return 1; }
    eval "${function_body}"

    valid_ipv4() { :; }
    flock() { printf '%s\n' "$*" >>"${lock_log}"; return 1; }
    die() { printf '%s\n' "$*" >&2; exit 1; }

    set +e
    output=$(write_proxy_files "${state}" 192.0.2.10 192.0.2.20 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail '国内入口写锁超时后仍报告成功'; return 1; }
    assert_contains "$(<"${lock_log}")" '-w 30 9' \
        '国内入口写锁没有使用 30 秒等待上限' || return 1
    assert_contains "${output}" '不会在无锁状态下继续修改' \
        '国内入口写锁超时提示不明确' || return 1
    assert_eq apt-original "$(<"${APT_CONF}")" \
        '写锁超时后改变了 APT 配置' || return 1
    assert_eq profile-original "$(<"${PROFILE_CONF}")" \
        '写锁超时后改变了登录代理配置' || return 1
    assert_eq helper-original "$(<"${HELPER}")" \
        '写锁超时后改变了国内入口助手' || return 1
    [[ ! -e ${state}/cn-entry-private-ip && ! -e ${state}/overseas-exit-private-ip ]] \
        || { fail '写锁超时后写入了连接地址记录'; return 1; }

    role_source=$(sed -n '1,$p' "${PROJECT_DIR}/cn-entry-role.sh")
    [[ $(grep -Fc 'flock -x 9' <<<"${role_source}" || true) -eq 0 ]] \
        || { fail '国内入口仍存在无上限的阻塞写锁'; return 1; }
    [[ $(grep -Fc 'acquire_state_mutation_lock "${state}"' <<<"${role_source}" || true) -eq 6 ]] \
        || { fail '六处国内入口写锁没有全部接入统一有界助手'; return 1; }
)

test_current_cn_entry_role_reuse_and_reconfigure_progress() (
    local selected= temporary= upload_calls=0 output log=${WORK_ROOT}/current-role.log
    local reconfigure_body
    load_harness 2.5.3
    CN_ENTRY_ROLE_LOCAL=${CASE_DIR}/current-cn-entry-role
    CN_ENTRY_REMOTE=${CASE_DIR}/installed-cn-entry-role
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${CN_ENTRY_ROLE_LOCAL}"
    cp -- "${CN_ENTRY_ROLE_LOCAL}" "${CN_ENTRY_REMOTE}"
    chmod 0700 "${CN_ENTRY_REMOTE}"
    export -f mode_of portable_stat stat
    ssh_cn_entry() { /bin/bash -c "$1"; }

    installed_cn_entry_role_is_current \
        || { fail '完整、安全且哈希一致的已安装组件没有通过复用校验'; return 1; }
    printf '%s\n' '# changed' >>"${CN_ENTRY_REMOTE}"
    ! installed_cn_entry_role_is_current \
        || { fail '内容变化的已安装组件仍被当作当前版本复用'; return 1; }
    cp -- "${CN_ENTRY_ROLE_LOCAL}" "${CN_ENTRY_REMOTE}"
    chmod 0644 "${CN_ENTRY_REMOTE}"
    ! installed_cn_entry_role_is_current \
        || { fail '权限异常的已安装组件仍被当作当前版本复用'; return 1; }
    chmod 0700 "${CN_ENTRY_REMOTE}"
    ln "${CN_ENTRY_REMOTE}" "${CASE_DIR}/installed-cn-entry-role.extra-link"
    ! installed_cn_entry_role_is_current \
        || { fail '存在额外硬链接的已安装组件仍被当作当前版本复用'; return 1; }
    rm -f -- "${CASE_DIR}/installed-cn-entry-role.extra-link"

    installed_cn_entry_role_is_current() { return 0; }
    upload_temporary_cn_entry_role() {
        upload_calls=$((upload_calls + 1))
        printf -v "$1" '%s' '/root/.po0-cn-entry-scan.Ab12Cd34'
    }
    select_current_cn_entry_role selected temporary
    [[ ${selected} == "${CN_ENTRY_REMOTE}" && ${temporary} == no && ${upload_calls} -eq 0 ]] \
        || { fail '哈希一致时仍重复上传国内入口组件'; return 1; }

    installed_cn_entry_role_is_current() { return 1; }
    select_current_cn_entry_role selected temporary
    [[ ${selected} == /root/.po0-cn-entry-scan.Ab12Cd34 \
        && ${temporary} == yes && ${upload_calls} -eq 1 ]] \
        || { fail '已安装组件不一致时没有回退到受校验临时上传'; return 1; }

    : >"${log}"
    CN_ENTRY_PRIVATE_IP=192.0.2.10
    CN_ENTRY_SSH_PORT=2222
    EXIT_PRIVATE_IP=192.0.2.20
    preflight() { printf '%s\n' PREFLIGHT >>"${log}"; }
    upload_temporary_cn_entry_role() { printf '%s\n' UPLOAD >>"${log}"; }
    ssh_cn_entry() { printf 'SSH:%s\n' "$*" >>"${log}"; }
    ssh_cn_entry_component() { shift 3; ssh_cn_entry "$@"; }
    run_exit_role() { printf 'EXIT:%s\n' "$*" >>"${log}"; }
    status_all_loaded reuse-installed >/dev/null
    output=$(<"${log}")
    assert_not_contains "${output}" PREFLIGHT \
        '刚完成安全上传后仍重复执行完整预检' || return 1
    assert_not_contains "${output}" UPLOAD \
        '刚完成安全上传后仍重复上传检查组件' || return 1
    assert_contains "${output}" "SSH:'${CN_ENTRY_REMOTE}'" \
        '最终状态检查没有执行刚校验安装的组件' || return 1

    reconfigure_body=$(sed -n '/^reconfigure_core() {/,/^}/p' "${SETUP_SOURCE}")
    for label in \
        '阶段 1/4：校验连接并同步国内入口组件' \
        '阶段 2/4：重建反向隧道并等待稳定' \
        '阶段 3/4：验证代理出口并刷新托管 Agent' \
        '阶段 4/4：执行最终状态检查'; do
        assert_contains "${reconfigure_body}" "${label}" \
            "连接更新缺少可见进度：${label}" || return 1
    done
    assert_contains "${reconfigure_body}" 'SECONDS - phase_started' \
        '连接更新没有显示各阶段实际耗时' || return 1
)

test_cn_entry_upload_rejects_unsafe_existing_target() (
    set -Eeuo pipefail
    local case_dir remote_tmp remote_script ssh_calls output rc victim target extra
    load_harness 2.5.6
    case_dir=${CASE_DIR}
    mkdir -p "${case_dir}/libexec"
    CN_ENTRY_ROLE_LOCAL=${case_dir}/embedded-role
    CN_ENTRY_TARGET=root@198.51.100.10
    remote_tmp=/usr/local/libexec/.po0-unlock-cn-entry.Ab12Cd34
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${CN_ENTRY_ROLE_LOCAL}"

    export -f mode_of portable_stat stat
    ssh_cn_entry() {
        ssh_calls=$((ssh_calls + 1))
        if (( ssh_calls == 1 )); then
            printf '%s\n' "${remote_tmp}"
            return 0
        fi
        remote_script=${1//\/usr\/local\/libexec/${case_dir}\/libexec}
        /bin/bash -c "${remote_script}"
    }
    scp_cn_entry() {
        cp -- "$1" "${case_dir}/libexec/.po0-unlock-cn-entry.Ab12Cd34"
    }

    victim=${case_dir}/victim
    target=${case_dir}/libexec/po0-unlock-cn-entry
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${victim}"
    chmod 0700 "${victim}"
    ln -s -- "${victim}" "${target}"
    set +e
    output=$(upload_cn_entry_role 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail '正式组件目标为符号链接时仍然成功复用'; return 1; }
    [[ -L ${target} && -f ${victim} ]] \
        || { fail '拒绝符号链接时破坏了原目标或链接'; return 1; }
    [[ ! -e ${case_dir}/libexec/.po0-unlock-cn-entry.Ab12Cd34 ]] \
        || { fail '符号链接拒绝后没有清理远端组件临时文件'; return 1; }

    rm -f -- "${target}" "${victim}"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${target}"
    chmod 0700 "${target}"
    extra=${case_dir}/libexec/po0-unlock-cn-entry.extra
    ln -- "${target}" "${extra}"
    ssh_calls=0
    set +e
    output=$(upload_cn_entry_role 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail '正式组件目标存在额外硬链接时仍然成功复用'; return 1; }
    [[ $(stat -c '%h' "${target}") == 2 ]] \
        || { fail '硬链接拒绝测试没有保留原文件现场'; return 1; }
    [[ ! -e ${case_dir}/libexec/.po0-unlock-cn-entry.Ab12Cd34 ]] \
        || { fail '硬链接拒绝后没有清理远端组件临时文件'; return 1; }
)

test_reconfigure_config_transaction() (
    local old_hash new_hash output rc residue
    load_harness 2.5.3
    CONFIG_DIR=${CASE_DIR}/etc/po0-unlock
    CONFIG_FILE=${CONFIG_DIR}/hosts.conf
    mkdir -p "${CONFIG_DIR}"
    chmod 0700 "${CONFIG_DIR}"
    {
        printf '%s\n' '# 在国外出口 VPS 上使用；不保存任何 SSH 密码。'
        printf '%s\n' 'CN_ENTRY_SSH_USER=root'
        printf '%s\n' 'CN_ENTRY_PRIVATE_IP=10.0.0.2'
        printf '%s\n' 'CN_ENTRY_SSH_PORT=22'
    } >"${CONFIG_FILE}"
    chmod 0600 "${CONFIG_FILE}"
    old_hash=$(sha256_file "${CONFIG_FILE}")

    ip() { :; }
    detect_exit_source_ip() { printf '%s\n' 198.51.100.20; }
    prompt_required_value() { printf '%s\n' 8.8.8.8; }
    prompt_value() {
        case "$1" in
            *端口*) printf '%s\n' 2222 ;;
            *) printf '%s\n' 8.8.8.8 ;;
        esac
    }
    configure yes no >"${CASE_DIR}/configure-preview.out" 2>&1
    output=$(<"${CASE_DIR}/configure-preview.out")
    assert_contains "${output}" '确认更新完成后才会写入' \
        '预览连接配置没有明确说明尚未写入'
    assert_eq "${old_hash}" "$(sha256_file "${CONFIG_FILE}")" \
        '未写入模式仍然改变了现有连接配置'
    assert_eq 8.8.8.8 "${CN_ENTRY_PRIVATE_IP}" \
        '未写入模式没有保留当前待提交地址'

    begin_reconfigure_config_transaction
    write_config_file
    new_hash=$(sha256_file "${CONFIG_FILE}")
    [[ ${new_hash} != "${old_hash}" ]] || fail '事务测试没有生成新的连接配置'
    set +e
    (
        trap cleanup_reconfigure_config_transaction EXIT
        exit 37
    )
    rc=$?
    set -e
    assert_eq 37 "${rc}" '事务清理没有保留原始失败状态'
    assert_eq "${old_hash}" "$(sha256_file "${CONFIG_FILE}")" \
        '授权/隧道失败后没有恢复原连接配置'
    residue=$(find "${CONFIG_DIR}" -maxdepth 1 \( -name '.hosts.conf.reconfigure.*' \
        -o -name 'hosts.conf.restore.*' \) -print)
    [[ -z ${residue} ]] || fail "连接配置事务残留临时文件：${residue}"

    rm -f -- "${CONFIG_FILE}"
    begin_reconfigure_config_transaction
    write_config_file
    set +e
    (
        trap cleanup_reconfigure_config_transaction EXIT
        exit 41
    )
    rc=$?
    set -e
    assert_eq 41 "${rc}" '无旧配置事务清理没有保留原始失败状态'
    [[ ! -e ${CONFIG_FILE} ]] || fail '无旧配置失败后仍留下了新连接配置'
)

test_reconfigure_transaction_cross_phase_consistency() (
    set -Eeuo pipefail
    local old_hash new_hash output rc call_log backup restore_tmp
    load_harness 2.5.12
    CONFIG_DIR=${CASE_DIR}/etc/po0-unlock
    CONFIG_FILE=${CONFIG_DIR}/hosts.conf
    call_log=${CASE_DIR}/reconfigure-call-order.log
    mkdir -p "${CONFIG_DIR}"
    chmod 0700 "${CONFIG_DIR}"
    {
        printf '%s\n' '# 在国外出口 VPS 上使用；不保存任何 SSH 密码。'
        printf '%s\n' 'CN_ENTRY_SSH_USER=root'
        printf '%s\n' 'CN_ENTRY_PRIVATE_IP=10.0.0.2'
        printf '%s\n' 'CN_ENTRY_SSH_PORT=22'
    } >"${CONFIG_FILE}"
    chmod 0600 "${CONFIG_FILE}"
    old_hash=$(sha256_file "${CONFIG_FILE}")

    CN_ENTRY_SSH_USER=root
    CN_ENTRY_PRIVATE_IP=8.8.8.8
    CN_ENTRY_SSH_PORT=2222
    EXIT_PRIVATE_IP=1.1.1.1
    CN_ENTRY_REMOTE=/usr/local/libexec/po0-unlock-cn-entry
    preflight() { :; }
    upload_cn_entry_role() { :; }
    ssh_cn_entry() {
        case "${1:-}" in
            *ssh_host_ed25519_key.pub*)
                printf '%s\n' 'SHA256:FixtureHostFingerprint'
                ;;
            *" refresh "*)
                printf '%s\n' REFRESH >>"${call_log}"
                return 73
                ;;
            *) return 2 ;;
        esac
    }
    ssh_cn_entry_component() { shift 3; ssh_cn_entry "$@"; }
    run_exit_role() {
        [[ ${1:-} == reconfigure ]] || return 2
        printf '%s\n' TUNNEL_COMMITTED >>"${call_log}"
    }
    status_all_loaded() {
        printf '%s\n' STATUS >>"${call_log}"
    }

    begin_reconfigure_config_transaction
    write_config_file
    new_hash=$(sha256_file "${CONFIG_FILE}")
    [[ ${new_hash} != "${old_hash}" ]] \
        || { fail '跨阶段事务测试没有写入新连接配置'; return 1; }
    set +e
    output=$(
        set -Eeuo pipefail
        exec 2>&1
        trap cleanup_reconfigure_config_transaction EXIT
        reconfigure_core current
    )
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] \
        || { fail 'Agent 刷新故障没有中止连接更新'; return 1; }
    assert_eq "${new_hash}" "$(sha256_file "${CONFIG_FILE}")" \
        '新隧道已经提交后，后续检查失败却把连接配置恢复成旧值' || return 1
    assert_eq $'TUNNEL_COMMITTED\nREFRESH' "$(<"${call_log}")" \
        '跨阶段事务测试没有在新隧道提交后触发刷新故障' || return 1
    backup=$(find "${CONFIG_DIR}" -maxdepth 1 -name '.hosts.conf.reconfigure.*' -print)
    [[ -z ${backup} ]] \
        || { fail "新隧道提交后仍残留未完成的连接配置事务：${backup}"; return 1; }

    {
        printf '%s\n' '# 在国外出口 VPS 上使用；不保存任何 SSH 密码。'
        printf '%s\n' 'CN_ENTRY_SSH_USER=root'
        printf '%s\n' 'CN_ENTRY_PRIVATE_IP=10.0.0.2'
        printf '%s\n' 'CN_ENTRY_SSH_PORT=22'
    } >"${CONFIG_FILE}"
    chmod 0600 "${CONFIG_FILE}"
    begin_reconfigure_config_transaction
    write_config_file
    backup=${RECONFIGURE_CONFIG_BACKUP}
    mv() {
        local -a operands=()
        while (( $# > 0 )); do
            case "$1" in
                -f|-T|-fT|-Tf|--) shift ;;
                *) operands[${#operands[@]}]=$1; shift ;;
            esac
        done
        [[ ${#operands[@]} -eq 2 ]] || return 2
        restore_tmp=${operands[0]}
        if [[ ${restore_tmp} == "${CONFIG_FILE}.restore."* \
            && ${operands[1]} == "${CONFIG_FILE}" ]]; then
            return 92
        fi
        /bin/mv -f -- "${operands[0]}" "${operands[1]}"
    }
    set +e
    output=$(
        exec 2>&1
        trap cleanup_reconfigure_config_transaction EXIT
        exit 74
    )
    rc=$?
    set -e
    assert_eq 74 "${rc}" '配置恢复失败没有保留原始退出状态' || return 1
    [[ -f ${backup} && ! -L ${backup} ]] \
        || { fail '连接配置自动恢复失败后删除了唯一事务备份'; return 1; }
    assert_contains "${output}" "${backup}" \
        '连接配置自动恢复失败后没有给出保留备份的准确路径' || return 1
)

test_admin_key_rejects_unsafe_paths_and_mismatched_pair() (
    set -Eeuo pipefail
    local output rc victim victim_hash extra_link key_path arg previous
    load_harness 2.5.12
    ADMIN_KEY=${CASE_DIR}/ssh/po0-unlock-admin
    victim=${CASE_DIR}/public-key-link-target
    mkdir -p "${ADMIN_KEY%/*}"
    chmod 0700 "${ADMIN_KEY%/*}"
    printf '%s\n' 'fixture-private-key' >"${ADMIN_KEY}"
    chmod 0600 "${ADMIN_KEY}"
    ln -s "${victim}" "${ADMIN_KEY}.pub"

    install() { :; }
    ssh-keygen() {
        key_path=
        previous=
        for arg in "$@"; do
            if [[ ${previous} == -f ]]; then key_path=${arg}; fi
            previous=${arg}
        done
        [[ " $* " == *' -y '* && ${key_path} == "${ADMIN_KEY}" ]] || return 2
        printf '%s\n' 'ssh-ed25519 AAAAFixturePublicKey'
    }

    set +e
    output=$(ensure_admin_key 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] || { fail '专用管理公钥路径为悬空符号链接时仍报告成功'; return 1; }
    [[ ! -e ${victim} ]] \
        || { fail '专用管理公钥生成跟随悬空符号链接改写了目标'; return 1; }
    [[ -L ${ADMIN_KEY}.pub ]] \
        || { fail '拒绝异常管理公钥路径时破坏了原符号链接'; return 1; }

    rm -f -- "${ADMIN_KEY}" "${ADMIN_KEY}.pub" "${victim}"
    printf '%s\n' 'fixture-private-key' >"${victim}"
    victim_hash=$(sha256_file "${victim}")
    ln -s "${victim}" "${ADMIN_KEY}"
    set +e
    output=$(ensure_admin_key 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 && $(sha256_file "${victim}") == "${victim_hash}" ]] \
        || { fail '专用管理私钥符号链接未被安全拒绝'; return 1; }

    rm -f -- "${ADMIN_KEY}"
    printf '%s\n' 'fixture-private-key' >"${ADMIN_KEY}"
    chmod 0600 "${ADMIN_KEY}"
    printf '%s\n' 'ssh-ed25519 AAAAFixturePublicKey' >"${ADMIN_KEY}.pub"
    chmod 0644 "${ADMIN_KEY}.pub"
    extra_link=${CASE_DIR}/public-key-extra-link
    ln "${ADMIN_KEY}.pub" "${extra_link}"
    set +e
    output=$(ensure_admin_key 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 && $(inode_of "${ADMIN_KEY}.pub") == "$(inode_of "${extra_link}")" ]] \
        || { fail '存在额外硬链接的专用管理公钥未被安全拒绝'; return 1; }

    rm -f -- "${extra_link}"
    printf '%s\n' 'ssh-ed25519 AAAADifferentPublicKey' >"${ADMIN_KEY}.pub"
    set +e
    output=$(ensure_admin_key 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] \
        || { fail '不匹配的专用管理公私钥仍被接受'; return 1; }
)

test_admin_key_generation_is_protected_and_idempotent() (
    set -Eeuo pipefail
    local first_private_hash first_public_hash key_path arg previous= output rc residue
    load_harness 2.5.12
    ADMIN_KEY=${CASE_DIR}/ssh/po0-unlock-admin
    mkdir -p "${ADMIN_KEY%/*}"
    chmod 0700 "${ADMIN_KEY%/*}"
    ssh-keygen() {
        key_path=
        previous=
        for arg in "$@"; do
            if [[ ${previous} == -f ]]; then key_path=${arg}; fi
            previous=${arg}
        done
        if [[ " $* " == *' -q '* ]]; then
            [[ -n ${key_path} ]] || return 2
            printf '%s\n' 'fixture-private-key' >"${key_path}"
            printf '%s\n' 'ssh-ed25519 AAAAFixturePublicKey po0-unlock-admin' >"${key_path}.pub"
            chmod 0600 "${key_path}"
            chmod 0644 "${key_path}.pub"
            return 0
        fi
        if [[ " $* " == *' -y '* && ${key_path} == "${ADMIN_KEY}" ]]; then
            printf '%s\n' 'ssh-ed25519 AAAAFixturePublicKey'
            return 0
        fi
        return 2
    }

    ensure_admin_key
    admin_key_directory_safe "${ADMIN_KEY%/*}" \
        || { fail '新建专用管理密钥目录属性异常'; return 1; }
    admin_key_file_safe "${ADMIN_KEY}" 600 \
        || { fail '新建专用管理私钥属性异常'; return 1; }
    admin_key_file_safe "${ADMIN_KEY}.pub" 644 \
        || { fail '新建专用管理公钥属性异常'; return 1; }
    admin_key_pair_matches \
        || { fail '新建专用管理公私钥不匹配'; return 1; }
    first_private_hash=$(sha256_file "${ADMIN_KEY}")
    first_public_hash=$(sha256_file "${ADMIN_KEY}.pub")

    ensure_admin_key
    assert_eq "${first_private_hash}" "$(sha256_file "${ADMIN_KEY}")" \
        '重复检查改变了专用管理私钥' || return 1
    assert_eq "${first_public_hash}" "$(sha256_file "${ADMIN_KEY}.pub")" \
        '重复检查改变了专用管理公钥' || return 1

    rm -f -- "${ADMIN_KEY}.pub"
    mv() { return 91; }
    set +e
    output=$(ensure_admin_key 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 && ! -e ${ADMIN_KEY}.pub && ! -L ${ADMIN_KEY}.pub ]] \
        || { fail '专用管理公钥原子安装失败后仍留下正式文件'; return 1; }
    residue=$(find "${ADMIN_KEY%/*}" -maxdepth 1 -name 'po0-unlock-admin.pub.*' -print)
    [[ -z ${residue} ]] \
        || { fail "专用管理公钥原子安装失败后残留候选：${residue}"; return 1; }
)

test_admin_key_accepts_safe_legacy_public_mode() (
    set -Eeuo pipefail
    local private_hash public_hash output rc key_path arg previous
    load_harness 2.5.13
    ADMIN_KEY=${CASE_DIR}/ssh/po0-unlock-admin
    mkdir -p "${ADMIN_KEY%/*}"
    chmod 0700 "${ADMIN_KEY%/*}"
    printf '%s\n' 'fixture-private-key' >"${ADMIN_KEY}"
    printf '%s\n' 'ssh-ed25519 AAAAFixturePublicKey po0-unlock-admin' >"${ADMIN_KEY}.pub"
    chmod 0600 "${ADMIN_KEY}" "${ADMIN_KEY}.pub"
    private_hash=$(sha256_file "${ADMIN_KEY}")
    public_hash=$(sha256_file "${ADMIN_KEY}.pub")
    ssh-keygen() {
        key_path=
        previous=
        for arg in "$@"; do
            if [[ ${previous} == -f ]]; then key_path=${arg}; fi
            previous=${arg}
        done
        if [[ " $* " == *' -y '* && ${key_path} == "${ADMIN_KEY}" ]]; then
            printf '%s\n' 'ssh-ed25519 AAAAFixturePublicKey private-key-comment'
            return 0
        fi
        return 2
    }

    ensure_admin_key
    assert_eq "${private_hash}" "$(sha256_file "${ADMIN_KEY}")" \
        '兼容旧版 0600 公钥时改变了私钥' || return 1
    assert_eq "${public_hash}" "$(sha256_file "${ADMIN_KEY}.pub")" \
        '兼容旧版 0600 公钥时改变了公钥' || return 1
    assert_eq 600 "$(mode_of "${ADMIN_KEY}.pub")" \
        '兼容旧版 0600 公钥时擅自放宽了权限' || return 1

    chmod 0666 "${ADMIN_KEY}.pub"
    set +e
    output=$(ensure_admin_key 2>&1)
    rc=$?
    set -e
    [[ ${rc} -ne 0 && $(mode_of "${ADMIN_KEY}.pub") == 666 ]] \
        || { fail '可被其他用户写入的管理公钥未被拒绝或被擅自修改'; return 1; }
    assert_contains "${output}" '专用管理公钥属性异常' \
        '宽松管理公钥权限的拒绝原因不明确' || return 1
)

test_agent_scan_reuses_current_cn_entry_role_and_progress() (
    local output rc log=${WORK_ROOT}/agent-scan-role.log
    load_harness 2.5.3
    : >"${log}"
    CN_ENTRY_REMOTE=/usr/local/libexec/po0-unlock-cn-entry
    CN_ENTRY_CMD_SCAN=scan-services
    C_BLUE=
    C_RESET=

    load_config() { :; }
    preflight() { printf '%s\n' PREFLIGHT >>"${log}"; printf '%s\n' PREFLIGHT_MARKER; }
    select_current_cn_entry_role() {
        printf '%s\n' SELECT_CURRENT >>"${log}"
        printf '%s\n' SELECT_CURRENT_MARKER
        printf -v "$1" '%s' "${CN_ENTRY_REMOTE}"
        printf -v "$2" '%s' no
    }
    upload_temporary_cn_entry_role() {
        printf '%s\n' UPLOAD_TEMPORARY >>"${log}"
        printf -v "$1" '%s' /root/.po0-cn-entry-scan.Ab12Cd34
    }
    ssh_cn_entry_tty() { printf 'TTY:%s\n' "$*" >>"${log}"; }
    ssh_cn_entry() { printf 'CLEANUP:%s\n' "$*" >>"${log}"; }

    output=$(scan_agent_services)
    assert_contains "$(<"${log}")" SELECT_CURRENT \
        'Agent 扫描没有安全选择当前国内入口组件' || return 1
    assert_not_contains "$(<"${log}")" UPLOAD_TEMPORARY \
        '已安装组件可复用时仍上传临时扫描组件' || return 1
    assert_not_contains "$(<"${log}")" CLEANUP \
        '复用已安装组件后仍尝试清理正式组件' || return 1
    assert_contains "$(<"${log}")" "TTY:" \
        'Agent 扫描没有调用选中的国内入口组件' || return 1
    assert_contains "$(<"${log}")" "${CN_ENTRY_REMOTE}" \
        'Agent 扫描命令没有包含选中的已安装组件路径' || return 1
    assert_contains "$(<"${log}")" scan-services \
        'Agent 扫描命令没有调用 scan-services' || return 1
    assert_contains "$(<"${log}")" 'timeout --foreground --kill-after=5s 60s' \
        'Agent 扫描远端命令没有在保持终端前台的同时设置总超时上限' || return 1
    [[ ${output} == *'正在校验国内入口连接'*PREFLIGHT_MARKER*'连接校验完成（耗时'* ]] \
        || { fail 'Agent 扫描没有在连接预检前显示进度和完成耗时'; return 1; }
    [[ ${output} == *'正在选择当前国内入口组件'*SELECT_CURRENT_MARKER*'复用已安装组件'* ]] \
        || { fail 'Agent 扫描没有在组件选择前显示进度或说明复用结果'; return 1; }

    : >"${log}"
    select_current_cn_entry_role() {
        printf -v "$1" '%s' /root/.po0-cn-entry-scan.Ab12Cd34
        printf -v "$2" '%s' yes
    }
    ssh_cn_entry_tty() { return 23; }
    set +e
    scan_agent_services_inner >/dev/null 2>&1
    rc=$?
    set -e
    [[ ${rc} -eq 23 ]] \
        || { fail '临时组件扫描失败没有保留远端退出状态'; return 1; }
    assert_contains "$(<"${log}")" "rm -f -- '/root/.po0-cn-entry-scan.Ab12Cd34'" \
        '临时扫描组件没有在失败后清理' || return 1

    : >"${log}"
    select_current_cn_entry_role() {
        printf -v "$1" '%s' /root/.po0-cn-entry-scan.Zy98Xw76
        return 77
    }
    set +e
    scan_agent_services_inner >/dev/null 2>&1
    rc=$?
    set -e
    [[ ${rc} -eq 77 ]] \
        || { fail '组件选择中断没有保留原退出状态'; return 1; }
    assert_contains "$(<"${log}")" "rm -f -- '/root/.po0-cn-entry-scan.Zy98Xw76'" \
        '组件选择中断后没有清理已创建的严格临时路径' || return 1

    : >"${log}"
    select_current_cn_entry_role() {
        printf -v "$1" '%s' "${CN_ENTRY_REMOTE}"
        printf -v "$2" '%s' yes
    }
    ssh_cn_entry_tty() { printf '%s\n' TTY >>"${log}"; }
    set +e
    scan_agent_services_inner >/dev/null 2>&1
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] \
        || { fail '临时标志与正式组件路径不匹配时仍继续扫描'; return 1; }
    assert_not_contains "$(<"${log}")" TTY \
        '组件路径与临时标志不匹配时仍执行远端组件' || return 1
    assert_not_contains "$(<"${log}")" CLEANUP \
        '临时标志错误时尝试清理正式组件' || return 1

    : >"${log}"
    select_current_cn_entry_role() {
        printf -v "$1" '%s' /root/.po0-cn-entry-scan.Qr12St34
        printf -v "$2" '%s' no
    }
    set +e
    scan_agent_services_inner >/dev/null 2>&1
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] \
        || { fail '正式标志与临时组件路径不匹配时仍继续扫描'; return 1; }
    assert_not_contains "$(<"${log}")" TTY \
        '正式标志与临时路径不匹配时仍执行远端组件' || return 1
    assert_contains "$(<"${log}")" "rm -f -- '/root/.po0-cn-entry-scan.Qr12St34'" \
        '标志不匹配时没有清理严格临时路径' || return 1
)

run_test() {
    local name=$1 function_name=$2 rc
    if [[ -n ${PO0_ACCEPTANCE_FILTER:-} && ${name} != *"${PO0_ACCEPTANCE_FILTER}"* ]]; then return 0; fi
    printf 'TEST %s ... ' "${name}"
    set +e
    ( set -Eeuo pipefail; "${function_name}" )
    rc=$?
    if [[ ${rc} -eq 0 ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf 'PASS\n'
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf 'FAIL\n'
    fi
}

main() {
    [[ -r ${SETUP_SOURCE} && -r ${BUILD_SOURCE} && -r ${CN_ENTRY_BUILD_SOURCE} ]] \
        || { printf '%s\n' '找不到项目源码。' >&2; exit 1; }
    make_library
    run_test '构建、自检与确定性' test_build_and_bundle_self_test
    run_test '仓库只保留唯一公开版' test_single_public_edition_contract
    run_test '用户可见产物品牌禁词' test_user_visible_branding_terms
    run_test '活动源码不含 v1 旧运行名称' test_legacy_runtime_identifiers_absent
    run_test 'v2 运行资源使用统一命名基线' test_v2_runtime_naming_contract
    run_test '完整回滚允许反向隧道安全退出' test_rollback_waits_for_tunnel_drain
    run_test '未完成代理初始化的安装仍可进入完整回滚' test_unfinalized_install_can_begin_rollback
    run_test '隧道账户家目录残留可安全重试清理' test_tunnel_home_cleanup_is_safely_retryable
    run_test '状态检查使用当前内嵌组件' test_status_uses_current_embedded_role
    run_test '已安装时再次选择安装可返回菜单' test_installed_install_returns_to_menu
    run_test '完整回滚可输入 0 安全返回' test_rollback_confirmation_returns_safely
    run_test '确认输入遇到 EOF 时安全取消' test_confirmation_eof_is_safe_cancel
    run_test '正常更新备份安全轮换并保留恢复点' test_script_backup_retention
    run_test '菜单统一使用任意键返回' test_any_key_return_copy
    run_test '直接更新与恢复成功后不打开交互菜单' test_direct_update_and_restore_do_not_open_menu
    run_test '脚本交接与更新恢复重入保留无人值守模式' test_reentry_preserves_assume_yes
    run_test '首次授权使用专用 SSH 主机密钥确认' test_admin_ssh_bootstrap_uses_dedicated_host_key_policy
    run_test '新出口机在授权写入前拒绝已占用入口' test_fresh_install_refuses_claimed_entry_before_authorization
    run_test '首次安装在组件写入前复核入口占用' test_install_rechecks_entry_claim_before_any_component_write
    run_test '安装失败回滚只能处理匹配事务' test_claimed_install_cleanup_cannot_rollback_another_deployment
    run_test '并发首次安装失败不会误回滚其他部署' test_concurrent_install_failure_never_uses_unclaimed_rollback
    run_test '服务器重装后的 SSH 指纹显式恢复向导' test_reinstalled_host_key_uses_explicit_recovery_wizard
    run_test '无可信主机密钥时拒绝建立国内入口会话' test_cn_entry_session_requires_trusted_host_key_file
    run_test '国内入口 SSH 会话有限重试、复用与清理' test_cn_entry_session_retries_and_reuses_transport
    run_test '主控操作互斥锁串行化并拒绝异常路径' test_operation_lock_serializes_and_rejects_unsafe_path
    run_test '远程组件调用超时有界并释放操作锁' test_remote_component_timeout_is_bounded_and_releases_operation_lock
    run_test '国内入口写锁等待有界且超时零写入' test_cn_entry_lock_timeout_is_bounded_and_preserves_config
    run_test '当前国内入口组件复用与连接更新分阶段耗时' test_current_cn_entry_role_reuse_and_reconfigure_progress
    run_test '国内入口正式组件拒绝符号链接与异常硬链接' test_cn_entry_upload_rejects_unsafe_existing_target
    run_test '连接更新配置事务失败回滚' test_reconfigure_config_transaction
    run_test '连接更新跨阶段事务保持配置与隧道一致' test_reconfigure_transaction_cross_phase_consistency
    run_test '专用管理密钥拒绝异常路径与不匹配密钥对' test_admin_key_rejects_unsafe_paths_and_mismatched_pair
    run_test '专用管理密钥安全生成且可重复检查' test_admin_key_generation_is_protected_and_idempotent
    run_test '旧版 0600 管理公钥可安全复用' test_admin_key_accepts_safe_legacy_public_mode
    run_test 'Agent 扫描复用当前组件并显示准备进度' test_agent_scan_reuses_current_cn_entry_role_and_progress
    run_test '严格版本规则' test_strict_versions
    run_test 'Debian 12 mawk 静态版本解析兼容性' test_mawk_static_version_compatibility
    run_test '候选摘要/版本/语法/self-test 拒绝' test_candidate_validation_failures
    run_test '空文件与超限更新候选不会替换当前脚本' test_candidate_size_gate_preserves_target
    run_test 'Release 元数据错误不改目标' test_release_metadata_failures_leave_target_unchanged
    run_test '最新版无操作与自动降级拒绝' test_latest_noop_and_downgrade_refusal
    run_test '公开 Release 请求与下载保持匿名' test_anonymous_public_requests_have_no_credentials
    run_test '更新器拒绝改名前账号下的旧仓库地址' test_updater_rejects_previous_owner_repository
    run_test '公开 Release 候选强制校验公开版类型' test_public_candidate_edition_gate
    run_test '历史私有版与分享版可由高版本公开版接管并恢复' test_legacy_editions_to_public_manual_takeover_and_restore
    run_test '同版本跨版本类型不替换已安装脚本' test_same_version_cross_edition_does_not_replace
    run_test '公开版接管失败保留原私有版' test_manual_takeover_failure_preserves_private_install
    run_test '有效更新、备份、原子替换与恢复' test_valid_update_backup_and_restore
    run_test '撤销到 v2.3 时同步恢复旧配置位置' test_restore_pre_24_script_and_config_together
    run_test '备份指针写失败不替换更新/恢复目标' test_pointer_failure_never_replaces_target
    run_test '恢复确认期间目标变化拒绝' test_restore_confirmation_change_is_rejected
    run_test '0777 目标脚本拒绝' test_world_writable_target_is_rejected
    run_test '主菜单与脚本管理菜单 0 无副作用' test_zero_paths_have_no_side_effects
    run_test 'Agent 扫描失败可留在主菜单并重试' test_agent_scan_failure_returns_to_main_menu
    printf '\n结果：PASS=%s FAIL=%s' "${PASS_COUNT}" "${FAIL_COUNT}"
    printf '\n'
    (( FAIL_COUNT == 0 ))
}

main "$@"
