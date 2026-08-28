# Hard Coupling Points

| 耦合 | 证据与判断 | 替换含义 |
| --- | --- | --- |
| runner <-> durable Session | Session ID coordinator、inbox/event/projector | 必须一起处理 admission、history、recovery |
| context <-> Session Parts | context 从 projected Message/Part 与 compaction 选择 | 不能只替换 system prompt |
| context <-> Provider | model limit/capability、message/schema transform | context policy需了解 provider contract |
| tool <-> Session | tool context carries session/message; result becomes Part | executor替换需保留 result/event semantics |
| MCP <-> Tool | MCP definitions turned into model tools | MCP client alone不是 runtime integration |
| permission <-> Tool | visibility + ask/Deferred gate | 仅在 HTTP 做确认会绕过执行时检查 |
| server <-> runtime | server assembles Location service and V2 execution | transport可替代，composition不可遗漏 |
| config <-> runtime | instance-scoped config initializes agent/provider/MCP/plugin | reload/instance disposal policy是隐含耦合 |

最硬的共同替换单元是 Session durable execution + event/projector + context selection；Provider transform 和 Tool/MCP/Permission 是次级但高复杂度共同替换单元。HTTP UI client 是相对可分离的外围。
