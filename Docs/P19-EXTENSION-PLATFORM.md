# P19 Extension Platform

## 目标

P19 为 Skills、Commands、Hooks、Plugins 和 MCP 提供统一的管理面。扩展内部仍保留各自 Runtime；registry 只统一 descriptor、发现、权限、生命周期、版本和诊断。

## Descriptor

`ExtensionDescriptor` 统一记录：

- `id`、`version`、`type`、`source`
- `scope`：`global` 或 `project`
- `enabled`、`capabilities`、`compatibility`
- `lifecycleState`
- `provenance`：scope、具体路径和发现时间

版本是三段式 semver 形式，schema version 必须匹配当前 registry schema，Core version 必须落在扩展声明的范围内。无效 descriptor、坏 JSON 和不兼容扩展进入 diagnostics，不进入可执行 registry。

## Discovery

全局目录支持 `<global>/skills`、`<global>/.lingxi/skills` 和 `<global>/commands`；项目目录使用 `.lingxi/skills` 与 `.lingxi/commands`。目录项按文件名排序，项目同名扩展覆盖全局扩展，最终结果按 ID 稳定排序。

Skill 必须包含 `SKILL.md`，Command 使用普通文件作为 descriptor source。每个结果保留具体 source path 和 scope，调用方可以追踪 provenance。`ExtensionPlatform.discover()` 只替换 Skills/Commands，保留已恢复的 Plugin/MCP 状态。

## Hooks

Hook 使用 `ExtensionEvent` 和 `ExtensionHookEvent` 的结构化值注册，不接受任意代码字符串。支持 AgentRun、Tool、Task、Workflow、Session 的 start/end 和 before/after 事件。

每个 handler 经现有 `ExecutionWatchdog` 执行，timeout 会被 `ExecutionDeadlinePolicy` clamp。单个 handler 的异常、取消或超时只产生 `ExtensionHookDiagnostic`，后续 hook 仍继续。没有交互授权通道时 Permission Engine 返回 `ask` 会按 fail-closed 处理，不创建 pending ask。

## Plugins

本阶段 Plugin 是本地 manifest/package 生命周期，不加载 native dylib/so，也不执行任意 manifest 字符串。`extension.json` 必须声明 ID、三段式 version、compatibility 和 capabilities。

生命周期为 `install -> load/installed -> enable -> disable -> update -> uninstall`。安装和升级先解码、校验和复制新版本，再更新 registry；失败不会替换旧 descriptor。卸载前将托管 package 复制到 `.backups`，再删除当前 package 和 registry entry。插件能力必须同时满足 manifest declaration 和 Permission Engine decision，不能绕过 Tool permission、Workspace、Credential、deadline 或 Execution Profile。

## MCP

MCP 的既有 `MCPServerRegistry`、`MCPConnectionManager`、`MCPToolPager` 和 transport 保持不变。平台把 MCP configuration 映射为 type=`mcp` descriptor，负责注册、enable/disable、状态、provenance 和恢复；实际 discovery、schema lease、call 仍由原 MCP Runtime 执行。MCP capability 默认显式标记为 `networkAccess` 与 `externalService`。

## Persistence and diagnostics

Global registry 状态保存于 `<global>/extension-registry.json`，Project 状态保存于 `<project>/.lingxi/extension-registry.json`，使用 atomic write。Core 启动时恢复 registry；坏文件只产生 diagnostics，不阻止 Core 启动。Global 与 Project 的同 ID descriptor 以 Project 为 effective precedence。

P19 不包含 GUI、Marketplace、远程分发、新 Provider 或 native code loading。
