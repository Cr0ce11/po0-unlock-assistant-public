# 国内入口组件模块

这里是 `cn-entry-role.sh` 的开发源码。模块按照文件名前缀的固定顺序拼接，生成文件仍是一个可以独立运行的 Bash 组件。

这些 `.sh.inc` 文件是连续源码片段，不保证可以单独执行或单独通过语法检查。修改后应运行：

```bash
bash tools/build-cn-entry-role.sh --build
bash tools/build-cn-entry-role.sh --check
```

日常也可以直接运行 `bash tools/build-single-file.sh <版本号>`；它会先生成国内入口组件，再生成最终单文件。

## 模块职责

- `00-runtime.sh.inc`：国内入口基础校验、状态准备和 helper 写入入口。
- `10-helper-identity.sh.inc`：helper 基础能力、Komari 自动发现身份守卫和 Agent 类型识别。
- `20-helper-cf-probe.sh.inc`：CF Probe 旧 Shell 与受支持 Go Agent 的延迟兼容，以及旧 Shell 真实地区上报兼容。
- `30-helper-komari-legacy.sh.inc`：只清理旧版创建的 Komari TCP 延迟转发文件和规则。
- `50-helper-service-transactions.sh.inc`：展示 IP、服务所有权和启停事务回滚。
- `70-helper-command-dispatch.sh.inc`：`po0-cn-entry` 命令入口及具体操作分发。
- `80-role-configuration.sh.inc`：helper、APT 和命令环境配置落盘。
- `85-role-install-refresh.sh.inc`：代理验证、安装完成和连接配置刷新。
- `90-role-agent-management.sh.inc`：Agent 扫描、单服务检查更新或撤销，以及 Komari 交互管理。
- `95-role-status-rollback.sh.inc`：状态检查、分阶段完整回滚和组件命令入口。

## 修改规则

1. 只修改对应模块，不直接编辑生成的 `cn-entry-role.sh`。
2. 模块顺序只能在 `tools/build-cn-entry-role.sh` 中明确维护。
3. 不使用运行时 `source`；服务器部署产物仍保持单文件。
4. 提交前必须确认 `cn-entry-role.sh` 可以由模块确定性重建。
5. 除明确批准的破坏性版本外，机械整理不得顺带改变功能、文案、配置路径、权限或服务器行为。
6. v2 只使用 `po0-unlock`、`cn-entry` 和 `overseas-exit` 命名，不接受 v1 运行状态或原地升级。
