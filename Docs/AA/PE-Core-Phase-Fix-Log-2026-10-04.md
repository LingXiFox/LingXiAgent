# P/E-Core 修复执行记录

- 基线：HEAD `4914c1b`
- 依据：`Docs/AA/PE-Core-ToolLoop-Audit-2026-10-04.md`
- 执行方式：按 Phase 顺序，每 Phase 先让测试复现 → 确认修复前失败 → 改生产代码 → focused tests → 相关回归 → 记录前后数据
- 未触碰：frozen eviction scoring、Branch Prediction steering（保持 observation-only）、provider wire 协议形状、GUI 布局、工具 schema、benchmark expectation

---

## Phase 1 — 统一 Tool Artifact Truth / Identity

### STATUS

`COMPLETE`

```
AUTHORITATIVE_TOOL_ARTIFACT_IDENTITY      = PASS
MODEL_FACING_REF_POINTS_TO_FULL_PAYLOAD   = PASS
NO_DUPLICATE_RECALL_TRUTH                 = PASS
```

Gate 测试：`Tests/LingXiAgentTests/ToolArtifactTruthTests.swift`
（真实 shell → ToolOutputPolicy → ToolOutputArchive → SessionStore → E-Core → page-out → ref → recall → 断言；全程无手工 `ToolResult(content:)`）

### ROOT CAUSE

同一个 ToolResult 的"召回真值"由四条互不相干的路径各自决定，最强的一份反而没有任何模型入口：

| 路径 | 产物 | 身份 | 有无 ref |
|---|---|---|---|
| ToolOutputArchive | 完整 raw | SQLite blob key | — |
| SessionRuntime sidecar | 完整 raw（≥32,768 才写） | `generate(tool,callID,content)` FNV | **无** |
| ContextProjection | bounded preview 的再拷贝 | `generate(tool,callID,preview)` | 有 |
| Compaction page-out | `"[Historical tool evidence]\n" + JSON(preview)` | `identify(envelope)` SHA256 | 有 |

模型看到的 ref 指向第 3/4 类，两者都是从 preview 二次导出的弱真值；唯一持有完整字节的路径（sidecar/archive）没有 occurrence-facing ref。加上 `store()` 与 `pageOut()` 用两套 ID 派生，同一 payload 落两个文件。

结果：`refs.first { objectID == identify(raw) }` 为 nil，recall 永远回不到完整载荷。

### ARCHITECTURE DECISION

**一个 occurrence 只有一个 payload 身份，由唯一权威函数决定，投影与 page-out 共用它。**

```swift
// ECoreObjectFabric（新增，唯一的真值定义）
authoritativeToolPayload(sessionID:toolCallID:toolName:content:artifactObjectID:) -> ContextObjectID?
```

规则：

1. `ToolOutputMetadata.artifactObjectID`（新增字段）= 完整 pre-truncation payload 的内容寻址身份，由 `ToolOutputArchive` 在真正存下 blob 时写入。它存在 ⟺ canonical `content` 只是 preview。
2. truncated → 身份就是 `artifactObjectID`，`ContextProjection` 与 `pageOut` 都只**绑定引用**，不再写第二份字节。
3. 从未 truncated → canonical 内容本身就是完整真值，身份为 `identify(toolArtifactRecord(result))`。
4. `toolArtifactRecord(result)` = `JSONEncoder(sortedKeys)` 序列化，保留结构化失败证据（code / exitCode / diagnostics），冻结测试 `structuredFailureSurvivesToolBatchArchive` 的语义不变。
5. sidecar 的入库条件从"preview 大小 ≥ objectizationThreshold"（对 ASCII 恒不成立、且按 preview 度量是循环论证）改为"存在 artifactObjectID"。
6. page-out 粒度从"每 batch 一份 envelope"改为"每 artifact 一份引用"；`contextOccurrenceID = "<batchID>#<callID>"`。`ContextUnitDebugSnapshot.derivedPageID` 只能放一个，因此新增 `occurrenceMessageIDs[session][refID] = Set<MessageID>` 保存反向映射。
7. `store()` 改用 `identify()`，消灭两套 ID。`legacyToolScoped` 保留用于解析改动前落盘的对象。

**Migration / compatibility boundary（明确）**

- 兼容读：`ECoreReference` 自带 `objectID`，旧 `.json` 引用继续按旧 ID 解析，`fetch` 按给定 ID 取文件 → 改动前落盘的对象与引用照常可读，无需数据迁移。
- 新写入：一律 `identify()`；`generate()` 在新路径中不再出现（仅 `legacyToolScoped` 与测试引用）。
- 遗留孤儿：改动前 sidecar 写的 `obj_<tool>_<call>_<fnv>` 对象无引用、不可达。本 Phase **未做**破坏性清理，列为待决项。

### FILES CHANGED

生产：

- `Sources/LingXiProtocol/ToolTypes.swift` — `ToolOutputMetadata.artifactObjectID: String?`（additive optional，Codable 走 `decodeIfPresent`，旧记录可读）
- `Sources/LingXiCore/Modules/Tool/ToolOutputArchive.swift` — 归档时计算内容寻址身份
- `Sources/LingXiCore/Modules/Model/ModelDomain.swift` — `projectToolResult` 重建 metadata 时不再丢失 `artifactObjectID`
- `Sources/LingXiCore/Modules/Context/ECoreObjectFabric.swift` — `store()` 内容寻址；`writePayload` 对 `.meta.json` first-writer-wins；`referenceForStoredObject` 支持 evictionEpoch / createdTurn / pageOutReason；新增 `authoritativeToolPayload` + `toolArtifactRecord`
- `Sources/LingXiCore/Modules/Session/SessionRuntime.swift` — sidecar 改为按身份入库并校验 blob 与 ID 一致
- `Sources/LingXiCore/Modules/Context/ContextProjection.swift` — 不再 store preview；引用绑定 authoritative payload；修正文件头那段"C 注释本身讲错了"的原则描述
- `Sources/LingXiCore/Modules/Context/ContextCompaction.swift` — `pageOutToolBatch`（每 artifact 一个引用）；`evictedReferences` 改 `[ECoreReference]`；`occurrenceMessageIDs`；`admitRequestedRecalls` 用反向映射

测试：

- 新增 `Tests/LingXiAgentTests/ToolArtifactTruthTests.swift`（Phase 1 gate）
- 改写 `Tests/LingXiAgentTests/ContextProjectionTests.swift`（`prune...` 的 kept/foreign 身份改为内容寻址——该测试写死了旧 ID 公式）
- 改写 `Tests/LingXiAgentTests/ECorePhysicalCensusTests.swift` 两条：该文件的原注释明确写着"两套 id 派生若被统一，这条断言就该随之改写而不是删掉"，本处照其指示改写为"一 payload 两独立引用"，并保留"去重不得合并生命周期"的断言；restart 基线 2 → 1

### BEFORE

`swift test --filter ToolArtifactTruthTests`（同一测试，修复前）：

```
✗ Expectation failed: refs.first { $0.objectID == artifactID } → nil
```

审计实机数据（51,090B shell 输出）：

```
raw                          = 51,090B
archive blob                 = 51,090B
durable ToolResult.content   = 16,384B (truncated=true)
E-Core objects               = 6 个 46,290–51,090B
E-Core references            = 0            ← 完整载荷无模型入口
model-facing ref → object    = 68,586B（evidence JSON，非 raw）
marker 可达偏移              = 57,344（envelope 内），raw 内真实偏移约 37,600
marker in Chat/Responses/Anthropic wire = false / false / false
```

### AFTER

Gate 测试连跑三次稳定通过（0.5s）。断言覆盖：

1. `preview.output.truncated == true`，`artifactObjectID == identify(raw)`
2. `∃ ref.objectID == artifactID` 且 `restore(ref).utf8.count == raw.utf8.count`
3. `recall(ref.objectID, offset = marker 在 raw 中的真实字节偏移)` 返回含 marker 的 slice
4. `hasObject(generate(tool, callID, preview)) == false` 且无引用指向 preview 派生对象
5. E-Core 中同字节数的对象恰好 1 个
6. canonical 历史未被改写（durable preview 仍是原对象）

Phase 1 后的实机数据（probe01，6 次真 shell 调用）：

```
raw                          = 60,690B
durable ToolResult.content   = 16,384B (truncated=true)
E-Core objects               = 6 个，字节数逐一对应各自 raw（60,690 / 55,890…）
                               → 一 artifact 一对象，无 preview 二次对象
```

### 相关回归

绿：`PEContextIntegrityTests`、`PERecallContractTests`、`ContextProjectionTests`、`ECoreObjectFabricTests`、`ECoreHeatPhase0Tests`、`ECoreRecallDiscoveryTests`、`ECorePhysicalCensusTests`、`SecondaryMemoryHygieneTests`、`PECoreRealWorldValidationTests`

全量 `swift test` 中与本 Phase 无关的隔离复验：`UXAndStreamingFixesTests` / `ProviderRateSchedulerTests` / `TUIRenderingTests` / `CancellationRaceTests` 单独运行全绿（全量并发下的计时抖动）。

仍然红（本 Phase 未触碰，属后续 Phase）：

- `ToolLoopRecoveryTests` 3 条 → Phase 6
- `ContextCompactionTests.eightStepToolLoop...` → **已验证为 HEAD 既有失败**，数字完全相同（`estimated 4948, hardLimit 4552, mandatory 4948`），非本 Phase 引入

### REMAINING RISKS

1. **入库量上升**：sidecar 现在为每个 truncated 结果写一个 E-Core 对象（此前 ≥32,768B 才写）。SQLite archive blob 与 E-Core payload 存在同字节双份。若要消重，需要让 E-Core object 直接以 archive blob 为后端，属独立设计决策。
2. **遗留孤儿对象**：改动前 `generate` 命名的无引用 sidecar 对象仍在磁盘上，普查会计入。未做破坏性清理，等主人决定（可用"无引用即回收"的一次性 sweep，需先备份）。
3. **同 batch 多引用**：`derivedPageID` 只保存主引用，完整映射在内存 `occurrenceMessageIDs`。跨进程恢复目前依赖 `derivedPageID` 回退——多 artifact batch 的第 2+ 个引用在重启后无法反查所属 unit。**这正是 Phase 3 的持久化范围**。
4. `eightStepToolLoop` 的预算前置失败虽与本轮无关，但它会让 P/E 相关的 loop 级测试在此机器上不可判定，建议单独处理。

---

## 基线失败清单（在 `4914c1b` 上实测取得，之后每个 Phase 都与此比对）

PRE_EXISTING_BASELINE_FAILURES：

```
ToolLoopRecoveryTests.successfulSiblingCannotHideRepeatedFailure
ToolLoopRecoveryTests.successfulNoOpCannotEraseUnresolvedFailure
ToolLoopRecoveryTests.realNoOpRewriteCannotMaskRepeatedTestFailure
ContextCompactionTests.eightStepToolLoopPagesHistoricalBatchesWithoutBreakingLiveProtocol
    estimated 4948, hardLimit 4552, mandatory 4948
FullCoreStackV1Tests.fullCoreStackV1
    CassetteMismatch: unbound run candidate count=0 roles=[] step=1 difference=$.body.input.count
ProviderHTTPTests.responsesStatelessRoundTripRestoresOpaqueReasoningAndExternalCallID
    isolation 下亦红（input 缺少 type=="reasoning"）
```

全量并发下的负载抖动（单独运行均绿，不计入回归）：
`PlatformHTTPServer` / `UXAndStreamingFixesTests` / `CancellationRaceTests` /
`ProviderRateSchedulerTests` / `TUIRenderingTests`

取得方式：`git stash` 暂存本轮改动 → `git checkout 4914c1b -- Sources Tests` → 全量跑 → 恢复。
因此 `eightStepToolLoop` 与 `fullCoreStackV1` 不是 Phase 1/2 的回归。

---

## Phase 2 — 拆分 Recall Slice 与 Occurrence Admission

### STATUS

`COMPLETE`（Case 4 的 live-turn 预算受策略上限约束，见 REMAINING RISKS 与 ARCHITECTURE DECISION）

```
RECALL_REQUEST_RANGE_PRESERVED                    = PASS
RECALL_SLICE_HONOURS_REQUESTED_LIMIT              = PASS
RECALL_SLICE_NOT_GENERICALLY_RETRUNCATED          = PASS
RECALL_SLICE_ONLY_DOES_NOT_ADMIT_OCCURRENCE       = PASS
RECALL_OCCURRENCE_USES_AUTHORITATIVE_PAYLOAD      = PASS
NO_SLICE_OCCURRENCE_DUPLICATION                   = PASS
RECALL_BYTE_RANGE_HEADER_ACCURATE                 = PASS
RECALLED_OCCURRENCE_SEGMENT_PRESERVED             = PASS
```

Gate 测试：`Tests/LingXiAgentTests/RecallSemanticsTests.swift`（4 条）

### ROOT CAUSE

1. `context_recall` 的 slice 是普通 tool 输出，出 `ToolRuntime` 前再过一次通用 `ToolOutputPolicy`（16,384 chars / 400 lines），把 header 之后的 payload 尾巴吃掉 → 模型收到的字节比 header 声称的少 168 字节。
2. `queueRecallAdmission(sessionID:referenceID:)` 的存储类型是 `[SessionID: [String]]`，offset / limit_bytes / limit_lines 在调用后立即丢弃 → 下一步只能按"整个 occurrence"处理。
3. 于是任何一次 range 读都会被隐式升级成 whole-occurrence admission，预算检查用的是 `retained + 整个 occurrence`，与模型实际请求的 8 KB 无关 → 错误的 `inputBudgetExceeded`。
4. 即使通过，slice 与 occurrence 会同时进入同一请求，同一证据两份。

补充事实（本狐原先归因不完整）：`recall()` 自身也以 `configuration.recallMaxBytes = 16_384` 为上限，所以 32,768 的请求本来就只能拿到 16,384 payload —— 这不是 bug，但通用 policy 再削一次让 header 变成谎报，这是 bug。

### ARCHITECTURE DECISION

1. **`RecallRequest` 成为一等值类型**（`ECoreObjectFabric.swift`）：`referenceID / offsetBytes / limitBytes / limitLines / admissionMode`；`RecallAdmissionMode ∈ sliceOnly | occurrenceProjection | occurrenceInline`。
2. **默认 `sliceOnly`**：带 range 或裸 id 的 `context_recall` 只授予该 range，完全不排队 admission。恢复 occurrence 必须显式表达：新增可选参数 `admission: "occurrence" | "inline"`（默认 sliceOnly）。这不是扩大 schema 能力面，而是把原本"隐式发生、无法表达"的两种语义拆开。
3. **recall 专用 output contract**：`ToolExecutor.outputContract(for:)`（默认 nil = 沿用通用 policy）。`ContextRecallTool` 按自身 `recallMaxBytes / recallMaxLines` 声明边界，header 单独计入允许量，因此 payload range 不再被偷偷削减。`ToolOutputPolicy` 未删除、通用值未提高。
4. **header 与送达一致**：`recall()` 现在先向内对齐 UTF-8 码点边界（起始丢弃 continuation 字节、末尾收缩到可解码），`lengthBytes` 由实际返回内容度量 → `Bytes: start - end` 恒等于模型收到的字节区间。
5. **occurrenceProjection 用 authoritative payload**：`admitRequestedRecalls` 不再无条件从 canonical entries 重建；当 occurrence 的 tool result 是 preview（`result.output.artifactObjectID == ref.objectID`）时，用 restore 出来的完整 payload 替换该 body。从未被截断的结果，canonical 内容本身就是完整真值，保持原样。
6. **不重复授予**：occurrence/inline 模式下工具返回 `[Context Object Occurrence: ref]` 回执而不带 payload；`RecallOutput.isBoundedTransport` 统一标识两种已预算的输出，`ModelToolResultProjection` 与 `ContextProjection` 共用该判定。
7. 策略上限 `policy.pCoreHardLimit` 会夹住 `hardInputLimit`，与模型窗口无关（实测 30k/40k/50k 窗口下 hard 恒为 22,532）。因此 Case 4 的 live-turn projection 会因 live P-Core 已顶到 hard 而被正确拒绝——拒绝本身是对的，但为了观察"projection 由什么构成"，该用例改用真实生产组件链（真实 page-out + 真实 ContextRecallTool + 真实 `admitRequestedRecalls` + 真实 `PCoreSnapshot.modelMessages()` + 真实三个 wire 编码器）并显式传入 `hardInputLimit`。Cases 1–3 仍是完整 live turn。

### FILES CHANGED

生产：

- `ToolOutputPolicy.swift` — 新增 `ToolOutputContract`、`RecallOutput` 标记；`excerpt` 行为未变
- `ToolRuntime.swift` — `ToolExecutor.outputContract(for:)`；成功路径按工具自声明边界裁剪（命令失败路径保持通用 policy，因其只会产生进程输出）
- `ToolOutputArchive.swift` / `ToolTypes.swift` — （Phase 1）
- `BuiltinTools.swift` — `admission` 参数、三模式分派、occurrence 回执、`outputContract` 覆写、slice 渲染提取为 `slice(of:reference:)`
- `ECoreObjectFabric.swift` — `RecallRequest` / `RecallAdmissionMode`；queue 由 `[String]` 改 `[RecallRequest]`（同 ref 后到覆盖先到）；新增非破坏式 `pendingRecallRequests(sessionID:)`；`recall()` UTF-8 边界对齐
- `ContextCompaction.swift` — `admitRequestedRecalls` 按模式分派 + preview→payload 升级 + synthetic 判定 + 已授予去重
- `ModelDomain.swift` / `ContextProjection.swift` — 白名单改用共享的 `RecallOutput.isBoundedTransport`
- `SessionRuntime.swift` — admission 消费者适配 `[RecallRequest]`

测试：

- 新增 `RecallSemanticsTests`（4 gate）
- 三条编码旧"隐式 occurrence 读回"语义的测试改为显式 `admission:"occurrence"`：`PERecallContractTests.recalledOccurrenceRemainsExactAcrossNextAssemblyAndProjection`、`PEContextIntegrityTests.residencySurvivesRestartAndOnlyExplicitRecallReadmits`、`PEContextIntegrityTests.recallBudgetRejectionIsExplicitAndDoesNotReadmitHistory`，以及 live replay provider 内的 `realPersistentSessionRuntimeReplaysPToERecallActiveFailure`。断言内容未弱化，只是把请求表达补全；`residencySurvivesRestartAndOnlyExplicitRecallReadmits` 现在才真正符合它自己的名字。

### BEFORE

```
requested limit_bytes = 32768
  durable slice bytes          = 16384   (rawToolOutputTotalBytes = 16552, truncated = true)
  header claims Bytes: 0 - 16384, payload actually delivered = 16216  → 168B 谎报
  offset/limit 在 queueRecallAdmission 后丢失（存储类型 [SessionID:[String]]）
requested offset=17000 limit_bytes=8192（模型只要 8KB）
  recallRejected: inputBudgetExceeded: required=17714, hard=16552
  （8KB slice ≈ 2.8K token，被拒的原因是整个 occurrence）
admission 成功时
  同一请求同时含 slice 7351B 与 occurrence 3328B → 同一证据两份
occurrence 重建来源
  canonical bounded preview（16384B），中间证据不可达
```

修复前四条 gate 的红（实测）：

```
✗ output.truncated == true                     （应 false）
✗ payload.utf8 16216 != header 16384           （header 谎报）
✗ budgetRejections == [inputBudgetExceeded required=17714, hard=16552]
✗ recallAdmitted == 0 / sliceEntries == []
（第四条 rangedSliceStaysSliceOnly 因预算拒绝而"意外绿"，本狐加强为：sliceOnly 连 rejection 都不许出现）
```

### AFTER

```
Case 1  requested 32768 → payload 16384（= recallMaxBytes 上限，未被削减），
        truncated=false，header 区间与实际送达逐字节相等，"Has More" 行完整存活
        probe10 复核：durableSliceBytes == rawToolOutputTotalBytes == 7349，truncated=false
Case 2  offset=17000/limit=8192 → recallAdmitted=0 且完全没有 recallRejected 事件
        （= 根本没有排队 occurrence admission），slice 在请求中恰好一次
Case 3  8KB slice 落在预算内并送达中间 marker，无 inputBudgetExceeded
Case 4  ack 不含 payload；projection 含 middle marker 且字节数 ≥ payload；
        .recalledOccurrence segment 存活至 ContextEntry → PCoreSnapshot →
        ModelMessage → 三个 provider wire；durable session 逐字节未变
```

schema 成本实测：新增 `admission` 参数使 `toolSchemaTokens` 上升，`eightStepToolLoop` 夹具的 `hardInputLimit` 从 4552 → 4532（约 20 token）。未删除该参数（三种 admission 必须可表达），如实记录。

### REMAINING RISKS

1. live turn 内的 occurrenceProjection 在 P-Core 已顶到 `hardInputLimit` 时会被正确拒绝。要观察到"授予成功"的 live 场景，需要 admission 前先给 P-Core 让出余量（Phase 7 的 bounded retrieval / 或 admission 独立预算），本狐没有在 Phase 2 里改 budget 策略。
2. `pendingRecallRequests` 仍是内存态，`takeRecallAdmissions` 仍先删后处理 → Phase 3。
3. `recallMaxBytes` 默认仍为 16,384：单请求最大 payload 未提高（符合"不许靠提高预算绕过"），更宽的证据需靠 range 分页取得；Phase 8 的分页回归要覆盖。
4. `admission` 参数使 context_recall 的 schema 变宽，属于模型可见接口变化，需要在 Agent 文档/教学里说明"默认只取 range"。本轮按要求未改 Agent prompt。

---

## Phase 3 — Recall Durability

### STATUS

`COMPLETE`

```
RECALL_REQUEST_DURABLE                          = PASS
RECALL_REQUEST_MODE_SURVIVES_RESTART            = PASS
RECALL_ADMISSION_ATOMIC                         = PASS
RECALL_COMMITTED_RESIDENCY_SURVIVES_RESTART     = PASS
RECALL_PAYLOAD_RECONSTRUCTS_AFTER_RESTART       = PASS
MULTI_ARTIFACT_OCCURRENCE_MAPPING_DURABLE       = PASS
NO_HALF_COMMITTED_RECALL_STATE                  = PASS
SLICE_ONLY_NOT_UPGRADED_AFTER_RESTART           = PASS
LIVE_RECALL_RESTART_MODEL_REQUEST               = PASS
```

顺带补上前一 Phase 记下的欠账：`LIVE_TURN_OCCURRENCE_PROJECTION_E2E` 现在 **PASS**（Case 3 为完整 live turn，未改任何 budget 策略）。

Gate 测试：`Tests/LingXiAgentTests/RecallDurabilityTests.swift`（5 条，真实 CoreHost + 真实 SQLite + 磁盘 E-Core + 真实 shutdown / 新 CoreHost 同 dataRoot）

### ROOT CAUSE

1. `pendingRecallRequests` 只在 `ECoreObjectStore` 内存字典里 → 工具成功、意图入队之后崩溃，请求永久消失（审计 probe11 实测）。
2. `takeRecallAdmissions` 先 `removeValue` 再非事务处理 → 消费与提交不是一个边界。
3. `admittedPayloads` 只在内存，且不落盘；`restoreResidencies` 只在 `messageID == refID` 时重建，canonical 型授予无法复现（probe12 实测 `1 → 0`）。
4. Phase 1 的 `occurrenceMessageIDs` 是内存态，`derivedPageID` 只容主引用 → 多 artifact batch 的第 2+ 个引用重启后查不回所属 unit。
5. telemetry（`recallAdmitted` 等）是内存计数，重启即归零，被误当状态使用会产生假象。

### ARCHITECTURE DECISION

1. **状态机**：`requested → admissionPrepared → admissionCommitted`，或终态 `rejected(reason)`。`RecallRequest` 新增 `state` / `reason`；"工具成功"与"assembly 已提交"从此是两个不同事实。
2. **控制面落 SQLite（schema v8）**：`recall_requests`（含 range、mode、state、reason）与 `recall_occurrences`（ref → messageIDs）。**payload 一个字节都不复制进 SQLite**；重启后仍走 reference → authoritative objectID → E-Core 字节。
3. **取消破坏式 take**：`recallQueue(sessionID:)` 以表为权威读取（无 persistence 时退回内存，保持 in-memory E-Core 语义）；推进状态用 `markRecallRequest`；只有 `admissionPrepared`/`requested` 会被再处理，`admissionCommitted` 不重复授予。
4. **一个事务即提交边界**：`commitRecallAdmissions` 在单个 `BEGIN IMMEDIATE` 里写 residency + occurrence 映射 + 请求状态。新增 failpoint `.beforeRecallCommit` 用于真实注入崩溃；Case 2 证明事务失败时内存 residency 也不动、模型请求里不出现未提交的授予。
5. **映射在 page-out 时就持久化**（不是等到 commit）：引用属于哪个 causal unit 是建立引用那一刻的事实。`reconcileAfterRevert` 会裁掉失效引用，`deleteSession` / `compactor.reset` 一并清表，不留孤儿行。
6. **`admittedPayloads` 定位为可重建投影**：`restoreRecallState` 用 committed 行 + `ecoreStore.restore` 重建；canonical 型授予则由 durable residency + 映射在 `activeEntries` 里重建，并用内容寻址 payload 把 preview 升级回完整载荷（`grantedPayloads` 只做只读缓存，payload 不可变所以缓存无失效问题）。
7. **sliceOnly 永不升级为授予**：工具不再为 range 读排队；万一有 sliceOnly 行到达 assembly，也只是丢弃而不是转换成授予（Case 5 覆盖重启后同样不出现）。
8. turn 在授予前终止时，请求以 `rejected(turnTerminatedBeforeAdmission:…)` 落库，不静默消失。

### FILES CHANGED

生产：`SQLitePersistenceStore.swift`（schema v8 + 迁移阶梯 + `beforeRecallCommit` failpoint + recall 控制面 API + deleteSession 清理）、`MigrationRunner.swift`（V7→V8 步骤）、`ECoreObjectFabric.swift`（`RecallRequestState`、`RecallRequest.state/reason`、`attachRecallPersistence`、`recallQueue` / `markRecallRequest` / `forgetRecallRequest`，删除 `takeRecallAdmissions`）、`ContextCompaction.swift`（状态机化的 `admitRequestedRecalls`、`restoreRecallState`、page-out 时持久化映射、`activeEntries` 的 payload 升级、revert/reset 清理）、`BuiltinTools.swift`（sliceOnly 不排队）、`SessionRuntime.swift`（拒绝落库；适配新队列）、`CoreHost.swift` / `AgentRuntime.swift`（attach persistence、启动时恢复 recall 状态）

测试：新增 `RecallDurabilityTests`（5 条真实重启）

### BEFORE（审计实机测量，即修复前行为）

```
probe11 工具成功并入队（drainedQueueCount=1，slice 8,359B）
        → 崩溃 → 新 CoreHost：refs=10 admitted=0 occurrenceVisibleAfterRestart=false   ← 意图丢失
probe12 admittedNowEntries=1 (.recalledOccurrence, 2,053B)
        → 换一个新 compactor 指向同一目录：afterCrashEntries=0 hasPayload=false        ← 授予不可重建
Phase 1 记录：occurrenceMessageIDs 内存态 → 多 artifact batch 第 2+ 引用重启后无法反查
```

### AFTER

```
Case 1 真实工具排队 occurrence 请求 → 立即 shutdown → 新 CoreHost
       recallQueue 仍含该请求且 admissionMode == .occurrenceProjection
       后续 live turn 把它推进到记录型终态（committed 或带 reason 的 rejected）
Case 2 armFailpoint(.beforeRecallCommit) → 提交抛错
       residency 与提交前逐条相等；请求停在 admissionPrepared；模型请求里无 .recalledOccurrence
       重启后同一请求被重新处理并落到终态
Case 3 committed 授予 → 真实 shutdown → 新 CoreHost → live turn
       next ModelRequest 含 .recalledOccurrence 且携带 preview 之外的中间 marker；
       Chat / Responses / Anthropic 三份真实 wire 均含该 marker
Case 4 一个 batch 内两个被截断 artifact → 两个引用
       recall_occurrences 各存自己的 message 集合；重启后逐引用与重启前完全相等
Case 5 纯 range 读 → 队列中无 committed 行、无 .recalledOccurrence；重启后依旧不被升级
```

全量 `swift test`：新增失败 **0**。仍失败的仅为基线清单内条目（`ToolLoopRecoveryTests` ×3、`eightStepToolLoop`、`fullCoreStackV1`，以及 `ProviderHTTPTests.responsesStatelessRoundTrip…` 与并发负载抖动）。

### REMAINING RISKS

1. **live 授予只在"刚好被截断"的 artifact 上成立**。预算比例冻结不动时 `hardInputLimit − lowWater ≈ 0.33 × hard`，而一个被截断的 payload 至少 16,385 字符 ≈ 5,462 token，加上 toolCall 条目后，51KB 级别的 occurrence 投影在 24K 窗口下**结构上放不进**（实测 required/hard 超出约 7%）。Case 3 用 16,4xx 字符的 artifact 与 `read_file`（不被 coding 投影压缩，因而主导淘汰顺序）建立真实授予。真正的解法属于 Phase 7：admission 需要自己的预算额度或"能放多少放多少"的投影策略，而不是全有或全无。
2. `grantedPayloads` 是只读缓存，进程内不淘汰；单会话授予很多时占内存。属可接受的观测型缓存，Phase 7 若做 bounded retrieval 再一并处理。
3. `recall_requests` 的 committed 行是长期记录，随会话累积；`deleteSession` / `reset` / revert 已清理，但尚未做"引用已消失即回收行"的惰性收缩。
4. telemetry 计数器仍不持久（有意如此）：真实状态只看控制面，重启后 `recallAdmitted` 归零不代表授予丢失。

---

## Phase 4 — Provider Privilege Parity

### STATUS

`COMPLETE`

```
RETRIEVED_DATA_UNPRIVILEGED_CHAT              = PASS
RETRIEVED_DATA_UNPRIVILEGED_RESPONSES         = PASS
RETRIEVED_DATA_UNPRIVILEGED_ANTHROPIC         = PASS
RECALLED_DATA_UNPRIVILEGED_CHAT               = PASS
RECALLED_DATA_UNPRIVILEGED_ANTHROPIC          = PASS
IMMUTABLE_INSTRUCTIONS_REMAIN_PRIVILEGED      = PASS
PROVIDER_PRIVILEGE_PARITY                     = PASS
RETRIEVAL_PROMPT_INJECTION_IS_DATA            = PASS
STABLE_PREFIX_NOT_CONTAMINATED_BY_RECALL      = PASS
```

Gate 测试：`Tests/LingXiAgentTests/ProviderPrivilegeTests.swift`（权限矩阵 + 两条真实生产路径）

### ROOT CAUSE

特权判定来自**内部 role** 而不是**语义 segment**：装配为了表达 synthetic context 一律用 `role = .system`，三个 adapter 又各自把这个 role 当权限读。

- Chat：`case .system → Message(role: "system")`，完全不看 segment。
- Anthropic（最严重）：top-level `system` = immutableBase **拼进所有** `role == .system` 消息内容，同时在 messages 循环里把 system 丢弃 → E-Core 索引行、引用行、召回载荷全部进入唯一特权指令通道。
- Responses：方向正确但判定条件错（`segment == .conversation || .immutableInstructions → developer`，即 `.conversation` 的 system 内容也会拿特权）。

实机证据（修复前，真实 live session）：`anthropic.system` 中含 `[E-Core index]` 与 `reference=ref_…`。

### ARCHITECTURE DECISION

`ModelContextSegment` 成为唯一权限判据，新增两个语义属性：

```swift
extension ModelContextSegment {
    public var carriesPrivilegedInstructions: Bool   // 仅 .immutableInstructions
    public var isUntrustedRetrievedData: Bool        // retrievalData / eCoreRetrievalProjection / recalledOccurrence
}
```

三家映射（表示不同、权限级别相同）：

| segment | Chat | Responses | Anthropic |
|---|---|---|---|
| immutableInstructions | `messages[].role=system` | `instructions`（developer） | top-level `system` |
| retrievalData / eCoreRetrievalProjection / recalledOccurrence | `role=user` | `input[].role=user` | `messages[]` user content block |
| conversation | user/assistant | 同名 | 同名 |
| admittedToolResult | `role=tool` | `function_call_output` | user 内 `tool_result` block |

要点：
1. 内容**没有被删除**，只是换通道 —— Anthropic 原本对 system 角色是 `return nil`（等于丢弃），现在改为落到 messages。
2. `request.system` / `cachePlan.immutableBase.systemPrompt`（Agent 自身指令、goal anchor、后台通知等 `source == .system && messageID == nil` 条目）仍是 privileged，未被降级。
3. 连续同角色 turn 的合法性已查证官方文档（Anthropic：consecutive user/assistant turns are combined into a single turn），不需要额外合并逻辑。
4. Cache 侧只做观测：`privilegedChannels(before) == privilegedChannels(after)`，且特权前缀不含索引/引用/召回内容。cache 策略与 `stablePrefixHash` 计算未改。

### FILES CHANGED

- `Sources/LingXiCore/Modules/Model/ModelDomain.swift`（segment 权限语义）
- `Sources/LingXiCore/Modules/Model/OpenAICompatibleProvider.swift`
- `Sources/LingXiCore/Modules/Model/OpenAIResponsesProvider.swift`
- `Sources/LingXiCore/Modules/Model/AnthropicMessagesProvider.swift`
- 文档：`Docs/AA/PE-Core-Context-Integrity-2026-10-04.md` 的 provider parity 段落改为描述 semantic privilege，并修正原文对 Responses 的错误描述（原文写"retrieval → developer input"，与代码 `user` 不符；现按 segment 语义重写）
- 新增测试：`ProviderPrivilegeTests`

### BEFORE → AFTER（同一探针，三家真实 body）

```
BEFORE（矩阵，cachePlan true/false 同样）
  retrievalData            Chat=chat.message[system]  Responses=data.user  Anthropic=anthropic.system
  eCoreRetrievalProjection Chat=chat.message[system]  Responses=data.user  Anthropic=anthropic.system
  recalledOccurrence       Chat=chat.message[system]  Responses=data.user  Anthropic=anthropic.system
  immutableInstructions    Chat=chat.message[system]                       ← 唯一应得特权者，与其他无法区分
  矩阵 12 项失败；live 路径 anthropic.system 内含 "[E-Core index]" / "reference=ref_…"

AFTER
  retrievalData / eCoreRetrievalProjection / recalledOccurrence
      Chat=data.user  Responses=data.user  Anthropic=data.user             ← 三家同权限级别
  immutableInstructions  Chat=chat.message[system]、Responses=instructions、Anthropic top-level system ← 仍特权
  live 注入（IGNORE PREVIOUS INSTRUCTIONS / SYSTEM OVERRIDE TEST MARKER，位于 preview 之后，
  只能由显式 occurrence 召回带入）：
      Chat=data.tool   Responses=data.function_call_output   Anthropic=data.user
      marker exists = true，privileged = false（三×二=6 项断言全绿）
  特权前缀 before == after，且不含索引/引用/召回内容
```

真实生产路径覆盖：`read_file` 大文件 → ToolOutputPolicy 截断 → authoritative artifact → page-out → 显式 `admission:"occurrence"` → Context Assembly → ModelMessage → 三家 request body。非全部手工 `new ModelMessage`（矩阵那条是 adapter 映射测试，注入与 prefix 两条走真实链路）。

### REMAINING RISKS

1. 召回内容现在会作为 `user` turn 出现在 Chat/Anthropic 的对话流里。Anthropic 服务端会把连续 user turn 合并为同一 turn —— 权限正确，但**同一 turn 内的相邻顺序**由合并后的 block 顺序保持，若将来需要在 UI 区分"用户原话 vs 检索数据"，应看 segment 而不是 role。
2. `chat.leadSystem` / `responses.instructions` 的 stable prefix 观测目前依赖 `immutableBase.systemPrompt`；Phase 7 的 providerVisible / telemetry 工作若改动缓存计划装配，需要保持本 Phase 的断言（已经把它固化进 `ProviderPrivilegeTests`）。
3. 本次未触碰 GUI 与 TUI 的 role 展示逻辑（它们读的是应用投影，不是 provider role），因此聊天界面里 retrieved data 的显示归类仍按旧假设——如主人在 GUI 上看到"检索数据显示为用户消息"，那是本 Phase 的预期结果，不是新 bug。

---

## Phase 5 — Read Consistency

### STATUS

DONE. 11 个 Phase 5 门（新增 `Tests/LingXiAgentTests/ReadConsistencyTests.swift`）先红后绿；全量套件的失败集合与记录的基线失败集合一致，未新增失败。

红灯基线（实现生产代码之前，真实 `CoreHost` + 真实 workspace 实测）：

```
Case 2 read/write_file/read   counts(a.txt)=1（第二次 read 从未执行）
                              r2.metadata["sharedRead"]="true"
                              r2.content 含 OLDVALUE、不含 NEWVALUE
Case 3 read/shell/read        同上，counts=1，r2 仍是旧字节
Case 6 持久化与下一轮 wire     SessionStore 里 r2 的记录 = 旧内容（陈旧读被当成当前文件写进了历史）
Case 7 read 的 stamp          read.content 无任何 version/hash；write_file(expected_hash) 从未被受理
Case 8 乐观并发               write-1 因缺少可引用的 stamp 直接被 guard 拒绝（contentChanged），
                              正常 read→改→write 路径在 production 上不可表达
```

### ROOT CAUSE

`SessionRuntime` 的 batch 调度把"同一批次内签名相同的只读调用"当作可复用结果，但复用范围与并发范围都没有 resource 概念：

1. `primaryBySignature` 只按 `{toolName, canonicalArguments, resource}` 匹配，键里没有"这个 resource 在本批次里是否已被改动"。于是 `read a / write a / read a` 的第三次调用被判定为"已有 primary"，**根本不执行**，直接拷贝第一次的结果并写进 SessionStore。
2. 所有 primary（读与写混在一起）在同一个 `withTaskGroup` 里并发派发，即使不去重，`read a` 与 `write a` 的先后也是竞态：模型要求的因果顺序无法保证。
3. 整文件 `read_file` 返回 `readText` 的裸文本，不带任何 revision；而 `write_file`/`edit_file` 的 stale guard 要求 `expected_hash`（sha256，模型算不出）或 `expected_version`（`stat:bytes:mtime`，模型看不到）。分页 read 早已返回 `version`，整文件 read 却没有 —— 于是 guard 在真实工作流里只剩"拒绝"，正常读改写路径不可表达。

### ARCHITECTURE DECISION

**read-sharing epoch（波次），而不是给 signature 加 hash/mtime。**

新增 `ToolRuntime.batchEffect(for:)` 把每个调用归类为四种效果之一：

| effect | 判定依据 | 语义 |
|---|---|---|
| `.readOnly(resource)` | `capability.readOnly` 且 `resource(for:)` 可解析且非空 | 读某个 workspace 资源，可共享，直到该资源被改动 |
| `.mutation(targets)` | capabilities 含写类且实现 `FileMutationTargetProviding`（write/edit/apply_patch，含 move 两端） | 已知精确写入目标 |
| `.opaqueMutation` | 有写类能力但 Core 说不出目标（shell、git、format、background…） | 不透明改动，**整个 batch 的 read epoch 失效** |
| `.neutral` | 非只读非写；或只读但无可寻址 resource（`context_recall` 读的是内容寻址且不可变的 E-Core payload） | 与读的真实性无关 |

`SessionRuntime.readSharingWaves(for:)`（纯函数、`nonisolated static`）据此把 batch 切成波次：同一波内可证明无序依赖 → 并发；波与波之间按模型自己的顺序串行。规则：

* 读 R：晚于任何写 R、任何写 `R/…`（目录读覆盖其下所有文件）、以及任何不透明改动；
* 写 T：晚于任何读 T、任何读 `T` 的祖先目录、以及任何早先写 T；
* 共享判定键改为 `{signature, wave}` —— 同签名不同波 → 不复用 → 真实执行。

不透明改动取 `highest + 1`，即"整批前置调用都先做完"，符合主人给的第三档兜底：**宁可少 dedup 一次，也不能持久化 stale read**。未引入 `expected_read` 之类新 schema 字段、未引入会话读台账、未放宽 guard、未动 signature 结构。

stamp 采用**首行方括号头**而非 JSON 信封或尾注：read_file 的 body 仍是逐字节的文件内容（Phase 1 的 raw-output-as-payload 原则不变），头是工具自己的输出格式，与本仓 `[Context Object Slice:` 的既有先例一致；`sha256` 只在整文件读给出，分页读仍只给 `version`（一页没见过整个文件，不能声称知道全文件哈希）。

### FILES CHANGED

生产：
* `Sources/LingXiCore/Modules/Tool/ToolRuntime.swift` — 新增 `ToolBatchEffect` 与 `batchEffect(for:)`
* `Sources/LingXiCore/Modules/Session/SessionRuntime.swift` — 波次计算 `readSharingWaves(for:)`、`primaryByEpoch`（signature→wave→primary）、按波串行派发与次级发布、波间取消检查
* `Sources/LingXiCore/Modules/Tool/BuiltinTools.swift` — 整文件 `read_file` 前置一行 stamp（path / bytes / sha256 / version）

测试：
* `Tests/LingXiAgentTests/ReadConsistencyTests.swift`（新增，11 门）
* `Tests/LingXiAgentTests/AgentSessionTests.swift` — 共享 `readFileBody(_:)`（read 结果 = stamp 行 + 文件字节，测试断言字节）
* 契约同步：`ToolRuntimeTests`（3 处）、`SensitivePathPolicyTests`（1 处）、`AgentToolLoopTests`（2 处）、`PERecallContractTests`（1 处）由 `content == "<file text>"` 改为 `readFileBody(content) == "<file text>"`。这些断言原样编码了"read 输出逐字节等于文件内容"的旧契约，属本 Phase 有意变更，不是被绕过的失败。

### REGRESSION TESTS

全部走真实 production path：真实 `CoreHost` + `SessionRuntime` 批调度 + 真实 builtin 工具 + 真实 SQLite 会话记录；执行次数由包在 `ReadFileTool` 外面的计数器实测（不从 `sharedRead` 字段反推"是否真执行"）。

| Gate | 测试 |
|---|---|
| READ_DEDUP_WITHOUT_MUTATION | identical reads in one batch share a single execution |
| READ_INVALIDATED_BY_FILE_MUTATION | a read after write_file of the same file really re-executes and returns the new bytes |
| READ_INVALIDATED_BY_SHELL_MUTATION | a read after a shell command that rewrote the file really re-executes |
| RESOURCE_UNRELATED_MUTATION_DOES_NOT_OVERINVALIDATE | a mutation of an unrelated file does not force a repeat read to run again |
| （同类，目录） | a directory listing is not shared across a write into that directory |
| NO_STALE_READ_PERSISTENCE | neither the durable record nor the next provider request carries a stale read |
| READ_AFTER_MUTATION_RETURNS_DISK_TRUTH | 上述三条同时断言磁盘内容 / 每个 ToolResult.content / 执行次数 / sharedRead / SessionStore 记录 |
| READ_FILE_EXPOSES_WRITE_VERSION | read_file's stamp is accepted by write_file as expected_hash；read_file's version token is accepted by edit_file as expected_version（并断言 stamp 经 Context Assembly 后仍是原哈希） |
| READ_MODIFY_WRITE_OPTIMISTIC_CONCURRENCY | a stamp that no longer matches is still refused, and a rejected write leaves the disk alone |
| 规则表 | read sharing follows the resource, not the tool name（8 条波次真值表） |

### BEFORE → AFTER

```
AFTER（同一批 read/write/read）
  counts(a.txt) = 2      r1 见 OLDVALUE，w1 写 NEWVALUE，r2 见 NEWVALUE
  r2.sharedRead = nil    磁盘 = NEWVALUE，SessionStore = NEWVALUE，下一轮 wire = NEWVALUE
AFTER（read/shell/read）  counts = 2，r2 = NEWVALUE（不透明改动关闭整批 read epoch）
AFTER（read a / write b / read a） counts = 1，仍共享，第二次仍标 sharedRead="true"
AFTER（list . / write c.txt / list .） 第二次 listing 含 c.txt，独立执行
AFTER（stamp 路径） read 首行 sha256 = 文件真实哈希（经 assembly 不变），write_file(expected_hash) 受理；
              同一 stamp 再次写 → contentChanged 拒绝且磁盘不动
波次成本：[read a, write a, read a] 由 1 波并发改为 3 波串行；[read a, write b, read a] 仍 1 波
```

### REMAINING RISKS

1. **不透明改动的保守代价**：batch 内只要出现 shell/git/format 等写类不透明调用，其后所有读都被推迟到独立波次执行。若模型习惯在一个 step 里"shell + 若干 read"，这一 step 会串行化。这是选择而非缺陷；将来若要收敛，正确路径是把 `shellPaths` 解析出的目标提升为可信 targets（并在误分类时回退到 opaque），而不是削弱 invalidation。
2. **`run_background_command` 的延迟改动**：后台命令在批次之后才落盘，波次只看 batch 内的因果顺序，跨 step 的读会真实执行（已由 Case 5 钉住），但"上一个 step 起了后台写、下一个 step 的 read 仍可能读到写之前"这一竞态无法由调度器消除，属工具语义问题，留给 Phase 6 的 progress 判定（成功但无进展）一起看。
3. **stamp 进入 read 载荷**：`read_file` 的 artifact payload 现在是"stamp 行 + 文件字节"。ToolOutputPolicy 的 16,384 预览因此少约 110 字符正文；GUI/TUI 的行数统计会 +1（未改 UI 代码）。模型若把 stamp 行当作正文复制回 `write_file`，会产生一行污染 —— 这是本设计的已知取舍；替代方案（JSON 信封 / 会话读台账 / `expected_read` 新字段）都各有更大代价，已在 ARCHITECTURE DECISION 说明。
4. **`expected_version` 依赖 mtime+size**（沿用 `fileVersion` 既有语义，未改）：同尺寸、同时间戳的原子替换理论上可骗过 version，但骗不过 `expected_hash`；两者都由工具自己给出，Core 不额外担保。
5. 本 Phase 未触碰 eviction scoring、Recall、Provider privilege、ToolLoop progress、Branch Prediction、benchmark expectation；`readOnlySignature` 结构本身也未改（仍是 `{toolName, canonicalArguments, resource}`），波次是调度层的正交信息。

---

## Phase 6 — Tool Loop Progress Semantics

### STATUS

DONE with one recorded design conflict that needs the master's decision.

- HEAD 的三个基线红测全部转绿：`successfulSiblingCannotHideRepeatedFailure`、`successfulNoOpCannotEraseUnresolvedFailure`、`realNoOpRewriteCannotMaskRepeatedTestFailure`。
- 新增 `ToolLoopProgressSemanticsTests`（15 门，含两条真实 SessionRuntime replay）全绿。
- `ToolLoopRecoveryTests` 现在 12/12 绿：既有 10 条（`differentCommandsSameErrorDoNotStop`、`exactDuplicateStillStops`、`warningOnceThenBounded`、`threeStrategiesReachReport`、`identicalCommandStopsEndToEnd`、`usefulWorkBeyond32StepsCompletes`、`blockedRepeatIsDuplicate`、`stepCeilingHolds` 等）+ 改写的 `progressResets` + 重命名的 B 测试。
- 与冻结原则冲突的旧测试 `recoveryBeyond32StepsReachesReport` 已由主人裁决按 **方案 B** 处理：重命名为 `changingFailureObservationsDoNotEvadeNoProgressStop` 并改为新语义断言（详见文末 RESOLUTION）。

全量套件失败集合 = 既有基线失败（`eightStepToolLoop`，失败签名仍是 `contextBudgetExceeded 5072/4532`，与 Phase 5 时测得一致；`fullCoreStackV1`、`ProviderHTTPTests.responsesStatelessRoundTrip…`）+ 负载抖动（`CancellationRace`、`ProviderRateScheduler`、`PlatformHTTPServer`、`TUIRendering`、`UXAndStreaming`、`StdioConnectionDeadline`、`VNextStdioTransportDeadline`，均已单独复验为绿）。未新增失败。

### ROOT CAUSE

tracker 以 **batch** 为判定单位，且把"本批有任意 succeeded"直接当作 progress：

```swift
let anySuccess = batch.contains(where: \.succeeded)
guard !failures.isEmpty, !anySuccess else { reset(...); return .progress(...) }   // 旧代码
```

于是 `失败 X → 成功 read → 失败 X → 写回相同字节成功 → 失败 X` 每两步就把 blocker 清零一次，永远数不满阈值；同一批里 `[失败 X, 成功 read]` 也因 `anySuccess` 被判为 progress。旧实现只保存一个 `lastFailure` 字符串，且要求"连续批次"才算重复——中间隔一个 neutral 批次就把计数打断。error 文本还直接参与比较，行号/随机路径变化会不断产生"新失败"。

### ARCHITECTURE DECISION

判定单位从 batch 换成 **blocker cluster**，输入信号全部机械化，不引入任何模型判断模型。

`Blocker`（按 fingerprint 保存，跨清除单调累计）：

```
fingerprint / firstSeenStep / lastSeenStep / repeats / strategies(Set<callKey>)
shapes(Set<normalized call>) / exactRepeats[callKey] / warned / batchesSinceWarning / open
```

- **fingerprint** = `tool family : exit code : 归一化消息`。归一化把 `/\S+`→`<path>`、12+ 位 hex→`<id>`、数字串→`#`、空白折叠；exit code 与 error code 保留（不同退出码/不同 error code 不得合成一个 blocker）。
- **shape**（objective identity）= `tool : 参数去数字`，**保留路径**。这样 `g++ app1.cpp` 与 `g++ app2.cpp` 是同一目标，而 `read a.txt` 永远不是 `read b.txt` 的尝试，也不可能被误认成一次构建通过。
- **evidence** 由结果事实决定，与工具名无关（`ToolLoopProgressTracker.evidence(toolName:success:mutatedPaths:exitCode:)`）：`read`/`shell` 成功但无文件改动 → `.none`；`write_file` 写回相同字节（`fileMutations` 为空）→ `.none`；`fileMutations` 非空 → `.mutation`；`run_background_command` / `manage_background_command` 成功 → `.attestation`（只证明进程被启动）；失败调用 → `.none`。

允许清除 blocker 的信号只有两个：

1. **fail → pass**：同一 shape 的调用这次成功了。
2. **失败类别实质变化**：同一 shape 再次尝试且不再复现该 fingerprint，**并且** `lastMutationStep > blocker.lastSeenStep`（真实 workspace 改动作为辅助证据）。没有改动而只是换 exit code / 换参数，视为交替而非进展。

`workspace changed` 单独永远不算进展（Case 3）。neutral 批次不清 blocker、不加重失败，只消耗 grace。

停止条件（顺序）：exact duplicate（同 callKey + 同 fingerprint 第 `exactDuplicateLimit=3` 次出现）→ 提示后 grace（`clusterGraceAfterWarning=2`）内该 blocker **再次复现**→ hardStop。两处都要求"本批复现"，避免把一个不再出现的 blocker 在别的任务上掐死运行（`warnedBlockerWithoutRecurrenceDoesNotStop` 钉住这一点）。策略变化只增加 `strategies`，绝不重置 `repeats`；被清除的 blocker 再出现时带着历史计数回来，所以换参数无法无限延后 hardStop。

阈值沿用 3/3/2：`differentCommandsSameErrorDoNotStop`、`warningOnceThenBounded`（提示一次、第 6 批停止）、`exactDuplicateStillStops`、`threeStrategiesReachReport`、`stepCeilingHolds` 因此都不必改动。高 emergency `maxAgentLoopSteps` 原样保留，未作为主判定。

### FILES CHANGED

生产：
* `Sources/LingXiCore/Modules/Session/ToolLoopProgressTracker.swift` — 重写为 blocker cluster 语义；新增 `CallOutcome.exitCode/.evidence`、`Verdict.neutral`、`Blocker`、`evidence(toolName:success:mutatedPaths:exitCode:)`、`fingerprint(of:)`、`shape(of:)` 与折叠归一化
* `Sources/LingXiCore/Modules/Session/SessionRuntime.swift` — 喂给 tracker 的 `CallOutcome` 带上 `result.exitCode` 与由 `result.fileMutations` 推得的 evidence；`recordLoopVerdict` 处理 `.neutral`（不再为无信号批次写 trace）

测试：
* `Tests/LingXiAgentTests/ToolLoopProgressSemanticsTests.swift`（新增，15 门）
* `Tests/LingXiAgentTests/ToolLoopRecoveryTests.swift` — `progressResets` 按新语义重写（其前半段正是本 Phase 推翻的旧规则）；`failed(...)` 增加 `exit:` 参数
* `Tests/LingXiAgentTests/ToolLoopRecoveryTests.swift:252` `recoveryBeyond32StepsReachesReport` — **未改动，现为红**，见下

### REGRESSION TESTS（gate → 测试）

| Gate | 测试 |
|---|---|
| HEAD_EXISTING_LOOP_TESTS | 3 条基线红测转绿；`ToolLoopRecoveryTests` 12/12 绿（含按方案 B 重命名的 B 测试） |
| READ_SUCCESS_DOES_NOT_CLEAR_BLOCKER | a successful read between repeated failures neither clears nor softens the blocker |
| NOOP_WRITE_DOES_NOT_CLEAR_BLOCKER | a no-op write between repeated failures does not clear the blocker |
| UNRELATED_MUTATION_DOES_NOT_CLEAR_BLOCKER | an unrelated real mutation does not clear the blocker |
| SUCCESSFUL_SIBLING_DOES_NOT_CLEAR_BLOCKER | the same failure keeps counting even when other strategies succeed alongside it（+ HEAD 同名测试） |
| STRATEGY_CHANGE_DOES_NOT_RESET_BLOCKER | different strategies under one blocker warn once, keep accumulating, then stop |
| SAME_FAILURE_ACCUMULATES_MONOTONICALLY | alternating two failure classes with no mutation is not progress |
| SOFT_WARNING_ONCE / HARD_STOP_AFTER_GRACE | 同上（warnings == 1）+ a real session that repeats one blocker while doing neutral work stops after one warning |
| REAL_PROGRESS_CLEARS_BLOCKER | the same objective passing after failing is objective progress；a failure-class change after a real mutation clears the old blocker；a real session that fixes the objective clears the blocker and keeps running |
| BACKGROUND_SUCCESS_IS_NOT_PROGRESS | a background command that merely launched does not clear the blocker + evidence 分类断言 |
| NO_FALSE_POSITIVE_ON_NORMAL_RECOVERY | a real session that fixes the objective keeps running；a warned blocker that is never reproduced again does not end a run doing other work；usefulWorkBeyond32StepsCompletes |
| fingerprint 稳定性 | fingerprints ignore line numbers, paths and ids but keep the failure class apart |

真实 production replay 记录：
- neutral 穿插型（churn=blocked）：25 批可用 → requests=9、tool calls=9、失败 5 次且全部 `exitCode == 69`、策略 5、软提示 1 次、`agentStepLimitReached / 多策略同一阻塞且提示后无进展`。
- 形式变化型（churn=requests，方案 B 的新 B 测试）：36 批可用 → requests=6、失败 6 次、两个 exit code 并存、策略 6、软提示 1 次、终止原因不含"超过上限"。
- 正向型（fix）：5 批工具 + 答案跑满，无提示、无终止，目标由 fail→pass 证明达成。

### BEFORE → AFTER

```
BEFORE  fail X → read ok → fail X → no-op write ok → fail X     → 每步被判 progress，永不终止
AFTER   同一 cluster 内 (callKey, fingerprint) 单调累计 → 第 3 次 hardStop(exactDuplicate)，neutral 只花 grace
BEFORE  [fail X, read ok] 同批 → anySuccess ⇒ progress，X 的证据被抹掉
AFTER   cluster 逐条更新：sibling 成功只影响自己，X 所属 cluster 仍累计
BEFORE  g++/clang++/gcc 三种策略同 69 → 旧实现把"不同错误文本"当进展；换参数可无限续期
AFTER   一个 cluster、三个策略 → 提示一次 → grace 后再次复现 → hardStop；repeats 单调
BEFORE  35 次 echo attempt-N; exit 1/2 交替、零改动、零通过 → 跑到 step 35（旧 regression contract）
AFTER   第 6 批停止：一个 cluster（shell:…状态 # 退出）下两个 exact 观察、6 个策略、提示恰一次
BEFORE  整文件 read/修复回归：模型改完文件重跑同一命令通过 → 旧实现也已放行
AFTER   仍放行：fail→pass 是唯一强信号，正向路径零误伤（35 次真实写入照常跑完）
```

### RESOLUTION（主人裁决：方案 B，语义冻结为 LONG RUN != LOOP）

冲突对象 `ToolLoopRecoveryTests.recoveryBeyond32StepsReachesReport` 已改名为
`changingFailureObservationsDoNotEvadeNoProgressStop` 并按新语义重写。主人裁定：旧期望不是 benchmark
expectation，而是一个被新架构语义淘汰的旧 regression contract，允许修改；同时不得为了这次修改去调
hardStop 阈值、grace 阈值、emergency ceiling、benchmark expectation 或 mutation progress 定义（均未改动）。

为兑现"exit1 / exit2 是不同观察但属于同一个未解决 cluster"，身份显式分两层：

```
ExactFailureFingerprint = tool family + exit code + 归一化消息
                          shell:exit1:commandFailed:命令以状态 # 退出
                          shell:exit2:commandFailed:命令以状态 # 退出        ← 两个不同观察
BlockerClusterIdentity  = tool family + 归一化消息类（exit code 折叠掉）
                          shell:commandFailed:命令以状态 # 退出              ← 同一个 cluster
```

`fingerprint(of:)` 与 `cluster(of:)` 分别产出两层；hardStop 原因同时带上 cluster 与其下实际观察到的
fingerprint（`observations(_:)`），所以"69"这类退出码不会因为归一化而从终止原因里消失。
cluster 层面：`repeats` 单调累计、`strategies` 跨观察合并、`warned` 每 cluster 一次；
清除只认 fail→pass，或"错误类真的变成另一个 cluster + 期间有真实 workspace mutation"。

对照测试 A/B（LONG RUN != LOOP 的两侧）：

| | 场景 | 结果 |
|---|---|---|
| A `usefulWorkBeyond32StepsCompletes` | 35 批，每批都经 `fileMutations` 证明真实改动 + 无失败 | 跑满 36 次请求正常完成；另断言默认 `maxAgentLoopSteps == 0`（不得夹带固定 step 上限）、全程零软提示 |
| B `changingFailureObservationsDoNotEvadeNoProgressStop` | 35 批 `echo attempt-N; exit 1/2`，command text / 计数 / 退出码都在变，但零目标成功、零 mutation、零 verification 改善 | 实测 requests=6 / offered=36、failures=6、软提示恰 1 次、终止原因 `无进展死循环…多策略同一阻塞且提示后无进展`（6 个不同策略），并断言原因文本不含"超过上限" |

B 的 9 项断言逐条对应主人要求：策略数增加、两个 exit code 作为不同 exact 观察被保留（`Set(exitCode).count == 2`）、同属一个 cluster、debt 单调累计到阈值（failures ≥ 3）、提示一次、grace 后 hardStop、终止原因为 no-progress/repeated-blocker 类、不是固定 step 上限、没跑到第 36 次请求。
A/B 两层身份与单调性另在单元层钉住：`exact fingerprint and cluster identity are different layers`、
`two exit codes on one objective are two observations of one unresolved cluster`。

### REMAINING RISKS

1. 方案 B 已落地，Phase 6 的 12 个门全部 PASS。`repeats` 现在按 **cluster sighting 批次**累计（同一批里两个观察落在同一 cluster 只算一次），单调性由此更明确；阈值 3/3/2 未变。
2. **verification 语义是间接的**：Core 不认识"这是测试命令"，只用 shape 匹配（同一目标 fail → pass）与 fingerprint 类别变化 + 真实 mutation。若模型用**不同命令**验证同一目标（`npm test` 修好后改跑 `npx jest`），旧 blocker 不会被"证明消失"，只会因不再复现而停在 open 状态（不会被用来 hardStop，因为停止条件要求本批复现）。这是保守方向：可能少清一次 blocker，不会误杀。
3. `.mutation` 证据按"该结果是否报告了文件改动"判定，只有 write/edit/apply_patch 通过 `FileMutationCapture` 报告。`git checkout`、`format`、`mv` 类真实改动不落 `fileMutations`，因此不会成为 class-change 的辅助证据（同样偏保守）。
4. `run_background_command` 的 `.attestation` 判定走工具 id，且其成功结果不带 `fileMutations`；后台命令**之后**真正改掉文件时，那一次进展要等真实 verification 或同目标复现才承认——与主人 Phase 5 收尾时记录的风险一致，本 Phase 只保证它天然不算 progress。
5. fingerprint 折叠了数字与路径，理论上会把"仅路径不同、错误类相同"的两次失败合成一个 blocker（例如 `g++ a.cpp` 与 `g++ b.cpp` 都报同一语法错误）。这正是期望行为（同一环境级阻塞），但若将来需要按文件区分目标，应扩展 objective identity 而不是削弱单调累计。
6. 本 Phase 未触碰 eviction scoring、context budget、Recall、Provider privilege、Phase 5 读调度、Branch Prediction、benchmark expectation；`exactDuplicateLimit/clusterWarningAt/clusterGraceAfterWarning` 三个阈值数值未变，变的只是"什么才算进展"。
