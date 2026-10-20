# LingXiAgent 2.0 旧版经验与回归案例清单

来源：LingXiAgent 1.x（`/Volumes/Development/Projects/projects/LingXiAgent`，main @ `8ca6b9f`）的代码、244 个测试文件、ContractTests、CI 机制与 200 余条历史修复提交。
性质：**活文档**。每修一个 bug 追加一条；每废弃一条架构标注废弃原因，不直接删行。

## 修订记录

- **Phase 1.2（2026-10-20，进入阶段 2 前的最小收尾）**：不新增功能、不加依赖、不动架构，只还 Phase 1.1 验收记录登记的四笔债。新增 2 条：**LOOP-026**（`endExecution` 已接线，四条终态路径各证一次 + 跨 Step 只释放一次 + 未启动的 Run 不调用）、**LOOP-027**（`turn-<turnID>` 条目 id 在 Session 内必须唯一，重复 TurnID 在 `runs.create` 之后、任何持久化写入之前被拒并 `discard` 内存记录，Session 后续新 Turn 正常可用；备选口径「按 runID 生成 id 容忍重复」被明确否掉，理由见 `Validation/Phase-1.2.md` §3.3）。既有口径收紧两处：**LOOP-003** 的恢复入口收敛为 `KernelRecovery` 唯一（删除 `RunRegistry.recoverUnfinishedRuns`，用例改为断言重放**新建**对象上的终态与二次重放幂等，原实现是复用旧 registry 冒充重启）；**Phase 1.1 风险 8.2 第 18 条**的告警计数更正为 11 处并按来源位置去重后全部删除，`swift build --build-tests` 归零告警（内核与宿主本就零告警）。**验收结果（2026-10-20，HEAD `8bc8774`）**：96 tests 全绿 ×5，反例 M1–M4 全部 RED（M3 专门证明「每 Run 一次」不是弱断言），空核启动仍零日志，两个独立验收文件 sha256 未变，证据见 `Docs/Validation/Phase-1.2.md`。

- **Phase 0.1（2026-10-19）**：插件运行模型由"插件即子进程、作者自实现 IPC"改为"插件是固定 C ABI 动态库 + 每插件一个独立 Plugin Host 进程"。影响范围：`IPC-*` 组的适用对象变为 **Core↔Host 内部协议**（作者不再接触）；`PLG-*` 组语义不变，新增 PLG-015~019 覆盖 ABI、签名策略、fail-closed 与进程级隔离；新增 E-13~E-15 记录握手五套不一致、library validation 取舍、无 size/version 字段的前向兼容缺陷。
- **Phase 1.1（2026-10-20，内核正确性收口）**：不新增功能、不加依赖、不重构架构，只修内核正确性并补验证。新增 12 条：**LOOP-021~025、STORE-008~010、CTX-017/018、CACHE-007、QA-013**（契约见 `Docs/Validation/Phase-1.1-contract.md`，验收记录见 `Docs/Validation/Phase-1.1.md`）。既有条目的硬约束不变，但证据扩展：LOOP-002 的"写失败回滚"扩展为日志修复状态机（STORE-009）；LOOP-003/LOOP-004 的重启与 begin 语义分别由 `KernelRecovery` 全量重放（STORE-008）与单事务（STORE-010）承担；LOOP-006/007 的取消语义扩展为阻塞流竞争（LOOP-023）。**恢复策略改为"只读重放 + 终态化，不恢复执行"**：`LOOP-008` 原"只读项补跑、继续下一步"的口径不再适用于内核重启恢复，重新定界为在线故障恢复（PLG-014）。**验收结果（2026-10-20，终态 HEAD `677d44e`；变异矩阵在代码基线 `70847ca` 复跑）**：89 tests 全绿 ×5，CI `macos-26` run `39361419757` success（同 89 tests，Swift 6.3.3），变异检验 11/11 RED（其中删除预算后协议复校验的覆盖缺口已由 `CTX_018_postBudgetValidationGatePresent` 结构性门禁关闭），证据见 `Docs/Validation/Phase-1.1.md`；新条目状态统一标为「已覆盖（阶段 1.1）」。终态分类补一条：Provider 自身抛出的 `CancellationError` 归 `.failed / .providerFailure`，不得冒充用户取消（LOOP-006 加固）。

## 使用方式

1. 测试函数名必须带条目 ID，例如 `func LOOP_006_cancelDoesNotFabricateProviderFailure()`。
2. 新出现的失败场景先登记 ID 再写测试，不允许"先修了再说"。
3. `状态` 列取值：`待继承`（2.0 需实现并覆盖）、`进行中`、`已覆盖`、`不适用`（架构已废弃，保留理由）；阶段验收期间的临时状态 `待验收（阶段 X.Y）` 表示测试已写但未完成 frozen 后验证与证据归档。
4. `阶段` 列表示该回归在哪个阶段必须开始跑；`层` 对应 `Testing-and-Acceptance.md` 的 L0–L4。
5. 证据列指向 1.x 的测试文件、符号或修复提交。它是"为什么这条值得测"的依据，不是实现参考。

---

## 第一部分：架构级经验（E 组）

这些是判断，不是用例。每条都在设计文档里被引用为某项决定的依据。

| ID | 经验 | 判决证据 | 2.0 处置 |
|---|---|---|---|
| E-01 | P/E 双核 + E-Core 自主召回被证明不划算：为补齐其正确性投入四套状态机、两次 schema 迁移、8 个 Phase；真实普查显示投影率 76.8%、**召回转化率 0.0%**——模型消费完前两轮全文就不再需要，宁愿重跑 read/grep | `Docs/AC/E-Core-Recall-Opportunity-Report.md`（59 会话 / 207 对象）；另一次真实 smoke 中 `eCore.objectCount = 0` | 废弃。只保留两条最小替代：载荷可无损回读 + 移出时留稳定引用行（CTX-005、010） |
| E-02 | 「排队 × 终态化 × 崩溃恢复」三者交叉是缺陷放大器，不是单点 bug。1.x 该区域 Round 12–20 的大多数缺陷来自三者组合 | `SessionTurnCoordinator` 1186 行；修复提交 `b420dde`、`503c6dd`、`5ba21d9`、`59601b2` | 内核只保留单 active Run（`Kernel-Design.md` D1），排队移出内核 |
| E-03 | 基于"看起来没进展"的终止权威不可维护：进度跟踪器三次重写后，其硬停权威被自己废除（现注释 "never authority to stop a model"）；完成声明正则守卫留下大量保守妥协记录 | `576ce61` → `8ca6b9f`；`Docs/AA/P16-AGENT-BEHAVIOR.md` | 内核终止权威只来自硬边界（D2） |
| E-04 | Provider 兼容面的规模不产生能力：27 个 product × 56 份 binding JSON，官方文档自己承认仅 9 个可跑、**真实 smoke 全部为 No** | `Docs/AA/P14-PROVIDER-ACCEPTANCE.md` | 按 wire family 三条划接口，首期 6–8 家（`Provider-Plugin-Contract.md` §2） |
| E-05 | 上下文压缩的多维评分从未用真实 trace 校准：八维权重评分器与经济 break-even 调度（默认阈值 272,000）在 128K/24K 窗口下形同虚设，且会跳过本该压缩的轮次 | `ContextValueWeights`、`economicThreshold` 相关实现与测试 | 只保留水位 + mandatory + 因果批次（D5） |
| E-06 | "记录在案但不生效"的声明是死重：35 种 quirk 名里运行时只读 1 条，`hasQuirk()` 仅出现在测试；所谓原生 driver 实为转发；未知协议**静默 fallback** 使配置错误延迟到上游才炸；`toLegacyDefinition()` 30 分支 switch 把已加载的 JSON 又硬编码一遍 | `BuiltinProviderCatalog.swift:339`、`resolveDriver`、`UnifiedProtocolModelProvider` | 能力声明必须与实际行为可核对；未知协议硬失败；无默认值兜底（PLG-009、PROV-017） |
| E-07 | 凭据收口必须一次做全：环境净化机制本身是对的，但 MCP 侧当时明确"这次先不动"，留下泄漏点 | `1b4b31e`（插件继承 vault passphrase、sidecar 继承全部 API key） | 子进程环境严格 allow-list 为**默认而非补丁**（PLG-008） |
| E-08 | 串行同步 IPC 无法后补流式与并发，协议与 peer 层必须一次定对 | `PluginProcessHost`：JSON Lines 一问一答、无路由、无流式、无心跳、无重启退避 | JSON-RPC 2.0 单管多路复用（D-P2，IPC-012） |
| E-09 | 只有监听没有返回值的 Hook 等于没有扩展点：1.x 全套 hook 类型、SDK 注册、握手协商都在，但 `broadcastHook` 与 `ExtensionPlatform.emit` 生产代码**零调用方**，且 handler 无返回值 | `PluginHookEvent`、`ExtensionHookEvent`、`PluginContext.on` | Hook 必须类型化返回 + 否决语义，且 L0 孤儿类型门禁守着（PLG-006） |
| E-10 | 测试若绕过真实边界或依赖固定 sleep，门禁就失去意义：手工构造工具结果直塞内核，使断言验证一个永不可能成立的前提；固定 sleep 造成 CI flake 反复修 | `Docs/AA/PE-Core-ToolLoop-Audit-2026-10-04.md` §H；`27b1899`、`67604b8` | QA-001、QA-002；必须新增注入式时钟 |
| E-11 | 端到端评估造假比没有评估更危险：1.x 的 Runner 从不启动 Agent，只跑 `oracle.sh` 后按 `success ? 2 : 0` 伪造工具数/轮次/token/成本，9 个 oracle 全是 `swift test --filter` 或 `git log --grep`，且 `exit 0` 无条件兜底使 oracle 永不误红，Evals 也未接入 CI | `Evals/Runner/main.swift`、`Evals/*/oracle.sh` | 只继承其判据设计（task.json + 非劣性四规则），L3 必须真跑 Agent（QA-003） |
| E-12 | 双真相源必然导致撤销不干净：`discoverAndStartAll` 纯扫目录且不查 `registry.enabled`；`configureExtension` 硬编码 `enabled:true` 且不落盘；前端命令表只增不减、`unregister` 无人调用 | `CoreHost` 扩展启停路径、`ApplicationCommandRegistry.syncPluginCommands` | registry 为唯一真相源 + 固定八步禁用流程（PLG-001、002） |
| E-13 | 握手与能力注册在 1.x 存在**五套互不一致**的实现：插件 IPC 用 `ipcVersion: Int` + 裸字符串错误；Core 侧 manifest 用 `compatibility.schemaVersion` + 版本字符串区间；browser-host 用真 JSON-RPC + `protocolVersion: "v1"`；MCP 用 `initialize → notifications/initialized → tools/list`；前端 wire 用 `protocolVersion = "2.0"` 字符串。字段名、类型、顺序、失败表达全不同，等于没有契约 | `PluginIPCProtocol.swift:5`、`ExtensionPlatform.swift:259`、`Sidecars/browser-host/index.mjs:215`、`MCPTransport.swift:113`、`FrontendWire.swift:72` | 统一为一条序列，版本语义只留 `abiMajor` 整数，错误统一 `code/domain/message`（`Plugin-System-Design.md` 第四章） |
| E-14 | 加载第三方动态库与 macOS 系统检查存在正面冲突：Hardened Runtime 的 library validation 默认只允许同 Team ID（或 Apple 签名）的库，要放行社区插件就必须带 `com.apple.security.cs.disable-library-validation`，而 Apple 对该 entitlement 的描述即"加载任意插件或框架，**而不要求代码签名**"。不能一边关掉系统检查一边宣称安全 | Apple 文档 entitlement 条目与 Hardened Runtime 条目；1.x 已有同立场记录：`Vendor/OpenTUI/0.5.10/ABI-MANIFEST.txt` 写明"ad-hoc 签名、未公证、不得发布分发、加载被阻时不得绕过 macOS 安全控制" | 首发默认 `restricted`（仅同 Team ID），开启社区插件是带前端告警的用户显式动作；自行校验签名与 Team ID；不宣称 OS 沙箱（`Plugin-System-Design.md` 第八章） |
| E-15 | 跨边界结构体没有尺寸与版本字段，前向兼容就只能靠"符号是否存在"；错误传递用全局静态缓冲，并发下互相覆盖 | `OpenTUIShim.c:36` 与 `include/OpenTUIShim.h`：无 version/size 字段、`static error_message[256]` | ABI 规则强制 `structSize + abiMajor` 头两字段、错误以结构返回（PLG-015） |

---

## 第二部分：回归用例清单

### LOOP 组 — Agent Loop、批次、取消、恢复

| ID | 场景 | 期望行为 | 1.x 证据 | 阶段 | 层 | 状态 |
|---|---|---|---|---|---|---|
| LOOP-001 | 同一 Run 并发触发取消终态化与完成终态化 | 只有一个赢家推进后续，另一次返回"未发生迁移"；幂等 | Round 12 *Single Terminalization Winner* | 1 | L1 | 已覆盖（阶段 1；1.1 加固：`terminalize` 显式返回赢家与否，begin 失败不补写终态） |
| LOOP-002 | 终态事件落盘失败 | 内存回滚到写之前，已追加事件被截断，不推进任何后续 | Round 19 *Root Terminal Durability* | 1 | L1 | 已覆盖（阶段 1；1.1 加固：repairRequired/rollbackFailed 状态机，见 STORE-009） |
| LOOP-003 | 进程重启，存在已 started 但非终态的 Run | 一律判 `failed`，绝不重新排队或重放（避免重复副作用） | Round 13 *Crash Recovery Safety* | 1 | L1 | 已覆盖（阶段 1；1.1 加固：由 `KernelRecovery` 全量重放重建，见 STORE-008；1.2 收口：旧入口 `RunRegistry.recoverUnfinishedRuns` 删除，恢复入口只剩 `KernelRecovery` 一个） |
| LOOP-004 | 全流程事件序列 | `runCreated` 恰好一次；stop 后内核待答交互账本与快照均为空 | `4ec856a`、`stopClearsCorePendingInteractions` | 1 | L1 | 已覆盖（阶段 1；1.1 加固：begin 三记录单事务，见 STORE-010） |
| LOOP-005 | 一个批次内 [慢, 快, 失败] 三个工具 | 并行执行，结果按 Provider 给出顺序进入同一条 tool 消息，事件保序；批次内出现重复 callID 时**整批拒绝** | `AgentToolLoopTests.multiToolBatchExecutesInParallelAndSettlesInProviderOrder` | 1 | L1 | 已覆盖（阶段 1；1.1 加固：`batchStarted` 意图先于任何副作用落盘） |
| LOOP-006 | Provider 已投递失败的同时用户按 Esc | 终态保留真实故障原因，不改判为 cancelled；取消路径静默结束流，**严禁伪造失败事件**；Provider 自身抛出的 `CancellationError` 归 `.failed / .providerFailure`，不得冒充用户取消（只有用户取消/内核 deadline 产生 `cancelled`） | `f118d15`、`CancellationRaceTests` 场景 4（钉 cause 不只钉 status） | 1 | L1 | 已覆盖（阶段 1；1.1 加固：阻塞流下的终态优先级 + provider CancellationError 不冒充取消） |
| LOOP-007 | Esc 发生在工具已结算、下一次模型请求未发出时 | Run 进 `cancelled`，已执行的工具不重跑 | `toolContinuationEscToolNotReplayed` | 1 | L1 | 已覆盖（阶段 1；1.1 加固：阻塞流取消竞争，见 LOOP-023） |
| LOOP-008 | 崩溃时留有未消费批次（含只读与可变混合） | **Phase 1.1 重新定界**：内核重启恢复不执行任何工具、不发模型请求，只读项也不补跑；已 `batchStarted` 未 `batchSettled` 一律合成 `executionStateUnknown` + `verificationRequired` 结果（见 LOOP-025）。"只读补跑"仅在阶段 3 在线插件故障恢复、执行器可用时按 PLG-014 实现 | `restartSchedulesReadOnlyRemainderAndSettlesMutationClaimAsUnknown`（1.x 口径） | 1 | L1 | 范围移至 PLG-014/阶段 3（重启恢复口径见 LOOP-025） |
| LOOP-009 | 等待人工应答期间跨过 Run 与工具超时 | 超时必须不能吞掉人工等待，Run 继续存活 | `permissionWaitKeepsRunDurablePastAgentAndToolDeadlines` | 1 | L1 | 待继承 |
| LOOP-010 | Stop 时队列非空 | 排队项一并进终态且不提升为新 root Run | `stopCancelsTheQueuedTurn` | — | — | **不适用**：内核取消排队（D1），该场景在 2.0 内核层不可构造；若将来在产品层引入队列，此条连同 LOOP-001/002/003 的交叉证明一起重新启用 |
| LOOP-011 | 取消一个不存在的 Run / 只取消排队项 | 在产生任何副作用前抛命名错误；取消范围不得越界伤及 active Run | Round 11 *Cancel Scope*、*P0-D Validation Before Destruction*、`3ca4d37` | 1 | L1 | 待继承 |
| LOOP-012 | 触达显式步数上限 | 错误信息含步数、最后一个工具调用、最后一次观察，可供用户判断；步边界的预算耗尽与总超时检查同样成立 | `maxStepsReachedProvidesDetailedExplanation…` | 1 | L1 | 已覆盖（阶段 1；1.1 加固：步边界预算/超时检查，`LOOP_012_budgetExceeded`、`DEADLINE_stepBoundaryCheck`） |
| LOOP-013 | 35 批真实变更 / 10 批空结果 / 10 批相同失败 | 全部执行到底，不得因"看起来没进展"硬停；空 stdout 不构成终止理由 | `usefulWorkBeyond32StepsCompletes`、`emptyResultsDoNotStop`、`identicalCommandsReachReport`、`8ca6b9f` | 1 | L1 | 已覆盖（阶段 1） |
| LOOP-014 | Turn 期间会话修订号发生变化 | 陈旧 Run 的终态以 `StaleRunError` 丢弃且**不落盘** | `completeTurn` lease 校验 | 1 | L1 | 待继承 |
| LOOP-015 | 同批次 `read a → write a → read a`；以及目录列表 + 该目录内写入 | 第三次读必须真执行并返回新字节；目录列表不可被复用；**数真实执行次数**作为断言手段 | `ReadConsistencyTests`（11 门）、`13b9c39` | 1 | L1 | 待继承 |
| LOOP-016 | 本轮带附件（含图片） | 附件必须进入实际发给模型的条目集合，而不是仅记账的集合；解析失败即让 Turn 失败，不静默降级 | `da3f14f`、`AgentLoopEndToEndTests`（附件三条） | 1 | L1 | 待继承 |
| LOOP-017 | 取消后仍有迟到增量到达 | 迟到增量不上屏；已投递增量保留；活动流注册表清空 | `providerStreamingEscImmediatelyTerminatedNoDeltas`、`cancelledProviderLateResponseIgnored` | 1 | L1 | 待继承 |
| LOOP-018 | 工具启动了后台子进程后被取消 | 后台进程归属必须登记并可回收，不得泄漏或杀不掉 | `0a2fffe`、`8726555` | 2 | L2 | 待继承 |
| LOOP-019 | 工具结果里的版本戳被用于后续写回校验 | `read_file` 的 stamp 必须被写/编辑的 expected-hash 接受；不匹配仍拒绝且**不动磁盘** | `SensitivePathPolicyTests`、`ReadConsistency` | 2 | L2 | 待继承 |
| LOOP-020 | Turn 完成路径并发 | Turn 完成必须串行，不得出现两次完成副作用 | `52243d7` | 1 | L1 | 待继承 |
| LOOP-021 | 同一 Session 已有 active Run 时发起第二个 Run | 第二个 Run 在产生任何副作用前被拒：`failed / concurrentRunRejected`，日志无新记录、SessionStore 无新条目，首 Run 不受影响；不同 Session 可各自并发建 Run | 1.x 用队列串行化、无准入拒绝语义（E-02 反面证据） | 1 | L1 | 已覆盖（阶段 1.1） |
| LOOP-022 | `maxTokens` / `contentFilter` / `refusal` / `unknown` 停止原因 | 不得报 `completed`：分别 `failed / outputTruncated`、`failed / contentFiltered`、`failed / refused`、`failed / streamProtocolViolation`；仅正常 `.stop` 才 `completed`（有文本 `completedWithText`、无文本 `completedWithEmptyText`） | 阶段 1 把所有 `.completed(stop)` 一律当 completed；Phase 1.1 契约 §2.5 | 1 | L1 | 已覆盖（阶段 1.1） |
| LOOP-023 | Provider 流阻塞时的取消与总超时 | `stream()` 调用与流消费整体放进可竞争任务；取消/总超时先被观察到 → `cancelled / cancelledByUser` 或 `deadlineExceeded / deadlineExceeded`；迟到事件丢弃且不伪造 provider 失败；终态事件一旦被内核处理即胜出，之后取消不改写；已收到的 usage 部分照常汇总 | 1.x `CancellationRaceTests` 场景 4（LOOP-006）只覆盖非阻塞流；Phase 1.1 契约 §2.6 | 1 | L1 | 已覆盖（阶段 1.1） |
| LOOP-024 | Assistant 文本落盘与跨 Turn 可见 | 工具轮：assistant 文本与工具调用写进**同一条** `entryRecorded`（`.assistantMessage`，unit=batchID；文本为空时用 `.toolCall`）；正常完成：最终文本写 `.text` 条目（role assistant、segment history）；`.maxTokens` 已产出文本同样写入，contentFilter/refusal 不写入；先事件落盘再进 store；后续 Turn 请求可见完整历史 | 阶段 1 只落工具调用、不落 assistant 文本；Phase 1.1 契约 §2.4 | 1 | L1 | 已覆盖（阶段 1.1） |
| LOOP-025 | 崩溃恢复不重放写操作 | 恢复只读重放事件、重建内存对象；`batchStarted` 有而 `batchSettled` 缺 → 合成 `isError=true`、`effect=.unknown` 的结果（内容含 `executionStateUnknown` 与 verification 要求），Run 记入 `executionStateUnknownRunIDs`，**绝不重放**；恢复期间 ToolExecutor 调用 0 次、模型请求 0 次 | 1.x 恢复矩阵允许只读补跑（LOOP-008），2.0 取更严格口径；Phase 1.1 契约 §1.3 | 1 | L1 | 已覆盖（阶段 1.1） |
| LOOP-026 | Run 终态后 provider 的执行态清理 | 内核在**每一条**到达过 loop 的终态路径上调用一次 `endExecution(executionID)`：正常完成、provider 失败、取消、总超时都要释放；一次 Run 只有一个 executionID，跨多个 Step 也只清理**一次**（不是每步一次）；准入被拒、预检失败等从未发起执行的 Run 不得调用（无状态可清）。缺此接线则 provider 的 continuation 状态永久泄漏（阶段 2 接真插件后是真缺陷） | `Phase-1.1.md` 风险 8.1 第 1 条；`Kernel-Design.md` 第十一章「阶段 1 未接线」 | 1.2 | L1 | 已覆盖（阶段 1.2） |
| LOOP-027 | 同一 Session 复用已记录的 Turn ID | 用户条目 id `turn-<turnID>` 在 Session 内**必须唯一**：淘汰引用行与模型引用都按条目 id 指回原文，重复 id 会让引用产生歧义。命中已记录 id 的 Run 在 `runs.create` 准入**之后**、任何持久化写入**之前**被拒（`duplicateRun` 仍优先命中同 runID 重试路径），并 `discard` 内存记录：事件日志零新记录、provider 零请求、条目 id 计数仍为 1、Session 后续新 Turn 正常可用。重试一轮必须换新 TurnID | Phase 1.1 前未定义（`Phase-1.1.md` 风险 8.2 第 9 条）；阶段 1 实时路径与重放路径均不去重 | 1.2 | L1 | 已覆盖（阶段 1.2） |

### CTX 组 — 上下文装配、完整性、压缩

| ID | 场景 | 期望行为 | 1.x 证据 | 阶段 | 层 | 状态 |
|---|---|---|---|---|---|---|
| CTX-001 | 检索/召回/插件 Hook 注入的文本 | 三家 wire 都必须走**非特权数据通道**；只有 `immutableInstructions` 能进指令位置 | `967b1ea`、`ProviderPrivilegeTests` | 1 | L1 | 已覆盖（阶段 1） |
| CTX-002 | 动态工具上线 / schema 变更 | 同一 epoch 内只单调追加、不改序不移位；schema 变更必须显式推进 epoch，否则请求被拒 | `dynamicMCPAppendOnlyMaintainsPriorPositions` | 1 | L1 | 已覆盖（阶段 1） |
| CTX-003 | 批次内出现陈旧读 | 陈旧读既不写会话存储，也不进入下一次模型请求 | `13b9c39` | 1 | L1 | 待继承 |
| CTX-004 | 工具失败（含 exitCode、异常名）后经压缩再投影 | 失败诊断证据必须存活，且重复投影幂等（从 evidence 字段读回） | `FailureDiagnosticEvidence`、T011 fixture | 1 | L1 | 待继承 |
| CTX-005 | 同一工具输出的多个身份 | 载荷只有**一个**权威身份，预览不等于全文；纯前缀截断不得丢掉关键诊断 | `2f774c6`、`ToolArtifactTruthTests` | 1 | L1 | 待继承 |
| CTX-006 | 请求 8KB 字节切片回读 | 不得被通用输出策略二次截断；头部声明的字节区间与送达内容逐字节相等；切片与整块回读是两种语义，不得隐式升级也不得假性拒绝预算超限 | `89cb8de`（probe08/10）、`RecallSemanticsTests` | 1 | L1 | 待继承 |
| CTX-007 | 一个批次多个 artifact，各自带 range | 已提交的 range 必须按**条目自身** artifact 选引用，不得串到兄弟条目（曾贴假 `bytes=` 标签） | `73fd9de`、Phase 8 §4 | 1 | L1 | 待继承 |
| CTX-008 | 上下文超预算 | 水位 `preferred×1.15 / ×0.8`；从低分逐个移出、降到 lowWater 立即停止；mandatory（system / 当前 user / 未消费因果批次）不可淘汰，mandatory 之和超 hard 直接报 `budgetExceeded` | `ContextBudgetPlanner.plan`、`ContextCompactor.compact:570-660` | 1 | L1 | 已覆盖（阶段 1） |
| CTX-009 | 压缩遇到未消费批次 | 以因果批次为不可分单位，不得拆出半截工具调用 | `CTX-009` 对应 `ToolExchangeBatch` mandatory 判定 | 1 | L1 | 已覆盖（阶段 1） |
| CTX-010 | 历史被移出活跃上下文 | 留一条能精确指回原文的稳定引用行；仅显式请求才回到活跃上下文，且**跨重启仍成立** | `residencySurvivesRestart…` | 1 | L1 | 待继承 |
| CTX-011 | 索引类投影随查询词变化 | 不得计入"持久历史"签名，否则被误报为历史被改写 | `historySignatureTexts` / `countsAsDurableHistory` | 1 | L1 | 待继承 |
| CTX-012 | 分支或工作目录变动 | 易变环境事实排在指令块之后，不得击穿前缀 | `AgentInstructions.AgentEnvironmentFacts.render` | 1 | L1 | 待继承 |
| CTX-013 | 单个超大条目装不进窗口 | 投影为带标注的**有界范围** + `continuation_offset`，不得整块拒绝；重启后重投影同一 range；range 用真实 token 估算器，禁用 bytes/token 常数 | `881841f`、`BoundedOccurrenceProjectionTests` | 1 | L1 | 待继承 |
| CTX-014 | 装配前协议校验 | 孤儿工具调用、乱序、重复必须显式抛错，不发往模型 | `ModelRequestProtocolValidator.validate` | 1 | L1 | 已覆盖（阶段 1） |
| CTX-015 | 同一条目连续 8 轮参与装配 | 只做一次移出 + 一条引用行，不得反复投影 | `residencyPreventsRepeatedCanonicalPageOut` | 1 | L1 | 待继承 |
| CTX-016 | 读文件类工具的大输出 | 该类工具豁免通用投影阈值（1.x 为 8 次全文 / 64KB），阈值判定在**被调用方一侧**完成 | 1.x 输出策略实现 | 2 | L2 | 待继承 |
| CTX-017 | 跨 Turn 的 user 条目分段 | 只有当前 Run 的 user 条目是 `.currentUser`（mandatory）；之前轮的 user 全部降级为 `.history`（可淘汰）；重放与实时共用同一降级规则 | 阶段 1 里所有 user 条目都是 currentUser，旧轮历史永不可淘汰；Phase 1.1 契约 §1/§2.9 | 1 | L1 | 已覆盖（阶段 1.1） |
| CTX-018 | 预算裁剪后的引用行与协议复核 | 引用行 segment `.derivedPage`、role **`.user`（不得 `.system`）**；引用行 token 计入 `BudgetPlan.estimatedTokens` 与 hard limit；计入后超 hard 先继续淘汰，为容纳引用行而追加淘汰后必须**重算引用行（清单不得漏列被移出 id）**，仍超 → `BudgetError`；`plan.selected` 必须再过 `ContextRequestValidator`，失败 → `failed / streamProtocolViolation` | 阶段 1 引用行是 `.system` 且不计预算；Phase 1.1 契约 §2.7/§2.8；引用行重算见 `4276281` | 1 | L1 | 已覆盖（阶段 1.1） |

### CACHE 组 — Prompt Cache 证据

| ID | 场景 | 期望行为 | 1.x 证据 | 阶段 | 层 | 状态 |
|---|---|---|---|---|---|---|
| CACHE-001 | 上游 usage 掉数据 | 客户端结构指纹（hash/bust/appendOnly/epoch）与上游遥测分轨记录；上游缺失不得算成客户端 bust | `ContextCacheController.recordFingerprint`、`ClientStructuralCacheHealth` | 1 | L1 | 待继承 |
| CACHE-002 | 缓存断点位置 | 由内核 cachePlan 决定（对应核心工具数量），插件无权自行判定 stable/volatile | `AnthropicMessagesProvider.swift:206-211` | 2 | L2 | 待继承 |
| CACHE-003 | 撤回/回退历史 | 不得伪造缓存命中：必须推进 epoch 并标 `status=invalidated` | `ContextCacheController.reconcileAfterRevert` | 1 | L1 | 待继承 |
| CACHE-004 | 上报命中率 | 同时给原始 token 与分母，并说明块粒度量化边界；禁止把量化后的连续值当精确比率解读 | 实测 `cacheReadTokens=16384 / previousPromptTokens=26555 ≈ 61.7%`，16384 为块量化值 | 5 | L4 | 待继承 |
| CACHE-005 | 前缀里混入每轮可变条目 | goal anchor、后台通知、子代理回执、检索内容一律不得并入特权前缀——这是 1.x 命中率天花板的直接成因 | 同上 live-audit；`missDiagnostics` 显示增量历史吃掉约 10,171 token | 1 | L1 | 待继承 |
| CACHE-006 | 某 Provider 不报缓存字段 | 五个 usage 字段允许缺失，**缺失不等于 0**，并独立上报"无缓存遥测" | `CrossProviderCacheArchitectureTests.providerC_NoCacheTelemetry…` | 2 | L2 | 待继承 |
| CACHE-007 | 同 Run 跨 Step 的 usage 汇总 | 每个字段独立做"非 nil 求和"；该字段全程缺失 → nil；显式 0 保留并参与求和（缺失 ≠ 0） | 阶段 1 用 `??` 取首个非 nil 值，后步数值覆盖前步；Phase 1.1 契约 §2.8 | 1 | L1 | 已覆盖（阶段 1.1） |

### PROV 组 — Provider 语义（详单见 `Provider-Plugin-Contract.md`）

| ID | 场景 | 期望行为 | 1.x 证据 | 阶段 | 层 | 状态 |
|---|---|---|---|---|---|---|
| PROV-001 | 任意流 | 恰好一个终态；终态后无事件；无终态信号必须报错；`(toolCall 完成 > 0) == (终态 == .toolCalls)` | `ModelGateway.swift:393 ModelBus` | 2 | L2 | 已覆盖（阶段 1） |
| PROV-002 | 工具增量跨 delta 分裂、id/name 迟到 | started 只发一次；arguments 每字符恰好一次；最终非 JSON object 必须失败 | `ToolCallBuffer`、`OpenAICompatibleProvider.swift:880` | 2 | L2 | 待继承 |
| PROV-003 | 跨轮回传工具结果 | 领域 id 由内核合成；厂商原生 id 仅作 provenance，绝不当领域 id | `ProviderProvenance.swift` | 2 | L2 | 待继承 |
| PROV-004 | 限流 / 5xx / 超时可重试，401/402/403/404/409/413/415/422/423 与 content 类不可重试；**语义先于状态码** | 可重试集合封闭；body 嗅探覆盖 `rpm/tpm exhausted`、`429001`、额度不足、`context_length_exceeded`、合规、模型不存在 | `ProviderErrorClassifier.swift:51` | 2 | L2 | 待继承 |
| PROV-005 | 重试时机 | 只在任何事件交付之前重试；重试不重复产生工具事件 | `rateLimitedRequestRetriesBeforeAnyProviderEvent`、`retryDoesNotDuplicateToolEvents` | 2 | L2 | 待继承 |
| PROV-006 | 429 冷却 | 按 (provider, model, account) 设冷却；取时点必须在记录限流**之前**，否则 9.6ms vs 10ms 假失败 | `3e60033` | 2 | L2 | 待继承 |
| PROV-007 | 超时与心跳 | 类目下限 300s、idle 下限 120s；心跳只刷看门狗、不外传；排队不吃推理预算 | `ModelGateway.swift:129` | 2 | L2 | 待继承 |
| PROV-008 | stop reason 映射 | Chat/Anthropic 各形态（含顶层多形态兼容）；Responses 无 reason，由 completed + 是否完成调用推导，`incomplete` 记 maxTokens | `ResponsesStreamStateMachine` | 2 | L2 | 待继承 |
| PROV-009 | reasoning 内容 | 不支持时不凭空产生；Chat 需读双字段；Responses 需显式请求 summary 且 encrypted_content 回放**保持原顺序** | `OpenAIResponsesProvider.swift:397,572` | 2 | L2 | 待继承 |
| PROV-010 | 多模态与文件 | 声明不支持则不发 image；assistant 轮含图片或 tool_result 必须报错而非静默丢；Files API 仅在真实支持时启用 | `AnthropicMessagesProvider` 多模态分支 | 2 | L2 | 待继承 |
| PROV-011 | 缓存字段名 | 十种拼法归一；`cacheWrite` 仅 Anthropic 报得出，缺失不填 0 | `OpenAICompatibleProvider.swift:806-856` | 2 | L2 | 待继承 |
| PROV-012 | 输入上限计算 | reservedOutput / toolSchema / protocolOverhead(256) / safetyMargin(1024) 各自单列扣一次，不得合并字段导致重复扣减 | 1.x 注释明确警告 | 2 | L2 | 待继承 |
| PROV-013 | `tool_choice` | auto 必须**省略字段**而非发字面值；required 且 tools 为空本地拒绝 | 1.x adapter 分支 | 2 | L2 | 待继承 |
| PROV-014 | 孤儿 tool_call | 发送前本地剪除 | `sanitizeMessagesForContract:223` | 2 | L2 | 待继承 |
| PROV-015 | base URL 已含 `/v1` | 不得拼出 `/v1/v1/messages` | 1.x 修复记录 | 2 | L2 | 待继承 |
| PROV-016 | 可用性探测 | one-token 流式定论；429 视为可达，仅 403/404 不可用；`/v1/models` 超报不可作依据；结果按账号记忆 | `ModelAvailabilityAndDiscoveryTests`(32) | 2 | L2 | 待继承 |
| PROV-017 | 未知协议 / 未声明差异 | 硬失败，不静默 fallback；不做 host 名特判；差异必须落成类型化能力字段 | `resolveDriver`（反面） | 2 | L0/L2 | 待继承 |

### IPC 组 — 子进程与传输

| ID | 场景 | 期望行为 | 1.x 证据 | 阶段 | 层 | 状态 |
|---|---|---|---|---|---|---|
| IPC-001 | 子进程写完最后一行立即退出 | 该行不得丢失；**只有进程确实退出后才算 EOF** | `e058b29` | 2 | L2 | 待继承 |
| IPC-002 | 子进程 stderr 持续大量输出 | 必须有界排空（环形缓冲 256KB，丢最旧），不得死锁子进程 | `StderrRingBuffer`、`IPCPeerRobustnessTests` | 2 | L2 | 待继承 |
| IPC-003 | 请求发出后无应答 | 必须有 deadline 并抛**命名**错误；连接忙不等于慢 | `619f917`、`7b2ef16`、`StdioConnectionDeadlineTests` | 2 | L2 | 待继承 |
| IPC-004 | 看门狗只持传输弱引用 | 不得出现"既无答案也无看门狗"的请求；`deinit` 必须 resume 全部 pending；超时一律 silence-bound | `afa5356` | 2 | L2 | 待继承 |
| IPC-005 | 逐次 cancel 轮询流的取值 | 不得吞事件；必须单条长驻 pump + 轮询采集值 | `fcbf10d` | 2 | L2 | 待继承 |
| IPC-006 | 超帧上限入站 | 硬上限（32MB）拒收并计入协议违规，防 OOM | `IPCRobustnessContractTests` | 2 | L2 | 待继承 |
| IPC-007 | 父进程（宿主）退出 | 插件进程树必须被级联回收，不留孤儿 | `640e47a`、`ManagedProcess:terminate` | 2 | L2 | 待继承 |
| IPC-008 | 阻塞读放在协作线程池 | 会占死 worker；必须专用线程或非阻塞逐行读；看门狗周期收紧 | `3ebecff`、`837b3ad` | 2 | L2 | 待继承 |
| IPC-009 | 握手失败 | 必须命名到底哪个能力不可用，不得只报裸 transport 错误 | `1747a51` | 2 | L2 | 待继承 |
| IPC-010 | 等待对端 EOF | 关父端写柄使 EOF 成立；不得在 task 里等对端并调用 `synchronize()` | `4219b7a`、`7b2ef16` | 2 | L2 | 待继承 |
| IPC-011 | 上游/插件送回未知枚举值 | 降级为 `.unknown`，不得抛；未知可选字段忽略 | `EnumDecoderRobustnessTests` | 2 | L2 | 待继承 |

### PLG 组 — 插件生命周期、隔离、Hook

| ID | 场景 | 期望行为 | 1.x 证据 | 阶段 | 层 | 状态 |
|---|---|---|---|---|---|---|
| PLG-001 | 禁用状态下扫描到插件可执行文件 | **registry 为唯一真相源**，未启用不得拉起进程 | `discoverAndStartAll`（反面） | 2 | L2 | 待继承 |
| PLG-002 | 禁用一个正在跑的插件 | 八步撤销序列走完：路由表清除、在途收敛、租约 revoked、事件流与 Hook 卸载、进程树终止、前端 unregister、状态落盘 | `syncPluginCommands` 只增不减（反面） | 3 | L2 | 待继承 |
| PLG-003 | 能力撤回 | 租约状态 `armed/used/expired/revoked` 明确可查，撤销后调用返回未注册错误 | `MCPRuntime:MCPLeaseState`（1.x 唯一做对的撤销样板） | 3 | L2 | 待继承 |
| PLG-004 | 插件进程崩溃 | 由 `terminationHandler` 携带退出码/信号/stderr 尾部合成结构化故障；不得靠"下次调用看 isRunning" | `PluginProcessHost`（反面） | 3 | L2 | 待继承 |
| PLG-005 | 连续故障 | 熔断计数 + 指数退避重启；超阈值标 `failed` 并撤销路由；**不得静默永久失能** | 一次超时即 terminate 判死全 host（反面） | 3 | L2 | 待继承 |
| PLG-006 | 声明 `intercept` 模式的 Hook | 真的被调用，返回能否决请求、改写参数、要求人工确认；`observe` 模式不得阻塞 | `broadcastHook`/`emit` 零调用方（反面） | 3 | L1/L2 | 待继承 |
| PLG-007 | 模型调用插件注册的工具 | 调用路径真实存在并抵达插件（1.x `executePluginTool` 无调用方，插件工具永不被调用） | `PluginToolRuntime`（反面） | 2 | L2 | 待继承 |
| PLG-008 | 插件/sidecar/工具子进程环境 | 严格 allow-list；sentinel 探针证明 passphrase 与 `*_API_KEY` 进不去，且 `PATH`/`HOME` 存活；**MCP 侧不得豁免** | `1b4b31e`、`CredentialNonLeakageTripwireTests`、`EnvironmentSanitizer` | 2 | L2 | 待继承 |
| PLG-009 | 能力与权限声明 | 无默认值兜底；不显式声明就不通过 | `ProtocolVersionContractTests`、`RuntimeCapabilities` 去默认参数 | 2 | L0 | 待继承 |
| PLG-010 | 协议公开类型无生产者或消费者 | CI 失败（带显式 allow-list） | `OrphanContractTests` | 2 | L0 | 待继承 |
| PLG-011 | 协议 major 不匹配 | 拒绝加载并报明确错误；minor 取能力交集；`minimumCoreVersion` 仅作人类提示 | `PluginIPC.supportedVersions`、`ProtocolVersionContractTests` | 2 | L2 | 待继承 |
| PLG-012 | 并发请求 + 流式事件共用一根管 | 响应按 id 路由，通知无 id，事件流按 streamId 多路；**不得退回串行一问一答** | `VNextStdioTransport`（正面样板） | 2 | L2 | 待继承 |
| PLG-013 | 插件实际行为越出 manifest 声明 | 记为权限违规，终止进程并标 `failed`，前端告警 | 1.x 无此机制（缺口） | 3 | L2 | 新增 |
| PLG-014 | 插件在工具批次中间崩溃 | 走内核恢复矩阵：只读可重跑，可变记状态未知，副作用不重复 | LOOP-008 | 3 | L2 | 待继承 |
| PLG-015 | 新版 Host 加载只认识旧 `abiMajor` 的插件；或结构体尾部新增字段 | 主版本不符**硬失败不静默兼容**；同主版本下按 `structSize` 判定字段可用性，旧插件读不到新字段也必须正常工作 | E-15（OpenTUIShim 无 size/version 字段） | 2 | L2 | 新增 |
| PLG-016 | `security` 类 Hook 超时、崩溃或返回非法值 | **一律判拒绝并要求人工确认**，不得默认放行；插件不能通过声明 `observe` 逃避 fail-closed，类别由内核判定 | Phase 0.1 决策第 4 条 | 3 | L1/L2 | 新增 |
| PLG-017 | 签名策略 | `restricted` 下拒绝非本 Team ID 插件；`permissive` 需用户显式开启并显示告警；ad-hoc 签名不得进入发布通道，开发模式加载必须标注不受信；`codesign --verify --strict` 通过不等于 Developer ID 或公证 | `Docs/browser check/` 两份 PoC；`Vendor/OpenTUI/0.5.10/ABI-MANIFEST.txt` | 2 | L2 | 新增 |
| PLG-018 | 插件 dylib 在其 Host 内段错误 | 只有该 Host 进程死亡；Core、前端、其他插件的 Host 全部存活，受影响 Run 收到 `crashed` 结构化故障 | 项目书 §七第 5 条 | 3 | L2 | 新增 |
| PLG-019 | 插件与 Host 的 Swift 运行时 | 插件不得静态嵌入 stdlib；同一 Host 地址空间内只能有一份 Swift 运行时 | 1.x 全仓 `@_cdecl` 零命中，此为首例 | 2 | L2 | 新增 |

### STORE 组 — 持久化、配置、凭据

| ID | 场景 | 期望行为 | 1.x 证据 | 阶段 | 层 | 状态 |
|---|---|---|---|---|---|---|
| STORE-001 | 终态写入与内存变更顺序 | 先落盘成功再改内存；写失败回滚内存并截断事件 | Round 19 | 1 | L1 | 已覆盖（阶段 1；1.1 加固：append 失败进入 repairRequired→rollBack 修复，见 STORE-009） |
| STORE-002 | 账号引用 `{env:NAME}` 在 Dock 启动进程里不可解析 | 不发注定失败的请求，报出变量名；`LINGXI_<ID>_API_KEY` 覆盖优先 | `4ec856a` | 4 | L1 | 待继承 |
| STORE-003 | 存储迁移时机 | `start()` 内禁止迁移（源码级门禁），避免隐式写库 | `4ec856a` | 1 | L0 | 待继承 |
| STORE-004 | 历史时间戳格式 / 排序精度 | 读取端容忍历史格式；需要排 page-out 与 cache bust 先后处必须毫秒精度 | `c5d00b5`、`0d9761d` | 1 | L1 | 待继承 |
| STORE-005 | 凭据库 KDF | cost 写进 header 且可用低值测（生产 600k 轮使每个 store 4s 拖死测试） | `5e9083c` | 4 | L1 | 待继承 |
| STORE-006 | 会话摘要字段 | 各构造点都要带 goal；重命名/改力度/回退不得清空；列表缓存分支需覆盖活值 | `8865b66`、`9b81345` | 4 | L1 | 待继承 |
| STORE-007 | 只读查询接口 | 不得回写任何状态（1.x 热度过期值被只读快照接口写回）；测试须用量级正确的 `now`，远期值会掩盖 underflow | `b49111e` | 1 | L1 | 待继承 |
| STORE-008 | 事件日志全量重放 | 用重放结果重建**全新** `SessionStore` 与 `RunRegistry`（不复用旧实例）：条目按实时规则重放（含 User 降级 CTX-017），Run 状态与终态与事件一致；连续重放两遍结果一致（幂等） | 1.x 重启恢复矩阵只覆盖 Run 终态，未证明全量重建；Phase 1.1 契约 §1.2 | 1 | L1 | 已覆盖（阶段 1.1） |
| STORE-009 | 事件日志损坏与写入失败 | 打开时只允许**末尾**一行损坏：截断并计数 `repairedTailRecordCount`，新记录仍可写；非末尾坏行 → `undecodableLine` 拒绝打开；`append` 失败后进入 `repairRequired`（除 `rollBack` 外一律拒绝），`rollBack` 成功即修复；`rollBack` 失败 → `rollbackFailed`，此后日志 `unavailable` 拒绝写入 | 1.x `FileEventLogSink` 遇损坏尾行按 `undecodableLine` 拒载（Kernel-Design D3 遗留缺口）；Phase 1.1 契约 §1 | 1 | L1 | 已覆盖（阶段 1.1） |
| STORE-010 | begin() 事务失败 | `runCreated + runStarted + user entry` 单事务失败 → rollBack、内存 Run 记录 `discard`，返回 failed 且 `terminalCommitted == false`；**不得补写孤立 runTerminal**；SessionStore 不变 | 阶段 1 事务失败后仍走终态化、留下孤立终态记录；Phase 1.1 契约 §2.3 | 1 | L1 | 已覆盖（阶段 1.1） |

### FE 组 — 前端协议与 TUI

| ID | 场景 | 期望行为 | 1.x 证据 | 阶段 | 层 | 状态 |
|---|---|---|---|---|---|---|
| FE-001 | wire 载荷新增带标签的字段 | 合成 Codable 会使其变必填并打断既有 wire；两种形状都要断言 | `2f1871c`、`FrontendWireSubmitPromptShapeTests` | 4 | L2 | 待继承 |
| FE-002 | 断连重连 / 切换会话 | 待答的权限与提问卡状态可恢复；切换会话不得复活过期审批卡 | `4ec856a`、`AgentLoopEndToEndTests` | 4 | L2 | 待继承 |
| FE-003 | 流式回放有界 | 已关闭流保留条数有上限，超窗口或宽限期后清 payload；revert 必须彻底 reset 流状态 | `acd8cf4`、`StreamReplayLifecycleTests` | 4 | L2 | 待继承 |
| FE-004 | 调试遥测 | 不得改变任何发往模型的请求（先断言数量再断言内容，且共享同一工作区）；环形缓冲满不得越界 | `ec84c78`、`RuntimeObservatoryBypassTests` | 1 | L1 | 待继承 |
| FE-005 | HTTP 接受短连接探测 | 0ms 可写探测即关闭时不得误发内容；客户端承诺 503 时读 0 字节；短消息不得等 EOF | `147354f`、`4219b7a` | 4 | L2 | 待继承 |
| FE-006 | 终端尺寸变化 / 长任务 / 大输出 | 无撕裂、无错位、无内存无界增长；Core 崩溃时 TUI 给出诊断而非随之退出 | 1.x 无对应资产（缺口） | 4 | L3 | 新增 |

### QA 组 — 测试与门禁卫生

| ID | 场景 | 期望行为 | 1.x 证据 | 阶段 | 层 | 状态 |
|---|---|---|---|---|---|---|
| QA-001 | 测试构造工具结果 | 禁止手工造结果直塞内核；必须跨真实执行与被调用方边界（截断、归档、投影都在被调用侧） | `Docs/AA/PE-Core-ToolLoop-Audit-2026-10-04.md` §H | 1 | 评审 + L0 | 新增 |
| QA-002 | 时间相关测试 | 禁止固定 `Task.sleep`；用注入时钟或 poll-to-deadline | `27b1899`、`67604b8`（flake 反复修） | 1 | L0 | 新增 |
| QA-003 | 端到端 oracle | oracle 必须真跑 Agent 并核查世界状态，不得用 `swift test --filter` 代替、不得 `exit 0` 兜底 | `Evals/Runner/main.swift`（反面） | 3 | L3 | 新增 |
| QA-004 | 基线非劣性 | 零翻转硬失败；p50 耗时/工具数/成本劣化 ≤ 5%；钉模型与协议版本；离线与真凭据分轨 | `Evals/*/task.json` 判据设计 | 5 | L4 | 待继承 |
| QA-005 | 录制回放 | 只替换传输层、保留真实解析器；严格匹配不回落；提升金标准需 secret scan + 人工批准 + 断网重放 | `Tests/LingXiAgentTests/VCR/README.md` | 2 | L2/L4 | 待继承 |
| QA-006 | 契约类型孤儿 | 无生产者或消费者的公开契约类型使 CI 失败 | `OrphanContractTests` | 2 | L0 | 待继承 |
| QA-007 | CI 分块 | 每块独立 watchdog + 一次隔离重试；落 event-stream 输出以在 kill 后指名卡住用例；发现 0 用例即失败；skip 计入已报告 | `Scripts/ci-integration-tests.sh`（机制） | 2 | CI | 待继承 |
| QA-008 | 冷却/退避时序 | 取时点顺序正确，避免 9.6ms vs 10ms 假失败 | `3e60033` | 2 | L1 | 待继承 |
| QA-009 | 基线数据来源 | 合成数据不得作为实测呈现（1.x 每任务恒 4000 cacheReadTokens 是 VCR 合成） | `Evals/Baselines/*/summary.json`（反面） | 5 | L4 | 新增 |
| QA-010 | 结构门禁实现 | 直接解析 `Package.swift` 断言依赖方向，不维护第二份清单 | `CoreDependencyGraphGateTests` | 1 | L0 | 待继承 |
| QA-011 | 真实网络与凭据 | 默认零外呼；真上游 env 门禁且在独立 job；CI 隔离 `HOME` 与数据目录 | 1.x CI 环境变量门禁组 | 2 | CI | 待继承 |
| QA-012 | 验收记录 | 每条验收含实测数字、trace 顺序与**反例**（把 bug 注回后测试必须变红） | `Docs/Validation/`（1 例） | 2 | 评审 | 待继承 |
| QA-013 | 无 Provider 的空内核启动与运行 | 启动预检 `router.resolve(model:)` 先于任何事件：失败 → `failed / runtimeFailure`，detail 为引导文案，`terminalCommitted == false`；日志 0 记录、RunRegistry 无记录、SessionStore 不变；CI 另有独立步骤断言 `events.jsonl` 不存在或为空 | 阶段 1 空内核运行会写 `runCreated`/`runTerminal` 等无意义日志；Phase 1.1 契约 §2.1 | 1 | L1 + CI | 已覆盖（阶段 1.1） |

---

## 第三部分：明确不继承（标注规模，便于阶段收尾时核对）

| 类别 | 规模 | 废弃原因 |
|---|---|---|
| P/E 双核与检索阶段测试 | 约 45 文件（占 Tests 的 ~18%）：`Round4–20`(17)、`RewindPhase1–8`(8)、`UnifiedRetrievalPhase*`(7)、`ECore*`(7)、`PE*`(6)、`PCoreTerminologyGateTests` | 架构废弃（E-01）。其中约 20 条真实数据流断言值得重写为上面 CTX 组条目，其余随架构消失 |
| GUI / SwiftUI / AppKit 测试 | 21 文件 import SwiftUI/AppKit/FrontendKit + `Apps/macOS` 全链 | 项目书 §四明确不再继续原生 GUI |
| 跨平台兼容 | 23 文件带 Windows/Win32 分支；`PlatformBuildGate`、`CompatibilityMatrix`、`DarwinDesktopBackend`、`LinuxSandboxMount`、`PlatformCryptoKAT`、三平台 CI job；`PortableFixture`；CI 脚本里的 MSYS pid 换算与 CRLF 算术防御 | 项目书 §四明确首发单平台 |
| 数百家 Provider 适配 | `BuiltinProviderCatalog`、`ModularProviderRegistry`、`PublicProviderConfiguration`、`ProviderWorkloadAudit`、`ProviderPrivilege` + 27 家产品 × 5 列验收表 | E-04。只保留三家 wire 的语义级断言 + 一个 Provider 无关的 adapter 契约骨架 |
| 许可/仓库流程门禁 | `LicenseMatrixDriftTests`、CODEOWNERS 流程 | 需保留机制但**必须先重写矩阵内容**，否则门禁检查的是一张过期表 |
| 依赖真实调用的 Provider 目录测试 | 大量目录/兼容性矩阵断言 | 方向错：测的是清单而非内核语义，13 套 Provider 测试里语义部分才值得继承 |

## 第四部分：待补充的空白

以下是 1.x **未找到**对应资产、2.0 必须从零建立的项，登记以免被误认为"已覆盖"：

1. 注入式虚拟时钟（超时、冷却、退避、水位触发全部需要确定性）。
2. 真 Plugin Host + 故障插件 dylib 的进程级注入：段错误退出、挂死沉默、非法帧/非法结构体尺寸、无应答、越权访问、读到宿主凭据（PLG-015~019）。
3. 插件权限声明与运行期实际行为的可核对性机制（PLG-013）。
4. TUI 端到端测试层（假 PTY 驱动）。
5. 真实 Provider 金标准 cassette 库（当前近乎为空）。
6. 跨 Provider 的系统性缓存命中率统计（当前仅一处 43 请求的 smoke）。
7. Hook 生效性的端到端证据（1.x 连一条完整链路都没跑通过）。
