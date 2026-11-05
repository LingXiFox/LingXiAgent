# Phase 1.6 测试与验收

状态：代码、自动化验收、提交与 CI 完成
分支：`rewrite/3.0`
基线：`d80069e`（Phase 1.5 文档收口）；实现提交：`8b48dac`

## 1. 验收环境

| 项目 | 值 |
| --- | --- |
| 主机 | macOS 27.3 arm64（Apple Silicon） |
| Rust | rustc 1.99.1（Homebrew） |
| Node / pnpm | Node v26.13.0 / pnpm 9.15.9 |
| Tauri | 2.x，debug binary `target/debug/lingxi-desktop` |
| 浏览器 E2E | Playwright 1.56.1 + 固定 Chromium 141（CI 同一浏览器） |
| 原生 E2E | WebdriverIO + `@wdio/tauri-service` embedded driver |
| Provider mock | 本地 HTTP/SSE 服务 `127.0.0.1:11434`（WDIO 内置 Node mock；Python fixture 同协议） |
| 数据库 | SQLite `user_version = 2`，新增 `task_sessions` |

所有命令在仓库根目录或 `apps/desktop` 执行。没有真实 OpenAI/Anthropic 凭据，没有访问外部模型服务。

## 2. 自动化结果

### 2.1 Rust

`cargo test --workspace`：exit 0，**146 passed / 0 failed / 0 ignored**。

| 测试二进制 / 模块 | 数量 | 覆盖 |
| --- | ---: | --- |
| desktop unit tests | 25 | SQLite 运行与会话、启动恢复、脱敏、工作流/模板资产闭包、Windows 覆盖保存、单实例、`fsutil` 原子替换 |
| runtime library unit tests | 18 | `agent_protocol` 6、`agent_bus` 6、`workspace` 3、上下文与媒体合并 |
| `agent_end_to_end.rs` | 13 | 旧 ReAct 工具闭环、Provider 错误、预算、取消、MCP、Skill、多实例隔离 |
| `agent_node.rs` | 6 | 完整完成并发布总线消息、真实工具、预算耗尽、一次修复、暂停+配置+指令、真实 LSP 诊断 |
| `agent_template.rs` | 1 | 标准 ReAct 模板静态校验仍通过 |
| `company.rs` | 1 | PM→Coder→Tester 真实总线 handoff、测试失败返工、3 个实例、5+ 消息、工作区 v2 |
| `composite.rs` | 10 | 组合执行、作用域事件、内部失败/取消/能力拒绝 |
| `control_flow.rs` | 7 | 条件分支、Loop Gate、预算耗尽、节点失败、取消 |
| `engine.rs` | 7 | DAG 顺序、依赖、能力拒绝、审批、超时、禁用节点 |
| `event_sequence.rs` | 2 | 事件序号连续、按运行重置 |
| `lsp.rs` | 1 | 真实 stdio JSON-RPC 的 initialize/diagnostics/documentSymbol |
| `mcp_and_skills.rs` | 5 | stdio/HTTP MCP、崩溃、Skill 注入 |
| `media_assets.rs` | 5 | 资产去重/摘要、能力拒绝、图片 ContentPart、PDF/DOCX 抽取、媒体顺序 |
| `protocols.rs` | 10 | 三条协议的真实 HTTP/SSE 编解码、工具结果、推理分离、错误/超时/取消/断流 |
| `assets.rs`（spec） | 6 | 根资产表、非法 ID/摘要、引用校验、JSON 往返 |
| `control_flow_validation.rs` | 8 | 循环出口、预算、触发器、绕过 Gate 拒绝 |
| `subgraph_validation.rs` | 9 | 子图绑定、递归、嵌套、循环边界、组合输入触发的 Gate |
| `validation.rs` | 12 | Schema、端口、边、参数、类型、JSON 往返 |

Phase 1.6 新增覆盖的核心断言：

- `agent_node.rs`：`core.agent` 通过 Rust AgentRunner 完成多轮模型调用、工具执行、结构化 `submit_result`、总线发布；预算/超时/取消有稳定终态；暂停后在安全点应用配置修订并消费纠偏指令；真实 LSP 诊断/符号工具可用。
- `company.rs`：3 个 Agent 使用同一运行、真实消息总线与版本化工作区；Tester 失败后 Coder 在同一 `AgentInstanceId` 上第二次激活；最终日志为 `Tests passed`，工作区文件内容为 v2。
- desktop unit tests：`task_sessions` 迁移与快照、启动时 `interrupted` 标记、工具已调用时生成 `PendingReview`、不重放未完成操作。

最终门禁还执行 `cargo fmt --all -- --check` 与 `cargo clippy --workspace --all-targets -- -D warnings`，结果见第 7 节。

### 2.2 前端单元测试与构建

| 命令 | 结果 |
| --- | --- |
| `pnpm test:events` | 6 passed |
| `pnpm test:routing` | 13 passed |
| `pnpm test:composite` | 8 passed |
| `pnpm -C apps/desktop build` | tsc + Vite 成功；221 modules，主 JS 474.22 kB（gzip 148.48 kB），CSS 50.37 kB（gzip 9.51 kB） |

### 2.3 Playwright（浏览器 UI，mock transport）

命令：

```bash
PLAYWRIGHT_CHANNEL=chromium pnpm -C apps/desktop exec playwright test --config playwright.config.ts --reporter=line
```

结果：**25 passed**，exit 0。总套件包含 5 项 Phase 1.4 回归、14 项 Phase 1.5 回归与 6 项 Phase 1.6 验收。

| # | 用例 | 断言要点 |
| ---: | --- | --- |
| 1 | 团队运行与总览 | 3 个 Agent 标签、总览 3 个 Agent、Coder 标签、消息时间线、完成后状态 |
| 2 | 配置预览/应用、纠偏指令、双向定位 | 暂停 PM 后改 model/rolePrompt，预览显示 `mock-pm-v2`，应用后 `版本 1 状态：applied`，指令进入总线，定位到画布并选中 PM，再回到工作台标签 |
| 3 | 暂停 Agent、切视图、继续 | 暂停后切画布再切回仍为已暂停；继续后原运行完成，不新建 Agent |
| 4 | 运行中锁定画布 | 暂停运行后画布显示“结构已锁定”；节点参数输入 disabled；Delete 不删除节点；切回工作台仍为已暂停 |
| 5 | 刷新恢复 | WebView 刷新后画布隐藏、工作台恢复、Coder 标签选中、增量流仍在 |
| 6 | 按 Agent 过滤与总览时间线 | Coder 流只含 Coder 事件；总览含跨 Agent 消息与 `task.result` |

Playwright 使用前端 mock transport，只证明编辑器、工作台、视图状态和画布锁；真实执行以下一节为准。

### 2.4 原生 Tauri E2E

命令：

```bash
pnpm -C apps/desktop e2e:tauri:build
pnpm -C apps/desktop exec wdio run wdio.conf.mjs --spec e2e/tauri/phase16.spec.mjs
```

结果：**8 passing**，exit 0。全部用例运行在真实 macOS Tauri 窗口、真实 IPC 与真实 Rust Runtime 中；Provider 为本地 wire-format mock。

| 用例 | 关键结果 |
| --- | --- |
| A：单个 Agent 通过 Rust runner | `core.agent` 完成一次激活，结构化结果与 `userResponse` 落到日志；无固定 Agent Loop 参与 |
| B：PM→Coder→Tester handoff | 3 个 Agent、各 1 次激活；3 条 `task.result` 总线消息，sender 为 3 个不同实例；最终交付日志 |
| C：QA 失败后返工 | Tester 先 fail、Coder 返工、Tester 再 pass；Coder/Tester 各自 2 次激活，`AgentInstanceId` 不变；工作区 v2 |
| D：暂停 Coder、改 prompt、resume | 暂停发生在安全点；`preview_agent_config` 返回 rolePrompt diff；`apply_agent_config` 返回 pending；resume 后应用为 applied，仍是同一激活 |
| E：非法或过期配置被拒绝 | 空 model 被 `model must not be empty` 拒绝；过期 revision 被拒绝；会话配置 revision 与版本记录不变 |
| F：反复切换画布/工作台 | 3 次双向切换后运行继续，Coder 仍只有 1 次激活 |
| G：WebView 刷新恢复 | 刷新后工作台、标签、选中 Agent、增量流恢复，不新建激活 |
| H：进程中断与人工核对 | 工具调用后 SIGKILL 并重启；会话/Agent/激活标记 `interrupted`，生成 1 条未解决 `PendingReview`，运行详情只有一个 `run.finished` 且状态为 `interrupted` |

原生 D 的暂停必须与网络/工具审批并发推进：审批提示会阻塞 Runner，未批准前不会到达安全点。测试先启动审批循环，再等待 `paused`，不把“暂停请求已发出”当成“已暂停”。

## 3. 验收条目对照

| 场景 | 结论 | 证据 |
| --- | --- | --- |
| 一等 `core.agent` 节点与四组端口 | 通过 | `agent_node.rs`；原生 A/B；`core.agent` 契约见 01-design |
| 独立 AgentRunner（规划、多轮模型、工具、上下文、完成判定、预算、审批、暂停/取消/恢复） | 通过 | `agent_runner.rs`；原生 A-D/F/H；`agent_end_to_end.rs` |
| 版本化 TaskEnvelope/AgentMessageEnvelope/ArtifactRef/AgentExecutionState | 通过 | `agent_protocol` 单测；`company.rs`；原生 B |
| Agent Message Bus（校验、去重、持久化、排序、ack、队列上限、隔离） | 通过 | `agent_bus` 单测；`company.rs`；原生 B/C |
| 双视图共享 RunId/事件流/状态/审批/产物/预算，切换不重启 | 通过 | Playwright 1/3/5/6；原生 F/G |
| 工作台动态标签、总览、状态、审批、错误、未读、过滤、定位 | 通过 | Playwright 1/2/5/6；原生 A-H |
| 暂停/继续/取消；安全点；不伪造暂停 | 通过 | 原生 D/F；Playwright 3/4；`agent_node.rs` 暂停测试 |
| 配置修订（预览、应用、版本、过期拒绝、安全点生效） | 通过 | 原生 D/E；Playwright 2；`agent_bus` 单测 |
| 结构变更不在运行中迁移 | 通过（UI 锁） | Playwright 4：运行中锁定拖拽/连线/删除/参数；需结构变更时停止并新建运行 |
| SQLite 会话、刷新恢复、崩溃恢复、人工核对、不重放 | 通过 | 原生 G/H；desktop unit tests |
| PM→Coder→Tester 公司示例（结构化 PRD、真实返工、真实工具） | 通过 | `company.rs`；原生 B/C；`fixtures/mock-provider` 与 WDIO mock |
| 受控文件版本与 LSP 最小真实链路 | 通过 | `workspace` 3 项；`agent_node.rs` LSP 项；`lsp.rs` |
| Phase 1.5 回归（三条协议、多模态、Reasoning、组合/模板、Schema 1.0/1.1/1.2） | 通过 | 146 Rust tests；Playwright 5 + 14 回归 |
| 真实外部模型 | **未验证** | 无凭据，未调用外部服务 |
| 独立 Agent 并发调度 | **未实现** | 当前顺序激活；不把顺序展示成并行 |

## 4. 真实 Tauri 验收步骤

原生 WDIO 已自动化覆盖下列路径；也可在 macOS 上手工复核：

1. `pnpm -C apps/desktop tauri dev`，确认左侧节点库、中央画布、右上运行/终止、底部日志。
2. 新建或载入“团队示例”，确认 PM、Coder、Tester 三个 Agent 节点与返工 Loop Gate。
3. 点击运行：应用切到 Agent 工作台，出现总览与 3 个 Agent 标签；PM 完成后 Coder 启动，测试失败时 Coder 二次激活。
4. 在 Coder 标签点击暂停：状态先显示“等待安全暂停点”，到达安全点后才显示“已暂停”。
5. 修改角色提示词，点击“预览影响”，确认只显示字段级 diff；点击“应用到当前任务”，确认版本记录为 pending，继续后在下一迭代变为 applied。
6. 发送纠偏指令，确认提示“已进入总线，将在最近的安全执行点交给 Agent”；恢复后同一激活继续，不重跑已完成工具。
7. 点击“定位节点”：切到画布对应组合层并选中节点；在画布点击“查看 Agent 执行”回到同一标签。
8. 运行中刷新 WebView：工作台、选中 Agent 与事件流恢复；运行不重启。
9. 运行中强制退出应用并重开：运行标记 interrupted，工具调用过的激活出现人工核对项；不自动重放。

## 5. 跨平台

| 平台 | 编译 / 静态检查 / 单测 | 真实桌面运行 |
| --- | --- | --- |
| macOS | 本地通过 | **通过**（原生 WDIO 8 项，真实窗口与 IPC） |
| Windows | **通过**（CI `42045389615`） | **未验收** |
| Linux | **通过**（CI `42045389615`） | **未验收** |

CI 的 Rust job 在 macOS、Ubuntu 24.04、Windows 上执行 format、clippy、`cargo test --workspace`；前端 job 执行构建、三组单元测试与 Playwright 固定 Chromium。CI 编译通过不等同于 Windows/Linux 实机运行验收，平台相关 keyring、WebView、路径与进程行为仍需实机复核。

## 6. 已知问题与边界

- **Agent 并发未实现**：调度器仍顺序激活 Agent；独立 Agent 的受控并发与并行时间线留待下一阶段，UI 不宣称并行。
- **结构变更无迁移**：运行中前端锁定结构与节点参数；没有 checkpoint 派生分支。需要改拓扑时停止并新建运行。
- **工作流级 revision 未接入事件**：`TaskSession.workflowRevision` 当前固定为 1，`RunEvent`/`AgentEvent` 不携带该字段；历史配置与运行快照的对照仅在会话级成立。
- **消息 ACL 较粗**：只做运行成员制与收件人校验，没有按消息类型/字段的细粒度权限。
- **崩溃恢复不重放外部副作用**：只标记 `interrupted` 并要求人工核对；未完成的外部写操作可能已发生，系统不会自动重试。
- **未调用真实外部模型**：三条 wire protocol 由本地 mock 验证，真实云服务的账号、配额、区域网络和模型差异未实测。
- **LSP 范围有限**：仅 stdio 与 diagnostics/documentSymbol；不含补全、重命名、代码操作。
- **Windows/Linux 原生行为未验收**：只确认 CI 编译、clippy 与单测；安装包、签名、公证也未做。

## 7. 最终门禁记录

提交前在本机（macOS Apple Silicon）执行：

```text
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
pnpm -C apps/desktop build
pnpm -C apps/desktop test:events
pnpm -C apps/desktop test:routing
pnpm -C apps/desktop test:composite
PLAYWRIGHT_CHANNEL=chromium pnpm -C apps/desktop test:e2e:web --reporter=line
pnpm -C apps/desktop test:e2e:tauri
```

实际结果（最终值将在提交前复核）：

| 检查 | 结果 |
| --- | --- |
| `cargo fmt --all -- --check` | 通过，无改动 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 通过，0 warning |
| `cargo test --workspace` | **146 passed / 0 failed** |
| `pnpm -C apps/desktop build` | 通过；221 modules，主 JS 474.22 kB（gzip 148.48 kB） |
| 前端单元测试 | events 6、routing 13、composite 8，全部通过 |
| Playwright 浏览器 E2E | **25 passed**（5 回归 + 14 Phase 1.5 + 6 Phase 1.6） |
| 原生 Tauri WDIO | **8 passed**（A-H，真实窗口与 IPC，34.7s） |
| GitHub Actions CI | **通过**：run [`42045389615`](https://github.com/LingXiFox/LingXiAgent/actions/runs/42045389615) attempt 2；macOS / Ubuntu / Windows Rust 与 Frontend 四个 job 全绿 |

CI 的 attempt 1 在 Ubuntu `apt-get` 安装 WebKit 依赖时停滞超过 25 分钟，未进入格式检查；取消后重跑 attempt 2 在 6 分 13 秒内完成该步骤，四个 job 均通过。该次停滞属于托管 runner 环境问题，不是项目构建失败。
