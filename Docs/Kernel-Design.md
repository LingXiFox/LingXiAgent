# LingXiAgent 2.0 内核设计

依据：项目书 §3.1（最小 Agent 内核）、§3.4（上下文与缓存）、§五（重构工作原则）、§七（完成标准）。
继承来源标注 `Regression-Cases.md` 的条目 ID；未标注的内容是 2.0 的新决定。

## 一、内核职责白名单

内核只做且必须做完整以下五件事：

1. 运行基础 Agent Loop：模型交互、工具请求、结果回传、任务终止。
2. 管理传统单一会话上下文，保障对话与任务连续性。
3. 提供上下文压缩、预算管理与 Prompt Cache 效率的必要能力。
4. 维持执行状态、取消、错误反馈与会话一致性。
5. 作为插件宿主，用插件提供的能力运行。

**内核不含**：任何 Provider 实现或厂商特判；任何工具实现（文件、命令执行、Git、Browser、MCP、LSP、记忆、子代理）；任何 UI 代码；P/E 双核与自主召回；面向数百家 Provider 的兼容矩阵。

判据：空内核在没有任何 Provider 插件时必须能启动、展示状态并引导配置，但不能发起推理，且启动与运行不得写下任何无意义的事件日志（项目书 §3.1、§七第 1 条；QA-013）。这条是阶段 1 的验收主体。

## 二、进程形态与模块边界

Core 是一个**可执行运行时进程**，不是被前端链接的库。TUI 与其他前端是独立进程，通过前端协议连接 Core；Core 反过来是插件的父进程。

```
TUI 进程 ──前端协议──> Core 进程 ──内部 IPC──> Plugin Host 进程 ×N ──C ABI──> 插件动态库
                        │
                        └─ 内核 + 插件宿主 + 持久化
```

插件不是 Core 的直接子进程对端，而是被 Plugin Host 用 `dlopen` 加载的动态库；Core 只与 Host 讲 IPC，插件作者不接触 IPC。分层与理由见 `Plugin-System-Design.md` 第一章。

理由：① 前端与内核解耦是 1.x 已经做对的部分（`lingxiagent` 在许可矩阵里明确标注 "strictly decoupled from Core"，CoreHost 承担 stdio 服务进程）；② 只有 Core 独立成进程，"不重新编译 Core 即可换 Provider"才成立；③ TUI 崩溃不该拖垮正在跑的任务，反之亦然。

模块划分（阶段 1 已建立 `LingXiKernel` 与 `LingXiCoreHost` 两个 target 加一个测试 target，其余按阶段推进；依赖方向现在就固定）：

- 内核：Agent Loop、上下文、执行状态、持久化。
- 协议：内核与插件、内核与前端共享的类型契约，**不含实现**。
- 平台层：进程、文件、终端、安全存储。只此一层允许触碰 Darwin API。
- 宿主：把内核装进可执行进程，含插件监管者。
- 前端与插件：不在内核依赖图内。

依赖方向由 L0 结构门禁自动检查：内核不可达 UI、不可达任何具体 Provider 或工具实现，协议公开类型必须有生产者与消费者（QA-006）。1.x 的 `CoreDependencyGraphGateTests`、`OrphanContractTests` 手法照搬。

## 三、Turn / Run / Step 模型

```
Session
 └ Turn（一次用户提交，含本轮附件）
    └ Run（一次执行实例）
       └ Step*（模型请求 → 工具批次 → 结果回传 的一次交替）
```

**一个 Session 同时只允许一个 active Run**（D1）。多轮排队、优先级、后台任务编排不在内核——移到产品层/插件层。理由：1.x 该区域 Round 12–20 的绝大多数缺陷源于「队列 × 终态化 × 崩溃恢复」三者交叉，不是单点 bug（`Regression-Cases.md` 第 2 节经验 E-02）。内核保留两条硬约束：终态化只有一个赢家（LOOP-001），终态先落盘再改内存（STORE-001）；排队语义一旦引入就要重做这套证明，故不做。

Run 状态机：

| 状态 | 进入条件 | 允许迁出 |
|---|---|---|
| `pending` | Run 已创建、尚未拿到执行租约 | `running` / 终态 |
| `running` | 拿到租约，`runCreated` 事件已落盘 | `terminating` / `interrupted` |
| `interrupted` | 等待人工应答（权限、提问）或等待插件超时恢复 | `running` / `terminating` |
| `terminating` | 已确定终态，正在落盘 | 终态 |
| 终态 | `completed` / `cancelled` / `failed` / `stepLimitReached` / `deadlineExceeded` / `budgetExceeded` | — |

终态化必须满足四条（LOOP-001、002、STORE-001）：

1. 终态事件先写入持久化，写成功才改内存状态；写失败必须截断已追加的事件并把内存回滚到写之前。
2. 只有一个赢家：非终态检查 + 幂等守卫，第二次对同一 Run 的终态化尝试返回"没有发生迁移"，绝不推进任何后续。
3. 终态与原因绑定写入。取消不得覆盖已投递的真实故障（LOOP-006）。
4. `runCreated` 恰好一次。

## 四、Step 循环与终止判定

一个 Step 的顺序：装配上下文与预算 → 向 Provider 插件请求模型流 → 聚合事件（文本/推理增量、工具调用完成）→ 无工具调用则终止，有则执行工具批次并把结果作为下一步输入回传。

**内核只有基于硬边界的终止权威**（D2）。终止条件封闭列举：

- 模型本轮未产生任何工具调用 → `completed`（含空完成 `.emptyCompletion`）。
- 用户取消 → `cancelled`。
- 显式步数上限（默认无上限）→ `stepLimitReached`，报错须含步数、最后一个工具调用、最后一次观察。
- 截止超时 → `deadlineExceeded`。
- Provider 流失败 → `failed`，保留真实原因。
- 上下文预算无法满足 → `budgetExceeded`。

**内核不做**：基于"看起来没进展"的启发式硬停；用正则识别模型自述"我已完成/我已创建"来判断真实性。这两样 1.x 都实现过：进度跟踪器经历三次重写、其硬停权威最终被自己废除（注释改为 "never authority to stop a model"）；完成声明守卫的中英正则误伤面大，多条保守妥协记录在案。**结论**：内核只保硬边界，把"任务是否真的完成"交回模型与用户在 TUI 层判断（E-03、LOOP-012、LOOP-013）。空结果、空 stdout、相同失败重复出现在这种口径下都不得终止循环——这三条 1.x 用真实批次跑通过，作为回归案例继承。

## 五、工具批次语义

一条 assistant 消息里的多个工具调用构成一个**因果批次**，是上下文里不可拆分的单位。

规则（LOOP-005、CTX-009）：

1. **并行执行、有序结算**。执行顺序不保证，结算顺序严格按 Provider 给出调用的顺序；结果合并进同一条 tool 消息。
2. `callID ↔ result` 严格配对；同一批次内出现重复 callID，**整批拒绝**，不做去重容忍。拒绝发生在写任何持久化记录**之前**（`677d44e` 加固）：非法 call 条目不得进入事件日志，否则一次失败 Run 会永久污染会话、后续每个请求都过不了协议校验（LOOP-005）。
3. 读共享波次：同批次内只读调用可共享一次实际执行，但**写操作使其失效**。`read a → write a → read a` 第三次必须真执行并返回新字节；目录列表不可被该目录内的写入复用；陈旧读不得写入会话存储，也不得进入下一次模型请求（LOOP-015、CTX-003）。1.x 用 `ReadConsistencyTests` 数真实执行次数来断言，这个"数执行次数"的手法要保留。
4. 每个调用带效果分类（只读 / 可变 / 未知），恢复流程据此决定能否重放（第六章）。
5. 批次状态持久化：`pending → settledAwaitingConsumption → consumed`。未消费的批次是 mandatory 上下文，压缩时不可淘汰（CTX-009）。

工具实现一律来自插件（项目书 §3.1 约束）。内核只见"执行一个已注册工具调用"这一抽象；工具的 schema 来自能力清单，不来自内核。

## 六、执行状态、持久化与崩溃恢复

存储形态（D3）：**追加式事件日志 + 定期快照**，阶段 1 不引入 SQLite。理由：1.x 的崩溃正确性来自"终态先落盘 + 单一赢家 + 恢复矩阵"这套纪律，而不是来自 SQLite；但因果批次与租约状态确实需要事务性提交，阶段 2 若事件日志无法满足原子性，再评估换存储，并作为 ADR 记录。

**恢复策略（Phase 1.1 冻结口径，LOOP-003、LOOP-025、STORE-008~010）**。恢复入口是 `KernelRecovery.recover(log:)`：只读重放 + 重建全新内存对象；唯一允许的写入是给未终态 Run 追加 `runTerminal` 失败记录。恢复期间**绝不调用 ToolExecutor、绝不重发模型请求**。

1. **打开日志**：只允许**末尾**一行坏数据——截断并计入 `repairedTailRecordCount`；非末尾坏行 → `EventLogError.undecodableLine`，拒绝打开。`append` 失败后日志进入 `repairRequired`（除 `rollBack` 外一律拒绝）；`rollBack` 失败 → `rollbackFailed`，此后日志 `unavailable`，不可再用（STORE-009）。
2. **重放重建**：按序重放 `runCreated / runStarted / entryRecorded / batchStarted / batchSettled / batchConsumed / runTerminal`，用与实时路径相同的规则重建**全新** `SessionStore` 与 `RunRegistry`（含 User 降级规则 CTX-017，不复用旧实例）；重放两遍结果必须一致（STORE-008）。
3. **批次对账**（历史自愈，仅内存、确定性）：
   - `batchSettled` 有、对应 `entryRecorded(result-<batch>)` 缺 → 用 settled outcomes 合成结果条目并插到 call 条目之后（settled-unconsumed 自愈）。
   - `batchStarted` 有、`batchSettled` 缺 → **执行状态不确定**：合成 `isError=true`、`effect=.unknown` 的结果条目（内容含 `executionStateUnknown` 与 verification 要求），Run 记入 `executionStateUnknownRunIDs`，**绝不重放**。
   - 有 call 条目（unit=batchID）但无任何 batch 事件 → 崩溃发生在派发前，合成"未开始执行"错误结果，不记 unknown。
4. **终态化**：未终态 Run 一律 `terminalize(failed)`：有未结算批次 → cause `.executionStateUnknown`；否则 cause `.runtimeFailure`；detail 含 "recovered after restart"。
5. **恢复不继续执行**：被中断的 Run 不会被"接着跑完"，继续执行只能由下一次 Turn 重新发起。这比 1.x 的恢复口径更严格——1.x 在部分路径上允许只读工具补跑（LOOP-008），2.0 选择一律不执行：只读重跑的正确性依赖执行器与插件环境完整可用，而恢复阶段这两者尚未建立；宁可显式标未知，也不冒重复副作用的风险。

阶段 1 有两个恢复入口：宿主使用的 `KernelRecovery.recover`（完整语义）与 `RunRegistry.recoverUnfinishedRuns`（旧入口，仅把未完成 Run 终态化，没有 `executionStateUnknown` 语义）。Phase 1.2 收敛到 `KernelRecovery`，避免两套恢复口径并存。

同进程内的悬空批次也按同一套规则处理（`677d44e` 加固）：Run 在 call 条目落盘后、result 落盘前失败（例如 `batchStarted` append 失败）时，下一次 Run 在装配请求前按日志**确定性自愈**——`batchSettled` 已落盘 → 恢复结果条目；`batchStarted` 未 settled → 合成 `executionStateUnknown` 错误结果；call 条目存在但没有任何 batch 事件 → 合成 not started 错误结果。自愈只写内存、不追加日志；重启后由 `KernelRecovery` 从同一日志派生出等价历史（LOOP-025 加固）。两条污染路径因此都被封死：重复 callID 在持久化前拒绝，悬空批次在进程内下一次 Run 前自愈。

恢复矩阵（Phase 1.1 口径；"恢复动作"只操作事件日志与内存，**不执行任何工具、不发模型请求**）：

| 崩溃时刻 | 恢复动作 | 禁止 |
|---|---|---|
| Run 已创建未开始 | 标记 `failed(runtimeFailure)`，不重排执行 | 重新排队 |
| Run 在跑、无终态 | `failed`；有未结算批次时 cause `.executionStateUnknown` | 继续执行该 Run |
| 批次全部 settled 未 consumed | 重建结果条目进历史（settled-unconsumed 自愈），Run 仍 `failed` | 重跑工具、恢复执行 |
| 批次 started 未 settled | 合成 `executionStateUnknown` 错误结果，Run 记入 unknown 列表并 `failed` | 静默重放整批 |
| call 条目存在、无 batch 事件 | 合成"未开始执行"错误结果，不记 unknown | 重跑工具 |
| 等待人工应答时崩溃 | 阶段 1 内核无待答交互（`interrupted` 仅作状态占位）；阶段 2 引入交互后按"保持待答、回复后原批次精确续跑一次"实现 | 复活过期审批卡 |

核心不变式：**副作用不重复执行**。宁可留下"状态未知"并让模型去验证，也不自动重放写操作。1.x 在 `SessionRuntime` 里对"工具成功后崩溃导致意图丢失"做过 SQLite 控制面 + 单事务提交的修复，2.0 用事件日志也要满足同一条不变式（CTX-008 关联）。

会话一致性：Turn 期间会话修订号变化时，陈旧 Run 的终态以 `StaleRunError` 丢弃且**不落盘**（LOOP-014）。附件必须进入本轮实际发给模型的条目集合，而不是仅记账的集合；附件解析失败即让 Turn 失败，不静默降级（LOOP-016）。

## 七、取消与超时

取消（LOOP-006、007、011、017）：

- 取消是意图声明，不是错误。取消路径必须**静默结束**流，严禁伪造 `.failed`；Provider 自己先投递的失败必须保留为真实原因，不能被取消覆盖。
- 取消必须能竞争过阻塞中的 Provider 流：`stream()` 调用与流消费整体放进可竞争的任务，watchdog 用注入时钟等到剩余总超时；取消/超时先被观察到 → `cancelled` 或 `deadlineExceeded`，迟到事件丢弃、不伪造 provider 失败，已处理的终态事件胜出；已收到的 usage 部分照常汇总（LOOP-023）。
- Provider 自身抛出的 `CancellationError` 属 provider 失败（`.failed / .providerFailure(.transport)`），不得冒充用户取消；只有用户取消或内核 deadline 才产生 `cancelled / cancelledByUser`。Provider 契约（阶段 2）必须写明不得用 `CancellationError` 表达用户取消。
- 取消粒度：按 Run。取消一个不存在的 ID 必须在产生任何副作用前抛出命名错误。
- 取消发生在工具已完、下一次模型请求未发出时：Run 进 `cancelled`，已执行的工具不重跑。
- 取消后到达的迟到增量不得渲染上屏；已投递的增量保留；活动注册表清空。
- 内核必须把取消传播到插件子进程；宽限期后仍未停则杀进程树（`Plugin-System-Design.md` 第七章）。后台启动的子进程归属必须登记，取消时可回收（LOOP-018）。

超时（IPC-004）：

- 三类超时分开：握手、单次调用、空闲沉默。
- 一律 **silence-bound deadline**：计时基准是"最后一次收到任何帧"，而非请求起始时刻。心跳事件只用于刷空闲看门狗，**不外传**给前端与模型。
- 排队等待不得吃掉推理超时预算（1.x 在网关层明确注释过这条）。
- 看门狗对底层传输只持弱引用时，`deinit` 必须 resume 所有挂起请求，否则出现"既无答案也无看门狗"的请求（IPC-004）。

## 八、单上下文组装

放弃 P/E 双核与 E-Core 自主召回（项目书 §3.4、E-01）。组装顺序与分区：

| 序 | 区段 | 可变性 | 特权级 |
|---|---|---|---|
| 1 | `immutableInstructions`（system） | 恒定 | 特权指令通道 |
| 2 | 核心工具定义（按 id 恒定排序） | 恒定 | 数据 |
| 3 | 会话历史（user / assistant / toolCall / toolResult 逐 part 展开） | 单调追加 | 数据 |
| 4 | 因果批次（未消费部分） | 追加 | 数据 |
| 5 | 本轮附件 | 每轮 | 数据 |
| 6 | 派生页与引用行 | 半稳定 | 数据 |
| 7 | 易变环境事实（分支、cwd、平台） | 每轮可变 | 数据 |
| 8 | 内核告警类尾部条目 | 每轮可变 | 数据 |

规则：

1. **特权通道只有一个**：只有 `immutableInstructions` 能进模型的指令位置。检索、召回、引用行、插件 Hook 注入的任何文本一律走数据通道（CTX-001、CACHE-005）。1.x 曾把检索内容拼进 Anthropic 顶层 `system`，被列为 P0 缺陷，也是缓存命中率 61.7% 天花板的直接成因（CACHE-005 附证据）。
2. **工具清单在同一 epoch 内只单调追加，不删除、不改序、不重排**。schema 变化必须显式推进 epoch（CTX-002）。这条是被实测验证为"客户端结构前缀 100% 稳定"的基础：单 hash、bust=0、appendOnly 违规=0。
3. 分区判定按 segment 语义，不按来源标签。区域计费不得从 `ContextSource` 猜语义（把 8K 的召回载荷算进索引 token 是 1.x 实测出的 bug）。
4. 索引类投影不计入"持久历史"签名，否则查询词变化会被误报为"历史被改写"（CTX-011）。
5. 易变事实拆出并排在指令块之后，避免切分支或改目录击穿整个前缀（CTX-012）。

## 九、上下文预算与压缩

保留 1.x 已被证明有效的部分，丢掉从未校准的部分（E-05）。

**保留**：
- 水位策略：`highWater = preferred × 1.15`，`lowWater = preferred × 0.8`。起点是"全保留"，按分数从低到高逐个移出，降到 lowWater **立即停止**，不做多余压缩（CTX-008）。
- mandatory 底价：system、当前 user 消息、未消费的因果批次不可淘汰；mandatory 之和超过 hard limit 直接报 `budgetExceeded`，不硬塞。
- 以因果批次为最小移出单位。
- 移出时留一条**能精确指回原文的稳定引用行**，由模型显式请求回读（CTX-010）。引用行 segment 为 `.derivedPage`、role 为 **user**（不得冒充 system 指令），其 token 计入 `BudgetPlan.estimatedTokens` 与 hard limit；引用行列出全部被移出条目 id，因此为容纳引用行而继续淘汰时必须**重算引用行文本与 token**，直到 mandatory 底价 + 引用行仍不超 hard limit，仍超才报 `budgetExceeded`；裁剪后的 `selected` 必须重新通过协议校验，失败即按流协议违例失败，不静默发送（CTX-018）。
- 失败诊断证据（异常名、exitCode）必须在压缩与再投影后仍存活，且重复投影幂等（CTX-004）。

**丢弃**：
- 八维上下文价值权重评分器——从未用真实 trace 校准过。
- 经济 break-even 调度器（默认阈值 272,000 token，在 128K/24K 窗口下形同虚设，且会跳过本该压缩的轮次）。
- 全有或全无的大载荷处理——必须支持有界 partial 投影加 `continuation_offset`（CTX-006）。
- 逐工具的输出策略二次截断——截断只发生在被调用方一侧，且工具须自声明输出契约（CTX-006、QA-001）。

**工具原文可无损回读**是放弃自主召回后必须补的最小替代：载荷只有一个权威身份，预览不等于全文（CTX-005）。判据：`context_recall` 类回读返回的字节区间必须与头部声明逐字节相等；一次批次多个 artifact 时，range 不得串到兄弟条目（CTX-007）。

为什么不需要自主召回：1.x 真实 59 会话 207 对象的普查显示投影率 76.8%、**召回转化率 0.0%**——模型消费完前两轮全文就不再需要，宁愿重跑 read/grep。这两条最小替代买的是正确性与可回溯，不是命中率。

## 十、Prompt Cache 度量

目标是用**真实数据**解释复用率、成本与延迟（项目书 §七第 7 条），不是理论命中率。

1. 双轨遥测：客户端结构指纹（前缀哈希、bust 次数、appendOnly 违规、epoch 变化）为第一真相；Provider 回报的 cache read/write 为第二真相。两轨分开记录，上游丢数据不得算成客户端 bust（CACHE-001）。
2. 缓存断点位置由内核的 cachePlan 决定，插件无权自行判定 stable/volatile（CACHE-002）。
3. 撤回/回退后不得伪造缓存命中：必须推进 epoch 并把该轮标记 `invalidated`（CACHE-003）。
4. 命中率不是连续量：1.x 实测 `cacheReadTokens=16384` 是块粒度量化值，上报时须同时给原始 token 与分母，并说明量化边界（CACHE-004）。
5. `usage` 各字段允许缺失，**缺失不等于 0**；某 Provider 无缓存遥测必须独立上报这一事实（CACHE-006）。同一 Run 跨 Step 对每个字段做"非 nil 求和"：全程缺失为 nil，显式 0 保留并参与求和（CACHE-007）。
6. 客户端自算的 token 估算只用于预算与限流预判，不进成本报告；成本报告用上游 usage。
7. 不为命中率牺牲必要上下文、推理质量或任务正确性（项目书 §3.4）。判定方式见 `Testing-and-Acceptance.md` L4。

1.x 唯一的硬数据：9 任务连续会话、128K 窗口、43 个可比请求，客户端结构前缀 100% 稳定，Provider 回报读命中约 61.7%，且增量历史本身吃掉约 10,171 token。2.0 的阶段 5 要复现这条链路并把口径固定成脚本，而不是靠人工记录。

## 十一、内核对外抽象

内核只认三个抽象接缝，全部经由插件实现（契约细节在 `Plugin-System-Design.md` 与 `Provider-Plugin-Contract.md`）：

- **模型请求端口**：`stream(request) → 事件流`，加一次 `endExecution` 清理。能力靠事件与声明表达，不靠方法数量。无 `countTokens`——估算在内核侧。
- **工具执行端口**：按能力清单里的 id 与 schema 调用，带效果分类与超时。
- **生命周期管线**：模型调用前后、上下文准备、工具执行前后的 Hook 调用点，带类型化返回与否决语义（不能只收诊断）。

内核不含任何端口的实现，因此"没有 Provider 时能启动、不能推理"是结构上的必然，不是配置上的开关。三个端口全部由插件经统一握手与能力注册流程提供（`Plugin-System-Design.md` 第四章）：内核看到的是 bundle id 命名空间下的能力标识，看不到厂商、进程方式或 ABI 细节。

**阶段 1 未接线**：`endExecution` 清理路径尚未被内核调用。Phase 1.2 接入 Provider 插件前必须补上，否则 provider 的每个执行态没有清理（`Docs/Validation/Phase-1.1.md` 风险 8.1 第 1 条）。

## 十二、决策与待决

| ID | 决定 | 理由 | 可逆性 |
|---|---|---|---|
| D1 | 内核不实现多轮排队，单 active Run | 消除队列×终态×崩溃交叉缺陷面（E-02） | 中：可在产品层加队列而不改内核 |
| D2 | 终止权威只来自硬边界，取消启发式硬停与正则完成检测 | 1.x 两套机制最终都被自己废除或大量妥协 | 高 |
| D3（**有条件成立**） | 追加事件日志 + 快照，阶段 1 不引入 SQLite | 正确性来自"终态先落盘 + 单一赢家 + 恢复矩阵"这套纪律，不来自存储引擎；依赖最小 | 中：阶段 2 可按 ADR 更换 |
| D4 | Core 独立成进程，前端只走协议 | 满足"不重编 Core 换 Provider"，TUI 与任务互不拖垮 | 低（架构根基） |
| D5 | 上下文压缩保留水位+mandatory+因果批次，丢弃评分器与经济调度 | 前者被实测有效，后者从未校准且在真实窗口下形同虚设 | 高 |
| ~~Q1~~ | **已解决**：首发 macOS 26.2+ / Apple Silicon，Swift 6.4 开发工具链，`swift-tools-version` 暂定 6.2 | Phase 0.1 决策第 1 条；`.swift-version` 已同步为 6.4 | — |
| Q2 | 事件日志的快照触发阈值 | 阶段 1 实现期决定即可 | — |
| Q3 | 是否需要"最小历史检索"作为自主召回的替代 | 目前判定只需引用行 + 显式回读；若真实任务出现需要再开 ADR | — |

D3 的前提是**可靠恢复必须被验证**（Phase 0.1 决策）。阶段 1 的验收要求：恢复策略与矩阵的每一行都有对应测试，且能证明"因果批次落盘 + 租约状态变更"这一类多记录写入的原子性。若事件日志无法在不引入事务引擎的前提下满足该原子性，D3 立即失效并改选存储——这不是可以拖到阶段 5 的技术债。

阶段 1 的实际证明程度（Phase 1.1 更新）：日志层事务（begin marker + 失败截断 + `repairRequired`/`rollbackFailed` 状态机）、终态先落盘、单一赢家、未终态 Run 的终态化、全量重放重建（STORE-008）、尾部坏行截断修复并计数（STORE-009）、begin 事务失败不留孤立终态（STORE-010）均已纳入测试。**半行写入行为已定论**：进程被强杀或掉电留下末尾坏行时，重开只截断该行并计入 `repairedTailRecordCount`，不再按 `undecodableLine` 拒绝；只有非末尾损坏才拒载。仍未证明的是：非末尾损坏的自动恢复（当前策略是显式拒载而非猜测修复）、快照压缩路径，以及真实掉电（非进程级 kill）下的块设备行为。

**D3 结论（Phase 1.1）**：事件日志方案在阶段 1 范围内满足可靠一致性要求——单一终态赢家、终态先落盘再改内存、多记录提交（marker + 回滚）、副作用前 `batchStarted` 意图落盘、尾部损坏可验证修复、重放确定且幂等，且变异检验 11/11 全红（证据映射见 `Docs/Validation/Phase-1.1.md` 第四节与「D3 前提验证」小节）。**保留追加式事件日志，不替换存储引擎**，不需要为换存储单独开 ADR；物理掉电/`fsync` 语义不在单测可证范围，列入残余风险。阶段 2 引入外部能力调用前必须保持"事件日志是唯一真相源"。
