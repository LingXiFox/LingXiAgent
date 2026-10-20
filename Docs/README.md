# LingXiAgent 2.0 技术文档

LingXiAgent 2.0 是一个本地优先的 Agent 运行时：一个不含任何 Provider、工具或 UI 实现的最小内核，
全部能力以原生动态插件的形式接入。本文档集规定**边界、契约与判定口径**，不规定具体写法；实现细节以
代码和测试为准，冲突时先确认是代码错了还是文档过期。

产品目标与完成标准以《LingXiAgent 2.0 项目书》为准，本文档集只引用其章节号。

## 1. 架构

```
TUI / 前端进程 ──前端协议──> Core 进程 ──内部 IPC──> Plugin Host 进程 ×N ──C ABI──> .lxap 动态库
                               │
                               ├─ 内核（Agent Loop、上下文、预算、Run 状态、事件日志）
                               └─ 插件监管（注册表、进程生命周期、能力路由、Hook 桥）
```

- **内核不做 I/O**：模型请求、工具执行、上下文注入全部经由端口由插件提供。没有 Provider 插件时，
  内核可以启动、展示状态、给出配置引导，但**结构上不能推理**。这不是开关，是依赖方向决定的。
- **每插件一个 Plugin Host 进程**。Host 是官方发布的通用可执行文件，只做 `dlopen`、签名与 manifest
  校验、ABI 协商、IPC↔ABI 翻译；它不含任何插件代码，官方插件也没有特权通道。
- **插件作者不实现 IPC**。插件与 Host 之间是固定 C ABI；Core 与 Host 之间是内部 JSON 行协议，
  随 Core/Host 同版本发布，不对外承诺兼容。
- **能力注册是唯一入口**。内核看到的是 bundle id 命名空间下的能力标识，看不到厂商、进程形态或 ABI 细节。

## 2. 模块

| Target | 路径 | 职责 | 许可 |
|---|---|---|---|
| `LingXiKernel` | `Sources/LingXiKernel` | Agent Loop、单上下文装配与校验、预算与压缩、Run 终态化、事件日志与恢复、端口与 Hook 接缝 | LCSAL-1.1 |
| `LingXiPluginABIC` | `Sources/LingXiPluginABIC` | 插件 ABI 的 C 头文件与 `ABI-MANIFEST.txt`（契约结构体必须来自 C，见 §5） | MIT |
| `LingXiPluginABI` | `Sources/LingXiPluginABI` | Core↔Host 线协议、Hook 载荷、签名策略枚举 | MIT |
| `LingXiPluginHost` | `Sources/LingXiPluginHost` | 通用 Host 进程：验包、签名/Team 策略、manifest、`dlopen`、调用分发、取消 | LCSAL-1.1 |
| `LingXiPluginRuntime` | `Sources/LingXiPluginRuntime` | Core 侧监管：注册表、会话、进程与 IPC 客户端、Hook 桥、启停编排 | LCSAL-1.1 |
| `LingXiCredentialStore` | `Sources/LingXiCredentialStore` | 凭据托管：解析规则（默认 Keychain；环境变量仅在显式选择时使用）与唯一的 macOS Keychain 实现；只链接进 Core，TUI 与 Host 都读不到已存密钥 | LCSAL-1.1 |
| `LingXiCoreHost` | `Sources/LingXiCoreHost` | 正式 Core 进程：恢复内核状态与插件，把 HookPipeline 接到真实 AgentLoop | LCSAL-1.1 |
| `LingXiContextProbe` | `Plugins/LingXiContextProbe` | 官方示例插件（Swift）：一个 `contextPrepare` Hook | PolyForm Noncommercial 1.0.0 |
| `LingXiFrontendProtocol` | `Sources/LingXiFrontendProtocol` | Core↔TUI 的请求/回复/事件契约 | PolyForm Noncommercial 1.0.0 |
| `LingXiTUI` | `Sources/LingXiTUI` | 终端前端：流式聊天、会话、插件管理；不加载插件 | PolyForm Noncommercial 1.0.0 |
| `LingXiCProbe` | `Plugins/LingXiCProbe` | 同一能力的 C 实现，用于证明 ABI 跨语言 | PolyForm Noncommercial 1.0.0 |
| `DeepSeekProvider` | `Plugins/DeepSeekProvider` | 首个真实 Provider：DeepSeek Responses API + SSE 流式，Cassette 回放 | PolyForm Noncommercial 1.0.0 |
| `MiMoProvider` | `Plugins/MiMoProvider` | 第二个 Provider，故意不同 wire family：MiMo Chat Completions | PolyForm Noncommercial 1.0.0 |
| `LingXiKernelTests` | `Tests/LingXiKernelTests` | L0 结构门禁 + L1 内核回归 | 不发布 |
| `LingXiCredentialStoreTests` | `Tests/LingXiCredentialStoreTests` | 凭据解析规则（内存后端）+ 真实 Keychain 往返（`LINGXI_RUN_KEYCHAIN_TESTS=1` 门禁） | 不发布 |
| `ContractTests` | `ContractTests` | L2 契约：真 `.lxap`、真签名、真 Host 进程、故障注入 | 不发布 |

依赖方向由 L0 门禁解析 `Package.swift` 强制执行：内核不得依赖任何其他 target、只 import `Foundation`，
且源码中不得出现 `dlopen`/`dlsym`/`@_cdecl`/`LingXiPlugin_Init` 或任何厂商名。装载代码只能存在于 Host 一侧。

## 3. 运行时模型

- **Session → Turn → Run → Step**。一次用户提交是一个 Turn；Turn 内「模型请求 → 工具批次 → 结果回传」
  的一次交替是 Step；一次执行实例是 Run。
- **同 Session 同时只允许一个 active Run**；第二个 Run 在产生任何副作用前被拒（`concurrentRunRejected`）。
- **标识唯一性**：`runID` 全局唯一；`turnID` 在 Session 内唯一（重复的 `turn-<turnID>` 条目 id 会让引用
  产生歧义，因此在任何持久化写入前拒绝）；`executionID` 每 Run 一个，跨 Step 共用。
- **终态化**：终态事件先落盘再改内存；写失败回滚并保持非终态；同一 Run 只有一个赢家。终态原因与状态
  绑定写入，正常完成、输出截断、内容过滤、拒绝、取消、超时、预算耗尽各自有独立原因码。
- **取消与超时**：取消是意图声明，不伪造失败；`stream()` 与流消费整体与取消/总超时竞争，迟到事件丢弃；
  取消/超时后调用 `endExecution` 释放 provider 执行态，每 Run 恰好一次。
- **恢复**：`KernelRecovery` 是唯一入口，只读重放事件、重建全新内存对象，绝不重放工具或模型请求。
  `batchStarted` 未 `batchSettled` 的批次记 `executionStateUnknown` 并要求后续验证。
- **上下文**：单一上下文，按 token 预算淘汰，mandatory 集合（指令、当前用户输入、未消费批次）不可淘汰；
  淘汰留稳定引用行；最终请求在发送前重新通过协议校验。只有 `immutableInstructions` 能进入指令位置，
  其余内容（检索、Hook 注入、引用行）一律是数据。

## 4. 插件系统

### 4.1 包格式

`.lxap` 是 macOS 原生 bundle：

```
Plugin.lxap/Contents/
├── Info.plist                    身份、版本、入口、能力、权限
├── MacOS/<CFBundleExecutable>    导出 C ABI 的动态库（单一 arm64 切片）
└── _CodeSignature/               标准 codesign 产物
```

`Info.plist` 顶层的 `LingXiPlugin` 字典包含 `ABIMajor`、`EntryPoint`、`Capabilities`、`Permissions`，
可选 `MinimumCoreVersion`（仅人类提示，不参与判定）。**能力与权限必须显式声明，缺字段即加载失败**。
作者身份由签名 Team Identifier 决定，不由 manifest 自称。

### 4.2 ABI v1

插件只导出 `LingXiPlugin_Init`：

```c
int32_t LingXiPlugin_Init(const LingXiHostAPI* hostAPI, uint32_t hostABIMajor,
                          const LingXiPluginAPI** outAPI, uint32_t* outABIMajor,
                          LingXiStatus* outStatus);
```

- 所有调用返回 `int32_t`，原因经 `LingXiStatus` 出参；状态只有三个整数，无指针。
- 跨边界结构体以 `structSize`、`abiMajor` 开头；新字段只追加。
- 字符串是 `(const uint8_t*, uint32_t)`，不假定 NUL 结尾；返回缓冲由被调方分配、调用方经函数表的
  `free` 释放。
- 生命周期固定为 `Init → Start → 运行 → Stop → Dispose`；`dlclose` 只在无在途调用时执行。
- 主版本不匹配是具名硬失败，不存在兼容回退。
- 布局与头文件哈希冻结在 `Sources/LingXiPluginABIC/ABI-MANIFEST.txt`（当前 revision 2）。

### 4.3 握手与能力

`load → 签名与 manifest 校验 → dlopen → Init 协商 → describe → start(grants)`。第 5 步之前，
插件的能力不可被调用。Host 校验 bundle id 与插件自述一致、manifest 能力集与 `describe` 一致。
Core 侧的注册表（`plugins.json`，独立于会话事件日志）是「是否启用」的唯一真相源；目录扫描不决定运行。

### 4.4 Hook

内核只在真实调用点挂 Hook：`contextPrepare`（装配后）与 `beforeModelRequest`（预算与复校验后）。
裁决类型为 `keep / rewrite / veto / failed`。**故障策略由内核按能力判定**：持有否决能力者为 security 类，
故障一律判拒绝；其余 fail-open，跳过原因写入 Run detail。挂载顺序按 priority、再按 handler id 稳定排序；
撤销后不再参与后续 Run。注入内容走非特权数据通道，并重新通过请求协议校验。

### 4.5 生命周期、隔离与故障

- 禁用顺序：先摘路由 → 再停进程（stop → 等待退出 → 必要时 SIGKILL）→ 最后写注册表。
- 卸载：禁用序列后删除注册表条目；插件产生的数据不随卸载自动清除。
- 崩溃检测依赖 `terminationHandler`，携带退出码/信号/stderr 尾部；崩溃只影响该 Host 进程，
  受影响的 Run 收到具名失败，其他插件与 Core 继续运行。
- Host 环境是严格 allow-list（`PATH/HOME/TMPDIR/LANG`），API key 等凭据不会跨进程。
- IPC：单管双向、按 id 路由、通知无 id、帧上限 32MB、stderr 环 256KB、通知队列有界 256、
  调用按插件串行但读循环独立，因此 `cancel` 能在调用进行中生效。

### 4.6 签名档位

| 档位 | 行为 |
|---|---|
| `restricted`（默认） | 要求与 Host 同 Team ID；ad-hoc 与非本 Team 一律拒绝 |
| `development` | 显式开启（`LINGXI_PLUGIN_POLICY=development`），允许 ad-hoc，启动输出标注不受信 |
| `permissive` | 允许第三方签名；Host 已实现档位判定，端到端验收与公证策略未完成 |

`codesign --verify --strict` 通过不等于 Developer ID 或公证；本项目不宣称 OS 沙箱。

## 5. 存储与一致性

- 会话与 Run 的**唯一真相源是追加式事件日志**（`events.jsonl`）：尾部单行损坏截断修复并计数，
  非尾部损坏拒绝打开；append 失败进入 `repairRequired`，回滚失败则日志不可用（fail-closed）。
- 插件启停是**配置**，存于独立的 `plugins.json`（原子写），不进入会话日志。
- 结论（D3）：在阶段 1–2 的验证范围内保留事件日志，不引入数据库。若后续出现事件日志无法满足的
  事务性需求，以 ADR 记录后再评估。

## 6. 构建、运行与测试

```bash
swift build --build-tests        # 零告警
swift test                       # 139 tests：104 内核 + 35 契约

# 空核启动：无 Provider 时启动、报状态、给出引导，不写事件日志
DATA_DIR="$(mktemp -d)"
LINGXI_DATA_DIR="$DATA_DIR" .build/debug/LingXiCoreHost
test ! -s "$DATA_DIR/events.jsonl"
```

环境变量：

| 变量 | 作用 |
|---|---|
| `LINGXI_DATA_DIR` | 数据目录（`events.jsonl`、`plugins.json`） |
| `LINGXI_PLUGIN_POLICY` | 仅 `development` 表示显式开发模式；其他值一律按 `restricted` |
| `LINGXI_PLUGIN_HOST` | 覆盖 Plugin Host 可执行文件路径（打包布局使用） |

安装一个插件：把 `.lxap` 放到任意路径，在 `<data>/plugins.json` 写入
`{"plugins":[{"bundleID":"…","version":"…","bundlePath":"…","enabled":true}]}`，下次 Core 启动时恢复。
Core 退出只停进程，不改注册表；用户禁用才写 `enabled=false`。

CI：`.github/workflows/ci.yml`，`macos-26` 单 job，执行构建、测试与空核启动检查；push `rewrite/2.0`、
PR→`main`、`workflow_dispatch` 触发。最近一次 CI 覆盖 Provider 离线用例；live 用例按设计跳过。

## 7. Provider 插件

Provider 是一种插件能力（`provider.<id>`），与 Hook 共用同一套 Host、ABI 与生命周期。目前有两个独立实现：DeepSeek（Responses API）与 MiMo（Chat Completions），两者不共享兼容层，只共享 ABI/Host/Runtime。

- capability `provider.deepseek`，模型 `deepseek-flash`，`POST https://api.deepseek.com/responses`。
- 插件把 SSE 事件归一化为文本增量、推理增量、工具调用增量/完成、usage、终态与失败；
  Runtime 再映射为内核的 `ModelEvent`，因此内核不认识任何厂商事件名。
- 凭据由 Core 按次从 macOS Keychain 获取并注入 invoke 载荷；`<data>/credentials.json` 仅保存能力 id → 环境变量名，
  只有显式选择环境源才使用该映射；TUI 通过 `/auth <provider>` 的专用隐藏输入设置，不返回保存的值。
  Host 进程环境仍是 allow-list，密钥不落日志、不进 cassette。
- 离线回归用脱敏 cassette（`vcr=<path>` 授权），真实 API 冒烟与录制由 `Scripts/deepseek-*.sh` 提供，
  CI 不依赖付费密钥。

## 8. 当前实现状态

已实现并验收（证据见 `Validation/`）：

- **内核**（阶段 1–1.2）：Loop、上下文与预算、终态分类、事件日志与恢复、取消/超时、Hook 接缝；
  104 个内核测试，含 L0 结构门禁与两组独立验收套件。
- **插件闭环**（阶段 2–2.1）：C ABI v1、通用 Host、注册表与监管、Hook 桥、真 `.lxap` 端到端、
  启停/重启用/卸载零残留、崩溃隔离、默认受限策略、环境隔离、Mach-O 运行时检查、在途取消与超时清理；
  16 个契约测试。
- **两个示例插件**（Swift / C）证明同一 ABI、同一 Core、无需改内核。
- **TUI**：居中首页、多行输入、安全粘贴、聊天历史召回、折叠思考、模型/会话/插件选择器与 Keychain 认证；
  真实 PTY 覆盖连续会话、草稿、隐藏输入与干净退出。快捷键及协议见 `Frontend-Protocol.md`，一键打包 `Scripts/tui-setup.sh`。
- **两个真实 Provider**：DeepSeek（Responses API）与 MiMo（Chat Completions），各自独立插件、不同 wire family，共用同一 ABI/宿主；均覆盖真流式、工具循环、usage、在途取消与脱敏 cassette。模型路由按插件归属，启停/崩溃只影响所属插件（ADR-0004）。MiMo 已完成真实 API 录制（`mimo-chat-live.json`，离线按 digest 重放）；DeepSeek 等候真实录制。详见 `Validation/Provider-DeepSeek.md`、`Validation/Provider-MiMo.md`。

尚未实现（技术待办，按建议顺序）：

1. **Provider 插件适配器与流式事件传输**：Host 已有有界通知通道，但 `ModelProvider.stream` 的适配
   （一次调用 + 多帧事件、背压）随第一个真实 Provider 插件一起实现。这是进入 Provider 阶段的硬前置。
2. 能力租约状态机（`armed/used/expired/revoked`）与熔断/退避。
3. `permissive` 档的端到端验收与公证策略（档位判定已在 Host 实现）。
4. `security` 类 Hook 的「要求人工确认」——依赖尚未定义的待答交互模型，当前只做故障即拒绝。
5. 插件工具能力接入、Swift 运行时唯一性的运行期检测。
6. TUI 与插件市场。

## 9. 文档集

| 文件 | 内容 |
|---|---|
| `Project-Conventions.md` | 目录与命名、依赖审批、Core 不膨胀评审、提交与许可登记、安全红线 |
| `Kernel-Design.md` | 最小内核：职责白名单、Run/Step 状态机、批次语义、恢复、取消、上下文、预算、缓存 |
| `Plugin-System-Design.md` | `.lxap`、C ABI、Host、握手与能力注册、生命周期、故障分类、Hook、权限 |
| `Frontend-Protocol.md` | Core↔TUI 的行式 JSON 协议：聊天流、会话、取消、插件管理 |
| `Provider-Plugin-Contract.md` | Provider 契约：wire family、事件流终态、错误分类、用量与缓存 |
| `Testing-and-Acceptance.md` | 测试分层（L0–L4）与完成标准判定 |
| `Regression-Cases.md` | 回归台账：带 ID 的场景 → 期望行为 → 证据 → 阶段归属 |
| `Decisions/` | ADR：ABI 许可轨道、阶段范围前移、插件状态为配置 |
| `Validation/` | 各阶段验收记录：计数、逐 ID 证据、反例、CI 记录 |

阅读路径：理解设计读 `Kernel-Design.md` → `Plugin-System-Design.md`；动手实现读
`Project-Conventions.md` → 对应模块设计 → `Testing-and-Acceptance.md`；评审读
`Project-Conventions.md` 第三章与 `Regression-Cases.md` 相关条目。

## 10. 术语

- **Core / 内核**：不含 Provider、工具与 UI 的可执行运行时。
- **插件**：以 `.lxap` 交付、导出固定 C ABI 的动态库，由独立 Host 进程加载并向内核注册能力。
- **Plugin Host**：官方发布的通用宿主进程，每插件一个，插件作者无需认识它。
- **前端**：通过前端协议连接 Core 的界面进程，不链接内核实现。
- **特权通道**：只有 `immutableInstructions` 能进入模型指令位置；其余皆为数据。
- **因果批次**：一条 assistant 工具调用请求与其全部结果构成的不可拆分上下文单位。
