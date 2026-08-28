# Agent Turn Sequence

## 从 HTTP prompt 到 idle

```mermaid
sequenceDiagram
  participant C as Client
  participant H as Session HTTP handler
  participant S as SessionV2
  participant E as EventV2 + SQLite projector
  participant X as SessionExecution/Coordinator
  participant R as Location SessionRunner
  participant P as Provider stream
  participant T as ToolRegistry/Permission/MCP
  participant SSE as Event/SSE

  C->>H: POST session.prompt(messageID, prompt, delivery, resume)
  H->>S: prompt()
  S->>E: PromptAdmitted durable event + session_input row
  S->>X: wake(sessionID), unless resume=false
  H-->>C: admitted input
  X->>R: drain sessionID in Session location
  R->>E: initialize/prepare context epoch; promote eligible input
  R->>P: one llm.stream(request)
  P-->>R: text/reasoning/tool/usage events
  R->>E: durable Session/Message/Part boundary events
  E-->>SSE: projected/domain event
  alt tool call
    R->>T: materialize + settle tools
    T->>E: tool called/result events
    R->>R: reload projection history; next provider turn
  else no tool or step limit
    R->>R: promote steer, otherwise one queue input or idle
  end
```

## 精确入口与状态

- Protocol route：`packages/protocol/src/groups/session.ts:205-224`，`session.prompt` 接收 stable message ID、delivery（默认 `steer`）与 `resume`。
- HTTP handler：`packages/server/src/handlers/session.ts:140-170` 调用 `SessionV2.prompt`，将 not-found/conflict 映射为 HTTP API error。
- admission：`packages/core/src/session.ts:360-385` 在 uninterruptible scope 中确认 Session、规范化/准入 input、仅在 `resume !== false` 调 `SessionExecution.wake`。HTTP 成功是“持久准入成功”，不是模型完成。
- runner：`packages/core/src/session/runner/llm.ts:390-413` 的 `SessionRunner.run` 是 canonical agent orchestration entry point；`SessionExecutionLocal` 仅按 location 取并调用该 runner（`execution/local.ts:17-27`）。

Message ID 重试不是无条件 idempotency：`SessionInput.find/admit/equivalent`（`core/src/session/input.ts:32-80,191-214`）要求 Session、规范化 prompt、delivery 都一致，否则 `PromptConflictError`。

## Turn 与结束条件

一个 admitted input 可引发多次 inference：每次 provider turn 恰好一处 `llm.stream(request)`（`runner/llm.ts:205-221,239-282`）；tool calls 全部 settle 后重建 projection history 进入下一轮（199-201、250-278、303-352）。Agent step limit 到达时移除 tool definitions 并注入 `MAX_STEPS_PROMPT`。

runner 优先批量 promote `steer`；无 steer 时，只有当前工作将 idle 才 promote 一个 `queue`，然后重新评估（`input.ts:245-287`, `runner/llm.ts:390-412`）。无 eligible work 且不是 forced drain 时即 idle。

## 错误、取消、retry

- provider `LLMError` 未已被 provider-error event 表示时，写 assistant `Step.Failed`、失败未 settle tool，再向上抛 stream cause（`runner/llm.ts:286-352`）。HTTP caller不会收到这个后续失败。
- interrupt 只作用本进程 active coordinator fiber；idle 是 no-op。未完成 tool 写 interrupted，assistant 已开始则写 provider turn interrupted（302-317）。新 drain 也会清理遗留 pending/running tool（119-139）。
- permission/question reject 停止该 loop，不会伪造 model-facing tool result（144-150、303-308）。
- `Retried` event schema存在，但 canonical runner 尚未实现 bounded provider retry；不要把 wake 后新 drain 当作 retry。
