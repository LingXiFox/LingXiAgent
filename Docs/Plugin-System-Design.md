# LingXiAgent 2.0 插件系统设计与 `.lxap` 契约

依据：项目书 §3.2、§3.3、§五.3–4、§七第 2–5 条；Phase 0.1 架构决策（2026-10-19）。
本文取代阶段 0 初稿中的"插件即子进程、作者自行实现 IPC"方案。产品形态仍是**最简内核 + 插件加载器**。

## 一、三层运行模型

```
Core 进程 ──(内部 IPC：JSON-RPC)── Plugin Host 进程 ×N ──(固定 C ABI)── 插件动态库（`.lxap` 内）
```

| 层 | 职责 | 谁负责 |
|---|---|---|
| 插件动态库 | 实现能力接口（provider / tool / service / hook / event） | **插件作者**（官方与社区完全相同） |
| Plugin Host | `dlopen` 与签名校验、ABI 协商、把 IPC 请求翻译成 ABI 调用、把 ABI 回调翻译成 IPC 事件、取消、生命周期、崩溃边界 | LingXi 官方发布的一个通用可执行文件，**不含任何插件代码** |
| Core | 能力路由、上下文与 Agent Loop、权限决策、故障归因、registry | 内核 |

关键取舍：**插件作者只写函数实现，不写 IPC、不管理进程、不做序列化**（Phase 0.1 决策第 4、5 条）；同时隔离边界仍是进程——插件段错误只打死它自己的 Host，插件死循环只让该 Host 沉默。`dlopen` 在独立 Host 内做，是同时满足"作者契约简单"与"故障不带崩 Core"的唯一干净解。

推论（必须写下来，否则会被悄悄违反）：

- 插件与 Host 处于同一地址空间，**不存在语言级隔离**。第 3 章的权限强制执行是唯一的真实边界。
- 一个插件一个 Host 实例。Host 生命周期由 Core 监管者管理，不由用户手工启动。
- Host 与 Core 同版本发布；插件独立发布。三者版本兼容性由 ABI 版本与能力协商决定（第 4 章）。
- 官方插件不享有任何特权通道：与社区插件走同一个 Host、同一套 ABI、同一套注册契约、同一套权限判定。

## 二、`.lxap` 包格式：macOS 原生 bundle

`.lxap` 是 macOS 原生 bundle 形态的目录包（可 `.lxap` 直接分发，也可 zip 或 dmg 承载），采用标准 bundle 布局与标准代码签名，不自造签名体系（Phase 0.1 决策第 1、4 条；解决阶段 0 待决 Q-P1）。

```
AnthropicProvider.lxap/
├── Contents/
│   ├── Info.plist                    Manifest（身份、版本、作者、入口、能力、权限）
│   ├── MacOS/
│   │   └── LingXiAnthropicProvider   导出固定 C ABI 的动态库（.dylib 角色，放在 MacOS/ 下）
│   ├── Resources/                    schema、图标、文档、静态资源
│   └── _CodeSignature/CodeResources  标准签名资源，由 codesign 生成
```

约束：

- `CFBundleIdentifier` 即插件 `id`（反向域名，全局唯一，注册面命名空间前缀）；`CFBundleShortVersionString` / `CFBundleVersion` 即插件版本；作者身份由**代码签名的 Team Identifier** 决定，不由 manifest 自称。发布策略见第 8 章。
- `LSMinimumSystemVersion` 声明系统下限；首发基线 macOS 26.2。
- 现阶段只接受 `arm64-apple-macos` 一个架构切片；出现其他架构视为打包错误。
- 入口只有一个动态库；禁止包内安装脚本、禁止包触发网络安装动作。
- LingXi 专有字段放进 `Info.plist` 的顶层 `LingXiPlugin` 字典，不与系统键混写：

```xml
<key>LingXiPlugin</key>
<dict>
  <key>ABIMajor</key><integer>1</integer>          <!-- 与插件导出符号协商，唯一生效的版本语义 -->
  <key>MinimumCoreVersion</key><string>2.0.0</string>  <!-- 仅人类提示，不参与判定 -->
  <key>EntryPoint</key><string>LingXiPlugin_Init</string>
  <key>Capabilities</key>                           <!-- 必须显式声明，无默认值；见 §2.1 -->
  <key>Permissions</key>                            <!-- 见第 8 章 -->
  <key>Depends</key><array/>                        <!-- 其他插件 id + 版本区间 -->
  <key>Conflicts</key><array/>
</dict>
```

### 2.1 能力与权限声明

能力和权限都**必须显式声明**，解码器不提供默认值，缺字段即加载失败。这条纪律来自 1.x 被验证过的教训：能力广告必须"挣得"，`RuntimeCapabilities` 去掉默认参数使"不显式声明就不编译"（PLG-009）；以及 35 种 quirk 名里运行时只读 1 条、其余只是文档的死重（E-06）。

## 三、插件 ABI：固定 C ABI

Phase 0.1 决策第 2 条：插件二进制采用固定 C ABI，导出 `LingXiPlugin_Init()`。

1.x 的事实基线：全仓 `@_cdecl` 零命中，唯一的运行时动态加载先例是 `Sources/OpenTUIShim/OpenTUIShim.c:36 opentui_load()`（`dlopen(RTLD_NOW|RTLD_LOCAL)` + `dlsym` 预检 15 个必需符号），它**没有 version/size 字段**、前向兼容完全依赖符号存在性，错误传递用 `static error_message[256]`——在并发多请求下不安全。2.0 的 ABI 必须避开这两点。

### 3.1 导出面

```c
// 插件必须且只需导出这一个符号；符号名可被 manifest 的 EntryPoint 覆盖以支持多实例
LX_EXPORT LingXiStatus LingXiPlugin_Init(
    const LingXiHostAPI* hostAPI,      // Host 提供的回调表（日志、发事件、请求权限、注册能力）
    uint32_t             hostABIMajor, // Host 实现的 ABI 主版本
    const LingXiPluginAPI** outAPI,    // 插件提供的函数表
    uint32_t*            outABIMajor); // 插件声明的 ABI 主版本
```

Host 只用这一个符号找到插件；插件生命周期其余入口都在 `LingXiPluginAPI` 函数表里。

### 3.2 ABI 规则（不可协商）

1. **每个跨边界结构体首两字段固定为 `structSize` 与 `abiMajor`**。Host 按 `structSize` 判断字段可用性，新增字段一律追加在尾部。这是 1.x OpenTUIShim 缺失的那块，也是 2.0 前向兼容的唯一手段。
2. 边界上只允许：定宽整数、指针、`const uint8_t* + uint32_t length`（UTF-8，**不假定 NUL 结尾**）、函数指针表。禁止 Swift / C++ 类型、异常、标准库容器跨边界。
3. **所有权显式**：入参字符串只在调用期间有效，被调方若需留存必须复制；返回的缓冲区由分配方导出 `LingXiFree`，谁分配谁释放，规则写进头文件而非口头约定。
4. 错误经 `LingXiStatus{code, domain, message}` **结构返回**，不使用全局缓冲、`errno` 或 thread-local；`code` 是封闭枚举，与第 6 章故障分类表一致。
5. 插件回调 Core 只能通过 `LingXiHostAPI` 表；插件不得自行 spawn 线程直接触碰 Core 状态，异步工作一律经 Host 提供的执行入口。
6. 调用顺序上有硬约束：`Init → Start → (运行) → Stop → Dispose`。`dlclose` 只在无在途调用时执行。
7. Swift 插件用 `@_cdecl("LingXiPlugin_Init")` 导出；**插件必须只依赖 macOS 自带的 Swift 运行时，不得静态嵌入 stdlib**，否则同一 Host 内出现两份运行时。Host 与 Core 同版本发布，插件可独立发布，正是靠这条约束才成立。
8. ABI 主版本不匹配 = 拒绝加载并报明确错误，**绝不静默降级或尝试兼容**。1.x 的 `resolveDriver` 遇未知协议静默 fallback 到 openaiChat，把配置错误推迟到上游才炸（E-06），此类行为在 2.0 属禁止项。

### 3.3 函数表形状

`LingXiPluginAPI` 至少含：`describe`（返回身份与声明）、`start`（接受授予的权限集）、`stop`、`dispose`、`invoke`（按能力种类分派：provider 请求、tool 调用、service 调用、hook 执行）、`cancel`、`capabilitiesChanged`（插件主动增量声明/撤回时经 `hostAPI` 上报）。

具体结构体字段在阶段 2 实现时定稿并冻结为 `ABI-MANIFEST`，同时钉 SHA-256——沿用 1.x `Vendor/OpenTUI/0.5.10/ABI-MANIFEST.txt` 的那份做法，它写清了"ad-hoc 签名、未公证、不得发布分发、加载被阻时不得绕过 macOS 安全控制"，这个立场 2.0 继续持有。

### 3.4 Provider 模型元数据

Provider 插件的 `describe` 返回 `ProviderIdentity` JSON。`models` 是路由键的权威列表；可选字段
`modelDetails` 为每个模型补充展示元数据：

```json
{
  "id": "provider.mimo",
  "models": ["mimo-v2.6-flash"],
  "modelDetails": [{
    "id": "mimo-v2.6-flash",
    "thinkingLevels": [{"id": "low", "label": "低"}, {"id": "high", "label": "高"}],
    "defaultThinkingLevel": "low"
  }]
}
```

- `modelDetails` 出现时必须与 `models` 的 id 顺序完全一致；不一致在握手阶段拒绝，不静默修补。
- `thinkingLevels` 按推理强度从低到高排列，`id` 稳定、`label` 仅用于显示；`defaultThinkingLevel`
  必须属于该集合。
- 加载器负责校验，Core 只透传运行中 Provider 的声明，前端负责显示。本版思考等级**只读**，
  不进入 `ProviderWireRequest`；插件不应把它当作已生效的请求参数。

### 3.5 自绘设置能力 `settings.view.v1`

插件可以在 `PluginIdentity` 中声明可选设置能力：

```json
{"settings": {"capability": "settings.view.v1"}}
```

manifest 的 `Capabilities` 必须包含同一字符串。声明后，`invoke` 的 `settings.view.v1` 接收
`SettingsInvocation`（`open`/`input`/`resize`/`prepareSave`/`commit`/`apply`/`cancel`），返回
`SettingsResponse`。`open` 会收到 `viewport`、**不含密钥**的凭据状态和已提交配置；插件自己保存草稿。
`prepareSave` 返回候选配置，由 Core 校验并原子写入 `<data>/plugin-settings/<bundleID>.json`。

插件只能返回受约束的 `SettingsFrame`：行、span、主题 token 或 `#RRGGBB`；禁止控制字符与 ANSI。
宿主拥有外框、标题、Esc/Ctrl-S 和物理终端，插件不能拦截关闭。设置会话使用独立 Host，不注册路由、
Hook 或 Tool；禁用插件也可以打开设置页。完整的 frame 限制与事务语义见 ADR-0006。

## 四、握手与能力注册：定义一次

阶段 0 初稿要求"统一握手与能力注册流程"，原因是 1.x 存在**五套互不一致**的实现：插件 IPC 用 `ipcVersion: Int` + 裸字符串错误、Core 侧 manifest 用 `compatibility.schemaVersion` + 版本字符串区间、browser-host 用真 JSON-RPC + `protocolVersion: "v1"`、MCP 用 `initialize → notifications/initialized → tools/list`、前端 wire 用 `protocolVersion = "2.0"` 字符串。字段名、类型、顺序、失败表达各不相同。

2.0 只有一条序列：

```
1  Core → Host   : 拉起 Host，指定插件包路径
2  Host          : dlopen → 签名与策略校验 → dlsym(EntryPoint) → ABI 主版本协商 → 取回函数表
3  Host → Core   : initialize.result { bundleId, version, teamId, abiMajor, capabilities[], permissions[], depends[], conflicts[] }
4  Core          : registry 检查（enabled / 依赖 / 冲突）→ 权限策略判定 → 计算本次授予集
5  Core → Host   : capability.activate(granted) → Host 转调插件 start(granted)
6  运行期        : 请求-响应带 id；通知无 id；事件流按 streamId 多路；插件可发 capabilities.changed 增量声明或撤回
7  Core → Host   : capability.deactivate → 插件 stop → 排空在途 → dispose → dlclose → Host 退出
```

规则：

- **第 5 步之前，插件的任何能力都不可被调用**；任何在第 5 步前抵达的请求判为协议违规。握手只交换身份与声明，不产生生效能力。
- 版本语义只有一个：`abiMajor` 整数。`MinimumCoreVersion` 与一切版本字符串仅用于给人看的提示，不参与任何判定。
- 错误表达统一为 `code`（封闭枚举）+ `domain` + `message`，不再有裸字符串错误。
- 前向兼容：未知枚举值降级为 `unknown` 而不抛异常；未知可选字段忽略；未知必选方法报 `methodNotImplemented` 并计入协议违规（IPC-011）。
- 握手失败必须**命名到底哪一步失败**（签名不符 / ABI 主版本不符 / 缺符号 / 权限被拒 / 依赖缺失），不得只报裸 transport 错误（IPC-009）。

## 五、生命周期状态机与撤销

```
uninstalled → installed → enabling → running(ready)
                                   ↘ degraded(部分能力被拒授予)
                                   ↘ failed(熔断打开)
      running → disabling → disabled → uninstalled
```

- **registry 是唯一真相源**（PLG-001、E-12）。目录扫描只用于发现未注册包，不决定是否拉起。1.x 三处各管一半，结果是禁用后命令残留、进程照拉起。
- `failed`（内核因故障判定、可恢复）与 `disabled`（用户判定）严格区分。
- `degraded` 是新状态：声明的能力中有一部分未被授予权限时进入，且必须在 TUI 可见——这是权限强制执行与声明分离后的必然产物（第 8 章）。
- 禁用序列固定八步，一步失败也要继续走完并记录：标记 disabling → 摘路由表（provider/tool/service/hook 四张）→ 等在途收敛（超时按取消处理）→ 租约置 `revoked` → 关事件流与 Hook 挂载 → `stop/dispose/dlclose` → 杀 Host 进程树并回收其派生子进程 → 通知前端 unregister → 落盘 `disabled`。
- 撤销用租约模型，状态 `armed / used / expired / revoked`（1.x MCP 侧唯一做对的样板，PLG-003）。
- 判定"禁用零残留"的可执行标准：模型请求的工具清单不含该工具、调用它返回未注册错误、`ps` 无残留进程、前端命令面板无残留项。对应项目书 §七第 3 条后半句。

## 六、故障分类与隔离

"慢"与"死"必须可区分（IPC-004、PLG-004）：

| 分类 | 判定 | 恢复动作 |
|---|---|---|
| `unresponsive` | Host 空闲沉默超阈值但进程存活 | 发取消 → 仍沉默则升级为 `crashed` |
| `crashed` | Host 进程异常退出（含插件在其中段错误），携带退出码/信号/stderr 尾部 | 结构化上报 + 熔断计数 |
| `abiViolation` | ABI 主版本不符、缺符号、结构体尺寸异常、非法返回布局 | 拒绝加载，不重试 |
| `protocolViolation` | 帧超限、非法 JSON、未知方法、第 5 步前调用 | 立即隔离并标 `failed`，不重启 |
| `capabilityFailed` | 单次能力调用的业务失败 | 原样回传给该 Run，Turn 按内核规则终止 |
| `timeout` | 超出该能力声明的 per-method 超时 | 取消 + 记故障 |
| `permissionViolation` | 越出授予集的实际访问 | 终止 Host + 标 `failed` + 前端告警 |

- 崩溃检测必须靠 `terminationHandler`，不是"下次调用时看 `isRunning`"。
- 熔断 + 指数退避重启；连续故障超阈值标 `failed` 并撤销路由；**禁止静默永久失能**（PLG-005，1.x 一次超时即判死全 host）。
- 单插件故障不得波及 Core、前端或其他插件；受影响的那个 Run 收到明确错误并走内核恢复矩阵（`Kernel-Design.md` 第六章）。
- 崩溃发生在工具批次中间 → 只读项可重跑，可变项记 `executionStateUnknown`，**副作用不重复**。
- L2 契约层必须有针对真实 Host + 故障插件的六种异常注入：段错误退出、挂死沉默、非法帧、无应答、越权访问、读到宿主凭据。1.x 有 643 行 `FaultInjectingTransport` 可作蓝本，但那是 transport 级；2.0 需要**进程级**故障注入（用一个会自杀的测试插件 dylib）。

## 七、Hook 与生命周期扩展点

1.x 的 hook 是完整死路（E-09）：类型、SDK 注册、握手协商全都在，但 `broadcastHook` 在生产代码零调用点（连测试都没调），`ExtensionPlatform.emit` 只在测试里被调用，且 handler 无返回值、只回收诊断结构——即便接线也只能监听。

2.0 的约束：

1. 每个 Hook 点必须**类型化返回且能改变执行**：注入内容、改写允许字段、否决并给原因、要求人工确认。只有诊断返回值的 Hook 不算扩展点。
2. 首发节点五个，宁少勿多：`onContextPrepare`、`beforeModelRequest`、`afterModelEvent`、`beforeToolExecute`、`afterToolExecute`。
3. **失败策略按类别固定，不由挂载方自由选择**（Phase 0.1 决策：安全授权不得因 Hook 故障默认放行）：

| 类别 | 涵盖 | 故障时行为 |
|---|---|---|
> **阶段 2 落地范围（ADR-0002）**：本表第三列的「并要求人工确认」尚未实现——待答交互的数据模型未在设档定义，`interrupted` 仍是状态占位。阶段 2 先落地**故障即判拒绝**（拒绝本身不依赖交互层），人工确认与续跑随交互模型那一条线一起补，不在此伪造。下表原文保持不变，作为该类的完整目标形态。

| `security` | 权限批准/否决、危险操作确认、凭据访问授权 | **一律 fail-closed**：超时、崩溃、非法返回一律判**拒绝**并要求人工确认。不提供任何覆盖开关 |
| `transform` | 改写参数、追加上下文 | 默认 fail-open：跳过该 Hook、保留原值，并记录成前端可见的诊断 |
| `observe` | 纯监听 | fire-and-forget，永不阻塞、永不影响执行 |

   一个 Hook 的类别由**内核**判定（依据它挂载的节点与返回类型），不由插件声明决定——插件不能把自己伪装成 `observe` 来逃避 fail-closed，也不能把 `transform` 升格为 `security` 去获得否决权。
4. `afterModelEvent` 不得吞掉终态事件；任何 Hook 都不得参与 Run 的终止判定（内核终止权威只来自硬边界，`Kernel-Design.md` D2）。
5. Hook 注入的文本一律走非特权数据通道，进不了指令位置（CTX-001）。
6. 顺序与优先级显式声明，同优先级按 bundle id 稳定排序；禁止依赖注册先后这种不可复现顺序。
7. L0 孤儿类型门禁必须同时守住 hook 相关类型——这条是防止 2.0 重演"类型全在、无人调用"的唯一有效手段（QA-006、PLG-006）。

## 八、权限：声明、强制执行、OS 沙箱是三件事

Phase 0.1 决策第 3、4 条要求把这三层彻底分开写清楚。

**第 1 层 — 声明**：`Info.plist` 的 `Permissions`（网络目的地、文件范围、凭据引用、子进程、UI 通知）。这一层**没有任何强制力**，只是给用户看和给第 2 层做输入。

**第 2 层 — 强制执行（唯一的真实边界）**：内核在每个调用点判定——工具能力网关、凭据发放、模型请求的网络出口、文件与命令执行范围、Hook 授予集。越界即 `permissionViolation`。实现要点：

- 凭据由内核保管。Provider 插件不持有 key 本体；需要时以内核授予的受限引用取用，取用行为被记录并与声明比对。1.x 的 `EnvironmentSanitizer` + 严格 allow-list + sentinel 探针（PLG-008）继续有效。
- Host 进程环境是严格 allow-list；**MCP 一类的外部进程不得豁免**（E-07 的教训就是"这次先不动"留下泄漏点）。
- `degraded` 状态与"部分声明被拒"必须在前端可见；用户能看到自己实际授予了什么。

**第 3 层 — OS 沙箱：当前没有，不宣称有**（Phase 0.1 决策第 4 条）。诚实记录两条约束：

1. 插件在 Host 内运行，与 Host 同地址空间；权限判定是语言层/逻辑层的，不是内核级强制。
2. 要让社区插件（不同 Team ID）被加载，Host 必须带 `com.apple.security.cs.disable-library-validation`；按 Apple 的定义，该 entitlement 表示"App 加载任意插件或框架，而不要求代码签名"。也就是说，**开启社区插件支持本身就会关掉一层 macOS 安全检查**，此后唯一防线是第 2 层加上我们自行做的签名校验。

因此签名策略分两档，且这是用户可见的选择而不是内部实现细节：

| 档位 | 内容 | 默认 |
|---|---|---|
| `restricted` | Host 保持 library validation 开启，只加载与 Host 同 Team ID 签名的插件 → 仅官方插件可用 | **首发默认** |
| `permissive` | Host 使用带 `disable-library-validation` 的构建/配置，允许第三方签名插件；启用是用户的显式动作，前端必须告警 | 需用户主动开启 |

两档都必须由 Host 自行校验：`codesign --verify --strict` 通过、Team ID 落入策略、拒绝 ad-hoc 签名进入发布通道（开发模式可加载未发布插件，但必须显示为不受信）。参照 1.x 已有的明确立场：`codesign --verify --deep --strict` 通过 **不等于** Developer ID 或公证（`Docs/browser check/` 两份 PoC 记录），且"加载被阻时不得绕过 macOS 安全控制"（`Vendor/OpenTUI/0.5.10/ABI-MANIFEST.txt`）。

未来若真要把 macOS 沙箱接到 Host 上，单独开 ADR，届时才允许出现"沙箱"字样。

## 九、Core ↔ Host 协议（D-P2 的职责重定位）

阶段 0 初稿把 JSON-RPC over stdio 定为**插件作者契约**，这是本次修订的主要偏差。新定位：

> **JSON-RPC/IPC 是 Core 与 Plugin Host 之间的内部实现协议，插件作者不需要知道它存在。**

保留的技术决定（都仍成立）：换行分隔 JSON、单管双工、请求-响应按 id 路由与无 id 通知共存、事件按 `streamId` 多路复用（禁止再开第二条管）、帧上限 32MB、silence-bound deadline、心跳只刷空闲看门狗不外传、专用读取线程不占协作线程池、stderr 有界排空 256KB、关父端写柄使 EOF 成立且只在进程真退出后判 EOF、进程树级联回收、看门狗 `deinit` 必须 resume 全部挂起请求。

理由：作者契约若要求实现 IPC，等于把 E-08 那类坑（串行同步无法后补流式、pump 写法、EOF 判定、背压）转嫁给每一位社区作者，与"最简内核 + 插件加载器"的初衷相反。改由官方维护一个通用 Host 后，这些坑只需在一处修好。

代价与承诺：Host 成为需要长期维护的官方组件，其 ABI 头文件与 manifest schema 是公开契约，变更要提 ABI 主版本；内部 IPC 协议不对外承诺兼容，随 Core/Host 同版本发布，但仍需版本字段以给出可读的错配诊断。

## 十、发现、安装、更新

- 安装：验包结构 → 验签名与 Team ID 策略 → 解析并校验 manifest（无默认值兜底）→ 依赖与冲突检测（同 `id` 不同版本、同一 provider id 重复注册）→ 写入 registry（`installed`，未启用）→ 首次启用时才展示权限确认。
- 更新：新版 Host 实例在旧实例走完禁用序列后才拉起；不允许同一 `id` 两个版本同时持有路由。
- 卸载：先禁用序列，再删包与 registry 条目；插件产生的数据归内核存储域，不随卸载自动清除。
- 启停、版本、作者（Team ID）、权限授予、故障状态必须在 TUI 可见可管理；协议面阶段 2 就绪，不等阶段 4。

## 十一、官方插件质量标准

官方与社区同契约，所以这份清单同时是官方插件的发布门禁：

1. manifest 完整、无默认值兜底、声明与实际行为可比对。
2. 只导出约定的 ABI 符号，不泄漏 Swift 类型到边界；只用系统 Swift 运行时。
3. 六类异常路径自测通过（第 6 章）。
4. 禁用后零残留（第 5 章四条判定）。
5. 不参与终止判定、不写指令通道、不伪造终态、`security` 类 Hook 不试图逃避 fail-closed。
6. 带 README（安装、权限说明、故障排查）与 LICENSE。
7. 破坏性变更提 ABI 主版本或改 `id`。

## 十二、决策与待决

| ID | 决定 | 理由 | 可逆性 |
|---|---|---|---|
| D-P1 | 每插件一个 Host 进程实例 | 撤销与故障归因可证；避免多实例路由与租约爆炸 | 中 |
| D-P2（**已修订**） | JSON-RPC over stdio 降级为 **Core↔Host 内部协议**；插件作者契约改为固定 C ABI + 单一导出符号 | 决策第 3、4 条；把 pump/EOF/背压/串行陷阱集中到官方一处（E-08） | 低（作者可见契约） |
| D-P3 | 官方插件用 Swift，经 `@_cdecl` 导出 C ABI；社区插件语言不限，只要满足 C ABI | 同工具链零额外运行时；C ABI 是跨语言唯一稳定选择 | 中 |
| D-P4 | 凭据由内核保管，插件取受限引用 | 消除 sidecar/插件继承全部 key 的泄漏面 | 中 |
| D-P5 | `.lxap` 用 macOS 原生 bundle + 标准代码签名，不自造签名体系 | 决策第 1 条；签名即作者身份，Team ID 可作策略输入 | 低 |
| D-P6 | 首发默认 `restricted`（同 Team ID 才加载），第三方插件需用户显式开启 `permissive` | 不隐瞒"开启社区插件会关掉一层 macOS 安全检查"这一事实 | 中 |
| D-P7 | `security` 类 Hook 强制 fail-closed，类别由内核判定 | 决策第 4 条：安全授权不得因 Hook 故障默认放行 | 高 |
| ~~Q-P1~~ | 已解决：标准 macOS 签名（`codesign` + Team ID 策略），开发模式例外且显示为不受信 | — | — |
| Q-P2 | 插件是否需要公证（notarization）作为 `permissive` 档的额外门槛 | 影响第三方作者门槛，需在阶段 2 结束前定 | — |
| Q-P4 | 单个通用 Host 承载多种语言插件时的内存上界与回收策略 | 长任务不泄漏是项目书 §七"可长期使用"的一部分 | — |
| Q-P5 | `service` 注册面在阶段 2 是否真有首批消费者 | 无消费者的通道一律不建（QA-006） | — |
