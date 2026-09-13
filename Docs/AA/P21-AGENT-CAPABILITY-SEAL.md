# P21 Agent Capability Seal

日期：2026-09-02

## Seal rule

只有在可靠性专项、完整构建测试、VCR Golden unchanged、并行稳定性、Trivy 和真实 coding benchmark 都有可复核结果，且没有明显结构性能力差距时，才能写入 `AGENT CAPABILITY READY`。GUI 计划不降低门槛。

## Capability summary

当前源码具备：

- Session lane、AgentRun、Workflow checkpoint 和持久化状态。
- Provider、Tool、MCP、Subagent 的错误归一化和 Watchdog 终态。
- HITL pending state 的重启挂接。
- P17 code intelligence 的 bounded context 和 LSP degrade 路径。
- 结构化、脱敏、有界 Runtime diagnostics bundle。

## Comparison results

原始记录：`Benchmarks/P20-coding-task-results.json`。

| Agent | Success rate | Tool calls | Tokens | Wall time | Retries | Regression | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LingXiAgent | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Codex | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| OpenCode | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Claude Code | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN |

## Strengths

Runtime 的结构化生命周期和持久化边界清晰；失败通常能归一化为 terminal 或 explicit recoveryRequired；Workflow 不会在重启后无确认重放副作用；diagnostics 不携带原始凭据或正文。

## Weaknesses

- LingXiAgent 当前没有可启动真实 Provider Run 的配置。
- 缺少 Codex、OpenCode 与 LingXiAgent 的同任务实测对照。
- 当前只能报告 orphan 候选，尚未提供跨进程 durable orphan registry。

## Remaining blockers

1. LingXiAgent 没有可用的真实 Provider 执行环境，benchmark infrastructure 无法在公平条件下运行。
2. 因此无法证明 LingXiAgent 相对当前可运行 baseline 没有结构性能力差距。

Claude Code 的缺席不是 blocker，已按 `NOT RUN — unavailable / unauthenticated` 记录。

## Final seal decision

`AGENT CAPABILITY BLOCKED`

在获得可重复的四 Agent 执行 harness、同一 repository snapshot、同一 test oracle、同一权限和完整 raw metrics 后，必须重新运行 P20 benchmark，再重新执行本 Seal。不得修改 Golden 或加入 benchmark-specific Agent 逻辑来掩盖结果。
