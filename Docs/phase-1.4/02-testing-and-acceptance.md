# Phase 1.4 测试与验收

状态：代码、自动化测试与 macOS 真实 Tauri 验收完成（2026-11-04）
分支：`rewrite/3.0`

## 1. 验收环境

| 项目 | 值 |
| --- | --- |
| 主机 | macOS 27.3 arm64（Apple Silicon） |
| Rust | rustc 1.99.1（Homebrew） |
| Node / pnpm | Node v26.13.0 / pnpm 9.15.9 |
| Tauri | 2.x，debug binary `target/debug/lingxi-desktop` |
| 浏览器 E2E | Playwright + 本机 Chrome（macOS 本地） |
| 原生 E2E | WebdriverIO + `@wdio/tauri-service` embedded driver |
| Provider | 本地 OpenAI-compatible mock（`127.0.0.1:11434`，真实 HTTP/SSE 协议） |

所有命令均在仓库根目录或 `apps/desktop` 执行。没有使用真实模型凭据，没有访问外部模型服务。

## 2. 自动化结果

### 2.1 Rust

`cargo test --workspace`：exit 0，**97 passed / 0 failed / 0 ignored**。

| 测试二进制 | 数量 | 覆盖 |
| --- | ---: | --- |
| desktop unit tests | 23 | SQLite 事件、脱敏、工作流/模板存储、覆盖保存、单实例、运行恢复 |
| `agent_end_to_end.rs` | 13 | ReAct 工具闭环、Provider 错误、预算、取消、MCP 工具、Skill、多实例隔离 |
| `agent_template.rs` | 1 | 标准 Agent 模板静态校验 |
| `composite.rs` | 10 | 组合执行、作用域事件、内部失败/取消/能力拒绝 |
| `control_flow.rs` | 7 | 条件分支、Loop Gate、预算耗尽、节点失败、取消 |
| `engine.rs` | 7 | DAG 顺序、依赖、能力拒绝、审批、超时、禁用节点 |
| `event_sequence.rs` | 2 | 事件序号连续、按运行重置 |
| `mcp_and_skills.rs` | 5 | stdio/Streamable HTTP MCP、崩溃、Skill 注入 |
| `control_flow_validation.rs` | 8 | 循环出口、预算、触发器、绕过 Gate 拒绝 |
| `subgraph_validation.rs` | 9 | 子图绑定、递归、嵌套、循环边界 |
| `validation.rs` | 12 | Schema、端口、边、参数、类型、JSON 往返 |

另有 `cargo fmt --all -- --check` 与 `cargo clippy --workspace --all-targets -- -D warnings` 通过。

### 2.2 前端单元测试

| 命令 | 结果 |
| --- | --- |
| `pnpm test:events` | 6 passed |
| `pnpm test:routing` | 13 passed |
| `pnpm test:composite` | 8 passed |

### 2.3 Playwright（浏览器 UI，mock transport）

命令：`PLAYWRIGHT_CHANNEL=chrome pnpm -C apps/desktop test:e2e:web --reporter=line`

结果：**5 passed**，exit 0。

1. 创建、连接、编辑、运行并持久化 DAG。
2. 移动与删除节点，确认拖拽期间没有逐帧 IPC。
3. 组合节点：分组、展开、返回顶层、保存模板。
4. 插入标准 Agent 模板并预览流式工具事件。
5. 静态校验错误可见。

Playwright 使用前端 mock，仅证明编辑器和 mock 事件链路；最终执行能力以下一节真实 Tauri 为准。

### 2.4 原生 Tauri E2E

命令：`pnpm -C apps/desktop test:e2e:tauri`

该命令依次执行 `tauri build --debug --no-bundle --features e2e` 与 `wdio run wdio.conf.mjs`。结果：**4 passing**，exit 0。

| 用例 | 关键结果 |
| --- | --- |
| DAG 真实执行与持久化 | 3 节点/2 连线；日志 `HELLO RUST E2E`；`run completed`；SQLite run 状态 completed，3 个 `node.finished` |
| 标准 Agent 模板真实工具循环 | 审批网络访问；模型发起 calculator `128 * 256`；工具结果 32768；最终 `The answer is 32768.`；run completed |
| WebView 刷新后重连 | 运行中刷新；日志 `reconnected to run`；无重复事件；唯一 seq 数等于事件数；2 次 model 调用均配对 |
| 运行中取消 | 审批等待期间终止；`run cancelled`；`run.finished` 为 cancelled 且有 `node.cancelled` |

这些用例运行在真实 macOS Tauri 窗口、真实 IPC 和真实 Rust Runtime 上；Provider 是本地 HTTP mock，但走真实 SSE/tool_calls 协议，不是前端假事件。

## 3. 真实 Tauri 验收步骤

1. 启动 `pnpm --dir apps/desktop tauri dev`，桌面窗口正常显示 ComfyUI 布局。
2. 加载 DAG 工作流并运行：节点顺序执行，日志实时出现，结束后写入 SQLite。
3. 加载标准 Agent 组合，接入文本输入和运行名，点击运行。
4. 首次模型请求前弹出网络审批；批准后进入 ReAct 循环。
5. 模型输出 tool call，Tool Dispatcher 调用 calculator，Context 回填结果，模型给出最终答案。
6. 运行中刷新 WebView：事件从 `active_run` 恢复，不重复、不丢序。
7. 运行中点击终止：工作流进入 cancelled，节点状态与日志一致。
8. 关闭应用重开：工作流与运行历史仍可读取；中断的运行标记为 interrupted。

## 4. 验收条目对照

| 场景 | 结论 | 证据 |
| --- | --- | --- |
| A. Provider / Model / Prompt / Context 真实闭环 | 通过 | `a_real_react_loop_calls_a_tool_and_returns_the_final_answer`、原生 Agent E2E |
| B. ToolCall → calculator → Context → 最终回答 | 通过 | 原生 Agent E2E、`one_response_with_two_tool_calls_executes_both`、`invalid_tool_arguments_become_a_tool_error_not_a_dead_loop` |
| C. 本地 MCP（stdio 与 HTTP） | 通过 | `mcp_stdio_lists_and_calls_tools_over_json_rpc`、`mcp_streamable_http_lists_and_calls_tools`、`the_agent_calls_an_mcp_tool_end_to_end`、崩溃测试 |
| D. Skill 注入 | 通过 | `the_agent_uses_skill_instructions_as_system_context` |
| E. 多 Agent 实例隔离 | 通过 | `two_agent_instances_keep_contexts_and_budgets_separate`、`multiple_instances_keep_independent_state` |
| F. 刷新重连与事件恢复 | 通过 | 原生 E2E 重连用例、事件重放 6 项前端单测 |
| G. 失败路径 | 通过 | Provider 401/429/5xx、超时、断流、非法工具参数、未知工具、MCP 崩溃、拒绝审批、取消、预算耗尽 |
| H. 无固定 Agent Loop | 通过 | 标准模板由 Prompt/Provider/ToolSet/Context/Loop Gate/Model/Condition/Dispatcher/Log 节点组合；Runtime 无隐式循环 |
| I. 权限不可绕过 | 通过 | `DeclaredCapabilityPolicy` + `PermissionManager`；Composite 内部能力拒绝与目标审批测试 |

## 5. 跨平台

| 平台 | 编译 / 静态检查 / 单测 | 真实桌面运行 |
| --- | --- | --- |
| macOS | 本地通过 | **通过**（原生 WDIO 4 项，真实窗口与 IPC） |
| Windows | 由 CI 验证 | **未验收** |
| Linux | 由 CI 验证 | **未验收** |

CI 在 macOS、Ubuntu 24.04、Windows 上执行格式化（Linux）、clippy 与 `cargo test --workspace`；前端 job 执行 build、三组单元测试、Playwright Chromium 安装与 5 项浏览器 E2E。CI 编译通过不等同于 Windows/Linux 实机运行验收。

## 6. 已知问题与边界

- **未调用真实外部模型**：本轮用本地 OpenAI-compatible mock 验证协议、流式输出与工具调用；真实服务凭据、配额、区域网络差异未实测。
- **MCP 认证范围有限**：支持无认证或静态 Bearer；OAuth、动态注册、远程服务发现未实现。
- **MCP stdio 不是安全沙箱**：子进程以当前用户权限运行，依赖用户对 command/args 的显式审批；资源隔离仍需后续权限层加强。
- **Windows/Linux 运行行为未验收**：只能确认 CI 编译与测试，平台相关的 keyring、WebView、路径差异仍需实机验证。
- **调度仍是顺序执行**：本轮不宣称并行 Agent 或多 Agent 协作；同一运行内节点按控制流激活顺序执行。
- **Context 预算为估算**：token 以字符数近似，不等同于 Provider 精确计费；极端长上下文仍可能出现服务端超限。
- **未做安装包、签名与公证**：验收使用 debug binary 与 embedded WebDriver，不覆盖发布分发链路。
- **UI 保持最小**：没有常驻聊天区、右侧属性栏或仪表盘；模型/工具状态通过节点与底部日志呈现。
- **Windows 覆盖保存不是原子替换**：Unix 使用原子 `rename`；Windows 目标已存在时先删除再 `rename`，极端崩溃窗口内可能丢失旧文件。后续可改用 `ReplaceFileW`。
