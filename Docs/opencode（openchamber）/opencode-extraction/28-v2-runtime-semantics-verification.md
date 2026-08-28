# V2 Runtime Semantics Verification

## Scope

本补充文档复核 OpenCode 当前 `dev` HEAD `755ebdb94ee755a9d5691e47af2c16f56696996e` 的 V2 core runtime。它补全 `27-open-questions.md` 中五项待验证项；只陈述静态源码可证实的行为，不将 TODO、注释目标或 V1 行为外推为 V2 保证。

状态标记：

- `CONFIRMED`：当前路径存在直接实现。
- `NOT IMPLEMENTED`：源码明确没有该能力或公开 API 返回 unavailable。
- `LIMIT`：有实现，但其边界应被调用方视为限制。

## 1. Context Token Estimator And Compaction Threshold

### Estimator

`CONFIRMED`：V2 不使用模型专属 tokenizer。`Token.estimate` 是 `Math.round(input.length / 4)`，因此中英文比例、工具 JSON、provider-native 编码和实际 tokenizer 差异都不会被精确建模。

`SessionCompaction.compactIfNeeded` 对以下对象 `JSON.stringify` 后估算：

- `request.system`
- `request.messages`
- `request.tools`

输出 token 预算不包含在估算对象中，而在阈值的右侧单独预留。

### Automatic Threshold

`CONFIRMED`：只有以下条件同时成立才会自动 compact：

1. config 的 `compaction.auto` 未关闭，默认 `true`。
2. `model.route.defaults.limits.context` 是正数。
3. 估算输入大于 `context - max(output, buffer)`。

默认值如下：

| Setting | Default |
| --- | ---: |
| `buffer` | 20,000 tokens |
| `keep.tokens` | 8,000 tokens |
| summary max output | 4,096 tokens |
| serialized tool/shell output | 2,000 characters each |

`output` 来自 request `generation.maxTokens`，否则使用 route 的 output limit；若都没有则为 `0`。配置文档按 entries 顺序 reduce，后遇到的 `compaction.auto`、`buffer`、`keep.tokens` 覆盖前值。

### Summary Selection And Overflow Recovery

`CONFIRMED`：compact 时先忽略旧 compaction message，将普通历史序列化。从尾部向前累计，保留估算值不超过 `keep.tokens` 的 recent；之前内容作为 head 摘要。单条末尾消息若自身超过 keep budget，则不会进入 recent。

已完成 tool output 以 text/file placeholder 序列化后截断到 2,000 字符；失败 tool 仅记录 error message。summary request 不带 tools，最大输出为 `min(model output limit, 4,096)`，并在 `Token.estimate(summaryPrompt) > context - summaryOutput` 时拒绝 compact。

`CONFIRMED`：正常阈值触发后，runner 以新的 history 重建 turn。若 provider 在 assistant start 前报 context overflow，runner 也可 compact 后只重试该 provider turn 一次；post-compaction attempt 再 overflow 会作为 defect 终止，不能无限循环。

`NOT IMPLEMENTED`：`SessionV2.compact(...)` 明确返回 `Session.OperationUnavailableError`，没有公开手动 compact API。

## 2. SessionRunner Retry, Abort, And Termination

### Drain And Continuation

`CONFIRMED`：`SessionRunner.run` 仅在 `force` 或存在 pending steer/queue input 时启动。每个 drain 开始前，旧 assistant 中尚为 `pending` 或 `running` 的 tool 都会被 durable 地标记为 `Tool.Failed("Tool execution interrupted")`。

一个 provider turn 只调用一次 `llm.stream(request)`。local tool call 由 fiber set 并发启动，所有 settlement 完成后才重载 projection history 并进入下一 turn。turn 在以下情况下继续：

- local tool call 已启动且 provider 未报错；
- active drain 中有新的 steer input；
- 当前 drain 空闲后存在 queue input，且每次只 promote 一个 queue input。

新 prompt promotion 会把 agent step 计数重置为 1。达到 agent `steps` 上限时，request 追加 `MAX_STEPS_PROMPT` 且禁用 tools。

### Provider Failure And Abort

`CONFIRMED`：provider 以 `provider-error` event 结束时，publisher 写入 `Step.Failed`，所有未 settlement 的 tool 写为失败，turn 不再继续。若 stream 以 `LLMError` 失败而没有先发 provider-error，runner 同样写 assistant/tool failure，但随后将原 failure cause 返回给 coordinator。

`CONFIRMED`：interrupt 会清除 tool fiber set，未 settlement tool 被标为 `Tool execution interrupted`；若 assistant 仍 active，写 `Step.Failed("Provider turn interrupted")`。`SessionRunCoordinator.interrupt` 只影响本进程持有的 active fiber，idle Session 是 no-op，并且会丢弃已合并但尚未处理的 wake。

`CONFIRMED`：Permission reject 或 Question reject 会使 tool fibers 清除、未 settlement tools 写失败，并 interrupt 当前 runner loop，而不是将拒绝文字作为 model-facing tool result。

`LIMIT`：runner 把 tool settlement 放在可中断区，且没有为 side effect 建立 durable invocation lease。进程崩溃可能发生在 `Tool.Called` 持久化之后和最终 `Tool.Success`/`Tool.Failed` 之前；下次显式 drain 会把投影中遗留的 pending/running call 标记失败，不会重新执行它。`file-mutation.ts` 也明确将此段的 crash recovery/idempotency 标为 TODO。

`NOT IMPLEMENTED`：没有 canonical 的 bounded provider retry、重复 tool-call 去重、durable busy/retrying/terminal 状态，或 post-crash continuation 自动恢复。`runner/llm.ts` 将 durable continuation recovery 标为未来设计。

## 3. Tool Cancellation And Permission Execution Matrix

### Registry Boundary

`CONFIRMED`：materialization 只做 catalog visibility。若 agent ruleset 的最后匹配规则是 `deny` 且 resource 为 `*`，该 tool definition 不会提供给模型；这不是执行授权。已 materialize call 在 settlement 时捕获有效 registration，未知或 stale call 返回 model-facing error result，而不执行本地 handler。

`CONFIRMED`：Tool runtime 先 schema-decode input，再调用 leaf executor，再 schema-encode output。`ToolFailure` 转为 error result；其他 defect 保持为 defect，由 runner 将未结算 tool 标为失败。

### Builtin Matrix

| Builtin | Execution authorization | Cancellation / failure behavior |
| --- | --- | --- |
| `read` | `read` approval；external absolute path 另需 `external_directory` | read/image errors 转 `ToolFailure`；无独立 cancellation settlement。 |
| `bash` | `bash` approval；external workdir 另需 `external_directory` | app process timeout 返回成功-shaped timeout output；其他错误转 `ToolFailure`；runner interrupt 终止 fiber，process-group cleanup 完整性仍 TODO。 |
| `write` | `edit` approval；external absolute path 先需 `external_directory` | 未处理异常转 `ToolFailure`；实际写入无跨崩溃幂等保证。 |
| `edit` | `edit` approval；external absolute path 先需 `external_directory` | 读取后 conditional write；若批准后内容改变，返回可恢复的 stale-content error。 |
| `apply_patch` | 对全部 target 一次 `edit` approval；每个 external directory 先批准 | 顺序应用；后续失败时保留已应用变更并报告 partial apply；无 rollback。 |

`LIMIT`：上述是当前已 port 的 local builtin，不是所有 OpenCode 工具的完整产品矩阵。`packages/core/src/tool/builtins.ts` 明确标注 task、LSP、repo clone/overview、plan exit、Rune/code mode 等仍未 port；MCP、plugin、remote managed-output 与其 cancellation/permission 生命周期也未在此 V2 registry 中实现。

### Permission State

`CONFIRMED`：`PermissionV2.assert` 依次评估 agent rules 和项目保存的 allow rules。任一 resource deny 则立即 `BlockedError`；任一 ask 则创建 in-memory deferred request，并发布 Asked event 后等待 reply；allow 直接通过。

`CONFIRMED`：reject 会拒绝同一 Session 的全部 pending permission。带 feedback 的 reject 转 `CorrectedError`，无 feedback 转 `DeclinedError`。runner 将这两类拒绝识别为 user-declined，终止当前 loop。

`LIMIT`：pending permission 和 question 都是 Location 进程内 map；layer finalizer 把遗留请求拒绝。没有持久化 pending state、重启后 reply、超时策略或跨进程恢复。

## 4. Provider Error, Usage, And Retry Accounting

### Usage And Session Accounting

`CONFIRMED`：publisher 只在收到 `step-finish` 后保存 tokens，并将每个值规范化为有限且不小于零：

- input = `nonCachedInputTokens`
- output = `visibleOutputTokens`
- reasoning = `reasoningTokens`
- cache read/write = 对应 cache input token 字段

在成功且没有 provider error 的 turn 末尾，runner 写 `Step.Ended`，目前 cost 固定为 `0`，tokens 为上述规范化结果。V2 projector 将 `Step.Ended` 投影到 assistant message；本 V2 projector 没有把这些 step usage 再累加到 `SessionTable`，其中的 Session-level `applyUsage` 只处理 V1 Part event。

`LIMIT`：若 provider error、stream failure、interrupt 或缺少 `step-finish`，不会写 `Step.Ended` usage；因此 partial provider usage 不会进入 V2 assistant message 或 Session totals。不能将 current V2 的 Session totals 当作所有 V2 provider turn 的完整 usage 账本。

### Retry Layers

`CONFIRMED`：HTTP `RequestExecutor` 对 retryable `LLMError` 最多再试 2 次。429（非 quota）映射为 retryable rate limit；所有 5xx 及 503/504/529 映射为 retryable provider-internal。`Retry-After` / `Retry-After-Ms` 优先，最多等待 10 秒；否则使用 500ms 起的随机指数退避，上限 10 秒。

`CONFIRMED`：401/403、quota 429、content policy、invalid request/context overflow、unknown provider output 与 transport errors 都不是 transport retry 的对象。尤其网络/timeout 形成的 `TransportReason.retryable === false`。

`CONFIRMED`：streaming protocol 也可以 emit `provider-error` event；该 event 会持久化 Step.Failed，但不会进入 RequestExecutor 的 HTTP retry loop。runner 不读取 `ProviderErrorEvent.retryable` 做第二次 provider attempt。

`NOT IMPLEMENTED`：runner-level retry notice 的 projector 被注释掉，且 TODO 明确要求未来加入 bounded provider retry。因此 transport retry 与 overflow-compaction retry 是当前仅有的自动重试语义。

## 5. Durable Event And Projector Recovery

### Atomic Write And Projection

`CONFIRMED`：durable EventV2 在 SQLite immediate transaction 内执行：读取 aggregate sequence/owner、验证 sequence 与 event ID、运行已注册 projector、运行可选 local commit hook、更新 `event_sequence`、插入 `event`。任一 projector 或 commit 失败会回滚该 transaction，之后才向 listeners/pubsub 通知。

Session prompt admission 是 durable `PromptAdmitted` event 和 `session_input` row 的同事务 projection。重用同一 message ID 时，`SessionInput.admit` 会先读 inbox；若首次 publish 在投影竞态后抛 defect，会重新读取已存 row 达到 exact retry。`SessionV2.prompt` 再校验 session、prompt 和 delivery 是否等价，不等价则返回 `PromptConflictError`。

`CONFIRMED`：历史 durable stream 先查询 event table，再用每 aggregate 一个 sliding(1) wake 追 live event。reader 从 `after` sequence 按序读取；event table 对 `(aggregate_id, seq)` 唯一，replay 要求同 aggregate、连续 sequence 和相同 payload，否则拒绝 divergence。

### Projection And Restart Limits

`CONFIRMED`：Session projector 不是异步 eventual worker；对当前进程中新 publish 的 durable Session event，它在 event transaction 内更新 `session`、`session_input`、`session_message` projection。assistant/tool message updater 通过 event sequence 写入或更新投影行。

`CONFIRMED`：projected history 读取会以 latest compaction 和 context epoch `baseline_seq` 过滤已替代的旧消息。context epoch 在首次 runner 使用时写入 baseline/snapshot；后续在 compaction 或 system context 变化后 reconcile/replace。

`LIMIT`：`EventV2.replay`/`replayAll` 提供的是外部 serialized event 的受序列和 owner 保护的重放 API；它不是启动时自动扫描 session event 表并重建 Session projection 的后台机制。当前未找到 Session projector checkpoint、startup full replay、projection repair job 或 Session execution lease。

`NOT IMPLEMENTED`：crash 后不会自动恢复 provider turn。进程本地 coordinator 和 Location permission/question state 都会消失；已 durable 但未 promote 的 inbox 可由之后的 explicit `resume`/新 wake 消费，已开始的 provider/tool work 则不重试。当前架构注释明确要求将 post-crash continuation recovery 作为单独设计。

## Source Evidence

- `packages/core/src/util/token.ts`
- `packages/core/src/session/compaction.ts`
- `packages/core/src/session/runner/llm.ts`
- `packages/core/src/session/run-coordinator.ts`
- `packages/core/src/tool/{registry,tool,bash,read,write,edit,apply-patch}.ts`
- `packages/core/src/{permission,question,file-mutation,event}.ts`
- `packages/core/src/session/{input,projector,history,context-epoch}.ts`
- `packages/core/src/session/runner/publish-llm-event.ts`
- `packages/llm/src/{schema/errors,route/executor,route/client}.ts`
