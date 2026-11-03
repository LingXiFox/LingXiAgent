# Phase 1.2.1 · 单实例保护与脱敏一致性

状态：已实现。Rust 自动化测试、前端事件重放测试与 macOS 实机 Tauri 验收通过；Windows/Linux 仅通过 CI 编译与单元测试，运行行为未验收。
范围：单实例互斥、实时/持久化事件脱敏一致性、事件重放纯函数测试、CI 门禁。
基线：`rewrite/3.0`，Phase 1.2 的 48 项 Rust 测试与 13 项路由测试全部保留。

## 一、目标与非目标

Phase 1.2 留下两个需要在进入下一阶段前收口的问题：

1. 两个桌面实例共用同一个数据目录时，后启动实例的启动扫描会把前一个实例仍在运行的记录改成 `interrupted`。
2. 实时事件与 SQLite 事件使用两条脱敏路径。嵌套输出会被递归脱敏，但 `NodeFinished.outputs` 顶层的敏感键可能只经过 `redact_json` 而未被替换，造成 UI 与数据库不一致。

本阶段目标：在同一数据目录上只允许一个桌面进程持有运行状态；实时与持久化事件使用同一个脱敏函数且重复执行稳定；把前端事件重放逻辑抽成可单测的纯函数；把这些测试纳入 CI。

非目标：不新增协议字段，不改变工作流 JSON，不新增 Tauri 命令，不做分布式锁，不做运行断点续跑，不实现凭据管理系统，不改变节点执行语义。

## 二、兼容性

- 工作流 JSON 仍为 `schemaVersion = "1.0"`，无字段变化。
- `RunEvent` 结构与 `seq` 语义不变。
- SQLite `runs` / `run_events` schema 不变。
- 新增文件仅 `instance.lock.sqlite3`（运行期锁，不是用户数据）与前端纯函数模块。
- 既有 48 项 Rust 测试、13 项路由测试全部保留。

## 三、单实例保护

### 3.1 机制

新增 `apps/desktop/src-tauri/src/single_instance.rs`。锁文件位于 `app_data_dir/instance.lock.sqlite3`，与 `runs.sqlite3` 分离，避免锁事务影响运行库的正常读写。

```rust
pub struct InstanceLock {
    connection: Mutex<Connection>,
}

impl InstanceLock {
    pub fn acquire(path: &Path) -> Result<Self, String>;
}

impl Drop for InstanceLock {
    fn drop(&mut self) { /* ROLLBACK */ }
}
```

获取流程：

1. 创建父目录（如不存在）。
2. `Connection::open` 打开专用锁库。
3. `busy_timeout(250ms)`，避免第二个实例长时间阻塞。
4. 执行 `PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE;`。
5. 成功后在 `AppState` 中持有连接直到进程退出；`Drop` 执行 `ROLLBACK` 释放 OS 锁。

SQLite 的文件锁由操作系统提供，macOS/Windows/Linux 均可用；没有引入新的平台依赖或第三方锁库。

### 3.2 获取顺序

`AppState::new` 的顺序被固定为：

```text
acquire(instance.lock.sqlite3)
  -> open(runs.sqlite3)
  -> mark_interrupted_at_startup()
  -> build registry / store / state
```

锁必须在打开运行库和启动恢复之前获取。这样第二个实例在触及 `runs.sqlite3` 前就失败，不会把第一个实例的 `running` 记录改成 `interrupted`。

### 3.3 退出语义

Tauri 会把 `setup` 返回的错误转成 panic/abort，在 macOS 上表现为 `Abort trap: 6` 和崩溃报告。单实例失败不是异常崩溃，而是正常的“已有实例”退出，因此 `apps/desktop/src-tauri/src/lib.rs` 对两类错误改为显式处理：

```rust
let data_dir = match app.path().app_data_dir() {
    Ok(path) => path,
    Err(error) => {
        eprintln!("LingXiAgent cannot start: cannot resolve app data directory: {error}");
        std::process::exit(1);
    }
};
let state = match AppState::new(data_dir) {
    Ok(state) => state,
    Err(error) => {
        eprintln!("LingXiAgent cannot start: {error}");
        std::process::exit(1);
    }
};
```

`tauri::Builder::run` 的返回值也不再 `expect`，统一打印后 `exit(1)`。第二个实例只输出：

```text
LingXiAgent cannot start: another LingXiAgent instance is already running
```

退出码为 1，不产生 panic，不影响第一个实例。

### 3.4 限制

- 这是单机、单数据目录的进程锁；不支持多用户共享同一目录。
- 网络文件系统（NFS/SMB）上的 SQLite 文件锁语义不保证，本阶段未验收。
- 锁数据库文件会残留，但残留文件本身不阻止下次启动；是否持有锁取决于是否存在活跃事务。
- 第二个实例目前只写 stderr，不负责把已有窗口带到前台；这是后续桌面体验工作。

## 四、脱敏一致性

### 4.1 单一事件脱敏契约

`apps/desktop/src-tauri/src/redact.rs` 的 `redact_event(&RunEvent) -> RunEvent` 成为实时与持久化共用的唯一事件脱敏函数。

Phase 1.2.1 补齐 `NodeFinished` 顶层输出：

```rust
RunEvent::NodeFinished { label, outputs, .. } => {
    *label = redact_text(label);
    for (name, value) in outputs.iter_mut() {
        if is_sensitive_key(name) {
            *value = Value::String(REDACTED.to_string());
        } else {
            redact_json(value);
        }
    }
}
```

规则：

- 顶层键名命中 `is_sensitive_key`（`apiKey`、`token`、`secret`、`password`、`authorization`、`credential` 等）时，整个值替换为字符串 `[REDACTED]`，不再保留原类型。
- 非敏感键继续走 `redact_json` 递归处理，保留嵌套对象中的非敏感字段。
- 节点 label、日志、错误、交互 prompt/options、运行 detail、工作流名与快照仍按原规则脱敏。

### 4.2 两条路径

实时转发：

```rust
// apps/desktop/src-tauri/src/commands.rs · TauriSink::emit
let event = redact_event(&event);
if let Err(error) = self.db.append_event(&event) { /* 持久化失败 */ }
let _ = self.app.emit(RUN_EVENT, &event);
```

持久化：

```rust
// apps/desktop/src-tauri/src/runs.rs
fn redacted_event_json(event: &RunEvent) -> Result<String, String> {
    serde_json::to_string(&redact_event(event))
        .map_err(|error| format!("cannot encode redacted event: {error}"))
}
```

`TauriSink` 在转发前已经脱敏，`append_event` 又会通过 `redacted_event_json` 再脱敏一次。因此 `redact_event` 必须幂等：对已含 `[REDACTED]` 的文本再次执行不能变成 `[[REDACTED]]`。

幂等实现覆盖：

- `key=value` 的 value 已以 `[REDACTED]` 开头时不再截取；
- `Authorization: Bearer [REDACTED]` 的 token 已脱敏时不再截取；
- 引号包裹的 `"client_secret": "[REDACTED]"` 内部已脱敏时跳过；
- 顶层敏感键再次输入时仍替换为同一个 `[REDACTED]` 字符串。

### 4.3 终态 detail

Phase 1.2 的 `RunFinished.detail` 在事件 payload 中已脱敏，但 `runs.detail` 列可能保留原始文本。本阶段补齐：

- `interrupt_run` 写库前对 detail 调用 `redact_text`；
- `update_run_terminal` 写 `runs.detail` 前脱敏；
- `row_to_record` 读库时再次脱敏，兼容旧数据库中已存在的未脱敏记录。

### 4.4 设计取舍

选择“统一函数 + 幂等”而不是“每个 sink 自己判断是否已脱敏”，原因是：

- 两个 sink 不可能长期保持同步；任何新增事件字段都容易只改一边。
- 幂等让调用顺序安全：先实时脱敏再落库、先落库再转发都不会改变结果。
- 代价是文本中真实值恰好为 `[REDACTED]` 时会被当作已脱敏而跳过，这是可接受的误判，不会泄漏真实密钥。

## 五、前端事件重放纯函数

`apps/desktop/src/App.tsx` 原先内联了队列排序、去重、补洞和跳过逻辑。本阶段抽出：

```ts
// apps/desktop/src/lib/eventReplay.ts
export function enqueueRunEvent(queue: RunEvent[], event: RunEvent): void;
export async function drainEventQueue(
  queue: RunEvent[],
  applied: Map<string, number>,
  fetchMissing: (runId: string, afterSeq?: number) => Promise<RunEvent[]>,
  hooks: { apply(event: RunEvent): void; log(level: "warn" | "error", message: string): void },
): Promise<EventDrainSummary>;
```

语义与 Phase 1.2 相同：

1. 同一 `runId` 按 `seq` 插入，快照与实时事件可交错。
2. `seq <= applied` 视为重复，直接丢弃。
3. `seq > applied + 1` 时调用 `run_events(runId, applied)` 补拉；只接受同 run、落在缺口内的记录。
4. 补拉为空或失败时记录显式警告并推进游标，绝不永久阻塞队列。
5. 返回 `applied/duplicates/recovered/skipped` 计数，便于测试与后续诊断。

`App.tsx` 只保留 ref 和依赖注入，不再重复实现排序规则。

## 六、涉及文件

- `apps/desktop/src-tauri/src/single_instance.rs`：SQLite 进程锁。
- `apps/desktop/src-tauri/src/lib.rs`：锁获取顺序、启动失败退出码、集成测试。
- `apps/desktop/src-tauri/src/redact.rs`：顶层输出脱敏、幂等处理。
- `apps/desktop/src-tauri/src/runs.rs`：统一 `redacted_event_json`、detail 写读脱敏、回归测试。
- `apps/desktop/src/lib/eventReplay.ts`：队列排序、去重、补洞纯函数。
- `apps/desktop/src/App.tsx`：改用纯函数。
- `apps/desktop/tests/eventReplay.test.mjs`：6 项事件重放测试。
- `.github/workflows/ci.yml`：新增 `pnpm test:events`。

## 七、已知限制

1. 单实例锁只在同一数据目录内生效；不同 `--config` / 不同用户目录可并存。
2. 网络文件系统上的 SQLite 锁未验收。
3. 第二个实例没有“激活已有窗口”的交互，仅退出并打印错误。
4. 脱敏仍是启发式模式匹配，不覆盖任意自定义敏感键；真正的凭据引用层尚未实现。
5. 幂等实现会把真实值 `[REDACTED]` 视为已脱敏。
6. 前端重放纯函数有单测，但 App 内的订阅/快照接线仍由 macOS 实机流程覆盖，没有浏览器自动化测试。
7. Windows/Linux 仅 CI 编译与单测，运行行为未实机验收。
