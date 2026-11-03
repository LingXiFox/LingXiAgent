# Phase 0 · 2.0 复用审计

审计对象：`rewrite/2.0` 分支 HEAD `c886ba7`（LingXiAgent 2.0，Swift 6.2 / SwiftPM / macOS 26 arm64）。
审计目的：在写 3.0 第一行代码之前，判断 2.0 中哪些协议、插件接口与测试资产值得继承，哪些必须放弃。
结论先行：**没有复用任何 Swift 源码**；复用的是四份设计契约（前端协议、插件契约、内核终止语义、测试分层）和 ADR 工作方式。3.0 是重新实现，不是移植。

## 一、2.0 资产盘点

| 资产 | 规模 | 与 3.0 的关系 |
| --- | --- | --- |
| `Sources/`（Core、TUI、Provider、Plugin Host） | 40 个 Swift 文件 | 全部移除，不直接移植 |
| `ContractTests/` | 32 个测试文件 | 用例意图可作为回归清单，代码不可复用 |
| `Tests/` | 9 个测试文件 | 同上 |
| `Plugins/` | 12 个插件目录 | `.lxap` 为 macOS bundle，跨平台不可用 |
| `Docs/` | 协议、内核、插件、验收文档 + 11 份 ADR | 已整体移入 `Docs/reference/2.0/` 作为参考 |
| `Package.swift`、`.swift-version` | SwiftPM 工程 | 删除，改用 Cargo workspace |

3.0 分支上 Swift 源码与测试已删除；2.0 分支保持原样，未被改写。

## 二、逐项复用判断

### 1. 前端协议（`Docs/reference/2.0/Frontend-Protocol.md`）

2.0 的 Core ↔ TUI 协议是「带 `id` 的请求/回复 + 单向事件流」，并明确了两条所有权规则：请求由前端发起、事件由内核按序推送；终态事件只发一次。

**判断：复用协议形状，不复用传输。** 3.0 用 Tauri `invoke` 代替 stdin/stdout 帧，用 `emit` 代替事件行；命令返回值直接携带类型化结果，不再手写 `{id, ok}` 信封。终态唯一、事件带 `runId` 的顺序约定保留，见 `Docs/phase-0/03-runtime-interfaces.md`。

未继承：TUI 导航/屏幕绘制、凭据管理、settings frame。

### 2. 插件系统（`Plugin-System-Design.md`、`Provider-Plugin-Contract.md`）

2.0 的三层运行模型（Core / Host / Plugin）和固定 C ABI 解决了 macOS 上的进程隔离与崩溃隔离，但 `.lxap` 是 macOS 原生 bundle，C ABI 与 dlopen 也不是跨平台插件分发的合理起点。文档中真正跨平台的部分是：

- 能力必须**声明**，权限必须**单独强制执行**；
- 插件生命周期有显式状态，撤销（revoke）优先于清理；
- 契约测试验证行为，不验证实现。

**判断：复用能力模型与注册边界，不复用 ABI。** 3.0 用 `NodeSpec.capabilities` 声明能力，`NodeRegistry` 统一注册 spec 与 executor，`CapabilityPolicy` 在执行前逐项授权；引擎不认识任何内置节点名。动态库加载、ABI 版本协商、安装/更新流程全部推迟。

### 3. 内核终止语义（`Kernel-Design.md`）

2.0 的 Run/Step 状态机核心不变量：一次运行只有一个终态；取消是协作式的；失败节点不得产出可被下游消费的输出。

**判断：复用不变量，不复用 Agent Loop。** 3.0 明确不内置 Agent Loop（见任务约束），只保留工作流 DAG 调度；`RunStatus` 只有 `completed / failed / cancelled` 三种终态，取消通过 `RunControl` + `tokio::select!` 实现，失败节点进入 `unavailable` 集合、下游标记 skipped。

未继承：Turn/Step 模型、上下文预算、Prompt Cache 度量、崩溃恢复日志。

### 4. 测试分层（`Testing-and-Acceptance.md`）

2.0 的 L0–L4 分层、默认无网络/无凭据、故障注入优先于 happy path，是可复用的方法论。

**判断：复用分层与默认值。** Phase 0 的 21 个测试全部离线；能力拒绝、取消、交互拒绝、无效工作流都走故障路径；UI 验收单独记录（含无法自动化的部分），不把「编译通过」当验收。L4（缓存/成本）本阶段不适用。

### 5. ADR 与文档纪律

2.0 的 ADR 编号、决策与待决分离、验收证据映射被保留为写作方式；3.0 的 Phase 0 文档放在 `Docs/phase-0/`，2.0 文档只读存放在 `Docs/reference/2.0/`。

## 三、明确放弃的部分

| 放弃项 | 原因 |
| --- | --- |
| Swift / SwiftUI / TUI | 任务约束：不再开发，且无法跨平台复用 |
| SwiftPM、`.swift-version`、macOS 26 基线 | 3.0 以 Rust + Tauri 2 为基线 |
| `.lxap` bundle、固定 C ABI、dlopen | macOS 专属分发模型，跨平台插件格式未定 |
| Keychain、macOS 沙箱 | 平台专属；凭据与沙箱留给后续资源权限层 |
| stdin/stdout 帧协议 | 由 Tauri IPC 替代 |
| 内置 Agent Loop、Provider 代码 | 本阶段不做 LLM 推理，也不锁死 Agent 结构 |
| arm64-only 假设 | 目标是三平台，x86_64 与 arm64 都要能构建 |

## 四、迁移规则（对后续阶段的约束）

1. 需要 2.0 的行为时，先读 `Docs/reference/2.0/` 的契约，再在 Rust/TS 中重写；不复制 Swift 代码，不保留「兼容层」。
2. 任何从 2.0 借来的语义，必须在 3.0 文档或测试里留下可验证的落点，否则视为未继承。
3. 2.0 的已知缺口（无跨平台插件格式、无 Windows/Linux 构建、macOS 专属依赖）不得原样带进 3.0。
4. 分支边界：`rewrite/2.0` 只读；所有 3.0 改动提交在 `rewrite/3.0`。

## 五、审计结论

Phase 0 的复用是**契约级**的，不是代码级：协议形状、能力/权限分离、单一终态与协作取消、离线故障测试。这个结论也解释了为什么 3.0 的 crate 里找不到任何从 2.0 搬来的类型——它们只共享设计约束，不共享实现。
