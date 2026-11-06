# Phase 1.7 设计：项目工作台与双向映射

- 状态：实现与验收进行中
- 分支：`rewrite/3.0`
- 入口：`apps/desktop/src/components/ProjectWorkbench.tsx`
- 目标：普通用户默认在工作台完成“项目 → 会话 → 对话 → 查看改动”，高级用户随时回到节点画布；两套视图共享同一份工作流文档和同一个运行

## 1. 双视图结构

```
App
├─ 顶部工具栏        视图切换、运行/终止、校验、保存
├─ canvas-view       React Flow 节点编辑器（高级视图）
└─ workbench-view    ProjectWorkbench（默认视图）
   ├─ 左栏：项目 / 会话 / 文件 / Git
   ├─ 中栏：概览 + Agent 标签 + 时间线 + composer
   └─ 右栏：文件、Git、规则、运行配置（默认收起）
```

画布仍是唯一的图编辑器，没有第二个编辑器。工作台不渲染节点图，也不计算调度；它只显示 Rust 事件派生的会话状态，并把用户意图转换成 command。

状态所有权：

| 状态 | 所有者 | 说明 |
| --- | --- | --- |
| 工作流文档（节点、边、子图） | `App.tsx` | 画布编辑与工作台快速配置修改同一份文档 |
| 运行状态、事件、`AgentSession` | `App.tsx` | 来自 Rust `run.started` / `agent.event` / `run.finished` |
| 当前项目、会话列表、当前会话 | `App.tsx` + SQLite | 刷新后由持久层恢复 |
| 标签页、展开状态、右栏开关、搜索词 | `ProjectWorkbench` | 仅 UI 状态，不写回工作流 |
| 左栏折叠、辅助面板宽度 | `ProjectWorkbench` + localStorage | 纯偏好 |

不变量：工作台不执行节点、不推导 DAG、不自行生成事件。时间线只按事件顺序追加。

## 2. 左栏：项目与会话

层级固定为“项目 → 会话 → 文件”，避免同时出现多个并列根节点。

- 打开项目：`project-open-folder` → 系统目录选择 → `project_open(root)` → 写入 `projects` → 返回项目、`WorkspaceHandle`、顶层树和 Git 摘要。
- 最近项目来自 `project_list`，点击直接重新打开；项目根目录由 host 注册，前端不拼接绝对路径。
- 打开项目后加载该项目最新会话；没有会话时自动创建“新会话”（默认单 Agent 工作流）并切入工作台。
- “新建会话”创建独立工作流草稿；“新建团队”创建 PM → Coder → Tester 的示例团队工作流。运行中禁止新建。
- 会话列表显示标题、时间与 Agent 数，点击切换；切换前当前草稿通过 `conversation_save_workflow` 落库。
- 文件树只在项目根内展开，支持刷新、搜索、显示忽略文件；文件内容通过 `project_read` 读取，版本号随读取返回。
- Git 摘要显示分支、变更数量；详细 diff 在右栏。

会话不是聊天记录容器，而是“一个可继续的工作流 + 一组消息 + 多次运行”。同一会话可以连续发起多次运行，`conversation_runs` 记录每次 run。

## 3. 中栏：概览、Agent 标签与时间线

- 概览：项目名、会话标题、Agent 数量、当前运行状态、权限模式、最近事件；不显示虚构进度条。
- Agent 标签：每个运行中的 Agent 一个标签，标签顺序按首次出现；显示状态徽标（等待 / 运行 / 暂停 / 完成 / 失败 / 已取消）。
- 时间线：按 `seq` 展示用户消息、Agent 文本、工具调用、工具结果、交互请求、状态变化；inner Agent 事件折叠在对应激活下。
- 选中 Agent 后显示暂停、恢复、终止、定位到画布；没有运行记录时这些按钮不出现。
- composer：输入文本、权限模式、模型、推理强度、配置入口、发送/停止/指令。
  - 空闲时发送 = 新建一次运行，文本作为 `userMessage` 注入被寻址 Agent 的本轮 instruction。
  - 运行中发送 = `send_agent_directive` 给选中 Agent，同时把同一文本追加为会话消息；不重启运行。
  - 运行中未选 Agent 时拒绝发送并提示，避免指令落到错误实例。
- 权限模式切换是 `set_permission_mode` 实时生效；同时回写当前工作流中 Agent 节点参数，保证下次运行沿用。
- YOLO 有常驻警告条：自动批准常规文件/命令/网络，但仍拒绝敏感目标与高风险操作，且每次决策写入审计。

## 4. 右栏：辅助面板

默认收起，宽度不挤压画布；四个标签：

1. 文件：编辑器、保存（带 `expectedVersion`）、 stale 冲突提示、与磁盘 diff。
2. Git：status、diff、log 只读展示；不提供提交/推送按钮。
3. 规则：当前文件生效的 `AGENTS.md` 链，根到当前目录顺序展示。
4. 运行配置：当前 Agent 的模型、推理、工具集、权限预览；应用配置走 `preview` → `apply(expectedRevision)`，冲突拒绝而不是覆盖。

右栏不承担节点参数编辑；节点参数仍在画布节点内部编辑。

## 5. 双向映射

映射键不是标签文本，而是 `nodeId + scope 实例路径`：

```ts
agent.nodeId === node.id &&
agent.scope.length === scope.length &&
agent.scope.every((frame, i) => frame.instanceId === instancePath[i])
```

工作台 → 画布（`onLocateNode`）：

1. 由 `agent.scope` 得到子图路径与实例路径。
2. 校验该路径在当前文档中存在；不存在则提示“找不到该 Agent 所在的组合层级”，不静默跳错层。
3. 切换图层、重建当前层节点、选中目标节点、设置聚焦 nonce、切到画布视图。

画布 → 工作台（`onOpenAgent`）：

1. 取当前选中节点与当前实例路径。
2. 在 `session.agents` 中按上述键查找。
3. 找到则选中该 Agent 并切到工作台；没有运行记录时提示“该 Agent 还没有运行记录”，不创建空标签。

已知边界：映射粒度是 Agent 节点实例，不是单次激活。同一 Agent 节点在循环中多次激活仍对应一个标签，各次激活在时间线中分开展示；并发多激活的独立标签尚未实现。

## 6. 视图与刷新恢复

- 视图选择持久化在 localStorage `lingxi.view`；项目、会话、选中 Agent 分别持久化在 `lingxi.project` / `lingxi.conversation` / `lingxi.agent`。
- 刷新后先恢复视图骨架，再按持久化 ID 重新读取项目、会话与消息；找不到时回落到最近项目或空状态，不保留悬空选择。
- 运行中刷新由 SQLite `run_events` 重放恢复；事件按 `seq` 去重，已完成的运行不重新订阅。
- 只有 `agent.event` 会产生 Agent 时间线；普通节点事件只进底部运行日志。

## 7. 与既有约束的关系

- 工作台是普通 React 组件，不依赖 Tauri 之外的平台能力；所有文件、Git、运行操作都经 command。
- 高频交互（展开文件树、切换标签、滚动时间线）不触发 Rust 运行逻辑；只有显式文件操作、运行控制、配置应用会跨 IPC。
- 工作台没有固定 Agent Loop：是否继续、重试、换 Agent 由用户工作流和 composer 决定。
- 组合节点内部的 Agent 同样出现在 `session.agents`，scope 携带子图实例路径；权限仍逐目标审批，不因工作台视图而放行。

## 8. 已知限制

- 无会话级并发：一个会话同一时间只有一个运行。
- 无虚拟滚动：时间线全量渲染，极长会话（数千事件）会变慢。
- 时间线不做富文本渲染，代码块与 diff 以等宽文本展示。
- 工作台不提供节点创建/连线；需要结构化编排时切回画布。
- 映射只覆盖 Agent 节点；普通节点没有工作台标签。
