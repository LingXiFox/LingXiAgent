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

**Phase 0.1 架构修订已完成，阶段 1 最小内核已落地。**

阶段 1 交付的是可运行事实，不是计划：

- `Sources/LingXiKernel`：Agent Loop、单上下文装配与校验、预算与水位压缩、执行状态与终态化、追加式事件日志与崩溃恢复、模型/工具端口与路由。零外部依赖，`swift build` 无告警。
- `Sources/LingXiCoreHost`：可执行宿主。无 Provider 时正常启动、报告状态并给出配置引导，但不能推理——项目书 §七第 1 条已实测。
- `Tests/LingXiKernelTests`：30 个用例，0.01 秒跑完，覆盖 L0 结构门禁（依赖方向、许可矩阵漂移、内核内无厂商名与无 `dlopen`）与 LOOP/CTX/STORE/PROV 各组回归；许可漂移门禁做过反向验证（塞入未登记 target 会变红）。
- `LICENSE-MATRIX.md` 已按 2.0 实际 target 重建。

已覆盖的回归条目在 `Regression-Cases.md` 里标为「已覆盖（阶段 1）」；未标的仍然是待办。Provider 插件、Plugin Host、TUI、插件市场均未开始，符合阶段 1 范围纪律。

已定的基线：

- 平台与工具链：macOS 26.2+ / Apple Silicon，Swift 6.4 开发工具链，`swift-tools-version` 暂定 6.2。
- 插件运行模型：`.lxap` 为 macOS 原生 bundle；插件是导出固定 C ABI 的动态库；每插件一个独立 Plugin Host 进程；Core↔Host 走内部 IPC，**插件作者不实现 IPC**；官方与社区共用同一套能力注册契约。
- 安全边界：权限声明 / 权限强制执行 / OS 沙箱三层分开；初期只做签名校验与进程隔离，**不宣称强制沙箱**；`security` 类 Hook 故障一律 fail-closed。
- 首批真实 Provider：OpenAI、Anthropic、DeepSeek。
- TUI：暂不迁移 1.x 的 OpenTUI 动态库，渲染方案后续阶段独立验证。
- D1、D2、D4 保留；D3（事件日志而非 SQLite）**有条件成立**，以阶段 1 的可靠恢复验证为前提；D-P2 从"作者契约"重定位为"Core↔Host 内部协议"。

仍需主人拍板的事项：

1. 插件 C ABI 头文件与示例工程的许可轨道（PolyForm 会劝退商业作者；MIT 需在矩阵新开一条轨道，属更改授权范围）。见 `Project-Conventions.md` 第八章。
2. `permissive` 档是否额外要求第三方插件经公证（notarization）。
3. OpenAI 一家同时覆盖 Chat 与 Responses 两条 wire 时的组织方式（Q-PR4）。
4. 新能力字段 `supportsParallelToolCalls` / `toolResultPlacement` 的缺省策略（Q-PR5，涉及"无默认值"纪律的边界）。
