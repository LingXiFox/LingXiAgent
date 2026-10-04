# LingXiAgent P/E-Core · ToolResult · Recall · read_file · Tool Loop 专项深审计

- 审计日期：2026-10-04
- 审计对象：HEAD `4914c1b`（Refactor and enhance tests for tool loop recovery, context integrity, and recall mechanisms）
- 审计方式：只读代码 + 真实 production execution path replay。**生产代码零改动**（`git diff Sources/` = 0）
- 唯一新增文件：`Tests/LingXiAgentTests/AuditRealityProbeTests.swift`（10 个诊断 probe，未 commit）
- 所有数字来自实机运行，不从单测通过推断

---

## 一、Executive Summary

### 先说一件必须先知道的事：HEAD 上有 3 个测试是真红的

```
swift test --filter ToolLoopRecoveryTests → Suite failed, 4 issues
  ✗ successfulSiblingCannotHideRepeatedFailure        (ToolLoopRecoveryTests.swift:33)
  ✗ successfulNoOpCannotEraseUnresolvedFailure        (:23)
  ✗ realNoOpRewriteCannotMaskRepeatedTestFailure      (:40)  requests.count=7, script.count=7
```

这三个测试正是问题 4 的语义规格 —— **规格已写、实现未做**。所以问题 4 不是"设计如此"，是 commit `4914c1b` 加了测试没加实现。

### P0（正确性 + 安全语义，破坏用户可见契约）

| # | 结论 | 实机证据 |
|---|---|---|
| P0-1 | **Recall 永远拿不回中间证据**：admission 从 canonical entries 重建，而 canonical 已被截到 16,384；全量 51,090 在 E-Core 里存在但**没有 occurrence-facing ref** | probe01 / probe08 |
| P0-2 | **retrieved data 被升级为特权指令**：Anthropic 把 recalledOccurrence / eCoreRetrievalProjection / retrievalData 拼进 top-level `system`；Chat 编成 `role=system`。只有 Responses 正确降级为 `user` | probe05 |
| P0-3 | **同 batch 内 read_file 读到旧内容**：只读签名去重 + 读写并发无 ordering barrier，stale 结果被**持久化进 SessionStore** | probe03 |
| P0-4 | **no-progress 永不触发**：`anySuccess` 即 progress；12 轮同一 blocker + 穿插成功 write_file → 25 步不终止 | probe04 |
| P0-5 | **Recall admission 不 durable**：`pendingRecallReferences` 是纯内存字典；工具成功→崩溃→意图永久丢失 | probe11 |

### P1（语义错误 + 指标失真）

| # | 结论 | 证据 |
|---|---|---|
| P1-1 | **slice 语义与 occurrence 语义混为一谈**：模型请求 8KB slice，admission 却按"恢复整个 occurrence"计费 → `inputBudgetExceeded: required=17087, hard=16552` 被拒；成功时 slice(7,524B) 与 occurrence(3,328B) **在同一请求里重复** | probe08 |
| P1-2 | **context_recall 的 slice 被通用 ToolOutputPolicy 二次截断**：显式 `limit_bytes:32768` → 实际落地 16,384，`truncated=true`，且 header 自报 `Bytes: 0-16552` 与实际送达不符 | probe10 |
| P1-3 | **P-Core region telemetry 污染**：真实 index 62 bytes，recall 一个 64,000B payload → `eCoreIndexTokens=21,363`。"index 与 E-Core size 解耦"的 benchmark 不可信 | probe06 |
| P1-4 | **老对象实际不可发现**：index 上限 8 行、候选只有 `summary 词法子串 + recency`；BM25/UnifiedRetrieval **完全不参与 index 选择**；同一脚本三次跑出 `refs=11` 但大对象 0/3 次进 index | probe08/09 |
| P1-5 | **E-Core 检索计算不是 bounded**：`references()` 每次全目录扫描+全量 decode+全量排序，warm≈cold 无 memoization；每步 assembly 调 ≥3 次；`context_search` 对每个 object `fetch` 全 payload 做 `contains`；且 page-out 对象不写 `.meta.json` → 对 `listObjects/search` 完全隐形 | probe07 |
| P1-6 | **`pageIn` / `exactRestore` 是假成功指标**：`handleSearch` restore 全 payload 只拼 500-char snippet 就 `pageIns += 1` | 代码 |

### P2（结构债 / 观察项，本轮不动）

- 两套 objectID 派生并存：sidecar 用 FNV `generate(tool,callID,content)`，page-out 用 SHA256 `identify(content)` → 同一 payload 落两个文件，不去重（ECoreObjectFabric:705 vs :519）。
- `ToolResult.diagnostics.stdout` 保存完整 50,171B 原始输出并**持久化进 canonical**，与"canonical 只留 bounded excerpt"的叙述不一致（虽未泄漏到 wire）。
- `write_file` 要求 `expected_hash/expected_version`，而整文件 `read_file` 不返回任何版本戳 → 模型无法完成 read-modify-write（probe02 的 write 就是这么失败的）。
- Branch Prediction 确认：`REAL_FEED=YES / PREDICTION=YES / TELEMETRY=YES / RUNTIME_CONSUMER=NONE / STEERING=DISABLED`，本轮不动。

---

## 二、逐条问题

### 问题 1：Recall admission 恢复的是摘要/已压缩 occurrence

**STATUS: CONFIRMED**（全量 payload 其实**在** E-Core 里，但不是 admission 恢复的那个东西）

**ROOT CAUSE**

两层叠加：

1. `ContextCompactor.admitRequestedRecalls` 拿到 `restore(refID)` 的完整 payload 后**把它丢掉**，改用 `canonicalEntries.filter{ids.contains(...)}` 重建；canonical 的 toolResult.content 早已被 ToolOutputPolicy 截到 16,384。
2. `SessionRuntime` 的 sidecar 写入把全量 payload 存进 E-Core，但**只调 `store()`，从不调 `referenceForStoredObject()`** → 全量对象没有任何模型可见 ref，Exact Restore 无法寻址它。

**PRODUCTION PATH**

```
BuiltinTools.ContextRecallTool.execute
  → ECoreObjectStore.requestRecall
  → ECoreObjectStore.recall(objectID:)
  → queueRecallAdmission(referenceID)
  → SessionRuntime:685 admitRequestedRecalls
  → ECoreObjectStore.restore
  → ContextCompaction:1120 canonicalEntries.filter
  → PCoreSnapshot.modelMessages
  → provider
```

**CODE EVIDENCE**

```swift
// ContextCompaction.swift:1113
guard let payload = try? await ecoreStore.restore(sessionID: sessionID, referenceID: refID) else { ... }   // 全量 68,586B
// ContextCompaction.swift:1120  ← 丢弃 payload，改用 canonical
var restored = canonicalEntries.filter { ids.contains($0.messageID ?? MessageID("")) }
// ContextCompaction.swift:1127  ← 只有 ids.isEmpty（无 canonical occurrence）才真的用 payload
restored = [ContextEntry(..., part: .text("[Restored session context]\n\(payload)"))]

// SessionRuntime.swift:1312-1324  全量入 E-Core，无 ref
if let ref = res.output.outputBlobRef, let archived = await toolRuntime.archivedOutput(ref), !archived.isEmpty {
    payload = archived
}
if payload.utf8.count >= cacheController.ecoreStore.configuration.objectizationThreshold {
    await cacheController.ecoreStore.store(sessionID:, toolCallID:, toolName:, content: payload)  // ← 没有 referenceForStoredObject
}

// ECoreObjectFabric.swift:692  store() 只写 payload + ObservationMetadata，不建 ECoreReference
// ContextProjection.swift:102  唯一建 ref 处，且用截断后的 result.content 再存一份 16KB 对象
```

**REAL REPRO**（probe01，真 shell 真 executor）

```
输入   : 真实 shell awk 产 51,090 bytes，中间行 MID7F31END（位于 ~37.6K）
实际   : durable content 16,384B (truncated=true, totalBytes=51,090, visibleBytes=16,384)
         archive blob 51,090B
         E-Core objects: 6 个 (46,290 / 51,090B)，references: 0
         page-out ref 指向的对象 68,586B，marker 只在 offset 57,344 的 slice 里出现
         三套 wire JSON: marker = false / false / false
预期   : 模型 recall 之后应能在 wire 中看到 MID7F31END
```

**TEST COVERAGE**

- `PERecallContractTests.swift:9` 手工构造 43,527B 的 `ToolResult(content:)` 直接塞进 hand-built `Session`（`:12-14`）。生产路径**不可能**产出这种对象（policy 上限 16,384）。所以 `SUCCESS_RECALL_NEXT_STEP originalChars=43527 admittedMarker=true` 是真的，但它验的是"如果 canonical 完整则能找回"这个永远不成立的前提。
- `PEContextIntegrityTests.swift:305-306` 同样用 `sessionStore.appendMessage` 绕过 executor。

**FIX BOUNDARY**

- 该修：`ContextCompactor.admitRequestedRecalls`（occurrence 身份 + 载荷来源）；`SessionRuntime:1312` 的 sidecar 建 ref。
- 不该修：`ToolOutputPolicy` 上限、context budget、provider wire 协议、`ECoreObjectID.identify` 冻结语义、eviction scoring。
- 关键判断：**不能**把 51KB 塞回长期 P-Core 绕过 E-Core（红线）。正确方向是让 admission 以 E-Core 载荷作为该 occurrence 的权威投影源，而不是 canonical excerpt。

**REGRESSION TEST**

`TruthTest_realExecutorFortyKBRecallReturnsMiddleEvidence`：真实 shell 产 >40KB → 断言

1. durable content ≤ 16,384 且 `truncated == true`；
2. `archivedOutput()` 返回全量；
3. E-Core 中存在**一个带 ref 的对象**，其字节数 == 全量；
4. 模型 recall 中间 offset 后，`makeRequestBody` 三种 wire 均含中间 marker；
5. canonical SessionStore 未被修改。

禁止 `ToolResult(content: big)`。

---

### 问题 2：context_recall slice 被通用 projection 再截断

**STATUS: PARTIAL**

- slice 二次截断：**CONFIRMED**（但凶手是 ToolOutputPolicy，不是 ModelToolResultProjection）
- "下一步 assembly 丢失 recalledOccurrence 语义"：**NOT REPRODUCED**（进程内该 segment 会存活；跨进程见问题 C）

**ROOT CAUSE**

`ModelDomain.swift:96-97` 已为 `toolName=="context_recall" && content.hasPrefix("[Context Object Slice:")` 开了 passthrough 白名单，projection 不再切；但 slice 的返回字符串本身就是普通 tool 输出，**在 executor 出口就过 `ToolOutputPolicy.excerpt()`（16,384 chars / 400 lines）**。所以"模型显式请求的字节范围"被上游无条件封顶。

**PRODUCTION PATH**

```
ContextRecallTool.execute(返回 slice)
  → ToolRuntime.swift:828 outputPolicy.excerpt(rawContent)
  → ToolRuntime.swift:833 ToolResult(content: bounded.content)
  → SessionRuntime:1377 持久化
  → 下一步 ContextProjection.modelEntries（白名单放行）
  → wire
```

**CODE EVIDENCE**

```swift
// ToolOutputPolicy.swift:9
public init(maximumCharacters: Int = 16 * 1024, maximumLines: Int = 400)

// ToolRuntime.swift:828-833
let bounded = outputPolicy.excerpt(rawContent)
let metadata = try await outputArchive?.archive(rawContent, metadata: bounded.metadata) ?? bounded.metadata
... ToolResult(callID: call.callID, success: true, content: bounded.content, ...)

// ModelDomain.swift:96-97  白名单只挡 projection，挡不住 policy
if segment == .admittedToolResult || (result.success && (segment == .recalledOccurrence ||
    (result.toolName == "context_recall" && result.content.hasPrefix("[Context Object Slice:")))) {
```

**REAL REPRO**（probe10）

```
输入   : context_recall(id, offset:0, limit_bytes:32768)
实际   : durableSliceBytes=[16384]  rawToolOutputTotalBytes=[16552]  policyMarkedTruncated=[true]
         slice header 自报 "Bytes: 0 - 16552"，模型实得 16384
预期   : 显式 limit_bytes 是模型的合同，应原样送达
```

**TEST COVERAGE**

`PERecallContractTests.swift:27` 手工 `ToolResult(content: slice)` 直接进 `ModelRequest`，跳过了 `ToolRuntime:828`，所以 `!wire.contains("characters truncated")` 只能证明 projection 白名单有效，证明不了 policy 不切。

**FIX BOUNDARY**

- 该修：executor 出口对 `context_recall` 这类"模型自证的有界读取"要有独立的 output contract —— 不是删 ToolOutputPolicy，而是给它按调用者身份分层的 policy，slice 上限应等于 `configuration.recallMaxBytes`，而不是通用 16,384。
- 不该修：删 `ToolOutputPolicy`、无限提高 budget、在 projection 层继续打补丁（已经打过，位置就不对）。

**REGRESSION TEST**

`recallSliceHonoursRequestedLimit`：真机走 `context_recall(limit_bytes:)` 取 {8192, 16384, 32768}，断言送达字节 ≥ min(requested, remaining)、header 的 `Bytes:` 区间与实际送达一致、`truncated` 由 slice 语义而非通用 policy 决定。

---

### 问题 3：read_file 返回旧内容

**STATUS: CONFIRMED（batch 内）**；跨 step 场景 **NOT REPRODUCED**（确实不存在跨 step 读缓存）

**ROOT CAUSE**

`SessionRuntime` 每个 batch 用 `ReadOnlySignature{toolName, canonicalArguments, resource}` 做只读去重：**key 里没有 mtime/size/hash**；`primaryBySignature` 把第二次相同读映射到第一次的 primary，第二次**根本不执行**；而读写在同一个 `withTaskGroup` 里并发派发，**没有 ordering barrier**。`write_file` 因 `readOnly:false` 被完全排除在签名表外，无法打断读缓存。结果 stale OLD 被 `publishCompletedTool` → `settleBatch` **写进 SessionStore 成为持久历史**。

**PRODUCTION PATH**

```
SessionRuntime:1205 readOnlySignature
  → :1219 primaryBySignature[signature] → primaryByIndex[offset] = primary
  → :1228 TaskGroup 只跑 primary（第二次 read 不执行）
  → :1490 sharedReadOutcome（逐字节复制第一次 content）
  → :1746 publishCompletedTool
  → :1380 settleBatch
  → SessionStore（stale 被持久化）
```

**CODE EVIDENCE**

```swift
// SessionRuntime.swift:1209
var primaryBySignature: [ToolRuntime.ReadOnlySignature: Int] = [:]      // batch-local，跨 step 无残留

// SessionRuntime.swift:1219-1223
} else if let signature = signatures[offset], let primary = primaryBySignature[signature] {
    primaryByIndex[offset] = primary
} else {
    if let signature = signatures[offset] { primaryBySignature[signature] = offset }
    primaryByIndex[offset] = offset
}

// SessionRuntime.swift:1228  读写并发派发，无 barrier
for (offset, call) in calls.enumerated() where outcomes[offset] == nil && primaryByIndex[offset] == offset {

// ToolRuntime.swift:432-446  签名无版本戳
public struct ReadOnlySignature: Sendable, Equatable, Hashable {
    public let toolName: String
    public let canonicalArguments: String
    public let resource: String
}

// ToolMutationCoordinator  只串行化 mutation，read 绕过 MutationGate
// FileMutationJournal.swift:71  beforeHash/afterHash 存在但从不接回读失效（唯一消费者是 FileRollbackEngine）
```

**REAL REPRO**

```
probe03  同 batch [read, shell mutation, read]
         disk=NEW | readResults=["OLD","OLD"] | sharedFlags=["nil","true"] | 预期 ["OLD","NEW"]
         → CONFIRMED

probe02  同 batch [read, write_file(NEW), read]
         write_file 失败："修改现有文件需要 expected_hash 或 expected_version" → disk=OLD
         → 副问题：整文件 read_file 不返回版本戳，模型拿不到 expected_hash
           （BuiltinTools.swift:511 无 stamp；:472/:193-197 分页路径才有 fileVersion；:200-212 write 门槛）

跨 step  read → 外部/shell 改盘 → read 返回 NEW（正确）
         PERecallContractTests.swift:63 realSessionReadAfterShellMutationReturnsFreshContent 已覆盖并通过
```

**TEST COVERAGE**

`AgentToolLoopTests.swift:392 identicalReadsInOneBatchShareRealPayload` 把 `sharedRead=="true"` 当**期望**断言 —— 测试在主动固化这个缺陷。没有任何测试在一个 batch 里混合 mutation 与重复 read。

**FIX BOUNDARY**

- 该修：batch 调度层 —— 签名的有效性域、读写 ordering barrier、以 workspace mutation 事件为界的失效。
- 不该修：GUI 显示层掩盖；把 dedup 整个关掉当"修好"（幽灵旋转防护要保留）；给 read_file 塞无界缓存。

**REGRESSION TEST**

`readOnlyDedupIsInvalidatedByBatchMutation`：三种 case

1. read / write_file / read
2. read / shell-mutation / read
3. read / read（无 mutation）

前两个第二次必须读到 NEW；第三个仍允许 dedup（防过度修复回归）。断言实际执行次数、磁盘内容，以及**持久化的 toolResult 等于当时磁盘内容**。

---

### 问题 4：Tool Loop no-progress 把"任意成功 ToolCall"当 progress

**STATUS: CONFIRMED**

**ROOT CAUSE**

`ToolLoopProgressTracker.record`：`guard !failures.isEmpty, !anySuccess else { reset(); return .progress }`。一个 batch 里只要有一个 succeeded，**未解决的 blocker 集群被整体清零**，`exactDuplicates` / `clusterStrategies` / `warnedAtBatch` 全归零，硬终止永不到达。且"成功"不区分：无关 write_file 成功、重复写相同字节、只读工具成功，全都算 progress。

**CODE EVIDENCE**

```swift
// ToolLoopProgressTracker.swift:72
let anySuccess = batch.contains(where: \.succeeded)

// ToolLoopProgressTracker.swift:74-79
// Any success, or a batch that did not fail at all, is progress.
guard !failures.isEmpty, !anySuccess else {
    let changed = lastFailure != nil
    reset(keys: keys)                                  // ← blocker 集群被抹平
    return .progress(strategyChanged: changed)
}

// SessionRuntime.swift:1340-1351  生产接线
let loopVerdict = loopTracker.record(zip(calls, settled).map { call, outcome in
    ... CallOutcome(callKey: failureKey(for: call), succeeded: outcome.result.success, errorMessage: ...)
})
recordLoopVerdict(loopVerdict, step: step + 1)
```

**REAL REPRO**

```
probe04  12× [失败 shell(NameError…exit 1)] + 12× [成功 write_file(相同内容)]
         providerRequests=25, endedWithError=none, reachedScriptEnd=true
         → 从未 hardStop

HEAD 红测  successfulSiblingCannotHideRepeatedFailure / successfulNoOpCannotEraseUnresolvedFailure
           / realNoOpRewriteCannotMaskRepeatedTestFailure  三个都在 HEAD 上失败
           realNoOp… 还额外暴露 requests.count(7) < script.count 断言失败 —— 循环一路跑到脚本尽头
```

**TEST COVERAGE**

不是"抓不到"，是**已经抓到了但没人修**：三个测试在 HEAD 真红（见 §一）。

**FIX BOUNDARY**

- 该修：tracker 的 progress 定义（TASK PROGRESS ≠ TOOL SUCCESS）。
- 不该修：用调小 `maxAgentLoopSteps` 当替代；冻结的 eviction scoring；Branch Prediction steering。

**状态机方案（先设计，不改）**

把单一 `anySuccess` 换成三条独立轨道：

```
BlockerCluster {
    fingerprint            // 失败指纹
    firstSeenStep, lastSeenStep
    strategies: Set<String>      // 同指纹的不同 call identity = exploration
    workspaceDeltaFingerprint    // 该 cluster 关联的 workspace 变化
    testStateDelta               // build/test 状态类别变化
}

progress 判定（按证据强度，不按 succeeded 布尔）：
 1. objectiveProgress   : cluster 的失败 fingerprint 在本 batch 之后不再复现          → 清除 cluster
 2. environmentProgress : workspace mutation fingerprint 真变化，且非 no-op（同字节不算）
 3. verificationProgress: test/build 状态类别改善（fail→pass，或 error 类别改变）
 4. exploration         : 同 fingerprint、不同 callKey → 计 strategy，不算 progress（保留现状）
 5. read-only success   : 永不清除 blocker cluster（当前最大漏洞）
 6. no-op write         : 相同内容重写 = 中性，不算 progress 也不算 failure

Verdict 迁移：
  progress 需满足 (1) 或 ((2|3) ∧ ¬repeatedFailureFingerprint)
  否则 exactDuplicate / cluster 计数单调累计 → soft warning 一次 → grace 后 hardStop
```

**REGRESSION TEST**

先把 HEAD 三个红测转绿；再加 `interleavedUnrelatedSuccessDoesNotEraseBlocker`（probe04 形状，12 batch，断言第 N 批 hardStop 且模型仍能报告 blocker）。

---

### A. Raw ToolResult 是否存在"两套 truth"

**STATUS: CONFIRMED（且比假设更糟）**

假设的拓扑基本成立，但有一处修正：**E-Core 全量对象并非"41KB 原文"**，而是 68,586B 的：

```
"[Historical tool evidence]\n" + JSONEncoder().encode(ToolResult)
```

它把 content(16,384) 和 diagnostics.stdout(50,171) 一起编码进去了。也就是说全量字节**确实**在 E-Core 且**确实**可 slice 读出，但：

1. 它是"JSON of truncated result"，不是原始 executor 输出；对象身份是 `identify(evidence)`，与 sidecar 的 `generate(shell, call-1, raw)` 是两个不同 objectID → **同一份知识落两个物理对象**；
2. sidecar 那个真正的 raw 对象 **0 个 ref**（probe01：`eCoreObjects=6, eCoreReferences=0`），Exact Restore 无法寻址；
3. `context_recall` 想拿中间证据必须知道 offset≈57,344（probe08 扫描得出），而 index 行只给 140-char summary，模型无从推出。

**模型最终拿到的 ref 指向哪个 object：** 实测 `ref_f91a39df… → obj_6a7e5149… = 68,580B（evidence JSON）`，不是 raw、也不是 sidecar 对象。假设成立。

---

### B. context_recall 的 slice semantics 与 occurrence admission 是否混在一起

**STATUS: CONFIRMED**

- `queueRecallAdmission(sessionID:referenceID:)` **只存 referenceID**；`offset / limit_bytes / limit_lines` 在 `BuiltinTools.swift:622` 之后永久丢失（`pendingRecallReferences: [SessionID: [String]]`，ECoreObjectFabric:426）。
- 下一 step 把"模型只要 16KB slice"升级成"恢复整个 occurrence"：`admitRequestedRecalls` 的 budget 检查是 `retained + restored`（整 unit），**不是** slice 成本。
- 实测两态：
  - **拒绝态**（24,000 窗口）：`requested=1 resolved=1 admitted=0 rejected=1 reason=inputBudgetExceeded: required=17087, hard=16552`。而 slice 只有 8,359B ≈ 2.8K token —— **远超余量的是 occurrence，不是 slice**。
  - **接受态**（30,000 窗口）：`admitted=1`，同一请求同时含 `sliceBytes=[7,524]` 与 `occurrenceBytes=[3,328]` → **重复**。且 occurrence 内容严格少于模型已经拿到的 slice（canonical excerpt vs slice），是纯负收益的重复。
- 结论：当前代码需要的是**两个不同概念**，不是修一处。建议形状（先分析，不重构）：

```swift
RecallRequest { referenceID, requestedRange, admissionMode }
  admissionMode ∈
      .sliceOnly              // 默认：模型显式范围，只把 slice 计入下步预算
    | .occurrenceProjection   // 用 E-Core 载荷投影该 occurrence，而非 canonical excerpt
    | .occurrenceInline       // 需显式授权 + 独立预算

// slice 与 admission 共享 occurrence 身份，避免同一证据两份
```

---

### C. Recall admission 是否 durable

**STATUS: CONFIRMED 缺口**（crash window 1 实测，window 2 代码证明）

| 状态 | in-memory | SQLite | E-Core disk | 实测/推断 |
|---|---|---|---|---|
| pending recall intent | `pendingRecallReferences` | ❌ | ❌ | **probe11：崩溃后 `admitted=0`、`occurrenceVisible=false`（意图永久丢失）** |
| admitted residency（canonical 型） | `unitResidencies` | ✅ 但**晚一步** | — | probe09：重启后 states 前后一致 → 若 persist 已跑则存活 |
| admitted payload（E-Core-only 型） | `admittedPayloads` | ❌ | payload 在 | **probe12：`admittedNowEntries=1` → `afterCrashEntries=0`、`hasPayload=false`** |
| reference / object payload | ✅ | ❌ | ✅ | probe09：refs 11→11 存活 |

Window 2 代码证明：

```swift
// SessionRuntime.swift:685 → :688  之间有崩溃窗口
finalEntries = await compactor.admitRequestedRecalls(...)                 // 内存已改
if await cacheController.ecoreStore.lifecycleSnapshot(...).recallAdmitted > admissionsBefore {
    try await persistCompaction()                                        // 才落盘
}
```

且 `persistCompaction` 只写 `residencies`；`admittedPayloads` 字典**从不落盘**；`restoreResidencies`（ContextCompaction:462-466）只在 `state.messageID.rawValue == refID` 时重建 → 只覆盖 E-Core-only 分支，canonical 型靠 residency 表回滚。

真实 restart replay 已执行：`pageOut → context_recall → admission → shutdown → new CoreHost → load same session → next inference`（probe09 / probe11）。

---

### D. Provider privilege parity

**STATUS: CONFIRMED（三个 provider 不一致，两个授予特权）**

probe05 用真实 `makeRequestBody` 输出：

| segment | Chat | Responses | Anthropic | 特权指令通道？ |
|---|---|---|---|---|
| conversation | tool/assistant 通道 | 同 | messages | 否 |
| admittedToolResult | tool 通道 | tool 通道 | tool 通道 | 否 |
| retrievalData | **`role:"system"`** | `role:"user"` | **top-level `"system"`** | Chat 是 / Responses 否 / **Anthropic 最严重** |
| eCoreRetrievalProjection | **`role:"system"`** | `role:"user"` | **top-level `"system"`** | 同上 |
| recalledOccurrence | **`role:"system"`** | `role:"user"` | **top-level `"system"`** | 同上 |
| immutableInstructions | `role:"system"` | `role:"developer"`（instructions） | top-level `"system"` | 是（设计如此） |

生产者同一个洞：所有 P/E 条目都带 `role: .system`

- `ContextCompaction.swift:465 / 1033 / 1050 / 1127`、`981-990`（index）、`SessionRuntime.swift:672`、`PCoreContextEngine.swift:219 / 272`
- `PCoreContextEngine.modelMessages()`（:134-152）只把 source 派生成 segment，**role 原样传下去**
- `AnthropicMessagesProvider.swift:141` 把所有 `role == .system` 拼进 `system` 字段；`:152-155` 再从 messages 移除

**历史 ToolResult 一旦被 recall 就变成指令通道内容。**

顺带纠正文档冲突：`Docs/AA/PE-Core-Context-Integrity-2026-10-04.md:69` 写"Responses 编码为 developer input"，与代码（`OpenAIResponsesProvider.swift:192`，retrieval → `user`）矛盾。**代码为准**，文档需同步。

注入 payload 建议留到修复阶段作为断言（`IGNORE PREVIOUS INSTRUCTIONS` / `SYSTEM OVERRIDE TEST MARKER` 放入历史 ToolResult → 三 wire JSON 断言不出现在 system/instructions 通道）。probe05 已用同结构 segment 探针定性。

---

### E. bounded E-Core Index 是否只是 token bounded

**STATUS: CONFIRMED —— prompt growth bounded 成立，retrieval computation bounded 不成立**

probe07（同一 `ECoreObjectStore`，持久化后端开启）：

| refs | `references()` 首次 | `references()` 再次 | `searchReferences` | `listObjects` |
|---|---|---|---|---|
| 100 | 0ms | 0ms | 1ms | 0 meta |
| 1,000 | 8ms | 7ms | 11ms | 0 meta |
| 5,000 | 40ms | **39ms** | 56ms | 0 meta |

- `warm ≈ cold` → **没有 memoization**：每次全目录扫描 + decode 未缓存文件 + 全量排序（`ECoreObjectFabric.swift:667-687`）。
- 每步 assembly 至少 3 次：`projectIndex` 在 `SessionRuntime:674` 与 `:686` 各一次，`eCoreIndexProjection` 内部 `searchReferences` 再调一次。
- `listObjects` 只认 `.meta.json`，而 `pageOut()` 有意不写 → 实测 `metaObjects=0`；`context_search` 走的 `ecoreStore.search()` 会对**每个对象 `fetch` 全 payload 做 `localizedCaseInsensitiveContains`**（`ECoreObjectFabric.swift:1085`）→ O(N × payload) IO+CPU，且对 page-out 载荷整体失明。
- index 展示口径确实 bounded：`eCoreIndexLineLimit = 8`、allowance `min(512, hardInputLimit / 8)`。

---

### F. bounded index 之外的历史对象是否实际上不可发现

**STATUS: CONFIRMED 不可发现**

- 候选来源 = `searchReferences(query)`（**词法子串** over `summary + toolName + objectID`，`ECoreObjectFabric.swift:1103-1109`）+ `references()` 按 `evictionEpoch / createdTurn` 排序的 recency 前缀，再 `prefix(8)`。
- `UnifiedRetrievalRegistry` / `BM25RetrievalIndex` / `ECoreRetrievalProvider` 在 `Sources/` 中**没有任何 Retrieval/ 模块外的消费者参与 index 选择**；`RetrievalSearchTool` 是另一条工具线。
- **命名"语义召回"不等于语义**：`searchReferences` 的注释写"语义召回"，底层是 lexical substring，无 embedding、无 BM25。
- 实测：同一脚本三次运行，`refs=11` 但大对象（含 `i<800`）0/3 进 index，`issuedRef=nil`、`markerAfterRestart=false`。

结论：一个足够旧、且 140-char summary 与当前 query 无词面重叠的对象，**永久不可达**（`context_recall` 只认 ref/objectID）。

---

### G. P-Core region telemetry 是否把 recall payload 算成 E-Core Index

**STATUS: CONFIRMED 污染**

probe06：index entry 62B、recall payload 64,000B

```
estimatedTokens      = 42727
stablePrefixTokens   = 5
growingContextTokens = 21338
eCoreIndexTokens     = 21363     ← 真实 index 只有 ~21 token
derivedTokens        = 21363
```

根因：**口径由 source 决定而非 segment**

```swift
// PCoreContextEngine.swift:27-29
case .projectPage, .derivedPage:
    return .eCoreIndex

// PCoreContextEngine.swift:313
regionCharacters[entry.source.pCoreRegion, default: 0] += count

// PCoreContextEngine.swift:322
eCoreIndexTokens: max(0, (regionCharacters[.eCoreIndex, default: 0] + 2) / 3)
```

而 recall 产物恰好是 `source: .derivedPage`（`ContextCompaction:1127 / 465`、`SessionRuntime:672`），index 也是 `.derivedPage`（`:981-990`）。

更糟：同一个 `recalledOccurrence` 语义走 canonical 分支时 `source` 保持 `.toolResult` → 落进 `growingContextTokens`（probe06 的 21,338）。**同一概念按代码分支落进两个 region**，这才是 benchmark 不可信的根本原因。

正确口径应由 **segment** 决定：`eCoreRetrievalProjection → index region`，`recalledOccurrence → 独立 region`。本轮不改。

---

### H. 当前 recall regression tests 是否绕过真实 production producer path

**STATUS: TEST GAP（确认）**

绕过 executor 的清单：

| 文件 | 行 | 手法 |
|---|---|---|
| `PERecallContractTests.swift` | 9 / 12-14 / 27 / 39-42 | `payload` = 43,527B，手工 `ToolResult(content:)` 塞进 hand-built `Session`；手工 slice |
| `PEContextIntegrityTests.swift` | 303-306 | 真 `CoreHost`，但 `sessionStore.appendMessage(..., .toolResult(failure))` 绕过 executor |
| `LMStudioToolChoiceIntegrationTests.swift` | 33 | 同上 |
| `PECoreRealWorldValidationTests.swift` | 83-102 / 330-354 | 同上（约 25KB 却在注释写 "12KB"） |
| `ContextProjectionTests.swift` | 23-42 / 153-167 | 直接构造 |
| `ECoreHeatPhase0Tests.swift` | 699 | 直接构造 |

生产者本应拦住它：`ToolOutputPolicy.swift:9`（16,384 chars / 400 lines），在 `ToolRuntime.swift:828-829` 应用、`:833` 产出 `ToolResult(content: bounded.content)`；`CoreHost.swift:506-510` 从未覆盖 `outputPolicy`；`SessionRuntime.swift:1377-1378` 持久化的就是已 bounded 的结果。**43,527B / 2 行的 durable ToolResult 不可达。**

另两处失真：

- `PEContextIntegrityTests.swift:307` 硬编码 `estimatedTokens: 4000` —— 喂给淘汰算术的数不是估算器会给的。
- `PERecallContractTests.swift:116-118` 用 `restoreResidencies` 直接制造 `.derived` 状态，绕过 compaction。

真实 wire 捕获能力**本来就存在**，只是没用在 P/E recall 上：

- `makeRequestBody`（Chat `:169` / Responses `:154` / Anthropic `:136`）
- `ProviderHTTPTransport`（`ProviderHTTPTransport.swift:39`，三 provider 均可注入，看得到真实 `URLRequest.httpBody`）
- VCR：`VCRNormalization.normalizeRequest`（`:104-119`，role/content 字节精确）+ `VCRCassetteStore`（`:107-133` 硬匹配）
- 本审计的 probe 系列已经用上这条链，报告里的数字即由此产出。

唯一较接近真实的现有测试：`ContextCompactionTests.swift:313-353`（真 `CoreHost`、真 `read_file`、真 8 步循环、断言 `[E-Core index]`），但 payload 只有 3,600B 且**无 context_recall 往返**。

---

### I. read_file stale 是否还存在 batch 内 race

见"问题 3"。三种 case 实测：

| case | 磁盘 | 返回值 | 执行次数 | 结论 |
|---|---|---|---|---|
| 1. 跨 step read→mutate→read | NEW | NEW | 每次真读 | 正确（无跨 step 缓存） |
| 2. 同 batch read→write_file→read | OLD | OLD / OLD | write 失败 | `expected_hash` 门槛（副缺陷 P2） |
| 3. 同 batch read→shell→read | **NEW** | **OLD / OLD** | 第二次未执行 | **CONFIRMED stale**，`sharedRead=true` |

---

### J. ToolLoopProgressTracker 语义

见"问题 4"，含 TASK PROGRESS vs TOOL SUCCESS 定义与状态机方案。补充比较维度结论：

- `same failure fingerprint 是否仍存在` → **应作为主判据**（当前完全未用）
- `failed objective / tool family 是否仍重复` → 当前只用于区分 exactDuplicate vs cluster，不用于阻止 progress 重置
- `workspace mutation fingerprint 是否真的变化` → 数据已存在（`FileMutationCapture` / `ToolResult.fileMutations`）但 tracker 未消费
- `test/build state 是否改善` → 无信号源，需新增
- `successful read-only tool 不能天然算 progress` → 当前错了
- `重复写相同字节不能算 progress` → 当前错了
- `不相关成功 ToolCall 不能清除 blocker cluster` → 当前错了

---

### K. Recall / PageIn telemetry 是否会产生"假成功"

**STATUS: CONFIRMED**

```swift
// ContextCacheController.swift:798-804
for reference in await ecoreStore.searchReferences(sessionID: sessionID, query: query, limit: limit) {
    guard let payload = try? await ecoreStore.restore(...) else { continue }
    let snippet = payload.count > 500 ? String(payload.prefix(500)) + "..." : payload   // ← 只给 500 字符
    pagedOutResults.append((reference, snippet))
    pageInsBySession[sessionID, default: 0] += 1                                        // ← 立刻记 pageIn
    ...
}

// ECoreObjectFabric.swift:623  restore() 内部无条件 noteExactRestore
debugHub?.noteExactRestore(sessionID: sessionID, referenceID: referenceID)
```

所以 `pageIn / exactRestore` 只证明"字节被读出来了"，不证明"字节进了下一次模型请求"。

**建议最终标准（可用证明链）**

```
recallRequested → recallResolved → recallAdmitted → providerRequestContainsPayload
```

前三项已有（`ECoreLifecycleTelemetry.swift:7/16`），**第四项缺失**。修法：在 `SessionRuntime` 组装出最终 `ModelRequest` 之后，按 referenceID / occurrence 身份做一次 byte-level presence 记录（纯观测、Fail-Open），作为唯一"E→P 成功"口径。`context_search` 的 `pageIn` 应改为独立指标（如 `snippetSurfaced`），不得进 E→P 成功链。

---

### L. Branch Prediction（仅确认，未修改）

```
REAL_FEED          = YES   SessionRuntime:1331（真实 tool 名）, :1161（directAnswer）, :1447（userInterrupt）
PREDICTION         = YES   VariableOrderMarkovPredictor(maxOrder: 3)，abstain gate 0.25 / support 2
TELEMETRY          = YES    hits / misses / confidence / support / matchedOrder（BranchPredictionRuntime:32-48）
RUNTIME_CONSUMER   = NONE   record() 返回值全部 `_ =` 丢弃；snapshot() 唯一读取处 = CoreHost:2565 Observatory 展示
STEERING           = DISABLED
```

本轮未触碰。

---

## 三、四条真实数据流

### 1. Raw Tool Output Lifecycle

```
executor raw 51,090B
 ├─→ ToolOutputPolicy.excerpt (16,384 chars / 400 lines)
 │      └─→ ToolResult.content 16,384B ──→ SessionStore (canonical, durable)
 ├─→ ToolOutputArchive.archive → SQLite storeToolOutput ──→ blob 51,090B
 │      （ToolResult.continuation / output.outputBlobRef 携带）
 ├─→ codingDetails(rawContent) → ToolDiagnostics.stdout 50,171B ──→ 一并持久化在 canonical 里
 ├─→ SessionRuntime:1317 sidecar：payload = archive 全量 ≥ 32,768 → ECoreObjectStore.store()
 │      └─→ objects/obj_shell_big-1_<fnv>.txt = 51,090B
 │          【无 ECoreReference → Exact Restore 不可达】
 └─→ ModelToolResultProjection.project → 模型实得 4,066B（shell 分支再收窄一次）
```

### 2. P-Core → E-Core Page-Out Lifecycle

```
pressure → ContextCompactor.compact → evictionPlan
   batch unit: evidence = "tool=… arguments=… status=ok result=<JSONEncoder(ToolResult)>"
   → ECoreObjectStore.pageOut(content: "[Historical tool evidence]\n" + evidence)
   → objectID = SHA256(evidence) = obj_6a7e5149…   bytes = 68,586
        （同时含 16,384 excerpt 与 50,171 diagnostics）
   → referenceID = SHA256(session ␟ occurrence ␟ epoch) = ref_f91a39df…
   → objects/<id>.txt + references/<ref>.json（不写 .meta.json）
        → 对 listObjects / context_search 隐形
   → unitResidencies[messageID] = (.derived, derivedPageID = ref)
   → eCoreIndexProjection：source=.derivedPage, segment=.eCoreRetrievalProjection,
        ≤8 行 / ≤ min(512, hard/8) token
```

### 3. context_recall Slice / Admission Lifecycle

```
模型读 index line "reference=ref_…  summary=<140 chars>"
 → context_recall(id, offset, limit_bytes, limit_lines)
   → requestRecall(refID)                     [recallRequested → recallResolved]
   → recall(objectID, offsetBytes, limitBytes) → RecallChunk
        （marker 只在 offset 57,344 才命中）
   → slice 文本 → ToolOutputPolicy.excerpt    ⚠ 32,768 请求被截成 16,384
   → queueRecallAdmission(refID)              ⚠ offset/limit 在此丢弃；状态仅内存
 → 下一 step
   → takeRecallAdmissions → admitRequestedRecalls
     → restore(refID) → 68,586B payload        【被丢弃】
     → restored = canonicalEntries(unit) = 16,384B excerpt, segment = .recalledOccurrence
     → budget: retained + restored             ⚠ required=17,087 > hard=16,552
          → recallRejected(inputBudgetExceeded)
     → 若通过：slice 7,524B 与 occurrence 3,328B 同请求并存  ⚠ 重复
   → persistCompaction（只写 residencies；admittedPayloads 不落盘）
```

### 4. read_file Mutation / Re-read Lifecycle

```
step N batch = [read A, shell "printf NEW > A", read A]
 → readOnlySignature(read#1) = {read_file, {"path":"A"}, <abs path>}   ← 无 mtime / size / hash
 → primaryBySignature[sig] = 0
 → read#2 同签名 → primaryByIndex[2] = 0                               ⚠ 不执行
 → TaskGroup 并发派发 primary：read#1 与 shell 同时跑                  ⚠ 无 ordering barrier
 → sharedReadOutcome 复制 read#1 的 content → read#2 = "OLD"
 → publishCompletedTool → settleBatch → SessionStore 持久化 "OLD"      ⚠ stale 成历史
磁盘实为 NEW（probe03 实测）
```

---

## 四、Truth Table（>40KB ToolResult，probe01 / probe08 / probe10 实测）

| 层 | 字节 | 完整 | ID / 载体 | segment | provider-visible |
|---|---|---|---|---|---|
| raw executor output | 51,090 | ✅ | — | — | ❌ |
| ToolOutputArchive | 51,090 | ✅ | SQLite blob，`outputBlobRef` / `continuation` | — | ❌ |
| SessionStore `ToolResult.content` | **16,384** | ❌（中段丢失） | message parts | conversation | 间接 |
| SessionStore `diagnostics.stdout` | 50,171 | ✅（但在非模型字段） | 同一 message | — | ❌ |
| E-Core sidecar object | 51,090 | ✅ | `obj_shell_big-1_a87144583c1b89`（FNV generate） | — | ❌ **无 ref** |
| E-Core page-out object | 68,586 | 逻辑完整（excerpt + diagnostics 的 JSON） | `obj_6a7e5149…`（SHA256 identify） | — | 仅经 slice |
| ECoreReference | — | occurrence 指向 page-out，不指向 sidecar | `ref_f91a39df…` / `ref_1e556f25…`（同一 object，occurrence 不同） | — | index 行 |
| context_recall slice | 请求 8,192 → 8,359；请求 32,768 → **16,384** | ❌ 被 policy 二次截断 | context_recall ToolResult | conversation → admittedToolResult | ✅ |
| admitted occurrence | 3,328 / 16,384 | ❌ 从 canonical 重建 | ContextEntry | **recalledOccurrence** | ✅ |
| ModelMessage（wire 视图） | 4,066（投影后） | ❌ | — | admittedToolResult | ✅ |
| Provider wire JSON | 3,258 – 8,358 / 条 | ❌ 中间 marker 不在 | — | 三 provider | ✅ |

---

## 五、Provider Role Matrix（probe05，真实 `makeRequestBody`）

| segment | Chat Completions | Responses | Anthropic Messages |
|---|---|---|---|
| conversation | tool / assistant 通道 | 同 | messages 通道 |
| admittedToolResult | tool 通道 | tool 通道 | tool 通道 |
| retrievalData | `role:"system"` | `role:"user"` | **top-level `"system"`** |
| eCoreRetrievalProjection | `role:"system"` | `role:"user"` | **top-level `"system"`** |
| recalledOccurrence | `role:"system"` | `role:"user"` | **top-level `"system"`** |
| immutableInstructions | `role:"system"` | `role:"developer"`（instructions） | top-level `"system"` |

结论：**三者不一致，且两个把 retrieved data 放进了特权指令通道**；只有 Responses 正确降级。Anthropic 最严重（直接进 system prompt）。

---

## 六、Durability Matrix

| 状态 | in-memory | SQLite | E-Core disk |  survives restart? |
|---|---|---|---|---|
| pending recall intent | `ECoreObjectStore.pendingRecallReferences` | ❌ | ❌ | **否**（probe11 实测：admitted=0） |
| resolved recall（recallResolved 计数） | lifecycle snapshot | ❌ | ❌ | 否（仅遥测） |
| admitted residency（canonical 型） | `ContextCompactor.unitResidencies` | ✅ `compaction_state.residency_json` | — | **是**，但仅在 persist 之后（`:685 → :688` 有窗口） |
| admitted payload（E-Core-only 型） | `ContextCompactor.admittedPayloads` | ❌ 从不写 | payload 在 | **否**（probe12：1 → 0） |
| ECoreReference | `pageOutReferences` | ❌ | ✅ `references/<ref>.json` | 是（probe09：11 → 11） |
| object payload | `pageOutObjects` / `memoryPayloads` | ❌ | ✅ `objects/<id>.txt` | 是 |
| provider-visible 证明链最后一环 | — | ❌ **不存在** | — | 无从判定 |

---

## 七、修复顺序（本轮不执行）

### Phase 1 — Truth / identity（P0-1）

sidecar 全量对象必须获得 occurrence-facing reference；或让 page-out 对象以 canonical excerpt 为唯一"投影"、raw 为唯一"载荷"，二者由同一 occurrence 绑定。统一 objectID 派生口径。`admitRequestedRecalls` 改为从 E-Core 载荷重建 occurrence，而不是从 canonical excerpt。

不能碰：`ToolOutputPolicy` 上限、budget、`ECoreObjectID.identify` 冻结语义、eviction scoring。

### Phase 2 — Recall semantics（P1-1, P1-2）

引入 `RecallRequest{referenceID, requestedRange, admissionMode}`；slice 不再被通用 policy 二次截断；slice 与 admission 共享 occurrence 身份消除重复；budget 按 admissionMode 计量（sliceOnly 只计 slice）。

### Phase 3 — Durability（P0-5）

pending recall 落 SQLite（含 requestedRange / admissionMode）；`admittedPayloads` 与 residency 同事务；把 `persistCompaction` 收进 admission 提交的同一临界区，消除 `:685 → :688` 窗口。

### Phase 4 — Provider parity（P0-2）

retrieved / recalled 内容一律非特权通道：Anthropic 不得进 top-level `system`（改为带标记的 user / tool 段），Chat 不得用 `system`。建议 producer 端把 P/E 条目的 `role` 从 `.system` 改为 `.user`（或新增 `data` role），三个 adapter 各自映射到该 provider 的"数据"位置。同步修正 `Docs/AA/PE-Core-Context-Integrity-2026-10-04.md:69` 的错误描述。

红线：**不得**反向把 retrieved data 升为 system 以求"三个一致"。

### Phase 5 — Read consistency（P0-3）

`ReadOnlySignature` 有效性域限定到"自该 read 起无该 resource 的 mutation"；batch 内 read / mutation 加 ordering barrier；stale 结果不得持久化。顺带修 `read_file` 整文件路径不返回版本戳导致 `write_file` `expected_hash` 死锁（P2）。

### Phase 6 — No-progress semantics（P0-4）

按 §二-J 状态机替换 `anySuccess`。先把 HEAD 三个红测转绿。

### Phase 7 — Bounded retrieval + telemetry correctness（P1-3 / P1-4 / P1-5 / P1-6）

- `references()` 加冷启动一次目录补齐 + 内存视图 + 增量失效，消除每步全扫；
- index 候选接入 BM25 / UnifiedRetrieval，或至少引入持久 metadata 让 page-out 对 `context_search` 可见；
- region 口径由 segment 决定；
- `pageIn` / `exactRestore` 从 E→P 成功链中摘出，新增 `providerRequestContainsPayload`。

不能碰：为让 benchmark 变绿而改 benchmark expectation。

### Phase 8 — Production-path regression tests（H）

把本审计的 probe01 / 03 / 04 / 08 / 10 / 11 / 12 固化为正式回归（去掉 `AuditProbe` 命名与 print，改成断言）；要求所有 P/E recall 测试走"真实 executor → archive → SessionStore → compact → recall → wire 字节断言"，禁用 `ToolResult(content: big)` 直塞。

---

## 八、审计边界声明

- **做了什么**：读全量生产路径；写并运行 10 个诊断 probe（真 shell / 真 read_file / 真 CoreHost / 真磁盘 E-Core / 真 restart / 真 `makeRequestBody`）；跑 `ToolLoopRecoveryTests`、`PERecallContractTests` 取证。
- **没做什么**：未改任何生产代码；未改测试期望；未改 P/E 冻结语义、eviction scoring、Branch Prediction、provider wire 协议、GUI 布局、工具 schema。
- **哪些是假设**：
  1. probe 用 `startupPolicy: .unitTest` + 假 provider；真实 provider 的 cache-plan 交互未测（Phase 4 修复时需补真实 transport 层的 wire 断言）。
  2. `E`/`F` 的规模测试到 5,000 refs（100,000 因写盘成本未跑，按线性外推约 800ms/次、每步 3 次）。
  3. probe11 的 `context_recall` 通过 `ContextRecallTool.execute` 直接调用，未过 `ToolRuntime` 的 policy 层（该层的截断已由 probe10 单独取证）。
- **待主人决策的两点**
  1. Phase 1 方向：**给 sidecar raw 对象建 ref**，还是**让 admission 以 raw 为 occurrence 权威投影源**。后者更贴近 P/E 契约第一节，语义后果不同。
  2. Phase 4 里 Chat 的 retrieved 数据目标位置（`user`，还是 tool / 检索专用字段）。需要主人定口径，不擅自选 provider wire 形状。
