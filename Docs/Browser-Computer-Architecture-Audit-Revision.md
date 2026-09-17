# LingXiAgent Browser / Computer Use 架构复核与纠偏报告 (Revision)

> **文档状态**: 终审定稿 (Architecture Baseline Ready)  
> **审计版本**: 2.0.0-REVISED  
> **执行角色**: 本狐（Antigravity 架构助理）  
> **产出目标**: 收敛所有架构分歧与自相矛盾，确立稳定契约，为 Phase 0 实施提供直接代码指导。

---

## 1. Previous Audit Findings Kept

在第一轮架构审计中确立的以下核心仓库现状与工程事实，经复核完全准确，继续作为本轮设计的坚实地基：

1. **分层清晰的单体仓库架构**:
   - `LingXiProtocol`（纯契约）、`LingXiPlatform`（系统抽象）、`LingXiCore`（核心引擎）、`LingXiApplication`（协调状态）、`LingXiTUI`（终端展示）的分层清晰且前后端解耦良好。
2. **核心层零 macOS GUI 污染**:
   - `LingXiCore` 与 `LingXiProtocol` 中没有任何 `AppKit`、`ScreenCaptureKit`、`AXUIElement` 或 `CGEvent` 等平台特有符号泄露。
3. **现有 Tool 系统的无状态特征**:
   - `ToolExecutor` 纯单次函数调用，不持有长生命周期资源；`ToolRuntime` 具有严格的单次调用审批机制。
4. **成熟的后台外部进程管理机制**:
   - `BackgroundCommandManager` 具备进程托管、状态机轮询、异步 Task 挂起恢复以及通过系统通知唤醒模型的完备范式。
5. **IPC 通信的黄金基础设施**:
   - `GenericProcessLSPTransport`（在 `LSPCoordinator.swift` 中）完整实现了基于 Stdio 的双向 Pipe、标准 JSON-RPC 2.0 序列化/分包、`NSLock` 线程安全以及级联进程树清理（`terminateProcessTree`）。
6. **内容寻址（CAS）的大对象存储**:
   - `FileBlobStore` 基于 SHA256 哈希实现，具备天然的数据去重与落盘能力，天然适配截图、DOM 快照与无障碍树的存储。
7. **审批与挂起核心机制**:
   - `PermissionEngine` 的 `withCheckedContinuation` 挂起与 Task cancellation 处理机制健壮可靠。
8. **Browser Use 独立性原则**:
   - Browser Use 优先走 DOM / CDP / Playwright 的原生结构化协议，绝不以 Computer Use 截屏模拟作为底层依赖。

---

## 2. Findings Revised (审计纠偏与设计修正)

本轮复核针对上一版审计报告中存在自相矛盾、粒度过粗、存在隐式假设或容易引发后期返工的 12 项设计进行了彻底纠偏：

```text
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                     主要纠偏对照表                                          │
├─────┬──────────────────────┬────────────────────────────┬─────────────────────────────┬─────┤
│ 序号│ 维度                 │ 第一版设计 (Old)           │ 纠偏后设计 (New)            │级别 │
├─────┼──────────────────────┼────────────────────────────┼─────────────────────────────┼─────┤
│ 1   │ Desktop Backend 抽象 │ PlatformDesktopBackend 大口 │ 组合式 DesktopEnvironment   │严重 │
│ 2   │ Linux 抽象维度       │ 假定 LinuxDesktopBackend   │ 动态装配器 + CapabilityProbe│严重 │
│ 3   │ Capability 模型      │ 简单 Bool (有/无)          │ CapabilityAvailability 枚举 │中等 │
│ 4   │ 权限与授权边界       │ Capability vs Permission   │ 细化三层：能力/系统授权/灵犀│严重 │
│ 5   │ Tool 扩展方式        │ 引入 StatefulToolExecutor  │ 废弃！Tool 仍无状态，挂 Manager│重要 │
│ 6   │ Observation 时间戳   │ ContinuousClock.Instant    │ Date(落盘) + 单调序号 + 瞬时│重要 │
│ 7   │ 信任模型 (Trust)     │ local = trusted            │ 废弃！Local 不等于 Trusted  │严重 │
│ 8   │ ElementRef 标识      │ 简单版本号                 │ 绑定 Session/Version/Identity│重要 │
│ 9   │ Action 批处理        │ 放至 Phase 5 高级阶段      │ 前移至 Phase 0/1 基础契约   │严重 │
│ 10  │ 等待机制 (Settle)    │ 依赖隐式等待或 sleep       │ 一等公民 WaitCondition      │重要 │
│ 11  │ 输入取消保证         │ 顺带清理                   │ 核心契约 InputNeutralization│重要 │
│ 12  │ 跨平台落地顺序       │ macOS -> Linux -> Windows  │ macOS -> Windows -> Linux   │策略 │
└─────┴──────────────────────┴────────────────────────────┴─────────────────────────────┴─────┘
```

### 详细纠偏分析：

#### 2.1 废弃单一大 Backend，改用组合式 `DesktopEnvironment`
- **旧结论**: 定义 `PlatformDesktopBackendProtocol`，由 `DarwinDesktopBackend`、`WindowsDesktopBackend`、`LinuxDesktopBackend` 分别实现全部方法。
- **为什么有问题**: 违背接口隔离原则（ISP）。Linux Wayland 下截屏与无障碍可用，但全局输入注入和窗口枚举可能完全不支持。若采用大接口，平台层只能抛出伪实现或大量运行时错误，严重破坏多态契约。
- **新结论**: 废弃 `PlatformDesktopBackendProtocol`！采用组合模型：定义 6 大可选能力协议与 1 个能力探针。由 `DesktopEnvironment` 聚合它们（`accessibility: AccessibilityBackend?`, `capture: CaptureBackend?`, `input: InputBackend?` 等）。运行时缺少某能力则属性为 `nil`。
- **影响范围**: `LingXiPlatform` 接口定义与 `LingXiCore` 的桌面交互编排器。

#### 2.2 Linux 彻底去除“桌面环境级大黑盒”，转为能力装配
- **旧结论**: 计划构建统一的 `LinuxDesktopBackend`，并粗暴区分 X11 与 Wayland。
- **为什么有问题**: 现实中的 Linux 极其碎片化，甚至存在 XWayland 混合环境（如 Wayland 下截屏走 Portal，而输入走 XTest 兼容旧应用）。按 GNOME / KDE / Sway 写死分支会导致代码迅速腐化。
- **新结论**: Linux 下不设黑盒 Backend，仅设 `LinuxDesktopEnvironmentAssembler`。由 `LinuxCapabilityProbe` 在启动时动态探测 D-Bus、Portal、PipeWire、EIS、XTest 状态，按需拼装成最终的 `DesktopEnvironment`。各桌面环境专有协议（如 Sway IPC）仅作为特定 Capability 的内部 Provider 插件。
- **影响范围**: `Sources/LingXiPlatform/Linux/` 内部实现。

#### 2.3 Capability 状态由 Bool 升级为结构化状态枚举
- **旧结论**: 使用 `var screenCapture: Bool`。
- **为什么有问题**: 无法表达“系统支持但需要用户在系统弹窗中点击允许”、“仅支持全屏不支持窗口级捕获”等中间状态。
- **新结论**: 引入 `CapabilityAvailability` 枚举：`.available`, `.requiresAuthorization`, `.partial(details)`, `.temporarilyUnavailable(reason)`, `.unsupported(reason)`。
- **影响范围**: `LingXiProtocol` 中的能力描述符。

#### 2.4 严格确立“三层防御模型”：Capability vs System Authorization vs LingXi Permission
- **旧结论**: 仅区分 Capability（能不能）与 Permission（允不允）。
- **为什么有问题**: 忽视了操作系统的系统级授权（如 macOS TCC 弹窗、Linux Portal 授权对话框、Windows UAC / Integrity Level）。系统功能完备且灵犀策略已放行，但用户在 OS 对话框点了“拒绝”，此时如果报 Permission Denied，模型会误以为是灵犀策略问题。
- **新结论**: 明确划分三层错误：
  1. `CapabilityUnavailable`（系统缺模块）；
  2. `SystemAuthorizationDenied`（OS 权限未授）；
  3. `InteractionPermissionDenied`（灵犀应用安全策略拦截）。
- **影响范围**: 错误处理流水线与模型重试决策。

#### 2.5 废弃 `StatefulToolExecutor`，保持 Tool 系统无状态纯洁性
- **旧结论**: 提议在 `ToolRuntime` 中引入 `StatefulToolExecutor` 协议。
- **为什么有问题**: 侵入了经过充分测试的核心 `ToolRuntime`。工具本身不需要变成有状态的对象，它本质上只是用户意图到后端服务的“RPC 门面”。
- **新结论**: **严禁引入 `StatefulToolExecutor`**！`browser_navigate`、`browser_act`、`computer_act` 等工具依然遵循普通的 `ToolExecutor`。真正的长生命周期状态（Chromium PID、CDP 连接、桌面流）由挂在 `AgentRuntime` 下的 `BrowserSessionManager` 与 `DesktopSessionManager` 独立 Actor 维护。工具执行时仅从 Context 获取 SessionID 并向对应 Manager 发送调用。
- **影响范围**: `ToolRuntime` 零侵入，维持现有调度逻辑。

#### 2.6 Observation 时间模型解耦：区分落盘时间、单调序号与内存瞬时
- **旧结论**: `Observation` 中直接使用 `ContinuousClock.Instant`。
- **为什么有问题**: `ContinuousClock.Instant` 无法序列化（不支持 `Codable`），无法存入 SQLite 也无法写入 JSONL Trace，且系统休眠后行为不适合作为绝对审计时间。
- **新结论**: 区分三个时间维度：
  - `observedAt: Date`：标准 UTC 挂钟时间，支持 `Codable`，用于持久化、审计和 Trace；
  - `version: Int64`：从 1 开始单调递增的序号，用于 Stale Element Reference 碰撞检测；
  - `monotonicNanoseconds: UInt64`（仅运行时内存私有）：用于精细计算帧延迟与超时控制。
- **影响范围**: `Observation` 结构体定义。

#### 2.7 颠覆信任模型：彻底废弃“Local = Trusted”的危险假设
- **旧结论**: 将观察结果标记为 `trustedLocal` 与 `untrustedExternal`。
- **为什么有问题**: **极具破坏性的安全漏洞！** 在 Computer Use 中，用户屏幕上正在显示的网页、PDF、邮件、VS Code README 甚至是终端 `cat` 出来的日志，全部都属于“外部不可信内容”。如果因为它们呈现在本地桌面就赋予其信任级别，攻击者通过在网页或文档中注入一条指令，就能直接“催眠”Computer Use 执行删除或转账！
- **新结论**: **屏幕与页面上的所有文本内容，默认一律为不可信数据（Untrusted Data）！** 引入 `Provenance`（来源追溯）与 `Authority`（指令级别）二维模型。任何来自屏幕观察的文本绝不能作为指令直接调用高危权限动作。
- **影响范围**: 上下文注入策略与安全防御。

#### 2.8 ElementRef 必须包含完整三元组作用域
- **旧结论**: 简单定义 `ref_12`，按全局版本号判定。
- **为什么有问题**: 用户在 Browser 中打开了多个 Tab，或者在桌面切换了活动窗口；如果 Ref 仅绑定一个版本号，Tab A 的 `ref_1` 很容易被误作用到 Tab B 的当前页面上。
- **新结论**: `ElementRef` 必须在逻辑上绑定三元组：`[EnvironmentSessionID / ScopeID (如 TabID)] + [ObservationVersion] + [ElementIdentity]`。不匹配立即抛出强类型的 `StaleElementReferenceError`。
- **影响范围**: DOM 提取器与动作执行器。

#### 2.9 ActionBatch 从高级特性前移至基础核心契约
- **旧结论**: 计划在 Phase 5 才引入 `ActionBatch`。
- **为什么有问题**: 若 Browser MVP 采用单步 Action，填一个登录表单（点输入框、打字、点密码框、打字、点登录）需要往返 LLM 5 次，端到端耗时突破 10~15 秒，不仅体验崩溃且容易被验证码超时打断。更关键的是，如果前期不定义 Batch，后续所有 API 和 Trace 格式全部要推倒重构。
- **新结论**: `ActionBatch` 必须作为 Phase 0 基础数据结构与 Phase 1 Browser MVP 的标配能力！定义原子化的顺序批处理流水线（Sequential Pipeline），并严格支持失败熔断（Stop-on-failure）。
- **影响范围**: `LingXiProtocol` 与交互运行时。

#### 2.10 将“等待/状态稳定（Settle）”确立为一等公民能力
- **旧结论**: 依赖步骤间粗暴的 `sleep` 或工具隐式逻辑。
- **为什么有问题**: 现代 Web（SPA）与桌面充满异步动画与网络请求，硬编码等待既浪费 Token 又极其不稳定。
- **新结论**: 引入一等公民的 `WaitCondition`（`domStable`, `networkIdle`, `elementVisible`, `screenStable` 等），在 `ActionBatch` 中作为标准原子动作执行（例如 `wait(.domStable(timeoutMs: 2000))`）。
- **影响范围**: 动作模型与后端驱动。

#### 2.11 输入中立化（Input Neutralization）作为底层安全契约
- **旧结论**: 取消任务时只做基本的进程清理。
- **为什么有问题**: 如果模型在按下鼠标左键或按下 `Shift` 键的瞬间，用户点击了 Stop 或任务发生异常，物理系统将处于“鼠标一直被按住”或“Shift 键卡死”状态，导致用户本机无法正常打字，产生严重的系统级破坏感。
- **新结论**: `InputBackend` 必须将 `neutralize()` 提升为核心生命周期契约。任何 Task 取消、中途异常退出、或者 Action 批处理失败时，必须在 `defer` 中无条件向 OS 注入鼠标释放（MouseUp）与修饰键释放（KeyUp Shift/Ctrl/Alt/Cmd）。
- **影响范围**: `InputBackend` 协议契约。

#### 2.12 跨平台推进顺序策略性调整：Windows 提前，Linux 承压
- **旧结论**: macOS -> Linux -> Windows。
- **为什么有问题**: Linux 内部显示服务器（X11 vs Wayland）、桌面环境（GNOME vs KDE）、授权框架（Portal vs EIS）极度复杂。如果在 macOS 之后立即做 Linux，会导致架构设计者被 Linux 碎片化的细枝末节拖累，分不清哪些抽象是通用的、哪些是 Linux 专有的。
- **新结论**: 调整为 **macOS -> Windows -> Linux**。
  - 原因：macOS 与 Windows 的官方 API 高度稳定成熟（macOS 走 SCKit/AX/CGEvent，Windows 走 WGC/UIA/SendInput）。先完成这两个异构 OS 的落地，能够以最低的干扰验证 `DesktopEnvironment` 组合抽象的正确性；最后引入 Linux 时，这套抽象即可作为极其坚固的容器，轻松接纳 Linux 的多样化装配。
- **影响范围**: 项目交付里程碑规划。

---

## 3. Final Interaction Architecture (最终架构全景)

```text
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                 Presentation & UI Layer                                │
│                     LingXiTUI (TerminalBackend) / Web GUI Client                       │
└───────────────────────────────────────────▲────────────────────────────────────────────┘
                                            │ Readonly State Stream / Events
┌───────────────────────────────────────────┴────────────────────────────────────────────┐
│                                LingXiApplication Layer                                 │
│                   ApplicationStore (ApplicationState.activeInteraction)                │
└───────────────────────────────────────────▲────────────────────────────────────────────┘
                                            │ Orchestrates
┌───────────────────────────────────────────┴────────────────────────────────────────────┐
│                                    LingXiCore Layer                                    │
│                                                                                        │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │                    AgentRuntime / SessionRuntime (Serial Turn)                   │  │
│  └───────────────────▲──────────────────────────────────────▲───────────────────────┘  │
│                      │ Dispatches Tools                     │ Compaction & Budget      │
│  ┌───────────────────▼──────────────────┐   ┌───────────────▼───────────────────────┐  │
│  │     ToolRuntime (Stateless Facade)   │   │  ContextCompactor (Token Budget)      │  │
│  │  browser_act / computer_act Tools    │   │  Hot UI Tree / Cold Blob Trimming     │  │
│  └───────────────────┬──────────────────┘   └───────────────▲───────────────────────┘  │
│                      │ Delegates to Manager                 │ References               │
│  ┌───────────────────▼──────────────────────────────────────┴───────────────────────┐  │
│  │                   Modules/Interaction (New Interaction Runtime)                  │  │
│  │                                                                                  │  │
│  │   ┌────────────────────────────────┐    ┌───────────────────────────────────┐    │  │
│  │   │     BrowserSessionManager      │    │       DesktopSessionManager       │    │  │
│  │   │  (Host/Context/Tab Lifecycle)  │    │      (DesktopSession Lifetime)    │    │  │
│  │   └───────────────┬────────────────┘    └─────────────────┬─────────────────┘    │  │
│  │                   │ JSON-RPC (Stdio)                      │ Composite Assembly   │  │
│  │   ┌───────────────▼────────────────┐    ┌─────────────────▼─────────────────┐    │  │
│  │   │      StdioByteTransport        │    │        DesktopEnvironment         │    │  │
│  │   │  (提炼自 GenericProcessLSP)    │    │ (Optional Capability Backends)    │    │  │
│  │   └───────────────┬────────────────┘    └─────────────────┬─────────────────┘    │  │
│  │                   │ Subprocess                            │ Implements Protocols │  │
│  └───────────────────┼───────────────────────────────────────┼──────────────────────┘  │
│                      │                                       │                         │
│  ┌───────────────────┴────────────────┐    ┌─────────────────┴──────────────────────┐  │
│  │         Persistence Layer          │    │          PermissionEngine              │  │
│  │  SQLiteStore (Trace & Summary)     │    │  Three-tier Guardrails & Verification  │  │
│  │  FileBlobStore (Screenshots & DOM) │    │  Capability / SystemAuth / Permission  │  │
│  └────────────────────────────────────┘    └────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┬─────────────────────┘
                                                                   │ Native Platform Calls
┌──────────────────────────────────────────────────────────────────▼─────────────────────┐
│                                   LingXiPlatform Layer                                 │
│                                                                                        │
│     ┌──────────────────────┐   ┌──────────────────────┐   ┌──────────────────────┐     │
│     │    Darwin (macOS)    │   │   Windows (Win32)    │   │    Linux (Dynamic)   │     │
│     │  - SCKit (Capture)   │   │  - WGC (Capture)     │   │  - Probe (Detector)  │     │
│     │  - AXUI (Access)     │   │  - UIA (Access)      │   │  - AT-SPI (Access)   │     │
│     │  - CGEvent (Input)   │   │  - SendInput (Input) │   │  - Portal (PipeWire) │     │
│     │  - NSWorkspace (Win) │   │  - Win32 (Window)    │   │  - EIS / XTest (In)  │     │
│     └──────────────────────┘   └──────────────────────┘   └──────────────────────┘     │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │ Launches & Manages
┌───────────────────────────────────────────▼────────────────────────────────────────────┐
│                            External Sidecars & Host Layer                              │
│                    Node.js Browser Host (Playwright Runner Process)                    │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Final Capability Backend Model (原子能力后端模型)

彻底废弃单一大 Backend 协议，拆解为独立可选的 Capability Protocol。

### 4.1 原子协议定义草案

```swift
/// 1. 屏幕与窗口画面捕获能力
public protocol CaptureBackend: Sendable {
    func availableSources() async throws -> [CaptureSource]
    func captureFrame(source: CaptureSource, cropRect: NormalizedRect?) async throws -> CapturedFrame
}

/// 2. 无障碍语义树读取与交互能力
public protocol AccessibilityBackend: Sendable {
    func fetchTree(scope: AccessibilityScope) async throws -> AccessibilityTreeSnapshot
    func performAction(nodeID: AccessibilityNodeID, action: AccessibilityAction) async throws -> ActionResult
}

/// 3. 鼠标与键盘底层输入模拟能力
public protocol InputBackend: Sendable {
    func injectPointer(event: PointerInputEvent) async throws
    func injectKeyboard(event: KeyboardInputEvent) async throws
    /// 强制安全契约：释放所有卡住的鼠标按键与修饰键
    func neutralize() async
}

/// 4. 窗口管理与拓扑发现能力
public protocol WindowBackend: Sendable {
    func listWindows() async throws -> [WindowInfo]
    func focusWindow(id: WindowID) async throws
    func setWindowBounds(id: WindowID, bounds: PixelRect) async throws
}

/// 5. 宿主应用发现与生命周期能力
public protocol ApplicationBackend: Sendable {
    func listRunningApplications() async throws -> [ApplicationInfo]
    func launchApplication(identifier: String) async throws -> ProcessID
    func terminateApplication(identifier: String) async throws
}

/// 6. 系统剪贴板交互能力
public protocol ClipboardBackend: Sendable {
    func readText() async throws -> String?
    func writeText(_ text: String) async throws
}

/// 7. 宿主环境能力运行时探测器
public protocol CapabilityProbing: Sendable {
    func probe() async -> HostCapabilitySnapshot
}
```

### 4.2 组合载体：`DesktopEnvironment`

```swift
public struct DesktopEnvironment: Sendable {
    public let capture: (any CaptureBackend)?
    public let accessibility: (any AccessibilityBackend)?
    public let input: (any InputBackend)?
    public let windows: (any WindowBackend)?
    public let applications: (any ApplicationBackend)?
    public let clipboard: (any ClipboardBackend)?
    public let probe: any CapabilityProbing
    public let snapshot: HostCapabilitySnapshot

    public init(
        capture: (any CaptureBackend)? = nil,
        accessibility: (any AccessibilityBackend)? = nil,
        input: (any InputBackend)? = nil,
        windows: (any WindowBackend)? = nil,
        applications: (any ApplicationBackend)? = nil,
        clipboard: (any ClipboardBackend)? = nil,
        probe: any CapabilityProbing,
        snapshot: HostCapabilitySnapshot
    ) {
        self.capture = capture
        self.accessibility = accessibility
        self.input = input
        self.windows = windows
        self.applications = applications
        self.clipboard = clipboard
        self.probe = probe
        self.snapshot = snapshot
    }
}
```

---

## 5. Platform Assembly (多平台装配矩阵)

各平台装配器（`Assembler`）在检测到底层运行时支持后，按需初始化对应能力的适配器并注入 `DesktopEnvironment`：

```text
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                   平台装配流 (Assembly)                                │
├─────────────────────────┬──────────────────────────────────────────────────────────────┤
│ 平台目标                │ 实际组装的原子 Backend                                       │
├─────────────────────────┼──────────────────────────────────────────────────────────────┤
│ macOS (Darwin)          │ • capture: ScreenCaptureKitBackend                           │
│                         │ • accessibility: AXAccessibilityBackend                      │
│                         │ • input: CGEventInputBackend                                 │
│                         │ • windows: DarwinWindowBackend                               │
│                         │ • applications: NSWorkspaceBackend                           │
│                         │ • clipboard: NSPasteboardBackend                             │
├─────────────────────────┼──────────────────────────────────────────────────────────────┤
│ Windows (Win32 / WinRT) │ • capture: WindowsGraphicsCaptureBackend                     │
│                         │ • accessibility: UIAutomationBackend                         │
│                         │ • input: SendInputBackend                                    │
│                         │ • windows: Win32WindowBackend                                │
│                         │ • applications: Win32ProcessBackend                          │
│                         │ • clipboard: Win32ClipboardBackend                           │
├─────────────────────────┼──────────────────────────────────────────────────────────────┤
│ Linux (Pure X11)        │ • capture: X11ShmCaptureBackend                              │
│                         │ • accessibility: ATSPIBackend                                │
│                         │ • input: XTestInputBackend                                   │
│                         │ • windows: EWMHWindowBackend                                 │
│                         │ • applications: DesktopEntryBackend                          │
│                         │ • clipboard: X11ClipboardBackend                             │
├─────────────────────────┼──────────────────────────────────────────────────────────────┤
│ Linux (Pure Wayland)    │ • capture: PortalPipeWireCaptureBackend                      │
│                         │ • accessibility: ATSPIBackend                                │
│                         │ • input: PortalEISInputBackend? (若缺少 libei 则为 nil)       │
│                         │ • windows: nil (或 Compositor 专用 IPC Provider, 如 Sway)    │
│                         │ • applications: DesktopEntryBackend                          │
│                         │ • clipboard: WlClipboardBackend                              │
├─────────────────────────┼──────────────────────────────────────────────────────────────┤
│ Linux (Mixed XWayland)  │ • capture: PortalPipeWireCaptureBackend (捕获全局画面)       │
│                         │ • accessibility: ATSPIBackend                                │
│                         │ • input: PortalEISInputBackend (优先) 或 XTest (降级)        │
│                         │ • windows: EWMHWindowBackend (仅管理 X11 兼容窗口)           │
│                         │ • applications: DesktopEntryBackend                          │
│                         │ • clipboard: PortalClipboardBackend / WlClipboardBackend     │
└─────────────────────────┴──────────────────────────────────────────────────────────────┘
```

---

## 6. Observation / Action Contracts (契约数据结构草案)

### 6.1 Observation 领域模型

```swift
public struct ObservationID: Hashable, Sendable, Codable { public let rawValue: UUID }
public struct EnvironmentSessionID: Hashable, Sendable, Codable { public let rawValue: String }

public struct Observation: Sendable, Codable {
    public let id: ObservationID
    public let sessionID: EnvironmentSessionID
    /// 单调递增序列号，用于 Stale 检测
    public let version: Int64
    /// 挂钟时间，用于持久化、审计和 Trace
    public let observedAt: Date
    public let source: ObservationSource
    public let elements: [ElementRef: AccessibilityNodeSnapshot]
    /// 截图大对象哈希索引 (存储于 FileBlobStore)
    public let screenshotBlobRef: String?
    /// 交互区域边界快照
    public let viewportBounds: PixelRect
    public let displayMetrics: DisplayMetrics
}

public enum ObservationSource: Sendable, Codable {
    case browser(tabID: String, url: String, title: String)
    case desktop(displayID: String, activeWindowID: String?)
}
```

### 6.2 ElementRef 作用域唯一绑定

```swift
public struct ElementRef: Hashable, Sendable, Codable, CustomStringConvertible {
    public let sessionID: EnvironmentSessionID
    public let scopeID: String        // TabID 或 WindowID
    public let version: Int64          // 必须严格匹配产生该 Ref 时的 Observation.version
    public let index: Int              // 该帧内的局部自增编号

    public var description: String { "ref_\(index)@v\(version)" }
}
```

### 6.3 Action & ActionBatch 模型

```swift
public enum InteractionAction: Sendable, Codable {
    case click(target: ActionTarget, button: PointerButton = .left, count: Int = 1)
    case hover(target: ActionTarget)
    case type(text: String, target: ActionTarget?)
    case keyPress(key: KeyCode, modifiers: KeyModifiers = [])
    case scroll(target: ActionTarget?, deltaX: Double, deltaY: Double)
    case drag(from: ActionTarget, to: ActionTarget)
    case wait(condition: WaitCondition)
    case navigate(url: String)
}

public enum ActionTarget: Sendable, Codable {
    case element(ElementRef)
    case coordinate(TargetPosition)
}

public enum WaitCondition: Sendable, Codable {
    case duration(milliseconds: Int)
    case stable(timeoutMs: Int = 2000)
    case elementVisible(ref: ElementRef, timeoutMs: Int = 5000)
    case elementGone(ref: ElementRef, timeoutMs: Int = 5000)
    case urlMatches(pattern: String, timeoutMs: Int = 10000)
}

public struct ActionBatch: Sendable, Codable {
    public let id: UUID
    public let actions: [InteractionAction]
    public let stopOnFailure: Bool
    public let riskCategory: InteractionRiskCategory
}

public struct ActionBatchResult: Sendable, Codable {
    public let batchID: UUID
    public let completedStepCount: Int
    public let succeeded: Bool
    public let failureReason: String?
    public let finalObservationRef: ObservationID?
}
```

### 6.4 坐标空间与几何变换矩阵 (`CoordinateTransform`)

```swift
public enum CoordinateSpace: Sendable, Codable, Equatable {
    case physicalPixel(displayID: String)
    case logicalPoint(displayID: String)
    case normalized(displayID: String)     // 0.0 ... 1.0 (模型最佳视野)
    case windowLocal(windowID: String)
    case browserViewport(tabID: String)
}

public struct CoordinateTransform: Sendable {
    public static func toLogicalPoint(
        from target: TargetPosition,
        metrics: DisplayMetrics
    ) -> (x: Double, y: Double) {
        switch target.space {
        case .logicalPoint:
            return (target.x, target.y)
        case .physicalPixel:
            return (target.x / metrics.scaleFactor, target.y / metrics.scaleFactor)
        case .normalized:
            return (
                metrics.bounds.originX + target.x * metrics.bounds.width,
                metrics.bounds.originY + target.y * metrics.bounds.height
            )
        default:
            // 依赖窗口或视口原点做局部偏移变换
            return (target.x, target.y)
        }
    }
}
```

---

## 7. Session & Lifetime Model (多层级生命周期管理)

```text
┌─────────────────────────────────────────────────────────────┐
│                        AgentSession                         │ 持久化于 SQLite，长天数存活，用户主动注销
└──────────────────────────────┬──────────────────────────────┘
                               │ 1:N 逻辑托管 (非继承)
        ┌──────────────────────┴──────────────────────┐
        ▼                                             ▼
┌───────────────────────────────┐     ┌───────────────────────────────┐
│       BrowserHostSession      │     │        DesktopSession         │ 依附于 AgentSession，关闭时销毁
└───────────────┬───────────────┘     └───────────────┬───────────────┘
                │ 1:1                                 │ 1:1
┌───────────────▼───────────────┐     ┌───────────────▼───────────────┐
│      BrowserHostProcess       │     │       OS Login Session        │ 物理进程 / OS 图形会话
│ (Node.js Playwright Instance) │     │ (Wayland Compositor / WinLogon│
└───────────────┬───────────────┘     └───────────────────────────────┘
                │ 1:N
┌───────────────▼───────────────┐
│        BrowserContext         │ 独立 Cookie / Storage 隔离沙箱
└───────────────┬───────────────┘
                │ 1:N
┌───────────────▼───────────────┐
│          Page / Tab           │ 具体 DOM / 网页页面
└───────────────────────────────┘
```

- **生命周期约束**:
  - `BrowserHostProcess` 属于易失性外部资源，AgentSession 发生恢复（Restore）时，**绝不保存和恢复 Node 进程句柄**；
  - 恢复机制：仅恢复最后访问的 URL 与历史 Trace，重新发起 `launch()` 并分配全新的 `EnvironmentSessionID`。

---

## 8. Capability / Authorization / Permission (三层防御模型)

执行交互动作前的三层串联评估流水线：

```text
               Interaction Action Request
                           │
                           ▼
 ┌───────────────────────────────────────────────────┐
 │ Layer 1: Capability Check (系统在技术上能不能做?) │
 └─────────────────────────┬─────────────────────────┘
                           │ Unsupported ──► 抛出 InteractionCapabilityError
                           ▼ Supported
 ┌───────────────────────────────────────────────────┐
 │ Layer 2: OS Authorization (操作系统层许不许可?)   │
 └─────────────────────────┬─────────────────────────┘
                           │ Denied ──────► 抛出 SystemAuthorizationError (引导用户开系统权限)
                           ▼ Granted
 ┌───────────────────────────────────────────────────┐
 │ Layer 3: LingXi Permission (灵犀安全策略批不批准?)│
 └─────────────────────────┬─────────────────────────┘
                           │ Denied ──────► 抛出 InteractionPermissionError
                           ▼ Approved
                    Action Execution
```

---

## 9. Error Taxonomy (完整错误分类与模型决策指引)

| 错误类别 | 具体 Case 示例 | 根本原因 | 模型 / Agent 应对指引 |
|---|---|---|---|
| **`CapabilityError`** | `.unsupported(feature: "WindowEnumeration")` | 宿主系统（如 Wayland）协议不支持 | **不可重试**，降级方案或通知用户该环境受限 |
| **`SystemAuthorizationError`** | `.denied(subsystem: "Accessibility/TCC")` | macOS TCC 未勾选，Portal 对话框被拒 | **暂停并提示用户去系统设置授权** |
| **`InteractionPermissionError`**| `.highRiskActionRejected` | 用户拒绝转账确认，或白名单拦截 | **停止当前高危动作**，向用户报告被拒绝 |
| **`StaleReferenceError`** | `.versionMismatch(expected: 128, got: 129)` | 页面刷新或窗口跳转导致元素引用失效 | **必须重新截屏并获取最新 Observation** |
| **`ActionExecutionError`** | `.elementNotInteractable(ref)` | 按钮被遮挡、元素不可见或处于禁用状态 | **调整滚动位置或等待稳定后再试** |
| **`TimeoutError`** | `.conditionNotMet(condition: .networkIdle)` | 页面长时间未加载完毕 | **评估当前画面，按需提前继续** |
| **`CancellationError`** | `.taskCancelled` | 用户按 Ctrl+C 或点击 Stop 按钮 | **立即退出并执行 `neutralize()`** |
| **`HostProcessError`** | `.sidecarCrashed(exitCode: 137)` | Node.js Sidecar 内存超限崩溃 | **重新拉起 Host 进程并重建页面** |

---

## 10. Security Model (安全与注入防御规范)

1. **彻底解耦 Provenance 与 Authority**:
   - 屏幕像素与 DOM 文本由系统采集，其来源标记为 `Provenance.observedEnvironment`；
   - 权威等级固定为 `Authority.untrustedData`；
   - **绝对禁止将任何观察内容直接当做系统提示词（System Prompt）注入！**
2. **高危行为风险矩阵 (`InteractionRiskCategory`)**:
   - **Low (可信自动放行)**: 页面只读滚动、文本选择、同域内页面跳转；
   - **Medium (根据配置询问)**: 普通文本输入、普通按钮点击、表单提交；
   - **Critical (强制物理弹窗确认)**:
     - 包含 `confirm_payment`, `delete_account`, `transfer`, `grant_permission` 语义的按钮；
     - 涉及凭据提交（密码框回车）；
     - 上传本地敏感情报文件。
   - **硬拦截保证**: 即使模型被间接提示词注入（Prompt Injection）欺骗，发出包含 Critical 动作的 ActionBatch，`PermissionEngine` 将在底层无条件挂起并向终端弹出高亮确认，严禁自动执行。

---

## 11. IPC Architecture (分层子进程通信底座)

提炼自原 `GenericProcessLSPTransport` 的公共通信层次：

```text
┌────────────────────────────────────────────────────────┐
│                   ManagedProcess                       │ (Foundation.Process 包装、环境变量、信号与跨平台树终结)
└───────────────────────────▲────────────────────────────┘
                            │
┌───────────────────────────┴────────────────────────────┐
│                 StdioByteTransport                     │ (双向 Pipe、线程安全读写锁、分包与 Header 解析)
└───────────────────────────▲────────────────────────────┘
                            │
┌───────────────────────────┴────────────────────────────┐
│                    JSONRPCPeer                         │ (JSON-RPC 2.0 请求/响应匹配、Notification、取消分派)
└─────────────┬────────────────────────────┬─────────────┘
              │ 复用                       │ 复用
┌─────────────▼─────────────┐┌─────────────▼─────────────┐
│       LSPTransport        ││    BrowserHostClient      │
│  (保持既有 LSP 语义不变)   ││ (处理 initialize 握手与事件)│
└───────────────────────────┘└───────────────────────────┘
```

- **Browser Host 握手协商协议**:
  Sidecar 启动后首先进行 `initialize` 阶段：
  ```json
  // Request
  { "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": { "clientVersion": "1.0.0", "supportedProtocols": ["v1"] } }
  // Response
  { "jsonrpc": "2.0", "id": 1, "result": { "protocolVersion": "v1", "hostVersion": "playwright-1.42.0", "capabilities": ["headless", "video", "download"] } }
  ```

---

## 12. Testing Strategy (测试架构与 Fake Backend)

为保证在无真实图形环境（如 GitHub Actions Linux CI、无显示器的 macOS 构建机）下能够实现 100% 的单元测试覆盖，建立完善的 Fake 体系：

```swift
/// 纯内存实现的无障碍伪后端
public final class FakeAccessibilityBackend: AccessibilityBackend, @unchecked Sendable {
    public var mockTree: AccessibilityTreeSnapshot?
    public private(set) var performedActions: [(AccessibilityNodeID, AccessibilityAction)] = []
    
    public func fetchTree(scope: AccessibilityScope) async throws -> AccessibilityTreeSnapshot {
        mockTree ?? AccessibilityTreeSnapshot.empty
    }
    public func performAction(nodeID: AccessibilityNodeID, action: AccessibilityAction) async throws -> ActionResult {
        performedActions.append((nodeID, action))
        return .success
    }
}

/// 纯内存实现的输入中立化伪后端
public final class FakeInputBackend: InputBackend, @unchecked Sendable {
    public private(set) var events: [PointerInputEvent] = []
    public private(set) var neutralizedCount = 0
    
    public func injectPointer(event: PointerInputEvent) async { events.append(event) }
    public func injectKeyboard(event: KeyboardInputEvent) async {}
    public func neutralize() async { neutralizedCount += 1 }
}
```

- **单元测试矩阵**:
  1. **ActionBatch 熔断测试**: 给定 3 个 Action，Mock 第 2 个失败，验证第 3 个绝不执行，且 `FakeInputBackend.neutralizedCount == 1`；
  2. **Stale Ref 拦截测试**: 构造 `v128` 的 Ref，在 `v129` 的环境中执行，验证抛出 `StaleReferenceError`；
  3. **坐标变换测试**: 验证 Retina 2x 与 Windows 150% 缩放下，归一化坐标计算结果精确无漂移；
  4. **Browser 本地静态服务测试**: 编写轻量 HTTP Fixture，验证 Node Sidecar 的页面导航、DOM 提取与表单提交。

---

## 13. Revised Implementation Phases (修订后实施顺序)

```text
Phase 0: Interaction Contracts & IPC Foundation (零平台风险，纯契约层)
    │  - 提炼 StdioByteTransport 与 JSONRPCPeer
    │  - 扩展 SessionMessagePart 与 FileBlobStore 索引支持
    │  - 定义 Observation, ElementRef, ActionBatch, CoordinateSpace 契约
    │  - 落地 FakeBackends 与无 GUI 单元测试套件
    ▼
Phase 1: Browser Use MVP (基于 Playwright Sidecar)
    │  - 落地 Node.js Playwright Runner 与握手协议
    │  - 实现 BrowserSessionManager 与无状态 RPC Tools
    │  - 实现 DOM 树向精简 ElementRef 映射与 Stale 检测
    │  - 跑通标准 ActionBatch 顺序执行与 Token 预算安全防护
    ▼
Phase 2: macOS Computer Use 原生落地
    │  - 组装 DarwinDesktopEnvironment
    │  - 接入 ScreenCaptureKit + AXUIElement + CGEvent
    │  - 落实 InputNeutralization 与 TCC 权限错误精准上报
    │  - 验证 Semantic First / Vision Fallback 双轨执行
    ▼
Phase 3: Windows Computer Use 落地 (双异构 OS 验证)
    │  - 组装 WindowsDesktopEnvironment
    │  - 接入 Windows Graphics Capture + UI Automation + SendInput
    │  - 验证多 DPI 缩放下 CoordinateTransform 的通用性
    ▼
Phase 4: Linux 动态组合落地 (承受多样性检验)
    │  - 实现 LinuxCapabilityProbe (检测 D-Bus, Portal, PipeWire, EIS, XTest)
    │  - 实现 LinuxDesktopEnvironmentAssembler 动态装配
    │  - 跑通 X11 与 Wayland 下的优雅降级
    ▼
Phase 5: Vision Grounding 视觉定位增强
    │  - 预留 VisionGrounder 协议并接入多模态视觉模型
    │  - 实现从 Downscaled Screenshot 到 Logical Coordinate 的反向变换
    │  - 完善高危交互硬拦截规则
```

---

## 14. Phase 0 Exact Scope (Phase 0 任务清单与准入准出标准)

| 任务编号 | 任务名称 | 核心目标 | 涉及模块 | 是否破坏现有 API | 前置依赖 | 完成验收标准 (Definition of Done) |
|---|---|---|---|---|---|---|
| **P0-1** | **IPC 传输层解耦提炼** | 将 `GenericProcessLSPTransport` 提炼为独立的 `StdioByteTransport` 与 `JSONRPCPeer` | `LingXiCore/Modules/Symbol` -> `LingXiPlatform` / `LingXiCore` | **否** (LSP 重定向继承，向后兼容) | 无 | 原有多语言 LSP 功能测试 100% 通过；新通信类具备独立单元测试 |
| **P0-2** | **交互契约模型定义** | 在协议层新增 `InteractionTypes.swift`，定义 `Observation`, `ElementRef`, `ActionBatch`, `WaitCondition` 等数据结构 | `LingXiProtocol` | **否** (纯新增文件与符号) | 无 | 类型定义完备，支持 `Codable` 与 `Sendable`，编译无 Warning |
| **P0-3** | **协议层消息枚举扩展** | 在 `SessionMessagePart` 增加 `.observation(ObservationID)`，在 `ToolResult` 增加可选元数据 | `LingXiProtocol` | **否** (枚举扩展 Case，保持既有兼容) | P0-2 | 会话序列化/反序列化测试通过，既有纯文本会话无破坏 |
| **P0-4** | **桌面环境组合抽象** | 定义 6 大原子 Capability Protocol 与 `DesktopEnvironment` 组合结构体 | `LingXiPlatform/Protocols` | **否** (纯新增协议) | P0-2 | 协议具备高内聚性，不引用任何 Darwin/Win32/Linux 特有头文件 |
| **P0-5** | **错误分类体系构建** | 定义 `InteractionError` 体系，细分 Capability, SystemAuth, Permission, StaleRef 等 10 大分类 | `LingXiProtocol` | **否** (新增类型) | P0-2 | 能够精准区分系统缺失与用户拒绝，单元测试覆盖各分支 |
| **P0-6** | **Fake 基础设施与单元测试** | 实现全套 `FakeAccessibilityBackend`, `FakeInputBackend`, `FakeCaptureBackend` | `Tests/LingXiCoreTests` | **否** (仅测试代码) | P0-4, P0-5 | 编写无 GUI 单元测试，验证 ActionBatch 熔断、中立化调用与坐标映射 100% 通过 |

---
*(报告完毕，全篇技术边界严密收敛，随时可直接按 Phase 0 TODO 启动第一阶段契约代码编写)*
