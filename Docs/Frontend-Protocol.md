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
