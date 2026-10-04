# P/E-Core Context Integrity Verification and Repair

日期：2026-10-04。基线：`11376bab46e04e066b9b8e5ebf1321aedf73c5e2`。

本轮恢复上下文投影、精确召回及 residency 语义，并审计 Branch Prediction。原 smoke 保持暂停。本轮没有重新执行 T001–T020，也没有把受上下文缺失污染的旧运行结果用于评价模型能力。

## 验收状态

| Invariant | Result |
| --- | --- |
| FAILURE_EVIDENCE_SURVIVES_COMPACTION | PASS |
| ECORE_INDEX_PROVIDER_PARITY | PASS |
| RECALL_REF_ROUND_TRIP | PASS |
| RESIDENCY_PREVENTS_REPAGEOUT | PASS |
| P_E_RECALL_ACTIVE_ROUND_TRIP | PASS |
| BOUNDED_ECORE_INDEX_PROJECTION | PASS |
| INDEX_GROWTH_DECOUPLED_FROM_ECORE_SIZE | PASS |
| PAGE_OUT_MUST_NOT_CAUSE_UNBOUNDED_INDEX_GROWTH | PASS |
| BRANCH_PREDICTION_REAL_FEED | PASS |
| BRANCH_PREDICTION_NON_ABSTAIN | PASS |
| BRANCH_PREDICTION_HIT_MISS_ACCOUNTING | PASS |
| BRANCH_PREDICTION_TELEMETRY | PASS |
| BRANCH_PREDICTION_STATE_LIFECYCLE | PASS |
| BRANCH_PREDICTION_RUNTIME_CONSUMER | NONE |
| BRANCH_PREDICTION_STEERING | DISABLED_BY_DESIGN |

PASS 指本轮源码及生产组件集成重放的验收结果。当前 GUI/Core 未重启加载新二进制，本轮没有真实 LM Studio 推理，也没有宣称新的实机 smoke/endurance 已通过。

## 复现先于实现

先新增 `PEContextIntegrityTests` 的五项回归，再运行旧实现：五项全部失败。随后增加 Responses remote continuation、失败结果前置投影、Host shutdown 生命周期的独立失败复现，再修实现。

真实 fixture：`Tests/LingXiAgentTests/VCR/Fixtures/T011-failed-tool.json`。

SHA256：`db5a306beeba11b4591d939f6e69ad53fa9d316034e75b0e6e8101278ef7b3ff`。

| 项目 | 修复前 | 修复后 |
| --- | --- | --- |
| T011 失败输出 | 原正文 9,864 字符；原编码结果 485 字符，stdout 摘要 240 字符；NameError 消失 | 编码结果 4,629 字符，诊断 evidence 有界为 4,000 字符以内；NameError、exitCode=1、失败测试、文件及 line 198 存活 |
| 带稳定 system 的索引编码 | Responses 存活，Chat/Anthropic 删除索引 | Chat、Responses、Anthropic 均包含同一个 RecallRef |
| Responses remote continuation | 恢复的早期证据被 tail 裁剪；索引重复两次 | P/E segment 请求重建当前 active context；证据存活，索引仅一份 |
| 冷启动公开 ref 召回 | 映射和对象存在，工具仍返回 not found | 原样传入 ref，正式 resolver 解析 object，返回 payload |
| 同一历史 occurrence，连续 8 次装配 | 8 条 reference，反复卸载 | 1 次 attempt、1 次 new、1 条 reference；durable history 不变 |
| 无正文的结构化失败归档 | error code/message/exit evidence 丢失 | 归档保留结构化 ToolResult，包括 diagnostics、error、exitCode、输出句柄 |
| Host shutdown 的预测 state | shutdown 后 shared predictor 仍保留 state | 仅清所属 Session state；其他 Host 的 Session state 保留 |

旧 smoke 的 8,940 条 reference / 141 个 occurrence / 138 个对象是历史取证数据。本轮没有删除、重写或迁移这些真实归档，不能把新测试的 8→1 说成原 smoke 的归档数量已经下降。

## 修复路径与测试

### 失败诊断

`FailureDiagnosticEvidence.render` 按异常签名、失败测试、位置及输出尾部选择证据，不依赖纯前缀。原 stdout/stderr 摘要字段仍保留；新增 evidence 补齐失败原因，使用现有 ToolResultBudget 的字符预算。

`ModelToolResultProjection.projectToolResult` 在 Context Assembly 前就建立有界失败投影，避免预算估计继续按长失败正文计算。重复投影从 evidence 字段读取原诊断，避免把 escaped JSON 当成一整行再次丢弃。ToolResult 的原始正文和诊断仍在 SessionStore / ToolExchangeBatch 内，归档使用确定性 sorted-key JSON。输出句柄及 modelStepID 在投影中保留。

位置：`Modules/Model/FailureDiagnosticEvidence.swift`、`ModelDomain.swift`、`Modules/Context/ContextCompaction.swift`、`ContextProjection.swift`、`LingXiProtocol/ToolTypes.swift`。

测试：

- `failureEvidenceSurvivesRealT011WireEncoding`
- `failureEvidenceSurvivesPreProjectionAndRepeatedEncodingWithoutStreams`
- `structuredFailureSurvivesToolBatchArchive`

### 一等索引 segment / provider parity

ContextEntry 和 ModelMessage 显式携带 `ModelContextSegment.eCoreRetrievalProjection`；重新 admit 的历史携带 `recalledOccurrence`。语义不再只依赖 system role 或正文标题。

共享 provider context 投影仅去掉与 immutable base 完全相同的重复 system 内容，保留动态内容和索引。Chat 编码为 system message，Responses 编码为 developer input，Anthropic 放入 system 内容；协议表示不同，ref 内容一致。Responses 有 remote state 时，P/E segment 会使请求使用完整的当前 assembled active context，不能用远端旧历史和最新 tool tail 代替它。

位置：`PCoreContextEngine.swift`、`ModelDomain.swift`、`OpenAICompatibleProvider.swift`、`OpenAIResponsesProvider.swift`、`AnthropicMessagesProvider.swift`。

测试：`eCoreIndexSurvivesAllProvidersWithCachePlan`、`responsesRemoteContinuationCannotDiscardOrDuplicateECoreSegments`；既有三种 adapter/contract 测试也通过。此仓库的上述三种生产 wire adapter 已覆盖，未把不存在的 adapter 算作已验证。

### RecallRef 与 admission

路径：`context_recall(id: ref)` → `ECoreObjectStore.requestRecall` → session-scoped `reference` mapping → `ContextObjectID` → `recall` slice。

工具返回后，store 只登记 pending admission。SessionRuntime 先完成正常压力收敛，再调用 `ContextCompactor.admitRequestedRecalls`，按剩余预算恢复原 canonical occurrence。成功会更新 residency 并保存；预算不足会记录 `recallRejected` 和 `inputBudgetExceeded: required=..., hard=...`。不能以 resolver success 代替 admission。

已有工具产物的 placeholder 也使用正式 reference mapping，不额外复制 payload。旧 object-ID 调用保留兼容支持；新 index/placeholder 不要求模型知道内部 object ID。Tool schema 保持原样。

位置：`ECoreObjectFabric.swift`、`BuiltinTools.swift`、`ContextProjection.swift`、`ContextCompaction.swift`、`SessionRuntime.swift`。

测试：`recallRefRoundTripsThroughPublicTool`、`recallBudgetRejectionIsExplicitAndDoesNotReadmitHistory`、`pageOutRetryIsDeduplicatedAndFailureMemoryFallbackIsRecallable`。

### Residency 与 durable history

SessionStore 继续保存完整逻辑历史。每次装配先调用 `activeEntries`，排除 derived/pagedOut/superseded occurrence；新 tail、当前用户消息和 live causal batch 仍可进入上下文。明确 admission 才将历史重新设为 active。scheduler skip 也会重建唯一的有界 index，避免索引消失。

同步覆盖了 SessionRuntime 的首轮状态与 AgentRuntime 的缺省 snapshot 路径。持久 residency 恢复后仍参与过滤；已 admit 的导入 payload 可从 reference 恢复。缓存 pressure、评分、排名及 P/E target/soft/hard 不变。

测试：`residencyPreventsRepeatedCanonicalPageOut`、`residencySurvivesRestartAndOnlyExplicitRecallReadmits`。旧 manual-compaction 测试改为验证已经卸载的历史不会再次产生新 reference；极小 budget 下不再允许索引 fallback 越过其独立 hard budget。

### P → E → Recall → Active Context 组合重放

测试：`realPersistentSessionRuntimeReplaysPToERecallActiveFailure`。

使用真实 CoreHost、SQLite-backed SessionStore、SessionRuntime、ContextCacheController、磁盘 E-Core、公开 ContextRecallTool、真实 Context Assembly 和三种 wire encoder。只有模型决策用 scripted provider 回放；没有替换 context/cache/store/recall 的生产实现。

1. 把真实 T011 ToolResult 和配对 ToolCall 写入独立持久 Session。
2. 将已 consumed 的 causal batch page-out，保留原 durable messages。
3. 真实 SessionRuntime 的第一请求携带有界 index。
4. 从这个 index 原样取出 ref，实际执行 `context_recall`。
5. 下一请求重新 admit 原 occurrence，residency 为 active。
6. 三种 wire 都包含原 NameError；原 ToolResult 在持久 Session 中仍逐字段一致。
7. 真实 Debug Hub 的 lifecycle phase 顺序严格为 `pageOutAttempt → pageOutNew → recallRequested → recallResolved → recallAdmitted`。

本轮不是只用 mock 拼一个最终 ModelRequest；真实 model inference 留待后续相同 workload 的 smoke。

## 有界索引规模

沿用既有预算，固定 hard allowance 为 `min(512, hardInputLimit / 8)`，最多 8 个 occurrence references；所有输出都必须同时满足独立索引 allowance 和总输入预算。移除单条 fallback 绕过独立 allowance 的路径。

候选选择使用现有 `searchReferences` ranking，随后用近期 references 补足 Top-K；未改变打分公式。投影检索不伪装成 payload recall telemetry。summary 有界，projection 淘汰不删除 object 或 exact mapping。

| E-Core objects | Index tokens |
| ---: | ---: |
| 10 | 358 |
| 100 | 361 |
| 1,000 | 363 |
| 2,000 | 365 |

测试：`boundedIndexGrowthAndQueryChangesPreserveExactMapping`。验证了相关对象进入 projection、未投影对象仍可 exact restore、query 改变后之前不可见对象重新进入 projection、P-Core 总使用量不超过 resident baseline + 512。

百万级对象未实测；输出 hard cap 与总对象数量无关。完整内部检索的扫描成本仍沿用旧实现，本轮没有做大规模检索性能优化。

## Telemetry

`ECoreLifecycleSnapshot` 累计区分 `pageOutAttempt / pageOutNew / pageOutDeduplicated` 与 `recallRequested / recallResolved / recallAdmitted / recallRejected`，最近事件队列有界为 256。正式 Debug Hub 事件携带 `lifecyclePhase` 和 `rejectionReason`；现有 Observatory 事件摘要显示它们，未新增布局。

幂等重试测试：attempt=2、new=1、deduplicated=1。预算拒绝测试：resolved=1、admitted=0、rejected=1。Turn 在 admission 前终止时，pending recall 会以 `turnTerminatedBeforeAdmission` 拒绝，避免静默延迟到下一轮。

## Branch Prediction 数据流审计

`Branch Prediction currently operates as observation-only telemetry.`

| 分类 | 当前生产路径 |
| --- | --- |
| Producer | SessionRuntime 正常 settled tools；subagent 映射为 `.subagent(task: "")`；零 ToolCall 答复映射 directAnswer；CancellationError 映射 userInterrupt |
| Predictor | 每 Session 独立 history，Variable-Order Markov，order≤3，现有 gate confidence≥0.25、support≥2、matchedOrder≥1 |
| Accounting | 每次 record 先核对上一次 expected action，再训练/预测；steps=hits+misses，是被评分的预测数，非全部 tool steps |
| Transport | CoreHost ContextState / DebugObservatory snapshot |
| Presentation | macOS Observatory、TUI、WebUI；macOS 现有卡片显示 hint/confidence/support/order/abstained/steps/hits/misses/实际 hit rate |
| Runtime consumer | NONE；没有读取 hint 来影响 model selection、tool choice、prompt、eviction、heat 或 retention 的生产路径 |

真实 SessionRuntime 轨迹用生产 read_file、grep、write_file、shell 反复执行 6 次，共 24 个成功 ToolResult，加一次 directAnswer。首个有效 hint=`tool:grep`、confidence=1、support=3、order=1；也真实产生 `tool:write_file` hint。最终 hits=19、misses=1、scored steps=20、hit rate=95%。最后 directAnswer 没有可匹配的后继规律，所以最终快照 abstained=true；不能把它解释为此前一直 abstain。

原 smoke 只读统计：176 个 prediction snapshots，159 个 non-abstain；末尾 hint=tool:write_file、confidence=0.6、support=5、order=3、hits=47、misses=31。support 最大值为 222。这些是轨迹观测结果，不是模型完成任务正确率。

生命周期：turn 结束保留学习；删除/撤回清 state；本轮修复 AgentRuntime shutdown 未清 shared predictor 的泄漏，按所有所属 lane 清理，包含 idle runtime 已被 evict 的 Session。双 Host 测试确认不清其他 Host 的状态。

测试：`realSessionRuntimeTrajectoryLearnsScoresAndPublishesToObservatory`、`hostShutdownClearsOwnedPredictionStates`、既有 `BranchPredictionRuntimeTests`。

Findings（本轮保持原有 action 语义）：

- `.askQuestion`、`.finish`、`.cancel` 专用 token 没有独立生产 feed；question 走普通 tool token，取消主要走 userInterrupt。
- durable recovery 的已执行工具补录路径没有相同的正常-loop predictor feed。
- feed 的 tool action 不区分成功/失败；directAnswer 在最终 completion guard 前记录，所以它代表模型选择直接答复，不保证 Runtime 已认可完成。
- predictor state 不跨 Core 重启持久化。本轮没有新增 consumer，也没有将上述 observation 改为 steering。

冻结设计文档已要求 Branch Prediction 暂不进入 ContextCompaction / retention scoring。本轮维持该设计；若要新增执行 consumer，需后续单独架构决策。

## 冻结与交付验证

- eviction scoring 区段与基线逐字一致。
- reference retrieval ranking 区段与基线逐字一致。
- BranchPredictionFabric / BranchPredictionRuntime 算法文件与基线完全一致；仅所属 Host shutdown 生命周期补清理。
- P/E policy/budget resolver、Agent prompt、Tool schema、LM Studio/Qwen 配置和 T001–T020 corpus 未改。
- GUI 没有布局调整；仅已有 Observatory 的语义文字、hit rate 和事件摘要补信息。
- 固定 step limit / progress-aware safety mechanism 留作独立任务，没有改成 128，也没有改 Tool Loop 的拦截算法。
- 最新相关回归：100 项 / 11 suites 通过。补充 telemetry、Observatory、规模、生命周期检查：59 项 / 9 suites 通过。两组有重叠，不累加为 159。
- `Scripts/bundle-mac-app.sh debug` 成功构建和打包 GUI + Core；未重启当前运行 App。
- `git diff --check` 通过；本机 Trivy secret scan 无发现。

本机详细 wire、durable parts、telemetry、预测快照、修复前后日志：
`/Volumes/Development/Projects/benchmark-reports/pe-integrity-fix-20261004/`。

原 smoke 的 events.jsonl SHA256 仍为：
`c30cb721379b8e16ef4189c4edf29aecdcf3a6e687336c6e85bffc0caf588826`。

重新跑相同 workload 才能评价修复后模型表现；原 smoke 保持主人此前要求的暂停状态。
