# Phase 1.2 验收记录：三项内核收尾与告警清零

> **状态：已验收** —— 代码 HEAD `8bc8774`，96 tests 全绿 ×5（本地 0.019–0.020s），`swift build --build-tests` 零告警，反例 4/4 RED，CI run `39365903961` 在 `macos-26` 上 success（96 tests、0 告警、空核零日志，第五节）。
> 依据：`Docs/Validation/Phase-1.1.md` 第八节风险清单第 1/3/9/18 条（本阶段只收这几笔债）；判定口径：`Docs/Testing-and-Acceptance.md`（实测数字 + trace 顺序 + 反例）。

## 一、范围

Phase 1.1 验收通过后、进入 Phase 2 前的最小收尾。**不新增功能、不加依赖、不动架构、不碰 Provider/插件层**，只做三件已登记的正确性收口：

| 项 | 来源 | 本阶段动作 |
|---|---|---|
| `endExecution` 内核从未调用 | Phase 1.1 风险 8.1 第 1 条（Medium） | 接线并钉死四条终态路径（LOOP-026） |
| 两个恢复入口并存 | Phase 1.1 风险 8.1 第 3 条（Low） | 删除旧入口，恢复口径唯一 |
| 重复 Turn ID 语义未定 | Phase 1.1 风险 8.2 第 9 条 | 定界为「Session 内条目 id 必须唯一」并加拒绝路径（LOOP-027） |
| 测试 target 编译告警 | Phase 1.1 风险 8.2 第 18 条 | 11 处冗余 `try` 全部删除 |

未在本阶段处理（明确留给 Phase 2+）：风险 8.1 第 2 条（恢复期追加终态记录失败即 `exit 1`，缺可诊断性）、第 4 条（Provider 用 `CancellationError` 作控制流）属 Provider 层，随阶段 2 实现覆盖。

## 二、基线与终态计数

| 阶段 | commit | 用例数 | 结果 |
|---|---|---|---|
| Phase 1.1 终态 | `677d44e` | 89 = 60 + 16 + 13 | 全绿 ×5，CI run `39361419757` success |
| **Phase 1.2 终态** | **`8bc8774`** | **96 = 67 + 16 + 13** | **全绿 ×5（0.019–0.020s/次）** |

分文件：`ContextTests` 13 / `DurabilityTests` 15 / `GatesTests` 6 / `LoopTests` 33；两个独立验收文件不变。
新增 7 条全部在 Lead 侧 `LoopTests`：`LOOP_026_*` 6 条 + `LOOP_027_*` 1 条。

**两个独立验收文件字节未变**（sha256 与 Phase 1.1 记录一致，本阶段只动了 Lead 拥有的测试与内核）：
`ConversationAcceptanceTests.swift` `df5fb3435df40c0de37400c6e6204a5d9ff321ef7964af8ec2fe0809155be92c`；
`RecoveryAcceptanceTests.swift` `62c98d217f3d2dd064f1d836a023837ced2fe830d786bb0c3090b7a1d3e4f424`。

## 三、逐项证据

### 3.1 LOOP-026 — provider 执行态清理已接线

接线点：`AgentLoop.run` 在 `commit(request, outcome:)` **之后**、构造 `RunResult` 之前调用一次。`commit` 不抛错，因此四条路径（completed / providerFailure / cancelled / deadlineExceeded）全部经过这里。一次 Run 一个 `executionID`，跨 Step 共用，故**每 Run 一次，不是每 Step 一次**。预检失败（QA-013 无 provider、modelNotOffered）与准入被拒（重复 runID、同 Session 已有 active Run）的 Run 从未发起执行，不调用。

| 测试函数 | 钉住的行为 |
|---|---|
| `LOOP_026_endExecutionAfterCompletedRun` | 正常完成释放一次，且带的正是该 Run 的 executionID |
| `LOOP_026_endExecutionAfterProviderFailure` | provider 失败路径照样释放，终态 cause 仍为 `.providerFailure` |
| `LOOP_026_endExecutionAfterCancellation` | 阻塞流被取消后仍释放（清理不能排在取消之后就被跳过） |
| `LOOP_026_endExecutionAfterDeadline` | 总超时路径照样释放 |
| `LOOP_026_endExecutionFiresOnceAcrossSteps` | 3 个 Step（两次工具批次 + 收尾）→ `requestCount == 3` 而 `endedExecutions` 长度为 1 |
| `LOOP_026_noEndExecutionWhenRunNeverStarted` | 准入被拒的 Run 不调用、日志零新增（负向对照） |

### 3.2 恢复入口收敛

删除 `RunRegistry.recoverUnfinishedRuns`（`RunState.swift`，16 行）。`KernelRecovery.recover(log:)` 成为唯一入口；`openRunIDs` 保留（多处测试用作状态断言）。

`LOOP_003_crashRecovery` 因此改写为真实重启形状：journal 停在 `runStarted`，由 `KernelRecovery` **重建全新对象**，断言 `report.failedRunIDs == [runID]`、新 registry 上该 Run 为 `failed / runtimeFailure / "recovered after restart"`，再跑一次恢复得 `failedRunIDs.isEmpty` 且 `openRunIDs.isEmpty`（终态记录已在日志里），并钉住日志中那条 `runTerminal(runID, .failed, .runtimeFailure)`。原实现是「复用旧 registry 冒充重启」，改后才是 Phase 1.1 冻结口径要求的重放语义。`STORE_001_fileJournalRoundTrip` 里另一处旧入口调用同样改为 `KernelRecovery`。

### 3.3 LOOP-027 — 重复 Turn ID 的行为定界

规则：**用户条目 id `turn-<turnID>` 在同一 Session 内必须唯一**。理由是淘汰引用行与模型引用都按条目 id 指回原文，重复 id 使引用产生歧义；且阶段 1 的实时路径与重放路径都不去重，重复会一路带进每次请求。

判定顺序有意为之：放在 `runs.create` **之后**，所以同 runID 重试仍由 `duplicateRun` 先命中（保住 `LOOP_021_duplicateRunIDRejected` 的既有语义）；放在 `log.beginMarker()` **之前**，所以拒绝不产生任何持久化写入，并 `runs.discard` 掉内存记录。

`LOOP_027_duplicateTurnIDRejectedWithoutJournalWrites` 断言九项：状态 `failed / runtimeFailure`、detail 含 `already recorded`、`terminalCommitted == false`、日志记录数不变、provider 请求数仍为 1、被拒 Run 不在 registry、`turn-turn-1` 条目计数为 1、`openRunIDs` 为空、以及换新 TurnID 后该 Session 正常继续（mandatory 只剩新 Turn）。

**被拒绝的备选口径**：把条目 id 改成按 `runID` 生成，从而允许同 TurnID 重复提交。否掉的原因是它会把同一段用户输入静默写入历史两次并计入预算，把「引用歧义」换成「内容重复 + token 浪费」，且不给调用方任何信号。

### 3.4 告警清零（含对本记录前身的更正）

Phase 1.1 记录第 18 条初写为「唯一告警」，是**核查方法错误**：当时 `grep warning | sort -u` 按文案去重，把 11 条同文案的 `#UnnecessaryEffectMarker` 折成 1 条。改用「按 `file:line:col` 来源位置去重」重测，实为 11 处：`ContextTests:126`、`DurabilityTests:33/75/96/117/118/119/221/461`、`LoopTests:489/773`。全部是 `#expect(try await …)` 套不抛错调用（`runs.record` / `store.entries` / `registry.epoch`）。逐条删除后 `swift build --build-tests` **0 告警**，用例数与断言语义不变。内核与宿主 target 从来零告警，`README.md`「`swift build` 无告警」的措辞本来就成立（指产品构建）。

方法论记入口径：**计数类断言必须按来源位置去重，不能按文案去重**。

## 四、反例（变异）验证

在 `/tmp/lx-p12-mut` 的 detached worktree 里把 bug 注回，主工作树零污染，验后 `git worktree remove`。**4/4 被捕获**：

| # | 注入的旧 bug | 期望变红 | 结果 |
|---|---|---|---|
| M1 | 删除 `run()` 里的 `endExecution` 调用 | `LOOP_026_*` | RED 5/6 —— 四条路径用例全红；`noEndExecutionWhenRunNeverStarted` 是负向对照，删除调用后它**本应仍绿**，不参与判定 |
| M2 | 条目 id 唯一性判断恒假（`{ _ in false }`） | `LOOP_027_*` | RED（9 处断言失败：重复条目写入、日志被污染、provider 收到第二次请求） |
| M3 | 把释放改成每个 Step 调一次 | `LOOP_026_*` | RED 5/6，含 `endExecutionFiresOnceAcrossSteps` —— 证明「每 Run 一次」不是弱断言 |
| M4 | 恢复不再终态化未闭合 Run（`where false`） | `LOOP_003_*` | RED（6 处断言失败），同批 `STORE_008` 仍绿 → LOOP-003 独立钉住终态化这一步 |

## 五、CI 记录

| 项 | 值 |
|---|---|
| workflow | `.github/workflows/ci.yml`（同 Phase 1.1，`macos-26` 单 job） |
| 代码基线 SHA | `8bc8774`（`fix(kernel): close the three Phase 1.2 correctness gaps in the loop and recovery`） |
| CI head SHA | `44b3a8af682b285d658f412dd9b1878df57f6403`（含代码提交 `8bc8774`，树内 `Sources/**`、`Tests/**` 与其一致） |
| Run ID | `39365903961` |
| Run URL | https://github.com/LingXiFox/LingXiAgent/actions/runs/39365903961 |
| Conclusion | **success** — 10/10 步骤全 success，2026-10-20T03:45:01Z → 03:45:48Z（47s，SwiftPM 缓存命中） |
| runner | GitHub Actions 托管 `macos-26`（arm64），runner id `1000000899` |
| runner 工具链 | `xcode: /Applications/Xcode_26.6.0.app`；`Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)`；`Target: arm64-apple-macosx26.0`（与本地 6.4.2 / Xcode 27.2 不同，口径同 Phase 1.1 风险 8.2 第 14 条） |
| `swift test` 汇总行（CI） | `✔ Test run with 96 tests in 0 suites passed after 0.052 seconds.` |
| 构建告警数（CI） | **0**（`grep -c warning:` 对全量日志计数，按来源位置核对） |
| 空核启动步骤 | **success** — `empty-core startup clean: guidance printed, no journal records` |

**一次踩坑记录（有教学价值，故写进正文）**：`44b3a8a` 推送后 CI **没有自动起跑**，原因是本阶段刻意不想跳过 CI，却在 commit message 正文里写了那个方括号跳过标记的**字面量**来解释意图；GitHub 对整条 message 做子串匹配，正文里的字面量同样触发跳过。处置：用 `gh workflow run --ref rewrite/2.0` 在同一 head SHA 上 `workflow_dispatch` 补跑，得到上表记录（`event: workflow_dispatch`），证据效力不变。**口径**：想让 CI 跑的提交，正文里不要出现该字面量；解释这件事时改用「跳过标记」之类的描述。

## 六、残余风险

1. **Medium（继承，Phase 2 必修）**：恢复期追加 `runTerminal` 失败仍直接抛到宿主 `exit 1`——fail-closed 正确，但缺自动恢复记录与可诊断信息（Phase 1.1 风险 8.1 第 2 条）。
2. **Low（继承，阶段 2 覆盖）**：Provider 自身以 `CancellationError` 作控制流会被归类为 provider failure，契约已写进 `Provider-Plugin-Contract.md` 第三章第 8 条，尚无插件层测试。
3. **本阶段引入的口径**：`LOOP-027` 选择「拒绝重复 TurnID」而非「容忍并去重」，意味着**上层重试同一轮必须换 TurnID**。前端/插件接入时（阶段 2、4）若需要「原地重试同一轮」的产品行为，需要显式设计这条路径，不能悄悄改回容忍语义。
4. **`endExecution` 的失败语义未定义**：协议为 `async` 且不返回错误（`Model.swift:152`），内核无法感知清理失败，也就无法上报。阶段 2 若真实 provider 需要清理失败可观测，要在插件契约里加返回通道——属 ABI 决策，不在本阶段。
5. **反例验证仍非 CI 门禁**（Phase 1.1 风险 8.2 第 13 条）：本轮 4 条变异同样在 `/tmp` 副本手工执行。

## 七、复现步骤

```bash
git rev-parse HEAD                       # 期望 8bc8774 或其后仅文档提交
git log --oneline -1 -- Sources Tests    # 期望 8bc8774
swift build --build-tests                # 期望 0 warning
swift test                               # 期望 Test run with 96 tests ... passed
for f in Tests/LingXiKernelTests/*.swift; do
  printf "%-40s %s\n" "$(basename "$f")" "$(grep -cE '^\s*func test|^\s*@Test' "$f")"
done                                     # 13/16/15/0/6/33/13 = 96
shasum -a 256 Tests/LingXiKernelTests/{ConversationAcceptanceTests,RecoveryAcceptanceTests}.swift
git show 8bc8774:Sources/LingXiKernel/RunState.swift | grep -c recoverUnfinishedRuns   # 期望 0
DATA_DIR="$(mktemp -d)"; LINGXI_DATA_DIR="$DATA_DIR" .build/debug/LingXiCoreHost
test ! -s "$DATA_DIR/events.jsonl"       # 空核仍零日志
```

## 八、修订记录

- 2026-10-20：建立记录；填入三项收口的逐项证据、4/4 反例明细、告警计数更正与残余风险。CI 运行记录待第五节补入。
- 2026-10-20：CI 实跑回填，状态转「已验收」。run `39365903961`（`workflow_dispatch`，head `44b3a8a`）success：96 tests、构建零告警、空核步骤通过；同时记录一次真实踩坑——push 提交的正文里出现了跳过标记字面量导致 push 事件未起跑（第五节）。
