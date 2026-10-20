# Phase 1.1 验收记录：内核正确性收口

> **状态：已验收 —— 内核、测试与变异审计已收口（代码 HEAD `677d44e`，89 tests 全绿 ×5；变异 11/11 RED 明细已归档）；CI run `39361419757` 在 `macos-26` 上 success（第六节），空核启动检查在 CI 与本地双双通过（第七节）。**
> Phase 1.1 的关键正确性问题全部验收通过，可进入 Phase 2。残余风险见第八节，其中第 1 条（`endExecution` 未接线）必须在 Phase 1.2 接入 Provider 插件前处理。
> 依据：`Docs/Validation/Phase-1.1-contract.md`（冻结稿 v1，原稿在 gitignored 的 `.tmp/`，已按字节归档，sha256 `bee6f2d8f41eadaae1908c4e7a24c23daf464896aeed8d7789fc8e4c5ac9cf48`）；判定口径：`Docs/Testing-and-Acceptance.md`（实测数字 + trace 顺序 + 反例，缺一不算通过）。

## 一、范围与基线

| 项 | 值 |
|---|---|
| 基线 commit | `cd9fed3`（分支 `rewrite/2.0`） |
| 最终代码/测试 HEAD | `677d44e`（`fix(kernel): heal a dangling tool batch in-process and never persist duplicate calls`）；其后的 `34c834a`（Docs + `.github/workflows/ci.yml`）与 `719d3f1`（契约归档）为纯文档/CI 提交，未改动 `Sources/**` 与 `Tests/**` |
| CI head SHA（实跑提交） | `719d3f16aed4d5340e51759b33314ad13b12d04c`（远端 `origin/rewrite/2.0`，由 `cd9fed3` fast-forward 10 个提交） |
| 基线测试数 | 30（契约 §0） |
| 范围 | 内核正确性修复：不新增功能、不加依赖、不重构架构 |
| 验收命令 | `swift build --build-tests`；`swift test`；空核启动检查（第七节） |
| 本地环境 | macOS 27.2（Apple Silicon）；Xcode 27.2（Build 27B48）；Swift 6.4.2（swiftlang-6.4.2.1.9） |
| 验收文件 sha256（`118263f`，至 `677d44e` 未变） | `ConversationAcceptanceTests.swift`：`df5fb3435df40c0de37400c6e6204a5d9ff321ef7964af8ec2fe0809155be92c`；`RecoveryAcceptanceTests.swift`：`62c98d217f3d2dd064f1d836a023837ced2fe830d786bb0c3090b7a1d3e4f424` |

代码基线演进（全部已在 HEAD 祖先链上）：`cd9fed3`（基线）→ `6c6cb28`（Phase 1.1 修复，50 tests）→ `4276281`（预算为容纳引用行继续淘汰后重算引用行，Lead 侧 51）→ `45abeb5`（仅 `Recovery.swift` 注释）→ `118263f`（两个独立验收文件）→ `c8634ab`（删除无调用方的 `SessionStore.replaceAll`）→ `70847ca`（mutation 审计缺口关闭，87 tests）→ `da61865`（测试断言加强，仍 87）→ `677d44e`（进程内悬空批次自愈 + duplicate-call 预校验，89 tests，最终 HEAD）。

## 二、基线 vs 终态测试计数

| 阶段 | commit | 测试用例数 | 结果 | 证据 |
|---|---|---|---|---|
| 基线 | `cd9fed3` | 30 | 全绿 | 契约 §0 |
| 内核 / Lead 侧测试冻结 | `6c6cb28` | 50 | 全绿 | Lead 本地 `swift test`（2026-10-20） |
| 预算引用行修复 | `4276281` | 51（Lead 侧 +1 CTX-018） | 全绿 | Lead 本地 `swift test` |
| 两个独立验收文件落地 | `118263f` | 80 = 51 + 16 + 13 | 全绿 ×5 | Lead 实测 |
| mutation 审计缺口关闭 | `70847ca` | 87 = 58 + 16 + 13 | 全绿 ×5 | Lead 实测 |
| 测试断言加强 | `da61865` | 87（用例数不变） | 全绿 ×5 | Lead 实测 |
| **终态** | **`677d44e`** | **89 = 60 + 16 + 13** | **全绿 ×5（0.021–0.024s/次）** | Lead 权威 inventory（2026-10-20） |
| 文件分布 | — | Lead 侧 60：`ContextTests` 13 / `DurabilityTests` 15 / `GatesTests` 6 / `LoopTests` 26；验收 29：`ConversationAcceptanceTests` 16 / `RecoveryAcceptanceTests` 13 | 全绿 | Lead 权威 inventory |
| `swift test` 汇总行（本地） | — | `Test run with 89 tests in 0 suites passed after 0.021 seconds.` | 通过 | Lead 本地 `677d44e` 5 连跑；本轮复跑 0.020s |
| `swift test` 汇总行（CI） | `719d3f1`（代码树与 `677d44e` 逐字节一致） | `✔ Test run with 89 tests in 0 suites passed after 0.074 seconds.` | 通过 | run `39361419757`，`macos-26`，Swift 6.3.3（第六节） |

测试函数名必须带回归 ID（`Project-Conventions.md` 第六章）。下表按「Lead 侧冻结清单」与「独立验收文件」分列：两者都通过才算该 ID 有独立证据。注：STORE-010 在两个文件里的函数名不同（Lead 侧 `STORE_010_beginFailureLeavesNoOrphanTerminal`、验收文件 `STORE_010_beginTransactionFailureLeavesNoOrphanTerminal`），是两个独立测试，均需为绿。

## 三、逐 ID 证据表

### 3.1 Phase 1.1 新增条目

| ID | Lead 侧证据（`677d44e`） | 文件 | 独立验收文件证据（已全绿） | 状态 |
|---|---|---|---|---|
| LOOP-021 | `LOOP_021_secondRunOnActiveSessionRejected`、`LOOP_021_differentSessionsMayRunConcurrently`、`LOOP_021_duplicateRunIDRejected` | `LoopTests.swift` | `LOOP_021_secondRunRejectedWithoutJournalWrites`、`LOOP_021_differentSessionsRunConcurrently`（`ConversationAcceptanceTests.swift`） | 通过 |
| LOOP-022 | `LOOP_022_incompleteOutcomes` | `LoopTests.swift` | `LOOP_022_incompleteStopReasonsClassified`（`ConversationAcceptanceTests.swift`） | 通过 |
| LOOP-023 | `LOOP_023_cancelWhileStreamBlocked`、`LOOP_023_blockedStreamTimeout` | `LoopTests.swift` | `LOOP_023_cancelWinsOverBlockedStream`、`LOOP_023_deadlineWinsOverBlockedStream`、`LOOP_023_providerFailureDeliveredAfterBlockedStream`（`ConversationAcceptanceTests.swift`） | 通过 |
| LOOP-024 | `LOOP_024_threeTurnsKeepHistory`、`LOOP_024_toolRoundKeepsAssistantText` | `LoopTests.swift` | `LOOP_024_historyAcrossThreeTurns`、`LOOP_024_toolRoundKeepsAssistantTextAndCalls`、`LOOP_024_truncatedTextPersisted`（`ConversationAcceptanceTests.swift`） | 通过 |
| LOOP-025 | `LOOP_025_recoveryNeverReplaysUnknownBatch`、`LOOP_025_danglingBatchHealedInProcess` | `DurabilityTests.swift` | `LOOP_025_settledMutatingBatchIsNotReplayedByRecovery`、`LOOP_025_openBatchHealsAsExecutionStateUnknown`、`LOOP_025_callWithoutDispatchHealsAsNotStarted`、`LOOP_025_settledUnconsumedBatchLosesNoResults`、`LOOP_025_settledBatchMissingResultRecordIsHealed`、`LOOP_025_doubleReplayIsIdempotentAndSideEffectFree`（`RecoveryAcceptanceTests.swift`） | 通过 |
| STORE-008 | `STORE_008_replayRebuildsFreshObjects` | `DurabilityTests.swift` | `STORE_008_fullReplayRebuildsFreshKernel`（`RecoveryAcceptanceTests.swift`） | 通过 |
| STORE-009 | `STORE_009_tornTailIsRepaired`、`STORE_009_middleCorruptionRefused`、`STORE_009_appendFailureRequiresRollback`、`STORE_009_rollbackFailurePoisonsJournal` | `DurabilityTests.swift` | `STORE_009_tailCorruptionIsRepairedOnOpen`、`STORE_009_nonTailCorruptionRefusesToOpen`、`STORE_009_appendFailureRequiresRepairRollback`、`STORE_009_rollbackFailurePoisonsTheJournal`、`STORE_009_tailRepairFailureSurfacesAsRepairFailed`（`RecoveryAcceptanceTests.swift`） | 通过 |
| STORE-010 | `STORE_010_beginFailureLeavesNoOrphanTerminal`、`STORE_010_beginRollbackFailureIsReported` | `DurabilityTests.swift` | `STORE_010_beginTransactionFailureLeavesNoOrphanTerminal`（`RecoveryAcceptanceTests.swift`） | 通过 |
| CTX-017 | `CTX_017_previousUserTurnsAreDemoted` | `ContextTests.swift` | `CTX_017_onlyCurrentUserIsMandatory`（`ConversationAcceptanceTests.swift`） | 通过 |
| CTX-018 | `CTX_018_nonPrivilegedSystemRoleRejected`、`CTX_018_referenceIsCountedAndNonPrivileged`、`CTX_018_referenceOverHardLimit`、`CTX_018_longConversationTrimsHistory`、`CTX_018_referenceListsAllEvictedIDs`、`CTX_018_postBudgetValidationGatePresent` | `ContextTests.swift`、`LoopTests.swift`、`GatesTests.swift` | `CTX_018_budgetTrimKeepsRequestValid`、`CTX_018_referenceCountsTowardHardLimit`（`ConversationAcceptanceTests.swift`） | 通过 |
| CACHE-007 | `CACHE_007_usageAccumulatesAcrossSteps`、`CACHE_007_allNilUsageStaysAbsent` | `LoopTests.swift` | `CACHE_007_usageSummedAcrossSteps`、`CACHE_007_absentUsageStaysNil`（`ConversationAcceptanceTests.swift`） | 通过 |
| QA-013 | `QA_013_emptyCoreDoesNotPolluteJournal`、`QA_013_modelNotOfferedGuidance` | `GatesTests.swift`、`LoopTests.swift` | `QA_013_noProviderWritesNothing`（`ConversationAcceptanceTests.swift`）；CI 空核步骤见第六、七节 | 通过 |

### 3.2 受 Phase 1.1 加固影响的既有条目

| ID | 测试函数名 | 文件 | 加固点 | 状态 |
|---|---|---|---|---|
| LOOP-001 | `LOOP_001_singleTerminalizationWinner`、`LOOP_001_concurrentTerminalizationWinner` | `DurabilityTests.swift` | 终态化赢家语义（取消 vs 完成） | 通过 |
| LOOP-002 | `LOOP_002_terminalWriteFailureRollsBack` | `DurabilityTests.swift` | append 失败 → `repairRequired` → rollBack 修复状态机 | 通过 |
| LOOP-003 | `LOOP_003_crashRecovery` | `DurabilityTests.swift` | 由 `KernelRecovery` 全量重放承担（STORE-008/LOOP-025） | 通过 |
| LOOP-004 | `LOOP_004_runCreatedExactlyOnce` | `DurabilityTests.swift` | begin 三记录单事务（STORE-010） | 通过 |
| LOOP-005 | `LOOP_005_orderedSettle`、`LOOP_005_duplicateCallIDRejectsBatch`、`LOOP_005_duplicateCallIDDoesNotPoisonHistory` | `LoopTests.swift` | `batchStarted` 意图先于任何副作用落盘；重复 callID 在持久化前整批拒绝 | 通过 |
| LOOP-006 | `LOOP_006_providerFailureSurvives`、`LOOP_006_providerCancellationIsProviderFailure` | `LoopTests.swift` | 阻塞流下的终态优先级；provider 自身 `CancellationError` 归 `.providerFailure`，不冒充用户取消 | 通过 |
| LOOP-007 | `LOOP_007_cancelAfterSettled` | `LoopTests.swift` | 阻塞流取消竞争（LOOP-023） | 通过 |
| STORE-001 | `STORE_001_durableBeforeMemory`、`STORE_001_fileJournalRoundTrip` | `DurabilityTests.swift` | append 失败→修复状态机（STORE-009） | 通过 |

独立验收文件对既有条目的补充：`ConversationAcceptanceTests.swift` 的 `LOOP_001_concurrentTerminalizationHasOneWinner` 覆盖同一 Session 下并发终态化的赢家语义。

### 3.3 mutation 审计缺口关闭新增用例（commit `70847ca`）

| 测试函数名 | 文件 | 关闭的缺口 |
|---|---|---|
| `CTX_018_postBudgetValidationGatePresent` | `GatesTests.swift` | S2：删除"预算裁剪后再过协议校验"会让原套件全绿，新增结构性门禁 |
| `STORE_010_beginRollbackFailureIsReported` | `DurabilityTests.swift` | begin 事务 rollBack 失败路径无测试 |
| `LOOP_012_budgetExceeded` | `LoopTests.swift` | 步边界上的预算耗尽终态 |
| `QA_013_modelNotOfferedGuidance` | `LoopTests.swift` | 无模型可用的引导路径（QA-013 扩展） |
| `LOOP_021_duplicateRunIDRejected` | `LoopTests.swift` | 重复 RunID 准入拒绝（LOOP-021 扩展） |
| `DEADLINE_stepBoundaryCheck` | `LoopTests.swift` | 步边界的总超时检查 |
| `LOOP_006_providerCancellationIsProviderFailure` | `LoopTests.swift` | provider 自身 `CancellationError` 的终态分类（行为变更，见 LOOP-006） |

### 3.4 独立审计之外的收口修复（commit `677d44e`）

这两条修复不在 11 条变异矩阵内（矩阵冻结于 `70847ca` 基线），由后续独立复核发现，随 `677d44e` 一并冻结：

| 修复 | 缺陷后果 | 测试函数名 | 文件 | 状态 |
|---|---|---|---|---|
| provider 重复 callID 批次在**持久化前**拒绝 | 原实现先落 call 条目再被 `ToolBatchRunner` 拒绝，非法条目永久留存，后续每个请求都过不了协议校验 | `LOOP_005_duplicateCallIDDoesNotPoisonHistory` | `LoopTests.swift` | 通过 |
| 进程内悬空工具批次在**下一次 Run 装配前**按日志确定性自愈 | Run 在 call 条目落盘后、result 落盘前失败时，下一次 Run 会在非法历史上重复失败；现在 settled 恢复结果 / started-未 settled 记 `executionStateUnknown` / 未派发记 not started，只改内存，重启重放等价 | `LOOP_025_danglingBatchHealedInProcess` | `LoopTests.swift` | 通过 |

## 四、反例（变异）验证表

按契约 §6 执行：由 adversarial-auditor 在 `/tmp` worktree 副本里注入旧 bug，主工作树零污染；在代码基线 `70847ca` 复跑（其后 `da61865` 仅加强断言，`677d44e` 为审计之外的收口修复，见 3.4）。每条要求「指定测试变红」（LOOP-023 允许表现为挂起/超时）；「测试仍绿」即反例验证失败——S2 是唯一例外，它的定位就是关闭"原套件全绿"的覆盖缺口，因此以新增结构性门禁的 RED 作为通过标准。

**结论：11/11 契约反例全部 RED，无坏 GREEN；额外审计发现 S2 覆盖缺口并由新增门禁关闭，M12 证明 `4276281` 的引用行重算修复是真 bug 修复（非测试过拟合）。**

| # | 注入的旧 bug | 期望变红的测试 | 结果 |
|---|---|---|---|
| 1 | 删除 `.stop` 时 assistant 条目落盘 | `LOOP_024_threeTurnsKeepHistory` | RED（历史 ids/segments 缺失） |
| 2 | 删除 `currentUser→history` 降级 | `CTX_017_previousUserTurnsAreDemoted`、`LOOP_024_threeTurnsKeepHistory` | RED both |
| 3 | 删除同 Session active Run 门禁 | `LOOP_021_secondRunOnActiveSessionRejected` | RED（第二次 Run 被放行并写日志） |
| 4 | 所有 stopReason 折叠成 completed | `LOOP_022_incompleteOutcomes` | RED（3 类终态全部错报） |
| 5 | 去掉阻塞流取消/看门狗竞争，改回直接 for-await | `LOOP_023_cancelWhileStreamBlocked`、`LOOP_023_blockedStreamTimeout` | RED both（60s 超时未触发） |
| 6a | 删除 unknown 标记 | `LOOP_025_recoveryNeverReplaysUnknownBatch` | RED（3 断言） |
| 6b | 删除 started-未 settled 自愈 | `LOOP_025_recoveryNeverReplaysUnknownBatch` | RED（4 断言，含合成结果缺失） |
| 7 | 尾部损坏改为直接抛错而非截断 | `STORE_009_tornTailIsRepaired` | RED（`undecodableLine index=2`） |
| 8 | begin 失败仍写孤立 `runTerminal`、不 `discard` | `STORE_010_beginFailureLeavesNoOrphanTerminal` | RED（5 断言） |
| 9 | usage 改回首值覆盖 | `CACHE_007_usageAccumulatesAcrossSteps` | RED（100≠120、5≠12） |
| 10 | 删除 provider 预检 | `QA_013_emptyCoreDoesNotPolluteJournal` | RED（journal 4 条、run/store 污染） |
| 11 | 引用行 role=system + 不计 token | `CTX_018_referenceIsCountedAndNonPrivileged`、`CTX_018_longConversationTrimsHistory` | RED both（后者被预算后复校验拦下） |
| S1 | 删除 validator 的 `nonPrivilegedSystemRole` 规则 | `CTX_018_nonPrivilegedSystemRoleRejected` | RED |
| S2 | 删除预算后协议复校验块（原覆盖缺口） | `CTX_018_postBudgetValidationGatePresent`（`70847ca` 新增结构性门禁） | **RED（缺口已关闭）**；`CTX_018_longConversationTrimsHistory` 仍 GREEN（符合"结构性防线"定位） |
| M12 | 回滚 `4276281` 的引用行重算修复 | `CTX_018_referenceListsAllEvictedIDs` | RED（其余 CTX-018 仍 GREEN → 真 bug 修复证据） |

说明：明细 diff 与命令在 `/tmp/lxj-mutation-*` worktree 中执行后回收；主工作树未接受任何变异。

## 五、D3 前提验证（事件日志是否保留）

判定问题：追加式事件日志（D3）能否在阶段 1 满足"可靠一致性"要求，从而保留而不替换存储引擎（SQLite 等）。

| 要求 | 证据 |
|---|---|
| 单一终态赢家 | `LOOP_001_singleTerminalizationWinner`、`LOOP_001_concurrentTerminalizationWinner`、`LOOP_001_concurrentTerminalizationHasOneWinner` |
| 终态先落盘、再改内存；写失败回滚 | `STORE_001_durableBeforeMemory`、`STORE_001_fileJournalRoundTrip`、`LOOP_002_terminalWriteFailureRollsBack` |
| 多记录提交（marker + 失败截断/回滚） | `STORE_009_appendFailureRequiresRollback`、`STORE_009_rollbackFailurePoisonsJournal`、`STORE_010_beginFailureLeavesNoOrphanTerminal`、`STORE_010_beginRollbackFailureIsReported` |
| 副作用前持久化意图（`batchStarted` WAL） | `LOOP_025_settledMutatingBatchIsNotReplayedByRecovery`、`LOOP_025_openBatchHealsAsExecutionStateUnknown`、`LOOP_025_callWithoutDispatchHealsAsNotStarted` |
| 进程内自愈与重启重放等价 | `LOOP_025_danglingBatchHealedInProcess`、`LOOP_025_doubleReplayIsIdempotentAndSideEffectFree` |
| 尾部损坏的可验证修复策略 | `STORE_009_tornTailIsRepaired`、`STORE_009_tailCorruptionIsRepairedOnOpen`、`STORE_009_nonTailCorruptionRefusesToOpen`、`STORE_009_tailRepairFailureSurfacesAsRepairFailed` |
| 重放确定性且幂等 | `STORE_008_replayRebuildsFreshObjects`、`STORE_008_fullReplayRebuildsFreshKernel`、`LOOP_025_doubleReplayIsIdempotentAndSideEffectFree` |
| 反例强度 | 变异 11/11 RED（第四节）；引用行重算修复由 M12 单独证明 |

**结论：保留追加式事件日志，不替换存储引擎。** D3 在阶段 1 范围内成立，不需要为换存储单独开 ADR。物理掉电/`fsync` 语义无法在单测层证明，作为残余风险列入第八节；若阶段 2 引入外部能力调用后出现事件日志无法满足的事务性需求，按 `Kernel-Design.md` D3 条款重新评估。

## 六、CI 记录

| 项 | 值 |
|---|---|
| workflow | `.github/workflows/ci.yml`（`runs-on: macos-26`，单 job，仅 `actions/checkout` + `actions/cache`） |
| 触发事件 | push 到 `rewrite/2.0`（`workflow_dispatch` 与 PR→`main` 同样触发） |
| 代码基线 SHA | `677d44e`（最终内核 + 测试 HEAD，CI 跑的树与它逐字节一致） |
| 测试提交 SHA（两个验收文件） | `118263f` |
| CI head SHA（含 Docs 与 workflow） | `719d3f16aed4d5340e51759b33314ad13b12d04c`（`docs(validation): archive the frozen Phase 1.1 contract in-repo`） |
| Run ID | `39361419757`（attempt 1，`event: push`，`headBranch: rewrite/2.0`） |
| Run URL | https://github.com/LingXiFox/LingXiAgent/actions/runs/39361419757 |
| Conclusion | **success** — job `macOS 26 (arm64) build & test` completed，10/10 步骤全 success（Set up job / Check out / Select newest Xcode / Cache SwiftPM / Build products and tests / Run tests / Empty core … / Post Cache / Post Check out / Complete job） |
| 用时 | 2026-10-20T02:54:21Z → 02:55:52Z（91s 端到端）；工具自报 `swift build --build-tests` 49.40s、test run 0.074s |
| runner | GitHub Actions 托管 `macos-26`（arm64），runner id `1000000898` |
| 空核启动步骤 | **success** — 日志实测：`providers:      0`、`No inference was attempted; nothing was added to the journal.`、`empty-core startup clean: guidance printed, no journal records`；`events.jsonl` 非空即 `exit 1` 的断言未触发 |
| runner 工具链 | `xcode: /Applications/Xcode_26.6.0.app`；`Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)`；`Target: arm64-apple-macosx26.0` |
| `swift test` 汇总行（CI） | `✔ Test run with 89 tests in 0 suites passed after 0.074 seconds.` — 与本地 89 用例数一致 |

> **命名提示**：本分支的 `.github/workflows/ci.yml` 与 `main` 上 1.x 的 `CI Matrix Gate` 是同一个文件路径，因此 GitHub 沿用该 workflow 身份（id `360644161`）在默认分支上的显示名「CI Matrix Gate」；实跑 job 名 `macOS 26 (arm64) build & test` 与步骤序列均来自 `rewrite/2.0` 自己那份文件（1.x 的 job 名为 `macOS Build & Test (arm64)`，且带 linux/windows job，本 run 没有）。核查时用 job 名与步骤名对齐，不要只看 workflow 显示名。

说明：1.x 的 `CI Matrix Gate` 只存在于 `main` 分支的历史工作流中；`rewrite/2.0` 维护自己的最小 `CI` workflow，不修改 1.x 工作流。本 run 记录以纯文档提交（`[skip ci]`，符合 `Project-Conventions.md` 第七章）补入，不影响首次 run 的证据效力。

## 七、空核启动检查（QA-013）

```bash
swift build --build-tests
DATA_DIR="$(mktemp -d)"
OUT="$(LINGXI_DATA_DIR="$DATA_DIR" .build/debug/LingXiCoreHost)"
printf '%s\n' "$OUT"
test ! -s "$DATA_DIR/events.jsonl"
```

判定：

1. 输出包含 `providers: 0`、provider 配置引导文案，以及 `No inference was attempted`（宿主自证本次启动未写日志）；
2. `events.jsonl` 不存在或大小为 0（空日志重放不得追加任何记录）；
3. RunRegistry 无 Run 记录、SessionStore 不变、`RunResult.terminalCommitted == false`（单元层由 `QA_013_emptyCoreDoesNotPolluteJournal`（`GatesTests`）与 `QA_013_modelNotOfferedGuidance`（`LoopTests`）覆盖）。

本地实测（2026-10-20，frozen HEAD `677d44e` 构建产物，Xcode 27.2 / Swift 6.4.2）：**通过**。`.build/debug/LingXiCoreHost` 退出码 0，数据目录内无 `events.jsonl`，输出：

```
LingXiAgent 2.0 core host
  providers:      0
  models:
  tools:          0
  journal:        0 records, repaired tail: 0
  recovered runs: 0, failed: 0, unknown execution: 0
No provider plugin is active. Install and enable a provider plugin to start a conversation; the core runs without one.
No inference was attempted; nothing was added to the journal.
```

CI 上的复跑结果（run `39361419757`，head SHA `719d3f1`，Swift 6.3.3 / Xcode 26.6.0）：**通过**。步骤 `Empty core starts without a provider and writes no journal records` 结论 success，日志含 `providers:      0`、`No provider plugin is active. Install and enable a provider plugin to start a conversation; the core runs without one.`、`No inference was attempted; nothing was added to the journal.` 与 `empty-core startup clean: guidance printed, no journal records`；journal 非空即 `exit 1` 的断言未触发。CI 与本地用不同工具链（6.3.3 vs 6.4.2）得到同一结果，见第八节第 14 条。

## 八、未覆盖与风险（诚实记录）

### 8.1 后续阶段必须处理

1. **Medium：`ModelProvider.endExecution(_:)` 内核从未调用**（`Model.swift:152`，`Kernel-Design.md` 第十一章）。Phase 1.2 接入 Provider 插件前必须接线，否则 provider 每个执行态没有清理。
2. **Low-Med：恢复时追加 `runTerminal` 的持久化失败会直接抛出**（宿主 `exit 1`）——fail-closed 正确，但没有自动恢复/重试记录；恢复失败后的日志状态需要可诊断。
3. **Low：两个恢复入口并存**：`RunRegistry.recoverUnfinishedRuns`（旧，LOOP-003 使用）与 `KernelRecovery.recover`（宿主使用）；旧入口没有 `executionStateUnknown` 语义，Phase 1.2 收敛到后者。
4. **Low：Provider 内部用 `CancellationError` 作为控制流时会被归类为 provider failure**（行为已按 Phase 1.1 修正）。已写入 `Provider-Plugin-Contract.md` 第三章第 8 条：provider 自身中止必须抛 `ModelFailure` 或交付 `.failed`，不得用 `CancellationError` 表达业务原因；Phase 2 实现时仍需测试覆盖。

### 8.2 已知限制（接受并记录）

5. **恢复的错误分支无测试**：`duplicateRunCreated` / `recordWithoutRun` / `batchWithoutRun`（非尾部损坏的 journal 形状）没有对应测试。
6. **尾部修复只支持"单个末尾坏行"**：连续多条坏尾按拒载处理（设计选择，宁可拒载不猜测）。
7. **终态 vs 取消的同一瞬间竞争不可确定性测试**：策略为 first-wins，两个方向都有确定性用例；同一瞬间的物理竞争无法用单测证明。
8. **`EventLogError.invalidMarker` 无测试**；begin rollback 失败会使日志不可用且无自动修复（fail-closed）。
9. **`EntryID("turn-<turnID>")` 同 turn 重试会产生重复条目 id**（store 不去重）；当前阶段无重试路径，Phase 2 前需决定语义。
10. **预算 token 估算为启发式**（设计既有），只用于预算与限流预判，不进成本报告。
11. **物理掉电/`fsync` 语义无法在单测层证明**：STORE-009 只覆盖可控坏尾行/坏中行；D3 结论的边界即止于此。
12. **恢复不继续执行**：重启后未完成 Run 一律 `failed`，用户需重新发起 Turn。`LOOP-008` 原「只读补跑」口径已重新定界（`Kernel-Design.md` 第六章）；在线恢复（执行器与插件环境可用）推迟到阶段 3（PLG-014）。
13. **反例验证不是 CI 门禁**：变异在 `/tmp` 副本执行，无法在 CI 中例行化；若以后要制度化，需要新增脚本（不在 Phase 1.1 范围）。
14. **本地与 runner 工具链差异（已实测并记录）**：本地 Xcode 27.2 / Swift 6.4.2（`Target: arm64-apple-macosx27.2.0`）；CI 在 `macos-26` 上取到最新 Xcode 26.6.0 / **Swift 6.3.3**（`Target: arm64-apple-macosx26.0`）。两边 `swift build --build-tests` + `swift test` 与空核检查**都是全绿**（本地 89 / CI 89），说明内核不依赖 6.4 专有行为；反向的缺口仍然存在——**6.4 更新版本上的前向兼容已由本地覆盖，但 6.3.3 之外的更旧工具链没有门禁**，Phase 1.2 若升 runner 需同步更新本条。
15. **Provider/插件/TUI 层不在范围**：本记录只覆盖内核；这些层的验收记录在阶段 2–4 补。
16. **LOOP-023 的调度确定性**依靠注入时钟与 Gate，不依赖固定 sleep（QA-002）；若 CI 出现 flake，必须按 `Testing-and-Acceptance.md` 第八章记录并限期处理，禁止用 retry 掩盖。
17. **Info：进程内自愈只写内存**，journal 中没有合成条目；重启后由 `KernelRecovery` 从同一日志重新派生相同历史（`LOOP_025_danglingBatchHealedInProcess` 与重放等价性测试覆盖）。这是设计选择，不是缺口。
18. **测试 target 有 1 条编译告警（不动已冻结代码）**：`swift build --build-tests` 在 `Tests/LingXiKernelTests/GatesTests.swift:111` 报 `#UnnecessaryEffectMarker`——`#expect(try await runs.record(...))` 里的 `try` 是多余的（`record` 不抛错）。**内核与宿主 target 零告警**（本地对 `Sources/**` 强制重编复核：`swift build` 无任何 warning），CI 日志里唯一告警也来自这一行测试代码。`README.md` 的「`swift build` 无告警」指产品构建，不含测试 target，措辞成立。删除这个 `try` 是一行无行为变更的清理，但 `677d44e` 已作为验收代码基线冻结、CI 证据与之绑定，本阶段不为 cosmetics 再动基线；留到 Phase 1.2 随 `endExecution` 接线一并处理。

## 九、复现步骤

```bash
# 1. 确认基线/终态
git rev-parse HEAD            # 期望 677d44e 或其后仅文档/CI 提交（34c834a、719d3f1）
git log --oneline -1 -- Sources Tests   # 期望仍是 677d44e：文档提交不得改代码
swift build --build-tests
swift test                    # 期望 Test run with 89 tests ... passed

# 2. 用例分布与验收文件未被改动（应与第二节、第一节 sha256 一致）
for f in Tests/LingXiKernelTests/*.swift; do
  printf "%-40s %s\n" "$(basename "$f")" "$(grep -cE '^\s*func test|^\s*@Test' "$f")"
done                          # 13/16/15/0/6/26/13 = 89
git diff --stat 118263f HEAD -- Tests/LingXiKernelTests/ConversationAcceptanceTests.swift \
                               Tests/LingXiKernelTests/RecoveryAcceptanceTests.swift  # 应为空
shasum -a 256 Tests/LingXiKernelTests/{ConversationAcceptanceTests,RecoveryAcceptanceTests}.swift
shasum -a 256 Docs/Validation/Phase-1.1-contract.md   # 期望 bee6f2d8…cf48

# 3. 逐 ID 证据表点名的测试函数确实存在（第七节口径：函数名可核查）
grep -ohE '\b(LOOP|CTX|STORE|CACHE|QA|L0|DEADLINE)_[0-9A-Za-z_]+' Docs/Validation/Phase-1.1.md \
  | sort -u | while read -r fn; do
      grep -rq "$fn" Tests/LingXiKernelTests/ || echo "MISSING: $fn"
    done                      # 期望无输出

# 4. 空核启动检查（同第七节）
DATA_DIR="$(mktemp -d)"
LINGXI_DATA_DIR="$DATA_DIR" .build/debug/LingXiCoreHost
test ! -s "$DATA_DIR/events.jsonl"

# 5. CI 结果
gh run view 39361419757 --repo LingXiFox/LingXiAgent \
  --json status,conclusion,jobs --jq '{status,conclusion,steps:[.jobs[].steps[]|{name,conclusion}]}'
gh run view 39361419757 --repo LingXiFox/LingXiAgent --log   # grep "Test run with 89 tests"
```

## 十、修订记录

- 2026-10-20：ci-docs 建立骨架。
- 2026-10-20：填入基线 30 / 冻结中间态 50 / 预算修复 51 与 Lead 侧证据函数名；填入本地空核启动实测。
- 2026-10-20：按 Lead 权威 inventory 填入 80 tests（51 + 16 + 13）与两个验收文件的逐 ID 函数名、sha256；代码基线锚定 `4276281`，区分代码基线/测试提交/CI head 三个 SHA。
- 2026-10-20：按 HEAD `70847ca` 更新为 87 tests；填入 mutation 审计逐条明细（11/11 RED，含 S1/S2/M12）与 7 个缺口关闭用例；新增「D3 前提验证」小节并给出保留事件日志的结论；按 Lead 清单重写风险章节。
- 2026-10-20：`Provider-Plugin-Contract.md` 第三章新增第 8 条；`Kernel-Design.md` 更新 D3 结论段、§六双恢复入口说明、§七 `CancellationError` 分类、§十一 `endExecution` 未接线提示；README 状态与用例数收口。
- 2026-10-20：最终 HEAD 校正为 `da61865`（仅测试断言加强），空核实测改用最终 HEAD 构建产物；替换已不存在的 `emptyCoreBootsButCannotInfer` 引用（改为 `QA_013_*` 双测试覆盖）。
- 2026-10-20：最后一轮源码收口 `677d44e`（进程内悬空批次自愈 + duplicate-call 持久化前预校验），终态改为 **89 tests = 60 + 16 + 13**（5 连跑 0.021–0.024s）；§三补两个新测试并新增 3.4「独立审计之外的收口修复」；D3 证据补进程内自愈等价性；风险清单补 Info 第 17 条。
- 2026-10-20：Docs 与 `.github/workflows/ci.yml` 入库（`34c834a`）；契约冻结稿按字节归档到 `Docs/Validation/Phase-1.1-contract.md`（sha256 `bee6f2d8…cf48`），验收记录与 `Regression-Cases.md` 的引用改指仓库内路径（`719d3f1`）。补记：README/Regression-Cases 曾停在 87 tests / `70847ca`，已同步为 89 / `677d44e`。
- 2026-10-20：**CI 实跑通过，状态转「已验收」**。run `39361419757`（push 事件，head SHA `719d3f1`，`macos-26` / Swift 6.3.3 / Xcode 26.6.0）10/10 步骤 success，`✔ Test run with 89 tests in 0 suites passed after 0.074 seconds.`，空核检查通过；§六填入实测值并加「workflow 显示名沿用 main 的 CI Matrix Gate」核查提示，§七补 CI 复跑结果，§九复现步骤扩为可机检的五步（含分文件用例数、验收文件 sha256、逐 ID 函数名存在性交叉核验，本条记录发布前已当场跑过）。风险第 14 条改为已实测口径，并新增第 18 条记录 `GatesTests.swift:111` 的测试侧 `#UnnecessaryEffectMarker` 告警（内核零告警，基线已冻结故本阶段不动）。
