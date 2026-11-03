# Phase 1.2.1 · 测试与验收记录

状态：macOS 实机验收通过；Windows/Linux 仅 CI 编译与单元测试，运行行为未验收。
基线：`rewrite/3.0`，Phase 1.2 的 48 项 Rust 测试与 13 项路由测试全部保留。

## 一、验收结论

| 验收项 | 结果 | 证据 |
| --- | --- | --- |
| 第二个实例被拒绝，第一个实例继续运行 | 通过 | 第二个进程输出错误并以 1 退出；第一个运行仍为 `running` |
| 第二个实例不触发启动恢复 | 通过 | 拒绝发生在 `runs.sqlite3` 打开前；第一个运行的 `last_seq=5` 未变 |
| 第二个实例不产生 panic/abort | 通过 | 修复后 stderr 只有一行错误，退出码 1；修复前为 `Abort trap: 6` |
| 释放锁后可再次启动 | 通过 | 单测覆盖 Drop；实机重启正常打开应用 |
| 顶层 `NodeFinished.outputs` 敏感键脱敏 | 通过 | 实机 `{"text":"token=[REDACTED]"}`；单测覆盖 `apiKey` |
| 实时事件与 SQLite 事件一致 | 通过 | 两处均为单层 `[REDACTED]`；单测逐字段比较 |
| 终态 detail 脱敏 | 通过 | 单测断言 `runs.detail` 与读取结果均为 `token=[REDACTED]` |
| 重复脱敏不产生 `[[REDACTED]]` | 通过 | 幂等单测 + 实机日志 |
| 前端事件重放排序/去重/补洞/跳过 | 通过 | 6 项纯函数测试全部通过 |
| 原有 48 项 Rust、13 项路由无回归 | 通过 | 54 项 Rust 全绿；路由 13/13 |
| Windows/Linux CI | 待本次提交后验证 | 见第六节 |

## 二、自动化测试

命令：

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
pnpm --dir apps/desktop build
pnpm --dir apps/desktop test:events
pnpm --dir apps/desktop test:routing
```

结果：`cargo test --workspace` **54 passed，0 failed**。

| 测试包 | 数量 | 说明 |
| --- | --- | --- |
| `lingxi-spec` | 19 | 11 基础校验 + 8 控制流静态规则，未改动 |
| `lingxi-runtime` | 16 | 7 engine + 7 control_flow + 2 event_sequence，未改动 |
| `lingxi-desktop` | 19 | 3 工作流存储 + 7 runs + 7 redact + 1 single_instance + 1 lib |
| 合计 | 54 | Phase 1.2 的 48 项全部保留 |

新增/相关测试：

- `a_second_owner_is_refused_until_the_first_releases`：同一锁路径第二次 `acquire` 返回“already running”，Drop 后可重新获取。
- `a_second_instance_cannot_interrupt_the_first_instances_run`：第一个 `AppState` 持有运行记录时，第二个实例在打开运行库前失败；第一个记录仍为 `running`；释放后第二个实例启动恢复为 `interrupted`。
- `redacting_an_already_redacted_event_is_stable`：对已脱敏事件再次 `redact_event`，序列化结果完全一致。
- `redaction_is_idempotent`：`token=[REDACTED]` 不增长括号；Bearer/Basic 与引号形式已脱敏时跳过。
- `persisted_events_match_live_redaction_for_top_level_outputs`：`apiKey` 顶层输出、嵌套 `accessToken` 与安全字段在实时与 SQLite 中逐字段相等。
- `terminal_detail_is_redacted_in_the_run_record`：失败终态 detail 写入 SQL 前与读出后均为脱敏文本。
- `apps/desktop/tests/eventReplay.test.mjs`：6 项，覆盖顺序、重复、补洞、空补拉跳过、补拉失败继续、游标推进后的迟到事件去重。

前端构建：`pnpm --dir apps/desktop build` 通过（208 modules，JS 376.16 kB / gzip 121.61 kB）；事件重放 6/6；路由 13/13。

## 三、macOS 实机 Tauri 验收

环境：macOS Apple Silicon，Tauri 2，真实 Rust 后端。
数据目录：`/Users/lingxifox/Library/Application Support/site.lingxi.desktop`。

### 3.1 单实例

1. 第一个实例加载 `Approval Demo`，点击运行，审批节点挂起；SQLite 记录
   `7bd3a1d3-0378-4a14-a6df-91766eeba725|running|Approval Demo|5`。
2. 直接运行 `target/debug/lingxi-desktop` 启动第二个实例。
3. 修复前：第二个进程打印“already running”后触发 Tauri setup panic，macOS 报
   `libc++abi: terminating due to uncaught foreign exception`、`Abort trap: 6`，退出码 134。
4. 修复 `lib.rs` 的 setup 错误处理后：第二个进程只打印

   ```text
   LingXiAgent cannot start: another LingXiAgent instance is already running
   ```

   退出码 1；第一个进程窗口正常，运行状态仍为 `running`，`last_seq=5` 未变化。
5. 在第一个实例点击“终止”，记录变为 `cancelled|8`，说明终止路径仍正常。

结论：锁在运行库打开前生效，第二个实例无法触发启动恢复；失败路径不再产生崩溃报告。

### 3.2 脱敏一致性

测试工作流 `Phase 1.2.1 Redaction`：`text_input -> approval -> log`，文本输入参数为
`token=super-secret`，审批通过后日志输出该值。

1. 运行后实时日志显示：
   - `✓ Text Input · 0ms · {"text":"token=[REDACTED]"}`
   - `✓ Approval Gate · 19487ms · {"payload":"token=[REDACTED]"}`
   - `demo token=[REDACTED]`
2. SQLite 同一运行 `3095223b-1dd8-4c14-8a3c-a0ef749cdbe1`，终态 `completed`，`last_seq=12`：
   - `seq 3 node.finished` 的 `outputs` 为 `{"text":"token=[REDACTED]"}`；
   - `seq 7 node.finished` 的 `outputs` 为 `{"payload":"token=[REDACTED]"}`；
   - `seq 9 log` 的 `message` 为 `demo token=[REDACTED]`。
3. 实时与持久化均为单层 `[REDACTED]`，没有 `[[REDACTED]]`，也没有保留 `super-secret`。
4. 测试结束后删除临时工作流文件，未保留测试数据。

证据：`Docs/phase-1.2.1/assets/redaction-run.png`。

## 四、数据库检查

```sql
-- 单实例验收时，第二个实例启动前后
SELECT run_id, status, last_seq FROM runs
WHERE run_id = '7bd3a1d3-0378-4a14-a6df-91766eeba725';

-- 脱敏验收：运行终态与事件
SELECT run_id, status, last_seq FROM runs
WHERE run_id = '3095223b-1dd8-4c14-8a3c-a0ef749cdbe1';

SELECT seq, event_type, payload FROM run_events
WHERE run_id = '3095223b-1dd8-4c14-8a3c-a0ef749cdbe1'
ORDER BY seq;
```

观测：单实例测试期间第一个运行保持 `running`；脱敏运行的事件 seq 从 0 到 12 连续，所有包含密钥的 payload 均已替换。

## 五、安全与失败语义

- 锁获取使用 SQLite 原生 `BEGIN EXCLUSIVE`，不依赖平台专有 API；锁连接在 `AppState` 生命周期内持有，进程退出或 Drop 时释放。
- 锁失败在打开运行库之前返回，避免“第二个实例把第一个实例标成中断”的数据破坏。
- 锁失败走 `std::process::exit(1)`，避免 Tauri 把 setup 错误升级为 panic/abort。
- 实时与持久化共用 `redact_event`；`redacted_event_json` 不再自行递归，避免两条路径漂移。
- `runs.detail` 在写入、读取和中断路径均脱敏，兼容旧库中的未脱敏历史记录。
- 脱敏仍是启发式，不是凭据保险箱；用户不应把真实密钥直接写入节点参数。

## 六、CI

本次提交推送后运行 GitHub Actions。预期四个 job：

- Frontend (TypeScript + Vite)：构建、13 项路由测试、6 项事件重放测试。
- Rust (macos-latest)：格式、Clippy、`cargo test --workspace`。
- Rust (ubuntu-24.04)：同上。
- Rust (windows-latest)：同上。

Windows/Linux 未做 Tauri 运行态验收；单实例锁、SQLite 路径、第二实例退出码、WebView 刷新等仅 macOS 实测。

## 七、已知问题

1. 单实例锁只在同一数据目录内生效；不同数据目录可并存。
2. 网络文件系统上的 SQLite 锁语义未验收。
3. 第二个实例不激活已有窗口，只打印错误并退出。
4. 脱敏是启发式模式匹配，自定义敏感键仍可能漏过。
5. 真实值恰好为 `[REDACTED]` 时会被幂等逻辑视为已脱敏。
6. 前端重放纯函数有单测，但订阅/快照接线仍由实机流程覆盖。
7. Windows/Linux 运行行为未验收。
8. 锁数据库文件会残留，不影响下次启动；未提供清理命令。
