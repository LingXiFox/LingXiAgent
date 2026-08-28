# OpenChamber 抽离研究摘要

研究范围截至 OpenChamber 与 OpenCode Server 的调用边界。本文档不研究 OpenCode 内部实现，也不定义 LingXiAgent 的新架构。

## 结论

OpenChamber 是一个多客户端工作台和本地服务层，不是 Agent Runtime。它把 React UI、Electron 平台能力、远程访问、项目/会话辅助功能，以及 OpenCode Server 的 HTTP/SSE API 整合成一个产品。

OpenCode Server 是实际的 Agent Runtime。OpenChamber 通过 `@opencode-ai/sdk/v2` 和 `/api/*` 反向代理调用它，读取 Session、Message、Part、Agent、Provider、MCP 与权限等数据，并把 OpenCode 的 SSE 事件同步到自己的 UI 状态与通知系统。

OpenChamber Server 不是可有可无的 HTTP 包装。它负责：

- 托管或连接 OpenCode 进程，处理健康检查、重启、配置变更和本机认证。
- 将 OpenCode API/SSE 代理给所有 Web、Desktop、Mobile、远程客户端。
- 提供 OpenCode 没有的项目配置、计划任务、Session Goal、自动许可、Git、文件、PTY、通知、远程配对、Relay/Tunnel、浏览器控制、更新等服务。
- 作为远程访问的统一认证点和私有中继的本地 host。

因此，删除 Electron 不会删除产品的 Session/Agent 能力，但会失去原生窗口、菜单、更新、原生通知、SSH、文件选择和本机 IPC。删除 OpenChamber Server 则会失去上述扩展服务、远程网关和 OpenCode 生命周期管理；保留 OpenCode Server 仍可保留基础 Agent 对话，但客户端必须直接实现其调用、事件同步、认证和全部被删服务的替代品。

## 当前运行图

```text
Desktop user / browser / Capacitor mobile / remote desktop
        |
        | React UI, RuntimeAPIs, runtimeFetch, runtime WebSocket
        v
OpenChamber Web Server (Express, packages/web/server/index.js)
        |                         ^
        | /api proxy + SSE bridge   | OpenChamber API: Git, FS, PTY, goals,
        v                         | pairing, relay, notifications, settings
OpenCode Server                     |
        | OpenCode Agent Runtime    |
        v                         |
Provider APIs, tools, MCP servers, workspace

Electron desktop only:
Electron renderer -> preload -> openchamber:invoke IPC -> Electron main
Electron main imports startWebUiServer() into the same main process.
```

Private Relay inserts an encrypted transport between a remote client and the OpenChamber server. It does not bypass OpenChamber authentication or call OpenCode directly.

## Ownership at a glance

| Domain | Current owner | Classification |
| --- | --- | --- |
| Agent loop, model inference, tool execution, canonical Session/Message/Part | OpenCode Server | OPENCODE WRAPPER at OpenChamber boundary |
| Session chat UI, stream reduction, local caches, selection/drafts | `packages/ui` | CLIENT UI |
| OpenCode lifecycle, proxy, process auth | OpenChamber Server | OPENCHAMBER SERVER GLUE |
| Scheduled tasks, Session Goal, session recap/suggestion, auto-accept policy | OpenChamber Server | OPENCHAMBER CORE LOGIC |
| Remote pairing, direct instances, Relay/Tunnel | OpenChamber Server + UI | REMOTE SERVICE |
| Git, filesystem, terminal, browser panel, notifications | OpenChamber Server; Electron adds native operations | OPENCHAMBER CORE LOGIC / PLATFORM SERVICE |
| Windows, menus, native dialogs, updater, tray, SSH | Electron | PLATFORM SERVICE |
| Provider configuration/auth, Agents/MCP/Commands/Plugins | OpenCode owns runtime semantics; OpenChamber adds configuration UI/filesystem routes | MIXED |
| Provider quota dashboard | OpenChamber Server | OPENCHAMBER OWNED |

## Evidence anchors

- Server composition and storage constants: `packages/web/server/index.js`.
- OpenCode proxy/lifecycle/config boundary: `packages/web/server/lib/opencode/{proxy,lifecycle,routes,settings-runtime}.js` and its `DOCUMENTATION.md`.
- UI synchronization: `packages/ui/src/sync/sync-context.tsx`, `event-reducer.ts`, `session-message-loader.ts`, `sync/DOCUMENTATION.md`.
- Shared SDK adapter/runtime switching: `packages/ui/src/lib/opencode/client.ts`, `runtime-switch.ts`.
- Desktop boundary: `packages/electron/main.mjs`, `preload.mjs`, `packages/electron/README.md`.
- Private relay: `packages/web/server/lib/relay/DOCUMENTATION.md`.

## Scope limits

- The actual OpenCode database schema, internal ID generator, Agent loop implementation and provider implementation are deliberately not inspected. Their ownership is inferred only from public calls and event/data contracts.
- No OpenChamber-owned SQLite database was found. The only repository SQLite use is read-only Cursor quota import (`packages/web/server/lib/quota/providers/cursor.js`).
- Items without code evidence are listed as `UNKNOWN / NEEDS FURTHER VERIFICATION` in `17-open-questions.md`.
