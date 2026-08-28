# Open Questions

以下不是结论：

- `v1.18.21` 对当前 HEAD 的 SessionV2/runner/context paths 是否逐项等价。当前只确认 tag/version relationship，未逐文件 tag audit。
- `SessionRunner` 的精确 termination、multi-inference、retry、provider rate-limit、abort propagation 和 queued/steer promotion的代码级 sequence。
- actual context token estimate、auto compaction threshold、manual summarize failure behavior、summary message selection。
- provider stream usage 在 error/partial response/retry 时的最终 Part/Session accounting。
- Tool executor 对每个 builtin 的 permission、abort、persistence 和 output-limit matrix。
- persistent grant、permission timeout、remote reply 以及跨进程 permission 恢复。
- Session/MCP/Config instance disposal/reload 对正在运行 drains 的准确行为。
- SSE unbounded queue 的实际 backpressure/slow consumer protection。
- production SQLite corruption recovery、cleanup/vacuum 以及 DB backup policy。
- plugin hook surface 中对 main chat request/context/tool execution 的完整、版本化契约。

这些项应标为 `UNKNOWN / NEEDS VERIFICATION`，不应由常见 Agent 架构或 UI 观察补全。
