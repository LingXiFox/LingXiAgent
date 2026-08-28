# Compaction 与 Memory

## 实际机制

OpenCode 当前 context management 是 **B. summarization + selected history boundary + provider prompt cache**，不是 embedding/vector selective retrieval，也不是仅截断。

`packages/core/src/session/compaction.ts:176-247` 预测请求 token，超过 `model.limit.context - max(model.limit.output, COMPACTION_BUFFER)` 时运行独立 summarization stream；成功发布 `Compaction.Started/Ended`。runner 在 provider overflow 时可做一次 overflow compaction 并重试该 turn；第二次 overflow不再恢复（`runner/llm.ts:284-295,362-387`）。

compaction 后原 history 不被物理删除。`SessionHistory.entriesForRunner` 以最后 compaction checkpoint 作为读取边界，保留之后的 entries（`history.ts:24-99`）；projection 仍保留历史，便于 replay/revert/audit。`SessionMessageUpdater` 在 Compaction.Ended 添加 checkpoint message（`message-updater.ts:101-393`）。

## Summary owner

summary 使用 hidden `compaction` agent prompt（`opencode/src/agent/agent.ts:219-233`）并以 provider stream 生成；其 stored state 是 durable compaction event/checkpoint，不是另一套 long-term memory store。手动 V2 HTTP `compact`/`wait` 当前返回 `OperationUnavailableError`（`core/session.ts:417-423`），不要把旧 API/UI capability 当成当前 V2 canonical支持。

## Memory capability inventory

| Capability | 结论 |
| --- | --- |
| Session memory | FOUND：durable history、context epoch、compaction checkpoint |
| Project instructions/AGENTS | FOUND：system context source |
| Skills/reference guidance | FOUND：runner guidance |
| Long-term semantic memory | NOT FOUND |
| Embedding/vector DB retrieval | NOT FOUND |
| Explicit agent memory store | NOT FOUND |
| Tool result cache | NOT FOUND；tool results留在 Session projection/history |
| Provider prompt cache | FOUND；provider request cache controls/key |

summary prompt、small summary model fallback、token estimator exact algorithm和 compaction failure retry policy应继续以 `core/session/compaction.ts` 和 tests逐行核验；未确认时不得将其描述为固定阈值或 L1/L2/L3 design。
