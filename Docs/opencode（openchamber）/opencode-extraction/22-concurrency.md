# Concurrency

- `SessionExecutionLocal` 使用 `SessionRunCoordinator`，以 Session ID 组织 active/interrupt/resume/wake；同 Session wake 会合并，不同 Session 可并行（`execution/local.ts:14-36`）。
- runner 启动前从 `SessionStore` 查 location，随后只在该 location service scope drain；这避免把 location runtime 当成全局 singleton。
- durable EventV2 per aggregate 通过 SQLite immediate transaction + seq 强制排序；跨 aggregate 的全局顺序不保证。
- MCP initial connections、clients close、registry plugin tool conversion 中存在 unbounded concurrency；plugin hook registration 则刻意 sequential（plugin/index.ts:219-225）。
- SSE 连接单独 queue；不是 EventV2 durable replay consumer，且 unbounded。
- Permission pending 和 temporary approved rules 是 instance-local map；并发 prompt 的 cross-session persistence 不能依赖它。

Tool call parallelism、同一 turn 的 provider request overlap、provider rate limiter 的准确限制应以 `SessionRunner`/processor 源码和 tests 验证；不要从 CLI/TUI concurrency 推论。
