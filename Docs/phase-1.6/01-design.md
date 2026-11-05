# Phase 1.6 设计：一等 Agent 节点、双视图工作台与运行期干预

- 状态：实现与测试完成，等待最终提交与 CI
- 基线：`d80069e`（Phase 1.5 文档收口）
- 分支：`rewrite/3.0`
- 范围：Agent 节点、独立 AgentRunner、版本化协作协议、消息总线、双视图工作台、安全暂停/配置修订/纠偏指令、SQLite 会话恢复
- 不在范围：真实 LLM 训练、MCP 市场、动态插件加载、多机调度、结构化分支迁移

## 1. 目标与硬约束

Phase 1.6 把 Agent 从"用多个节点拼出来的 ReAct 流程"提升为**一个完整的一等节点**：`core.agent` 负责自己的多轮模型调用、工具选择、上下文、预算、审批、消息收发与完成判定。节点编辑器仍是极简 ComfyUI 布局；Agent 的运行观察与干预放在独立的顶层"Agent 工作台"视图，不新增右侧属性栏、常驻聊天区或仪表盘。

不变量：

1. 引擎不内置固定 Agent Loop。`core.agent` 只是注册在 NodeRegistry 中的一个执行器，内部循环归 AgentRunner，不归 Scheduler。
2. 节点编辑器与工作台共享同一个 TaskSession、同一个 RunId、同一条事件流；切换视图不重启运行、不重建 Agent、不重发已完成的模型调用。
3. 工作流文档仍是可序列化 JSON，不含 React Flow 临时状态。Phase 1.6 不新增必填工作流字段，Schema 保持 `1.2`。
4. 前端不执行工作流。暂停、继续、取消、发送指令、预览/应用配置全部经 Tauri command 进入 Rust。
5. 普通节点和 Agent 工具都不能绕过能力声明与逐目标审批。
6. 静态配置与运行快照分离。运行中的 Agent 只使用已注册的配置版本；画布上的新配置在显式"应用到当前任务"并经安全点提交前不生效。
7. 不伪造推理。工作台只展示模型返回的增量文本、工具参数/结果、结构化消息和运行状态，不生成"思考过程"。

## 2. 分层与模块

```
lingxi-spec
  model / node / validation        工作流文档、NodeSpec、静态校验
        ↑
lingxi-runtime
  engine / control_flow            DAG 与受控循环调度，RunControl
  agent_protocol                   TaskSession、AgentInstance、消息、配置版本
  agent_bus                        消息总线、实例注册、暂停/取消、审批核对
  agent_runner                     Agent 内部循环、模型/工具/安全点
  agent_node                       core.agent 的端口、参数、执行入口
  workspace / workspace_tools      版本化文件与受限命令
  lsp / lsp_node                   stdio LSP 客户端与 core.lsp_server
        ↑
apps/desktop/src-tauri
  commands / runs                  Tauri command、SQLite 运行与会话快照
        ↑
apps/desktop/src
  Canvas / AgentWorkbench / App     编辑、展示、控制指令
```

依赖方向仍是 `lingxi-spec ← lingxi-runtime ← src-tauri`。运行时不知道 Tauri、窗口或 React 的存在。Tauri 现有 37 个 command，其中 Phase 1.6 新增 `pause_workflow`、`resume_workflow`、`pause_agent`、`resume_agent`、`cancel_agent`、`send_agent_directive`、`preview_agent_config`、`apply_agent_config`、`reject_agent_config`、`task_session`。

## 3. 身份与生命周期

四层身份，全部可从事件与持久化快照中还原：

| 层级 | 形式 | 生命周期 |
| --- | --- | --- |
| TaskSessionId | `session-{runId}` | 一次工作流运行 |
| WorkflowRunId | UUID | 一次运行；事件 `seq` 在整个运行内单调 |
| AgentInstanceId | `agent:{runId}:{scope path}{nodeId}` | 同一节点在同一组合作用域内跨激活保持 |
| ActivationId | `{instanceId}#activation-{n}` | 一次节点激活，从 1 递增 |

- 组合作用域由每层组合实例 ID 以 `/` 连接；因此两个同名 Agent 节点、或不同组合副本中的同一节点，不会合并成同一个实例。
- 同一 Agent 节点被循环重复激活时，`AgentInstanceId` 不变，`ActivationId` 递增；工作台一个标签页保留全部激活历史。
- 动态 Agent 由运行期注册，实例 ID 同样包含 run 与作用域，不使用显示名作为身份。
- `RunEvent::Agent` 携带 `agentInstanceId`、`activationId` 与运行状态；`TaskSession` 另存 `workflowRevision`（当前为 1）。前端按实例与激活精确过滤，不靠自然语言解析。

## 4. `core.agent` 节点契约

`AGENT_KIND = "core.agent"`。端口按四组折叠：

| 组 | 输入 | 说明 |
| --- | --- | --- |
| Capabilities | `provider`、`model`、`reasoning`、`toolset`、`mcp`、`skills`、`lsp` | 未连接的配置使用节点参数或默认值 |
| Instructions | `systemPrompt`、`rolePrompt`、`agentsMd`、`userPrompt` | AGENTS.md 优先级低于 system/role |
| Collaboration | `task`、`messages`、`artifacts`、`media` | TaskEnvelope / AgentMessageEnvelope / ArtifactRef / 多模态资源 |
| Control | `start`、`budget`、`policy`、`cancel` | `start`/`cancel` 是控制端口，不会被当作数据依赖 |

输出：

| 端口 | 类型 | 语义 |
| --- | --- | --- |
| `agentMessage` | JSON | 结构化 `AgentMessageEnvelope`，供其他 Agent 使用 |
| `userResponse` | Text | 面向人的可读结果，不要求下游解析 |
| `artifacts` | JSON | `ArtifactRef[]`，大交付物只传引用 |
| `executionState` | JSON | 实例/激活/状态/配置版本/用量 |
| `completed` / `blocked` / `failed` | Control | 只发出与实际终态对应的一个控制端口 |

主要参数与默认值：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `providerId` | `openai` | 复用 Phase 1.5 的三条协议 |
| `protocol` | `openai_chat` | `openai_chat` / `openai_responses` / `anthropic_messages` |
| `baseUrl` | `http://127.0.0.1:11434/v1` | 允许本地 mock 与自定义网关 |
| `credentialRef` | `env:OPENAI_API_KEY` | 明文不进入工作流或日志 |
| `model` | `gpt-4o-mini` | 运行前做能力检查 |
| `reasoning` | `auto` | off/auto/low/medium/high/xhigh |
| `rolePrompt` | `You are a capable autonomous agent.` | 最高优先级行为指令 |
| `systemPrompt` | 空 | 次级行为指令 |
| `agentsMd` | 空 | 工作区指令，低于 system/role |
| `instruction` | 空 | 未连接 `userPrompt` 时的默认任务 |
| `recipient` | `broadcast` | 结果消息收件人 |
| `maxIterations` | 12 | 每次激活的模型轮次预算 |
| `maxToolCalls` | 48 | 每次激活的工具调用预算 |
| `maxTotalTokens` | 0 | 0 表示不单独限制 |
| `timeoutMs` | 300000 | 每次激活墙钟超时 |
| `toolset` | `calculator` | 逗号分隔的已注册工具 |
| `skills` / `lsp` | 空 | Skills 注入与 LSP 工具句柄 |
| `maxTokens` | 1024 | 单次模型输出上限 |

配置优先级：**输入端口 > 节点参数 > 内置默认值**。`budget` 输入整体覆盖四个预算字段。`AGENTS.md` 文本追加到系统提示，带固定标题 `Workspace instructions (AGENTS.md):`，并在提示中声明其优先级低于 system/role。

协作输入不是"看到 JSON 就信"：`task` 与 `messages` 引用的 `messageId` 必须已通过消息总线投递；否则分别报 `handoff message ... was not delivered through the task bus` 与 `BUS_FORBIDDEN`。这样 Agent 不能绕过总线直接注入别人私有上下文。

## 5. AgentRunner 执行循环

`run_agent(ctx, bus, instance, activation, config, input)` 是唯一 Agent 内部循环，职责包括：

1. 校验 `AgentConfigSnapshot`：模型非空、预算非零、reasoning 受协议支持、模型能力满足多模态输入。
2. 走 `PermissionManager` 审批网络目标与凭据；需要时发交互请求，实例进入 `waiting_approval`。可选 LSP 子进程单独审批。
3. 构建 `ChatProvider`，复用 Phase 1.5 的 OpenAI Chat / Responses / Anthropic Messages 实现，不另起协议栈。
4. 每轮：检查取消 → **安全点** → 应用待生效配置 → 注入纠偏指令 → 超时/迭代预算 → 调模型 → 记录用量与 token 预算 → 再检查安全点 → 处理工具调用或结构化结果。
5. 工具调用：`submit_result` 解析为 `AgentResult`；其他工具检查工具预算、参数 schema、能力与逐目标审批，发 `agent.tool.started` / `agent.tool.finished`。
6. 完成判定由模型通过 `submit_result` 提交，Runner 校验 `status`、`agentMessage`、非空 `userResponse`。若模型只返回散文，最多发一次修复请求；仍失败则报 `model did not submit a structured result after one repair request`。非法结果最多修复一次，不做无限重试。
7. 结束时写激活终态、用量、用户可读结果、消息 ID 与错误，发出对应终态控制端口。

复用关系：模型 Provider、工具注册、权限、上下文、多模态与资产模块全部复用 Phase 1.4/1.5 的实现。Phase 1.4 的标准 ReAct 组合模板仍可校验、可运行；它不是第二套 Agent 栈，只是由普通节点组合出的另一种工作流。

## 6. 版本化协作协议

协议版本 `AGENT_PROTOCOL_VERSION = "1.0"`，只接受 `1.0`。上限：`MAX_ARTIFACT_REFS = 64`，`MAX_MESSAGE_BYTES = 512 * 1024`。

### 6.1 TaskEnvelope

```json
{
  "schemaVersion": "1.0",
  "taskId": "task-1",
  "sessionId": "session-...",
  "parentTaskId": null,
  "sender": "user",
  "recipient": "agent:...",
  "instruction": "Implement the feature",
  "artifacts": [],
  "budget": { "maxIterations": 12, "maxToolCalls": 48, "maxTotalTokens": 0, "timeoutMs": 300000 },
  "correlationId": "corr-1",
  "idempotencyKey": "task-1",
  "createdAtMs": 1760000000000,
  "metadata": {}
}
```

### 6.2 AgentMessageEnvelope

字段：`schemaVersion`、`messageId`、`taskId`、`sender`、`recipient`、`type`、`status`、`payload`、`artifactRefs`、`correlationId`、`idempotencyKey`、`createdAtMs`。

| 类型 | 必填 payload |
| --- | --- |
| `task.request` / `task.handoff` | `instruction` |
| `task.result` | `summary`、`status`（completed/blocked/failed） |
| `task.feedback` | `feedback`，可选 `verdict`（pass/fail/revise） |
| `task.question` | `question` |
| `task.blocked` | `reason` |
| `task.progress` | `step`、`percent`（0–100） |

状态：`queued`、`delivered`、`acknowledged`、`completed`、`failed`、`rejected`。

Payload 使用**显式 JSON Schema 子集**校验：`type`、`properties`、`required`、`additionalProperties`、`items`、`enum`、`minLength`、`maxLength`、`minimum`、`maximum`。未实现的 schema 关键字不会被默默忽略；非法结构直接以 `agent.invalid_message` 拒绝。

### 6.3 ArtifactRef

`id`、`name`、`kind`、`mime`、`size`、`digest`（64 位十六进制 sha256）、`uri`。大文件不塞进消息体，工作台只显示引用数量与摘要。

### 6.4 双输出

一次执行、一次结构化提交同时产生：

- `agentMessage`：给下游 Agent / 协调者，字段稳定，可校验。
- `userResponse`：给人看，不要求解析自然语言。

默认不为"人类可读版本"再发一次完整模型调用，避免翻倍成本。

## 7. 消息总线

`AgentBus` 是运行内所有 Agent 通信的唯一入口：

- `send`：先校验 envelope 与 payload，再按 `idempotencyKey` 去重；同 `messageId` 重复投递拒绝。返回 `Delivery { message, duplicate }`。
- 发送者必须是 `user`、`workflow` 或已注册 Agent；收件人必须是已注册 Agent 或 `broadcast`。广播不回送发送者。
- 每个收件人一个 FIFO 队列，容量 `DEFAULT_QUEUE_LIMIT = 128`；满时返回 `bus.queue_full`，错误文本包含 `inbox for ... is full (...)`，不静默丢弃。
- 会话消息总量 `DEFAULT_MESSAGE_LIMIT = 4096`，超出时裁剪最旧消息；持久化快照与内存会话同源。
- `receive` 只返回 `queued` 消息并原子标记 `delivered`，同一条不会取两次；`acknowledge` 接受 acknowledged/completed/failed/rejected。
- 所有消息写入 `TaskSession.messages`，由 TauriSink 在 Agent 事件与 `run.finished` 时检查点落库。

边界：当前权限模型是**运行成员制**（注册 Agent + broadcast），没有按消息类型的细粒度 ACL；跨运行消息隔离由每个 Run 独立 Bus 保证。外部消息一律视为不可信数据，不能覆盖 system/role 指令或能力策略。

## 8. 运行期干预

### 8.1 三种控制语义

| 操作 | 作用域 | 语义 |
| --- | --- | --- |
| `pause_workflow` | 整个运行 | 调度器在下一个激活前停发；**不**强行打断正在执行的 Agent |
| `pause_agent` | 单个 Agent | 置 `pausing`，Runner 到最近安全点后进入 `paused`；之前绝不显示"已暂停" |
| `cancel_agent` | 单个 Agent | 运行期取消令牌；安全点或模型/工具边界返回，激活终态 `cancelled` |
| `stop_workflow` | 整个运行 | RunControl 取消；循环、Agent、工具与审批等待都退出 |

`pause_agent` 在审批提示期间不会立即生效：Runner 正阻塞在交互请求，尚未到达安全点。原生测试必须先并发批准交互，再等待暂停，不能把"请求已发出"当成"已暂停"。

### 8.2 安全点

`wait_for_safe_point` 只检查**本 Agent** 的暂停标志，位置：

1. 每轮模型调用之前；
2. 模型响应返回后、任何工具或结构化结果被处理前；
3. 每个工具执行前。

暂停时发 `agent.state`，`reason = "safe pause point reached"`；恢复后发 `running`，`reason = "resumed"`。取消在等待循环中优先于继续。

### 8.3 配置修订

- 运行期间画布锁定结构操作与节点参数输入；工作台里的配置编辑是**草稿**，不影响运行中的 Agent。
- `preview_agent_config` 只做校验与 diff，返回 `ConfigChange { field, before, after }`；长提示词摘要到 80 字符，避免把全文塞进事件。
- `apply_agent_config(config, expectedRevision)` 要求 revision 匹配、diff 非空，校验模型与预算；新版本状态 `pending`，旧 pending 标记 `superseded`。
- Runner 在下一轮安全点应用 pending 配置，发 `agent.config`，`reason = "config revision N applied at the next iteration"`，版本状态转 `applied`。
- `reject_agent_config` 记录 `rejected` 与原因。
- 过期 revision 返回错误，配置版本不变；UI 必须重新读取，不能盲写。
- 结构变更（增删节点、改拓扑、换 Agent 实例）**不会**在运行中直接迁移。Phase 1.6 没有 checkpoint 分支实现，画布在运行中禁用结构与参数编辑；需要结构变更时停止并新建运行。

### 8.4 纠偏指令

`send_agent_directive` 以 `task.feedback`（sender `user`）进入总线，同时排队为待投递指令。Runner 在安全点把文本注入当前对话：

```
User intervention for the current task (follow it; do not restart completed work): ...
```

不重启激活、不重放已完成工具、不丢弃已有上下文。工作台显示"纠偏指令已进入总线，将在最近的安全执行点交给 Agent"；被消费后不再显示待投递数量。

## 9. 工作台与双向定位

工作台是**顶层视图**（工具栏"Agent 工作台"），不是右侧属性栏，也不与画布同时挤在中央：

- 顶部标签：`总览` + 每个 Agent 一个标签。标签显示状态点/文字、未读数、待投递指令标记。
- 单 Agent：当前任务、执行记录（第 N 次执行）、配置版本、迭代与错误、用户可读结果、模型增量流、工具调用、团队消息、成本（迭代/模型调用/工具调用/token/毫秒）、纠偏指令、运行配置与版本记录、暂停/继续/取消、定位节点。
- 模型流只显示 `agent.delta`；没有增量时明确写"当前激活暂无增量输出。未公开的推理不会被伪造。"
- 总览：团队状态、成本与交付、最近 `task.result`/`task.blocked`、跨 Agent 消息时间线（最近 20 条）、待处理审批/核对。
- 视图状态存 `localStorage`（`lingxi.view`、`lingxi.agent`）。刷新后从 `task_session` 恢复当前视图、选中 Agent 与运行详情；画布保持挂载但隐藏，不重建 React Flow 状态。

双向定位：

- 工作台"定位节点"：由 `agent.scope` 还原组合层级路径，切换到对应面包屑层，选中并聚焦该节点，再切回画布。
- 画布"查看 Agent 执行"：按选中 `nodeId` + 当前实例路径匹配 AgentInstance，打开对应工作台标签。
- 两个方向均已由 Playwright 与原生 WDIO 覆盖。

## 10. 持久化与恢复

SQLite 在 `user_version = 2` 新增 `task_sessions`：

```sql
CREATE TABLE task_sessions (
    run_id              TEXT PRIMARY KEY REFERENCES runs(run_id) ON DELETE CASCADE,
    session_id          TEXT NOT NULL,
    state               TEXT NOT NULL,
    workflow_revision   INTEGER NOT NULL,
    session_json        TEXT NOT NULL,
    updated_at_ms       INTEGER NOT NULL
);
```

- 整个 TaskSession 作为一个 JSON 文档保存，不从日志行重建 Agent 状态。旧库通过 `CREATE TABLE IF NOT EXISTS` 原地升级，不改已有 `runs`/`run_events`。
- TauriSink 在 Agent 事件与 `run.finished` 时检查点；后者保证最后一条总线消息也能落库。
- 正常暂停可恢复；WebView 刷新不影响 Rust 执行；桌面进程崩溃后启动恢复：`running` 运行标记 `interrupted`（detail `app restarted before the run finished`），活跃 Agent 与激活标 `interrupted`，不重放。
- 若中断的激活已有工具调用，新增未解决 `PendingReview`：工具名 `unknown`，原因 `The desktop process exited during a tool-using activation. Verify the external side effect before retrying.`。外部副作用必须人工核对，绝不自动重试。
- "UI 日志回放"只是展示，不是执行恢复。完成过的操作不会因刷新或重启再执行。

## 11. 受控工作区与 LSP

工作区文件写入是版本化比较提交：

- 内容版本 `sha256:<hex>`，文件不存在为 `absent`。
- 必须先 `read_file` 得到版本，再 `write_file(expectedVersion)`。版本过期报 `workspace.version_conflict`，文本包含 `changed since it was read ...; read it again before writing`。
- 路径拒绝 `..`、绝对路径与符号链接逃逸。
- `run_command` 不经过 shell，仅允许 `cargo`、`npm`、`pnpm`、`node`、`python3`、`pytest`，带超时与 `kill_on_drop`。

LSP 为最小真实链路：`core.lsp_server` 启动 stdio 服务（默认 `rust-analyzer`），完成 `initialize`、`textDocument/diagnostic`、`textDocument/documentSymbol`，分别暴露 `lsp_diagnostics` 与 `lsp_symbols` 工具；诊断超时 5 秒，关闭 2 秒。没有 diagnostics 时返回空数组，不伪造错误。fixture `fixtures/mock-lsp` 验证真实 JSON-RPC 往返。

## 12. 兼容性与迁移

- 工作流 Schema 仍为 `1.2`，支持 `1.0`/`1.1`/`1.2`；Phase 1.6 不要求新增文档字段。
- 旧 `core.provider`、三条协议、Reasoning、多模态资产、组合节点/模板、SQLite 历史、MCP/Skills 均保持原契约。
- 旧标准 ReAct 模板通过 `agent_template.rs` 静态校验。
- 新增端口组字段 `PortSpec.group` 为可选，旧文档缺省即无分组。
- 新 Agent 使用独立的 `AgentConfigSnapshot`；旧工作流的节点参数原样保留，不自动改写成 Agent 配置。

## 13. 已知边界

1. 并发：当前 Agent 节点通过调度器顺序激活；尚未实现独立 Agent 的受控并发，也不把顺序执行展示成并行。
2. 结构变更：运行中禁止改拓扑；checkpoint 派生分支未实现。
3. 消息权限：仅运行成员制，没有按消息类型/字段的细粒度 ACL。
4. 恢复：崩溃恢复只保证"不重放、标记中断、人工核对"，不保证恢复未完成的外部副作用。
5. 工作台不展示私有推理；只展示模型主动返回的文本、工具与结构化结果。
6. Windows / Linux 只验证编译、clippy 与单测；原生 Tauri 行为只在 macOS 验收。
7. LSP 仅支持 stdio 与诊断/符号两类请求，不含补全、重命名、代码操作。
8. 工作流级 revision 尚未接入事件：`TaskSession.workflowRevision` 当前固定为 1，`RunEvent`/`AgentEvent` 不携带该字段；跨版本画布与运行快照的对照留待下一阶段。
