# Phase 1.2 · 运行状态持久化与事件恢复

状态：已实现。Rust 自动化测试与 macOS 实机 Tauri 验收通过；Windows/Linux 仅通过 CI 编译与单元测试，运行行为未验收。
范围：事件序号、SQLite 运行历史、刷新重连、异常退出识别、运行管理、事件脱敏。

## 一、目标与非目标

目标：UI 刷新或应用重启后，运行状态不再依赖内存；事件可去重、可补洞、可按序恢复；异常退出不会被伪装成成功；数据库写入失败必须显式暴露。

非目标：断点续跑、自动恢复执行、分布式运行、运行历史导出、SQLite 迁移框架、真实 LLM/MCP/Skills。

## 二、兼容性

- 工作流 JSON 格式不变，仍为 `schemaVersion = "1.0"`；SQLite 只保存运行记录与事件，不替代工作流文件。
- `RunStatus` 新增 `interrupted`，`RunCause` 新增 `interrupted`。旧运行不存在该状态。
- 所有 `RunEvent` 新增必填字段 `seq: u64`。这是运行时事件协议的破坏性变更，但 3.0 尚无外部事件消费者；前端、mock、测试同步更新。
- 既有节点、端口、控制流语义、校验规则均未改动。

## 三、分层与依赖

```
lingxi-spec  <-  lingxi-runtime  <-  apps/desktop/src-tauri
（纯数据）      （EventSink）        （SQLite + Tauri IPC）
```

- Runtime 只认识 `EventSink` trait，不知道 SQLite、Tauri 或窗口存在。
- `RunDatabase`、脱敏、Tauri 命令全部位于桌面壳。
- 工作流文件仍由 `WorkflowStore` 以 JSON 原子写入；运行历史单独存放在 `runs.sqlite3`。

## 四、事件序号协议

`crates/lingxi-runtime/src/event.rs` 新增 `EventEmitter<'a>`：

```rust
pub struct EventEmitter<'a> {
    sink: &'a dyn EventSink,
    next_seq: AtomicU64,
}

impl<'a> EventEmitter<'a> {
    pub fn new(sink: &'a dyn EventSink) -> Self;
    pub fn allocate_seq(&self) -> u64;
    pub fn emit(&self, event: RunEvent) -> u64;
    pub fn emit_with_seq(&self, event: RunEvent, seq: u64);
    pub fn log(&self, run_id: &str, level: LogLevel, node_id: Option<&str>, message: impl Into<String>);
}
```

规则：

1. 每次运行从 `0` 开始，事件按产生顺序连续递增，无空洞。
2. 序号只由 `EventEmitter` 分配；引擎、控制调度器、普通节点都通过它发事件。
3. `RunEvent::seq()` 读取序号；`set_seq` 私有，避免外部伪造。
4. 交互请求 ID 使用 `run_id:node_id:seq`，与事件序号一致。
5. 同一运行由单任务顺序执行，因此 `run.started` 必为首事件、`run.finished` 必为末事件。
6. `EventSink::emit` 约定为快速、非阻塞；桌面壳在转发前同步落库。

编号不写入工作流 JSON，也不跨运行复用。

## 五、SQLite 存储

位置：`app_data_dir/runs.sqlite3`（macOS 为 `~/Library/Application Support/site.lingxi.desktop/runs.sqlite3`）。

```sql
CREATE TABLE runs (
    run_id          TEXT PRIMARY KEY,
    workflow_id     TEXT NOT NULL,
    workflow_name   TEXT NOT NULL,
    status          TEXT NOT NULL,          -- running/completed/failed/cancelled/interrupted
    cause           TEXT,
    detail          TEXT,
    started_at_ms   INTEGER NOT NULL,
    finished_at_ms  INTEGER,
    duration_ms     INTEGER,
    node_count      INTEGER NOT NULL,
    workflow_json   TEXT NOT NULL,          -- 脱敏后的工作流快照
    last_seq        INTEGER NOT NULL DEFAULT -1
);

CREATE TABLE run_events (
    run_id      TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    seq         INTEGER NOT NULL,
    at_ms       INTEGER NOT NULL,
    event_type  TEXT NOT NULL,
    payload     TEXT NOT NULL,              -- 脱敏后的 RunEvent JSON
    PRIMARY KEY (run_id, seq)
);

CREATE INDEX run_events_run_seq ON run_events(run_id, seq);
```

连接配置：`journal_mode = WAL`、`synchronous = FULL`、`foreign_keys = ON`、`busy_timeout = 5000`。所有访问经过 `Mutex<Connection>`，单进程串行写入。

写入生命周期：

1. `run_workflow` 校验通过后生成 `run_id`，先 `create_run`（`status='running'`、`last_seq=-1`），失败直接返回 `cannot persist run start: ...`，不启动执行。
2. 每个事件一个事务：读取 `last_seq`；`seq <= last_seq` 视为重复，忽略；`seq != last_seq + 1` 返回显式缺口错误；否则插入事件、更新 `last_seq`。
3. 若事件是 `run.finished`，同一事务内更新终态、cause、detail、结束时间与耗时。
4. 事务提交后才算持久化成功。

`append_event` 返回 `AppendOutcome::{Appended, Duplicate}`；缺口、缺运行记录、SQL 错误均为 `Err(String)`。

## 六、持久化失败语义

`TauriSink::emit` 顺序固定：

```rust
let event = redact_event(&event);
if let Err(error) = self.db.append_event(&event) {
    // 只报一次 lingxi:persistence-error
    // 立即 control.cancel()，不再产生新工作
}
let _ = self.app.emit(RUN_EVENT, &event);
```

- UI 顶部显示“持久化失败”固定告警，日志同时记一条 error。
- 运行被取消，而不是继续执行却假装已持久化。
- 当前事件仍转发给 UI，避免界面停在未知状态；前端可凭告警判断历史不完整。
- 启动时数据库打不开会让 AppState 初始化失败，应用直接报错退出，不做静默降级。

## 七、异常退出恢复

两条路径：

1. **启动扫描**：`AppState::new` 打开数据库后立即 `mark_interrupted_at_startup()`，把所有 `status='running'` 的运行改为 `interrupted`，并在 `last_seq + 1` 插入一条合成 `run.finished`，detail 为 `app restarted before the run finished`。
2. **任务守卫**：`RunTaskGuard` 在运行任务结束时移除 `RunControl`，并调用 `mark_interrupted`。若引擎 panic 或漏发终态事件，该运行也会被标为 `interrupted`。

`interrupted` 是独立终态：

- 不会改写成 `completed`。
- 不会自动重新执行，也不会自动恢复节点状态。
- 历史列表显示“已中断”，详情包含 cause 与合成终态事件。

## 八、刷新重连与竞态

前端 `apps/desktop/src/App.tsx` 的顺序是固定的：

```
挂载
  → 订阅 lingxi:run-event / lingxi:persistence-error
  → 等待订阅真正注册完成（bridgeReady）
  → 拉取 active_run 快照（工作流 + 已持久化事件）
  → applyDoc 恢复画布
  → 快照事件入队
  → 结束 recovering，开始 drain
  → 队列按 runId + seq 排序、去重、补洞、应用
```

关键点：

- **先订阅，后取快照**。快照返回前到达的实时事件先进入缓冲区，不会被丢弃。
- 快照事件和实时事件进入同一个有序队列；同一运行按 `seq` 排序，先快照后实时或反之都能合并。
- `appliedSeqRef: Map<runId, seq>` 记录已应用序号；`seq <= applied` 直接丢弃，解决重复。
- 发现 `seq > applied + 1` 时调用 `run_events(runId, applied)` 补拉缺失区间，插入队列后重新 drain。
- 补拉仍缺口时记录 `event gap ... missing` 并显式推进游标，不让队列永久卡死；不伪造事件。
- 仅当 `recovering = false` 时 drain 实时事件；恢复期间只入队。
- `run.started` 可以把当前运行切换到新 runId；其他运行的事件若 runId 不匹配则忽略，防止旧运行终态覆盖新运行。
- 刷新不会调用 `run_workflow`，因此不会重复启动任务。活动运行来自数据库中最新一条 `status='running'` 记录。

事件在写入 SQLite 成功后才转发，因此缺口补拉读到的始终是已提交数据。

## 九、运行管理与 UI

新增 4 个 Tauri 命令（总计 13 个）：

| 命令 | 参数 | 返回 |
| --- | --- | --- |
| `run_list` | `limit?: u32`（默认 50，上限 200） | `RunRecord[]`，按开始时间倒序 |
| `run_detail` | `runId` | `RunDetail \| null`（记录 + 工作流快照 + 全部事件） |
| `run_events` | `runId`, `afterSeq?: u64` | 该序号之后的 `RunEvent[]` |
| `active_run` | 无 | 最新 `running` 运行的 `RunDetail \| null` |

前端工具栏新增“历史”按钮，打开 `RunHistoryDialog`：左侧运行列表（状态、工作流名、时间、耗时），右侧详情（cause、detail、逐条事件及 seq）。保留原有运行、终止、审批。未新增右侧面板或仪表盘。

## 十、脱敏

`apps/desktop/src-tauri/src/redact.rs` 两层：

- `redact_json`：递归替换敏感键（token、apiKey、secret、password、authorization、credential、privateKey 等）的值。
- `redact_text`：识别 Bearer/Basic、`sk-`、`ghp_`、`github_pat_`、`xoxb-`、`xoxp-`、`AKIA`、`key=value` 等形态。

`redact_event` 对工作流名、节点 label、节点输出、错误信息、跳过原因、日志、交互提示与选项、运行 detail 全部脱敏。TauriSink 在**落库前和转发前**都使用脱敏后的事件；工作流快照也在 `create_run` 时脱敏。数据库测试断言密钥不出现在 `payload` 中。

局限：这是模式匹配，不是密钥管理系统；未知格式或用户自定义字段名仍可能泄漏。后续应接入统一凭据引用，而不是把密钥放进节点参数。

## 十一、涉及文件

- `crates/lingxi-runtime/src/event.rs`：seq、`EventEmitter`、`Interrupted`
- `crates/lingxi-runtime/src/engine.rs`、`control_flow.rs`、`context.rs`：改用 emitter
- `crates/lingxi-runtime/tests/event_sequence.rs`：序号连续性
- `apps/desktop/src-tauri/src/runs.rs`：SQLite 运行库
- `apps/desktop/src-tauri/src/redact.rs`：脱敏
- `apps/desktop/src-tauri/src/commands.rs`：持久化 sink、运行命令
- `apps/desktop/src-tauri/src/lib.rs`：数据库初始化与启动恢复
- `apps/desktop/src/App.tsx`：订阅/快照/补洞/去重
- `apps/desktop/src/components/RunHistoryDialog.tsx`：历史 UI
- `apps/desktop/src/lib/{types,transport,tauri,mock,log}.ts`：协议与 mock

## 十二、已知限制

1. 前端只有运行历史，没有“重新载入历史运行到画布”的入口；`run_detail` 已返回工作流快照，后续可直接复用。
2. 刷新后若运行已经结束，`active_run` 为空，画布保持空白；完成状态只出现在历史与上一次页面状态中。
3. 脱敏是启发式，无法覆盖任意自定义敏感键。
4. SQLite 无迁移框架；当前只有 v1 schema，字段变化需手写迁移。
5. 数据库损坏或无法打开时应用拒绝启动，没有只读/降级模式。
6. Windows/Linux 仅 CI 编译与单测，运行行为未实机验收。
