# Po0-Unlock 项目执行规则

本项目是运行于生产 VPS 的安全关键工具。任何 AI 会话在修改本仓库前，必须先阅读并遵守本文件；与通用习惯冲突时，以本文件为准。本文件是本项目规则的唯一来源，对所有执行代理一致生效；不得新增代理专属的规则文件或目录。

接手会话的阅读顺序：本文件 → [`PROJECT.md`](PROJECT.md)（当前版本、环境、发布形态与维护执行方）→ [`TODO.md`](TODO.md)（可执行事项与状态）→ [`docs/HANDOVER.md`](docs/HANDOVER.md)（维护交接基线与约束）。

## 运行位置边界

- Po0 主项目永远只在国外出口机运行：`po0-unlock.sh`、正式 `/usr/local/sbin/po0-unlock` 和 `po0` 入口不得在 Mac 或国内入口机执行。
- 国内入口组件只能由国外出口主控从单文件内自动释放、传输、校验和调用；不得绕过国外出口主控，手工向国内入口上传或运行 Po0 项目脚本。

## 三条核心规矩

1. **改动要小而单一。** 每次会话只做一件事、只为一个目的改动代码。禁止在完成任务之余顺带重构、整理格式、改写文案或"优化"无关代码；机械整理不得改变功能、文案、配置路径、权限或服务器行为。若发现无关问题，记录下来向用户报告，不要顺手修改。
2. **行为改动必须附带验收测试。** 任何新增或修改的行为，必须在 `tests/` 中新增或更新对应的验收测试，并确保新测试在改动前会失败、改动后会通过。新增的 `test_*` 函数必须注册进所属套件的执行清单（`tests/check-acceptance-registration.sh` 会强制检查）。测试断言必须真正生效：用例应在 `( set -Eeuo pipefail; ... )` 子 shell 中运行，或给每条断言加 `|| return 1`；禁止只靠对源码做字符串 grep 来"验证"运行时行为。
3. **提交前跑完整套本地验收。** 全部通过才允许提交；任何一项失败都必须修好或如实报告，禁止跳过、注释或弱化测试来换取通过。完整清单见下节。

## 本地验收清单（提交前逐项执行）

```bash
bash -n setup.sh
bash -n overseas-exit-role.sh
bash -n cn-entry-role.sh
bash -n tools/build-cn-entry-role.sh
bash -n tools/build-single-file.sh
bash -n tools/check-shell.sh
bash -n po0-unlock.sh
bash tools/check-shell.sh
bash tools/build-cn-entry-role.sh --check
bash po0-unlock.sh self-test
bash tests/check-acceptance-registration.sh
bash tests/build-backup-acceptance.sh
bash tests/update-acceptance.sh
bash tests/install-entry-acceptance.sh
bash tests/config-migration-acceptance.sh
bash tests/cf-probe-acceptance.sh
bash tests/komari-acceptance.sh
bash tests/health-acceptance.sh
bash tests/diagnostic-acceptance.sh

cmp -s <(bash po0-unlock.sh __extract-role overseas-exit) overseas-exit-role.sh
cmp -s <(bash po0-unlock.sh __extract-role cn-entry) cn-entry-role.sh

# 在干净临时目录重新生成单文件，并与仓库产物逐字节比较。
(
    set -Eeuo pipefail

    po0_release_version=$(
        sed -nE 's/^SCRIPT_VERSION=([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' po0-unlock.sh
    )
    [[ -n ${po0_release_version} ]]

    po0_verify_dir=$(mktemp -d)
    cleanup_po0_verify() {
        rm -rf -- "${po0_verify_dir}"
    }
    trap cleanup_po0_verify EXIT

    mkdir -p \
        "${po0_verify_dir}/project/tools" \
        "${po0_verify_dir}/project/src/cn-entry-role"

    cp -- \
        setup.sh \
        overseas-exit-role.sh \
        cn-entry-role.sh \
        "${po0_verify_dir}/project/"

    cp -- \
        tools/build-cn-entry-role.sh \
        tools/build-single-file.sh \
        "${po0_verify_dir}/project/tools/"

    cp -- \
        src/cn-entry-role/*.sh.inc \
        "${po0_verify_dir}/project/src/cn-entry-role/"

    bash "${po0_verify_dir}/project/tools/build-single-file.sh" \
        "${po0_release_version}" >/dev/null

    cmp -s \
        "${po0_verify_dir}/project/po0-unlock.sh" \
        po0-unlock.sh
)
```

## 源码与产物边界

- 可直接编辑的程序逻辑源码包括：`setup.sh`、`overseas-exit-role.sh`、`src/cn-entry-role/*.sh.inc`、`tools/` 和 `tests/`。
- `CHANGELOG.md`、`README.md`、`使用说明.md`、`PROJECT.md`、`TODO.md`、`docs/`、`.github/workflows/`、`AGENTS.md` 及其他工程配置，只能在当前任务确实涉及对应内容时修改；不得顺带整理或改写。
- 严禁手工编辑生成产物：`cn-entry-role.sh` 与 `po0-unlock.sh` 只能分别由 `tools/build-cn-entry-role.sh` 和 `tools/build-single-file.sh` 生成。
- 国内入口组件是被写到对端执行的**独立脚本**（由角色脚本中的 heredoc 生成），它取不到角色脚本里的函数与变量。写在组件那几个模块里的代码，只能调用同样进入组件的函数、只能读组件自己赋值的常量；两个作用域都需要的东西按既有约定各留一份、名字不同（如 `active_state`／`helper_active_state`）。`tests/cf-probe-acceptance.sh` 里有两条守卫强制这一点。
- 角色脚本通过 `$0` 或 `${HELPER}` 跨进程调用子命令时，命令名必须直接写成字面量，并存在于对应角色或 helper 的 dispatch；不得把子命令藏进变量或数组，导致契约无法静态核对。`tests/cf-probe-acceptance.sh` 会系统核对全部这类调用，并通过真实角色入口运行可安全执行的只读桥接夹具。
- 修改国内入口模块后，必须运行 `bash tools/build-cn-entry-role.sh` 重新生成产物，并确认 `bash tools/build-cn-entry-role.sh --check` 通过。
- 修改任何会进入单文件的源码后，必须使用当前版本号重新生成 `po0-unlock.sh`，并执行本地验收清单中的确定性重建检查。
- 本项目只维护一个公开版单文件。它只允许通过匿名 HTTPS 访问预期的公开 GitHub Release，不得要求、读取、保存或发送 GitHub Token；在线更新、上一版助手恢复和手动上传更高版本后的本地安全接管均保留。
- 正式发布前必须使用目标版本号重新生成并提交 `po0-unlock.sh`；提交后应确认 `git diff --exit-code -- cn-entry-role.sh po0-unlock.sh` 没有未提交差异。

## 安全红线（不得弱化）

- 不得放宽或绕过：Komari 身份守卫"仅 401 且响应体明确未授权才重置"的判定、更新器的 SHA-256 与语法校验闸门、隧道账户 `restrict` 授权限制、各状态文件与令牌文件的属主和权限（root、0600/0700）。
- 不得把真实密码、令牌、SSH 私钥、公钥、生产 `known_hosts` 内容、真实服务器地址或端口写入代码、测试夹具、提交信息或本文件；测试只能使用明确无效、无法用于真实认证或连接的占位数据。
- 令牌与凭据的处理遵循工作区级 `../AGENTS.md` 的 GitHub 认证规则。

## 公开仓库边界

- 本仓库从 v2.5.17 起以干净初始历史公开；原私有仓库与本地冷归档已按项目所有者授权删除。不得从其他副本把旧 `.git`、标签、Release、Issue、Pull Request、Actions 日志或未审计分支重新复制到公开仓库，也不得把这些已删除材料描述为当前恢复来源。
- 所有准备推送的文件、历史和 Release 附件都必须扫描凭据、生产地址、主机记录、诊断报告、备份和个人信息；测试仅使用明确无效的占位数据。
- 本仓库自 2026-08-17 起按 GPL-3.0-only 发布（项目所有者决定，长期状态见 `PROJECT.md`），版权署名 `Cr0ce11`，许可证全文在 `LICENSE`。未经项目所有者明确决定，不得更换许可证、删除或改写 `LICENSE`，也不得在文档中把授权范围描述得比 GPL-3.0 更宽或更窄。新增代码同样以 GPL-3.0-only 发布；不得引入与之不兼容的第三方代码，确需引入时先取得所有者决定并附第三方许可声明。
- GitHub Actions 默认权限必须保持 `contents: read`，只有标签发布作业可以声明 `contents: write`；所有第三方 Action 固定到完整提交 SHA，不使用浮动标签。公开 Pull Request 工作流不得读取仓库 Secret。
- Release 必须先创建草稿，上传脚本与 SHA-256 两个预期附件，把 GitHub 返回的 digest 与本地 SHA-256 逐一核对后才发布。同标签 Release 已存在时必须拒绝；失败时只清理本次创建且尚未发布的草稿。不得为不可变 Release 设置预检引入额外 Secret；远端启用后只做不修改设置的核验。

## 版本与记录

- 版本号使用严格语义化 `x.y.z`；发布标签必须等于 `po0-unlock.sh` 内声明的版本。
- 每次行为改动同步更新 `CHANGELOG.md`（写清"相对上一正式版变了什么"），涉及用户可见行为时同步更新 `README.md` 与 `使用说明.md`。
- 最新正式版、仓库形态、CI 覆盖环境、发布形态、生产环境状态或维护执行方发生变化时，在同一个 Pull Request 中更新 `PROJECT.md`；事项与状态变化更新 `TODO.md`；维护方交接更新 `docs/HANDOVER.md`。长期结论不得只留在聊天或某个代理的本地记忆中。
- 完成后向用户用平实中文汇报：改了什么、为什么、跑了哪些验证、结果如何；不确定或未验证的事项必须如实说明。
