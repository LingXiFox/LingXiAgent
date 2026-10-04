# LingXiAgent macOS GUI ↔ Core 功能对接审计报告

> **审计执行**：LingXiFox（本狐）
> **审计时间**：2026-09-30
> **审计性质**：源码级只读审计（Read-Only Codebase Audit），未修改任何生产代码
> **源码基线**：Git commit `d21e79d`（`main`，PR #4 合并后），Apple Swift 6.4 / Xcode 27.2 / macOS 27.2 arm64
> **行文口径**：所有 `path:line` 以 `d21e79d` 为准；行号随后续提交漂移属正常，判定结论以符号名为锚
> **核心原则**：以真实源码为唯一依据；不推测、不迎合假定；不确定项一律标 UNKNOWN，不写成结论

---

## 0. 结论摘要

GUI 的**主对话链路是真的连着 Core 的**，不是自嗨原型：`RuntimeFrontend` 通过 `LingXiClientVNext.stdioCore(...)` 拉起真实 Core 子进程、订阅 `runtime.updates` 并经 `CoreProjection` 落到视图状态。但**外围能力大面积未接线**，且两处原则被破坏：前端在若干地方绕开协议直接操作本机（spawn git、改进程 cwd、自己数 diff 行数），前端整体在平台抽象层之外（`Apps/` 对 `LingXiPlatform` 零引用）。浏览器是缺口最大的一块 —— GUI 的 WKWebView 与 Agent 的 Playwright page 是两个毫无共享句柄的独立实例，Core 已交付的只读投影 `browser.sessions` / `browser.capture` 在所有前端**零调用方**。

| 维度 | 状态 | 一句话依据 |
|---|---|---|
| 功能完整度 | **部分接通** | 会话/时间线/输入/交互/终端/任务/设置已接；浏览器、附件、上下文检索、run 恢复、任务产物、凭据、presets 全未接 |
| 前后端分离 | **有实质破口** | 前端 spawn `/usr/bin/git` 执行写操作、改进程 cwd、违反 `ProtocolService.swift:571-572` 自订规则自行数 `+`/`-` |
| 跨平台分层 | **前端整体在层外** | `Apps/` 对 `LingXiPlatform` 引用数 0；6 个文件裸 `import AppKit`；`LingXiPlatform` 自身为混合体 |
| 浏览器 / Agent 同页 | **ABSENT** | sidecar 硬编码 `headless: true`，契约无 controller/paused/loading 字段，接管七项语义 1 项可表达、5 项部分、1 项缺失 |

---

## 1. 审计范围与模块边界

被审计的五层，及其名义职责与实际职责：

| 层 | 位置 | 名义职责 | 实际状态 |
|---|---|---|---|
| GUI 视图 | `Apps/macOS/FrontendKit/{Components,Settings,DesignSystem}` | 纯展示 + 意图上抛 | 混入了 VCS 执行、文件系统读写、diff 语义判定 |
| GUI 视图模型 | `Apps/macOS/FrontendKit/Frontend/RuntimeFrontend.swift` | 桥接 client 与视图 | 真桥接 + 一整条 preview 假数据分支 |
| 共享契约 | `Sources/LingXiProtocol/` | 平台中立、OS 中立的 wire 类型 | **零** `#if os(` / `#if canImport(`，教科书级干净 |
| 客户端 | `Sources/LingXiClient/VNext/Domains/` | 每域一个 client | 已暴露 118 个 wire 方法，GUI 只消费其中一部分 |
| 编排层 | `Sources/LingXiApplication/` | action 分发、投影 | 零 OS 条件；但 `Package.swift:72` 让它依赖 `LingXiPlatform`，构成对前端的传递链接 |
| 业务核心 | `Sources/LingXiCore/` | 状态权威 | 112 个 RPC 已实现；23 处 OS 分支待下沉 |
| 平台层 | `Sources/LingXiPlatform/{Protocols,Darwin,Linux,Windows,Common}` | 每平台一份兼容层 | 七类门面是真适配层；socket/HTTP/AsyncIO/PTY 是 `Common/` 内联 `#if` 的伪适配层 |

---

## 2. 主链路判定：live 还是 demo

**判定：入口是 live 的。**

- `Apps/macOS/FrontendKit/Frontend/RuntimeFrontend.swift:5-7` import `LingXiClient` / `LingXiProtocol` / `LingXiApplication`
- `:91` `LingXiClientVNext.stdioCore(...)` 起真实进程（`Sources/LingXiClient/VNext/Transport/VNextStdioTransport.swift:102-108` 真的 `Process()` 执行二进制）
- `:92` 建 `ApplicationStore(client:autoConnect:true)`
- `:133-149` 订阅 `runtime.updates`，经 `FrontendUpdateCoalescer` 约 30Hz 落 `apply(_:)`
- `Frontend/LingXiWorkbenchScene.swift:6` 构造的是 `RuntimeFrontend()`，**不是** `preview()`
- `Components/MainStageView.swift:26-30` 未连接时渲染 `WorkspaceGate`，而非假会话

**不诚实的一处**：`stopGenerating()` 在 `backend == nil` 时不看 `isPreview` 就直接本地 `finalizeStreaming()`（`RuntimeFrontend.swift:368-370`），在未连接状态下谎报流结束。其余 preview 分支都有 `guard isPreview` 前置（`:359, 380, 410, 427`），只有这一条漏了。

---

## 3. 逐面板对接矩阵

| 面板 | 功能 | 数据来源 | 证据 |
|---|---|---|---|
| `WarmWorkbench.swift` | 整体布局、工具栏、rail badge | 混合：布局与 `selectedTool` 本地；badge 读 Core diff 计数 | `:250` `inspector.live?.changes.count`；`:264` |
| `SidebarView.swift` | 工作区/会话列表、重命名、删除、切换 | **Core** | `:96,102,109,204` → `RuntimeFrontend.swift:405-469` |
| `SidebarView.swift` 搜索框 | 过滤会话 | **纯本地** `contains` 过滤，非 `context.search` | `:132-135` |
| `MainStageView.swift` | 时间线主舞台、空态、连接门 | **Core** | `:20-31,94-152` ← `CoreProjection.timeline` |
| `MainStageView.swift` StarterPrompt | 5 条快捷指令 | 本地硬编码文案（发送走真链路） | `:283-294` |
| `ComposerDock.swift` | 输入、模式、模型、思考等级、权限、YOLO、Worktree | **Core**（双向 intent） | `:413-434,444-461,168-171` ← `RuntimeFrontend.swift:250-269` |
| `ComposerDock.swift` 分支菜单 | git branch switch | **纯本地**：直接 spawn `/usr/bin/git` | `:290-305` → `WarmToolPane.swift:417-433` |
| `ComposerDock.swift` 附件 / `@` `#` 引用 | 展示与插入 | **假象**：只拼字符串 `"@/path"`；live 发送丢弃附件 | `:515-535`；`RuntimeFrontend.swift:356`；`CoreProjection.swift:78` `attachments: []` |
| `TimelineRows.swift` | context group / diff summary 折叠 | 纯本地逻辑（输入来自 Core 投影） | `:85-90,96-191` |
| `TimelineViews.swift` | 各类行渲染 | **Core**；但 `.diff` 分支 live 下永不触发 | `:51-53,494-537`；唯一生产者是 fixture `RuntimeFrontend.swift:756,760` |
| `InteractionSurfaces.swift` | 权限 / 提问 / 决策卡片 | **Core** | `:33,70-74,144` ← `RuntimeFrontend.swift:374-403` |
| `AgentStatusHUD.swift` | 状态机 + 双核上下文占用 | **Core** | `:230-279` ← `RuntimeFrontend.swift:191-232` |
| `CommandPalette.swift` | ⌘K：app 动作 + Core 注册命令 | **Core**，但仅在 openWorkspace 时取一次 | `:186-198` ← `RuntimeFrontend.swift:101-105` |
| `TraceWindowView.swift` | 轨迹表 + JSONL 导出 | **Core，但只取尾部**，未用 `trace.query` 分页 | `:36-46,131-136` ← `RuntimeFrontend.swift:187,488-491` |
| `QuickAskPanel.swift` | 侧问浮窗 | **Core**（`agent.sideQuestion`） | `:107-118` → `RuntimeFrontend.swift:640-650` |
| `NativeSearchField.swift` / `NSTextViewBridge.swift` | AppKit 控件桥 | 纯 UI，无数据 | 无 Core 引用 |
| `WarmToolPane.swift` 终端面板 | shell 会话/读写/中断 | **Core**（`terminal.*` 全套） | `:670-719` ← `RuntimeFrontend.swift:520-585` |
| `WarmToolPane.swift` Git 面板 | 状态/diff/暂存/提交/fetch/pull/push | **纯本地**：自建 git 子进程，绕开 Core；仅"让 Agent 写提交信息"走 Core | `:293-635`，尤其 `:307-350,365-374,484-489,526` |
| `WarmToolPane.swift` **浏览器面板** | 内置 WKWebView | **纯本地 demo**：从未调用 `client.browser` | `:230-291`；`:282` 自陈"尚未连接 Agent 的浏览器会话" |
| `WarmToolPane.swift` `WarmTasksPane` | 任务胶囊/目标/待办/工作流/后台任务 | **Core** | `:190-227`（`task.*` + `state.todos/workflows/backgroundTasks`）；但 plan/report 分支仅 preview 生效 `:123-130` |
| `SettingsStore.swift` | 设置数据中枢 | **Core**（17 路并发 RPC + 命令通道） | `:205-221,265-490` |
| `CoreConfigFile.swift` | 读写 `~/.lingxiagent/config.json` | 混合：文件直写 + `runtime.config.reload`；**未查 `runtime.config` 权威值** | `:5-17,119-127`；`SettingsStore.swift:115-123,298` |
| `SettingsView/Workbench/Catalog/Controls.swift` | 设置导航、搜索索引、控件 | 混合：页面结构硬编码；搜索并入 store 实体 | `SettingsView.swift:44-70`；`SettingsCatalog.swift:105-162` |
| `SettingsAppPages.swift` | 通用/外观/对话/快捷键 | 混合：Core 状态 + config.json + preferences.json + UserDefaults；**快捷键页整页硬编码** | `:182-256`；`:388-401` |
| `SettingsAgentPages.swift` | Provider/Agent 默认/权限/上下文/执行/代码智能 | **Core**（catalog、policy 快照、LSP、toolStatus）+ config.json | `:13-110,319-438,441-505,622-712` |
| `SettingsSystemPages.swift` | MCP/Skills/Plugins/Hooks/工作区/Worktree/诊断/Computer Use/关于 | **Core** | `:10-115,175-310,310-450,457-545,572-627` |
| `SettingsProviderEditing.swift` / `SettingsMCPEditing.swift` | 编辑表单 | **Core**（save/testDraft/delete 全 RPC） | `:55-390`；`:94-392` |
| `DesignSystem/*` | 视觉令牌 | 视觉层，`AppPreferences` 被 `RuntimeFrontend.swift:236` 消费 | — |

---

## 4. Mock、假数据与死代码

| 位置 | 内容 | 真实替代 |
|---|---|---|
| `RuntimeFrontend.swift:679-772` | `loadPreviewFixture()`：会话 `sess-1`、`task-init` + 3 条 SuccessCriterion + 2 artifact、`feat/gui-v1-fork`、4 条假工具调用、假权限卡 `int-101`、两段假 diff、假终端结果 | `CoreProjection.sessionFolders/timeline/task` + `interaction.list` + `workspace.diff` |
| `RuntimeFrontend.swift:756,760` | `.diff` timeline 条目在 **live 下无任何生产者** → `TimelineViews.swift:51-53,494-537` 与 `TimelineRows.swift:133-157` 的折叠渲染是死代码 | Core 需提供 per-turn 文件改动事件，或由 `workspace.diff` 切分插入时间线 |
| `RuntimeFrontend.swift:654-668` | `sendPreviewMessage` 假流式"预览模式回复…" | `.submitPrompt` |
| `RuntimeFrontend.swift:670-677` | `updatePreviewCard` 本地改卡片状态 | `.grantPermission` |
| `RuntimeFrontend.swift:427-439` | preview 的 `newSession` 造 `sess-XXXX` | `.createSession` |
| `RuntimeFrontend.swift:368-370` | **未连接时也执行** `finalizeStreaming()`，谎称流结束 | 应补 `guard isPreview` |
| `Models/PresentationModels.swift:239-240` + `Frontend/CoreProjection.swift:56-59` | live 的 `TaskPresentation.plan/report` 恒 nil | `task.report` / `task.artifacts` |
| `CoreProjection.swift:128` | `exitCode: nil` 硬编码（协议侧确无该字段） | UNKNOWN：需协议扩展 |
| `CoreProjection.swift:280` | `managedWorktreeBranchPrefix = "lingxi/"` 在 GUI 侧硬编码，真值在 `Sources/LingXiCore/App/CoreHost+Worktree.swift:14` | 应由 `WorkspaceSummary` 下发 |
| `SettingsAppPages.swift:388-401` | 快捷键表硬编码且**与实际实现矛盾** | 应源自 `LingXiMenuCommands` 单一真源 |
| `PresentationModels.swift:309-323,424` | `InspectorTab` 三枚举 + `selectedTab` —— **全仓无任何一处读取**；所谓"变更"面板并不存在，`workspace.diff` 结果只用于一个数字角标 | 要么接出该面板，要么删掉这组死类型 |

矛盾点单列：`SettingsAppPages.swift:391` 声称"审批：拒绝 esc"，而 `InteractionSurfaces.swift:8-9` 明确写「Esc is not bound: it must never resolve a request」，且拒绝按钮未绑键（`:70`）。设置页在向用户描述一个不存在的快捷键。

---

## 5. Core 已具备、GUI 未接线的能力

CoreHost 侧实现 **112 个** RPC，stdio 路由表 118 个方法名（`Sources/LingXiClient/VNext/Transport/VNextStdioCoreServer.swift:240+`）。下列为 client 已暴露、GUI 全链路零调用的能力（✗ 指 GUI 与 `LingXiApplication` 调用点均无引用）：

| 能力 | 所在 | 应消费的 GUI 面板 |
|---|---|---|
| **浏览器会话 + 截图** `browser.sessions` / `browser.capture` | `VNext/Domains/BrowserDomainClient.swift:12-21`；Core `App/CoreHost.swift:4775-4804` | `WarmToolPane.swift:253-291` 浏览器面板 |
| **内容上传/下载**（附件真通道）`content.beginUpload/uploadChunk/commitUpload/abortUpload/get/getMetadata/getRange` | `Domains/ResourceDomainClient.swift:20-109`；Core `CoreHost.swift:3948,3968` | `ComposerDock.swift:515-535` + `TimelineViews.swift:205-226` AttachmentStrip |
| **Agent 树** `agent.tree` | `Domains/RunDomainClient.swift:33` | 概览面板 subagents（`RuntimeFrontend.swift:199-206` 只拼平铺数组） |
| **Run 恢复与枚举** `run.resume` / `run.list` / `run.get` | `RunDomainClient.swift:16-31` | 无"已阻塞 Run 可恢复"入口 |
| **跨会话待处理交互** `interaction.list` | `Domains/InteractionDomainClient.swift:11` | Sidebar 角标只看当前会话（`SidebarView.swift:223-229`） |
| **上下文检索 / 按需召回** `context.search`、`context.entry` | `Domains/ContextDomainClient.swift:27-37` | 折叠组 `ContextGroupRow`（`TimelineViews.swift:459-491`）与 `@`/`#` 补全。TUI/WebUI 已在用（`Sources/LingXiTUI/ApplicationTUI.swift:303`、`Sources/LingXiWebUI/WebUIServer.swift:164`），**唯 macOS GUI 未用** |
| **上下文策略写回** `context.policy.update` | `ContextDomainClient.swift:39-45` | `SettingsAgentPages.swift:622-680` 目前只能写 config.json 并等重启 |
| **Agent Presets** `agent.presets` / `agent.runs` | `Domains/AgentPresetDomainClient.swift:11-18` | Composer 模式菜单只有 build/plan/explore（`ComposerDock.swift:413-421`） |
| **多 Run 对比** `agent.compare` | `Domains/MultiRunDomainClient.swift:11` | 无面板 |
| **权威有效配置** `runtime.config` | `Domains/RuntimeDomainClient.swift:28` | `CoreConfigFile.swift` 用本地 `fallback` 猜默认值 |
| **分页 Trace / Run Trace** `trace.query` 分页、`diagnostics.runTrace` | `Domains/DiagnosticsDomainClient.swift:27-38,61` | `TraceWindowView.swift:35-46`（只有尾部 + 本地关键字过滤） |
| **任务产物 / 报告 / 判据** `task.get`、`task.criteria`、`task.artifacts`、`task.report` | `Domains/TaskDomainClient.swift:28,60,65,71` | `WarmTasksPane` 的 plan/report 分支（`WarmToolPane.swift:123-130`） |
| **凭据视图** `credential.list/status/test` | `Domains/CredentialDomainClient.swift:11-34` | 设置页只显示"由 CredentialBroker 持有"文字（`SettingsAgentPages.swift:495-500`） |
| **扩展安装/卸载/配置/查询** `extension.install/uninstall/configure/get/getStatus` | `Domains/ExtensionDomainClient.swift:17-27,29-37,71-74` | `ExtensionsSettingsPage` 只有 enable/disable/reload |
| **切换工作区** `workspace.set` | `Domains/WorkspaceDomainClient.swift:16` | 换目录靠**杀掉重启 Core**（`RuntimeFrontend.swift:85-96`） |
| **批量终止后台任务** `terminateAllBackgroundTasks` | `RuntimeDomainClient.swift:55` | 诊断页逐个停止（`SettingsSystemPages.swift:310+`） |
| 会话/轮次枚举 `session.get`、`session.listEvents`、`turn.get`、`turn.list` | `SessionDomainClient.swift`、`TurnDomainClient` | 时间线无历史回填 |
| `provider.get`、`provider.configure`、`model.get`、`model.setSelection` | `ProviderDomainClient`、`ModelDomainClient` | Provider 编辑页 |

另有一组**算了但没人看**的投影：`RuntimeFrontend.swift:191-232` 计算的 `rootRun / lastMetrics / health / pendingInteraction / compaction / providerState / providerDetail / diffLoaded / runStartedAt / subagents`，在 `PresentationModels.swift:434-483` 定义，但在 `Components/`、`Settings/` 内检索为 0 消费。

---

## 6. 前后端分离原则的失守点

按严重度排序。前四项是**能力越权**，后三项是**职责越界**。

1. **前端直接执行 VCS 写操作。** `WarmToolPane.swift:417-433` 定义 `run(_ args:)` spawn `/usr/bin/git`；`:484-489` 执行 `add` / `restore` / `fetch` / `pull` / `push`；`ComposerDock.swift:290-305` 执行 `git switch`。这与 `Sources/LingXiApplication/Commands/ApplicationCommandRegistry.swift:275` 所记「严禁前端越权直接 spawn `/bin/sh`（Audit Round 5 Phase C）」是同一精神，而 Core 已有 `worktree.*` / `workspace.diff`。前端因此完全绕开了 Core 的权限、引用版本与取消链。
2. **前端改整个 GUI 进程的 cwd。** `RuntimeFrontend.swift:90` `FileManager.default.changeCurrentDirectoryPath(workspace.path)`，失败不恢复；随后 Core 以该 cwd 启动（`:91`）。`LingXiPlatform` 已有 `process.currentWorkingDirectory()` 抽象（`ApplicationCommandRegistry.swift:150` 在用），GUI 绕开了它。
3. **前端直接读 `.git/HEAD`。** `CoreProjection.swift:283-293`。同一文件 `:280` 还硬编码 worktree 分支前缀，真值在 Core。
4. **违反协议自订规则。** `Sources/LingXiProtocol/ProtocolService.swift:571-572` 明文写「行数统计由 Core 用 `--numstat` 算出，**前端不得再从 diff 文本里自己数 `+`/`-**」，而 GUI 三处都在数：`CoreProjection.swift:324-325`、`TimelineRows.swift:145-146`、`TimelineViews.swift:532-534`；同时完全忽略 Core 已下发的 `addedLines/deletedLines/changedFiles`（`RuntimeFrontend.swift:228` 只取 `.diff`）。已核实为真实违规。
5. **业务语义在投影层重复实现。** `CoreProjection.swift:144-150`（挑选"最小说明参数"的 key 顺序）、`:186-216`（terminalReason/errorCode 中文归类，靠 `localizedCaseInsensitiveContains("rate")` 猜字符串）、`TimelineRows.swift:85-90`（只读工具名白名单）都是业务判断。而 `Sources/LingXiProtocol/FrontendWireTypes.swift:10-95` 已有共享的 `ToolFamily.classify`，`Sources/LingXiApplication/Projection/ToolNode.swift:39-42` 在用 —— GUI 另建了一套平行分类。
6. **配置权威错位。** `CoreConfigFile.swift:5-17,119-127` 直接读写 `~/.lingxiagent/config.json` 并调用 `runtime.config.reload`，但不查 `runtime.config` 取权威值，用本地 `fallback` 猜默认值。写文件而非走配置通道，是 Core 之外的第二真源。
7. **命令目录陈旧化风险。** `availableCommands` 仅在 openWorkspace 时取一次（`RuntimeFrontend.swift:101-105`）；`ApplicationCommandRegistry.syncPluginCommands`（`:38-76`）存在但 GUI 无触发点，装/卸插件后 ⌘K 与 `/` 补全会陈旧。

**测试盲区（导致以上不被拦截）**：

- `Tests/LingXiAgentTests/LingXiAppPhase0Tests.swift:142-146` 的架构纯度检查只是字符串 `contains("import LingXiCore"/"import LingXiPlatform")`。而 `Package.swift:21-23` 让 `LingXiFrontendKit` 依赖 `LingXiApplication`，`Package.swift:72` 让 `LingXiApplication` 依赖 `LingXiPlatform` —— 前端**事实上传递链接了 `LingXiPlatform`**，字符串检查永远抓不到。已核实该链条成立。
- `ContractTests/LingXiPlatformContractTests/CoreDependencyGraphGateTests.swift` 只反向检查「Core / `LingXiApplication` 不指向 `Apps/**` 与 `LingXiFrontendKit`」，不检查前者的传递闭包，缺口无人看守。
- `ContractTests/LingXiPlatformContractTests/PlatformBoundaryArchitectureTests.swift:40-51` 的 `scannedModules` 只列 `Sources/*`，因此 `WarmToolPane.swift:5-7` 的 `import WebKit` / `import Darwin`、`SidebarView.swift:3` 的 `import AppKit` 全部合法通过 —— 规则未被违反，但规则覆盖不到 GUI。

---

## 7. 跨平台分层原则的失守点

### 7.1 前端桌面框架泄漏普查

**A-1 无文件级守卫（真泄漏，iOS 编译即死）**

| 文件 | 桌面框架/符号 | 守卫情况 | 计数 | 证据 |
|---|---|---|---|---|
| `DesignSystem/Tokens.swift` | AppKit、`NSColor`、`Color(nsColor:)` | **无** | 1+15 | `:2`(import)、`:22-23`、`:29-41`(12 处)、`:49`(动态色) |
| `DesignSystem/Components.swift` | AppKit、`NSPasteboard`、`NSImage` | **无** | 1+4 | `:2`、`:297`、`:639`、`:648`、`:652` |
| `DesignSystem/WallpaperStyle.swift` | AppKit + ImageIO + UniformTypeIdentifiers | **无** | 3+5 | `:2,3,4`、`:41`、`:52`、`:65`、`:81`(`NSOpenPanel`)、`:88`(`NSAlert`) |
| `Components/SidebarView.swift` | AppKit、`NSViewRepresentable`、`NSOpenPanel` | 仅第 1 行 `#if canImport(SwiftUI)`，AppKit 在守卫之外 | 1+5 | `:3`、`:232-240`、`:431` |
| `Components/ComposerDock.swift` | AppKit、`NSOpenPanel` | 仅 `#if canImport(SwiftUI)` | 1+1 | `:3`、`:516` |
| `Settings/SettingsControls.swift` | `Color(nsColor:)`（macOS-only SwiftUI API） | 仅 `#if canImport(SwiftUI)` | 1 | `:126` |

> 本狐前一轮只报了前三个文件，**`SidebarView` / `ComposerDock` / `SettingsControls` 是本轮新发现的漏网项**。`DesignSystem/Surfaces.swift`、`Atmosphere.swift`、`AppPreferences.swift` 只 import SwiftUI，干净。

**A-2 有守卫（做法正确，不需改）**：`NSTextViewBridge.swift:1`、`NativeSearchField.swift:1`、`WarmToolPane.swift:1`、`LingXiWorkbenchScene.swift:1`、`LingXiMacApp.swift:1` 均整文件 `#if os(macOS)`；`QuickAskPanel.swift:3,121`、`SettingsSystemPages.swift:4,399,421,447`、`TraceWindowView.swift:145`、`SettingsAppPages.swift:215,265`、`WarmWorkbench.swift:1,114` 为局部守卫。误报排除：`CoreConfigFile.swift:174` 的 `NSNull`、`RuntimeFrontend.swift:56` 的 `NSObjectProtocol` 属 Foundation，跨平台可用。

### 7.2 内联平台条件分布

| 目录 | `#if os(` | `#if canImport(` | `#elseif os(` | `#available(` |
|---|---|---|---|---|
| `Apps/macOS/` | 16 | 21 | 0 | 1 |
| `Apps/iOS/` | 1 | 0 | 0 | 0 |
| `Sources/LingXiClient/` | 1 | 0 | 0 | 0 |
| `Sources/LingXiProtocol/` | **0** | **0** | 0 | 0 |
| `Sources/LingXiApplication/` | **0** | **0** | 0 | 0 |
| `Sources/LingXiCore/` | 12 | 30 | 2 | 0 |
| `Sources/LingXiPlatform/` | 74 | 64 | 24 | 5 |
| `Sources/LingXiTUI` / `TUIComponents` | **0** | **0** | 0 | 0 |
| `Sources/LingXiWebUI/` | 0 | 4 | 2 | 0 |

GUI 侧最高为 `SettingsSystemPages.swift` 5 处。

### 7.3 `LingXiPlatform` 的真实机制：**混合**

**是真适配层的部分（可验证、符合"每平台一份兼容层"）**：`process / terminal / pty / sandbox / secureStorage / system / desktopHelper` 七类门面，各有 1 个协议 + 3 个 conforming type，分别落在 `Darwin/`、`Linux/`、`Windows/`，整文件守卫做构建期裁剪。范式：`Darwin/DarwinProcess.swift:1 #if canImport(Darwin)` → `:5 class DarwinProcessAdapter: PlatformProcessProtocol` → `:71 #endif`；`Linux/LinuxProcess.swift:1`；`Windows/WindowsProcess.swift:1 #if os(Windows)`。同一模式覆盖 18 个文件。桌面能力也是真协议：`Protocols/PlatformDesktopCapabilityProtocol.swift:171,190,208,234,264,270,275` 定义 7 个 backend，由 `Common/PlatformDesktopEnvironmentFactory.swift:19-33` 按 OS 组装。选择点全仓唯一：`LingXiPlatform.swift:8-90`，未知平台 `fatalError` 兜底。

**是伪适配层的部分（藏在 `Common/` 里靠内联 `#if` 冒充）**：

- `Common/PlatformHTTPSocket.swift`（31 处 `#if`）、`Common/PlatformLoopbackServer.swift`（23 处）、`Common/PlatformHTTPServer.swift`、`Common/PlatformHTTPConnection.swift`、`Common/AsyncLineReader.swift`（17 处）、`PosixPty`、`EnvironmentSanitizer` —— **`Protocols/` 下没有任何 socket / HTTP / line-reader 协议与之对应**。
- `Protocols/PlatformAsyncIOProtocol.swift:41-88`：契约文件自己内联 `Darwin.read` / `Glibc.read` / `Darwin.close`（`:46-52,66-72,83-87`）。协议层本应平台中立，这是最自相矛盾的一处。
- `Common/PlatformAdapters.swift` 里的"实现"是**桩**：`PlatformNetworkAdapter.resolve(host:)`（`:9-28`）硬返回 `127.0.0.1:0`，`read()` 返回 `Data()`，`interfaceAddresses()` 返回 `["127.0.0.1"]`；`PlatformFileAdapter`（`:4-6`）与 `PlatformAsyncIOAdapter`（`:61-63`）是空类。
- `Package.swift:69` 只有一行 `.target(name: "LingXiPlatform", dependencies: ["LingXiProtocol"])`，无 `path` / `exclude` / 条件源列表 —— 三个平台目录在所有主机都参与编译，每个文件必须自守。这在 SwiftPM 单 target 下是正当写法，本身不算问题；问题是没被协议覆盖的那批能力。

**判定：外壳是真适配层，内脏约三分之一是 `if os`。**

### 7.4 iOS 落地的具体阻塞点（按依赖顺序）

1. `Package.swift:49` `platforms: [.macOS(.v14)]` —— 无 `.iOS`，SwiftPM 层面即拒绝。
2. `Package.swift:9-45` —— `LingXiFrontendKit` / `LingXiMacApp` 整体在 `#if os(macOS)` 内；`Apps/iOS/` **不被任何 manifest、脚本或 CI 引用**。`Apps/iOS/LingXiIOSApp.swift` 是从未编译的死代码。
3. `Apps/iOS/LingXiIOSApp.swift:32` `LingXiTheme.accentColor` —— **`LingXiTheme` 全仓不存在**（唯一命中即该行）。符号级编译错误，即使前两条修好也编不过。
4. `:6,13` 依赖 `RuntimeFrontend` / `MainStageView`，二者在未声明给 iOS 的 target 内。
5. DesignSystem 令牌层裸 AppKit（7.1 A-1）—— iOS 编不过令牌层就等于编不过所有视图。
6. `ComposerDock.swift:315` `MacNativeTextView`（定义于 `NSTextViewBridge.swift:7`，`NSViewRepresentable`）、`:338` `.bodyLineHeight`；`SidebarView.swift:232-240,431` 同理。
7. `SettingsControls.swift:126` `Color(nsColor:)`。
8. `MainStageView.swift:204` `#available(macOS 15.0, *)` 在 iOS 上恒 false，所需 API 无 iOS 对等实现。
9. **UIKit 对等物不存在**：全仓（排除 `.build`/`.tmp`/`scratch`）grep `UIKit|UIColor|UIViewRepresentable|UIHostingController|UIApplication` **零命中**。
10. 唯一好消息：门面用 `canImport(Darwin)`（`LingXiPlatform.swift:9`）而非 `os(macOS)`，iOS 上能自然落到 `Darwin*Adapter`；`desktopHelper`（`:85`）等用 `#if os(macOS)`，iOS 自动降级为 `HeadlessDesktopHelperAdapter`。**平台层基本可用，UI 层从零开始。**

### 7.5 违反"平台兼容层分离"清单（按严重度）

1. **`Apps/` 对 `LingXiPlatform` 引用数为 0**（已实测确认）—— 整个前端在抽象层之外。应由 `LingXiPlatform.swift:6` 门面承担。
2. **剪贴板**：`DesignSystem/Components.swift:297`、`SettingsSystemPages.swift:422-423` 用 `NSPasteboard.general`。已有能力：`Protocols/PlatformSystemProtocol.swift:11 copyToClipboard`、`Protocols/PlatformDesktopCapabilityProtocol.swift:270 ClipboardBackend`，`Darwin/DarwinSystem.swift:44` 已实现。
3. **系统权限探测**：`SettingsSystemPages.swift:448-449` import `ApplicationServices`/`CoreGraphics`，`:458-459,466` 直接调 `AXIsProcessTrusted()` / `CGPreflightScreenCaptureAccess()`。已有：`Darwin/DarwinCapabilityProbe.swift:12,20` + `CapabilityProbing.probe() -> HostCapabilitySnapshot`（协议 `:275`）。
4. **文件/目录选择面板与告警框**：`NSOpenPanel` × 5（`SidebarView.swift:431`、`ComposerDock.swift:516`、`WallpaperStyle.swift:81`、`LingXiWorkbenchScene.swift:108`、`SettingsAppPages.swift:267`）+ `NSSavePanel`（`TraceWindowView.swift:146`）+ `NSAlert`（`WallpaperStyle.swift:88`）。**平台层无对应协议 —— 这是抽象层的真实缺口**，需按 `PlatformSystemProtocol` 的模式补一个对话协议 + 三份实现，而不是在视图里加 `#if`。
5. **主题令牌**：`Tokens.swift:22-49` 用 `NSColor` 承载全部语义色。应由 per-platform token 文件（对齐 `Darwin/` `Linux/` `Windows/` 现有做法）。
6. `Protocols/PlatformAsyncIOProtocol.swift:41-88` 契约内联平台调用（见 7.3）。
7. `Common/PlatformHTTPSocket.swift` / `PlatformLoopbackServer.swift` / `AsyncLineReader.swift` 无协议、无平台目录（见 7.3）。
8. **Core 业务层 OS 分支（应下沉到已有适配器）**：`Modules/Interaction/BrowserHostClient.swift:42-62` 硬编码各 OS 的 node 路径 —— 该用 `LingXiPlatform.process.resolveExecutable`，且同文件 `:59` Windows 分支已经这么做了，另两支没有；`Modules/Tool/ShellLaunch.swift:86-100` 与 `Extensions/ExtensionPlatform.swift:425-429` 的 `cmd /c` vs `/bin/sh -c` → 应由 `PlatformProcessProtocol` 提供 shell invocation；`Modules/MCP/MCPTransport.swift:226-230` `Darwin/Glibc.signal(SIGPIPE)`、`:270-280` `NUL` vs `/dev/null` → `Common/PlatformLoopbackServer.swift:309-311` 有同样的 SIGPIPE 代码，属重复泄漏；`App/CoreHost.swift:5629` `kill(getpid(),SIGKILL)` vs `exit(9)`；`Infrastructure/ToolExecutionSupport.swift:170,281`；`Modules/Symbol/LSPCoordinator.swift:30` Xcode toolchain 路径。
9. `Sources/LingXiClient/LingXiClient.swift:311-315` `#if os(Windows)` 拼 `.exe` —— 已有 `Common/ExecutableFinder.swift:6 defaultWindowsExtensions`。这是 Client/Protocol/Application 三层的**唯一**一处 OS 分支。
10. `Sources/LingXiWebUI/ServeCLI.swift:48-59` 重新实现"打开浏览器"（`/usr/bin/open` / `cmd /c start` / `xdg-open`），而 `Protocols/PlatformSystemProtocol.swift:7 openBrowser(at:)` 与三份实现（`DarwinSystem.swift:31`、`LinuxSystem.swift:34`、`WindowsSystem.swift:34`）**都已存在**；`:5-13` 还直接 `import Darwin/Glibc/WinSDK/Musl`。
11. **`#if canImport(SwiftUI)` 被当作平台守卫使用**（`Apps/macOS/` 21 个文件）：`ComposerDock.swift:1` 与 `:3`、`SidebarView.swift:1` 与 `:3` 构成"名义可移植、实则 macOS 专属"的误导。要么改整文件 `#if os(macOS)`（诚实），要么把 AppKit 依赖下沉到适配层（正确）。

---

## 8. 浏览器与 Agent 使用链路

对照 `Docs/browser use/Browser-embedded-implementation-handoff-2026-09-30.md` 第 6 节「产品接入时的最低语义」。

### 8.1 同页可能性判定

**不存在任何同页路径。GUI 的 WKWebView 与 Core 的 Playwright page 是两个彻底独立的浏览器实例，无共享句柄。**

- `WarmBrowserPane` 定义于 `WarmToolPane.swift:253`，`WarmBrowserModel:234` 自建 `let webView = WKWebView()`，`:243` 唯一动作是 `webView.load(URLRequest(url:))`
- `:34` 实例化为 `WarmBrowserPane()` —— **连 `runtime` 都不接收**（对比 `:35` `WarmGitPane(runtime: runtime)`）
- 全仓 `BrowserDomainClient` 仅命中其自身定义与 `VNext/LingXiClientVNext.swift:26,56`，`Apps/` 下 **0 命中**（本轮已实测确认）
- Core 侧页面在 Node 进程内创建：`Sidecars/browser-host/index.mjs:242 context.newPage()`，Swift 从不持有句柄
- `BrowserSessionStatus.tabID`（`Sources/LingXiProtocol/BrowserSessionTypes.swift:17`）形似 CDP targetId，实际只是 sessionID 回显：`BrowserHostClient.swift:301 source: .browser(tabID: sessionID, ...)`；sidecar 从不暴露 CDP 端点或 targetId
- `WarmToolPane.swift:282` 面板脚注「独立浏览会话 · 尚未连接 Agent 的浏览器会话」是诚实标注，非遗留文案

### 8.2 七项语义对照

| 语义 | 判定 | 现有依据 | 缺什么 |
|---|---|---|---|
| 选择会话 | **PARTIAL** | `Tool/BrowserTools.swift:41,82` 取 `ToolExecutionContext.sessionID`；`BrowserSessionManager.swift:18` 按 sessionID 分桶；`ToolRuntime.swift:796` 注入 | GUI 从不调 `client.browser.sessions()`；一 session 一 page，无"活动页面"概念；`act()` 只按 sessionID 查找、不校验 run 归属，"切会话不误控上一个"无硬约束 |
| 用户接管 | **ABSENT** | — | 契约无字段（`BrowserSessionTypes.swift:11-37` 全为只读投影）；manager 仅 navigate/act/capture/reset/close；`index.mjs:199-555` 无 pause；无法确认在飞动作已归零：`BrowserHostClient.swift:336` 无取消令牌下发，sidecar 不跟踪在飞动作，`:368` 用 `try?` 吞掉关闭失败 |
| Agent 恢复 | **PARTIAL** | `BrowserSessionManager.swift:145-161` 引用匹配 + `index.mjs:449-455` `-32002` 陈旧拒绝 | 有"陈旧引用作废"底层机制，但无 resume 命令、无"先确认活动页再执行"步骤；version 只在 navigate(`index.mjs:299`) 与 snapshot(`:386`) 递增，恢复不强制作废旧 ref |
| 关闭或失联 | **PARTIAL** | `BrowserSessionManager.swift:205`；`index.mjs:542-551` + `:68-81` 真实拆除 | 失联与空页面无法区分；`index.mjs:264-288` 在 session 缺失时**惰性重建 context/page**，`BrowserSessionManager.swift:88-90` 同样惰性 create —— 正是文档禁止的"偷偷重建空白页面继续执行"；契约无 liveness/lost 状态 |
| 权限与拒绝 | **REPRESENTABLE** | `ToolRuntime.swift:737-784`（deny 在执行前抛 `permissionDenied`）；`BrowserTools.swift:25-32` resource 即目标 URL；GUI 应答 `RuntimeFrontend.swift:374-381` + `InteractionSurfaces.swift:10` | `BrowserActTool.swift:70` resource 是常量 `"browser://act"`，无法说明动作与目标；`Sources/LingXiCore/Modules/Permission/` 内**无任何 browser 专属规则**（grep 无命中）；无法区分"读页面 / 写入 / 接管" |
| 登录态与隔离 | **PARTIAL** | `index.mjs:239-242` 每 sessionID 独立 `newContext()`，跨导航复用 | 无持久化契约（文档称另行设计，可接受）；context 句柄不对外；无字段告知 GUI"该会话登录态在此宿主" |
| 远端 Core / iOS | **PARTIAL** | `VNextStdioCoreServer.swift:243-244`、`VNextStdioTransport.swift:311-312`；客户端与传输无关；`ProtocolService.swift:979-985` 可合法声明不支持 | `BrowserSessionStatus` 无宿主设备/能力描述，无法表达"有会话但无交互展示能力"；`Apps/iOS` 下 0 browser 引用 |

### 8.3 最小协议增量（复用现成抽象，不新造）

仓库里**已经**存在同形概念，按最小化原则必须先复用：

- **所有权 + 能力位**：`Sources/LingXiProtocol/TerminalSessionTypes.swift:11-45` —— 正是"一个实时会话，属于 agent 还是 user，带 `ownerSessionID` / `ownerRunID`，显式声明 `supportsInput` / `supportsInterrupt`，运行时拒绝而非假装"。这就是接管语义的现成模板（已核实 `:13 case agent`、`:15 case user`、`:38 ownerRunID`、`:41 supportsInput`）。
- **生命周期动词**：`Protocol/Task/TaskLifecycleCommands.swift:5-8` 已有 `pause` / `resume` / `cancel`；`Task/TaskState.swift:8` 有 `.paused`；`Modules/Task/TaskStateMachine.swift:19-44` 是合法转换表；`ProtocolService.swift:826-827` 已有 `task.pause` / `task.resume` wire 模式。
- **可审计撤销**：`CapabilityTypes.swift:9 PrincipalKind.browserHost` 与 `CapabilityGrantState.revoked`（`:31-35`）已存在。

真正的增量只有三项，且都是**扩展现有类型**：

1. `BrowserSessionStatus`（`BrowserSessionTypes.swift:11`）加 `controller`（照 `TerminalSessionKind` 取 `.agent`/`.user`）、`state`（照 `TaskState` 取子集 `.running/.paused/.closed/.unavailable`）、`isLoading`、`supportsTakeover`。这是加字段，不是新契约。
2. `ProtocolService.swift` 在 `:787` 的 10b 段增加 `browser.pause` / `browser.resume` / `browser.takeOver`，载荷沿用 `CommandEnvelope` + `TaskLifecycleRequest` 形状（`TaskLifecycleCommands.swift:14`），命名沿用 `task.pause` 风格。
3. pause 应答需要"在飞动作已归零"确认。现有类型里最近的是 `ActionBatchResult.completedStepCount`（`InteractionTypes.swift:274`）；最小做法是在 `CommandReceipt` payload 回 `quiescedAt` + `cancelledInFlightActionCount`，并在 sidecar 增加 `session.quiesce` 与在飞计数。
4. 附带修 `BrowserCapture`（`BrowserSessionTypes.swift:53-63`）：文档注释声明"恰好一侧有值"，实际允许两侧皆空，需要显式 `.noImage(reason:)` 形态。

**不需要新增**：独立的 ownership 协议、pause 状态枚举、第二套会话注册表、新引用系统。

### 8.4 mock 伪装风险

Swift 侧**未发现**自动降级（值得肯定）：`BrowserSessionManager.swift:29-31` 默认 `.real`，仅显式 `LINGXI_BROWSER_HOST_MODE=mock` 才切；`BrowserHostClient.swift:165-172,179-185,190-197` 在 real 模式对无握手、`playwrightAvailable == false` 都硬抛 `capability.featureUnsupported`。

sidecar 侧三处真实问题：

1. **未知 mode 静默变成假浏览器**（`index.mjs:5,8,202,230,237,267`）：所有判定都是 `HOST_MODE === "real"` 精确字符串比较。任何既非 `real` 也非 `mock` 的值（拼写错、大小写）既跳过全部 real 守卫，又因 `playwright` 为 null 不建 page → `session.navigate` 记 `Mock Page: <url>` 并**返回成功**（`:294-297`），`session.snapshot` 返回两张固定假元素（`:379-383`），`session.act` 什么都没做却回 `{success:true}`（`:538`）。一个配置错误即可触发文档明令禁止的伪装。
2. **空 capture 被报成成功**（`index.mjs:425` 返回 `{mock:true, success:true}`）：`BrowserHostClient.swift:330-332` 只读 `path`/`screenshotBase64`，**丢弃 `mock` 标志**；`CoreHost.swift:4799-4803` 组装出 `base64JPEG: nil, savedPath: nil` 的成功 envelope，违反 `BrowserSessionTypes.swift:50-52` 自述不变式。前端拿到"空对象 + 成功"。
3. **握手 mode 字段被解码但从不比对**：`BrowserHostHandshakeResult.mode`（`BrowserHostClient.swift:13`）从未与 `expectedMode` 校验；`index.mjs:11-13` 把 playwright import 失败 `catch {}` 吞掉。一个 mock 宿主应答 real 客户端不会被 Swift 侧拦住。

另有掩盖失败的弱化：`BrowserHostClient.swift:368` 与 `BrowserSessionManager.swift:206` 用 `try?` 关闭会话，失败后仍从字典移除 → 前端显示"已关闭"而页面存活。

### 8.5 sidecar 真实能力

**可见窗口不存在**：`index.mjs:47` 硬编码 `headless: true`，全文件无 env/param 可覆盖，无 `channel`、无 `executablePath`、无 `launchPersistentContext`、无 `--user-data-dir`。交付决策里的"独立受管可见 Chromium / 本机 Google Chrome"在仓库代码中**没有对应实现** —— 那是外部验证脚本的结论。

已实现：握手与 capabilities 声明（`:210-216`）、每 session 一 context 一 page（`:239-242`）、`domcontentloaded` 导航 + http/https/about 协议白名单（`:53-66, :291`）、有界 DOM 扫描（300 候选 → 报 100，`:322-370`）、click/type/hover/key/wait（`:515-535`）、陈旧 ref 与陈旧 version 拒绝（`:440-455`）、动作前实时重取 bounds（`:459-489`）、虚拟光标 DOM 叠层（`:83-181`）、JPEG 落盘或 base64、真实 context/page 拆除（`:68-81, :542-551`）、SIGINT/SIGTERM 收尾（`:575-583`）。

未实现：可见窗口；弹窗/新标签（无 `context.on('page')`）；`dialog` / `filechooser` / `download`；back/forward/reload；CDP 端点或 targetId 导出；请求拦截；`$/cancel` 或任何在飞动作跟踪；IME 组合输入（只有 `keyboard.type`，`:525`）。`capabilities`（`:215`）未声明 pause/takeover/embed/visible 任何一项。

**并发模型缺陷**：`index.mjs:183 rl.on("line", async (line) => {...})` 的 async handler 从不被 await，请求并发交错；同一 `session.page` 上两个动作无 per-session 互斥。接管所需的"确认在飞动作已结束"在当前结构上无处可查。

### 8.6 测试覆盖的真实边界

全部行为断言跑在 `mode: .mock`：`Tests/LingXiAgentTests/BrowserSessionManagerTests.swift:76,131`；`BrowserCorrectnessTests.swift:48,70,95,198,225`。因此它们证明的是 JSON-RPC 成帧、Swift 解析与 mock 分支，**不证明**真实 Chromium 能起、真实 DOM 扫描结果、点击/输入落在正确元素、截图字节、超时行为、弹窗，或 headless 之外的任何东西。

- `BrowserCorrectnessTests.swift:15-42` 名为"Real mode fails hard"，实则双向接受：playwright 可用时只断言 `playwrightAvailable == true`（`:32`），不可用时断言错误类型。从不驱动真实页面 —— 两个文件里没有任何真实模式的行为覆盖。
- `BrowserCorrectnessTests.swift:214` 是恒真式 `#expect(base64 == nil || base64 != nil)`，注释（`:211`）却写"正常调用"。**它把 8.4 第 2 点的空 capture 伪装编码成预期行为，而不是捕获它。**
- `BrowserSessionManagerTests.swift:50-61` 用读源码字符串（`source.contains("\"\(action)\"")`）验证 `browser_act` 宣称的动作宿主是否实现 —— 文本匹配不是执行验证，`hover` 即便实现为 no-op 也会通过。
- 测试各自新建 `BrowserSessionManager` / `BrowserHostClient`，从不经过 `CoreHost.swift:304` 的实例级 manager，故 `CoreHost.swift:4775-4804` 的投影/抓图 RPC 仅由 `ContractTests/.../ProtocolVNextFrozenContractTests.swift:937`（in-process mock runtime）覆盖。

### 8.7 交接文档中被代码现实推翻或已过时的条目

文档钉 HEAD `b861395`，早于本轮 `Apps/` 迁移。以下条目接手时须先校正：

1. **`:68` 基线过时**：当前工作树是 `d21e79d`，Apps 迁移已落地。
2. **`:70-80` §3 全部链接是坏链**：相对 `Docs/browser use/` 写成 `../Apps/...`，解析为 `Docs/Apps/...`，实测不存在。正确路径是 `Apps/macOS/FrontendKit/Components/WarmToolPane.swift`。不只浏览器条目，§3 每条链接都错。
3. **`:82` lockfile 判断方向已反**：文档提示"不把实验版本 1.63.0 当作仓库已锁定版本"。实际 `Sidecars/browser-host/package-lock.json:19` **已锁 1.63.0**，`node_modules/playwright/package.json` 亦为 1.63.0；`package.json:11` 的 `^1.40.0` 只是声明范围。
4. **`:75` 低估差距**：「当前 `headless: true`」属实，但同一句"独立窗口方案也仍需产品接入"掩盖了更强事实 —— 仓库里连 `headless: false` 都不可达，也没有任何外部 Chrome / `executablePath` / 持久 profile 入口。§6 `:150`「只是打开窗口、加 `headless: false`，还不能算完成统一」应改为：`headless: false` 本身也需要改代码。
5. **`:73` "保留共享 manager" 表述不准**：`BrowserSessionManager.swift:15` 确有 `static let shared`，但 `CoreHost.swift:304` 明确构造**实例级** manager，共享靠注入（`CoreHost.swift:462, 5487` → `BuiltinTools.swift:2100-2101`）。未注入时 `BrowserTools.swift:10, 52` 的 `?? BrowserSessionManager()` 会另起一个实例（即另一个 sidecar 进程）。不应被理解为存在全局单例注册表。
6. **`:79` 遗漏关键现状**：`BrowserDomainClient` 不只是"只有查询"，而是**在所有前端零调用方**。已交付的只读投影尚未被任何 GUI/TUI 消费 —— 这一步比"没有控制命令"更靠前。
7. **`:78`「没有暂停/控制方/恢复/loading 契约」经核对仍准确。**
8. **§6 `:145`「GUI/TUI 都使用可回答的现有授权交互」半真**：应答通道存在（`RuntimeFrontend.swift:374-381`），但 `Modules/Permission/` 内无任何 browser 专属规则，浏览器权限只能靠通用 `.networkAccess` / `.userInteraction` 命中，无法表达"允许读页 / 拒绝写入 / 允许接管"。

---

## 9. 按四条原则排序的整改优先级

排序依据：先拆掉会持续扩大债务的结构性破口，再补能力缺口，最后才是新增面。每条都标注它服务的是哪条原则。

**P0 —— 止住原则性破口（否则后续接线会把破口放大）**

| # | 动作 | 服务原则 |
|---|---|---|
| 1 | Git 面板的写操作（`add/restore/fetch/pull/push/switch`）改走 Core 通道，前端只留展示 | 前后端分离 |
| 2 | 停止前端数 `+`/`-`，改用 Core 已下发的 `addedLines/deletedLines/changedFiles`（三处：`CoreProjection.swift:324-325`、`TimelineRows.swift:145-146`、`TimelineViews.swift:532-534`） | 前后端分离 + 最小化（用现成字段） |
| 3 | 移除 `changeCurrentDirectoryPath` 进程级副作用；`.git/HEAD` 直读与 worktree 前缀硬编码改由 `WorkspaceSummary` 下发 | 前后端分离 |
| 4 | 把 `PlatformBoundaryArchitectureTests.swift:40-51` 的扫描范围扩到 `Apps/`，并把纯度检查从字符串 `contains` 换成依赖图（补 `CoreDependencyGraphGateTests` 的正向传递闭包） | 跨平台 + 前后端分离（让破口不再隐身） |
| 5 | sidecar：未知 mode 直接拒绝启动而非退化成假浏览器；`mock` 标志不得在 `BrowserHostClient.swift:330-332` 被丢弃；握手 `mode` 必须与 `expectedMode` 比对 | 最小化（是收紧，不是新增） |

**P1 —— 补抽象层真实缺口（跨平台的根）**

| # | 动作 | 服务原则 |
|---|---|---|
| 6 | 新增对话/选择面板协议 + 三份平台实现，替换 5 处 `NSOpenPanel`、`NSSavePanel`、`NSAlert` | 跨平台（这是抽象层真实空缺，必须补，不算堆砌） |
| 7 | 把 `Common/` 里的 socket / HTTP / AsyncLineReader / SIGPIPE 提升为协议并拆到 `Darwin/Linux/Windows`；清除 `PlatformAsyncIOProtocol.swift:41-88` 契约内的平台调用；删掉 `PlatformAdapters.swift` 的桩实现（假可用比没有更危险） | 跨平台 |
| 8 | Core 业务层 8 处 OS 分支下沉到已有适配器（`BrowserHostClient.swift:42-62` node 路径、`ShellLaunch.swift:86-100` shell invocation、`MCPTransport.swift:226-230,270-280`、`LingXiClient.swift:311-315`、`ServeCLI.swift:48-59` 重复实现 openBrowser） | 跨平台 + 最小化（目标都是复用已存在的门面） |
| 9 | DesignSystem 令牌层做 per-platform 拆分；6 个裸 AppKit 文件要么整文件 `#if os(macOS)`（诚实），要么下沉（正确） | 跨平台 |

**P2 —— 接线已存在的能力（详尽性的主体）**

按用户可感知价值排序，全部是"Core 已有、client 已暴露、只差调用"，零新增抽象：

| # | 接线项 | 落点 |
|---|---|---|
| 10 | `browser.sessions` / `browser.capture` → 浏览器面板消费真实投影 | `WarmToolPane.swift:253-291` |
| 11 | `content.*` → 附件真通道（同时需要 `ApplicationAction.submitPrompt` 补附件位，`Sources/LingXiApplication/Actions/ApplicationAction.swift:19`） | `ComposerDock.swift:515-535` |
| 12 | `context.search` / `context.entry` → 侧栏搜索与 `@`/`#` 补全（TUI/WebUI 已有用法可照抄） | `SidebarView.swift:132-135` |
| 13 | `interaction.list` → 跨会话"待你处理"角标 | `SidebarView.swift:223-229` |
| 14 | `run.resume` / `run.list` / `agent.tree` → Run 恢复入口与 subagent 树 | 概览面板 |
| 15 | `task.artifacts` / `task.report` / `task.criteria` → 填平 live 下恒 nil 的 plan/report | `WarmToolPane.swift:123-130` |
| 16 | `trace.query` 分页 + `diagnostics.runTrace` → 轨迹窗口去截断 | `TraceWindowView.swift:35-46` |
| 17 | `context.policy.update` → 上下文设置页免重启生效 | `SettingsAgentPages.swift:622-680` |
| 18 | `workspace.set` → 换目录免杀 Core 重启 | `RuntimeFrontend.swift:85-96` |
| 19 | `credential.list/status/test`、`extension.install/uninstall/configure`、`agent.presets`、`runtime.config` | 对应设置页 |
| 20 | `.diff` timeline 事件源（需要 Core 侧提供 per-turn 改动事件，属协议增量，非纯接线） | `TimelineViews.swift:494-537` |

**P3 —— 清理与对齐**

| # | 动作 |
|---|---|
| 21 | `RuntimeFrontend.swift:368-370` 补 `guard isPreview`，未连接不得谎报流结束 |
| 22 | 删除死类型 `InspectorTab` / `selectedTab`，或接出"变更"面板 |
| 23 | 修正 `SettingsAppPages.swift:391` 与 `InteractionSurfaces.swift:8-9` 的快捷键矛盾（单一真源） |
| 24 | `availableCommands` 增加插件变更后的重同步触发点（复用 `syncPluginCommands`） |
| 25 | 删除或接管 `Apps/iOS/LingXiIOSApp.swift` —— 它引用不存在的 `LingXiTheme`，且无任何构建系统编译它 |

**浏览器内嵌的边界提醒**：8.3 的协议增量属于"产品接入"阶段。交接文档第 5 节的门槛（生命周期、同 document、弹窗、退出）尚未通过，且 sidecar 连 `headless: false` 都不可达。P2 第 10 项只做**只读投影消费**（让用户看见 Agent 的会话与截图），不等于同页接管；接管语义必须等原型门槛通过后再实现，否则是在未验证的宿主上叠代码。

---

## 10. UNKNOWN（本狐没能确定的项）

诚实标注，不写成结论：

1. Core 是否计划在协议里为 `ToolResultSnapshot` 增加 exit code（`CoreProjection.swift:128` 的恒 nil 是否有计划填）。
2. `browserSessionManager` 能否被 macOS GUI 进程内合法驱动 —— 截图通道是否假定 headless，需实跑验证。
3. `agent.presets` 与 Composer 三档模式（build/plan/explore）的映射关系是否已被 `AgentMode` 穷尽，还是正交概念。
4. `ApplicationStore` 是否已消费 `session.snapshot` 做全量重同步（`client.session.snapshot(` 出现在装配层，故 GUI 侧可能无需再接 —— 但没确认其刷新时机）。
5. 把 `LingXiFrontendKit` 对 `LingXiApplication` 的依赖去掉是否可行：这是"前端传递链接平台层"的根因，但拆它可能改变投影职责分配，需设计而非直接改。
6. 注：任务描述中列举的 `WorkspaceTypes.swift` **不存在**于仓库，`Sources/LingXiProtocol/` 下最近邻是 `SessionTypes.swift`；不应据其推断存在可复用的 workspace 所有权概念。

---

## 11. 已经守住、不要动的地方

审计报告若只列问题会误导优先级，以下经核实为正确实现：

- `Sources/LingXiProtocol`、`Sources/LingXiApplication`：**零** OS 条件，纯契约与编排。
- `Sources/LingXiTUI`、`Sources/LingXiTUIComponents`：**零** `#if os(` / `#if canImport(`，唯一 `#if` 是 `ApplicationTUI.swift:4251` 的 `#if DEBUG`；终端能力经 `Sources/LingXiTUI/TerminalBackend.swift` 走 `LingXiPlatform` 门面。**第 5 项检查答案是"没有泄漏"，不需要修。**
- 18 个平台适配器文件整文件守卫，命名与目录一一对应，符合"每平台一份兼容层"。
- `LingXiPlatform.swift:8-90` 是全仓唯一适配器选择点，`fatalError` 兜底未知平台。
- `Package.swift:9-45` 把"GUI 只在 macOS 存在"这个决定放在 manifest 里，注释 `:15-19` 明确承认 DesignSystem 的 AppKit 未守卫 —— **决策位置正确**，问题只在决策未被代码执行。
- GUI 中 9 个文件（7.1 A-2）的 `#if os(macOS)` 守卫正确且必要。
- Core 的 `canImport(FoundationNetworking)`（23 处）与 `PlatformCrypto` 的 `canImport(CryptoKit)`（10 处）属 SDK 可用性判断，**不算违反原则**，不要为了"消除 if os"去动它们。
- 浏览器 Swift 侧**未发现**真实模式失败降级成 mock 成功（见 8.4 开头）——伪装风险在 sidecar，不在 Swift。
- `WarmToolPane.swift:282`、`BrowserSessionTypes.swift:50-52` 这类"代码自陈边界"的注释是诚实的，整改时应保留而非抹掉。

---

## 12. 审计方法与局限

- 取证方式：三路并行源码审查（GUI↔Core 绑定、跨平台分层、浏览器链路），本狐另做 7 项关键断言的直接复核（`Apps/` 对 `LingXiPlatform` 引用数、`Package.swift` 依赖链、`TerminalSessionKind` 字段、纯度检查实现、`ProtocolService.swift` 禁令原文、`CoreProjection` 数行数处、浏览器面板脚注）。
- 局限：本审计为静态源码审计，**未运行 Core 与 GUI 做端到端验证**，未启动 sidecar，未测量任何性能数据。因此"某面板显示 X"类的判定基于代码路径而非实际渲染结果。性能相关结论一律不给出（交接文档第 7 节要求的采样口径尚未执行）。
- 本文不授权任何新依赖、新服务或宿主模型变更；`Docs/` 依 `LICENSE-MATRIX.md` 为 CC-BY-4.0。

---

## 13. 整改记录与本报告的自我更正（2026-09-30，同日晚些）

按第 9 节的 P0 清单执行后的结果。**其中两条审计结论在执行中被证伪，先更正结论再记录改动**，因为本文会被后续实现引用。

### 13.1 被证伪的两条审计结论

| 原结论 | 实际 | 影响 |
|---|---|---|
| §6 第 4 条：三处前端自数 `+`/`-` 是活数据违规，改用现成聚合字段即可 | `FileChangePresentation.additions/deletions` **没有任何读取者** —— `inspector.live?.changes` 全仓唯一消费者是 `WarmWorkbench.swift:250` 取 `.count` 当徽标；另两处计数点位于 `loadPreviewFixture()` 独产的 `.diff` 时间线条目，而 preview 按定义无 Core 连接 | 正解是**删除死计数**，不是新增逐文件契约。§9 P0 第 2 项原方案作废 |
| §9 P0 第 2 项「改读现成字段」 | `WorkspaceDiffSummary` 的 `addedLines/deletedLines/changedFiles` 是**整个 diff 的聚合值**，填不了逐文件需求；执行中一度加了 `WorkspaceFileLineCount` 逐文件契约，确认无消费者后**已完整回退**（`Sources/` 零残留，两文件回到 HEAD 原状） | 契约保持不动 |

另澄清一处避免误伤：`DesignSystem/Components.swift:576-577` 按 `+`/`-` 前缀给 diff 行**着色分类**，属 diff 渲染器本职，不是统计总数，未改动。

### 13.2 已落地（4 项）

| 项 | 改动 | 验证 |
|---|---|---|
| 依赖门禁 | `CoreDependencyGraphGateTests` 新增前端正向闭包、禁止前端直接依赖平台层、**把空转的 `allowList` 真正接进所有断言**、新增「过期豁免必须失败」检查 | 反向验证：注入直接依赖立即红，撤销即绿；8/8 通过 |
| 子进程 cwd | `stdioCore` / `VNextStdioTransport` 增可选 `workingDirectory`，删除 `RuntimeFrontend` 的 `changeCurrentDirectoryPath` 全局副作用 | `CoreHost.swift:342` 靠子进程 cwd 定 baseWorkspace，交付同一值，行为不变 |
| Git branch 读越权 | 删除 `CoreProjection.gitBranch(at:)` 的 `.git/HEAD` 直读（全仓无残留），两处改用 `WorkspaceSummary.gitBranch` | 构建 + 17 项相关测试通过 |
| Sidecar 伪装 | 非法 `LINGXI_BROWSER_HOST_MODE` 拒绝启动；握手 mode 与 `expectedMode` 不一致即抛错；真模式下「成功但无图像」不再返回 `(nil,nil)`；`BrowserCorrectnessTests:214` 恒真断言改为真断言 | 实测 `Real` 大小写误配 → exit 1；`mock` 正常且回报 mode；15 项浏览器测试通过 |

### 13.3 仍未做，且原 P0 定性有误（2 项）

1. **Git 写操作走 Core**（§9 P0 第 1 项）：Core **没有** `add/commit/push/fetch/switch` 的 RPC，workspace 线只有 `diff/fork/get/languageServices/set/toolStatus` 加 `worktree.*`。这是新增协议面，不是收紧。附带发现：`WarmToolPane.swift:296-394` 在 GUI 里自己跑 `git diff --numstat` 做逐文件统计，与 Core 的 `4810-4824` 完全重复 —— 同一决策一并处理。
2. **逐文件行数**：见 13.1，当前无活消费者，不做。

### 13.4 执行中新发现的 main 缺陷（本审计原未覆盖）

`ProviderWorkloadAuditTests.swift:174` **确定性失败**：`toolSchemaTokens` 实测 2072 > 阈值 2000。溯源：阈值由老提交 `cad8d52` 设立；本分支 `17f78ab..HEAD` 给工具模块新增 101 行（`BuiltinTools.swift` +44、`ShellLaunch.swift` +66）将其顶过线，且分支从未改动 token 计算逻辑。**这是测试在正常工作**，报出的是分支自带的 schema 预算超支，因每提交带 `[skip ci]` 而未被发现。处置属产品决策（接受更大预算，还是压缩工具 schema），不在本报告授权范围。

全量 1301 项测试中其余失败（`ProviderRateSchedulerTests:120`、`UXAndStreamingFixesTests:258`、`TUIRenderingTests:46`、`PlatformHTTPServerTests:328`、`VNextStdioTransportDeadlineTests:29`）经单独运行验证均确定性通过，且失败集合在三次未改代码的全量运行间漂移 —— 属时序 flake，与本报告的改动无关。


---

## 14. P/E 核心与 Git 面收敛记录（2026-09-30 至 10-01）

契约 `Docs/Decisions/PE-Core-Git-Semantics-Freeze-2026-09-30.md` 的执行落点：

### 已经改到位

- **P→E 单一路径**：`ContextCompactor` 的 page-out 只调用 `ECoreObjectStore.pageOut(...)`；`DerivedContextStore` 的写入 API 改名为 `insertLegacyPage`，生产侧零调用者，只做 Legacy Read Fallback。
- **E-Core Index Projection**：每轮由引用重建，只带 `referenceID / origin / turn / summary`；投影自身受预算约束（`min(512, hardInput/8)`，且永不超过 hardInputLimit），压力极大时先牺牲索引、不牺牲正文。
- **Exact Restore**：`referenceID → ECoreReference → objectID → payload`；`context_recall` 按 summary 命中后同样按 referenceID 精确取回。rewind 只裁工具来源引用，非工具 page-out 保留。
- **Context Value Eviction**：第四节冻结公式（`ContextValueEviction.swift`）+ 4.15 逐对象水位收敛 + 4.16 五级 tie-break + 4.19 Fail-Open + 4.20 全字段可观测（`evictionTrace(sessionID:)`）。
- **activeFileAffinity 数据流**：改由批次真实 `ToolResult.changedFiles` 与 `ToolCall.arguments` 路径推导；`handleSearch` 的 `activeFiles` 参数（此前恒为 `[]`）删除，改为从同一工作集推导。
- **P/E-Core 退出架构语义**：类型全部按真实职责重命名，`PCoreTerminologyGateTests` 禁止新增 L 类型；配置键走「新 P/E 键 → 旧 L 键 → 默认」，GUI 只显示 P/E 术语。
- **Git RPC namespace**：`git.status/diff/log/show/branch` + `git.add/restore/checkout/switch/commit`，结构化参数、无默认实现（`ProtocolService` 里是必选项），CLI/GUI/Agent/stdio/in-process 全部经同一 `GitRunner`。写操作进 `ToolMutationCoordinator`，权限走 `PermissionEngine`，GUI 身份为 `gui:<UUID>`。
- **`dirtyPathCount`**：porcelain v2 records 统一解析，同路径 staged+unstaged 计 1，`-uall` 展开未跟踪目录，ignored 不计；`mainCheckoutRoot` 由 `--git-common-dir` 推导。

### 第二轮收敛：远程同步与前端 raw git 清零（2026-10-01）

第一轮留下的两项例外已经按新冻结语义关闭，**不再有白名单**：

- 权威 `GitAction` 扩到 13 个动作：原 10 个 + `fetch` / `pull` / `push`，对应新增 `git.fetch` / `git.pull` / `git.push` RPC 与 feature `git.remote.sync`。GUI 的获取 / 拉取 / 推送回到面板，但走 RPC。
- 远程动作仍是结构化参数（`remote` / `prune` / `branch` / `setUpstream`），没有 `git.exec`、没有裸 argv。`pull` 只有 `--ff-only`；分叉返回 `gitNonFastForward`，Core 不 merge、不 rebase、不 auto stash。`push` 没有 upstream 时拒绝执行而不是猜目标；`setUpstream` 只接受已配置的 remote 名，Core 不代为添加 remote。force / refspec / 镜像 / tag 全量推送在结构里不存在。
- 风险模型新增 `repositoryRemoteWrite`：`push = repositoryRemoteWrite + network`，本地 `repositoryWrite` 不会被继承成远程写。全部远程动作与本地写一样进 `ToolMutationCoordinator`。
- `git.status` 响应扩为 `branchName / headSHA / upstreamRemote / upstreamBranch / ahead / behind / files[]`（一次 porcelain v2 调用），`git.diff` 扩为 `patch + files[]`（含 `additions / deletions / binary / status / oldPath`，支持 `worktree / staged / head` 与 `baseReference / commitReference`）。没有新增 `git.numstat` 这种按 shell 命令形状暴露的接口。
- 前端与 CLI 的 git 进程调用清零：`WarmGitModel` 不再 `Process`，`ComposerDock` 的分支列表与切换改走 `git.branch` / `git.switch`，TUI 标题栏分支改走 workspace summary（Core 由 porcelain 计算），离线 review CLI 经 `GitService` / Git RPC 取 diff。`GitRPCSurfaceTests` 的门禁现在只允许 `GitRunner.swift` 一个文件启动 git，白名单长度为 1。

未跟踪文件的 file stats 已按固定语义补进 Core：`git.diff` 的 `files[]` 对未跟踪文本文件给出 `additions = 文件行数 / deletions = 0 / binary = false`，二进制给出 `nil / nil / true`，超大、读不到、编码无法可靠判定时 stats 为 nil 且绝不因此让整次 `git.diff` 失败。行数只在 Core 读文件计算：前端不读文件、不数行，也不用 `git diff --no-index`，门禁白名单仍是单文件。未跟踪文件只在 `worktree` / `head` 口径出现，`staged` 口径不含它们 —— 这与 git 自身的暂存语义一致。
