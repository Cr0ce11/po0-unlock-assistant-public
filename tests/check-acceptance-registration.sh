#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)
WORKFLOW_FILE=${PROJECT_DIR}/.github/workflows/ci-release.yml
FAIL_COUNT=0
SUITE_COUNT=0
TEST_COUNT=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

check_suite_registration() {
    local suite=$1 result count
    SUITE_COUNT=$((SUITE_COUNT + 1))
    if result=$(awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        {
            line=$0
            if (line ~ /^[[:space:]]*test_[A-Za-z0-9_]+\(\)[[:space:]]*[\{\(]/) {
                line=trim(line)
                name=line
                sub(/\(\).*/, "", name)
                definitions[name]++
                next
            }
            if (line ~ /^[[:space:]]*run_(case|test)[[:space:]]+/) {
                name=$NF
                if (name ~ /^test_[A-Za-z0-9_]+$/) registrations[name]++
                next
            }
            line=trim(line)
            if (line ~ /^test_[A-Za-z0-9_]+$/) registrations[line]++
        }
        END {
            failed=0
            total=0
            for (name in definitions) {
                total++
                if (definitions[name] != 1 || registrations[name] != 1) {
                    printf "%s：定义 %d 次，注册 %d 次\n",
                        name, definitions[name], registrations[name] >"/dev/stderr"
                    failed=1
                }
            }
            for (name in registrations) {
                if (!(name in definitions)) {
                    printf "%s：已注册但没有定义\n", name >"/dev/stderr"
                    failed=1
                }
            }
            if (total == 0) {
                print "没有发现 test_* 测试函数" >"/dev/stderr"
                failed=1
            }
            if (failed) exit 1
            print total
        }
    ' "${suite}"); then
        count=${result}
        TEST_COUNT=$((TEST_COUNT + count))
        printf 'PASS: %s（%d 项测试均且仅注册一次）\n' \
            "${suite#${PROJECT_DIR}/}" "${count}"
    else
        fail "${suite#${PROJECT_DIR}/} 的测试注册不完整"
    fi
}

check_workflow_coverage() {
    local suite relative run_count
    [[ -r ${WORKFLOW_FILE} ]] || {
        fail '找不到 CI 工作流 .github/workflows/ci-release.yml'
        return
    }
    for suite in "$@"; do
        relative=${suite#${PROJECT_DIR}/}
        run_count=$(grep -Fc "/bin/bash ${relative}" "${WORKFLOW_FILE}" || true)
        if [[ ${run_count} -lt 2 ]]; then
            fail "${relative} 必须在基础验证和 Debian 兼容任务中各执行一次；当前共 ${run_count} 次"
        fi
    done
    run_count=$(grep -Fc '/bin/bash tests/check-acceptance-registration.sh' "${WORKFLOW_FILE}" || true)
    if [[ ${run_count} -lt 2 ]]; then
        fail "注册守卫必须在基础验证和 Debian 兼容任务中各执行一次；当前共 ${run_count} 次"
    fi
}

main() {
    local suites=()
    if (( $# > 0 )); then
        suites=("$@")
    else
        shopt -s nullglob
        suites=("${SCRIPT_DIR}"/*-acceptance.sh)
        shopt -u nullglob
    fi
    (( ${#suites[@]} > 0 )) || {
        printf '%s\n' 'FAIL: 没有发现验收套件。' >&2
        return 1
    }

    local suite
    for suite in "${suites[@]}"; do
        [[ -r ${suite} ]] || {
            fail "无法读取验收套件：${suite}"
            continue
        }
        check_suite_registration "${suite}"
    done
    if (( $# == 0 )); then
        check_workflow_coverage "${suites[@]}"
        check_shellcheck_coverage
    fi

    if (( FAIL_COUNT > 0 )); then
        printf '结果：%d 个注册或 CI 接入错误\n' "${FAIL_COUNT}" >&2
        return 1
    fi
    printf '结果：%d 个套件、%d 项 test_* 测试均已完整注册并接入 CI\n' \
        "${SUITE_COUNT}" "${TEST_COUNT}"
}

# ShellCheck 门禁按 glob 发现文件，这里核对它实际会检查的清单是否覆盖了
# 全部生产脚本、构建产物、工具与测试套件——漏检比检查失败更危险，因为它是静默的。
check_shellcheck_coverage() {
    local listed expected path missing=0
    listed=$(/bin/bash "${PROJECT_DIR}/tools/check-shell.sh" --list) || {
        fail 'tools/check-shell.sh --list 执行失败'
        return
    }
    expected=$(
        printf '%s\n' setup.sh overseas-exit-role.sh cn-entry-role.sh po0-unlock.sh
        (cd -- "${PROJECT_DIR}" && printf '%s\n' tools/*.sh tests/*.sh)
    )
    while IFS= read -r path; do
        [[ -n ${path} ]] || continue
        grep -Fxq -- "${path}" <<<"${listed}" || {
            fail "ShellCheck 门禁没有覆盖：${path}"
            missing=$((missing + 1))
        }
    done <<<"${expected}"
    (( missing > 0 )) || printf 'PASS: ShellCheck 门禁覆盖全部生产脚本、产物与测试套件\n'
}

main "$@"
