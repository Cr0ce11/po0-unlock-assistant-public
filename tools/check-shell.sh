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

# 生产脚本与工具。两个构建产物都在其中：po0-unlock.sh 由构建器注入约 110 行
# 运行时代码，此前从未进入静态检查（heredoc 内的代码 ShellCheck 只当数据）。
production=(
    setup.sh
    overseas-exit-role.sh
    cn-entry-role.sh
    po0-unlock.sh
)
# 用 glob 展开而不是 mapfile：本脚本也要在开发机上运行，macOS 自带的 bash 3.2
# 没有 mapfile 内建。glob 结果本身就是排序的。
for candidate in tools/*.sh; do
    production+=("${candidate}")
done

# 测试套件按文件通配发现，新增套件会自动进入检查，不会因为忘记登记而漏检。
# 默认归入动态夹具组：宁可多排除一个 SC2034，也不能让新套件完全不被扫到。
static_fixtures=(
    tests/build-backup-acceptance.sh
    tests/check-acceptance-registration.sh
)
dynamic_fixtures=()
for candidate in tests/*.sh; do
    is_static=no
    for known in "${static_fixtures[@]}"; do
        [[ ${candidate} == "${known}" ]] && { is_static=yes; break; }
    done
    [[ ${is_static} == yes ]] || dynamic_fixtures+=("${candidate}")
done

if [[ ${1:-} == --list ]]; then
    printf '%s\n' "${production[@]}" "${static_fixtures[@]}" "${dynamic_fixtures[@]}" | sort
    exit 0
fi

# SC1007：项目有意使用 `local name=` 对局部变量做空值初始化。
# SC2100：带连字符的入口命令常量会被误判为算术表达式。
shellcheck --severity=warning --exclude=SC1007,SC2100 "${production[@]}"

# SC1007：测试夹具沿用与生产脚本相同的空值初始化写法。
shellcheck --severity=warning --exclude=SC1007 "${static_fixtures[@]}"

# SC1007：动态夹具套件沿用与生产脚本相同的空值初始化写法。
# SC2034：这些套件会动态抽取或 source 函数片段，夹具变量的使用无法被静态追踪。
shellcheck --severity=warning --exclude=SC1007,SC2034 "${dynamic_fixtures[@]}"
