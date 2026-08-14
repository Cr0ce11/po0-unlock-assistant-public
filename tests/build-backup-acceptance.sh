#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEMP_BASE=${TMPDIR:-/tmp}
WORK_ROOT=$(mktemp -d "${TEMP_BASE%/}/po0-build-backup.XXXXXXXX")

cleanup() {
    case "${WORK_ROOT}" in
        "${TEMP_BASE%/}"/po0-build-backup.*) rm -rf -- "${WORK_ROOT}" ;;
    esac
}
trap cleanup EXIT INT TERM HUP

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    return 1
}

new_build_case() {
    CASE_DIR=$(mktemp -d "${WORK_ROOT}/case.XXXXXXXX")
    CASE_PROJECT=${CASE_DIR}/project
    CASE_BACKUPS=${CASE_DIR}/project-backups/bundle-history
    mkdir -p "${CASE_PROJECT}/tools" "${CASE_PROJECT}/src/cn-entry-role"
    cp -- \
        "${PROJECT_DIR}/setup.sh" \
        "${PROJECT_DIR}/overseas-exit-role.sh" \
        "${PROJECT_DIR}/cn-entry-role.sh" \
        "${PROJECT_DIR}/po0-unlock.sh" \
        "${CASE_PROJECT}/"
    cp -- \
        "${PROJECT_DIR}/tools/build-cn-entry-role.sh" \
        "${PROJECT_DIR}/tools/build-single-file.sh" \
        "${CASE_PROJECT}/tools/"
    cp -- \
        "${PROJECT_DIR}"/src/cn-entry-role/*.sh.inc \
        "${CASE_PROJECT}/src/cn-entry-role/"
    CASE_VERSION=$(sed -nE \
        's/^SCRIPT_VERSION=([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' \
        "${CASE_PROJECT}/po0-unlock.sh")
    [[ -n ${CASE_VERSION} ]] || fail '测试夹具无法读取当前版本号'
}

run_build() {
    /bin/bash "${CASE_PROJECT}/tools/build-single-file.sh" "${CASE_VERSION}"
}

test_identical_rebuild_creates_no_backup() (
    new_build_case
    local before output
    before=$(sha256sum "${CASE_PROJECT}/po0-unlock.sh" | awk '{print $1}')
    output=$(run_build)
    [[ ${output} == *'单文件生成物未变化'* ]] \
        || fail '相同内容重建没有明确报告跳过备份'
    [[ $(sha256sum "${CASE_PROJECT}/po0-unlock.sh" | awk '{print $1}') == "${before}" ]] \
        || fail '相同内容重建改变了单文件生成物'
    if [[ -d ${CASE_BACKUPS} ]] \
        && find "${CASE_BACKUPS}" -mindepth 1 -print -quit | grep -q .; then
        fail '相同内容重建仍然创建了历史备份'
    fi
)

test_managed_backups_keep_latest_ten_and_preserve_legacy() (
    new_build_case
    local sequence path
    local -a managed=()
    mkdir -p "${CASE_BACKUPS}"
    printf '%s\n' 'legacy unique snapshot' \
        >"${CASE_BACKUPS}/po0-unlock.legacy.previous.keep"

    for sequence in $(seq 1 12); do
        printf '# backup-snapshot-%s\n' "${sequence}" \
            >>"${CASE_PROJECT}/po0-unlock.sh"
        run_build >/dev/null
    done

    shopt -s nullglob
    managed=("${CASE_BACKUPS}"/po0-unlock.managed.*)
    shopt -u nullglob
    [[ ${#managed[@]} -eq 10 ]] \
        || fail "受管备份没有收敛到10份：实际 ${#managed[@]} 份"
    [[ -f ${CASE_BACKUPS}/po0-unlock.legacy.previous.keep ]] \
        || fail '保留策略误删了旧格式独有快照'

    for sequence in 1 2; do
        if grep -lFx -- "# backup-snapshot-${sequence}" "${managed[@]}" \
            >/dev/null 2>&1; then
            fail "最旧的受管备份 ${sequence} 没有被淘汰"
        fi
    done
    for sequence in $(seq 3 12); do
        path=$(grep -lFx -- "# backup-snapshot-${sequence}" "${managed[@]}" \
            | head -n 1 || true)
        [[ -n ${path} ]] || fail "最近的受管备份 ${sequence} 没有被保留"
    done
)

test_unmodified_source_build_succeeds() (
    new_build_case
    local output
    output=$(run_build 2>&1) \
        || fail '未改动的源码树无法正常构建'
    [[ ${output} == *'单文件生成物未变化'* ]] \
        || fail '未改动的源码树没有生成预期单文件'
)

test_changed_preflight_signature_is_rejected() (
    new_build_case
    local output rc=0 rewritten=${CASE_PROJECT}/setup.sh.rewritten
    awk '
        $0 == "preflight() {" {
            print "preflight() ("
            in_preflight=1
            opening_replaced++
            next
        }
        in_preflight && $0 == "}" {
            print ")"
            in_preflight=0
            closing_replaced++
            next
        }
        { print }
        END {
            if (in_preflight || opening_replaced != 1 || closing_replaced != 1) exit 42
        }
    ' "${CASE_PROJECT}/setup.sh" >"${rewritten}" \
        || fail '测试夹具无法唯一改写 preflight 函数形式'
    mv -- "${rewritten}" "${CASE_PROJECT}/setup.sh"

    output=$(run_build 2>&1) || rc=$?
    [[ ${rc} -ne 0 ]] \
        || fail 'preflight 函数签名变化后构建器仍然静默成功'
    [[ ${output} == *'单文件构建匹配计数异常：preflight() {，期望 1 次，实际 0 次。'* ]] \
        || fail '构建拒绝时没有准确报告 preflight() { 匹配计数'
)

run_test() {
    local name=$1
    "${name}"
    printf 'PASS: %s\n' "${name}"
}

run_case() {
    local label=$1 name=$2
    "${name}"
    printf 'PASS: %s\n' "${label}"
}

main() {
    run_test test_identical_rebuild_creates_no_backup
    run_test test_managed_backups_keep_latest_ten_and_preserve_legacy
    run_case '未改动源码树仍可正常构建' test_unmodified_source_build_succeeds
    run_case 'preflight 函数形式变化会被明确拒绝' test_changed_preflight_signature_is_rejected
    printf '%s\n' 'PASS: 单文件构建备份保留验收测试通过'
}

main "$@"
