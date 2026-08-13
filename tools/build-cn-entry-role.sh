#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

TOOLS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=${TOOLS_DIR%/tools}
MODULE_DIR=${PROJECT_DIR}/src/cn-entry-role
OUTPUT=${PROJECT_DIR}/cn-entry-role.sh
MODE=${1:---build}

MODULES=(
    00-runtime.sh.inc
    10-helper-identity.sh.inc
    20-helper-cf-probe.sh.inc
    30-helper-komari-legacy.sh.inc
    50-helper-service-transactions.sh.inc
    70-helper-command-dispatch.sh.inc
    80-role-configuration.sh.inc
    85-role-install-refresh.sh.inc
    90-role-agent-management.sh.inc
    95-role-status-rollback.sh.inc
)

expected_modules=$(printf '%s\n' "${MODULES[@]}")
actual_modules=
for path in "${MODULE_DIR}"/*.sh.inc; do
    [[ -e ${path} ]] || continue
    actual_modules+="${path##*/}"$'\n'
done
actual_modules=${actual_modules%$'\n'}
[[ ${actual_modules} == "${expected_modules}" ]] \
    || { printf '%s\n' '国内入口模块清单与构建器声明不一致。' >&2; exit 1; }

case "${MODE}" in
    --build|--check) ;;
    *) printf '用法：%s [--build|--check]\n' "${0##*/}" >&2; exit 2 ;;
esac

candidate=$(mktemp "${OUTPUT}.modules.XXXXXXXX")
cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP
    rm -f -- "${candidate:-}"
    exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

for module in "${MODULES[@]}"; do
    path=${MODULE_DIR}/${module}
    [[ -f ${path} && ! -L ${path} ]] \
        || { printf '缺少或拒绝使用异常国内入口模块：%s\n' "${path}" >&2; exit 1; }
    sed -n '1,$p' "${path}" >>"${candidate}"
done

chmod 0755 "${candidate}"
/bin/bash -n "${candidate}"

if [[ ${MODE} == --check ]]; then
    [[ -f ${OUTPUT} && ! -L ${OUTPUT} ]] \
        || { printf '缺少或拒绝检查异常生成文件：%s\n' "${OUTPUT}" >&2; exit 1; }
    cmp -s "${candidate}" "${OUTPUT}" \
        || { printf '%s\n' 'cn-entry-role.sh 不是当前模块的确定性构建结果。' >&2; exit 1; }
    printf '%s\n' 'CN_ENTRY_ROLE_MODULES=PASS'
    exit 0
fi

if [[ -f ${OUTPUT} && ! -L ${OUTPUT} ]] && cmp -s "${candidate}" "${OUTPUT}"; then
    printf '%s\n' '国内入口组件未变化。'
    exit 0
fi
[[ ! -e ${OUTPUT} || ( -f ${OUTPUT} && ! -L ${OUTPUT} ) ]] \
    || { printf '拒绝替换异常生成文件：%s\n' "${OUTPUT}" >&2; exit 1; }
mv -f -- "${candidate}" "${OUTPUT}"
candidate=
trap - EXIT INT TERM HUP
printf '已生成：%s\n' "${OUTPUT}"
