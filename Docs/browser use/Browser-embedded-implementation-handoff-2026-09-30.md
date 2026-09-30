# LingXiAgent 浏览器统一与原生内嵌实现交接

日期：2026-09-30。面向：后续实现 Agent。

本文件整理开源实现、当前工程入口、既有验证和下一轮最小实验。目标是让 GUI 用户与 Agent 操作同一个浏览器页面，最终评估能否在 SwiftUI 主窗口内原生展示。本文是实现提案，不代表内嵌方案已通过验收。

当前交付决策仍是独立受管 Chromium + 项目已有 Playwright。后续内嵌实验应独立开展，不阻塞 GUI/Core 深度连接和 iOS GUI。本文不撤销该决策；完整依据见 [交付决策](Browser-delivery-decision-2026-09-30.md)。

## 1. 产品目标与边界

- 保留现有 SwiftUI/AppKit macOS GUI，包括已经选定的 B 版玻璃与应用内静态壁纸。
- 用户看到、手动操作和 Agent 控制的应是同一个页面实例，共享导航、DOM 状态和该会话的登录态。
- GUI 提供明确的用户接管与 Agent 恢复操作；接管期间 Agent 不得继续写入页面。
- Core 通过浏览器会话协议调度操作，TUI 和 GUI 复用相同权限与生命周期语义。
- 浏览器初始化按需发生；闲置或隐藏时不持续抓图、串流或刷新整个 GUI。
- iOS 首阶段作为桌面/服务端 Core 的客户端，展示能力与会话状态；不承诺本机运行 Chromium/Node，也不把远端页面截图称为原生可交互内嵌。

验收时必须分别标明：主窗口原生内嵌、独立浏览器窗口、截图预览。独立 WKWebView 即使打开相同 URL，也不能证明与 Agent 共用页面。

本阶段不扩展 desktop computer-use，不更换整个 GUI 框架，不批量重构无关 Core 模块。新增外部依赖、服务或运行环境仍须按项目约定取得明确许可；本文件本身不授权安装。

## 2. 开源实现：可以借鉴什么

以下是 2026-09-30 检查的源码快照，未启动这些项目、未做性能或可靠性测试。链接固定到 commit；接手时如查新版本，应记录新 commit 和行为差异。

| 项目 | 展示方式 | 控制方式 | 借鉴点与限制 |
| --- | --- | --- | --- |
| AionUi | Electron 主界面内 `<webview>` | 页面 `webContentsId` → 单目标 CDP 桥 → `chrome-devtools-mcp` | 用户和 Agent 共用页面；桥包含目标/会话协议适配，不能直接认定兼容完整 Playwright、多标签或所有弹窗 |
| Craft Agents | 专用 Electron `BrowserWindow` 内多个 `BrowserView` | 对网页 `webContents.debugger` 直接发送 CDP 命令 | 同页控制、独立窗口、浏览器会话管理；它不是主聊天窗口里的内嵌面板 |
| OpenHands | 本次检查的 browser panel 使用 `<img>` | 面板消费 URL 和截图状态 | 可参考执行预览，不是该面板内的原生可交互网页 |
| Cline | 聊天内展示截图 | 后端 Puppeteer 启动或连接浏览器，动作后截图 | 浏览器执行与 GUI 预览分离；截图组件点击是打开图片，不是网页点击 |
| MonoCode | Tauri/Wry 的 WKWebView 承载自身 GUI | 本次源码检查未找到同类 Agent 浏览器/CDP 链路 | 可参考玻璃视觉，不能据此断言存在可复用 browser-use 内嵌实现 |

### AionUi 的同页链路

```text
GUI 内 WebviewHost 的 Electron webview
  -> dom-ready 获取 getWebContentsId()
  -> IPC 报告当前浏览器页面实例
  -> 主进程 webContents.fromId() 定位页面
  -> webContents.debugger.attach() / sendCommand()
  -> localhost 单目标 CDP 桥
  -> chrome-devtools-mcp
  -> Agent
```

桥接层拒绝将非 `webview` 的主窗口作为控制目标，包含 CDP 事件与 sessionId 转发。MCP 启动器接到该桥的 `--browser-url`，缺少桥参数时拒绝启动，避免悄悄另开浏览器。这些是实际源码行为，不是对完整安全性的审计结论。

- [WebviewHost：页面实例报告与内嵌标签](https://github.com/iOfficeAI/AionUi/blob/6744099b279b991c17e31c243f0920477bd31cb6/packages/desktop/src/renderer/components/media/WebviewHost.tsx)
- [cdpBridge：页面选择、调试连接和协议转发](https://github.com/iOfficeAI/AionUi/blob/6744099b279b991c17e31c243f0920477bd31cb6/packages/desktop/src/process/resources/builtinMcp/cdpBridge.ts)
- [browserServer：连接该桥的 MCP 启动器](https://github.com/iOfficeAI/AionUi/blob/6744099b279b991c17e31c243f0920477bd31cb6/packages/desktop/src/process/resources/builtinMcp/browserServer.ts)

### Craft 与其他来源

Craft 的浏览器 manager 创建专用窗口、网页视图和 `BrowserCDP(pageView.webContents)`。控制器使用 Electron debugger API；该路径没有依赖 Playwright 来驱动页面。另有远端代理将浏览器调用转发给具备该能力的桌面客户端，可参考 GUI/Core 分离，但首个本地验证不需要照搬其完整远程架构。

- [Craft 窗口管理](https://github.com/craft-ai-agents/craft-agents-oss/blob/73bd9c2a3573158bea880984eb8d5fdb41e0cac2/apps/electron/src/main/browser-pane-manager.ts)
- [Craft 直接 CDP 控制](https://github.com/craft-ai-agents/craft-agents-oss/blob/73bd9c2a3573158bea880984eb8d5fdb41e0cac2/apps/electron/src/main/browser-cdp.ts)
- [Craft 远端浏览器调用代理](https://github.com/craft-ai-agents/craft-agents-oss/blob/73bd9c2a3573158bea880984eb8d5fdb41e0cac2/packages/server-core/src/sessions/RemoteBrowserPaneManager.ts)
- [OpenHands 截图面板](https://github.com/OpenHands/OpenHands/blob/1ec86616bc0511b1e56269fd6ba5872438f4fb7f/src/components/features/browser/browser-snapshot.tsx)
- [Cline 浏览器控制](https://github.com/cline/cline/blob/3435f72fcf4cb843bee946b8f9e981683564c9e3/apps/vscode/src/services/browser/BrowserSession.ts)、[截图组件](https://github.com/cline/cline/blob/3435f72fcf4cb843bee946b8f9e981683564c9e3/apps/vscode/webview-ui/src/components/chat/BrowserSessionRow.tsx)
- [MonoCode macOS 宿主](https://github.com/hardbeat920/monocode/blob/b4f5befbc27d148f08125a060980ea4a446d578d/src-tauri/src/macos.rs)

如果以后获得另做 Electron 原型的授权，应评估 `WebContentsView`，不要直接复制旧视图 API：Electron 官方已弃用 [BrowserView](https://www.electronjs.org/docs/latest/api/browser-view)，并建议避免新增使用 [webview 标签](https://www.electronjs.org/docs/latest/api/webview-tag)。这些组件无法直接作为 SwiftUI 的原生视图复用。

## 3. 当前工程入口

本节核对的是当前工作区，HEAD 为 `b861395357ad5a23821c6bfd9962ac0993830a78`，存在大量未提交修改与 Apps 目录迁移。不能用 HEAD 单独代表工作区，接手前必须重新检查 diff，保留已有修改。

| 位置 | 当前职责 | 接手要点 |
| --- | --- | --- |
| [WarmToolPane.swift](../Apps/macOS/FrontendKit/Components/WarmToolPane.swift) | `WarmBrowserModel` 创建独立 WKWebView，`WarmBrowserPane` 展示它 | 当前明确标为独立浏览会话，尚未连接 Agent；最终如有同页宿主，应替换其展示来源 |
| [BrowserSessionManager.swift](../Sources/LingXiCore/Modules/Interaction/BrowserSessionManager.swift) | 会话管理、navigate/act/capture/reset/close | 保留共享 manager 与防陈旧引用语义，先扩展已有路径 |
| [BrowserHostClient.swift](../Sources/LingXiCore/Modules/Interaction/BrowserHostClient.swift) | Node sidecar 的 stdio JSON-RPC、握手、超时、取消 | 不应把真实模式失败伪装成 mock 成功；新宿主需明确能力与错误 |
| [browser-host/index.mjs](../Sidecars/browser-host/index.mjs) | Playwright 宿主，当前 `headless: true`，会话创建 Context/Page | 当前代码未实现可见窗口交付；独立窗口方案也仍需产品接入 |
| [BrowserTools.swift](../Sources/LingXiCore/Modules/Tool/BrowserTools.swift) | `browser_navigate`、`browser_act` | 不绕过已有权限、引用版本检查与取消链 |
| [CoreHost.swift](../Sources/LingXiCore/App/CoreHost.swift) | 共享 browser manager；`getBrowserSessions`、`getBrowserCapture` | 是现有产品连接入口，不另造第二套会话注册表 |
| [BrowserSessionTypes.swift](../Sources/LingXiProtocol/BrowserSessionTypes.swift) | URL、title、tabID、observationVersion 等只读投影与 capture 请求 | 目前没有暂停、控制方、恢复或 loading 契约，不能在 GUI 虚构状态 |
| [BrowserDomainClient.swift](../Sources/LingXiClient/VNext/Domains/BrowserDomainClient.swift) | sessions/capture 查询 | wire 名为 `browser.sessions`、`browser.capture`；新控制命令名称须设计和实现，不能当作已存在 |
| [BrowserSessionManagerTests.swift](../Tests/LingXiAgentTests/BrowserSessionManagerTests.swift)、[BrowserCorrectnessTests.swift](../Tests/LingXiAgentTests/BrowserCorrectnessTests.swift) | 现有会话和浏览器正确性检查 | 复用相关测试；mock 通过不代表原生宿主通过 |

源码的 package.json 声明范围是 `playwright: ^1.40.0`；既有实验使用本机已安装的 1.63.0。接手时核对 lockfile 与实际安装版本，不把实验版本当作仓库已锁定版本。

## 4. 已有实验与不得遗漏的失败

按以下顺序阅读：[基础驱动验证](Browser-unification-PoC-2026-09-30.md) → [CEF 原型](Browser-unification-CEF-PoC-2026-09-30.md) → [分层复测](Browser-unification-CEF-layered-retest-2026-09-30.md) → [最终交付决策](Browser-delivery-decision-2026-09-30.md)。较早报告里的下一步建议已被最终决策部分覆盖。

| 路径 | 已验证 | 失败或未验证 |
| --- | --- | --- |
| 受管独立 Chrome + Playwright | 自动输入、同 document 二次自动编辑、3 次弹窗操作、正常 context.close 和退出 | 人工接管、GUI/Core 权限链、中文输入法、GPU、iOS 均 NOT RUN |
| 原生 Alloy sample 与 SwiftUI 内嵌 Alloy | 主页面与原生弹窗显示、原生输入；主页面 Playwright 操作 | Playwright 新弹窗卡住；优雅退出失败，需要测试清理 |
| 官方 Views/Chrome 独立窗口 | 最终受控运行的自动弹窗操作和优雅退出 | 较早退出失败仍保留；非 SwiftUI 内嵌验收，非可靠性压力测试 |

CEF 使用 `154.0.32+g682c378+chromium-154.0.8037.58`，macOS 27.2 beta/arm64，开发期本机签名。结果不可直接推广到其他版本或正式分发。

**已排除的具体路径：**同一 macOS native-parent / `SetAsChild(parent, bounds)` 调用只改成 Chrome style。该版本 [头文件契约](https://github.com/chromiumembedded/cef/blob/682c378/include/internal/cef_types_mac.h#L140) 与 [创建实现](https://github.com/chromiumembedded/cef/blob/682c378/libcef/browser/browser_host_create.cc#L203) 都强制原生 parent 使用 Alloy，不能靠改枚举取得 Views/Chrome 的行为。

Alloy 弹窗观察到 `type: other`、`waitingForDebugger: true`，`Runtime.runIfWaitingForDebugger` 未收到对应回复。关闭观察到 `DoClose`，未到 `OnBeforeClose` / `CefShutdown`。这是失败线索，尚未证明单一根因。

独立 Chrome 的人工接管未测，是 CUA 未能绑定隔离进程；没有在个人 Chrome 内执行输入。证据里的 `agentResumeSameDocument` 仅代表第二次自动编辑，不能改写为“人工接管通过”。

## 5. 推荐下一轮：只做一个可交互内嵌最小实验

### 5.1 原生内嵌探索路径

保持 SwiftUI，以独立临时 macOS 原型复用已有 CEF Alloy 实验源，先解决浏览器生命周期，再验证控制方式。原型源码在 [分层复测 reproduction-source.zip](browser-cef-layered-retest-2026-09-30/reproduction-source.zip)；应解压到 `/tmp` 或 `.tmp/`，先阅读和核对版本，勿直接并入产品。

参考 Craft 的思路，可以单独评估直接 CDP 或 CEF 宿主侧执行动作，判断能否避开已观察到的 Playwright Target 自动附加问题。**这只是新的实验假设，未验证，且不会自动解决退出失败。**不要为第一轮实现完整 CDP 兼容层、MCP 服务器或另一套语义引用系统；先用最小动作证明显示和控制确实指向同一页。直接发送输入的命令也必须验证真实事件行为，不用 DOM 赋值替代用户输入作为验收。

```text
SwiftUI 浏览器面板
  -> 唯一 native browser 实例 / 活动页面
  -> 宿主侧页面句柄及生命周期
  -> 最小控制通道（验证中）
  -> 后续适配现有 BrowserHostClient / BrowserSessionManager
  -> Core 的浏览器工具
```

前两步失败时停止产品接入。若认为需要 CEF Views 拥有整个原生窗口、重挂原生视图、改变 GUI 窗口所有权或改用其他引擎，应先写清新的宿主模型、公开 API 依据与验证计划，不把它描述成现有 SetAsChild 路径的小修。

### 5.2 验证顺序和停止条件

1. **宿主生命周期：**显示主页面与弹窗，关闭弹窗，再关闭主窗口；重新打开。要求关闭回调、宿主 shutdown 与进程退出完整，不以强制终止算 PASS。
2. **同页控制：**本地 fixture 为每个 document 生成随机 ID；原生手动输入后由驱动读取，再由驱动输入/点击让用户观察。双方读取同一个 ID 与状态。URL 相同或截图相似不算通过。
3. **弹窗与焦点：**用户和驱动分别打开弹窗，验证页面选择、输入、关闭和返回主页面；重复至少 3 次。记录每个页面句柄及目标类型。
4. **输入质量：**中文输入法组合输入/候选窗、英文、emoji、Meta+A、复制粘贴、缩放后点击定位。自动写入中文只算 Unicode 写入，不算 IME 通过。
5. **性能：**按第 7 节做配对采样。功能通过后再判断集成，不根据竞品实现推断性能。
6. **产品接入：**原型关键门槛通过后，才扩展现有协议并接入 Core/GUI，验证真实模型工具调用和授权。

开始实验性产品接入的必过门槛是：正常生命周期与无残留进程、人工和驱动共享同一 document、基本原生输入与自动动作、3 次弹窗往返。IME 或 GPU 检查为 NOT RUN 时，可以在隔离开发分支继续接入，但必须保留该标记，不能交付为验收通过。已发现的 IME 失败、持续闲置刷新或资源泄漏必须先修复；性能没有比较数据时不作改善结论。最终产品验收还要求第 6、8 节的真实权限、接管和取消检查。

建议首轮限制为一个工作日的原型验证；这是工作量建议，不是新的后台任务。到期若生命周期或弹窗仍失败，提交明确阻塞与证据，保留独立 Chromium 交付路径，不在主 GUI 继续堆补丁。不能通过禁用浏览器 sandbox、读取个人 profile、私有 API 或掩盖失败来换取通过。

## 6. 产品接入时的最低语义

下表是待实现语义，不是现有 API 名称；先检查现有会话和权限组件，再决定最少的协议增量。

| 场景 | 要求 |
| --- | --- |
| 选择会话 | 浏览器绑定 Agent session 与活动页面；切会话不会误控上一个会话 |
| 用户接管 | Core/宿主停止新动作调度，并确认正在执行动作已结束或取消后，才能显示“已接管” |
| Agent 恢复 | 重新读取当前页面 observation，作废接管前的元素引用，确认活动页后再执行 |
| 关闭或失联 | 明确取消/拒绝后续动作，更新真实状态，不偷偷重建一个空白页面继续执行 |
| 权限与拒绝 | GUI/TUI 都使用可回答的现有授权交互；拒绝后不执行，允许后必须作用到实际宿主操作 |
| 登录态与隔离 | 同一会话复用页面/context；不同会话隔离。重启后的持久化是另外的设计，不默认复用个人浏览器 profile |
| 远端 Core / iOS | 明确宿主所在设备及具备的能力；没有交互展示能力时标为状态或截图预览 |

浏览器接管与网页读写权限不应隐式提升文件系统权限。网页上传、下载、目录选择等涉及文件的操作仍需核对现有范围规则与 OS 权限；应用内允许不等于操作系统已经授权。

独立 Chromium 的最低产品接入也需要上述语义。只是打开窗口、加 `headless: false`，还不能算完成 GUI/Core 统一。

## 7. 性能采样与验收

比较对象固定为：现有 GUI 关闭浏览器、同 GUI 打开静态内嵌页、同 GUI 使用独立 Chromium。保持相同窗口大小、分辨率、壁纸、会话数据和页面。记录工具、版本、设备、前后台状态与采样方法；预热后每场景至少采样 60 秒，长采样工具应允许期间报告进度。

| 指标 | 方法与报告限制 |
| --- | --- |
| CPU | 同时记录 GUI、宿主及浏览器子进程，报告平均与峰值/分位数及单核百分比口径 |
| 内存 | 报告各进程 RSS 与可获得的 footprint；RSS 求和会重复计算共享内存，不称为独占占用 |
| GPU | 使用本机可用的系统采样方法，注明是全机、WindowServer 还是可归因进程数据；权限/工具不可用时写 NOT RUN |
| 动作延迟 | 分开测宿主动作往返与真实 Core 工具调用，不把本地热连接延迟称为整轮 Agent 延迟 |
| 生命周期 | 检查打开前后、关闭后残留进程，重复开关后的内存趋势与退出耗时 |

至少覆盖静态页闲置、浏览器面板隐藏、连续滚动、输入及关闭。禁止默认常驻截图串流；性能优化应先排查持续计时器、抓图和重复解码，不先增加复杂渲染层。

本文件不设无依据的“GPU 必须低于某百分比”阈值。接手者先提交同口径原始数据和相对基线变化；没有 GPU 数据不得宣称已解决用户报告的常驻 GPU 问题。历史独立 Chrome 的 CPU/RSS 数据只适用于当时简单本地 fixture，不能代替当前 GUI 采样。

## 8. 最终交付清单

- 最小复现代码、运行步骤、固定 SDK/驱动版本与源码来源。
- 原生宿主、人工输入、自动动作、弹窗、关闭回调和进程退出证据；失败也保留。
- 同 document ID 与状态的人工 → Agent → 人工操作记录。
- IME、授权拒绝/允许、取消、切会话、重开和无残留进程检查。
- 性能原始数据与可复现采样说明；检查标为 PASS / FAIL / NOT RUN。
- 说明最终是同窗内嵌、独立窗口还是截图，以及剩余限制。mock、单次成功和源码推断必须单列。

临时工具、构建和 profile 清理前先确认测试进程停止；需要留作交接的最小复现和证据归档到 Docs。不得删除既有失败归档。文档及公开 GUI/TUI 均使用 LingXiAgent 产品名，不加入私人对话人设。

## 9. 可直接交给下一位 Agent 的任务

> 阅读本文件和 Browser-delivery-decision-2026-09-30.md，重新检查当前工作区与版本。保留 SwiftUI GUI、现有修改和 Core 浏览器协议。优先在临时原型里验证 CEF Alloy 生命周期，随后评估直接控制同一原生网页能否解决已知弹窗问题；不要重复 native-parent 只改 Chrome style 的已排除路径。以人工与驱动共享 document、真实输入、弹窗和正常退出为门槛，记录 FAIL / NOT RUN。门槛通过后才给出最小产品接入 diff；未通过则提交阻塞证据，保持独立 Chromium 交付路径。新增依赖或改变 GUI 宿主模型前说明具体方案并按项目约定取得许可。
