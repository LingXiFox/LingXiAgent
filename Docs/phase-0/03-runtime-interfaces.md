# Phase 0 · 运行时接口

本文是前端、桌面壳与 Rust 运行时之间的稳定契约。类型定义以 Rust 为准，TypeScript 侧在 `apps/desktop/src/lib/types.ts` 手工镜像（Phase 0 不引入代码生成）。

## 一、边界

```
React (transport.ts)
   │ invoke(command, args)                    ▲ listen("lingxi:run-event")
   ▼                                          │
Tauri command layer (commands.rs) ────────────┘
   │ 反序列化 / 校验 / 管状态
   ▼
lingxi-runtime (Engine / Registry / Broker)
```

- 前端只发**显式命令**；不存在「每帧同步」或「前端驱动执行」的通道。
- Rust 只通过一个事件名推送运行事件；命令是请求/响应，事件是单向流。
- 所有结构体 serde `camelCase`；枚举 `snake_case`；命令参数在 JS 侧用 camelCase，Tauri 自动映射到 Rust 的 snake_case 形参。

## 二、命令表

| 命令 | JS 参数 | 返回 | 失败 |
| --- | --- | --- | --- |
| `list_node_specs` | — | `NodeSpec[]` | 无（同步） |
| `validate_workflow` | `{ workflow }` | `ValidationReport` | 反序列化失败 → reject |
| `run_workflow` | `{ workflow }` | `RunStartResponse` | 反序列化失败 / run 表锁中毒 → reject |
| `stop_workflow` | `{ runId }` | `boolean` | 锁中毒 → `false` |
| `respond_interaction` | `{ requestId, approved }` | `boolean` | 未知/已决议 → `false` |
| `workflow_list` | — | `WorkflowSummary[]` | 目录不可读 → reject |
| `save_workflow` | `{ name, workflow }` | `WorkflowSummary` | 名称非法/IO 失败 → reject |
| `load_workflow` | `{ name }` | `Workflow` | 不存在/JSON 非法 → reject |
| `delete_workflow` | `{ name }` | `boolean` | IO 失败 → reject |

`Result<_, String>` 的命令失败时，Promise 以字符串 reject；UI 直接展示该字符串并写日志。Phase 0 不定义结构化错误对象。

### RunStartResponse

```json
{
  "started": true,
  "runId": "0f4f7d9e-6b1a-4b6e-9d63-1f0f0f2a9c11",
  "report": {
    "ok": true,
    "schemaVersion": "1.0",
    "nodeCount": 3,
    "edgeCount": 2,
    "errors": 0,
    "warnings": 0,
    "issues": []
  }
}
```

校验失败时返回 `started:false, runId:null`，`report` 带完整问题列表；**不会创建运行**，也不会发任何运行事件。

### WorkflowSummary

```json
{ "name": "hello", "nodeCount": 4, "updatedAtMs": 1770000000000 }
```

### 工作流名称规则

保存/加载/删除都走同一校验：非空、≤64 字符、不以 `.` 开头、不以 `.`/空格结尾、只允许 Unicode 字母数字与空格 `-` `_` `.`。路径分隔符、`..`、控制字符无法进入文件名。

## 三、运行事件

事件名：`lingxi:run-event`。payload 是带 `type` 标签的枚举，字段 camelCase。

| type | 关键字段 |
| --- | --- |
| `run.started` | `runId, workflowId, workflowName, nodeCount` |
| `node.started` | `runId, nodeId, kind, label` |
| `node.finished` | `runId, nodeId, kind, label, outputs, durationMs` |
| `node.failed` | `runId, nodeId, kind, label, code, message, durationMs` |
| `node.skipped` | `runId, nodeId, kind, label, reason` |
| `node.cancelled` | `runId, nodeId, kind, label` |
| `log` | `runId, seq, atMs, level, nodeId?, message` |
| `interaction.requested` | `runId, requestId, nodeId, prompt, options[]` |
| `interaction.resolved` | `runId, requestId, nodeId, decision` |
| `run.finished` | `runId, status, cause?, detail?, durationMs` |

顺序保证：事件由单个执行任务按序发出，`run.started` 一定先于该 run 的任何其他事件，`run.finished` 一定是最后一个。前端仍应按 `runId` 过滤，防止多窗口/残留事件串台。

### 一次成功运行

```json
{"type":"run.started","runId":"r1","workflowId":"wf-1","workflowName":"hello","nodeCount":2}
{"type":"node.started","runId":"r1","nodeId":"n-1","kind":"core.text_input","label":"Text Input"}
{"type":"log","runId":"r1","seq":0,"atMs":1770000000000,"level":"info","nodeId":null,"message":"run started: 2 node(s), 1 edge(s)"}
{"type":"node.finished","runId":"r1","nodeId":"n-1","kind":"core.text_input","label":"Text Input","outputs":{"text":"hello"},"durationMs":1}
{"type":"node.started","runId":"r1","nodeId":"n-2","kind":"core.text_uppercase","label":"Uppercase"}
{"type":"node.finished","runId":"r1","nodeId":"n-2","kind":"core.text_uppercase","label":"Uppercase","outputs":{"text":"HELLO"},"durationMs":0}
{"type":"log","runId":"r1","seq":1,"atMs":1770000000003,"level":"info","nodeId":null,"message":"run finished: Completed in 4 ms"}
{"type":"run.finished","runId":"r1","status":"completed","cause":null,"detail":null,"durationMs":4}
```

注意 `log.seq` 是单次运行内的日志序号，从 0 开始；它不是全局事件序号。

### 失败与取消

- 节点失败：`node.failed` → 依赖它的节点逐个 `node.skipped`（reason 含上游 ID）→ `run.finished{status:"failed", cause:"node_failed"}`。
- 用户取消：当前节点发 `node.cancelled` → `run.finished{status:"cancelled", cause:"cancelled"}`；未开始的节点不再发事件。
- 校验失败：命令直接返回 `started:false`，不产生事件。

## 四、交互协议

```
Approval executor
  └─ ctx.request_interaction(prompt, options)
       └─ PendingInteractions: insert(request_id, oneshot::Sender)
            ├─ emit interaction.requested
            └─ await oneshot
UI: 弹窗 → invoke respond_interaction({ requestId, approved })
       └─ broker.resolve(request_id, Approved|Rejected)
            ├─ emit interaction.resolved
            └─ wake executor
```

- `approved=true` → `InteractionDecision::Approved`；false → `Rejected`（节点以 `node.interaction_denied` 失败）。
- 决议只生效一次；重复/未知 `requestId` 返回 `false`。
- 等待上限 300 秒；超时以 `node.interaction_timeout` 失败，避免无人值守的运行永久挂起。
- 运行取消时，挂起交互的等待任务随节点被丢弃，不会阻塞停止流程。
- 当前只有 `core.approval` 使用该通道；协议本身与节点类型无关。

## 五、前端 Transport

```ts
export interface Transport {
  listNodeSpecs(): Promise<NodeSpec[]>;
  validateWorkflow(workflow: WorkflowDoc): Promise<ValidationReport>;
  runWorkflow(workflow: WorkflowDoc): Promise<RunStartResponse>;
  stopWorkflow(runId: string): Promise<boolean>;
  respondInteraction(requestId: string, approved: boolean): Promise<boolean>;
  workflowList(): Promise<WorkflowSummary[]>;
  saveWorkflow(name: string, workflow: WorkflowDoc): Promise<WorkflowSummary>;
  loadWorkflow(name: string): Promise<WorkflowDoc>;
  deleteWorkflow(name: string): Promise<boolean>;
  onRunEvent(handler: (event: RunEvent) => void): Promise<() => void>;
}
```

实现有两套：

- `tauriTransport`：真实 IPC，`onRunEvent` 返回取消监听的函数。
- `createMockTransport`：仅浏览器开发模式（`import.meta.env.DEV && !isTauri()`），内存文件 + 模拟事件；用于 UI 开发与自动化，不参与 Tauri 运行路径。

`api.ts` 在模块加载时二选一，UI 不感知差异。新增命令必须同时更新 `Transport`、两套实现与 Rust `generate_handler!`。

## 六、错误码

| 层 | 形态 | 示例 |
| --- | --- | --- |
| 命令失败 | 字符串 reject | `"workflow name contains an unsupported character: '/'"` |
| 校验问题 | `{code, severity, path, message}` | `edge.type_mismatch` |
| 节点执行失败 | `node.failed.code` | `node.missing_input` |
| 能力拒绝 | `node.failed.code` | `capability.denied` |
| 交互拒绝 | `node.failed.code` | `node.interaction_denied` |

稳定错误码清单见 `Docs/phase-0/02-node-spec-v1.md` 第五节。前端只对 code 做分支，不匹配 message 文本。

## 七、并发与生命周期

- 运行表是 `Mutex<HashMap<run_id, Arc<RunControl>>>`；`run_workflow` 插入，任务结束时移除。停止一个已结束的 run 返回 `false`。
- 引擎本身支持多个 run 并发（每个 run 独立控制令牌与事件流），但 UI 在 `status === "running"` 时禁止再次运行；这是产品约束，不是引擎限制。
- 应用退出时没有优雅停止协议：进行中的 run 随进程结束。Phase 0 不持久化运行状态。
- 事件没有重放/补发；如果 WebView 在 run 中途刷新，会丢失已发事件，后端运行仍会完成（但无人接收）。这是已知限制。

## 八、预留接口

| 接口 | 现状 | 设计意图 |
| --- | --- | --- |
| `NodeRegistry::register` | 公开，编译期调用 | 动态插件宿主复用同一签名 |
| `CapabilityPolicy` | trait + AllowAll | 资源权限层的唯一决策点 |
| `EventSink` | trait，Tauri 实现 | 可接 JSONL、远程订阅、测试记录器 |
| `InteractionBroker` | trait + oneshot 实现 | 可接 CLI/HTTP/多前端 |
| `schemaVersion` | 固定 `"1.0"` | 迁移与兼容读取 |
| `Workflow.metadata` | 原样保存 | 编辑器扩展，不参与执行 |

这些接口的共同约束：**运行时不得反向依赖宿主**。新增宿主（CLI、Web、测试）只实现 trait，不改引擎。
