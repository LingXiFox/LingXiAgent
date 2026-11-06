# Phase 1.7 测试与验收

状态：代码与自动化验收完成，提交与 CI 待本阶段收口
分支：`rewrite/3.0`
基线：Phase 1.6 收口提交（`d80069e` 之后的 Phase 1.6 实现与文档）

## 1. 验收环境

| 项目 | 值 |
| --- | --- |
| 主机 | macOS 27 arm64（Apple Silicon） |
| Rust | rustc 1.99.1（Homebrew） |
| Node / pnpm | Node v26.13.0 / pnpm 9.15.9 |
| Tauri | 2.x，debug binary `target/debug/lingxi-desktop` |
| 浏览器 E2E | Playwright 1.56.1 + 固定 Chromium 141（与 CI 相同） |
| 原生 E2E | WebdriverIO + `@wdio/tauri-service` embedded driver |
| Provider mock | 本地 HTTP/SSE 服务 `127.0.0.1:11434`（WDIO 内置 Node mock） |
| 数据库 | SQLite `user_version = 3`；新增 project / conversation / permission audit 表 |

所有命令在仓库根目录或 `apps/desktop` 执行。没有真实 OpenAI/Anthropic 凭据，没有访问外部模型服务。

## 2. 自动化结果

### 2.1 Rust

`cargo test --workspace`：exit 0，**159 passed / 0 failed / 0 ignored**。

| 测试二进制 / 模块 | 数量 | 覆盖 |
| --- | ---: | --- |
| desktop unit tests | 26 | SQLite 运行/会话/项目迁移、启动恢复、脱敏、工作流/模板资产闭包、Windows 覆盖保存、单实例、`fsutil` 原子替换 |
| runtime library unit tests | 25 | `agent_protocol` 6、`agent_bus` 6、`workspace` 6、上下文与媒体合并等 |
| `agent_end_to_end.rs` | 13 | 旧 ReAct 工具闭环、Provider 错误、预算、取消、MCP、Skill、多实例隔离 |
| `agent_node.rs` | 6 | 完整完成并发布总线消息、真实工具、预算耗尽、一次修复、暂停+配置+指令、真实 LSP 诊断 |
| `agent_template.rs` | 1 | 标准 ReAct 模板静态校验 |
| `company.rs` | 1 | PM→Coder→Tester 真实总线 handoff、测试失败返工、3 实例、工作区 v2 |
| `composite.rs` | 10 | 组合执行、作用域事件、内部失败/取消/能力拒绝 |
| `control_flow.rs` | 7 | 条件分支、Loop Gate、预算耗尽、节点失败、取消 |
| `engine.rs` | 7 | DAG 顺序、依赖、能力拒绝、审批、超时、禁用节点 |
| `event_sequence.rs` | 2 | 事件序号连续、按运行重置 |
| `lsp.rs` | 1 | 真实 stdio JSON-RPC diagnostics/documentSymbol |
| `mcp_and_skills.rs` | 5 | stdio/HTTP MCP、崩溃、Skill 注入 |
| `media_assets.rs` | 5 | 资产去重/摘要、能力拒绝、图片 ContentPart、PDF/DOCX 抽取、媒体顺序 |
| `project_workspace.rs` | 5 | 不透明 `WorkspaceHandle`、项目根隔离、版本冲突、符号链接逃逸、AGENTS.md 链与权限审计 |
| `protocols.rs` | 10 | 三条协议真实 HTTP/SSE 编解码、工具结果、推理分离、错误/超时/取消/断流 |
| `assets.rs`（spec） | 6 | 根资产表、非法 ID/摘要、引用校验、JSON 往返 |
| `control_flow_validation.rs` | 8 | 循环出口、预算、触发器、绕过 Gate 拒绝 |
| `subgraph_validation.rs` | 9 | 子图绑定、递归、嵌套、循环边界、组合输入触发的 Gate |
| `validation.rs` | 12 | Schema、端口、边、参数、类型、JSON 往返 |

Phase 1.7 新增覆盖的核心断言：

- `project_workspace.rs`：同一目录重复打开得到稳定 `proj-*`；运行 catalog 只暴露已注册项目；`read(version) → write(expectedVersion)` 的过期写入被拒绝；`../`、绝对路径与 symlink escape 被拒绝；`project_rules` 返回由外到内的 AGENTS.md 链；Workspace 模式的审批记录逐项落库。
- desktop unit tests：SQLite v3 迁移、projects/conversations/messages/permission_audit 的写入与读取、启动时活动运行恢复。
- workspace unit test 额外锁定 `project_tree` 的目录 kind 必须是 `dir`，与前端 `FileEntry` 契约一致。

### 2.2 前端单元测试与构建

| 命令 | 结果 |
| --- | --- |
| `pnpm test:events` | 6 passed |
| `pnpm test:routing` | 13 passed |
| `pnpm test:composite` | 8 passed |
| `pnpm -C apps/desktop build` | tsc + Vite 成功；222 modules，主 JS **498.61 kB**（gzip 155.52 kB），CSS **60.26 kB**（gzip 10.98 kB） |

### 2.3 Playwright（浏览器 UI，mock transport）

命令：

```bash
PLAYWRIGHT_CHANNEL=chromium pnpm -C apps/desktop exec playwright test --config playwright.config.ts --reporter=line
```

结果：**31 passed**，exit 0。总套件为 5 项 Phase 1.4 回归、14 项 Phase 1.5 回归、6 项 Phase 1.6 与 6 项 Phase 1.7 验收。

| # | Phase 1.7 用例 | 断言要点 |
| ---: | --- | --- |
| 1 | 打开项目、创建会话并运行普通 Agent 任务 | 项目树、默认会话工作流、mock 运行完成、时间线出现助手结果 |
| 2 | 快捷配置在刷新后仍是真实节点配置 | 改 model/reasoning 后刷新，composer 与节点参数一致 |
| 3 | 浏览项目树并按版本编辑文件 | 展开目录、打开 `src/index.ts`、保存后版本推进 |
| 4 | 工作台 Agent 与真实节点双向映射 | 定位节点进入对应组合层，画布再回到同一 Agent 标签 |
| 5 | 不重新打开项目创建第二个会话 | 会话列表出现两条、切换不丢项目上下文 |
| 6 | 从工作区节点内部绑定项目文件夹 | ProjectField 选择目录后项目树出现，回调不丢失 |

Playwright 使用前端 mock transport，只证明编辑器、工作台、项目树与视图状态；真实执行以第 2.4 节和第 3 节为准。

### 2.4 原生 Tauri E2E

命令：

```bash
pnpm -C apps/desktop e2e:tauri:build
pnpm -C apps/desktop exec wdio run wdio.conf.mjs
```

完整原生套件：**21 passing**，exit 0，约 1m30s。构成为 Phase 1.5 3 项、Phase 1.6 8 项、Phase 1.7 6 项、runtime 4 项；全部运行在真实 macOS Tauri 窗口、真实 IPC 与真实 Rust Runtime 中。

Phase 1.7 原生用例：

| 用例 | 关键结果 |
| --- | --- |
| A：打开真实目录、创建默认 Agent 会话并编辑工作区 | `project_open` 返回 `proj-*` 与 `ws-*`；树含 `src` 且 kind 为 `dir`；默认工作流 kind 为 project/agent/log；mock agent 写入 `feature.txt` v1 |
| B：版本化写入、路径边界与符号链接逃逸 | 过期版本拒绝、`../escape.txt` 拒绝、`link/secret.txt` 拒绝、缺失目录打开失败 |
| C：AGENTS.md 作用域与 Workspace 审批审计 | 根规则 + src 规则按由外到内返回；网络审批记录 approved/approved_once/auto，文件系统 auto |
| D：同一会话跨两次运行 | 消息角色严格为 user,assistant,user,assistant；runId 不同；会话数仍为 1 |
| E：跨项目工作流被拒绝 | 其他项目的 projectId 在同会话运行中报 `workspace.not_found` |
| F：YOLO 自动放行并审计 | mock-coder 无提示完成并写入 v1；network/filesystem 审计均为 auto |

### 2.5 真实 macOS 工作台走查

在真实 Tauri 窗口上执行了一条手工风格走查（WebdriverIO 驱动真实 UI，除项目打开与 mock 模型注入外不调用业务 IPC）：

1. 打开 `/tmp/lingxi-phase17-acceptance`，确认项目树、Git 状态与 1 个变更。
2. 新建会话，切换权限 Ask → Workspace → YOLO → Workspace；YOLO 警告出现后消失。
3. 发送 “Inspect the project and report completion.”，出现真实 Rust 网络审批对话框，目标 `openai_chat://127.0.0.1:11434`；点击批准。
4. 时间线出现 “Agent completed the task.”，状态变为“已完成”。
5. 展开 `src`，打开 `index.ts`，在版本化编辑器中写入 `export const value = 42;`，点击“保存（版本检查）”；`project_read` 读回新内容。
6. 点击 Agent 标签的“定位节点”，画布显示对应节点；切回工作台。
7. 刷新 WebView，项目、会话与时间线仍在。

结果：**1 passing（2.5s）**。证据截图：[phase-1.7-workbench.png](assets/phase-1.7-workbench.png)。

这次走查发现并修复了一个真实 UI 缺陷：

- 现象：真实 Tauri 中 `src` 目录在项目树里显示为文件，点击后报错，无法展开；浏览器 E2E 因 mock 返回 `dir` 而始终通过。
- 根因：`Workspace::list_inner` 返回的 `FileEntry.kind` 是 `"directory"`，前端 `ProjectWorkbench` 只认 `"dir"`。
- 修复：Runtime 统一返回 `"dir"`；workspace 单测与 native Phase 1.7 A 都锁定该契约。
- 证据：修复后真实窗口可展开 `src` 并编辑 `index.ts`，截图中的文件树显示目录箭头。

## 3. 验收条目对照

| 场景 | 结论 | 证据 |
| --- | --- | --- |
| 选择真实项目目录并持久化项目身份 | 通过 | native A/B；desktop unit tests；走查第 1 步 |
| 项目 / 会话 / 文件树工作台 | 通过 | native A/D；Playwright 1/3/5；走查第 1/5/7 步 |
| 同一项目多会话、多轮对话连续 | 通过 | native D；Playwright 5 |
| 文件版本化读写与冲突拒绝 | 通过 | native B；Playwright 3；走查第 5 步 |
| 路径边界、symlink escape、敏感路径 | 通过 | native B；`project_workspace.rs` |
| Ask / Workspace / YOLO 三档权限与审计 | 通过 | native C/F；走查第 2/3 步 |
| Git 状态 / diff / log | 通过 | 走查第 1 步显示变更；native A 断言 Git 摘要 |
| AGENTS.md 规则链 | 通过 | native C；`project_workspace.rs` |
| 工作台 Agent ↔ 画布节点双向定位 | 通过 | Playwright 4；走查第 6 步 |
| 刷新后项目、会话、时间线恢复 | 通过 | 走查第 7 步 |
| 无固定 Agent Loop、执行在 Rust | 通过 | native A/D；前端不执行调度 |
| Windows / Linux | 编译/单测待 CI；运行**未验收** | 见第 5 节 |
| 真实外部模型 | **未验证** | 无凭据，只使用本地 wire-format mock |
| 原生文件夹选择对话框 | **未自动验收** | 自动化通过 `project_open` 打开同一目录；系统文件对话框需人工操作 |

## 4. 跨平台

| 平台 | 编译 / 静态检查 / 单测 | 真实桌面运行 |
| --- | --- | --- |
| macOS | 本地通过 | **通过**（原生 21 项 + 真实工作台走查） |
| Windows | CI 待本次提交后运行 | **未验收** |
| Linux | CI 待本次提交后运行 | **未验收** |

CI 的 Rust job 在 macOS、Ubuntu 24.04、Windows 上执行 format、clippy、`cargo test --workspace`；前端 job 执行构建、三组单元测试与 Playwright 固定 Chromium。CI 编译通过不等同于 Windows/Linux 实机运行验收，平台相关 keyring、WebView、路径与进程行为仍需实机复核。

## 5. 已知问题与边界

- **原生文件夹选择对话框未自动化**：WDIO 不能可靠驱动 macOS 系统面板；测试通过 `project_open` 使用与 UI 相同的后端命令，人工验收需补一次点击路径。
- **Windows/Linux 未实机验收**：只确认 CI 编译、clippy 与单测；安装包、签名、公证未做。
- **Git 面板只读**：提供 status/diff/log，不提供 stage/commit/push；高风险 Git 操作仍由权限层拒绝。
- **文件树按需加载一层**：没有虚拟滚动与大型仓库性能基准；展开深层目录是逐层 IPC。
- **项目移动即新身份**：`proj-*` 由规范路径哈希决定，移动目录会得到新 projectId；旧会话仍指向旧路径。
- **工作台映射是节点实例级**：同一 Agent 节点多次激活共用标签，不按 activation 拆分标签。
- **Agent 并发未实现**：调度器仍顺序激活；工作台不宣称并行。
- **真实外部模型未验证**：三条协议仍由本地 mock 覆盖。

## 6. 最终门禁记录

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

实际结果：

| 检查 | 结果 |
| --- | --- |
| `cargo fmt --all -- --check` | **通过** |
| `cargo clippy --workspace --all-targets -- -D warnings` | **通过** |
| `cargo test --workspace` | **159 passed / 0 failed** |
| `pnpm -C apps/desktop build` | 通过；222 modules，主 JS 498.61 kB（gzip 155.52 kB），CSS 60.26 kB（gzip 10.98 kB） |
| 前端单元测试 | events 6、routing 13、composite 8，全部通过 |
| Playwright 浏览器 E2E | **31 passed**（5 回归 + 14 Phase 1.5 + 6 Phase 1.6 + 6 Phase 1.7） |
| 原生 Tauri WDIO | **21 passed**（Phase 1.5 3 + Phase 1.6 8 + Phase 1.7 6 + runtime 4） |
| 真实工作台走查 | **1 passed**（2.5s） |
| GitHub Actions CI | 待本次提交后运行 |
