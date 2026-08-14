# 项目待办

本文件是项目的可执行清单。状态变化通过 Pull Request 更新，不能只在聊天中标记完成。

状态说明：`进行中`、`待办`、`待决定`、`暂缓`、`阻塞`、`完成`。完成项在对应 Release 或治理 PR 合并后移入 [`CHANGELOG.md`](CHANGELOG.md) 或从本文件删除，不长期堆积。

本仓库当前没有启用 GitHub Issue，因此每个事项的“正式记录”指向 Pull Request、Release 或仓库内的长期文档。如果今后启用 Issue，新事项必须先建立 Issue，本文件只保留索引。

| 编号 | 优先级 | 状态 | 正式记录 | 事项 | 完成条件 |
|---|---|---|---|---|---|
| GOV-001 | P1 | 完成 | 本文件与 [`PROJECT.md`](PROJECT.md)、[`docs/HANDOVER.md`](docs/HANDOVER.md) | 建立项目状态、待办与维护交接基线 | 三份长期文档与 v2.5.18、公开 CI 和 Release 事实一致；不改变运行代码、生成物或服务器行为，本地验收清单与公开 CI 全部通过 |
| HAND-001 | P1 | 进行中 | [`docs/HANDOVER.md`](docs/HANDOVER.md) | Claude Code 临时维护期（2026-08-14 起） | 交回 Codex 时在 `docs/HANDOVER.md` 追加交接结束小节，记录期间合并的 PR、发布的版本、未完成事项、回退方式、交回时的 `main` 提交与开放项，并同步更新 `PROJECT.md` 的维护执行方 |
| GOV-002 | P2 | 待决定 | 项目所有者决定 | 是否启用 GitHub Issue 作为需求与缺陷的登记入口 | 所有者作出决定；若启用，同步调整 `PROJECT.md`、本文件和协作说明，改由 Issue 承载需求与优先级 |
| GOV-003 | P3 | 暂缓 | 项目所有者决定 | 是否授予开源许可 | 当前明确不授予；未经所有者明确决定，不新增 `LICENSE`、不在文档中宣称开源或暗示已授权复制、修改、再发布及商业使用 |
| OPS-001 | P2 | 待办 | 待建立 | 明确真机验证的授权与执行方式 | 记录一次可重复的授权流程：由谁授权、在哪台服务器、做哪些只读或可回退的检查、失败如何恢复；不把地址、端口或凭据写入仓库 |
| REL-001 | — | 完成 | [PR #5](https://github.com/DTB201/po0-unlock-assistant-public/pull/5) | 准备并发布 v2.5.18 | 版本号、生成物、标签与 Release 一致；本地验收清单、公开 CI 与两个 Release 附件摘要核对全部通过 |
| FIX-001 | — | 完成 | [PR #1](https://github.com/DTB201/po0-unlock-assistant-public/pull/1)、[PR #2](https://github.com/DTB201/po0-unlock-assistant-public/pull/2)、[PR #3](https://github.com/DTB201/po0-unlock-assistant-public/pull/3)、[PR #4](https://github.com/DTB201/po0-unlock-assistant-public/pull/4) | v2.5.18 的四项修复与门禁加固 | 同行 IPv4 脱敏、单文件构建语义门禁、ShellCheck 基线与变量作用域、远程组件与入口写锁超时保护均已合并并随 v2.5.18 发布，详见 `CHANGELOG.md` |

## 当前最值得继续的顺序

1. 维持交接期约束：规则只在 `AGENTS.md`，不新增代理专属规则文件，不引入 Codex 受限沙箱无法执行的必需流程（HAND-001）。
2. 以真实使用中发现的缺陷驱动维护；当前没有已登记的未解决缺陷。
3. 等待项目所有者对 GOV-002 与 GOV-003 的决定，在此之前维持现状。

任何需要登录服务器、修改 SSH、操作生产环境或改变公开仓库设置的事项必须独立执行，先记录回退方式并取得明确授权。
