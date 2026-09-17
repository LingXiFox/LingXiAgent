# Architecture-Baseline-2.1-Patch

> **基线状态**: 架构终审冻结 (Architecture Baseline 2.1 Frozen)  
> **修订性质**: 局部细节纠偏与关键断点收敛（Patch Revision）  
> **执行准则**: 零生产代码修改、零提前重构、零 Git Commit；本补丁完成即为最终实施基线。

---

## 1. 修改项对照表

```text
┌─────┬──────────────────────────┬────────────────────────────┬─────────────────────────────┐
│ 序号│ 修订主题                 │ 2.0 遗留设计               │ 2.1 最终决定 (Patch)        │
├─────┼──────────────────────────┼────────────────────────────┼─────────────────────────────┤
│ 1   │ Action 风险等级判定      │ ActionBatch 包含 riskCategory 由模型自填 │ 移出 ActionBatch，由独立 Evaluator 运行时裁决 │
│ 2   │ Desktop 能力时效性       │ DesktopEnvironment 仅静态快照 | 引入动态 refresh / invalidate 机制 │
│ 3   │ 交互动作类型正交性       │ 通用 Action 包含 navigate/urlMatches | 拆分 CommonPrimitive / Browser / Desktop │
│ 4   │ Session 拓扑拓扑关系     │ HostProcess 1:1 Session 混淆 | 1 Host : N Session / Context 明确分层 │
│ 5   │ Phase 0 交付深度         │ 仅定义协议与类型骨架       │ 落地 ActionBatchExecutor 骨架与 Fake 验证 │
│ 6   │ 协议枚举扩展兼容性       │ 标为“无 API 破坏”           │ 纠偏：全仓 Exhaustive Switch 存在破坏性 │
│ 7   │ 坐标变换健壮性           │ 转换失败兜底原样返回，用裸 Rect │ 转换失败必须抛错，统一 CoordinateRect │
│ 8   │ IPC 层次划分             │ Stdio 与 Framing 耦合      │ Process → Stdio → Framer → JSONRPC 四层解耦 │
└─────┴──────────────────────────┴────────────────────────────┴─────────────────────────────┘
```

---

## 2. 最终决定与架构细化

### 2.1 独立交互风险裁决器 (`InteractionRiskEvaluator`)
- **最终决定**:
  - `ActionBatch` 内部**禁止**包含由调用方赋值的 `riskCategory`，仅允许模型传递意图提示 `intentHint: String?`；
  - 风险计算完全移入 Core 内部独立的 `InteractionRiskEvaluator`：
    ```swift
    public protocol InteractionRiskEvaluating: Sendable {
        func evaluateRisk(
            actions: [InteractionAction],
            observation: Observation?,
            origin: String?,
            intentHint: String?
        ) async -> InteractionRiskCategory
    }
    ```
  - 根据目标 DOM 语义（如“支付/删除/授权”按钮文本）、URL 域信任级别、密码输入等静态规则与启发式规则在运行时强制判定，杜绝 Prompt Injection 自行绕过审批。

### 2.2 `DesktopEnvironment` 动态能力刷新与失效
- **最终决定**:
  - `DesktopEnvironment` 封装为管理动态状态的容器/Actor，废弃一次性只读快照假设；
  - 暴露 `refreshCapabilities() async -> HostCapabilitySnapshot` 与 `invalidateCapabilities()`；
  - 在执行关键交互前执行轻量 Preflight 检查，若检测到系统 TCC 权限变动、显示器拔插或 Portal 会话失效，立即刷新能力并触发对应错误分支。

### 2.3 动作分层：Common Primitive、BrowserAction 与 DesktopAction
- **最终决定**:
  - 彻底将 Web 专有行为移出通用层，建立三层干净模型：
    1. **`CommonInteractionPrimitive`**: 点击、双击、输入、修饰键、滚动、拖拽、基础等待；
    2. **`BrowserAction`**: 包装通用原语 + `navigate(url)`, `reload`, `goBack`, `waitForURL(pattern)`;
    3. **`DesktopAction`**: 包装通用原语 + `activateWindow(id)`, `moveWindow(id, bounds)`, `launchApp(identifier)`;
    4. **`InteractionAction`**: `case browser(BrowserAction)`, `case desktop(DesktopAction)`.

### 2.4 Session 多层级拓扑关系厘清
- **最终决定**:
  - **Browser 拓扑**:
    ```text
    BrowserHostProcess (单个 Node.js Sidecar 守护进程)
        └── 1:N BrowserSession (逻辑会话，绑定到 AgentSession)
            └── 1:N BrowserContext (独立 Cookie / Storage 隔离沙箱)
                └── 1:N Page / Tab (具体页面与 DOM)
    ```
    单个 Node.js Sidecar 进程可支撑多个 BrowserSession（多会话复用）；
  - **Desktop 拓扑**:
    `DesktopSession` 严格定义为 LingXiAgent 自身分配的逻辑交互资源上下文（包含一组激活的 Backend 句柄、活动 Display 指针与临时授权 Token），**绝不等同于** OS 图形登录会话（Login Session）。

### 2.5 Phase 0 落地 `ActionBatchExecutor` 核心调度骨架
- **最终决定**:
  - Phase 0 不仅定义接口，还要直接实现无 GUI 依赖的纯调度逻辑 `ActionBatchExecutor`；
  - 利用 `FakeInputBackend`、`FakeAccessibilityBackend` 建立无 GUI 单元测试套件，提前跑通：
    - 顺序执行（Sequential Pipeline）
    - 局部失败熔断（Stop-on-failure）
    - 任务取消（Task Cancellation）
    - 元素陈旧检测（Stale Ref Check）
    - 前置能力校验（Capability Preflight）
    - 输入中立化保证（Input Neutralization）

### 2.6 `SessionMessagePart` 枚举扩展的 Exhaustive Switch 影响评估
- **最终决定**:
  - 修正影响评估描述：**“二进制/JSON 数据存储向前兼容，但源码层属于破坏性变更（Breaking Change）”**；
  - Swift 的枚举模式匹配要求穷尽（Exhaustive）。在 `SessionMessagePart` 增加 `.observation(ObservationID)` 将导致全仓所有 `switch message.parts` 处（包括 `SessionRuntime`, `ContextCompactor`, `SQLitePersistenceStore`, `ApplicationStore`, `ApplicationTUI`）编译报错；
  - Phase 0 实施时必须全仓同步补充处理分支（如 ContextCompactor 针对 Observation 仅提取轻量摘要，TUI 针对 Observation 仅渲染指示器），不可遗漏。

### 2.7 坐标变换强类型抛错与 `CoordinateRect`
- **最终决定**:
  - 彻底杜绝转换失败返回原始坐标的“假装成功”隐患；
  - `CoordinateTransform.toLogicalPoint(...) throws -> LogicalPoint` 在无法解析（如缺少窗口上下文、缩放因子非法）时**强制抛出强类型错误**；
  - 废弃所有裸 `PixelRect`，统一引入包含显示器与空间的 `CoordinateRect`。

### 2.8 IPC 严格解耦：四层正交流水线
- **最终决定**:
  - 明确分离“字节流读写”与“协议分包（Framing）”：
    ```text
    ManagedProcess (跨平台进程树生命周期与信号)
        │
        ▼ (Raw Byte Streams)
    StdioTransport (双向 Pipe、线程安全读写锁)
        │
        ▼ (Byte Buffers)
    MessageFramer (分包协议解析器)
        ├── LSPContentLengthFramer (解析 Content-Length 头部)
        └── LineDelimitedJSONFramer (解析以 \n 结尾的 JSON 帧)
        │
        ▼ (Complete Frame Payloads)
    JSONRPCPeer (JSON-RPC 2.0 请求/响应匹配与派发)
    ```

---

## 3. 对 Phase 0 的影响

1. **测试提前收敛**: 增设 `ActionBatchExecutor` 与 Fake Backend 使核心调度逻辑在 Phase 0 即可完成 100% 单元测试闭环，无需等到 Phase 1 接入 Node.js 才能验证。
2. **全仓编译适配**: 识别出 `SessionMessagePart` 的 Exhaustive Switch 影响后，Phase 0 工作量增加了相关消费模块的模式匹配补齐，但消除了后续被编译器阻断的意外风险。
3. **架构坚固度提升**: 引入独立的 `InteractionRiskEvaluator`、严格抛错的 `CoordinateTransform` 与解耦的 `MessageFramer`，杜绝了安全绕过与坐标漂移的隐藏缺陷。

---

## 4. 修订后的 Phase 0 TODO 清单 (Frozen Action Plan)

| 任务编号 | 任务名称 | 核心目标与交付内容 | 涉及模块 | 破坏性与兼容性 | 前置依赖 | 完成验收标准 (Definition of Done) |
|---|---|---|---|---|---|---|
| **P0-1** | **IPC 四层流水线提炼** | 将进程与通信拆分为 `ManagedProcess`、`StdioTransport`、`MessageFramer`、`JSONRPCPeer` 四层 | `LingXiPlatform/Process`, `LingXiCore/Modules/Symbol` | **向后兼容** (原有 LSPCoordinator 适配新层) | 无 | 既有多语言 LSP 单元测试 100% 通过；新增 Framer 独立分包测试通过 |
| **P0-2** | **基础交互契约模型** | 落地 `Observation`, `ElementRef`, `CommonInteractionPrimitive`, `BrowserAction`, `DesktopAction`, `WaitCondition` | `LingXiProtocol/Interaction` | **无破坏** (纯新增文件) | 无 | 类型完备，支持 `Codable` 与 `Sendable`，坐标系采用 `CoordinateRect` |
| **P0-3** | **风险裁决与错误体系** | 定义 `InteractionRiskCategory`、`InteractionRiskEvaluating` 与 `InteractionError` 体系 | `LingXiProtocol/Interaction` | **无破坏** (纯新增类型) | P0-2 | 涵盖 Capability, SystemAuth, Permission, StaleRef 等错误枚举 |
| **P0-4** | **消息枚举扩展与全仓 Switch 适配** | `SessionMessagePart` 扩展 `.observation(ObservationID)`，同步适配 Core、Application、TUI 所有 switch 分支 | `LingXiProtocol`, `LingXiCore`, `LingXiApplication`, `LingXiTUI` | **代码级 Breaking** (需全仓补充 exhaustive 分支) | P0-2 | 全仓 `swift build` 编译零错误零 Warning，会话存储与回放测试通过 |
| **P0-5** | **桌面环境组合抽象与动态探针** | 定义 6 大原子 Capability Protocol 与支持 `refreshCapabilities()` 的 `DesktopEnvironment` 容器 | `LingXiPlatform/Protocols` | **无破坏** (纯新增抽象) | P0-2, P0-3 | 协议不引用任何 OS 专有头文件，支持动态失效与刷新 |
| **P0-6** | **坐标几何变换引擎** | 实现 `CoordinateTransform`，提供从物理/归一化/窗口坐标到逻辑坐标的强校验抛错转换 | `LingXiPlatform/Common` | **无破坏** (纯新增工具) | P0-2 | 覆盖 Retina 2x、Windows 150%、多屏负坐标与转换失败抛错测试 |
| **P0-7** | **Action 批处理调度内核与 Fake 验证** | 落地 `ActionBatchExecutor` 调度骨架，使用 `FakeAccessibilityBackend` 与 `FakeInputBackend` 完成全套闭环测试 | `LingXiCore/Modules/Interaction`, `Tests/LingXiCoreTests` | **无破坏** (新增核心与测试) | P0-1 ~ P0-6 | 顺序执行、熔断、取消、Stale Ref 拦截、Preflight、中立化单测 100% 通过 |

---
*(基线修订完毕，本补丁与 Revision 报告共同构成最终冻结架构基线，后续无须再讨论架构边界，下一步直接开启 Phase 0 编码)*
