# Tool Runtime

## Registry

`packages/opencode/src/tool/registry.ts:91-347` 是 builtin、project custom tool、plugin tool 和 MCP-aware description 的组合点。builtin 包含 shell/read/glob/grep/edit/write/task/fetch/todo/search/skill/patch/question/LSP/plan，受 client/experimental flags 控制。它在每次 model request 依据模型、agent、permission 生成可公开 schema；plugin hook `tool.definition` 可修改描述/parameters/schema。

Tool definition 的 owner 是各 tool module 的 `Tool.define` schema/executor；registry 是 resolver/schema adapter，不是所有执行逻辑的统一 switch。工具结果通过 processor 写为 tool Part，并成为下一 provider request 的 tool-result content。

## 选择规则

- Web search 依 provider/feature flag 启用。
- GPT family 在 `apply_patch` 与 edit/write 间切换（291-303）。
- task description 注入可用 subagent 清单（265-278）。
- MCP tools 由 Permission visibleTools 过滤后可供 code mode catalog 使用（280-289）。

## 通用执行语义

每个 tool 接收 session/message/agent/abort/ask/metadata context；executor 负责自己的环境、输出截断、附件、错误和取消。外部 side-effect tools 必须先调用 `ctx.ask`，但 read-only 与 agent policy 也可跳过 ask。具体 shell/FS/LSP 行为见 18、23。

工具 inventory 不应按 TUI labels 推断：当前 source 中 tool ID 是 `shell`、`fetch`、`search`、`todo` 等，客户端显示名/API 别名可能不同。
