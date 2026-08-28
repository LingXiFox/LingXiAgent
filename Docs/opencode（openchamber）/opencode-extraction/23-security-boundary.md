# Security Boundary

| 边界 | 已确认机制 | 限制 |
| --- | --- | --- |
| tool action | Agent/session rules -> Permission evaluate/ask | allow/reject 状态进程内 |
| filesystem | external directory/read/edit permission patterns | executor 仍必须正确 canonicalize/validate path |
| credentials | Auth/ProviderAuth/McpAuth service | 本研究不读取 credential store |
| MCP | configured local command or remote endpoint, OAuth/status | MCP tool 本身是外部能力，需 permission policy |
| plugins | local/external plugin loads, hooks with SDK/Bun access | third-party plugin is trusted code boundary |
| HTTP | ServerAuth, instance context, workspace routing | remote exposure needs correct configured auth/CORS |

`Agent` defaults ask for external directories and `.env` reads（`agent/agent.ts:119-136`）；`Permission` supports wildcard/path matching and deny precedence by last matching rule. `MCP.connectLocal` uses configured environment combined with process environment (`mcp/index.ts:340-370`)，所以 MCP config is an execution/security boundary, not mere metadata.

本报告只做架构静态分析，未做攻击测试。路径 traversal robustness、credential OS-store encryption、plugin package trust/sandbox、remote server default binding 都需要单独安全验证。
