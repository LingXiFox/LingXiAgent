# LingXiAgent V1.1 → V2.0.0 开发路线图（抽象版）

> 版本定位：V1.0.0 解决了“Agent 能稳定运行”。V1.1 至 V1.3 分三步把 LingXiAgent 建成跨平台、多前端、目标驱动的 Agent Runtime，V2.0.0 把这些成果冻结、稳定化，形成第一个长期承诺的正式大版本。
> 本文只定义 **每个版本要完成什么、怎样算完成**，不规定具体实现方案、框架细节或代码结构。

---

## 0. 版本总览

| 版本 | 定位 | 核心内容 |
|---|---|---|
| V1.0.0 | 稳定运行（已完成） | P/E-Core、工具调用、Computer Use、Branch Prediction、三平台 TUI |
| **V1.1.0** | 地基版 | 单主干模块化 Core、平台契约、TaskCapsule 模型、IPC/Frontend Contract、Capability Gateway 基础、SwiftUI 前端、Windows 行为对齐、评测与 Trace 基础 |
| **V1.2.0** | 目标与验证版 | Goal 模式、Producer–Verifier、E-Core Knowledge Cards、Capability Gateway 完善、WinUI 前端 |
| **V1.3.0** | 执行效率版 | ToolPlan、完整 Worktree 并行、Smart Model / Harness Router、Computer Use Record & Replay |
| **V2.0.0** | 正式版 | 协议与数据冻结、三平台前端对等、稳定化、实验线去留决策 |
| 实验线 | 与主线并行，默认关闭 | Dream、Workflow Distillation、自动 Skill 候选、Harness 自优化 |

```text
V1.0.0 ──► V1.1 地基 ──► V1.2 目标与验证 ──► V1.3 执行效率 ──► 稳定化周期 ──► V2.0.0
                                                                ▲
实验线（Dream / Distillation / 自优化）──── 评测达标才可晋升 ────┘
```

---

## 1. 贯穿全程的原则

1. **单主干。** 所有平台、所有前端都在 `main` 上开发，用模块边界隔离差异，不用长期分支隔离差异。
2. **契约先行。** 先定数据模型和状态机，再定协议，再做 UI。UI 是契约的消费者，不是契约的来源。
3. **模型先于界面。** GUI 展示的主要对象是 Task，所以 Task 模型必须早于 GUI 定型。
4. **地基先于组合。** Goal 由 Task 组成，Task 必须先存在；Fork 依赖 Workspace，Workspace 抽象必须随 Task 一起出现。
5. **测量先于优化。** 任何声称“降低成本、提升稳定性”的能力，必须能在评测集上与基线对比。评测基础设施属于 V1.1。
6. **安全先于扩展。** 能力授权与凭据隔离必须早于 Skill、Extension、Replay 等扩展能力。
7. **用户显式意图优先。** 自动路由、自动沉淀只提供默认值和候选，用户的显式配置始终优先。

---

## 2. 仓库与平台结构

### 2.1 仓库组织

所有代码位于同一主干，按职责分目录/Target（名称仅示意）：

| 区域 | 职责 | 依赖约束 |
|---|---|---|
| `Core/` | Agent Runtime、任务模型、Goal、P/E-Core、工具契约、协议、持久化 | 不得依赖任何平台 UI 框架或平台桌面 API |
| `Platform/Darwin`、`Platform/Linux`、`Platform/Windows` | 进程、文件、终端、IPC、异步 IO、桌面能力的平台实现 | 只实现 Platform Contract，不承载业务逻辑 |
| `Frontends/TUI` | 终端前端（三平台） | 只经 CoreHost / IPC 访问 Runtime |
| `Frontends/SwiftUI` | macOS 原生前端 | 同上 |
| `Frontends/WinUI` | Windows 原生前端（V1.2 起） | 同上 |
| `ContractTests/` | 平台无关契约测试 | 三平台必须运行同一套 |
| `Evals/` | 评测任务集、基线数据、Trace 工具 | 所有优化类功能共用 |

### 2.2 分支策略

| 分支 | 用途 |
|---|---|
| `main` | 唯一开发主干，始终可构建、三平台 CI 通过 |
| `feature/*` | 短期功能分支，完成即合并 |
| `release/*` | 发版稳定化，只接受修复 |

不再设立长期平台分支。平台差异由目录边界与条件编译处理，由 CI 强制约束。

### 2.3 CI 约束

- macOS / Linux / Windows 三平台矩阵构建。
- 三平台运行同一套 Contract Test，Core 测试不允许按平台跳过；确需跳过的必须登记为平台债务。
- 自动检查 Core 的依赖图，禁止引入平台 UI 框架。

### 2.4 平台与前端支持范围

| 平台 | 正式前端 | 备注 |
|---|---|---|
| macOS | TUI + SwiftUI | |
| Linux | TUI | V2.0.0 不承诺 Linux GUI |
| Windows | TUI（V1.1）+ WinUI（V1.2 起） | Windows 始终为正式支持平台，不降级 |

---

## 3. V1.1.0 — 地基版

### 目标

建立真正的平台无关 Core 和稳定的前端契约，使三平台成为同一 Core 的宿主；用 TUI 和 SwiftUI 两个前端验证契约；为后续所有能力准备好 Task、能力授权、评测和数据迁移的地基。

### 内容

| 领域 | 要完成什么 |
|---|---|
| Core 边界 | 明确哪些模块属于平台无关 Core，哪些属于平台层；按 §2.1 重组仓库 |
| Platform Contract | 统一进程、文件、终端、桌面能力、网络、IPC、异步 IO 的语义边界 |
| TaskCapsule 模型 | 定义 Task 身份、Objective、Success Criteria、状态机、Workspace、上下文、Tool 状态、Artifacts、Validation Evidence、Risk State、Waiting Reason、Resume Point |
| Task 生命周期 | 统一 running / waiting / paused / completed / failed / cancelled；支持 Pause / Resume / Cancel / Fork |
| Workspace 抽象 | 每个 Task 绑定一个 Workspace；Fork 产生独立 Workspace（本版允许简单实现） |
| IPC / Frontend Contract v1 | 所有正式前端通过统一 CoreHost 协议访问 Runtime；协议携带版本号 |
| Capability Gateway 基础 | 子进程与 SubAgent 不直接持有 Provider Credential；能力按 Session / Task 授权 |
| 评测基础 | 建立固定评测任务集，在 V1.0.0 上测出成功率、Token、耗时、工具调用次数基线 |
| Trace 格式 | 定义统一运行轨迹格式，供 Runtime Inspector、Verifier、Router、评测共用 |
| 持久化迁移 | 新数据结构带 schema 版本；V1.0 的 Session 数据可迁移 |
| SwiftUI 前端 | 会话、Task、Agent 执行过程、Tool 调用、审批、Runtime Inspector、Artifacts |
| Windows 对齐 | Windows 上 Core 与 TUI 行为与 macOS 一致；V1.0 暴露的平台差异整理为正式平台债务 |

### 退出条件

- [ ] Core 的依赖图中不含 SwiftUI / AppKit / WinAppSDK 等平台 UI 框架，由 CI 自动检查。
- [ ] 三平台 CI 运行同一套 Contract Test 并全部通过，无未登记的平台跳过项。
- [ ] TUI 与 SwiftUI 只经 CoreHost / IPC 访问 Runtime，没有直接调用 Core 内部实现。
- [ ] Task 可 Pause / Resume / Cancel；进程重启后可从 Resume Point 恢复。
- [ ] Fork 出的 Task 拥有独立 Workspace，修改互不影响。
- [ ] 任何子进程、SubAgent 都不持有 Provider Credential。
- [ ] IPC 版本不匹配时，前端得到明确错误，而不是静默失败。
- [ ] V1.0.0 的持久化数据可迁移到 V1.1，迁移有回归测试。
- [ ] 评测集在 V1.0.0 与 V1.1.0 上均有完整基线数据，V1.1.0 各项指标不劣于 V1.0.0。
- [ ] Runtime Inspector 能读取并展示 Trace。
- [ ] 许可证矩阵 LICENSE-MATRIX.md 与 LCSAL-1.1 / PolyForm 附加条款定稿并 CI 守护。

---

## 4. V1.2.0 — 目标与验证版

### 目标

在 Task Runtime 之上建立长期目标层和独立验证层，让 Agent 能围绕目标持续工作，并对结果负责；同时补齐 Windows 原生前端。

### 内容

| 领域 | 要完成什么 |
|---|---|
| Goal 模式 | Goal Definition、Goal State、Task Decomposition、Evidence、Dependencies、Checkpoints、Resume、Replan、Completion |
| Producer–Verifier | 关键结果进入 Verifier；高风险动作自动提高验证等级；低置信度结果二次验证；失败或矛盾触发 Repair / Replan |
| E-Core Knowledge Cards | Architecture、Invariant、Interface、Convention、Dependency、Workflow、Failure Pattern、Historical Decision、Project Constraint；与来源建立关联，支持过期检测 |
| Capability Gateway 完善 | Tool / MCP / Vision / Context Recall 统一经网关暴露；能力可限制、撤销、审计 |
| WinUI 前端 | 通过同一 IPC 协议接入，覆盖 SwiftUI 的核心视图 |
| 前端扩展 | SwiftUI 与 WinUI 增加 Goal、Validation Evidence、Knowledge Cards 视图 |

### 退出条件

- [ ] Goal 可跨会话恢复；Goal 只能由 Success Criteria 判定完成，模型无法自行宣布完成。
- [ ] Replan 保留原计划与变更原因，可在 Trace 中追溯。
- [ ] Verifier 按风险策略触发：低风险任务默认不触发，高风险动作一定触发。
- [ ] 在注入缺陷的评测子集上，Verifier 检出率可测量且优于无 Verifier 基线；总成本增幅有记录。
- [ ] 代码变化后只有受影响的 Knowledge Cards 失效，有自动化测试覆盖。
- [ ] 能力授予、使用、撤销全部写入审计记录。
- [ ] WinUI 与 SwiftUI 在会话、Task、Goal、Tool 调用、审批上功能对等，且不需要改动 Core。
- [ ] 评测集上各项指标不劣于 V1.1.0。

---

## 5. V1.3.0 — 执行效率版

### 目标

在已有的 Task、Goal、Verifier、Trace、评测基础上，降低无效往返、支持真正的并行 Coding，并让执行策略可以自动选择。

### 内容

| 领域 | 要完成什么 |
|---|---|
| ToolPlan | 顺序、并行、条件、批量读取与搜索、结果聚合、简单循环、局部失败处理；与 Branch Prediction 配合 |
| Worktree Task Isolation | 多个 Coding Task 并行，各自独立工作空间；完成后进入 Review / Merge |
| Smart Model / Harness Router | 按任务类型、复杂度、风险、上下文规模、视觉/Computer Use/Coding/Tool 需求、延迟与成本目标，选择 Model、Harness、Tool Set、Agent Strategy、Verification Level、Context Strategy |
| Computer Use Record & Replay | 记录成功轨迹，沉淀为 Action Flow；每步有前置与完成条件；环境不符时退出 Replay 交还 Agent；Replay 与推理可混合执行 |

### 退出条件

- [ ] ToolPlan 失败时可回退到逐步 Agent Loop，不影响任务正确性。
- [ ] 在评测集上，启用 ToolPlan 后 LLM 往返次数与耗时相对 V1.2.0 基线下降（具体目标值由基线确定后写入）。
- [ ] N 个 Coding Task 并行执行无互相污染；合并冲突进入 Review 而不是被静默覆盖。
- [ ] 用户对 AgentRun 的显式模型配置始终优先于 Router；Router 的每次决策写入 Trace 并可解释。
- [ ] Replay 在前置条件不满足时必然退出，不会在错误界面上继续执行。
- [ ] Action Flow 的上层契约三平台统一；各平台的具体轨迹格式可以不同（macOS AX / Windows UIA / Linux AT-SPI），各平台的支持程度在本版写明。
- [ ] 在重复型 Computer Use 评测任务上，视觉模型调用次数相对纯推理模式下降。
- [ ] 评测集上成功率不劣于 V1.2.0。

---

## 6. V2.0.0 — 正式版

### 定位

V2.0.0 不是新功能版本，而是把 V1.1 至 V1.3 的成果 **冻结、打磨、承诺** 的版本。V1.3.0 发布后进入稳定化周期，此期间只修复缺陷、补文档、补测试，不接受新功能。

V2.0.0 的主版本号意味着一项长期承诺：之后的 2.x 版本在协议和数据上保持向后兼容。

### 内容

| 领域 | 要完成什么 |
|---|---|
| 协议冻结 | IPC / Frontend Contract 定为 2.0；之后 2.x 只做向后兼容的扩展 |
| 数据冻结 | 持久化 schema 定为 2.0；支持从任意 1.x 版本迁移 |
| 能力契约冻结 | Tool 契约、Capability Gateway 授权模型、Action Flow 上层契约定型 |
| 前端对等 | 按 §2.4 的支持范围，三平台前端核心功能对等 |
| 平台债务清算 | V1.x 期间登记的平台债务全部清零，或逐项明确推迟到 2.x 并说明原因 |
| 实验线决策 | 对实验线每一项做出“晋升 / 继续实验 / 放弃”的决定 |
| 发布资料 | 用户文档、迁移指南、协议文档、许可证边界说明 |

### 退出条件

- [ ] IPC 协议、持久化 schema、能力契约的 2.0 版本文档发布，并有兼容性测试守护。
- [ ] 从 V1.0.0、V1.1.0、V1.2.0、V1.3.0 的数据均可迁移到 V2.0.0，全部有回归测试。
- [ ] 三平台 × 对应前端的核心功能对等矩阵全部通过。
- [ ] 无已知 P0 / P1 缺陷。
- [ ] 平台债务清单中没有未处理且未说明的条目。
- [ ] 实验线每一项都有明确决定；晋升的项目通过了评测门槛。
- [ ] 评测集上各项指标不劣于 V1.3.0。
- [ ] 许可证边界明确：Core 为 LCSAL-1.1，TUI/SwiftUI/WinUI 统一为 PolyForm Noncommercial 1.0.0 + 第三方改版仅限源码分发。

---

## 7. 实验线

### 内容

| 项目 | 定位 |
|---|---|
| Dream | 长期上下文维护：合并、去重、压缩、失效检测、低价值衰减、高价值提升 |
| Workflow Distillation | 从成功轨迹中发现重复工具模式、常见修复流程、项目级工作流、可复用操作序列 |
| 自动 Skill 候选生成 | 由 Distillation 产出候选 Skill |
| Harness 自优化实验 | 在评测约束下尝试调整 Harness |

### 规则

- 实验线功能默认关闭，不影响主线发版节奏。
- 自动产出的 Skill / Workflow 只能是候选，必须经过验证、回归和评测才能晋升为正式能力（Eval-Gated Promotion）。
- Agent 不得在无验证的情况下修改自身 Harness。
- V2.0.0 不等待实验线；实验线项目可以在 2.x 中晋升。

---

## 8. 核心概念模型

```text
Goal（长期目标）
 ├─ Task（可执行工作单元，TaskCapsule）
 │   ├─ Workspace
 │   ├─ Agent Loop
 │   │   ├─ ToolPlan
 │   │   └─ Branch Prediction
 │   ├─ Tool Execution（经 Capability Gateway）
 │   ├─ Verification（Producer–Verifier）
 │   └─ Trace
 ├─ Task
 └─ Task

Session = 用户交互视图
Goal    = 长期要达成什么
Task    = 当前正在执行什么
```

P-Core 负责当前完整上下文，E-Core 负责长期结构化认知（Knowledge Cards）。

---

## 9. 能力定义参考

以下为各能力的抽象定义，版本归属见 §3–§7。

### 9.1 Task Runtime / TaskCapsule（V1.1）

把 Agent 的核心运行单位从“聊天消息流”提升为可管理、可恢复、可分叉的任务对象。它是 GUI 的主要展示对象、Interactive Interruption 的运行基础、多任务并发的统一抽象、Goal 的执行载体、Verifier 的工作边界、Worktree 的绑定对象。

### 9.2 Session Capability Gateway（V1.1 基础 / V1.2 完善）

Agent 子进程、Skill、Extension、SubAgent 访问 Core 能力的唯一受控入口。子组件不持有凭据；能力按 Session / Task 授权，可限制、撤销、审计；Agent Runtime 是能力的唯一可信来源。

### 9.3 Goal 模式（V1.2）

高于 Session 与 Task 的长期工作对象，覆盖目标定义、状态、任务分解、证据、依赖、检查点、恢复、重新规划与完成判定。

### 9.4 Producer–Verifier Fabric（V1.2）

独立于执行 Agent 的验证层，使用 Success Criteria、Tool Evidence、Test Result、Branch Prediction Confidence、Trace、Artifact Diff、Goal Progress，形成“执行—验证—修正”闭环。普通低风险任务不强制启用。

### 9.5 E-Core Knowledge Cards（V1.2）

让 E-Core 从上下文索引发展为长期知识层。知识与代码、文件、提交、任务建立来源关系，代码变化只失效受影响的知识，Agent 优先读取高密度知识而非反复扫描仓库。

### 9.6 ToolPlan（V1.3）

Agent Loop 的执行加速层，不替代 Agent Loop。目标是从预测“下一步动作”发展到预测“下一段工具执行图”。

### 9.7 Worktree Task Isolation（V1.1 抽象 / V1.3 完整）

长期 Coding Task 不共享同一个正在变化的工作区。Workspace 状态是 TaskCapsule 的一部分，支持并行、暂停、恢复、Fork 与回滚。

### 9.8 Smart Model / Harness Router（V1.3）

根据任务特征选择执行策略。路由对象包括 Model、Harness、Tool Set、Agent Strategy、Verification Level、Context Strategy。Router 只提供默认值，用户显式配置始终优先。

### 9.9 Computer Use Record & Replay（V1.3）

让 Computer Use 从每步重新观察推理，升级为可学习、可复用的交互流程，提升稳定性，降低视觉调用、Token 与时间成本，避免纯坐标点击的脆弱性。轨迹天然与平台相关，上层契约统一、底层格式按平台实现。

---

## 10. 不应成为的东西

整个 V1.1 → V2.0.0 周期内，LingXiAgent 不追求：

- 无限增加 Agent 数量，或为“多 Agent”而多 Agent。
- 所有任务默认启用 Verifier。
- 依赖超长 Context 代替长期记忆。
- Agent 无验证地修改自身 Harness。
- GUI 与 Core 强耦合，或任何前端绕过 CoreHost 协议。
- 为不同平台维护多套业务逻辑，或用长期分支隔离平台。
- 未经评测就宣称某项优化有效。
- 自动路由覆盖用户的显式配置。
- 为追求功能数量牺牲 V1.0.0 已经建立的 Runtime 稳定性。

---

## 11. 最终形态

V2.0.0 完成后，LingXiAgent 应从：

> 一个具备 P/E-Core、工具调用、Computer Use 与 Branch Prediction 的 TUI Agent

演进为：

> 一个以单主干跨平台 Core 为基础，由 TUI、macOS SwiftUI 和 Windows WinUI 提供一致体验，以 Goal 和 Task Runtime 组织长期工作，具备受控能力网关、知识层、验证闭环、工具编排、Computer Use Replay 和智能执行路由，并在协议与数据上做出长期兼容承诺的多前端 Agent Runtime。

---

## 12. 一句话路线

**V1.0.0 让 Agent 稳定运行。**
**V1.1 打地基，V1.2 让 Agent 围绕目标工作并对结果负责，V1.3 让它更快更省。**
**V2.0.0 把这一切冻结成可以长期依赖的正式版本。**
