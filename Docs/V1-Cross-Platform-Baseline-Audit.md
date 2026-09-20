# LingXiAgent V1.0.0 跨平台架构审计与基线冻结报告
**Cross-Platform Architecture Audit & Baseline Freeze Report**

- **系统版本**: LingXiAgent V1.0.0 (Release Candidate 1)
- **正式支持平台**: macOS (arm64/x86_64), Linux (Ubuntu/Debian/Arch/RHEL), Windows 10/11 / Server 2022 (x86_64)
- **正式用户入口**: CLI (`lingxiagent`), TUI (`LingXiTUI`), Core Service (`LingXiCoreHost`)
- **审计日期**: 2026-09-20
- **基线状态**: **FROZEN (正式冻结)**

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
| 16 | **TUI 原生渲染** | OpenTUI (Zig Dylib) | OpenTUI (Zig .so) | OpenTUI (Zig .dll) | 预编译三平台原生库 |
| 17 | **TUI ANSI 兜底渲染** | `AnsiFallbackRenderer` | `AnsiFallbackRenderer` | `AnsiFallbackRenderer` | 无原生动态库时 100% 纯 Swift ANSI 渲染 |
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

2. **`PlatformDesktopHelperProtocol`**:
   在 `Sources/LingXiPlatform/Protocols/PlatformDesktopCapabilityProtocol.swift` 中定义了平台无关的桌面辅助协议，并在 Darwin 下由 `DarwinDesktopHelperAdapter` 桥接 `NSScreen` 与 `DarwinVisionOCRBackend`，在非 Darwin 平台由 `HeadlessDesktopHelperAdapter` 提供无头实现。
   `Sources/LingXiCore/Modules/Tool/ComputerBatchTool.swift` 中直接引用的 `import Cocoa`、`import CoreGraphics` 以及 macOS 专用 Overlay 全部移除。

3. **架构静态守卫测试 (`PlatformBoundaryArchitectureTests.swift`)**:
   配置了强制性静态扫描门禁，任何在 `LingXiCore`、`LingXiApplication`、`LingXiClient`、`LingXiTUI`、`LingXiProtocol` 中直接出现的以下 import 将直接导致构建门禁阻断：
   - `import AppKit`
   - `import Cocoa`
   - `import CoreGraphics`
   - `import CoreFoundation`
   - `import Security`
   - `import Darwin`
   - `import Glibc`
   - `import WinSDK`

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

## 7. TUI 跨平台终端与渲染方案

1. **双轨渲染管道**:
   - **优先原生轨道 (OpenTUI)**: 通过 FFI 加载各平台优化的 Zig 动态库（macOS `libopentui.dylib`, Linux `libopentui.so`, Windows `libopentui.dll`），提供亚毫秒级的终端局部脏矩形差分渲染。
   - **安全回退轨道 (`AnsiFallbackRenderer`)**: 当宿主环境未部署动态库或运行在极简容器/无头环境时，自动透明降级为 100% 纯 Swift 实现的 ANSI 转义序列渲染器，保证终端界面在任何环境下均不崩溃、不乱码。
2. **Smoke 验证**:
   `lingxiagent --smoke` 在无真实 TTY 的测试环境下，成功完成终端与渲染管线的无头初始化和回退自检。

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
