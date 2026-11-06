# 泠溪 · LingXiAgent 3.0

跨平台、节点式 Agent 工作流平台。Phase 0 建立 Rust 运行时 + Tauri 2 桌面壳 + React Flow 画布；Phase 1.1 加入条件分支与可预算、可取消的受控循环；Phase 1.1.1 用带避障的自定义路由替换默认边渲染；Phase 1.2 加入事件序号、SQLite 运行历史与刷新重连；Phase 1.2.1 补上单实例保护与实时/持久化事件的统一脱敏；Phase 1.3 加入可展开、可编辑、可复用、由 Rust 分层执行的组合节点与本地模板；Phase 1.4 完成首个真实文本 Agent 闭环：Provider、Model、Prompt、Context、Tool、MCP、Skills、权限审批与端到端测试；Phase 1.5 加入中文可折叠节点库、OpenAI Chat / OpenAI Responses / Anthropic Messages 三条真实协议、独立思考等级、模型能力面板，以及图片/音频/视频/文档的统一资产链路；Phase 1.6 加入一等 `core.agent` 节点、独立 AgentRunner、版本化协作协议与消息总线、双视图 Agent 工作台、安全暂停/配置修订/纠偏指令，以及 SQLite 任务会话恢复；Phase 1.7 加入项目工作区、项目/会话/文件树 Agent 工作台、Ask/Workspace/YOLO 运行权限、版本化文件读写、Git 辅助面板与画布双向定位。工作流是可序列化 JSON，执行全部在 Rust 侧。

## 当前状态

- 分支：`rewrite/3.0`（从 `rewrite/2.0` 的 `c886ba7` 起）
- 阶段：Phase 1.7 — 项目工作区与项目/会话式 Agent 工作台
- 验收：macOS 真实 Tauri 通过（原生 WDIO 21 项 + 1 项真实工作台走查）；Windows / Linux 的 CI 编译、clippy、单测结果待本次提交后更新，运行行为**未验收**
- 测试：`cargo test --workspace` 159 passed；Playwright 31 passed（5 项回归 + 14 Phase 1.5 + 6 Phase 1.6 + 6 Phase 1.7）；原生 Tauri WDIO 21 passed；前端单测 6 + 13 + 8 passed

## 技术栈

| 层 | 选型 |
| --- | --- |
| 运行时 | Rust（workspace，无 Tauri 依赖） |
| 桌面壳 | Tauri 2 |
| 前端 | React 18 + TypeScript 5（strict） |
| 画布 | `@xyflow/react` 12 |
| 存储 | 工作流 JSON 文件 + SQLite 运行历史 |

## 仓库结构

```
crates/lingxi-spec/      工作流模型、节点规格、校验（纯数据，无 IO）
crates/lingxi-runtime/   执行引擎、控制调度器、内置节点、事件、能力策略、交互总线
apps/desktop/            React UI + Tauri 壳
  src/                   画布、节点库、日志、对话框、transport
  src-tauri/             59 个 command、工作流与项目存储、SQLite 运行/任务会话库、事件桥、能力策略、资产导入
Docs/phase-0/            基础架构、节点规格、接口、测试、已知问题
Docs/phase-1.1/          控制流设计、测试与验收记录
Docs/phase-1.1.1/        智能连线设计、测试与验收记录
Docs/phase-1.2/          运行持久化设计、测试与验收记录
Docs/phase-1.2.1/        单实例保护与脱敏一致性设计、测试与验收记录
Docs/phase-1.3/          组合节点、子图协议、分层执行与模板设计/验收
Docs/phase-1.4/          文本 Agent 闭环、Provider/工具/MCP/Skills 设计与验收
Docs/phase-1.5/          多协议、多模态、资产层、中文节点库设计与验收
Docs/phase-1.6/          Agent 节点、Runner、协议/总线、工作台、干预与恢复设计与验收
Docs/phase-1.7/          项目工作区、项目/会话工作台、权限、文件版本与双向映射设计与验收
Docs/reference/2.0/      2.0 历史文档（只读参考）
```

依赖方向严格单向：`lingxi-spec` ← `lingxi-runtime` ← `src-tauri`。运行时不知道窗口存在。

## 快速开始

需要 Rust ≥ 1.90（Tauri 2.12 的实际 MSRV）、Node ≥ 20、pnpm 9。

```bash
pnpm -C apps/desktop install
cargo test --workspace
pnpm -C apps/desktop tauri dev
```

浏览器里单独调 UI（mock transport，不启动 Rust）：

```bash
pnpm -C apps/desktop dev   # http://localhost:1420
```

打包当前平台：

```bash
pnpm -C apps/desktop tauri build
```

Linux 需要 `libwebkit2gtk-4.1-dev` 等系统包，详见 `Docs/phase-0/04-testing-and-acceptance.md`。

## 已实现

- ComfyUI 式布局：左侧节点库、中央自由画布、右上运行/终止、底部可收起日志
- 节点创建（拖入/点击）、移动、缩放、删除、连线、断线、参数内联编辑
- 工作流保存 / 打开 / 删除，视口一并持久化
- Rust 校验并返回结构化问题（36 个稳定 code，含 6 个循环/控制边规则、8 个子图规则、2 个资产规则）
- Rust 顺序执行：普通 DAG 走 Kahn 拓扑序，含控制节点的图走 token/activation 调度器；支持取消、失败隔离、禁用节点、能力拒绝
- 条件分支（Condition）与受控循环（Loop Gate）：显式预算、迭代计数、超时、预算耗尽失败、取消中断
- 自定义边路由：按实测节点矩形避障、反向边外侧绕行、圆角正交、平行边分道、无解 fallback，支持拖拽/缩放/保存重载
- 运行时事件流：每次运行内连续 `seq`、节点状态、迭代/激活编号、日志、交互请求
- 交互节点（Approval Gate）批准/拒绝，运行暂停等待
- SQLite 持久化运行记录、事件与终态；刷新后重新连接活动运行，按 `seq` 去重、补洞、恢复日志与节点状态
- 应用异常退出后，未完成运行标记为 `interrupted`，不伪装完成、不自动重跑；支持运行列表、详情与历史事件
- 单实例保护：同一数据目录只允许一个桌面进程，第二个实例在打开运行库前安静退出，不破坏第一个实例的运行记录
- 实时与持久化事件共用同一脱敏函数，顶层与嵌套输出一致；重复脱敏幂等；数据库写入失败显式告警并取消运行
- 节点目录 30 个 kind：29 个静态注册节点（基础节点、旧 ReAct Agent 节点 Provider/Model/Prompt/Context/Tool Set/Tool Dispatch/MCP/Skill/Reasoning、一等 `core.agent`、`core.lsp_server`、`core.project_workspace`、三个协议 Provider 与图片/音频/视频/文档输入节点）加动态 `core.composite`
- 中文可折叠节点库：10 个分组、图标与计数、全部展开/收起、中英文与 kind 搜索、折叠状态持久化、44px rail；中文标签只作用于展示层，稳定 kind/端口/参数名不变
- 模型能力与思考等级：`ModelCapabilities` 区分 native/preprocessed/unsupported/unknown；独立 `core.reasoning` 节点覆盖 off/auto/low/medium/high/xhigh，并按三条协议分别映射；不支持时运行前拒绝
- 多模态资产：图片/音频/视频/文档由 Rust 读取、缩放/抽帧/抽取；`AssetStore` 内容寻址去重，工作流只保存 `AssetRef`，不写 base64 或绝对路径；视频默认抽帧并标时间戳，音频 native/transcribed 显式区分
- 组合节点（Composite）：多选封装/解组、自动端口映射、控制边、双击展开与面包屑、可编辑内部画布，运行时按实例分层执行
- 组合模板：本地保存/插入/删除，实例化重映射全部节点与定义 ID；复制组合时深拷贝定义闭包，编辑副本不影响原定义
- 子图静态校验：检查端口绑定、递归、内部循环、控制边穿越与嵌套循环限制；非法结构在运行前拒绝
- 三条 Provider 协议共用统一 `ChatProvider`：OpenAI Chat、OpenAI Responses、Anthropic Messages；自定义 Base URL、SSE、tool_calls/tool_result、usage、推理字段与多轮状态分别编码；401/403、429、5xx、超时、断流映射为稳定错误码，重定向关闭以防凭据跨 host
- 旧 `core.provider` 仍兼容 OpenAI Chat；旧工作流按 Schema 1.0/1.1/1.2 加载，1.2 只新增可选 `assets` 表与 `subgraphId`
- 标准 ReAct Agent 组合模板：Prompt → Loop Gate → Model → Condition → Tool Dispatch / Context 回环，最终输出到 Log；Provider 与 ToolSet 作为数据输入，没有硬编码 Agent Loop
- 工具闭环：calculator、text_transform、json_query 内置工具，参数校验、超时、取消、ToolCall ID 对齐与结构化错误
- MCP：真实 stdio 与 Streamable HTTP JSON-RPC 客户端，工具名 `mcp__<namespace>__<tool>`；Skills：发现 `SKILL.md` 并注入系统上下文，不执行 Skill 脚本
- 权限与凭据：`DeclaredCapabilityPolicy` 拒绝未声明能力；网络/进程/文件/工具目标在运行时逐目标审批并缓存到本次运行；`env:`/`keyring:` 凭据引用，明文不进入工作流、日志或 SQLite
- 运行可靠性：流中断、MCP 崩溃、审批拒绝、取消、预算耗尽均有稳定错误码和回归测试；WebView 刷新后从 `active_run` 恢复事件流
- 一等 `core.agent`：Capabilities / Instructions / Collaboration / Control 四组端口，独立 AgentRunner 负责多轮模型、工具、上下文、完成判定、预算、审批与消息；Agent 节点内部循环不归 Scheduler
- 版本化协作协议：TaskEnvelope、AgentMessageEnvelope、ArtifactRef、AgentExecutionState；所有 Agent 消息经 Agent Message Bus 校验、去重、排序、持久化并受队列上限约束
- 双视图工作台：总览 + 每个 Agent 标签，展示当前任务、激活历史、模型增量、工具调用、消息、成本、审批与配置版本；画布与工作台双向定位，切换视图不重启运行
- 运行期干预：工作流/Agent 暂停、继续、取消，安全点后进入 `paused`；配置修订先预览再显式应用，过期 revision 拒绝；纠偏指令经总线在最近安全点注入
- 任务会话持久化：SQLite `user_version = 3` 新增 `projects`、`conversations`、`conversation_messages`、`conversation_runs`、`permission_audit`；`task_sessions` 继续保存 Agent 实例、激活、配置版本、消息与审批；刷新不影响 Rust 执行，崩溃后标记 `interrupted` 并要求人工核对工具副作用
- 受控工作区与 LSP：文件 `read(version) → write(expectedVersion)`，过期冲突拒绝；stdio LSP 真实 diagnostics/documentSymbol
- 公司示例：PM → Coder → Tester，结构化 PRD handoff、测试失败返工、同一 Coder 实例二次激活、版本化文件交付
- 项目工作区：`project_open` 规范化真实目录、稳定 `proj-*` 身份、不透明 `WorkspaceHandle`；项目/会话/文件树、文件搜索、Git 状态/diff/log 与 AGENTS.md 规则链
- 项目式 Agent 工作台：左侧项目/会话/文件树，中央总览与每 Agent 时间线，底部常驻 composer；右侧默认收起的文件/Git/规则/运行配置面板
- 三档运行权限：Ask / Workspace / YOLO 由 Rust `PermissionManager` 逐目标审批并审计；YOLO 也不自动放行敏感路径与高风险操作
- 版本化文件：`read(version) → write(expectedVersion)`，过期写入拒绝；`project_tree` 的 `kind` 统一为 `dir`/`file`
- 画布与工作台双向定位：Agent 标签定位到对应节点/组合层，画布节点回到对应 Agent 会话；切换不重启运行

## 文档

- [2.0 复用审计](Docs/phase-0/00-reuse-audit.md)
- [架构说明](Docs/phase-0/01-architecture.md)
- [Node Specification v1](Docs/phase-0/02-node-spec-v1.md)
- [运行时接口](Docs/phase-0/03-runtime-interfaces.md)
- [Phase 1.1 控制流设计](Docs/phase-1.1/01-design.md)
- [Phase 1.1 测试与验收](Docs/phase-1.1/02-testing-and-acceptance.md)
- [Phase 1.1.1 智能连线设计](Docs/phase-1.1.1/01-design.md)
- [Phase 1.1.1 测试与验收](Docs/phase-1.1.1/02-testing-and-acceptance.md)
- [Phase 1.2 运行持久化设计](Docs/phase-1.2/01-design.md)
- [Phase 1.2 测试与验收](Docs/phase-1.2/02-testing-and-acceptance.md)
- [Phase 1.2.1 单实例与脱敏设计](Docs/phase-1.2.1/01-design.md)
- [Phase 1.2.1 测试与验收](Docs/phase-1.2.1/02-testing-and-acceptance.md)
- [Phase 1.3 组合节点设计](Docs/phase-1.3/01-design.md)
- [Phase 1.3 测试与验收](Docs/phase-1.3/02-testing-and-acceptance.md)
- [Phase 1.4 文本 Agent 设计](Docs/phase-1.4/01-design.md)
- [Phase 1.4 测试与验收](Docs/phase-1.4/02-testing-and-acceptance.md)
- [Phase 1.5 多协议与多模态设计](Docs/phase-1.5/01-design.md)
- [Phase 1.5 测试与验收](Docs/phase-1.5/02-testing-and-acceptance.md)
- [Phase 1.6 Agent 节点与工作台设计](Docs/phase-1.6/01-design.md)
- [Phase 1.6 测试与验收](Docs/phase-1.6/02-testing-and-acceptance.md)
- [Phase 1.7 交互调研](Docs/phase-1.7/00-ux-research.md)
- [Phase 1.7 项目工作区](Docs/phase-1.7/01-project-workspace.md)
- [Phase 1.7 工作台映射](Docs/phase-1.7/02-workbench-mapping.md)
- [Phase 1.7 测试与验收](Docs/phase-1.7/03-testing-and-acceptance.md)
- [Phase 0 测试与验收](Docs/phase-0/04-testing-and-acceptance.md)
- [Phase 0 已知问题](Docs/phase-0/05-known-issues.md)

## 设计约束

- 不内置固定 Agent Loop；节点即执行单元，循环由 Loop Gate 与用户连边组合
- 前端不执行工作流，只编辑与提交命令
- 拖动/缩放等高频交互不调用 Rust
- 核心不依赖 macOS 专属能力
- 普通节点必须经过 `DeclaredCapabilityPolicy`；网络、进程、文件与工具目标再由运行时 `PermissionManager` 逐目标审批，Composite 内部不能绕过
- 不直接移植 2.0 Swift 代码；只复用协议与概念，见审计文档

## 许可证

见 [LICENSE](LICENSE)、[LICENSE-CORE](LICENSE-CORE)、[LICENSE-FRONTEND](LICENSE-FRONTEND)、[LICENSE-ABI](LICENSE-ABI)。
