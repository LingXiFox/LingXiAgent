# Domain Dependency Map

```text
Server transport
  -> routing/auth/location context
  -> Session admission/execution

Agent orchestrator (Session runner)
  -> Session store/history/context epoch
  -> Agent config
  -> Provider + transform
  -> ToolRegistry
       -> Permission
       -> MCP
       -> platform adapters
  -> EventV2

EventV2
  -> SQLite events + projector
  -> Session/Message/Part projections
  -> bridge/global bus/SSE

Config
  -> Agent, Provider, MCP, Plugin, Permission inputs
```

依赖依据：HTTP `server.ts:212-306` layer graph；ToolRegistry deps `tool/registry.ts:427-452`；Event durable commit `core/event.ts:205-395`；Session projection `core/session/projector.ts:210-452`。箭头表示 runtime dependency，不表示每个模块只能经此路径通信。

域重组：Agent Orchestrator、Context Engine、Session Engine、Model Gateway、Tool Runtime、Permission Engine、MCP Runtime、Event Bus、Persistence、Config、Workspace/Platform、Server Transport、Plugin System。当前 folder layout 并不完全等于这些领域边界。
