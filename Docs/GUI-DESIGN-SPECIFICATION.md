# LingXiAgent GUI (SwiftUI) 全能力接入与视觉设计规范

> **版本**：v1.2.0-draft  
> **更新时间**：2026-09-24  
> **基准规范**：macOS Human Interface Guidelines (HIG) ✕ LingXi Protocol vNext  
> **最低系统**：macOS 14 Sonoma（`.inspector()`、`Table` 多列排序、`Observation` 依赖此版本）  
> **范围**：本文件只约束 macOS SwiftUI 前端。Linux / Windows 按「按平台做前端」原则另立规范，共享 `LingXiFrontendKit` 的契约层，不共享视图层。  
> **交付方式**：本规范所列全部视图、模块与原生约束在 P28 一次性交付，不分期。

---

## 目录

1. [设计哲学与四大原则](#一设计哲学与四大原则)
2. [视觉语言：系统语义色 ✕ 狐橙](#二视觉语言系统语义色--狐橙)
3. [窗口、Scene 与布局架构](#三窗口scene-与布局架构)
4. [菜单栏与快捷键规范](#四菜单栏与快捷键规范)
5. [统一术语表](#五统一术语表)
6. [八大核心视图功能与接入点矩阵](#六八大核心视图功能与接入点矩阵)
7. [九大支撑模块功能与接入点矩阵](#七九大支撑模块功能与接入点矩阵)
8. [原生实现约束（SwiftUI × AppKit）](#八原生实现约束swiftui--appkit)
9. [反模式清单](#九反模式清单)
10. [现有断裂点与接线差距 (Gap Analysis)](#十现有断裂点与接线差距-gap-analysis)
11. [实施路径与验收清单](#十一实施路径与验收清单)
12. [附录：竞品调研与借鉴映射](#附录竞品调研与借鉴映射)

---

## 一、设计哲学与四大原则

### 原则 1：macOS 原生优先（HIG Native First，如无必要不自己画 UI）

- 容器与控件一律使用系统原生实现：
  - 主窗口采用**两栏** `NavigationSplitView`（侧栏 + 主区），右侧信息区使用 `.inspector()` 修饰符，不作为第三栏；
  - 列表采用 `List` + `.listStyle(.sidebar)`、`DisclosureGroup`、`OutlineGroup`；
  - 控件采用原生 `Button`、`Picker`、`Toggle`、`TextField`、`Gauge`、`GroupBox`、`ProgressView`、`Table`、`Menu`；
  - 窗口顶部使用原生 `.toolbar`，不自绘标题栏、不自绘红绿灯。
- 图标统一使用 `SF Symbols`，字体统一使用系统字体（SF Pro / PingFang SC 自动回落，代码用 SF Mono），全部通过语义字阶（`.body`、`.headline`、`.caption` 等）设置字号。macOS 没有 iOS 式的 Dynamic Type，字号跟随系统设置与侧栏图标尺寸偏好即可。
- 材质只使用系统在侧栏、工具栏、检查器、浮动面板上默认提供的材质；**禁止**在材质之上再铺不透明底色。
- 所有命令必须出现在菜单栏（见第四章）；工具栏、右键菜单、命令面板只是菜单栏命令的快捷入口。

### 原则 2：美学优先（Aesthetics First，拒绝工程参数调试面板）

- 主界面不堆砌底层工程指标（PE 核心负荷、分支预测、L1/L2/L3 原始水位、缓存命中率明细）。
- **信息升华与视觉克制**：
  - 复杂遥测升华为**上下文健康度仪表 (`Gauge`)**；
  - 界面重心放在**业务成果**上：任务目标（Criteria）、执行计划（Action Flow）、交付产物（Artifacts）、文件变更（Diff）与人机决策；
  - **允许且仅允许一个用量数字常驻**：本会话用量（token 或订阅额度占比），作为健康度仪表的副标签。其余明细一律收进「运行轨迹」窗口。
- 专业审计需求通过独立的「运行轨迹」窗口满足（见 3.1、6.7），平时不干扰主界面。

### 原则 3：纯契约解耦与零副作用（Core Boundary Gate）

- `LingXiFrontendKit` 与 `Apps/**` **绝对禁止 `import LingXiCore` 或 `LingXiPlatform`**。
- 前端只与 `LingXiClientVNext` 和 `FrontendRuntime` 通信，通过 IPC 或轻量 InProcessTransport 发送 Envelope 契约。
- UI 进程不直接写磁盘、不触碰私有密钥库。**唯一例外**：用户经 `NSSavePanel` 亲自选定路径的导出操作（Trace JSONL 导出、产物另存为）。这类写入只写用户选定的那一个文件，内容由 Core 经契约下发，UI 不做二次加工。
- 工作区目录选择使用 `NSOpenPanel`，选定结果以契约形式交给 Core，由 Core 负责绑定与权限校验。

### 原则 4：借鉴交互，不借鉴外观

- 调研对象（OpenChamber、ChatGPT、Claude、MiMo Desktop、MiniMax Agent、Qoder）均为 Web 技术栈，**只借鉴其信息组织与交互流程**，视觉一律回到 macOS 原生。
- 原生手感的对标对象是：Xcode（导航器 + 检查器结构、问题导航）、邮件（列表 → 内容的层级）、ChatGPT Classic 原生版（全局快捷键迷你浮窗）。

---

## 二、视觉语言：系统语义色 ✕ 狐橙

品牌气质不靠自定义底色表达，而是靠**唯一的狐橙强调色 + 应用图标 + 空状态插画**表达。所有背景、文字、分割线均使用系统语义色，从而自动适配浅色 / 深色外观、「增强对比度」「降低透明度」等系统设置。

### 1. 调色规范

| 语义角色 | 取值 | 应用场景 |
| :--- | :--- | :--- |
| **窗口 / 内容背景** | 系统默认（`windowBackgroundColor`、`controlBackgroundColor`、`textBackgroundColor`） | 主区、代码框、表格。**不得**以 hex 覆盖 |
| **侧栏 / 检查器 / 工具栏** | 系统默认材质 | 不叠加任何底色 |
| **主字 / 次字 / 弱字** | `.primary` / `.secondary` / `.tertiary`（层级前景样式） | 所有文本与图标。**不得**自定义文字色 |
| **分割线** | `separatorColor` / `Divider()` | 列表、分组、卡片轮廓 |
| **强调色 `AccentColor`**（Asset Catalog，唯一品牌色） | 浅色外观：`#C24A14`<br>深色外观：`#EE6725`<br>增强对比度变体（浅深通用）：`#C24A14` | 主按钮（`.borderedProminent`）、选中态、进度、激活指示、链接 |
| **成功** | 系统 `Color.green` | 测试通过、任务完成徽章 |
| **警告 / 暂停** | 系统 `Color.yellow` | 已暂停、等待回答 |
| **危险** | 系统 `Color.red` | 失败、危险操作确认（`role: .destructive`） |

说明：

- 浅色外观取 `#C24A14`，是为了让 `.borderedProminent` 按钮上的白色文字达到 4.5:1 对比度；深色外观保留品牌原色 `#EE6725`（白字约 3.2:1，与系统橙色同级），并在 Asset Catalog 中提供「High Contrast」变体 `#C24A14`，系统开启「增强对比度」时自动切换。
- 旧调色盘中的 `warmInkBackground` / `warmInkPanel` / `warmInkSurface` / `warmInkElevated` / `milkWhiteText` 系列**全部废弃**。暖墨与奶白只出现在应用图标与空状态插画中。

### 2. 排版

| 用途 | 字体与字阶 |
| :--- | :--- |
| 正文、消息 | 系统字体 `.body` |
| 分组标题、卡片标题 | `.headline` |
| 说明、时间戳、徽章 | `.caption` / `.caption2`，前景 `.secondary` |
| 代码、命令、路径、ID | `.body.monospaced()`（SF Mono） |
| 界面内一律不使用自定义衬线或展示字体 | — |

### 3. 图标

- 仅使用 SF Symbols，按工具类型固定映射：终端 `terminal`、文件 `doc.text`、编辑 `pencil`、网络 `network`、图谱 `point.3.connected.trianglepath.dotted`、MCP `puzzlepiece.extension`、LSP `curlybraces`、浏览器 `safari`、电脑操作 `cursorarrow.rays`、子 agent `person.2`。
- 菜单栏菜单项不加自定义图标，跟随系统默认呈现。
- 状态**不得只靠颜色区分**：每个状态必须是「SF Symbol + 文字标签」，例如 `pause.circle.fill` + 「已暂停」。

### 4. 动效

- 运行中状态统一使用原生 `ProgressView`（小尺寸环形或线性），**不使用**呼吸光效、光晕、发光边框。
- 流式输出不加脉冲光标，以文本自然增长为反馈。
- 所有过渡动画使用系统默认时长；检测到「减弱动态效果」时关闭非必要动画。
- 检测到「降低透明度」时，材质由系统自动替换为实色，前端不做额外处理。

### 5. 无障碍

- 全部交互元素可通过键盘到达（全键盘访问），焦点环使用系统默认。
- 所有仅图标按钮提供 `accessibilityLabel`。
- 时间线消息、工具卡片、审批卡片提供 VoiceOver 分组与自定义操作（如「允许一次」「拒绝」可直接作为 VoiceOver 操作触发）。
- 支持系统文字大小偏好，布局不得因字号变大而截断关键文本。

---

## 三、窗口、Scene 与布局架构

### 3.1 Scene 清单

| Scene | SwiftUI / AppKit 实现 | 用途 |
| :--- | :--- | :--- |
| **主窗口** | `WindowGroup(for: WorkspaceID.self)` | 每个工作区一个窗口，支持系统自动窗口标签页与窗口状态恢复 |
| **设置** | `Settings` scene | ⌘, 打开；分页：通用 / 模型与 Provider / 权限与沙箱 / MCP / 快捷键 / 外观 |
| **运行轨迹** | `Window("运行轨迹", id: "trace")` | 非模态独立窗口，可与主窗口并排观察运行中的 Trace |
| **多模型对比** | `WindowGroup(for: MultiRunID.self)` | Multi-run 结果并排对比与 Fusion 合并 |
| **快问浮窗** | `NSPanel`（`.nonactivatingPanel`、`.floating`）经 AppKit 桥接 | 全局快捷键唤起的轻量提问窗口 |
| **关于** | 系统标准关于面板 | 应用菜单 →「关于 LingXiAgent」 |

### 3.2 主窗口布局

```
┌────────────────────────────── 原生 Toolbar ─────────────────────────────────────────┐
│ [⌃⌘S 侧栏]  工作区名 · ⌥ 分支*  │  任务标题 · 状态徽章 │ ▶︎⏸ 继续/暂停 │ 🔀 Fork │ ⓘ 检查器 │
├──────────────────────┬──────────────────────────────────────────┬──────────────────┤
│ 侧栏 (Sidebar)        │ 主区 (Main Stage)                        │ 检查器 (.inspector)│
│                      │                                          │ ┌──────────────┐ │
│ 🔍 搜索               │ [任务视图切换：计划 │ 执行 │ 报告]         │ │概览│Agent│任务│能力│ │
│                      │                                          │ └──────────────┘ │
│ ▾ LingXiAgent        │ 对话与执行时间线                          │ 概览：            │
│   ▾ Sources/Core     │ • 用户意图                               │  🎯 目标 Checklist │
│     💬 状态机重构     │ • 思考（原生 DisclosureGroup）            │  ◔ 上下文健康度    │
│       ⮑ 任务 #3 ⏸    │ • 助手流式回答（原生 Markdown）           │    副标签：本会话用量│
│   ▾ Docs             │ • 工具卡片（可展开控制台）                │  📦 产物（含版本）  │
│     💬 契约审查       │ • 审批 / 提问 / 决策卡片（GroupBox）       │                  │
│   💬 未分类会话       │   ↳ 标明发起方 AgentRun                   │ Agent：Agent 树    │
│ ▸ openchamber-lingxi │ • 侧问线程（折叠，不进主上下文）           │ 任务：后台任务     │
│                      │                                          │ 能力：MCP / 工具   │
│                      ├──────────────────────────────────────────┤                  │
│                      │ Composer（NSTextView 桥接）               │ [运行轨迹… ⌥⌘L]   │
│                      │ 模式 ▾ 思考 ▾ 权限 ▾ 模型档位 ▾  📎  ⏎/⏹   │                  │
└──────────────────────┴──────────────────────────────────────────┴──────────────────┘
```

### 3.3 工具栏

- 左侧：侧栏开关（系统标准位置）、工作区名与 Git 分支（点击弹出分支菜单）。
- 中部（`.principal`）：当前任务标题 + 任务状态徽章。
- 右侧：继续 / 暂停、Fork、Provider 连接状态（仅在异常时显示黄 / 红图标）、后台任务计数（有任务时显示 `gearshape.2` + 数字）、检查器开关。
- 工具栏支持系统「自定工具栏…」。

### 3.4 侧栏

- 顶部为搜索框（`.searchable(placement: .sidebar)`），按标题与关键词即时过滤。
- 主体为 `OutlineGroup`：**工作区 → 目录分组 → 会话 → 任务**。任务行显示状态符号，Fork 出的任务缩进在源任务之下，并带 `arrow.triangle.branch` 标记。
- 选中项使用系统选中样式（自动带 AccentColor），不自绘高亮边线。
- 侧栏底部不放「设置」「关于」「状态」按钮；这些入口在菜单栏与工具栏中。

### 3.5 检查器

`.inspector()` 内使用分段 `Picker` 切换四个标签，对应快捷键 ⌥⌘1–4：

| 标签 | 内容 |
| :--- | :--- |
| **概览** ⌥⌘1 | 目标 Checklist、上下文健康度 `Gauge`（副标签为本会话用量）、产物列表（含版本） |
| **Agent** ⌥⌘2 | Agent 树与选中 AgentRun 详情（见 6.6） |
| **任务** ⌥⌘3 | 后台任务列表（见 7.3） |
| **能力** ⌥⌘4 | 已挂载 MCP 服务器、已授权工具、已加载 Skills |

检查器底部固定一个「运行轨迹…」按钮，打开独立的运行轨迹窗口。

---

## 四、菜单栏与快捷键规范

### 4.1 菜单栏结构

| 菜单 | 菜单项（快捷键） |
| :--- | :--- |
| **LingXiAgent** | 关于 LingXiAgent；设置… (⌘,)；服务；隐藏 (⌘H)；退出 (⌘Q) |
| **文件** | 新建会话 (⌘N)；新建任务… (⇧⌘N)；新建多模型对比… (⌥⌘N)；打开工作区… (⌘O)；最近使用的工作区 ▸；关闭窗口 (⌘W)；导出运行轨迹… ；产物另存为… (⇧⌘S) |
| **编辑** | 系统标准项（撤销、重做、剪切、复制、粘贴、全选、查找 ⌘F、拼写与语法 ▸、替换 ▸）；复制为 Markdown (⌥⌘C) |
| **显示** | 显示 / 隐藏侧栏 (⌃⌘S)；显示 / 隐藏检查器 (⌥⌘I)；检查器标签 ▸ 概览 (⌥⌘1) / Agent (⌥⌘2) / 任务 (⌥⌘3) / 能力 (⌥⌘4)；任务视图 ▸ 计划 / 执行 / 报告；运行轨迹 (⌥⌘L)；显示 / 隐藏工具栏 (⌥⌘T)；进入全屏幕 (⌃⌘F) |
| **会话** | 发送 (⏎)；作为侧问发送 (⌥⏎)；停止当前运行 (⌘.)；暂停任务；继续任务；从此处 Fork…；回滚上一轮；重命名…；删除会话…（二次确认） |
| **Agent** | 模式 ▸ Build / Plan / Explore；思考等级 ▸ Auto / Off / Low / Medium / High / Max；权限策略 ▸ Ask / Auto / YOLO；模型档位 ▸ 自动 / 快速 / 强力 / 指定模型…；角色预设 ▸；管理角色预设… |
| **审查** | 接受全部改动；放弃全部改动；完成任务但不应用；下一处改动 (⌃⌘↓)；上一处改动 (⌃⌘↑)；让 agent 修改所选内容… |
| **窗口** | 系统标准项；快问浮窗 (全局 ⌥Space，可在设置中修改) |
| **帮助** | LingXiAgent 帮助；键盘快捷键；运行环境诊断（doctor）… |

### 4.2 快捷键规则与冲突说明

| 快捷键 | 行为 | 说明 |
| :--- | :--- | :--- |
| ⏎ / ⇧⏎ | 发送 / 换行 | 默认值。可在「设置 → 通用」改为 ⌘⏎ 发送、⏎ 换行，两套只能二选一 |
| ⌥⏎ | 作为侧问发送 | 见 7.6 |
| ⌘. | 停止当前运行 | 级联停止当前 Run 及其后台子进程，遵循 Mac 惯例 |
| Esc | **只**用于关闭弹出菜单、Popover、Sheet、快问浮窗 | 不承担 TUI 中「全局熔断」语义，防止关闭弹层时误杀任务 |
| ⌥⌘I | 检查器开关 | 不用 ⌘I：⌘I 在 Mac 上是「显示简介」和斜体 |
| ⌃⌘S | 侧栏开关 | 系统标准 |
| ⌘K | 命令面板 | 辅助入口，不替代菜单栏 |
| ⌘T | **不占用** | 留给系统自动窗口标签页（新建标签页） |
| ⌥⌘T | **不占用** | 系统标准「显示 / 隐藏工具栏」 |

---

## 五、统一术语表

GUI、TUI、CLI、README、协议字段必须使用同一套名字。TUI 中 `Tab / Shift+Tab` 的 Normal / Plan / Boost 命名随本规范一并更正。

| 维度 | 取值 | 说明 |
| :--- | :--- | :--- |
| **Agent 模式** | Build / Plan / Explore | Build：可写入；Plan：只读规划并产出 Spec；Explore：只读探索与问答。原「Ask」模式名废弃（与权限策略重名），原「Review」由任务报告与审查流程承担 |
| **思考等级** | Auto / Off / Low / Medium / High / Max | 与 Core `/reasoning` 一致 |
| **权限策略** | Ask / Auto / YOLO | 与 Core `/permissions` 一致；subagent 权限只能是父级的子集 |
| **模型档位** | 自动 / 快速 / 强力 / 指定模型 | 前三档由 Core 按任务类型与成本路由；「指定模型」时显示具体模型名 |
| **任务工作流** | Spec First / 直接执行 | 见 6.1 |
| **执行环境** | 当前目录 / 独立 Worktree | 见 7.2 |
| **任务状态** | pending 待开始 / running 运行中 / paused 已暂停 / waiting 等待回答 / completed 已完成 / failed 失败 / cancelled 已取消 | `waiting` 为新增：任一 AgentRun 在等待人工回答时，任务显示此状态 |
| **任务收尾动作** | 接受 / 放弃 / 完成 | 见 6.8 |

---

## 六、八大核心视图功能与接入点矩阵

### 1. Task 视图（TaskCapsule 任务生命周期 —— 核心中枢）

任务流程借鉴 Qoder Quest Mode：**定义目标 → 计划 → 执行 → 报告 → 收尾**。主区顶部用分段控件在「计划 / 执行 / 报告」三个视图间切换，随任务阶段自动前进。

| 维度 | 规范与技术接入点 |
| :--- | :--- |
| **Core 底层支撑** | • `TaskDomainClient`：`task.create`, `get`, `list`, `pause`, `resume`, `cancel`, `fork`, `watch`, `update_criteria`, `artifact.list`, `report.get`, `finalize(accept \| discard \| finish)`<br>• 数据模型：`TaskCapsule`, `TaskState`, `TaskResumePoint`, `SuccessCriterion`, `TaskLimits`, `TaskSpec`, `TaskPlan`, `TaskReport` |
| **GUI 能力接入点<br>(交互与控制)** | 1. **新建任务 Sheet**（⇧⌘N）：<br>   • 目标描述（多行）与验收标准（可逐条添加）；<br>   • 工作流：`Spec First`（先生成 Spec，确认后执行）/ `直接执行`；<br>   • 执行环境：当前目录 / 独立 Worktree（默认独立 Worktree）；<br>   • 上限：最大步数、最大 token、最长时长，任一触达即暂停并请求人工决定；<br>   • 模型档位与角色预设。<br>2. **Spec 共创**：Spec First 模式下先进入「计划」视图，Spec 以可编辑文档呈现，可与 agent 对话修改，确认后点「开始执行」。Spec 由 Core 持久化在工作区内。<br>3. **执行中追加需求**：执行视图下 Composer 发送的消息作为追加需求并入当前任务，agent 调整计划后继续。<br>4. **Pause / Resume / Cancel**：暂停时落盘 `TaskResumePoint`；取消级联终止该任务下所有 AgentRun 与子进程。<br>5. **Fork**：在时间线任一轮次右键「从此处 Fork…」，克隆任务并在新 Worktree 中继续。<br>6. **Criteria 交互**：手动签核或触发自动验证。 |
| **GUI 显示接入点<br>(呈现与状态)** | 1. **计划视图 (`TaskPlanView`)**：Spec 文档 + 执行计划步骤列表。<br>2. **执行视图 (`ActionFlowView`)**：当前计划步骤（已完成 / 进行中 / 待办）、实时输出、阻塞问题列表；下方为对话时间线。<br>3. **报告视图 (`TaskReportView`)**：改动摘要、测试与验证结果、改动文件清单（可逐个打开 Diff），底部为收尾按钮组（见 6.8）。<br>4. **状态徽章 (`TaskStatusBadge`)**：SF Symbol + 文字，颜色取系统语义色；运行中使用小尺寸 `ProgressView`。<br>5. **上限进度**：执行视图顶部以线性 `Gauge` 显示最接近触达的那一项上限。<br>6. **验收标准看板 (`SuccessCriteriaCard`)**：目标完成列表、判定方式与证据链。 |

### 2. Session 视图（会话组织与生命周期）

| 维度 | 规范与技术接入点 |
| :--- | :--- |
| **Core 底层支撑** | • `SessionDomainClient` / `ApplicationAction`：`createSession`, `switchSession`, `renameSession`, `deleteSession`, `listSessions`, `revertLastTurn`, `undoTurn`, `redoTurn`<br>• 数据模型：`SessionSummary`, `SessionSnapshot`, `SessionViewState` |
| **GUI 能力接入点<br>(交互与控制)** | 1. 新建会话：⌘N 或侧栏工具按钮。<br>2. 切换会话：侧栏点选；支持 ⌘1–9 之外的键盘上下箭头导航。<br>3. 右键原生菜单：重命名、回滚上一轮、撤销 / 重做轮次、在新窗口中打开、删除（`confirmationDialog` 二次确认）。<br>4. 即时检索：侧栏搜索框。 |
| **GUI 显示接入点<br>(呈现与状态)** | 1. 侧栏 `OutlineGroup`：工作区 → 目录分组 → 会话 → 任务。<br>2. 会话行：标题、相对时间（`Text(date, style: .relative)`）、当前模式标签；有待回答的交互时显示 `questionmark.bubble` 标记。<br>3. 选中态使用系统样式。 |

### 3. 执行过程视图（Timeline、流式生成与深度思考）

| 维度 | 规范与技术接入点 |
| :--- | :--- |
| **Core 底层支撑** | • `TurnDomainClient` / `ClientTransport`：`submitTurn`, `submitSideQuestion`, `cancelTurn`, `subscribeStreamFrames`, `subscribeSessionEvents`<br>• 数据模型：`TimelineNode`, `MessageNode`, `ThinkingNode`, `StreamFrame`, `LiveDeltaBuffer`（40ms 合批流式缓冲） |
| **GUI 能力接入点<br>(交互与控制)** | 1. **Composer**（实现约束见 8.1）：<br>   • 发送 ⏎ / 换行 ⇧⌏（可改为 ⌘⏎ 方案）；侧问 ⌥⏎；<br>   • 底栏 `Menu` 型选择器：模式、思考等级、权限策略、模型档位；<br>   • 附件：📎 按钮调用 `NSOpenPanel`，或拖拽文件到窗口；<br>   • `/` 命令补全、`@` 文件补全、`#` 符号补全，均使用原生弹出列表。<br>2. **停止**：生成中发送按钮变为 `stop.fill` 停止按钮（⌘.），触发 `stopCurrentRun`。<br>3. **思考展开 / 折叠**：原生 `DisclosureGroup`。<br>4. **消息右键菜单**：复制、复制为 Markdown、从此处 Fork、回滚到此处。 |
| **GUI 显示接入点<br>(呈现与状态)** | 1. **时间线容器 (`ConversationTimelineView`)**：自动跟随到底部；用户上滚时暂停跟随并显示「回到底部」按钮。<br>2. **流式 Markdown (`AssistantMessageCard`)**：经 `LiveDeltaBuffer` 平滑呈现；代码块使用等宽字体与语法高亮，表格、引用原生渲染。<br>3. **思考卡片 (`ThinkingCard`)**：折叠时显示用时与首句摘要。<br>4. **来源标注**：subagent 产生的消息、工具调用、提问均在卡片头部标注发起方 AgentRun 名称与模型。<br>5. **终结卡片 (`TerminalCard`)**：成功时显示用时与本轮用量；失败时显示诊断与恢复建议。 |

### 4. Tool 调用视图（工具执行与多阶段生命周期）

| 维度 | 规范与技术接入点 |
| :--- | :--- |
| **Core 底层支撑** | • `ToolNode`, `ToolExecutionPhase` (`requested`, `waitingPermission`, `scheduled`, `running`, `completed`, `failed`, `cancelled`), `ToolResultSnapshot`, `RuntimeTraceEvent`<br>• E-Core 旁路：`ContentMetadata`, `getContent(objectID:)` |
| **GUI 能力接入点<br>(交互与控制)** | 1. 展开 / 折叠：点击工具行展开入参与完整输出。<br>2. 复制入参 / 结果 JSON。<br>3. 失败调用一键重试。<br>4. **旁路产物**：输出已旁路到 E-Core 时，卡片显示「输出 N KB 已归档」与「查看完整输出」按钮，按需经 `getContent` 拉取，不预加载。 |
| **GUI 显示接入点<br>(呈现与状态)** | 1. **工具卡片 (`ToolCallCard`)**：工具类型 SF Symbol（映射见 2.3）、状态（符号 + 文字）、耗时。运行中显示小尺寸 `ProgressView` 与滚动 stdout。<br>2. **终端控制台 (`ToolOutputConsole`)**：只读 `NSTextView`，stdout 用 `.primary`，stderr 用系统红色；支持查找 ⌘F。<br>3. **行内 Diff 预览**：文件修改类工具显示折叠的行级对比，点击在审查视图中打开。 |

### 5. 审批（HITL）交互视图（人机协同决策中心）

| 维度 | 规范与技术接入点 |
| :--- | :--- |
| **Core 底层支撑** | • `InteractionDomainClient`：`listPendingInteractions`, `resolveInteraction`<br>• 数据模型：`InteractionSnapshot`（含 `originRunID`、`originRunName`、`originModel`、`isRunSuspended`）、`PermissionRequest`, `QuestionRequest`, `DecisionRequest`, `ApprovalDecision`<br>• **硬约束：严格复用既有通道，不开第二条 UI 交互通道；subagent 发起的一切交互必须回传到主 UI** |
| **GUI 能力接入点<br>(交互与控制)** | 1. **权限审批 (`PermissionApprovalCard`)**：`允许一次`（`.borderedProminent`）、`本会话始终允许`、`拒绝`、`修改后执行`（行内编辑命令或路径）。<br>2. **提问 (`QuestionInteractionCard`)**：单选 / 多选选项、补充输入框、`提交答案`、`交给主 agent 决定`（仅 subagent 提问时出现）。<br>3. **方案决策 (`DecisionConfirmationCard`)**：方案点选、`确认选定方案` / `要求重新规划`。<br>4. **上限触达决策**：任务触达上限时以决策卡片呈现：`提高上限并继续` / `暂停` / `结束并生成报告`。 |
| **GUI 显示接入点<br>(呈现与状态)** | 1. **行内卡片 (`InlineInteractionCell`)**：原生 `GroupBox`，标题行为「SF Symbol + 发起方 AgentRun 名称 + 模型 + 是否已暂停等待」，正文为请求内容与风险说明。<br>2. **待处理提示**：<br>   • 窗口内：工具栏下方原生横幅「有 N 项待处理」，点击滚动定位；<br>   • 窗口外：Dock 图标角标显示待处理数量，并发送系统通知（见 7.8）。 |

### 6. Agent 树与 AgentRun 视图（新增）

对应 Core 的分层 subagent、独立 AgentRun、隔离的历史与工具状态、共享的项目 memory。

| 维度 | 规范与技术接入点 |
| :--- | :--- |
| **Core 底层支撑** | • `AgentRunDomainClient`（待补齐，见 G7）：`run.list`, `run.get`, `run.watch`, `run.pause`, `run.resume`, `run.terminate`, `run.updateConfig`<br>• 数据模型：`AgentRunSnapshot`（`runID`, `parentRunID`, `role`, `modelSelection`, `reasoning`, `permissionPolicy`, `toolGrant`, `contextUsage`, `usage`, `state`）<br>• 角色预设：`AgentPresetDomainClient`（`preset.list`, `create`, `update`, `delete`） |
| **GUI 能力接入点<br>(交互与控制)** | 1. **每个 AgentRun 独立配置**：在详情区用 `Picker` 设置模型档位或指定模型、思考等级；权限策略与工具授权只能在父级范围内收窄，超出父级的选项呈禁用态并附说明。<br>2. **暂停 / 继续 / 终止此分支**（终止需二次确认）。<br>3. **在时间线中只看此 Agent**：一键筛选主时间线。<br>4. **角色预设**：从「Agent → 管理角色预设…」打开 Sheet，预设内容包括名称、指令、模型档位、思考等级、工具子集、Skills。派生 subagent 时可按预设创建。 |
| **GUI 显示接入点<br>(呈现与状态)** | 1. **Agent 树 (`AgentTreeView`)**：检查器 Agent 标签内的 `OutlineGroup`，每行显示角色名、模型、状态符号；等待回答的节点显示 `questionmark.bubble`。<br>2. **AgentRun 详情 (`AgentRunDetailView`)**：模型与思考等级、工具授权清单（未授予的以删除线弱化）、独立上下文用量、本分支用量、共享 memory 读写权限、调用链（父 → 子）。<br>3. **本分支时间线**：该 AgentRun 的关键事件列表（派生、工具调用、提问、完成）。 |

### 7. Runtime Inspector 与运行轨迹（美学优先的信息与健康度）

| 维度 | 规范与技术接入点 |
| :--- | :--- |
| **Core 底层支撑** | • `DiagnosticsDomainClient`：`getDiagnostics`, `getPerformanceMetrics`, `getRunTrace`, `trace.query`, `trace.tail`<br>• 数据模型：`RuntimeTraceEvent`, `RuntimeTraceKind`, `TraceTokenUsage`, `TraceAttributeValue` |
| **GUI 能力接入点<br>(交互与控制)** | 1. 检查器开关 ⌥⌘I，标签切换 ⌥⌘1–4。<br>2. **运行轨迹窗口**（⌥⌘L）：非模态独立窗口，可与主窗口并排实时观察。<br>3. 轨迹窗口内按 AgentRun、Kind、时间范围筛选；「导出…」经 `NSSavePanel` 写出 JSONL。 |
| **GUI 显示接入点<br>(呈现与状态)** | 1. **上下文健康度 (`ContextHealthGauge`)**：原生环形 `Gauge` 展示上下文充裕度；副标签为本会话用量（原则 2 允许的唯一常驻数字）。<br>2. **能力清单 (`ActiveCapabilitiesList`)**：MCP 服务器（连接状态 + 传输方式）、已授权工具、已加载 Skills；需要重新授权的 MCP 显示「重新授权」按钮。<br>3. **轨迹表格 (`TraceTableView`)**：原生 `Table`，列为时间戳、AgentRun、Kind、Span 耗时、Token、脱敏合规徽章；支持列排序与复制行。 |

### 8. Artifacts 产物与变更审查视图

收尾语义借鉴 Qoder：改动默认发生在独立 Worktree 中，「接受」才真正落到工作区，彻底消除「采纳 / 放弃」语义不清的问题。

| 维度 | 规范与技术接入点 |
| :--- | :--- |
| **Core 底层支撑** | • `TaskDomainClient.listArtifacts`, `artifact.versions`, `artifact.compare`, `finalize`<br>• `WorkspaceDomainClient.diff`, `worktree.apply`, `worktree.discard`, `getContentMetadata`, `getContent`<br>• 数据模型：`TaskArtifact`（含 `version`, `parentVersion`）、`ArtifactKind` (`diff`, `testResult`, `reviewVerdict`, `filePatch`, `diagram`, `spec`, `report`) |
| **GUI 能力接入点<br>(交互与控制)** | 1. **收尾三动作**（报告视图底部）：<br>   • **接受**：把 Worktree 中的改动应用到工作区并归档任务；<br>   • **放弃**：丢弃全部改动，工作区保持任务开始前的状态；<br>   • **完成**：不应用改动直接关闭任务（适用于无代码改动的任务）。<br>   若任务选择「当前目录」执行环境，改动已直接写入，此时「放弃」等价于回滚到 Core 在改动前自动创建的备份，按钮文字相应改为「回滚到备份」。<br>2. **逐文件 / 逐块处理**：在审查视图中可对单个文件或单个改动块执行接受 / 放弃。<br>3. **选中局部让 agent 修改**：在 Diff 或产物预览中选中代码行，右键「让 agent 修改所选内容…」，输入要求后作为追加需求提交，附带所选范围。<br>4. **版本历史**：每次修改产生新版本；可在版本列表中选择两个版本并排对比，或回退到任一版本。<br>5. **Quick Look**：选中产物按空格键调用系统 Quick Look 预览。<br>6. **另存为**：⇧⌘S，经 `NSSavePanel`。 |
| **GUI 显示接入点<br>(呈现与状态)** | 1. **产物面板 (`ArtifactsPanelView`)**：列表显示类型图标、文件名、版本号、生成时间、大小；支持按类型筛选。<br>2. **审查视图 (`CodeDiffViewer`)**：左侧改动文件列表（标注由哪个 AgentRun 修改），右侧 Diff；支持统一 / 并排两种显示；⌃⌘↑↓ 在改动块间跳转。<br>3. **测试裁决 (`TestVerdictView`)**：通过 / 失败统计与日志。<br>4. **任务报告 (`TaskReportView`)**：改动摘要、验证结果、文件清单、权限审计记录（何时、由谁、批准了什么）。 |

---

## 七、九大支撑模块功能与接入点矩阵

### 1. Provider 与模型管理（设置 → 模型与 Provider）

- **Core 支撑**：`ProviderDomainClient`、`ModelDomainClient`、`CredentialBroker`（只读授权状态，永不下发密钥明文）。
- **模型列表来源**：由 Core 从 `models.lingxifox.cn` 拉取并缓存，GUI 只展示 Core 下发的列表。规范与代码中**不写死任何模型名**。
- **两层选择**：
  - 默认层：模型档位「自动 / 快速 / 强力」，由 Core 按任务类型、复杂度与成本路由；
  - 高级层：「指定模型」，列出 Provider 下的具体模型，并附能力徽章（Vision / Reasoning / Tool Use / 上下文长度）。
- **能力接入点**：Provider 列表（添加 / 编辑 Base URL、配置 API Key 经 CredentialBroker 写入保险箱、测试连通性）；订阅登录（Codex OAuth、Claude 订阅）通过系统浏览器回调完成。
- **显示接入点**：Provider 健康状态仅在异常时出现在工具栏；设置页内显示每个 Provider 的连接状态与最近错误。

### 2. Workspace 与 Worktree

- **Core 支撑**：`WorkspaceDomainClient`（`get`, `set`, `diff`, `create`, `fork`, `bind`, `worktree.create`, `worktree.list`, `worktree.apply`, `worktree.discard`, `worktree.prune`）。
- **能力接入点**：
  - 打开工作区 ⌘O（`NSOpenPanel`），每个工作区一个窗口；
  - 工具栏分支标签点击弹出分支菜单；
  - 「设置 → 通用」配置 Worktree 初始化脚本（新建 Worktree 后自动执行依赖安装等准备工作）；
  - 已完成且无改动的 Worktree 由 Core 自动清理，有改动的保留到任务收尾。
- **显示接入点**：工具栏显示工作区名、路径徽章（本地 / 远程 / Fork）、Git 分支（有未提交变更时带 `*`）；任务行显示其所在 Worktree。

### 3. 后台任务

- **Core 支撑**：`FrontendRuntime.getBackgroundTasks()`, `terminateBackgroundTask(id:)`。
- **能力接入点**：检查器「任务」标签（⌥⌘3），或点击工具栏后台任务计数；每行提供「终止」按钮（`role: .destructive`）。
- **显示接入点**：命令行、所属 AgentRun、PID、已运行时长、CPU 与内存；模型因等待后台任务而休眠时，在对应 AgentRun 上显示「休眠中」。

### 4. 命令面板

- **Core 支撑**：`FrontendRuntime.availableCommands`, `executeCommand(rawInput:)`。
- **能力接入点**：⌘K 唤起居中搜索框（系统材质），模糊匹配菜单栏命令与内置 `/` 命令（`/help`, `/mode`, `/compact`, `/diff`, `/doctor` 等），每项显示对应快捷键。
- **约束**：命令面板中的每一项都必须在菜单栏中有对应菜单项。

### 5. 快问浮窗（Quick Ask Panel）

借鉴 ChatGPT Classic 原生版的全局快捷键迷你窗口。

- **实现**：AppKit `NSPanel`（非激活、浮动层级），经 `NSViewRepresentable` 承载 SwiftUI 内容。
- **唤起**：全局快捷键 ⌥Space（可在设置中修改或关闭）；Esc 关闭。
- **能力**：单行起步、可自动增高的输入框；目标可选「新建会话」或「发到当前工作区的活动会话」；回答以紧凑形式显示在浮窗内，可「在主窗口中继续」。
- **约束**：快问默认使用 Explore 模式与 Ask 权限策略，不在浮窗内执行写操作。

### 6. 侧问（Side Question）

借鉴 Claude Code 的 `/btw`：在 agent 执行长任务时提出旁支问题，不打断主线，也不污染主线上下文。

- **Core 支撑**：`TurnDomainClient.submitSideQuestion`（待补齐，见 G8）——基于当前上下文快照创建临时只读 Run，回答不写回主 AgentRun 的历史。
- **能力接入点**：Composer 中 ⌥⏎ 发送，或在「会话」菜单中选择「作为侧问发送」。
- **显示接入点**：时间线中以折叠的「侧问」线程呈现，标注「不计入主上下文」；可一键「将此回答并入主线」。

### 7. 多模型对比（Multi-run 与 Fusion）

借鉴 OpenChamber 的 Multi-run 与 Fusion。

- **Core 支撑**：`MultiRunDomainClient`（待补齐，见 G9）：`multirun.create`（同一任务分发给 2–5 个模型，每个在独立会话与独立 Worktree 中执行）、`multirun.watch`、`multirun.select`、`multirun.fuse`。
- **能力接入点**：文件 → 新建多模型对比…（⌥⌘N）；在新建 Sheet 中选择 2–5 个模型；结果窗口中可「采用此结果」或勾选多个结果的部分改动后「合并为新会话」（Fusion）。
- **显示接入点**：独立对比窗口，横向并排显示每个模型的状态、用时、用量、测试结果与改动文件；点击任一文件并排对比各模型的 Diff。

### 8. 通知与 Dock

- 使用 `UserNotifications`：任务完成、任务失败、有待处理的审批或提问、任务触达上限时发送系统通知；点击通知聚焦对应窗口并定位到对应卡片。
- **通知中不提供「允许」「拒绝」等快捷操作**，审批必须在窗口内看到完整请求后再决定。
- Dock 图标角标显示待处理交互数量。
- 任务在 `LingXiCoreHost` 中运行，关闭窗口或退出 GUI 后任务继续执行；再次打开时从 Core 恢复状态。退出时若有运行中的任务，弹出标准提示说明任务会在后台继续。

### 9. 首次启动引导（Workspace First）

借鉴 MiniMax 桌面端「先选工作目录」的顺序，与 Mac 上基于文档的应用习惯一致。

1. 欢迎页：应用图标与一句定位说明；
2. 选择工作区（`NSOpenPanel`）；
3. 登录订阅或配置 Provider；
4. 运行环境诊断（doctor）：以原生列表显示 ripgrep、沙箱能力、LSP、格式化器等检测结果，缺失项附安装指引；
5. 进入主窗口，Composer 获得焦点。

---

## 八、原生实现约束（SwiftUI × AppKit）

纯 SwiftUI 在 macOS 的文本编辑、撤销等基础能力上仍有缺陷，以下组件**必须**使用 AppKit 桥接实现：

### 1. Composer 输入框

- 使用 `NSTextView`（经 `NSViewRepresentable`），不使用 SwiftUI `TextEditor`。
- 必须保证：系统级撤销 / 重做正确、输入法（中文拼音、候选框）正常、拖拽文件与图片进入输入框、粘贴富文本自动降为纯文本。
- **关闭**智能引号、智能破折号、自动文本替换、自动拼写更正（代码与命令场景下会破坏内容）；保留拼写检查下划线。

### 2. 代码、Diff 与控制台

- 使用只读 `NSTextView`（TextKit 2）渲染代码、Diff 与终端输出，支持查找 ⌘F、选择复制、大文本虚拟化滚动。
- 语法高亮在后台线程计算，渲染不阻塞主线程。

### 3. 表格

- 运行轨迹、后台任务、多模型对比的明细使用原生 `Table`，支持列排序、多选、复制。

### 4. 窗口行为

- 支持窗口状态恢复（重启后恢复打开的工作区窗口、选中会话、检查器标签）。
- 支持系统自动窗口标签页。
- 支持拖拽文件或文件夹到 Dock 图标：文件夹打开为工作区，文件作为附件加入当前会话。

### 5. 性能

- 时间线使用懒加载列表，长会话下滚动保持流畅。
- 流式文本经 `LiveDeltaBuffer` 40ms 合批后刷新，避免逐 token 触发视图更新。

---

## 九、反模式清单

以下做法**禁止**出现在 LingXiAgent GUI 中：

| # | 反模式 | 来源教训 |
| :-: | :--- | :--- |
| A1 | 自定义窗口背景色、面板底色、文字色覆盖系统语义色 | 会让界面失去深浅色适配，退化为网页观感 |
| A2 | 呼吸光效、光晕、发光边框、渐变描边 | 与 HIG 克制原则冲突 |
| A3 | 自绘标题栏、红绿灯、分段控件、下拉菜单 | 典型 Electron 做法 |
| A4 | 把设置、关于、状态按钮放在侧栏底部 | 应在菜单栏、Settings scene 与工具栏 |
| A5 | 默认进入非聊天的模式，或把基础对话藏进子菜单、底部弹窗 | ChatGPT 超级应用的主要差评点 |
| A6 | 设置页堆满开关 | 设置按主题分页，每页只放该主题的必要项 |
| A7 | 把应用做成「小操作系统」：内嵌浏览器面板、底部终端面板、侧任务面板层层叠加 | 同上 |
| A8 | 在界面上直接暴露大量模型名让用户每次挑选 | 以档位为默认，指定模型收进高级层 |
| A9 | Esc 触发破坏性操作 | Esc 只负责关闭 |
| A10 | 通知中直接批准权限 | 审批必须看到完整请求 |
| A11 | 把任何竞品的界面「翻译」成 SwiftUI | 设计从 Mac 惯例出发重做 |

---

## 十、现有断裂点与接线差距 (Gap Analysis)

| # | 现有断裂点 | 严重程度 | 解决方案与重构目标 |
| :-: | :--- | :-: | :--- |
| **G1** | **审批 (HITL) 交互断路**：时间线内仅有假文本展示，无确认 / 拒绝按钮 | 🚨 **阻断级** | 新建 `InlineInteractionCell`，绑定 `InteractionDomainClient`；卡片标注发起方 AgentRun |
| **G2** | **缺少 TaskCapsule 任务中心**：侧栏只有平铺会话，无任务状态机与控制 | 🚨 **阻断级** | 侧栏改为「工作区 → 目录 → 会话 → 任务」树；实现计划 / 执行 / 报告三视图与收尾三动作 |
| **G3** | **Inspector 全是写死的假数字**，查不到真 Trace | 🚨 **阻断级** | 改为健康度 `Gauge` + 四标签检查器；运行轨迹改为独立窗口，接入 `trace.query` |
| **G4** | **执行过程无法中断**：生成时无 Stop 按钮 | ⚠️ **高危 UX** | 发送按钮在生成态变为停止按钮，绑定 ⌘. |
| **G5** | **Tool 输出只有单行摘要** | ⚠️ **高危 UX** | 可展开控制台、stdout / stderr 分流、E-Core 旁路内容按需拉取、行内 Diff |
| **G6** | **视觉不合规**：冷蓝紫青多强调色 + 自制 Glass 画板（`LingXiGlass`） | 🎨 **视觉违规** | 删除 `LingXiGlass` 与自定义调色盘；改用系统语义色 + 唯一 AccentColor |
| **G7** | **没有 Agent 树与 AgentRun 视图**：无法逐个 Run 配置模型，subagent 提问无法回传 | 🚨 **阻断级** | 补齐 `AgentRunDomainClient`、`AgentPresetDomainClient`；实现 6.6 |
| **G8** | **缺少侧问通道** | ⚠️ **功能缺失** | Core 补齐 `submitSideQuestion`（临时只读 Run，不写回主历史）；实现 7.6 |
| **G9** | **缺少多模型对比** | ⚠️ **功能缺失** | Core 补齐 `MultiRunDomainClient`（含 Fusion）；实现 7.7 |
| **G10** | **缺少 Worktree 隔离与收尾语义** | 🚨 **阻断级** | `WorkspaceDomainClient` 补齐 `worktree.*`；`TaskDomainClient` 补齐 `finalize`、`report.get` |
| **G11** | **缺少产物版本** | ⚠️ **功能缺失** | `TaskArtifact` 增加 `version` / `parentVersion`；补齐 `artifact.versions`、`artifact.compare` |
| **G12** | **没有菜单栏命令体系与 Settings scene** | 🚨 **阻断级** | 按第四章实现完整菜单栏；设置迁入 `Settings` scene |
| **G13** | **Composer 使用 SwiftUI 文本控件** | ⚠️ **高危 UX** | 按 8.1 改为 `NSTextView` 桥接 |
| **G14** | **术语不统一**：模式、思考等级在 GUI / TUI / README 中各有一套 | ⚠️ **一致性** | 按第五章统一；同步修改 TUI 的 Tab 模式命名与 README |
| **G15** | **模型列表写死** | ⚠️ **一致性** | Core 从 `models.lingxifox.cn` 拉取；GUI 删除所有硬编码模型名 |
| **G16** | **无通知、Dock 角标、窗口恢复、快问浮窗** | ⚠️ **原生体验缺失** | 按 7.5、7.8、8.4 实现 |

---

## 十一、实施路径与验收清单

### 1. P27：能力网关与安全封口（前置）

- 交付 `CredentialBroker` 与 `CapabilityGateway`；
- 修复 MCP 环境变量注入，子进程仅下发 `LINGXI_GATEWAY_TOKEN`；
- 强制 subagent 授权单调收窄（`child ⊆ parent`）；
- 为 GUI 的设置、权限审批与凭据调用建立唯一权威基石。

### 2. P28：契约补齐与 macOS 原生界面一次性交付

- Core / 契约层：补齐 G7–G11、G15 所列全部 RPC 与数据模型；
- 拆分 `lingxiagent`（交互前端）与 `lingxiagent-ops`（运维 CLI）；
- `LingXiFrontendKit` 引入正式依赖，创建 `RuntimeFrontend` 并存层；
- 按本规范一次性交付第三至第八章全部内容；
- 删除 `LingXiGlass.swift`、旧调色盘与 `FakeFrontendRuntime.swift`；
- 同步完成 G14 的 TUI 与 README 术语更正。

### 3. 验收清单

- [ ] 主窗口为两栏 `NavigationSplitView` + `.inspector()`，无自绘标题栏与控件
- [ ] 全部颜色来自系统语义色与 AccentColor；浅色 / 深色 / 增强对比度 / 降低透明度四种设置下均显示正常
- [ ] 第四章所列菜单项全部存在且快捷键生效；命令面板每项都能在菜单栏找到
- [ ] 设置为独立 `Settings` scene，⌘, 可打开
- [ ] 任务可走通「新建 → Spec → 执行 → 报告 → 接受 / 放弃 / 完成」全流程，默认在独立 Worktree 中执行
- [ ] 任务上限触达时暂停并弹出决策卡片
- [ ] subagent 的提问与权限请求出现在主时间线，并标注发起方
- [ ] 每个 AgentRun 可独立设置模型与思考等级；权限与工具只能收窄
- [ ] 侧问回答不进入主 AgentRun 上下文
- [ ] 多模型对比可并行 2–5 个模型，并可 Fusion 合并
- [ ] 产物有版本历史，可两两对比与回退；空格键可 Quick Look
- [ ] 运行轨迹窗口为非模态独立窗口，可筛选、排序、经 `NSSavePanel` 导出
- [ ] Composer 为 `NSTextView`：撤销正确、中文输入法正常、智能引号关闭
- [ ] 关闭 GUI 后任务继续运行；完成与待处理事项有系统通知与 Dock 角标
- [ ] 快问浮窗可全局唤起，Esc 关闭
- [ ] VoiceOver 可完整操作审批卡片；所有状态均为「符号 + 文字」
- [ ] `Apps/**` 与 `LingXiFrontendKit` 中无 `import LingXiCore` / `import LingXiPlatform`（ContractTests 门禁）
- [ ] 代码与界面中无硬编码模型名
- [ ] GUI / TUI / README 术语一致

---

## 附录：竞品调研与借鉴映射

调研时间：2026-09。调研对象均为 Web 技术栈（Electron / Tauri / VS Code 分支），本规范只采纳其交互与信息组织。

| 来源 | 借鉴点 | 落地位置 |
| :--- | :--- | :--- |
| **Qoder**（Quest Mode） | Spec First / 直接执行两种工作流；本地执行用 git worktree 隔离；Action Flow 视图（计划、实时输出、阻塞问题）；执行中可追加需求；任务报告 + 接受 / 放弃 / 完成三种收尾 | 6.1、6.8、7.2 |
| **OpenChamber** | Session Goals：每轮后检查目标，直到完成、受阻或触达上限，关闭 App 后继续；Multi-run 多模型并行对比与 Fusion 合并；可分支的时间线与撤销 / 重做 | 6.1、6.2、7.7、7.8 |
| **MiniMax Agent** | 「专家」可复用配置模板（指令、模型偏好、Agent 行为）；可查看子 Agent 调用链；首次启动先选工作目录 | 6.6、7.9 |
| **小米 MiMo Desktop** | 产物选中局部定向修改；多版本记录、回退与对比；按任务类型与成本自动选择模型与 Agent | 6.8、7.1 |
| **Claude Code 桌面端** | `/btw` 侧问：不打断当前任务；并行会话 Git 隔离；可视化 Diff 审查 | 7.6、7.2、6.8 |
| **ChatGPT Classic（原生版）** | 全局快捷键唤起的迷你浮窗 | 7.5 |
| **ChatGPT 新版（2026-07 起）** | 「更快 ↔ 更聪明」档位代替模型名（正面）；默认进入 Work 模式、Chat 藏进子菜单与底部弹窗、设置开关过多、内嵌浏览器与终端面板（反面） | 7.1；A5–A8 |
| **Claude 桌面端** | 设计本身非原生、忽视 Mac 界面惯例（反面） | A1–A4、A11 |
