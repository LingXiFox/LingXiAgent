# Phase 1.2 · 测试与验收记录

状态：macOS 实机验收通过；Windows/Linux 仅 CI 编译与单元测试，运行行为未验收。
基线：`rewrite/3.0`，Phase 1.1.1 的 36 项 Rust 测试与 13 项路由测试全部保留。

## 一、验收结论

| 验收项 | 结果 | 证据 |
| --- | --- | --- |
| 运行中刷新，不重复启动，状态恢复 | 通过 | 重连日志、事件 seq 0..12、完成于 170.01s |
| 刷新期间事件不丢不重 | 通过 | 6 条历史事件补发；实时事件按 seq 去重；详情连续 |
| 正常完成持久化 | 通过 | 历史“已完成 170.01s”，终态事件 seq 12 |
| 失败持久化 | 通过 | 拒绝审批，历史“失败 26.27s”，事件 seq 0..10 |
| 取消持久化 | 通过 | 终止运行，历史“已终止 8.20s”，事件 seq 0..8 |
| 异常退出识别为中断 | 通过 | `kill -9` 后重启，`interrupted`，seq 6 合成终态 |
| 中断不伪装完成、不自动重跑 | 通过 | 重启后画布为空，无运行请求，状态“已中断” |
| 运行列表/详情/历史事件 | 通过 | 历史对话框四类终态 |
| 数据库写入失败显式报告 | 代码路径 + 单测通过 | `PRAGMA query_only=ON` 注入失败；UI 告警未做实机故障注入 |
| 密钥不进入日志/持久化 | 单测通过 | 文本与 JSON 脱敏、转发前脱敏 |
| 原有 36 项 Rust + 13 项路由无回归 | 通过 | 48 项 Rust 全绿；路由 13/13 |
| Windows/Linux CI | 通过 | 见第六节 |

## 二、自动化测试

命令：

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
pnpm --dir apps/desktop build
pnpm --dir apps/desktop test:routing
```

结果：`cargo test --workspace` **48 passed，0 failed**。

| 测试包 | 数量 | 说明 |
| --- | --- | --- |
| `lingxi-spec` | 19 | 11 基础校验 + 8 控制流静态规则，未改动 |
| `lingxi-runtime` | 16 | 7 engine + 7 control_flow + 2 event_sequence |
| `lingxi-desktop` | 13 | 3 工作流存储 + 5 runs + 5 redact |
| 合计 | 48 | 原有 36 项全部保留 |

新增测试：

- `every_event_gets_a_contiguous_sequence`：一条运行内 seq 从 0 连续到 n-1。
- `sequence_restarts_for_each_run`：不同运行各自从 0 开始。
- `terminal_state_and_events_are_persisted`：完成后记录终态与事件。
- `gaps_are_rejected_and_duplicates_are_ignored`：重复 seq 忽略，缺口报错。
- `startup_marks_running_runs_interrupted`：启动扫描写合成终态。
- `write_failures_are_reported`：只读连接下 `append_event` 必须返回错误。
- `secrets_are_redacted_before_sqlite`：API key 参数与日志 token 不落库。
- `live_events_are_redacted_before_forwarding`：转发前日志/输出/终态 detail 已脱敏。
- `bearer_and_api_key_shapes_are_redacted`、`sensitive_json_keys_are_redacted_recursively`、`ordinary_log_text_is_unchanged`、`token_like_but_safe_keys_are_not_redacted`。

前端：`pnpm --dir apps/desktop build` 通过（207 modules，JS 375.59 kB / gzip 121.26 kB）；`pnpm --dir apps/desktop test:routing` 13/13，未回归。

## 三、macOS 实机 Tauri 验收

环境：macOS Apple Silicon，Tauri 2，真实 Rust 后端，数据库
`/Users/lingxifox/Library/Application Support/site.lingxi.desktop/runs.sqlite3`。

测试工作流 `Phase 1.2 断线恢复验证`：`text_input -> approval -> log`，审批节点无限等待，便于制造长运行。

### 3.1 刷新重连

1. 运行工作流，审批节点挂起。
2. 在 Web Inspector 执行 `location.reload()`（Tauri 的 Cmd+R 不重载 WKWebView）。
3. 页面恢复后状态为“运行中”，日志出现 `reconnected to run · Phase 1.2 断线恢复验证 · 6 events replayed`，节点状态恢复，审批按钮仍在。
4. 点击批准，运行继续并完成，总耗时 170.01s。

证据：`Docs/phase-1.2/assets/reconnected-run.png`、`Docs/phase-1.2/assets/run-history.png`。
运行详情事件 `#0..#12` 连续，终态 `#12 run finished Completed 170011ms`。刷新没有产生第二个 `run_id`，也没有第二次 `run_workflow`。

### 3.2 异常退出

1. 再次运行，审批挂起。
2. `kill -9` 桌面进程。
3. 重启应用。数据库原记录为 `status=running, last_seq=5`；启动扫描后变为 `interrupted`，写入 `#6 run interrupted · 41429ms · app restarted before the run finished`。
4. 画布为空，没有自动运行，历史列表显示“已中断 41.43s”。

证据：`Docs/phase-1.2/assets/restarted.png`、`Docs/phase-1.2/assets/interrupted-run.png`。

### 3.3 失败与取消

- 拒绝审批：运行失败，`resume-approval` 报 `node.interaction_denied`，历史“失败 26.27s”，事件 `#0..#10`。
- 终止：审批挂起时点击“终止”，历史“已终止 8.20s”，事件 `#0..#8`。
- 历史列表同时存在 `已完成 170.01s`、`失败 26.27s`、`已终止 8.20s`、`已中断 41.43s`。

证据：`Docs/phase-1.2/assets/failed-run.png`、`Docs/phase-1.2/assets/cancelled-run.png`。

### 3.4 最终构建冒烟

在完成脱敏与文档修改后的最终构建上重新启动应用，加载计数器示例并运行：5 节点 / 7 连线，状态“已完成”，循环门、计数器、条件、日志均显示“迭代 3”，日志包含 `loop exited after 3 iteration(s)`、`count: 3.0`、`run completed · 10ms`。随后打开运行历史，最新记录为“已完成 · 计数器循环示例 · 5 节点 · 10ms”。

证据：`Docs/phase-1.2/assets/final-build-smoke.png`。

## 四、数据库检查

```sql
-- runs：四类终态
SELECT run_id, workflow_name, status, cause, duration_ms, last_seq
FROM runs ORDER BY started_at_ms DESC;

-- run_events：每个运行 seq 连续
SELECT run_id, COUNT(*) AS events, MIN(seq) AS first_seq, MAX(seq) AS last_seq
FROM run_events GROUP BY run_id;
```

观测：中断运行 `last_seq=6` 且有 7 条事件；其余运行事件数与 `last_seq + 1` 一致。重启后没有新增 `run_workflow` 调用。

## 五、安全与失败语义验证

- 单元测试把 `apiKey` 写入节点参数与日志，读取 `run_events.payload` 断言只含 `[REDACTED]`。
- 直播事件在 `TauriSink::emit` 内先 `redact_event` 再落库/转发，避免“数据库安全但 UI 泄漏”。
- `PRAGMA query_only = ON` 后 `append_event` 返回 `cannot append run event`；此时 `TauriSink` 会发 `lingxi:persistence-error` 并取消运行。
- 未做真实磁盘满/权限拒绝的 UI 故障注入；该项由数据库层单测覆盖，UI 告警路径为代码审查确认。

## 六、CI

GitHub Actions run [41651790983](https://github.com/LingXiFox/LingXiAgent/actions/runs/41651790983)（提交 `9afef4e`）四个 job 全部 success：

- Frontend (TypeScript + Vite)：构建与 13 项路由测试通过。
- Rust (macos-latest)：`cargo test --workspace` 通过。
- Rust (ubuntu-24.04)：Rust 检查与单元测试通过。
- Rust (windows-latest)：Rust 检查与单元测试通过。

Windows/Linux 未做 Tauri 运行态验收，仅编译与单元测试通过；SQLite 路径、窗口刷新、`kill -9` 恢复未在这两个平台实测。

## 七、已知问题

1. 刷新后若运行已结束，`active_run` 返回空，画布不会自动恢复该次工作流；需从历史查看。
2. 历史详情暂不能一键把工作流快照载入画布。
3. 脱敏为模式匹配，自定义敏感键可能漏过。
4. SQLite 无迁移机制；数据库损坏时应用拒绝启动。
5. Tauri 的 Cmd+R 不重载 WebView，本次用 `location.reload()` 模拟浏览器刷新；二者对前端状态的效果一致，但正式产品应提供“重新连接”入口或拦截快捷键。
6. 前端“订阅/快照/补洞/去重”合并逻辑目前由 macOS 实机流程覆盖，没有独立的前端单元测试；纯函数部分后续可抽出测试。
7. Windows/Linux 运行行为未验收。
8. 未实现单实例互斥：两个桌面实例共用同一 `runs.sqlite3` 时，后启动实例的启动扫描会把前一个实例仍在运行的记录标记为 `interrupted`。
