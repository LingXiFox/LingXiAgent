# Runtime 拓扑

```text
HTTP/CLI/ACP client
  -> typed HttpApi handler (instance/workspace/auth context)
  -> SessionV2 prompt admission + SessionExecution wake
  -> process-global SessionRunCoordinator (by Session ID)
  -> Location-scoped SessionRunner
       -> Session/context/history + agent + ToolRegistry
       -> Provider.getLanguage -> llm.stream
       -> stream processor -> Message/Part events + tool continuation
  -> EventV2 durable commit + SessionProjector SQLite projection
  -> EventV2Bridge / GlobalBus -> SSE
```

`packages/opencode/src/server/routes/instance/httpapi/server.ts:212-269` 是 HTTP server 组合根：V1 runtime services 与 `SessionV2`、`SessionExecution`、`SessionProjector` 都在此 layer graph 装配。`packages/core/src/session/execution/local.ts:10-36` 表明协调器是 process-global、Session-ID keyed；真正 runner 在 location layer 内取得。

状态 owner：

| 状态 | Owner | 生命周期 |
| --- | --- | --- |
| durable session input / aggregate events | Core SQLite + EventV2 | 跨进程重启 |
| Session/Message/Part projection | SQLite projector | 跨进程重启 |
| active drain/coalesced wakes | `SessionRunCoordinator` | 当前进程 |
| MCP clients、tool definitions、agent/config | `InstanceState` | directory/workspace instance |
| pending permission | `Permission` InstanceState | 当前实例，进程内 |
| SSE subscription queue | HTTP request | 单连接 |

这说明 OpenCode Server 不只是 HTTP wrapper：server 是 runtime composition root；HTTP endpoint 本身不拥有 agent loop。
