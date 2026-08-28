# Agent Orchestrator

## 形态

OpenCode 当前 canonical orchestrator 是 event-driven durable admission 加 process-local serialized drain；drain 内部是循环式 provider-turn state machine，而不是递归 agent call 或 HTTP request loop。

| 层 | 模块/符号 | 调用方向 | 状态 owner |
| --- | --- | --- | --- |
| admission | `SessionV2.prompt` | input -> durable inbox -> wake | SQLite SessionInput/Event |
| schedule | `SessionExecution` / `SessionRunCoordinator` | wake/resume -> one Session drain | process-local Map/Fiber |
| placement | `SessionExecutionLocal.drain` | SessionStore location -> scoped runner | LocationServiceMap |
| turn | `SessionRunner.run` / `runTurnAttempt` | eligible input -> stream/tool/next turn | runner fiber + projected Session |

`SessionRunCoordinator` 的 Entry 保有 fiber、completion Deferred、pendingWake、stopping（`core/src/session/run-coordinator.ts:17-103`）。同一 Session 串行，不同 Session 可并行；wake 不等待且把 active session 合并为一次 pending wake，resume 加入现有 drain 或以 force 启动。

## 状态机

```text
admitted -> (resume=false) pending
admitted -> wake -> active drain
active -> promote steer / prepare epoch -> provider turn
provider turn -> tool calls -> settle -> reload history -> provider turn
provider turn -> no continuation -> queue promote or idle
overflow -> one compaction -> retry same turn
overflow again / provider failure / permission reject / interrupt -> failed or stopped drain
```

`runTurnAttempt` 的底层 lifecycle：prepare durable context epoch、read projected history、assemble request、stream、persist boundaries、settle tools。新用户输入在安全 provider-turn 边界才变可见；它不是直接向当前 request 注入 mutation。

## 保护与未实现项

- max steps 用 agent `steps` 控制并关闭 tools，而非无限 tool loop。
- nest depth 防护归 Task tool（`tool/task.ts:104-117`），默认 `subagent_depth` 1。
- `doom_loop` 是 permission policy，不是 runner generic iteration counter。
- provider rate limit/transient retry 的 canonical bounded policy：`NOT FOUND`；runner source明确留有 retry TODO。
- cluster/remote placement ownership：`NOT IMPLEMENTED`；local execution只处理当前进程，post-crash provider-work retry也没有被设计为自动行为。
