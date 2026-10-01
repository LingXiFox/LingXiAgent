# GUI ↔ Core Closure Report — 1.2.0

> 依据 `LingXiAgent-GUI-Core-Closure-Freeze.md`（审计基线 HEAD `6120d22`）逐项收口的结果报告。
> 本轮工作基线：`e2c686b`，收口版本 `ProductVersion.current = 1.2.0`。
> 报告格式遵循冻结文档第 29 节；每条结论都对应一次可复现的检查，不写「已实现」。

## 0. 先说三件与冻结文档前提不一致的事

冻结文档是在 `6120d22` 上审计的，本轮开工前重新核对了 `e2c686b` 的实际代码。三处前提已经过时或说反了，先摆出来，避免后续按错误前提判断完成度：

1. **第 30 节「右侧常驻栏新增子代理状态与 Task/To-do」大部分已经存在**。子代理行与待办行在时间线里已有真值投影（`RuntimeFrontend.swift` 的 `inspectorSnapshot` 从 `session.subagents`、`live.todos` 填），只是**没有出现在常驻栏**。所以第 30 节的实际工作量是「把已有真值搬到指定位置」，不是从零做两个模块。本轮按第 30 节字面要求执行：常驻栏新增两块，运行上下文卡片一字未改。
2. **第 11 节点名的伪造 default 范围比实际小**。文档列的 `Terminal methods`、`Provider configuration`、`getBrowserSessions/Capture` 在 `e2c686b` 已经是诚实 `throw unsupportedCommand`；真正伪造的只有 9 个（Task 域 5 个 + `listWorktrees` + Agent 域 3 个）。本轮按实际清点处理，并留下机械闸口防止未来重新出现。
3. **有一处比文档说得更严重**：文档只说 GUI 附件没进 `UserInput.attachments`。实际上 `attachments` 在整个 `Sources/LingXiCore` 里只出现一行（`CoreHost.swift` 组装 `MessageSnapshot` 时），**Core 收到后直接丢弃**——即使 GUI 传了也没人用。所以闭环必须包含 Core 侧消费，第 3.1 节流程图的最后一段 `→ Agent Loop` 原本是不通的。

---

## A. 已修复的 GUI → Core 缺口

| 域 | 修复前的实际断点 | 现在的链路 |
| :--- | :--- | :--- |
| **附件 §3** | `ComposerDock.pickFiles()` 只把 `@/绝对路径` 拼进输入框；`model.attachments` 全仓**无任何写入点**，`AttachmentStrip` 是不可达 UI；live 提交走 `dispatch(.submitPrompt(text))`，Application/Protocol 两层**根本没有附件位**；Core 收到 `UserInput.attachments` 后丢弃 | 选择→`AttachmentPresentation(sourceURL:)`→提交前 `client.resource.upload` 真上传→`ApplicationAction.submitPrompt(text:attachments:)`→`UserInput.attachments`→`CoreHost.resolveAttachments`→`SessionRuntime` 生成 `source: .attachment` 的独立上下文条目（进入 growing context，RetentionScore 65） |
| **浏览器 §4** | 右侧栏是一个私有 `WKWebView` + 地址栏，自己 load/goBack/goForward，与 Agent 会话无关；`browser.sessions`/`browser.capture` 在 `Apps/` 里**零引用** | Agent Browser Monitor：`client.browser.sessions()` + `capture(sessionID:)`，显示 URL/title/tabID/observationVersion/observedAt/elementCount + 最新截图；仅在 run 活跃时轮询，run 停即停；无会话时明确空态。`import WebKit` 已移除，全仓不再有第二个浏览器状态 |
| **Goal §5** | `setGoal(nil)` 清完 GUI 字段直接 `return`，Core 的 goal 锚点仍在每轮注入；设置走 `/goal` 文本命令 | 设置/修改/清空统一走 `client.session.setGoal(sessionID:goal:)`；chip 值改由 `apply(_:)` 从 `session.goal` 投影，GUI 不再自写 |
| **Agent 树 §6** | 只有扁平子代理时间线行；`getAgentTree`/`cancelRun`/`resumeRun` 客户端方法存在但 GUI 从不调用 | `AgentTreeSheet` 递归渲染 `getAgentTree`，节点显示 runID/title/status/model/startedAt/latestActivityAt/terminalReason；取消与恢复后回读权威树 |
| **Task §7** | `finalizeTask` 先写本地 `task.state` 再 `try?` 发 RPC，失败仍显示已完成；`updateCriteria`/`listArtifacts`/`getReport` 无 GUI 入口 | 命令→回执→`refreshTasks()` 回读；Task Detail 补产物、报告、验收标准、收尾动作 |
| **Context §8** | `searchContext`/`getContextEntry` 已实现已传输，但**无任何界面调用**（核查为 0 引用） | 独立「上下文检查器」窗口（菜单 ⌥⌘J）：搜索、打开精确条目、P/E/缓存/生效策略、压缩走 RPC 后回读。按 §30 不动运行上下文卡片 |
| **Extensions §9** | Settings 只有 list/enable/disable/reload，`getStatus` 无调用点，行状态是列表快照的旧值 | 行展开即向 Core 单独 `getStatus(id:)`；读不到时明说「Core 没有回答」而不是继续显示旧值 |
| **Diagnostics §10** | `getPerformanceMetrics` 真实现但无处渲染；Settings 里显示的 Provider 指标是硬编码 0 | TurnProfiler 真数据渲染进右侧运行时详情面（总耗时/首文本/Core 开销/逐工具时间/上下文预算/压缩次数） |
| **Settings 刷新 §15** | `needsCore` 单个布尔，六个页面（Agent Defaults/Context/Code Intelligence/Computer Use/Diagnostics/General）显示实时 Core 数据却声明 `false`，进页不刷新、无未连接横幅 | 每页声明 `needsCoreData` 域集合，进页只刷自己要用那几个域 |
| **Settings 生效 §16** | 横幅只有「关闭」，真正的 reload 藏在诊断页 | 写入携带 `ConfigApply`，横幅直接给「重新加载 Core」/「重启 Core」，接既有 `reloadConfiguration()`/`restartCore()` |

---

## B. 移除的伪成功与 default 实现

`public extension LingXiProtocolService`（`ProtocolService.swift:1219-1422`）原有 **45 个 default**。清点结果：**42 个遮蔽的是 CoreHost 已真实实现的方法**——忘记转发不会编译失败，而是走 default 造答案。

删除全部 42 个，立即暴露出 `InProcessTransport` 缺 15 个转发（Task 域 11 + Agent 域 4），已全部补齐。其中 `createTask` 的 default 会现场 new 一个 `TaskCapsule` 返回 `applied: true`，而 Core 从没注册过这个任务；`submitSideQuestion` 返回 `"Processed side question: …"` 而 CoreHost 有真的模型实现。

`FaultInjectingTransport`（测试替身）原来靠 45 个 default 少写实现，改为全部转发 `underlying`——它之前测的是 default，不是 Core。

九个真伪造里三个没有生产实现（`listAgentPresets`/`listAgentRuns`/`compareMultiRuns`），按 §11.3 保留 default 但改成 `throw unsupportedCommand`，并在代码里写明为什么不能返回 `[]`/`applied:true`。

顺带清掉两个重复 RPC：`getWorkspaceSummary` 是 `getWorkspace` 的别名、共用同一 wire 名；`setModelSelection` 转发到 `selectModel` 且**静默丢弃 `sessionID`**，两者都**没有服务器 case**（stdio 上根本调不通）。

Core 内部两处自造数据：`getRunTrace` 对每个 run 返回固定 `["run.start","run.finish"]`；`getProviderMetrics` 永远返回 0/0/0.0，而 Settings 把它当事实显示——一个跑了一百次 Provider 调用的 runtime 看起来是空闲的。两者改为明确 unsupported，伪造的指标行从界面删除；§10.1 用真的 `getPerformanceMetrics` 满足。

`getTask` 的 default 用 `.resourceNotFound` 把「本 runtime 没有任务存储」误报成「该任务不存在」——分类修正。

闸口：`ProtocolSurfaceParityTests`（7 项）——declared ⇔ dispatched ⇔ forwarded ⇔ implemented 四者必须对同一批名字成立；任何 requirement 重新获得 default 即失败；扩展体内不允许再出现 `applied: true`/`payload: []`/`payload: nil`。

---

## C. Capability 变化

`RuntimeCapabilities.init` 的 `supportedFeatures` **原本默认 `ProtocolFeature.knownFeatures`**，而唯一的生产构造点（`CoreHost.swift:2799`）不传该参数——于是「枚举里有这个 case」等价于「本 runtime 支持」。这正是 §12 禁止的。

改动：默认参数删除，CoreHost 显式写出广播集合；`ContractTests/ProtocolVersionContractTests.swift` 里那条**要求**「默认值必须包含所有 knownFeatures」的测试（它把谎锁成了契约）改写为三条正向断言。

三个 case 直接从枚举删除：`capability.gateway`、`trace.stream`、`trace.query`——它们背后没有任何 RPC、没有分派、没有客户端，`CapabilityGateway` 是 Core 内部 actor（§21 C 类），不该作为协议特性广播。

每个保留的 feature 现在带 `requiredMethods`，`FeatureCoverageManifestTests` 之外的 `ProtocolSurfaceParityTests` 会验证：广播某 feature 时，它点名的每个 method 必须在服务器 case 与客户端 wire 名里都存在；反向若某 feature 已全接线却没广播，同样失败。

新增共享判据 `AttachmentSupport`（LingXiProtocol）：GUI 与 Core 用同一张「哪些媒体类型能被携带」的表，避免各判各的导致「界面收了、Core 丢了」。

---

## D. Settings 覆盖变化

- **`agent.preferredActiveTokens`**：Core 真读、`ContextBudgetPlanner` 真用、GUI 完全不知道。补 `ConfigKey` + `ConfigOptionalNumberField`。它的类型是 `Int?`，且**关闭 = 键不存在**（Core 据此回退到按模型窗口推导），所以不能用普通数字框——写 `0` 会被 planner 当成真实预算。开关关闭时调用 `writeOverride(key, nil)` 把键删掉。
- **`context.eCore.pressureThreshold`**：键与漂移表都有、控件没有。新增 `ConfigFractionField`，硬边界 `(0, 1]`。
- **`l3UseRemaining`**：Core 读 `context.eCore.useRemainingBudget`，GUI 里是个没有任何引用者的孤儿键（`§14` 同类问题）。改名 `eCoreUseRemainingBudget` 并补开关。
- **E-Core 热度文案**：原文「按访问热度决定上下文淘汰与召回优先顺序」与冻结架构冲突。改为「用于 E-Core 召回排序、热点索引与缓存优先级、可观测性；**不参与 P-Core 淘汰决策**——淘汰只由 P 侧 RetentionScore 决定」。
- **七个失效搜索锚点**：`mcp.list`/`plugins.list`/`skills.list`/`hooks.list`/`providers.reload`/`mcp.reload`/`context.fabric` 在界面上不存在对应控件，点搜索结果等于跳空。重定向到真实 section，并由 `SettingsClosureTests.catalogAnchorsResolve` 比对两份清单，删除控件再也不会留下悬空结果。
- **`InspectorTab` / `selectedTab` / `isPresented`**：声明后无任何读取者，随「详情面改用窗口」一并删除。

§22 零容忍项里有一类必须请主人定夺：**背景氛围**与**浮动面板材质**两个选择器把值写进 UserDefaults，但渲染层从不读它——`AtmosphereBackdrop` 画常量渐变、`LXFloatingChrome` 用固定 `LXColor.elevated`，选了不会有任何变化。本轮按 §22 移除（连同无控件无读取者的 `dockPanels`/`dockVisible`，以及只往输入框插一个 `@`/`#` 字符、Core 侧没有 mention 解析的两个「引用」菜单项）。**让它们真正生效属于改全局视觉层，§8 要求先经主人确认**，所以本狐没有擅自接上渲染。

> 主人已确认：允许移除这两个无效控件及其配置入口，但不得借此重排 Settings 或改动主布局。实际删除后 Settings「外观」页只剩「主题」一张卡（配色模式），没有出现需要重排的连带结构；`LXSettingsCard("材质")` 整卡随控件一并删除，卡片间距由既有 `LXSettingsScrollPage` 处理，未改任何布局代码。

闸口：`SettingsClosureTests`（9 项）。

---

## D2. 固定背景视觉资产（Owner 补充冻结）

Owner 在本轮进行中追加了 `GUI 固定背景视觉资产补充冻结`，本节按其 14 条逐条落地。

**资产**：`./Picture/` 下只有一个候选 `background.JPG`（3880×2320 JPEG），无歧义，未触发「停下来问用哪张」。已按 §2 放入正式资源目录：

```
Picture/background.JPG            （主人的源资产，未改动、未删除）
        ↓ 字节一致复制（sha256 已核对）
Apps/macOS/FrontendKit/Resources/Background.jpg
        ↓ Package.swift 既有 .copy("Resources")
Bundle.module  →  GUI 背景
```

`Picture/` 加入 `.gitignore`：把同一个 2.4MB JPEG 在 git 里存两份不是版本管理，是重复存储；**入库的唯一一份是打包用的 `Resources/Background.jpg`**。源目录留在磁盘上，主人换图时覆盖它，再由 `FixedBackgroundAssetTests.packagedCopyMatchesSource` 在本地比对两份是否同源（`Picture/` 不在时该检查自动跳过，不会在 CI 上误报）。

**改动点（仅背景层与设置入口，未触布局）**：

| 冻结条款 | 落地 |
| :--- | :--- |
| §2 运行时不读工作区路径 | `WallpaperBackdrop` 由 `Bundle.module.url(forResource:"Background", withExtension:"jpg", subdirectory:"Resources")` 解析；文件里已不存在 `URL(fileURLWithPath:` |
| §3 显示行为冻结 | `.scaledToFill()` + `.clipped()` 原样保留（等比填满、resize 裁切），底层设计好的三段渐变保留为基色与兜底 |
| §4 删除 Picker | 删掉菜单「选择背景图片…」「恢复内置背景」、`chooseImage()`、`NSOpenPanel` 与 `@AppStorage(pathKey)`；未留禁用态 Picker、未留「Coming Soon」、未留隐藏但写配置的假设置 |
| §5 Legacy 兼容 | `lx.appearance.wallpaperPath` **不再被读取**（旧值因此无法再改变 GUI），也不再被写入；未在启动时加清理逻辑——不读不写即已满足「不恢复可配置能力」 |
| §6 允许前景校准、禁止重设计 | **本狐没有改任何颜色/透明度数值**：这些参数是本轮之前针对同一套底色调好的，而本狐无法截图目视验证，盲调对比度等于用猜测替换已验证的状态。此项留待主人目视或提供截图后再做（见 J 节遗留） |
| §7 运行上下文卡片冻结 | 一字未动，并新增断言专门盯这件事（§13 说固定背景常被当作改布局的借口） |
| §8 最右 Tool Rail 不变 | Browser / Terminal / Git 三案与轨道结构未改，测试断言其存在 |
| §10 Theme 与背景解耦 | 背景无条件加载，`WallpaperStyle.swift` 内不含 `colorScheme` 分支——主题只影响前景 token |
| §11 Reduce Transparency | **按主人的裁定保留原行为**：降低透明度时照片与遮罩一起撤掉，只剩底层渐变。本狐曾按 §11 字面（「调整 overlay 而非换背景」）改成「照片常驻 + 遮罩加深到 0.72→0.95」，并把两种行为用同一批数值渲染成图交给主人对比；主人选定旧行为。该决定已写进 `WallpaperStyle.swift` 注释与 `FixedBackgroundAssetTests.reduceTransparencyKeepsOriginalBehaviour`，防止后人再「修正」回去 |
| §12 缺失必须 Fail Loud | `#if DEBUG` 下资源缺失 `fatalError` 并指名路径；release 返回 nil 回落到稳定渐变；不存在随机图、网络下载或读桌面壁纸的路径 |

闸口：`FixedBackgroundAssetTests`（10 项），覆盖「picker 不得复活」「不得读绝对路径」「不得由主题换图」「不得借背景改布局」。

---

## E. Agent Loop 端到端路径

§18 要求从 GUI 真实入口逐条走到 Core。`AgentLoopEndToEndTests` 用脚本化 Provider 搭起真 CoreHost，16 项，每条都断言"权威落点"而不是"调用返回成功"。它抓出三个本狐先前判断错了的东西：

| 缺陷 | 症状 | 处理 |
| :--- | :--- | :--- |
| **附件根本没进模型请求** | 本狐把附件条目加在 `startTurn` 的 `updatedEntries` 上，而那是 L1 **记账**变量；请求实际由 `runTurn` 里的 `allEntries → projection → compactor → context.modelMessages()` 组装。更糟的是当时的守卫 `if !updatedEntries.contains(…userMessage.id…)` 永远为假——CoreHost 在 `startTurn` 之前就已把用户消息提交进 session store。结果：字节被上传、被解析、然后丢掉 | 已修：`runTurn` 显式接收 attachments，注入到真正组装请求的 `allEntries`。resume 路径不传（文件属于引入它的那一轮） |
| **9 处 `SessionSummary` 构造里 8 处丢 `goal:`** | 除 `setSessionGoal` 外，create / rename / setReasoningEffort / revert / getSession / listSessions / getSnapshot 全都广播 `goal: nil` 的 `.sessionUpdated`。于是任何一次改名或回滚都会把 GUI 的 goal chip 抹掉，而 Core 那边锚点还在、还在往每轮注入。`getSession` 还额外丢 `reasoningEffort`，并把 `mode` 写死 `.build` | 已修：新增 `currentGoal(_:)` 从唯一持有者 `SessionGoalRegistry` 读，9 处全部补齐；`listSessions` 的 `map` 改成循环（同步闭包无法 `await`，这正是它漏掉 goal 的原因） |
| **`Stop` 语义两处不完整** | ① 被排队的 Turn 在 Stop 之后作为新的 root run 起来；② Stop 之后 Core 侧 pending interaction 仍是权威 | **未修**，保留为 `withKnownIssue` 标注，见 J 节 |

§18.1 权威落点核对结果：Mode / Permission / Model 只经 `TurnExecutionIntent`（有专门一条测试断言 wire 上除 intent 之外没有别处携带这三者）；Reasoning 是 session 设置而非 turn 字段；Goal 进 `SessionGoalRegistry` 并经 summary / snapshot / 事件三条路投影；Attachments 进 `UserInput.attachments` 并真的成为模型看到的文本；Worktree 走真 git。

---

## F. 有意保留为 internal-only 的 Core 能力

| 能力 | 为什么没有界面 |
| :--- | :--- |
| `CapabilityGateway` | Core 内部授权汇聚点，没有 RPC 承载。要成为协议特性，需要先有 RPC + 分派 + 实现 |
| `extensions` 的 `install` / `uninstall` / `configure` / `executeCommand` | `ExtensionInfo` 不暴露「该对象能否卸载」「有没有配置 schema」。§9 禁止 runtime 无法回答适用性时给按钮。这些动词属于 `lingxiagent-ops`，调用方显式指名对象 |
| `listAgentPresets` / `listAgentRuns` / `compareMultiRuns` | 无生产实现，改 throw unsupported；有实现再谈界面 |
| `getRunTrace` | 需要 span 存储；现在是明确 unsupported，而不是固定两条 span |
| `getProviderMetrics`（全局） | 没有与会话无关的计数器；真数据是按会话的 `getPerformanceMetrics` |

---

## G. 已废弃、不再广播

- `capability.gateway` / `trace.stream` / `trace.query` 三个协议特性（枚举 case 删除；对端发来旧字符串仍按设计降级为 `.unknown`）。
- `getWorkspaceSummary(envelope:)`、`setModelSelection(envelope:)` 两个重复/失真 RPC（连同 `SetModelSelectionRequest` 类型）。
- 全局 `ProviderMetricsInfo` 展示面与 `RunTraceInfo` 固定 span 内容。

---

## H. 本地测试与构建结果

（待本轮全量回归与 Xcode 构建完成后填入。）

## I. 已知历史 flake

（同上。）

## J. CI_GATE

（同上，冻结文档只允许 `READY` 或 `BLOCKED`。）
