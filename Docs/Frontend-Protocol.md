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
