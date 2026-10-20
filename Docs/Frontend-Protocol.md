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
| `hello` | — | `models`, `sessions`, `plugins`（启动快照） |
| `models.list` | — | `models` |
| `sessions.list` | — | `sessions[]`（id、标题、轮数） |
| `session.history` | `sessionID` | `history[]`（role、text、kind: message/tool/toolCall） |
| `session.new` | — | `sessionID`（新会话在下一条消息落盘前不写日志） |
| `chat.send` | `sessionID?`, `model?`, `text` | `sessionID`, `runID`（随后以事件流返回内容） |
| `run.cancel` | `runID` | —（在途 Run 按内核取消语义收敛） |
| `plugins.list` | — | `plugins[]`（id、版本、enabled、running、capabilities、permissions） |
| `plugin.enable` / `plugin.disable` | `bundleID` | `plugins`, `models` |
| `shutdown` | — | —（Core 在输入 EOF 后退出） |

失败时 `ok=false` 且 `error` 是非空的人类可读原因；错误不折叠成单一 `failed`。

## 事件

无 `id`。TUI 按 `event` 分派：

| event | 字段 | 含义 |
|---|---|---|
| `run.state` | `runID`, `sessionID`, `status` | `running` 等运行态 |
| `delta` | `runID`, `delta` | 助手文本增量（真流式，逐事件到达） |
| `reasoning` | `runID`, `reasoning` | 推理增量（可选渲染） |
| `run.terminal` | `runID`, `status`, `cause`, `detail`, `sessions` | 终态；`status != completed` 时 TUI 明确提示 cause/detail |
| `plugins.changed` | `plugins` | 启停、崩溃或外部变化后的快照 |
| `models.changed` | `models` | 路由变化后的可用模型 |

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

首页采用居中输入区；对话时输入区固定在底部。`/` 前缀显示命令候选，↑↓ 选择、Tab 补全、Enter 执行；
Ctrl-P 打开可搜索命令面板。`/models`、`/sessions`、`/plugins` 与不带参数的 `/auth` 使用同一键盘选择方式。
选择器内 Esc 返回，再输入新的斜杠命令。已有 `/auth <provider> [update|remove|status]` 用法保持可用。

输入区随内容增长（最多显示 6 行，再随光标滚动），中文、组合字符与 emoji 按字形计宽。
Enter 发送，Ctrl-J 换行；支持能发送独立序列的 Shift-Enter / Alt-Enter。
带括号粘贴保留换行并留在草稿，不会因粘贴中的回车、命令或控制键触发操作。
↑↓ 在逻辑行间移动；抵达首尾后回看本进程最多 100 条聊天输入，向下返回原草稿。
命令和专用隐藏输入不进入这份历史，也不另建历史文件。生成中按 Enter 保留草稿，Esc 取消生成。

TUI 接收 `chat.send` 回复的 `sessionID` / `runID`，后续发送复用同一会话。
生成期间禁止 `/new`、`/switch`、`/clear`，避免把在途回复写到另一会话；其他选择器仍可打开。
推理事件与回答依序呈现，默认折叠；Ctrl-T 或 `/thinking` 展开/收起，不改变发给模型的内容。
会话历史接口当前不保存推理，重启恢复的仍是正式聊天和工具条目，不虚构丢失的推理内容。
PgUp/PgDn 滚动聊天，End 回到底部。标题、选择器等单行区域中的换行转换为空格，不能扰乱绝对行绘制。

隐藏输入是独立认证面板，只把 label 和字符数传给 Renderer；Renderer 不接触 secret。
每帧按终端实际列/行数裁剪，以绝对坐标逐行清除再绘制，使用固定背景，避免缩短输入后残留旧文本。
TUI 会恢复退出时的自动换行、光标和背景状态。布局参考 OpenCode 的
[home](https://github.com/anomalyco/opencode/blob/v2/packages/tui/src/routes/home.tsx) 与
[prompt](https://github.com/anomalyco/opencode/blob/v2/packages/tui/src/component/prompt/index.tsx)，实现沿用本项目 Swift 渲染器。
