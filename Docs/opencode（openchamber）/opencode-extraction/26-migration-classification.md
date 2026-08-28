# Capability Classification

只做当前能力分类，不给出 LingXi 实现设计。

| Current OpenCode capability | 候选分类 | Temporary OpenCode dependency | Difficulty |
| --- | --- | --- | --- |
| Session aggregate, inbox, projector, recovery | LingXi Core candidate | 是 | VERY HIGH |
| Context history/compaction/snapshot epoch | LingXi Core candidate | 是 | VERY HIGH |
| Provider catalog/model gateway | Core + runtime adapter candidate | 是 | HIGH |
| provider SDK transforms | Provider adapter candidate | 是 | HIGH |
| builtin tools / FS / shell / LSP | Tool runtime + platform adapter | 可逐个 | HIGH |
| MCP connection and adapter | Runtime adapter candidate | 可逐个 | HIGH |
| permission evaluation/UI reply bridge | Core policy + protocol candidate | 可逐个 | MEDIUM |
| Event durable log/projector | LingXi Core candidate | 是 | VERY HIGH |
| SSE/HTTP/OpenAPI client protocol | Protocol/transport candidate | 可替代 | MEDIUM |
| config/agent/plugin discovery | Platform/config candidate | 可并存 | MEDIUM |
| TUI/Desktop/SDK | client protocol consumers | 否 | LOW-MEDIUM |

难度理由：跨 provider 的兼容矩阵、durable sequence/replay、context compaction 的可恢复语义和任意 tool/MCP cancellation 都是行为性耦合，而非接口数量问题。
