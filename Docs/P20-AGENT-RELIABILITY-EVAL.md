# P20 Agent Reliability Eval

日期：2026-09-02

## 范围

本阶段只补 Runtime 可诊断性、恢复状态可见性和评测记录，不进入 P22 Local IPC、P23 Remote Runtime、GUI、新 Provider 或大规模新 Tool。现有 Session、AgentRun、Workflow、Tool、MCP、Provider 和 VCR 仍是行为权威。

## Reliability architecture

- `RuntimeDiagnosticsStore` 是进程内有界 actor，最多保留 4000 条结构化事件。
- `RuntimeDiagnosticsBundle` 通过只读控制面 `getDiagnostics` 导出，包含运行版本、协议版本、脱敏配置摘要、trace、近期错误、Provider/MCP 计数、Run/Workflow 状态、恢复项和 orphan 候选。
- correlation 使用现有 `SessionID`、`AgentRunID`、`rootRunID`、`parentRunID`、`WorkflowID`、`WorkflowTaskID`、turn execution UUID、model request ID 和 ToolCallID。
- 业务执行仍由原有 actor、Session lane、scheduler、persistence 和 Watchdog 负责；诊断写入是旁路操作。

## Tracing

SessionRuntime 的既有 step trace 现在同步进入结构化 store，覆盖 context build、provider stream、tool batch、Session parts、MCP 相关 tool、turn 完成或失败。AgentRun spawn、terminal 状态、Workflow create、HITL pending、recovery acknowledge 和 Core start/shutdown 也记录关联 ID。

trace 只保存事件名、状态、计数、错误码、hash 或关联 ID。禁止保存 prompt 正文、Tool 参数、Provider body、Authorization、credential、secret 和敏感环境变量。配置摘要只保存布尔值、策略名、上限和 durable/ephemeral 标记。

## Recovery

- `recoveryRequired` 不再被标记为 AgentRun terminal，允许 Core restore 重新识别它。
- 没有可安全重放依据的 AgentRun 仍进入 `recoveryRequired`，不自动重做副作用；需要显式恢复路径。
- 持久化 Tool batch 中的 pending HITL 仍由现有 Question/Permission runtime 重新挂接。
- Workflow running task 在重启后仍按既有规则变为 `recoveryRequired`，必须显式 acknowledge 后才重新排队。
- orphan 候选由 active/queued scheduler 状态和非 terminal Run 状态交叉判断，诊断只报告，不自动猜测或重放。

## Diagnostics bundle

`LingXiClient.diagnostics()` 和控制面 `getDiagnostics` 提供可导出的 Codable bundle。MCP 只导出 catalog、schema 文件数、schema 字节数、page fault、active lease 等计数，不导出 schema 正文。

## VCR

本阶段没有修改或重录 Golden。既有 VCR harness 继续负责无网络 replay、终态、错误、取消、run-id canonicalization 和 secret sanitizer。Golden 文件必须由原有测试确认 unchanged。

## Benchmark methodology

任务清单位于 `Benchmarks/P20-coding-task-manifest.json`，覆盖 bug fix、feature、multi-file、refactor、test repair、migration、exploration、Git investigation 和 failure recovery。最终 oracle 是目标测试、完整回归、无关 diff 和验证证据，不以 ToolCall 数量单独评分。

当前 raw result 位于 `Benchmarks/P20-coding-task-results.json`。LingXiAgent 无默认数据根、Provider credential 或本地模型，无法启动真实 Provider Run。Codex/OpenCode 的 CLI 可用，但在 LingXiAgent 无法以同条件运行时没有单独跑分，避免不公平比较。Claude Code 记录为 `NOT RUN — unavailable / unauthenticated`。没有猜测任何成绩，也没有为 benchmark 修改 Agent 行为。

## Required scenarios

专项测试覆盖诊断导出和敏感 metadata 脱敏。既有测试继续覆盖 Provider failure、Tool failure/timeout、MCP lease/failure、Subagent failure/timeout、HITL restart、Workflow checkpoint restart、无网络 VCR 和 LSP degrade。完整串行、并行、Golden、Trivy 结果以本次执行日志为准。

本次门禁记录：`swift build` PASS；`swift test --no-parallel` PASS，294 tests / 41 suites；`swift test` PASS，294 tests / 41 suites；Golden replay PASS；Golden unchanged PASS；`git diff --check` PASS；Trivy vulnerability、misconfiguration、license、secret 扫描均为 0 findings。

## Known limitations

1. trace 当前为 bounded in-memory，不是跨进程 durable trace。
2. orphan 是诊断候选，不是后台自动清理器。
3. MCP bundle 暴露计数，不暴露每个 server 的健康明细。
4. 四 Agent 对照 benchmark 尚未实际执行，因此本阶段不能授予产品层 Capability Seal。
