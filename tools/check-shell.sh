#!/usr/bin/env bash
set -Eeuo pipefail

TOOLS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=${TOOLS_DIR%/tools}
cd -- "${PROJECT_DIR}"

command -v shellcheck >/dev/null 2>&1 \
    || { printf '%s\n' '缺少 shellcheck，无法执行 Shell 静态检查。' >&2; exit 1; }
shellcheck_version=$(shellcheck --version | sed -n 's/^version: //p')
[[ ${shellcheck_version} == 0.11.0 ]] \
    || { printf 'ShellCheck 版本必须是 0.11.0，当前是：%s\n' "${shellcheck_version:-未知}" >&2; exit 1; }

# SC1007：项目有意使用 `local name=` 对局部变量做空值初始化。
# SC2100：带连字符的入口命令常量会被误判为算术表达式。
shellcheck --severity=warning --exclude=SC1007,SC2100 \
    setup.sh \
    overseas-exit-role.sh \
    cn-entry-role.sh \
    tools/*.sh

# SC1007：测试夹具沿用与生产脚本相同的空值初始化写法。
shellcheck --severity=warning --exclude=SC1007 \
    tests/build-backup-acceptance.sh \
    tests/check-acceptance-registration.sh

# SC1007：动态夹具套件沿用与生产脚本相同的空值初始化写法。
# SC2034：这些套件会动态抽取或 source 函数片段，夹具变量的使用无法被静态追踪。
shellcheck --severity=warning --exclude=SC1007,SC2034 \
    tests/cf-probe-acceptance.sh \
    tests/config-migration-acceptance.sh \
    tests/diagnostic-acceptance.sh \
    tests/health-acceptance.sh \
    tests/install-entry-acceptance.sh \
    tests/komari-acceptance.sh \
    tests/update-acceptance.sh
