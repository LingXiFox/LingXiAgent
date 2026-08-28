# MCP Runtime

```text
config mcp entry
  -> MCP InstanceState connect local stdio / remote Streamable HTTP then SSE
  -> MCP client capabilities + McpCatalog.defs cache
  -> MCP.tools native definitions named `<server>_<tool>`
  -> ToolRegistry/model schema
  -> model call -> MCP client callTool
  -> tool Part/result -> next context
```

`mcp/index.ts:204-589` owns connections, local process transport, remote transport fallback, OAuth status, client lifecycle、tool-list-changed watch 和 finalizer close；state 是 directory instance scoped。local transport uses configured command/cwd/environment; remote transport tries Streamable HTTP then SSE and records `connected/disabled/failed/needs_auth/needs_client_registration`.

`MCP.tools()`（666-688）只返回已连接 client 的 cached definitions，按 config/experimental timeout 包装原生 client；`instructions()`（615-625）提供 server instructions、tool names。server instruction 能进入 system/context 的路径在 Session system assembly，工具 schema 则通过 registry adapter。资源、templates、prompts 是独立 MCP APIs，不等于 model tools。

OAuth token storage is delegated to `McpAuth`; no token value was read. Connection close/tool list notification publishes `McpEvent.ToolsChanged`，使下一次 registry resolution 看到新 catalog。
