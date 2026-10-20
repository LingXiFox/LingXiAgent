# Phase 1.1 内部契约（冻结稿，v1）

范围：内核正确性修复。**不新增功能、不加依赖、不重构架构。**
基线：`rewrite/2.0 @ cd9fed3`，当前 30 tests / `swift build` / `swift test` 全绿。

## 0. 写作用域与协作规则

| 角色 | 允许写 |
|---|---|
| Lead | `Sources/**`、`Tests/LingXiKernelTests/Fakes.swift`、`Tests/LingXiKernelTests/{ContextTests,DurabilityTests,GatesTests,LoopTests}.swift`、`.tmp/**` |
| recovery-verifier | `Tests/LingXiKernelTests/RecoveryAcceptanceTests.swift`（新建，唯一） |
| conversation-verifier | `Tests/LingXiKernelTests/ConversationAcceptanceTests.swift`（新建，唯一） |
| ci-docs | `.github/**`、`Scripts/**`、`Docs/**` |
| adversarial-auditor（后续） | 只读仓库；在 `/tmp` 的副本里做变异，不改主工作树 |

规则：
- 验证者不改 `Sources/**`、不改既有测试、不改 `Fakes.swift`。发现内核 bug 报告给 Lead，由 Lead 修。
- 所有验证者测试**禁止固定 `Task.sleep` 等待调度**；用 `Gate`/注入时钟。唯一例外是 `Gate` 自带的 5s 兜底。
- 测试函数名必须带回归 ID（见 §4）。同一测试 target 共享命名空间：新文件里的私有 helper 一律 `private` 且加文件前缀，避免符号冲突。
- 验证者只在 Lead 宣布 “implementation frozen” 后跑 `swift build`/`swift test`（避免与 Lead 编辑并发）。之前可以写测试、读代码、评审契约。
- 不执行任何 git 写操作（commit/push/checkout），Lead 统一提交。

## 1. 冻结的公开 API 增量

### Context.swift
```swift
public enum ContextPayload {
    case text(String)
    case toolCall(requests: [ToolCall])
    case assistantMessage(text: String, requests: [ToolCall])   // 新增：工具轮里同时有文本
    case toolResult(outcomes: [ToolOutcome])
    public var toolCalls: [ToolCall]    // .toolCall 与 .assistantMessage 都返回 requests
    public var toolOutcomes: [ToolOutcome]
}

public enum ContextValidationError {
    // 既有 case 保留
    case nonPrivilegedSystemRole(index: Int)   // 新增：role == .system 但 segment 不特权 → 拒绝
}
```

### EventLog.swift
```swift
public enum RecordedEvent {
    // 既有 case 保留
    case batchStarted(RunID, BatchID, [ToolCall])   // 新增：工具执行意图先于任何副作用落盘
    public var runID: RunID   // 覆盖新 case
}

public enum EventLogError: Error {
    case undecodableLine(index: Int, reason: String)  // 保留：非末尾行损坏 → 拒绝打开
    case repairFailed(reason: String)                 // 新增：末尾修复（截断）失败
    case repairRequired                               // 新增：上次 append 失败，必须先 rollBack 才能再写
    case rollbackFailed(reason: String)               // 新增：rollBack 失败，日志不可用
    case unavailable(reason: String)                  // 新增：日志已污染，拒绝任何写入
}

public actor DurableEventLog {
    public var recordCount: Int
    public private(set) var repairedTailRecordCount: Int   // 新进程打开时被丢弃的损坏尾行数
    public var isUsable: Bool                              // 新进程：false = rollback 失败后不可再用
    public init(sink: any EventLogSink) throws             // 打开时：末尾坏行截断并计数；非末尾坏行 throw
    public func beginMarker() -> Int
    @discardableResult public func append(_ event: RecordedEvent) throws -> Int
    public func rollBack(to marker: Int) throws
    public func events() throws -> [RecordedEvent]
    // append 失败后：needsRepair 状态，除 rollBack 外一律 throw .repairRequired；
    // rollBack 失败后：throw .rollbackFailed，之后 append 一律 throw .unavailable。
}
```

### Recovery.swift（新文件）
```swift
public struct RecoveryReport: Sendable {
    public let eventsReplayed: Int
    public let sessionCount: Int
    public let restoredRunCount: Int
    public let failedRunIDs: [RunID]
    public let executionStateUnknownRunIDs: [RunID]
    public let synthesizedResultEntryCount: Int
    public let repairedTailRecordCount: Int
}

public struct RecoveredKernel: Sendable {
    public let runs: RunRegistry
    public let store: SessionStore
    public let report: RecoveryReport
}

public enum KernelRecovery {
    /// 只读重放 + 重建全新内存对象；唯一写入是给未终态 Run 追加 runTerminal 失败记录。
    public static func recover(log: DurableEventLog) async throws -> RecoveredKernel
}
```

恢复策略（可验证、按序）：
1. 打开日志时只允许**末尾**一行坏数据：截断并 `repairedTailRecordCount += 1`；非末尾坏行 → throw `.undecodableLine`。
2. 重放 `runCreated/runStarted/entryRecorded/batchStarted/batchSettled/batchConsumed/runTerminal`，用 `SessionStore.append`（含 User 降级规则）与 `RunRegistry` 内部 restore 重建。
3. 批次对账（历史自愈，仅内存，确定性）：
   - `batchSettled` 有、但对应 `entryRecorded(result-<batch>)` 缺失 → 用 settled outcomes 合成结果条目并插到 call 条目之后。
   - `batchStarted` 有、`batchSettled` 缺 → **执行状态不确定**：合成 isError=true、effect=.unknown 的结果条目（内容含 `executionStateUnknown` 与 verification 要求），Run 记入 `executionStateUnknownRunIDs`，绝不重放。
   - 有 call 条目（unit=batchID）但无任何 batch 事件 → 崩溃发生在派发前，合成“未开始执行”错误结果，不记 unknown。
4. 未终态 Run 一律 `terminalize(failed)`：有未结算批次 → cause `.executionStateUnknown`；否则 cause `.runtimeFailure`。detail 含 “recovered after restart”。
5. 恢复过程中绝不调用 ToolExecutor、绝不重发模型请求。
6. 重放两遍结果必须一致（幂等）。

### RunState.swift
```swift
public enum TerminalCause {
    // 既有 case 保留
    case outputTruncated
    case contentFiltered
    case refused
    case executionStateUnknown
    case concurrentRunRejected
}

public enum RunAdmissionError: Error, Equatable {
    case duplicateRun(RunID)
    case sessionHasActiveRun(session: SessionID, active: RunID)
}

public actor RunRegistry {
    public func create(id:sessionID:turnID:) throws          // 同 Session 已有非终态 Run → throw sessionHasActiveRun
    public func markRunning(_:) throws
    public func record(_:) -> RunRecord?
    public var openRunIDs: [RunID]
    public func activeRun(for sessionID: SessionID) -> RunID?
    public func discard(_ id: RunID)                        // begin 事务失败时清除内存记录
    @discardableResult public func terminalize(...) async throws -> Bool
    @discardableResult public func recoverUnfinishedRuns(via:) async throws -> [RunID]  // 保留
}

public actor SessionStore {
    public func entries(for:) -> [SessionID: [ContextEntry]] // 语义不变
    public func append(_ entry: ContextEntry, to sessionID: SessionID)
    // 规则：append 的条目 segment == .currentUser 时，先把该 session 已有 .currentUser 条目降级为 .history，
    //       再追加。重放与实时共用同一规则，因此重放结果 = 实时内存状态。
    public func sessionIDs() -> [SessionID]
}
```

### Clock.swift
```swift
public protocol MonotonicClock: Sendable {
    func now() -> Duration
    func sleep(for duration: Duration) async throws   // 新增；默认 Task.sleep(for:)
}
```

## 2. AgentLoop 行为契约

1. **启动预检**：`run()` 在写任何事件前 `router.resolve(model:)`。失败 → `RunResult(status: .failed, cause: .runtimeFailure, detail: guidance, terminalCommitted: false)`，日志 0 记录、RunRegistry 无记录、store 不变。
2. **准入**：`runs.create` 抛 `sessionHasActiveRun` → `.failed / .concurrentRunRejected`，无日志写入；抛 duplicateRun → `.failed / .runtimeFailure`。
3. **begin 事务**：`runCreated + runStarted + user entry` 一次事务。事务失败 → rollBack；内存记录 `discard`；返回 failed、`terminalCommitted == false`，**绝不补写孤立 runTerminal**。
4. **Assistant 持久化**（LOOP-024）：
   - 工具轮：assistant 文本与工具调用写为**同一个** `entryRecorded`（`.assistantMessage`，unit=batchID；文本为空时用 `.toolCall`）。
   - 正常完成：最终 assistant 文本写为 `.text` 条目（role .assistant，segment .history）。
   - `.maxTokens` 截断时已产出的文本同样写入；contentFilter/refusal 不写入。
   - 顺序：先事件落盘，再进 store。
5. **终态分类**（LOOP-022）：
   | stopReason | status | cause |
   |---|---|---|
   | `.stop`，有文本 | completed | completedWithText |
   | `.stop`，无文本 | completed | completedWithEmptyText |
   | `.maxTokens` | failed | outputTruncated |
   | `.contentFilter` | failed | contentFiltered |
   | `.refusal` | failed | refused |
   | `.unknown` | failed | streamProtocolViolation |
6. **阻塞流约束**（LOOP-023）：Provider 的 `stream()` 调用与流消费整体放进可竞争的任务；watchdog 用注入时钟 `sleep` 到剩余总超时。取消/超时先被观察到 → `.cancelled/.cancelledByUser` 或 `.deadlineExceeded/.deadlineExceeded`，**丢弃迟到事件，不伪造 provider 失败**。终态事件（completed/failed）一旦被内核处理即胜出；之后到达的取消不再改写终态。usage 已收到部分照常汇总。
7. **预算**（CTX-018）：
   - `plan.highWater = preferred*1.15`、`lowWater = preferred*0.8` 语义不变；
   - 引用行 segment `.derivedPage`、role **.user**（不得 system）；
   - 引用行 token 计入 `BudgetPlan.estimatedTokens` 与 hard limit；若计入后超 hard → 先继续淘汰；仍超 → `BudgetError`；
   - `plan.selected` 必须再过一次 `ContextRequestValidator`，失败 → `.failed / .streamProtocolViolation`。
8. **usage 汇总**（CACHE-007）：同 Run 跨 Step 对每个字段做“非 nil 求和”；全缺 → nil；出现 0 → 0 计入。
9. **会话历史**（CTX-017）：只有当前 Run 的 user 条目是 `.currentUser`（mandatory），之前轮 user 全部 `.history`。

## 3. 测试夹具（Lead 在 Fakes.swift 提供，冻结签名）

```swift
// 既有：Gate / ScriptedProvider / RecordingExecutor / MemorySink / ManualClock /
//       registerEchoTool / makeCall / completed / toolBatch / newRunID / GatingExecutor / makeLoop / runRequest

// 新增/扩展：
// MemorySink: var failOnTruncate: Bool；truncate 失败抛 EventSinkFault.truncateFailed
// ManualClock: 实现 MonotonicClock.sleep(for:)（advance 到 deadline 时恢复；Task 取消时抛 CancellationError）
// BlockingStreamProvider:
//   init(terminalEvents: [ModelEvent], capabilities: ModelCapabilities = ...)
//   let arrival = Gate()      // stream() 被调用时 fire
//   let release = Gate()      // 测试打开后，terminalEvents 才被投递
//   行为：记录 request；fire arrival；返回的流先 yield .started，然后等待 release，
//         再 yield terminalEvents 并 finish。requestCount/request(at:) 可用。
```

## 4. 回归 ID 映射（测试函数名必须带 ID）

| ID | 场景 | 归属 |
|---|---|---|
| LOOP-021 | 同 Session 已有 active Run 时第二个 Run 被拒，无日志污染；不同 Session 可并发 | conversation-verifier |
| LOOP-022 | maxTokens/contentFilter/refusal 不得报 completed，cause 各自明确 | conversation-verifier |
| LOOP-023 | 阻塞流上的取消与总超时；终态优先级；迟到事件丢弃且不伪造失败 | conversation-verifier |
| LOOP-024 | Assistant 文本（含工具轮）写入事件日志与 SessionStore，跨 Turn 可见 | conversation-verifier |
| LOOP-025 | 崩溃恢复不重放写操作；未知执行状态标 executionStateUnknown | recovery-verifier |
| STORE-008 | 事件日志全量重放重建全新 SessionStore/RunRegistry | recovery-verifier |
| STORE-009 | 尾部损坏修复、中部损坏拒载、回滚失败、append 失败→rollback 修复 | recovery-verifier |
| STORE-010 | begin() 事务失败不留孤立终态记录 | recovery-verifier |
| CTX-017 | 历史 User 降级 .history，仅当前 User mandatory | conversation-verifier |
| CTX-018 | 预算裁剪后重新协议校验；引用行计入预算且非 system role | conversation-verifier |
| CACHE-007 | 跨 Step usage 汇总保留缺失与零值区别 | conversation-verifier |
| QA-013 | 无 Provider 启动/运行不污染会话日志，只报告引导 | conversation-verifier |

既有 ID（LOOP-001..007/012/013、CTX-001..014、PROV-001、STORE-001、DEADLINE）继续有效，语义以本契约为准。

## 5. 验收测试文件

- `RecoveryAcceptanceTests.swift`（recovery-verifier）：
  STORE-008/009/010 + LOOP-025 + 完整重放幂等 + 恢复期间 executor 调用次数为 0 + 新进程对象不复用旧 Registry/Store。
- `ConversationAcceptanceTests.swift`（conversation-verifier）：
  LOOP-021..024、CTX-017/018、CACHE-007、QA-013；必须用真实 `AgentLoop` 连续多 Turn 跑（禁止手工拼 ContextEntry 直塞内核来断言历史）。
- Lead 侧既有文件：更新受影响的旧测试 + 崩溃恢复/事务/日志硬化单元测试。

## 6. 反例验收

需要“注入旧 bug → 测试变红”的证据（adversarial-auditor 在 `/tmp` 副本执行）：
1. 删除 assistant 落盘 → LOOP-024 红。
2. 关闭 User 降级 → CTX-017 红。
3. 去掉 Session 并发门禁 → LOOP-021 红。
4. 终态统一按 completed 处理 → LOOP-022 红。
5. 取消不竞争、阻塞流无限等待 → LOOP-023 红/挂。
6. 关闭恢复重建或重放时执行工具 → STORE-008/LOOP-025 红。
7. 尾部坏行直接报错而非截断 → STORE-009 红。
8. begin 失败仍写 runTerminal → STORE-010 红。
9. usage 首值覆盖 → CACHE-007 红。
10. 无 Provider 仍写日志 → QA-013 红。
11. 引用行 role=system 或不计预算 → CTX-018 红。
