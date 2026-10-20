# LingXiAgent 2.0 设计与规范文档

本目录是 2.0 的**设计与验收依据**。产品目标、工作范围和完成标准以《LingXiAgent 2.0 项目书》为准（外部文档，本文档集不重复其内容，只引用其章节号）。

文档只规定**边界、契约和判定口径**，不规定具体实现写法。实现细节以代码和测试为准；与本文冲突时，先确认是代码错了还是文档过期了。

## 文档集

| 文件 | 内容 | 对应阶段 |
|---|---|---|
| `Project-Conventions.md` | 项目规范：目录与命名、依赖审批、Core 不膨胀的评审规则、提交与许可登记、安全红线 | 阶段 0 |
| `Kernel-Design.md` | 最小内核设计：职责白名单、进程形态、Run/Step 状态机、工具批次语义、执行状态与恢复、取消与超时、单上下文组装、预算与压缩、缓存度量 | 阶段 1 |
| `Plugin-System-Design.md` | 插件系统与 `.lxap`：macOS 原生 bundle 包格式与 Manifest、插件 C ABI（`LingXiPlugin_Init`）、Plugin Host 进程模型、统一握手与能力注册、生命周期与启停撤销、故障分类与隔离、Hook 与 fail-closed、权限三层区别 | 阶段 2–3 |
| `Provider-Plugin-Contract.md` | Provider 插件契约：按 wire family 划分的能力面、事件流终态契约、错误分类与重试、用量与缓存字段、验收清单 | 阶段 2 |
| `Testing-and-Acceptance.md` | 测试分层门禁与项目书第七章完成标准的逐条判定方式 | 贯穿 |
| `Regression-Cases.md` | 1.x 已验证经验与回归案例清单：带 ID 的场景 → 期望行为 → 1.x 证据 → 2.0 归属 | 阶段 0，持续引用 |
| `Validation/` | 阶段验收记录：基线/终态数字、逐 ID 证据、反例（变异）结果、CI 记录 | 各阶段 |

## 阅读顺序

要理解产品为什么这么设计：项目书 → `Kernel-Design.md` → `Plugin-System-Design.md`。
要写代码：`Project-Conventions.md` → 对应模块设计 → `Testing-and-Acceptance.md`。
要评审一个 PR：`Project-Conventions.md` 第三章（Core 不膨胀）+ `Regression-Cases.md` 相关条目。
要判断某个能力该放内核还是插件：项目书 §3.1 与 §五.3，判据在 `Project-Conventions.md` 第三章。

## 关键术语

- **Core / 内核**：不含 Provider、不含工具的可执行运行时。
- **插件**：以 `.lxap` bundle 交付、导出固定 C ABI 的动态库，被独立的 Plugin Host 进程加载，向内核注册能力。官方插件与社区插件遵循同一契约。
- **Plugin Host**：官方发布的通用可执行文件，`dlopen` 加载单个插件，并在 Core 与插件之间翻译 IPC 与 ABI 调用。插件作者不需要认识它。
- **前端**：TUI 或其他界面进程，通过前端协议连接 Core，不链接内核实现。
- **Turn / Step / Run**：一次用户提交为 Turn；Turn 内模型请求与工具执行的交替单位为 Step；一次执行实例为 Run。
- **特权通道**：只有内核标记为 `immutableInstructions` 的内容才能进入模型的指令位置；其余一律为数据。
- **因果批次**：一条 assistant 工具调用请求与其全部结果构成不可拆分的上下文单位。

## 状态

**阶段 1（含 1.1、1.2）已验收；阶段 2 最小动态插件闭环与 Phase 2.1（产品接线、安全边界、取消传播）已实现并验收（120 tests），验收记录 `Validation/Phase-2.md`、`Validation/Phase-2.1.md`。`LingXiCoreHost` 启动时恢复已启用插件并把 Hook 管线接到真实 AgentLoop；默认签名策略为 restricted。**

阶段 1 交付的是可运行事实，不是计划：

- `Sources/LingXiKernel`：Agent Loop、单上下文装配与校验、预算与水位压缩、执行状态与终态化、追加式事件日志与崩溃恢复、模型/工具端口与路由。零外部依赖，`swift build` 无告警。
- `Sources/LingXiCoreHost`：可执行宿主。无 Provider 时正常启动、报告状态并给出配置引导，但不能推理——项目书 §七第 1 条已实测。
- `Tests/LingXiKernelTests`：96 个用例（基线 30；Phase 1.1 新增 59，Phase 1.2 新增 7），覆盖 L0 结构门禁（依赖方向、许可矩阵漂移、内核内无厂商名与无 `dlopen`）与 LOOP/CTX/STORE/PROV 各组回归；Phase 1.1 新增 `RecoveryAcceptanceTests`（STORE-008/009/010、LOOP-025）与 `ConversationAcceptanceTests`（LOOP-021~024、CTX-017/018、CACHE-007、QA-013）；Phase 1.2 新增 LOOP-026（`endExecution` 四条终态路径清理）与 LOOP-027（Session 内条目 id 唯一）。`swift build --build-tests` 零告警。许可漂移门禁做过反向验证（塞入未登记 target 会变红）。
- `.github/workflows/ci.yml`：最小 macOS 26 CI：`swift build --build-tests` + `swift test`，外加一步空核启动检查（无 Provider 时只打印引导、不写事件日志，QA-013）；触发条件为 push `rewrite/2.0`、PR→`main`、`workflow_dispatch`。**首跑已 success**：run `39361419757`（`macos-26`，Swift 6.3.3 / Xcode 26.6.0，89 tests 全绿，证据见 `Validation/Phase-1.1.md` 第六节）。
- `LICENSE-MATRIX.md` 已按 2.0 实际 target 重建。

Phase 1.1 修的是内核正确性，不新增功能、不加依赖（逐条对应 `Regression-Cases.md`）：同 Session 并发 Run 准入（LOOP-021）、stop reason 终态分类（LOOP-022）、阻塞流取消/超时竞争（LOOP-023）、assistant 文本落盘（LOOP-024）、恢复不重放写操作（LOOP-025）、全量重放重建（STORE-008）、事件日志尾行修复与回滚毒化（STORE-009）、begin 事务无孤立终态（STORE-010）、历史 User 降级（CTX-017）、预算引用行（CTX-018）、跨 Step usage 汇总（CACHE-007）、无 Provider 启动零日志（QA-013）。验收记录 `Validation/Phase-1.1.md` 含 89 tests 全绿 ×5、变异反例 11/11 RED、D3 前提验证与 CI run 记录。

Phase 1.2 是进入阶段 2 前的最小收尾，只还 Phase 1.1 登记过的债（验收记录 `Validation/Phase-1.2.md`，反例 4/4 RED，CI run `39365903961` 全绿且构建零告警）：`endExecution` 已在四条终态路径接线、每 Run 释放一次（LOOP-026）；恢复入口收敛为 `KernelRecovery` 唯一（旧 `RunRegistry.recoverUnfinishedRuns` 删除）；同 Session 内条目 id 必须唯一，重复 TurnID 在任何持久化写入前被拒（LOOP-027）；测试 target 的 11 处冗余 `try` 告警清零。
阶段 2 的最小动态插件闭环已落地（验收记录 `Validation/Phase-2.md`）：固定 C ABI v1（标量状态 + 出参，`ABI-MANIFEST` 已按真机验证后冻结）、通用 Plugin Host（每插件一进程，`dlopen` + 单管双向 JSON）、Core 侧监管（独立 `plugins.json` 注册表 + 会话监管 + Hook 桥）、Swift 与 C 两个实验插件。114 tests 全绿；启用改写上下文、禁用即停止参与、卸载后路由/进程/注册表三空、插件崩溃只杀死自己的 Host。未实现且不声称：租约状态机、熔断退避、permissive/公证、security 类人工确认、插件工具能力、Swift 运行时唯一性检测。TUI 与插件市场仍未开始。已覆盖的回归条目在 `Regression-Cases.md` 里标为「已覆盖（阶段 1）」「已覆盖（阶段 1.1）」「已覆盖（阶段 1.2）」，未标的仍然是待办。

已定的基线：

- 平台与工具链：macOS 26.2+ / Apple Silicon，Swift 6.4 开发工具链，`swift-tools-version` 暂定 6.2。
- 插件运行模型：`.lxap` 为 macOS 原生 bundle；插件是导出固定 C ABI 的动态库；每插件一个独立 Plugin Host 进程；Core↔Host 走内部 IPC，**插件作者不实现 IPC**；官方与社区共用同一套能力注册契约。
- 安全边界：权限声明 / 权限强制执行 / OS 沙箱三层分开；初期只做签名校验与进程隔离，**不宣称强制沙箱**；`security` 类 Hook 故障一律 fail-closed。
- 首批真实 Provider：OpenAI、Anthropic、DeepSeek。
- TUI：暂不迁移 1.x 的 OpenTUI 动态库，渲染方案后续阶段独立验证。
- D1、D2、D4 保留；D3（事件日志而非 SQLite）**有条件成立**，以阶段 1 的可靠恢复验证为前提（Phase 1.1 已把恢复策略定为可验证口径：尾部坏行截断修复、全量重放重建、恢复不重放执行，见 `Kernel-Design.md` 第六章；证据见 `Validation/Phase-1.1.md`。**D3 前提已验证：保留追加式事件日志，不替换存储引擎**）；D-P2 从"作者契约"重定位为"Core↔Host 内部协议"。

仍需主人拍板的事项：

1. 插件 C ABI 头文件与示例工程的许可轨道（PolyForm 会劝退商业作者；MIT 需在矩阵新开一条轨道，属更改授权范围）。见 `Project-Conventions.md` 第八章。
2. `permissive` 档是否额外要求第三方插件经公证（notarization）。
3. OpenAI 一家同时覆盖 Chat 与 Responses 两条 wire 时的组织方式（Q-PR4）。
4. 新能力字段 `supportsParallelToolCalls` / `toolResultPlacement` 的缺省策略（Q-PR5，涉及"无默认值"纪律的边界）。
