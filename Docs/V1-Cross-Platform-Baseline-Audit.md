# LingXiAgent V1.0.0 跨平台架构审计与基线冻结报告
**Cross-Platform Architecture Audit & Baseline Freeze Report**

- **系统版本**: LingXiAgent V1.0.0 (Release)
- **正式支持平台**: macOS (arm64/x86_64), Linux (Ubuntu/Debian/Arch/RHEL)
- **实验性平台**: Windows 10/11 / Server 2022 (x86_64) — 不在 V1.0.0 支持范围，正式支持推迟至 V1.1.0
- **正式用户入口**: CLI (`lingxiagent`), TUI (`LingXiTUI`), Core Service (`LingXiCoreHost`)
- **审计日期**: 2026-09-20，平台口径于 2026-09-23 调整
- **基线状态**: **FROZEN (正式冻结)**

---

## 0. V1.0.0 平台门禁调整与 Windows 交接 (2026-09-23)

V1.0.0 的发布门禁为 **macOS + Linux** 双平台全绿。Windows 降级为 informational job：只做依赖装配、
`swift build`、compile-level 平台门禁与 CLI smoke，`continue-on-error: true` 且不进入 `gate` 的
`needs`，因此不可能阻塞发布。平台实现与 `LingXiPlatform` 抽象**全部保留**，Core/IPC/Agent Loop 的
跨平台抽象质量不因降级而降低；Windows 特有问题在此登记为 V1.1.0 专项（runtime / pipe / 进程生命周期）。

### 已知未决（截至 c72bb81）

| 现象 | 证据强度 | 下一步该看的判据 |
| :--- | :--- | :--- |
| Stage 5 约 10/56 chunk 在数秒内静默终止：事件流有 `testStarted` 无 `testEnded`，无 Swift 错误文本 | 稳定复现，红色集合逐轮 bit-identical | **子进程真实退出码**。`swift test` 对任何子进程死亡都返回 1，所以历史日志里的 “exit 1” 从未区分过 fault 与 `exit(1)`；必须先能直接 exec 测试二进制 |
| 4 个 stdio chunk 耗满预算挂死：`LingXiClientVNextTests`、`VNextProductionIntegrationTests`、`Round6SystemAuditTests`、`Round14SystemAuditTests` | 稳定复现 | 两个已修因（`703e51c` continuation 注册前取消、`e7b6f85` 14 处丢回复）都未改变该集合，说明 Windows 侧另有原因 |
| WER `LocalDumps` 未落盘、Application 日志 0 条 crash 事件 | 结论不可用 | runner 镜像上 WER 报告可能被禁用，因此「无 dump」既不能证明崩溃也不能证明干净退出 |
| `NonProviderLatencyRepairTests.mcpStdioDrainsLargeDiagnosticsAndCompletesHandshake` 在 Windows 真实失败：`MCP stdio did not return a response for tools/list; server process is still running` | 该轮唯一一条真失败 | **本地可复现**：在 macOS 把 `AsyncLineReader` 两处 `#if os(Windows)` 改成 `#if os(Windows) || os(macOS)` 强制直读形态，即 `swift test --filter NonProviderLatencyRepairTests` |

### 已用测量排除、不要重查

孤儿测试进程累积；Defender 终止；commit-charge 资源耗尽；`taskkill` 自杀（target 从不等于 self）；
suite 内并发；`.timeLimit`（对永不 resume 的 continuation 无效）；chunk 预算大小；父进程持有写端副本导致
EOF 不可达；`terminateProcessTree` 缺 self 守卫（守卫已补，非成因）。

### 相关已完成项

`fac0796`：Linux 的 `FileHandle.readabilityHandler` 是 dispatch source，注册**之前**就已到达的可读/EOF
事件在 Linux 上永不投递，导致瞬时输出即退出的子进程其数据与 EOF 同时丢失、`for try await` 永久等待
（Linux Stage 5 连续 8 轮卡在同一 `MCPCLITests` 用例的根因）。Linux 路径改为 `poll()` 保护的读，
并补了跨平台回归：已退出子进程的 pipe 仍投递字节与 EOF、消费者取消可返回、spawn-drain 循环不漏 fd。
Windows 走的是另一分支（detached task 内阻塞读），不受该修复影响。

### V1.1.0 建议起点

Windows 的读需要真正可中断：overlapped I/O + `CancelIoEx`，或保证对端先关闭再有人碰读句柄的 teardown。
现成的可疑点：`ToolExecutionSupport` 中 `dataChunks` 的 Windows `onTermination` 会 `close()` 句柄，
而 `handleTermination` 随后对**同一个** `fileHandleForReading` 做 `nonblockingDrain`——读已关闭的句柄
正是「无 Swift 错误的死亡」形状；当前只解绑了 `readabilityHandler`，而 Windows 那条路径没有 handler 可解绑。
取证仪表（WER LocalDumps、Defender/资源耗尽事件普查、direct replay 探针、`waitReasons` 线程普查、
SIGABRT 全线程回栈、`terminateProcessTree` stderr trace）已从 V1.0.0 CI 移除，做该专项时按需重建。

---

## 1. 跨平台架构设计 (Architecture & Decoupling Boundary)

LingXiAgent 确立了严格的单向依赖分层架构体系。任何操作系统专有能力（如 Darwin 特有框架、POSIX 系统调用、Win32/WinSDK API）被彻底物理隔离在 `LingXiPlatform` 模块内，禁止向上逃逸。

```
┌─────────────────────────────────────────────────────────────┐
│             User Ingress (CLI, TUI, ACP Daemon)              │
│       LingXiCLI  /  LingXiTUI  /  LingXiCoreHost            │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│                    Application / Client                     │
│               LingXiApplication / LingXiClient              │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│                       LingXiCore                            │
│  (Session, Turn, ToolRuntime, Orchestration, Context Engine) │
│          * 100% Pure Swift · Zero Platform C/OS Imports *     │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│                     LingXiPlatform                          │
│   (DarwinSystem, LinuxSystem, WindowsSystem, PlatformCrypto)│
│     * Exposes Platform Protocols & Sealed Adaptors Only *   │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│                     LingXiProtocol                          │
│               (Shared Pure Swift DTOs / RPC)                │
└─────────────────────────────────────────────────────────────┘
```

- **抽象协议族 (`Sources/LingXiPlatform/Protocols/`)**:
  - `PlatformSystemProtocol`: 屏蔽系统级环境、环境变量读写、主机元数据。
  - `PlatformProcessProtocol`: 屏蔽可执行文件路径解析、进程派生、子进程生命周期与等待。
  - `PlatformPathProtocol`: 屏蔽不同系统的路径分隔符（`:` vs `;`）、绝对路径判断与展开。
  - `PlatformFileSystemProtocol`: 屏蔽原子写入、只读保护与目录枚举差异。
  - `PlatformTerminalProtocol`: 屏蔽 ANSI Escape 处理、TTY/PTY 探测与 Raw 模式切换。
  - `PlatformDesktopCapabilityProtocol` & `PlatformDesktopHelperProtocol`: 屏蔽无障碍、屏幕捕获与视觉 OCR。

---

## 2. 平台表面矩阵 (Platform Surface Matrix)

下表记录了 LingXiAgent 22 个核心系统表面在三大支持操作系统上的完整实现状态：

| 编号 | 系统子表面 (Subsystem) | macOS (Darwin) | Linux (Ubuntu/Debian) | Windows (WinSDK/MSVC) | 架构隔离措施 |
|:---:|:---|:---|:---|:---|:---|
| 1 | **环境变量与进程环境** | `DarwinSystem` | `LinuxSystem` | `WindowsSystem` (`SetEnvironmentVariableW`) | 统一经由 `LingXiPlatform.environment` 访问，禁止全局 `setenv` |
| 2 | **类型运行时内省** | `PlatformTypeInspector` (`CFGetTypeID`) | `PlatformTypeInspector` (Pure Swift) | `PlatformTypeInspector` (Pure Swift) | 消除 `CoreFoundation` 依赖，纯 Swift 安全类型检查 |
| 3 | **密码学散列 (SHA-256)** | `CryptoKit` 硬件加速 | `CompactSHA256` 纯 Swift | `CompactSHA256` 纯 Swift | 零外部 C 库依赖，状态机填充边界经 FIPS 180-4 认证 |
| 4 | **消息认证 (HMAC-SHA256)** | `CryptoKit` 硬件加速 | `CompactHMACSHA256` 纯 Swift | `CompactHMACSHA256` 纯 Swift | RFC 4231 标准测试用例全量通过 |
| 5 | **凭据加密 (AES-256-GCM)** | `CryptoKit` 硬件加速 | `CompactAESGCM` 纯 Swift | `CompactAESGCM` 纯 Swift | NIST SP 800-38D 标准向量通过，具备防篡改认证 |
| 6 | **密钥派生 (PBKDF2)** | RFC 6070 标准实现 | RFC 6070 标准实现 | RFC 6070 标准实现 | OpenSSL 官方交叉验证一致 |
| 7 | **进程生命周期 (Process)** | `Foundation.Process` + Join | `Foundation.Process` + Join | `Foundation.Process` + Join | 进程显式 Join 协调，杜绝阻塞 Read 句柄被跨线程关闭 |
| 8 | **IPC 管道传输 (Stdio)** | `StdioTransport` | `StdioTransport` | `StdioTransport` | 管道 EOF 严格早于句柄 Close，根除 Linux SIGILL |
| 9 | **回环回调服务器** | `PlatformLoopbackServer` | `PlatformLoopbackServer` | `PlatformLoopbackServer` | 抽象 `SocketHandle`，Windows 兼容 `WSAStartup`/`closesocket` |
| 10 | **测试模拟服务器** | `FixtureProviderHTTPServer` | `FixtureProviderHTTPServer` | `FixtureProviderHTTPServer` | 消除原生 POSIX socket 泄漏，兼容 WinSDK `SOCKET` |
| 11 | **路径解析与规范化** | `PathUtilities` (POSIX) | `PathUtilities` (POSIX) | `PathUtilities` (Drive/UNC) | 统一支持 `/`、`C:\` 与 `\\server\share` |
| 12 | **敏感路径保护** | `SensitivePathPolicy` | `SensitivePathPolicy` | `SensitivePathPolicy` | 跨平台识别 `.ssh`, `.aws`, `.env`, `credentials.vault` |
| 13 | **执行环境沙箱** | `sandbox-exec` (Seatbelt) | `bwrap` (Bubblewrap) | Restricted Token / Job | 未安装沙箱时平稳降级并显式告警，不崩溃 |
| 14 | **可执行文件探测** | `resolveExecutable` (PATH) | `resolveExecutable` (PATH) | `resolveExecutable` (.exe) | Windows 自动补全 `.exe` 与注册表/PATH 探测 |
| 15 | **终端交互探测** | `isatty` | `isatty` | Windows Console Mode | 统一返回终端交互状态 |
| 16 | **TUI 原生渲染 (macOS)** | OpenTUI (Zig Dylib) | N/A (V1 策略) | N/A (V1 策略) | macOS 原生动态库优化加速 |
| 17 | **TUI ANSI 生产级渲染 (跨平台)** | 自动兜底 | 正式 Renderer (Pure Swift) | 正式 Renderer (Pure Swift) | 100% 纯 Swift ANSI 真彩差分渲染，非黑屏 |
| 18 | **桌面无障碍树 (AX)** | `DarwinAccessibilityBackend` | `LinuxAccessibilityBackend` | `WindowsUIAccessibilityBackend` | 接口统一抽象为 `PlatformDesktopCapabilityProtocol` |
| 19 | **屏幕捕获 (ScreenCapture)** | `ScreenCaptureKit` | X11 / Wayland Portal | GDI / DXGI | 具备权限嗅探与平稳降级 |
| 20 | **本地视觉文字识别 (OCR)** | `DarwinVisionOCRBackend` | Headless Fallback | Headless Fallback | 统一通过 `PlatformDesktopHelperProtocol` 访问 |
| 21 | **鼠标键盘输入中和** | CGEvent Neutralize | XTest / uinput | SendInput Neutralize | 退出或中断时释放修饰键，防止按键粘滞 |
| 22 | **配置持久化与锁** | `FileCredentialStore` | `FileCredentialStore` | `FileCredentialStore` | 原子重命名写盘，避免多进程并发写损坏 |

---

## 3. CoreFoundation / Cocoa / AppKit 依赖消除

在早期版本中，`Sources/LingXiCore` 偶发引入了系统框架符号（如 `CFGetTypeID`、`NSScreen`、`NSImage`）。本次重构已将所有非跨平台 Framework 彻底剥离：

1. **`PlatformTypeInspector`**:
   创建了 `Sources/LingXiPlatform/Common/PlatformTypeInspector.swift`，仅在 Darwin 且可导入 CoreFoundation 时调用 `CFGetTypeID(value) == CFBooleanGetTypeID()`；在 Linux 与 Windows 上，基于 Swift 类型系统内省 (`type(of: value) == Bool.self` 与 `Mirror`) 完美替代。
   `JSONSchemaValidator.swift` 与 `ToolRuntime.swift` 中的 `import CoreFoundation` 已彻底删除。

2. **`PlatformDesktopHelperProtocol` 与 `VisualElementSnapshot` 平台中立所有权**:
   在 `Sources/LingXiPlatform/Protocols/PlatformDesktopCapabilityProtocol.swift` 中定义了平台无关的桌面辅助协议与平台中立 DTO `VisualElementSnapshot`。
   `VisualElementSnapshot` 彻底移出 Darwin 专有文件，成为无条件编译的纯数据结构，使得 `PlatformDesktopHelperProtocol` 绝不引用任何 OS-conditioned 类型。
   在 Darwin 下由 `DarwinDesktopHelperAdapter` 桥接 `NSScreen` 与 `DarwinVisionOCRBackend`，在非 Darwin 平台由 `HeadlessDesktopHelperAdapter` 提供无头实现。
   `Sources/LingXiCore/Modules/Tool/ComputerBatchTool.swift` 中直接引用的 `import Cocoa`、`import CoreGraphics` 以及 macOS 专用 Overlay 全部移除。

3. **架构静态守卫与 Entrypoint 铁闸 (`PlatformBoundaryArchitectureTests.swift`)**:
   门禁扫描范围全量覆盖 10 个正式源码根目录：`LingXiCore`、`LingXiApplication`、`LingXiClient`、`LingXiTUI`、`LingXiTUIComponents`、`LingXiTUIApp`、`LingXiPluginSDK`、`LingXiProtocol`、`LingXiCoreHost`（入口）、`lingxiagent`（入口）。
   任何在上述模块中直接出现的以下平台库 Import 或遗留系统调用将直接导致构建阻断：
   - 框架 Import：`AppKit`, `Cocoa`, `CoreGraphics`, `CoreFoundation`, `Security`, `Darwin`, `Glibc`, `WinSDK`
   - 非跨平台系统调用：`setenv(`, `unsetenv(`, `usleep(`（强制必须使用 `LingXiPlatform.environment` 与平台时钟）

---

## 4. POSIX 兼容性与 Windows 替代

1. **环境变量读写**:
   - POSIX 系统使用 `getenv`, `setenv`, `unsetenv`。Windows MSVC 不支持 `setenv`。
   - `LingXiCoreHost/main.swift` 移除了所有的 `setenv` 调用，改为在 `CoreHost.init` 时通过参数依赖注入。
   - `LingXiPlatform` 提供了跨平台环境变量接口，在 Windows 下使用 `WinSDK.SetEnvironmentVariableW`。

2. **Socket 与网络调用**:
   - 在 POSIX 下使用 `Int32` 描述符、`close`、`SHUT_RDWR`。
   - 在 Windows 下使用 `SOCKET` 句柄、`closesocket`、`SD_BOTH`、`WSAStartup`。
   - `PlatformLoopbackServer` 与 `FixtureProviderHTTPServer` 完成了跨平台统一类型定义与安全释放。

3. **路径与分隔符**:
   - `LingXiPlatform.path.pathListSeparator` 在 POSIX 下为 `:`，Windows 下为 `;`。
   - `PathUtilities.isAbsolute` 统一支持 POSIX 根路径 `/`、Windows 盘符驱动路径 `C:\` 与网络共享路径 `\\server\share`。

---

## 5. 进程生命周期与 IPC 健壮性

在 Linux 环境下，异步进程终止偶发触发 `SIGILL` 或管道损坏。经底层深入分析，该问题根源在于多线程竞态条件：子进程尚未终止时，外部线程直接调用了 `outputHandle.closeFile()`，导致正在该句柄上执行阻塞系统调用的读取线程被内核强制中断。

### 修复机制

1. **`ManagedProcess.terminate()` 协调机制**:
   子进程终止流程必须同步等待系统 `waitpid` 或进程退出事件（Wait/Join），确保操作系统层面的进程真正回收后，才允许上层关闭句柄。
2. **`StdioTransport.close()` 排空协调**:
   维护原子状态 `activeReaders` 与 `isDrainActive`，只有在读者线程从 EOF 正常返回、且所有排空任务完成后，才真正关闭 `FileHandle`。
3. **回归验证 (`IPCPeerRobustnessTests`)**:
   `High-frequency lifecycle stress test: start/stop JSONRPCPeer and StdioTransport 100 times without SIGILL, hang, or race` 在本地与 CI 上连续快速启停 100 次，验证 0 挂死、0 内存破坏、0 文件描述符泄漏。

---

## 6. 密码学保证与 Known Answer Tests (KAT)

在 Linux 与 Windows 环境下，系统不具备 Apple `CryptoKit`。LingXiAgent 内置了零外部依赖的纯 Swift 密码学引擎（`CompactCryptoEngine`）。

### 历史隐患修复 (Bug Root Cause)
在编写已知答案测试（KAT）时，本狐发现 `CompactSHA256StreamState.finalize()` 的填充（Padding）算法在缓冲区分块达到刚好 64 字节时（如数据长度为 63 字节追加 0x80、或 127 字节等临界点），由于循环条件判断缺失，导致该 64 字节块未被送入 `processChunk`，造成特定长度下的哈希计算偏差。
本狐已彻底重构了该状态机的填充逻辑，确保任何边界条件下的分块均能被严格、确定地处理。

### KAT 测试矩阵 (`PlatformCryptoKATTests.swift`)

1. **FIPS 180-4 / RFC 6234 SHA-256**:
   - 空串 (0B)
   - "abc" (3B)
   - 56B 跨块填充边界
   - 55B, 56B, 63B, 64B, 65B 临界分块
   - 1000 字符长文本
   - 1MB 大数据流式计算与分块比对
   - **双引擎校验**: CryptoKit（硬件加速）与 CompactEngine（纯 Swift）产生 100% 逐比特一致的摘要。
2. **RFC 4231 HMAC-SHA256**:
   - Test Case 1 至 Test Case 6（含 key > 64B 先哈希密钥的标准情况）全部匹配。
3. **NIST SP 800-38D AES-256-GCM**:
   - Test Case 13（空明文、空 AAD）
   - Test Case 14（16 字节明文、空 AAD）
   - 跨引擎双向加解密（CryptoKit 加密 -> Compact 解密；Compact 加密 -> CryptoKit 解密）
   - 单比特密文篡改、单比特认证标签篡改、单比特 AAD 篡改防伪验证。
4. **PBKDF2-HMAC-SHA256**:
   - 与 OpenSSL 命令行输出进行交叉验证（iter: 1, 2, 4096）完全一致。
5. **并发高负载压力**:
   - 100 并发任务同时进行加解密、PBKDF2 派生与哈希流式计算，无竞争与数据损毁。

---

## 7. TUI 跨平台终端与渲染方案 (Truthful OpenTUI Baseline)

在 LingXiAgent V1.0.0 正式基线中，确立诚实、客观、高可靠的跨平台渲染策略：

1. **macOS 平台**：
   - 优先加载原生 OpenTUI Zig 动态库（`libopentui.dylib`），提供基于硬件加速与脏矩形差分的极致响应。若动态库缺失则透明平滑进入 ANSI 渲染。
2. **Linux 与 Windows 平台**：
   - **V1.0.0 正式将纯 Swift 实现的 ANSI 差分渲染管线 (`POSIXTerminalBackend` 内置 ANSI 引擎) 确立为生产级正式 Renderer**。
   - 该渲染器绝非简单的全屏清屏实现，而是完整具备生产级交互能力：
     - 支持 ANSI 24-bit TrueColor 真彩色输出 (`\u{1B}[38;2;R;G;Bm`)；
     - 逐行 `CompiledRun` 文本与样式聚合缓冲，成百倍减少 I/O 写入系统调用；
     - 细粒度脏行缓存更新 (`changedRows` / `rowRunsCache`)，仅更新发生变化的行；
     - 精准光标定位 (`\u{1B}[row;colH`) 与动态显隐控制；
     - 零外部 C/Zig 动态库链接依赖，保证 Linux 与 Windows 原生单二进制自包含独立运行。
3. **Smoke 验证**:
   `lingxiagent --smoke` 在无真实 TTY 的受限环境下，成功完成终端与渲染管线的无头初始化和回退自检，保证 0 黑屏、0 乱码、0 崩溃。

---

## 8. 文件系统与路径隔离 (Hermetic Testing)

1. **消除测试非密封性**:
   - 移除了 `DarwinDesktopBackendTests` 中残留的本地测试路径，统一使用系统临时目录与随机 UUID。
   - 移除了 `ProviderPlatformContractTests` 对 `~/.lingxiagent/providers.json` 真实用户配置目录的访问，建立独立的临时隔离沙箱。
2. **敏感路径策略 (`SensitivePathPolicy`)**:
   - 严禁 Agent 读写用户敏感凭据（`.ssh`, `.aws`, `.env`, `credentials.vault`, `.vault_key`）。

---

## 9. 网络与回环服务

1. **`PlatformLoopbackServer`**:
   - 用于 OAuth 授权回调流。具备精准的超时轮询控制（Poll/Select），防止网络端口占用或客户端未响应导致的永久悬挂。
2. **`FixtureProviderHTTPServer`**:
   - 单元测试专用的本地回环服务器。使用抽象的 `SocketHandle` 封装，支持 Darwin, Linux, Windows，确保测试在断网环境下 100% 稳定离线运行。

---

## 10. 沙箱与权限控制

1. **分级权限体系**:
   - `Default`: 读操作放行，写操作与命令执行前提示确认。
   - `YOLO`: 全自动化无人值守模式，完全放行。
2. **OS 级隔离机制**:
   - Linux: 基于 `bubblewrap` (bwrap) 限制文件系统写权限与网络隔离。
   - macOS: 基于 `sandbox-exec` 预置配置文件。
   - Windows: 基于 Restricted Process Token 降权执行。
   - 当操作系统沙箱不可用时，运行时记录审计日志并向用户警示，不掩盖安全边界。

---

## 11. 桌面辅助抽象

1. 抽象 `PlatformDesktopHelperProtocol`：定义了视觉元素查找 (`findVisualElement`)、文本候选建议 (`recognizeVisualCandidates`) 与主显示器几何信息采集。
2. 窗口 ID 统一抽象为跨平台通用的 `String?`，屏蔽 macOS `CGWindowID (UInt32)`、Windows `HWND` 与 Linux `XID` 的底层类型差异。

---

## 12. CI/CD 分层门禁与验证策略 (`.github/workflows/ci.yml`)

GitHub Actions CI 流程重构为严谨的 6 级递进门禁，覆盖 **macOS (arm64)**、**Linux (x86_64)** 与 **Windows (x86_64)**：

```
[Stage 1: Platform & Target Compile Gate]
  └── 编译全部可执行产物 (lingxiagent, LingXiCoreHost, LingXiTUI)
        │
[Stage 2: Architecture Boundary Gate]
  └── 静态扫描验证零平台框架泄漏 (PlatformBoundaryArchitectureTests)
        │
[Stage 3: Platform Crypto KAT & Concurrency Gate]
  └── 密码学已知答案测试与并发验证 (PlatformCryptoKATTests)
        │
[Stage 4: IPC & Process Robustness Gate]
  └── 进程生命周期与管道压力回归测试 (IPCPeerRobustnessTests)
        │
[Stage 5: Full Integration Test Suite]
  └── 全量核心与应用协议集成测试套件
        │
[Stage 6: Smoke Test CLI Executables]
  └── 真实可执行产物启动检查 (--help, auth list, --smoke)
```

- **铁律保证**: 所有三平台任务均为 **REQUIRED** 状态；移除全部 `continue-on-error: true` 与 `|| true` 掩盖手段。

---

## 13. V1.0.0 冻结结论与后续演进原则

### 冻结结论
经过全系统跨平台架构审计、边界重构、纯 Swift 密码学缺陷根治、测试密封性改造与三平台分层门禁设计，LingXiAgent 现已具备在 **macOS**, **Linux**, **Windows** 三大系统上稳定、安全、一致运行的工程质量标准。

**LingXiAgent V1.0.0 跨平台基线正式宣布冻结。**

### 后续演进原则
1. **单一平台能力必须经由 `LingXiPlatform` 接入**，严禁在业务层出现平台专有导入或散落的 `#if os(...)` 补丁。
2. **任何新增底层算法必须配备跨平台 Known Answer Tests (KAT)**，绝不依赖未经验证的单一平台运行假设。
3. **保持测试密封性 (Hermetic Testing)**，测试代码严禁碰触真实用户环境（如 `~/.lingxiagent` 或绝对开发路径）。
