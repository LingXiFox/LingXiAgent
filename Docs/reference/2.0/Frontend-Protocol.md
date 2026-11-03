# 前端协议（Core ↔ TUI）

传输：Core 进程的标准输入/输出，**每行一个 JSON 对象**（UTF-8，无嵌入换行）。TUI 以子进程方式启动
Core 并设置 `LINGXI_FRONTEND=stdio`；Core 只在被这样启动时进入常驻服务模式。TUI 不加载 Provider、
不加载任何插件，所有执行经 Core 与 Plugin Runtime。

## 请求与回复

请求带 `id`，回复原样带回：

```json
{"id":1,"method":"models.list"}
{"id":1,"ok":true,"models":["mimo-v2.6-flash"]}
```

| method | 参数 | 回复字段 |
|---|---|---|
| `hello` | — | `models`, `modelDetails`, `providerStates`, `sessions`, `plugins`（启动快照） |
| `models.list` | — | `models`, `modelDetails`, `providerStates` |
| `sessions.list` | — | `sessions[]`（id、标题、轮数） |
| `session.history` | `sessionID` | `history[]`（role、text、kind: message/tool/toolCall） |
| `session.new` | — | `sessionID`（新会话在下一条消息落盘前不写日志） |
| `chat.send` | `sessionID?`, `model?`, `text` | `sessionID`, `runID`（随后以事件流返回内容） |
| `run.cancel` | `runID` | —（在途 Run 按内核取消语义收敛） |
| `plugins.list` | — | `plugins[]`（id、版本、enabled、running、capabilities、permissions） |
| `plugin.enable` / `plugin.disable` | `bundleID` | `plugins`, `models`, `modelDetails` |
| `plugin.settings.open` | `bundleID`, `viewport` | `settings`（sessionID、标题、受约束 frame、`dirty`） |
| `plugin.settings.input` | `settingsSessionID`, `settingsInput` | `settings` |
| `plugin.settings.resize` | `settingsSessionID`, `viewport` | `settings` |
| `plugin.settings.save` | `settingsSessionID` | `ok`；成功即关闭设置会话 |
| `plugin.settings.cancel` | `settingsSessionID` | `ok`；丢弃草稿 |
| `plugin.settings.credential` | `settingsSessionID`, `provider`, `settingsCredentialAction`(`update`/`remove`), `settingsCredentialConfirmed` | `credentials[]`；`remove` 必须显式确认 |
| `provider.reasoning.set` | `provider`, `model`（设置时必填）, `reasoningLevel` 或 `clearReasoning:true` | `providerStates[]`；等级必须是插件为该模型声明的 id |
| `shutdown` | — | —（Core 在输入 EOF 后退出） |

`modelDetails` 是 `models` 的可选增强，元素形如
`{"id":"mimo-v2.6-flash","provider":"mimo","thinkingLevels":[],"thinkingProfiles":[{"protocolKind":"responses","protocolLabel":"Responses","axisLabel":"effort","levels":[{"id":"high","label":"high"}],"defaultLevel":"default","note":"…"}]}`。
`thinkingProfiles` 是「模型 × 协议」的思考阶梯：TUI 用 `providerStates.protocolKind` 选匹配项，
绝不合并两条阶梯；`axisLabel` 为 `effort` 时底栏显示 `effort: high（临时）`。
`models` 始终完整；旧前端可以忽略 `modelDetails`。思考等级由 Provider 插件在 `describe` 中声明，
Core 只做透传和路由过滤。`providerStates` 是 Provider 的实时状态：

```json
{"providerID":"mimo","protocolKind":"responses","thinkingLevel":"enabled","thinkingLabel":"开启思考",
 "source":"plugin-settings","overridden":false}
```

`source` 为 `plugin-settings` / `server-default` / `session-override`；`session-override` 表示用户用
`/reasoning` 做了临时选择（该值不落盘，Core 重启即消失）。未声明状态能力的 Provider 不出现，或只有
`providerID`，前端不得虚构默认值。

设置会话的 `settings` 元素包含 `sessionID`、`bundleID`、`title`、`version`、`status`、`viewport`、
`frame` 和 `dirty`。`dirty` 由插件回答“草稿是否与保存结果不同”；`null` 表示插件不跟踪，宿主按脏处理。`frame` 是插件自绘的行/spans；宿主在 Core 侧校验控制字符、颜色、尺寸并裁剪到视口。TUI 只负责
外框、标题、页脚与输入路由，不解释插件字段。`viewport` 由 TUI 提供，插件可据此重排；Resize 走独立
请求。`settingsInput` 的 `kind` 为 `key`/`paste`/`mouse`/`resize`/`credential`，键名使用
`up`/`down`/`left`/`right`/`tab`/`enter`/`backspace`/`delete`/`char`/`pageUp`/`pageDown`。

`auth.set` 携带 `settingsSessionID` 时，Core 用该设置会话的 Bundle ID 与插件声明解析凭据归属：
允许禁用插件首次配置自己的 Key，但其他插件不能借会话操作它。伪造 `provider` 而不带会话只会走
运行中 Provider 的既有路径，无法跨插件读写。

失败时 `ok=false` 且 `error` 是非空的人类可读原因；错误不折叠成单一 `failed`。

## 事件

无 `id`。TUI 按 `event` 分派：

| event | 字段 | 含义 |
|---|---|---|
| `run.state` | `runID`, `sessionID`, `status` | `running` 等运行态 |
| `delta` | `runID`, `delta` | 助手文本增量（真流式，逐事件到达） |
| `reasoning` | `runID`, `reasoning` | 推理增量（可选渲染） |
| `tool` | `runID`, `tool`, `status`, `detail?` | 模型发起工具调用：`started` 只有名称，`requested` 带截断到 240 字符的参数 JSON |
| `usage` | `runID`, `usage` | 单次 Provider 调用的 token 计数（input/output/reasoning/cacheRead，缺失不等于 0）；一个 Run 可有多条 |
| `run.terminal` | `runID`, `status`, `cause`, `detail`, `sessions` | 终态；`status != completed` 时 TUI 明确提示 cause/detail |
| `plugins.changed` | `plugins` | 启停、崩溃或外部变化后的快照 |
| `models.changed` | `models`, `modelDetails`, `providerStates` | 路由变化后的可用模型与元数据 |
| `providers.state` | `providerStates` | Provider 实时状态变化（保存设置、启停后） |
| `timing` | `runID`, `timing` | 一次 Run 一条，终态前到达：Core 准备、内核各阶段、插件 HTTP 各阶段、Run 总耗时（整数毫秒，只含数字） |

`timing` 的字段：`corePrepareMs`、`prepareMs`、`httpSendMs`、`firstResponseMs`、`firstSSEMs`、
`firstReasoningMs`、`firstTextMs`、`providerTotalMs`（本 Run 所有 Provider 请求之和）、
`providerCalls`、`providerLastCallMs`、`credentialMs`、`runTotalMs`、`renderMs`（仅 TUI 本地填充），以及内核阶段
`assemblyMs`、`budgetMs`、`contextHookMs`、`requestHookMs`、`providerWaitMs`、`toolMs`、
`logWriteMs`（journal 写入+fsync）、`terminalCommitMs`、`providerCleanupMs`、`unaccountedMs`、
`loopTotalMs`、`steps`。`credentialMs` 是 Core 侧 Keychain/环境读取时间，属于本地成本，不是上游延迟。
缺失表示未观测到，**不是 0**；`unaccountedMs` 是总耗时减所有已知阶段的余量，必须被当作缺陷信号。

## 所有权与顺序

- 一次 `chat.send` 对应一个 Run；同一 Session 的并发 Run 仍被内核拒绝（LOOP-021）。
- 取消：`run.cancel` 取消该 Run 的 Task 与在途 Provider 请求；内核终端原因为取消或 Provider 失败。
- 插件启停：Core 调用 `PluginCoordinator`，路由与 Hook 立即更新；TUI 只反映快照，不执行插件代码。
- 会话：SessionStore 由事件日志恢复；Core 重启后历史可读。`/clear` 是 TUI 的屏幕清空，不删历史。
- Plugin Host 崩溃：协调器清理该插件的路由与 Hook 并广播 `plugins.changed`；TUI 报告状态、不退出。

`LINGXI_CORE_CONTROL=1` 是 Phase 3.1 的最小测试控制面（`models`/`plugins`/`enable`/`disable`/`quit`），
与前端协议相互独立，不会被 TUI 使用。

## 凭据管理（Phase 4.1）

| method | 参数 | 回复字段 |
|---|---|---|
| `auth.status` | `provider` | `credentials[]`（providerID、credentialID、label、source、configured） |
| `auth.set` | `provider`, `secret` | 同上，仅状态 |
| `auth.remove` | `provider` | 同上，仅状态 |

没有读取密钥的方法。`secret` 只能从专用隐藏输入进入 `auth.set`，不得进入 `chat.send`、普通输入缓冲、
消息列表、历史、日志或错误正文。TUI 收到保存回复前丢弃后续按键；Esc/Ctrl-C 取消输入，多行粘贴拒绝。
`/auth <provider>` 首次设置，已有凭据时只提示更新命令；`update` 显式替换，`status` 不返回密钥。

Core 根据已启用插件的认证声明授权；Keychain account 为 `bundleID/providerID/credentialID`。
禁用插件不删除项，已保存凭据可在禁用期间查看状态或移除；重新启用后下一次调用重新读取。
当前每个 Provider 支持一个 API Key；其他认证方案未实现。

默认只用 macOS Keychain。开发/自动化必须显式设置 `LINGXI_CREDENTIAL_SOURCE=environment`，并由
`<data>/credentials.json` 将能力 ID 映射到变量名，例如 `{"provider.mimo":"MIMO_API_KEY"}`。
插件的 `envVariable` 只是建议，不能授权读取任意 Core 环境变量。JSON 中从不保存变量值。
环境覆盖生效时禁止通过 `/auth` 伪装更新/删除环境变量；须移除覆盖并重启 Core 后管理保存的 Key。
`LINGXI_KEYCHAIN_SERVICE` 可指定独立命名空间（测试用唯一 `.test.<UUID>` 服务，不触碰用户条目）。

SwiftPM ad-hoc Core 使用文件型 Keychain默认 ACL，仅信任创建项的 Core 身份，不信任 TUI 或 Host。
同一构建重启可复用凭据；代码重建导致 cdhash 改变时可能触发 macOS 重新授权。发布版需要稳定签名身份，
不能把 ACL 改为“所有应用”或仅验证可伪造的 identifier 来消除提示。


## TUI 导航与屏幕绘制

布局：顶栏（品牌、会话标题、工作目录）、消息区、输入区、状态栏。首页输入区居中，下方是常用命令提示；
对话时输入区固定在底部。输入区底行是模型区，只显示当前模型与草稿行数（插件状态在 `/plugins`）。
状态栏左侧是运行态（就绪 / 生成中 + 已用秒数 / 已向上滚动），右侧只放一个当前最相关的按键（空闲时 `Ctrl-P 命令`）。
生成中只有秒数计数器每秒刷新一次，没有动画。

消息：用户消息是带狐橙竖条的凸起块；回复以 `◆ 泠溪` 开头，结束后在末尾显示模型、耗时与 `↑输入 ↓输出` token。
推理默认折叠，只显示字数；Ctrl-T 或 `/thinking` 展开/收起，不改变发给模型的内容。
`tool` 事件显示为 `◇ 工具名  参数`，历史中的工具结果最多显示 4 行。运行未完成时原因以内联错误留在对话里。

Markdown：标题、有序/无序/任务列表、引用、分隔线、带语言标签与轻量高亮的代码块（流式中未闭合的代码块照常渲染）、
表格（按 CJK 宽度对齐，超宽时截断最宽列）、行内代码、加粗、斜体、删除线、链接（显示为文字加灰色 URL）。
英文按词换行，过长的词与 CJK 按字断行；行内样式跨行保持。

`/` 前缀在输入区旁弹出命令候选（对话时在上方，首页在下方），↑↓ 选择、Tab 补全、Enter 执行；
Ctrl-P 打开可搜索命令面板。`/models`、`/sessions`、`/plugins` 与不带参数的 `/auth` 使用同一居中面板，
显示选中位置（如 `2/8`）；选择器内 Esc 返回。`/plugins` 是勾选列表：Space 切换启用/禁用（只暂存），
Enter 保存并关闭（只对与当前状态不同的插件发送 `plugin.enable` / `plugin.disable`），Esc 放弃修改。已有 `/auth <provider> [update|remove|status]` 用法保持可用。
`/copy` 用 `pbcopy` 复制最后一条回复。`/mouse` 开关鼠标捕获（默认关）：开启后滚轮滚动消息，
但终端原生拖选需按住 fn（Terminal.app）或 ⌥（iTerm2）；默认关闭是为了不破坏直接拖选复制。

阶段 4.3 的交互补充（ADR-0010）：

- 输入区底行是状态区：`模型 · 协议 <插件给的显示名> · 思考 <生效等级>`；临时选择追加 `·临时`。
  协议/思考只取 Core 的 `providerStates`，Provider 未声明 `provider.state.v1` 时只显示模型。
  Ctrl-T 仍只展开/收起思考内容，不改变临时选择。
- `/reasoning` 打开当前模型声明的思考等级（另加“跟随插件设置”）。选择立即生效于后续请求、
  不写设置文件；`/reasoning follow` 清除临时值。Core 拒绝未声明的等级。
- 每次 Run 结束后，回复 meta 下方有一行 `上游 xms · 思考 xms · 本地 xms/N 帧`（缺项省略）；
  `/perf` 展开为“本地阶段 / 上游延迟 / 总计”三段明细。数值只含毫秒与帧数。
- 主界面鼠标：点击底栏模型名打开模型选择器；点击思考状态打开该协议的完整档位选择器；
  点击状态栏右下角“Ctrl-P 命令”打开命令面板；输入区右侧 `[ 发送 ]` 与 Enter 走同一发送路径，
  生成中不产生命中区域（按钮禁用），草稿保留。全部经 Renderer 命中图，不硬编码坐标。
- 设置窗口：Ctrl-S 保存；Esc 在 `dirty == false` 时直接关闭，`true`/`null` 时弹出宿主三按钮
  `[ 保存 ] [ 放弃 ] [ 继续编辑 ]`（←→/Tab 移动、Enter 确认、Esc 继续编辑，均可点击）。
  保存失败保留窗口与草稿；设置 Host 死亡时关闭窗口并提示，不阻塞 `/quit` 或 Ctrl-C。
- 鼠标：`/mouse` 开启后，点击选择器/插件列表行等于选中并确认；点击勾选框等于 Space；
  滚轮滚动消息或移动选择。设置面板内点击转成帧内相对坐标发给插件，边框/标题/页脚与宿主弹窗按钮
  不穿透。release 事件不转发，一次点击只触发一次。键盘操作全部保留，与鼠标共用同一选中状态。

编辑：输入区随内容增长（最多 8 行，再随光标滚动），中文、组合字符与 emoji 按字形计宽。
真实终端光标停在输入位置并显示，输入法候选框跟随输入点；面板打开时隐藏光标。
Enter 发送，Shift-Enter 换行。TUI 启动时开启 kitty 键盘协议的 disambiguate 级别（`CSI >1u`，退出时 `CSI <u` 恢复），
支持该协议的终端（如 kitty、Ghostty、WezTerm、iTerm2 3.5+）会把 Shift-Enter 报告为 `CSI 13;2u`，Esc、Ctrl 组合键
也以 `CSI code;mods u` 到达并映射回原有按键。不支持的终端（如 Terminal.app）里 Shift-Enter 与 Enter 无法区分，
可用行尾 `\` 再按 Enter、Alt-Enter（需开启 Option 作 Meta）或 Ctrl-J 换行。
Ctrl-A/Ctrl-E 行首/行尾，Ctrl-W 或 ⌥⌫ 删除前一个词，Ctrl-K 删除到行尾，Ctrl-U 清空，
⌥←/⌥→（或 ESC b/f、Ctrl-←/→）按词移动，Ctrl-D 在非空时删除后一个字符，Ctrl-L 重绘。
Home/End 接受 CSI `H/F/1~/4~/7~/8~` 与 SS3（`ESC O x`）变体。非空输入时 Ctrl-C 先清空，再按一次退出。
带括号粘贴保留换行并留在草稿，不会因粘贴中的回车、命令或控制键触发操作。
↑↓ 在逻辑行间移动；抵达首尾后回看本进程最多 100 条聊天输入，向下返回原草稿。
命令和专用隐藏输入不进入这份历史，也不另建历史文件。生成中按 Enter 保留草稿，Esc 取消生成。

TUI 接收 `chat.send` 回复的 `sessionID` / `runID`，后续发送复用同一会话。
生成期间禁止 `/new`、`/switch`、`/clear`，避免把在途回复写到另一会话；其他选择器仍可打开。
会话历史接口当前不保存推理，重启恢复的仍是正式聊天和工具条目，不虚构丢失的推理内容。
PgUp/PgDn 按一屏翻页，End 回到底部；向上滚动后新内容到达时视图保持原位，右侧滚动条指示位置。
提示消息约 6 秒后消失，错误保留到被替换。

渲染：Renderer 在 cell 帧缓冲上绘制（宽字符占两格，覆盖半个宽字符时补空格），每帧按终端实际列/行数裁剪，
以绝对坐标逐行清除再绘制，使用固定背景，避免缩短输入后残留旧文本；单行区域中的换行一律转为空格。
已排版的消息按内容与宽度缓存，只有变化的消息重新排版。隐藏输入是独立认证面板，只把 label 和字符数传给 Renderer；
Renderer 不接触 secret。TUI 会恢复退出时的自动换行、光标、鼠标与背景状态。布局参考 OpenCode 的
[home](https://github.com/anomalyco/opencode/blob/v2/packages/tui/src/routes/home.tsx) 与
[prompt](https://github.com/anomalyco/opencode/blob/v2/packages/tui/src/component/prompt/index.tsx)，实现沿用本项目 Swift 渲染器。
