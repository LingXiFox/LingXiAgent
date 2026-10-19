# LingXiAgent 2.0 设计与规范文档

本目录是 2.0 的**设计与验收依据**。产品目标、工作范围和完成标准以《LingXiAgent 2.0 项目书》为准（外部文档，本文档集不重复其内容，只引用其章节号）。

文档只规定**边界、契约和判定口径**，不规定具体实现写法。实现细节以代码和测试为准；与本文冲突时，先确认是代码错了还是文档过期了。

## 文档集

| 文件 | 内容 | 对应阶段 |
|---|---|---|
| `Project-Conventions.md` | 项目规范：目录与命名、依赖审批、Core 不膨胀的评审规则、提交与许可登记、安全红线 | 阶段 0 |
| `Kernel-Design.md` | 最小内核设计：职责白名单、进程形态、Run/Step 状态机、工具批次语义、执行状态与恢复、取消与超时、单上下文组装、预算与压缩、缓存度量 | 阶段 1 |
| `Plugin-System-Design.md` | 插件系统与 `.lxap`：包格式、身份与权限声明、进程与 IPC 协议契约、生命周期与启停撤销、故障隔离与恢复、Hook 扩展点 | 阶段 2–3 |
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
- **插件**：以 `.lxap` 交付、运行于独立子进程、向内核注册能力的组件。官方插件与社区插件遵循同一契约。
- **前端**：TUI 或其他界面进程，通过前端协议连接 Core，不链接内核实现。
- **Turn / Step / Run**：一次用户提交为 Turn；Turn 内模型请求与工具执行的交替单位为 Step；一次执行实例为 Run。
- **特权通道**：只有内核标记为 `immutableInstructions` 的内容才能进入模型的指令位置；其余一律为数据。
- **因果批次**：一条 assistant 工具调用请求与其全部结果构成不可拆分的上下文单位。

## 状态

阶段 0 收口中。以下事项仍未定，需主人拍板后写入 `Kernel-Design.md` 的待决清单：

1. 最低发布 macOS 版本与 `swift-tools-version` 的固定值（本机工具链 6.4，`.swift-version` 记 6.0.3，两者不一致）。
2. TUI 渲染载体：是否继续使用 1.x vendored 的 OpenTUI 动态库（外部依赖，需单独审批），还是自建终端渲染层。
3. `Docs/` 三份 LICENSE 与 `LICENSE-MATRIX.md` 仍是 1.x 的 target 清单，2.0 首个 target 建立时必须同步重写，否则许可漂移门禁形同虚设。
