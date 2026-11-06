# Phase 1.7 设计：项目工作区、会话与权限

- 状态：实现与验收进行中
- 分支：`rewrite/3.0`
- Schema：工作流仍为 `1.2`，未新增必填字段；项目绑定放在节点参数与会话表
- 数据库：SQLite `user_version = 3`
- 核心不变量：Runtime 不枚举宿主路径；只有 Tauri host 能把项目根目录注册进本次运行的 `WorkspaceCatalog`

## 1. 分层

```
crates/lingxi-spec
  model / validation                 工作流 JSON、节点规格、静态校验
        ↑
crates/lingxi-runtime
  project.rs                         ProjectRef、WorkspaceHandle、WorkspaceCatalog
  project_node.rs                    core.project_workspace
  workspace.rs                       版本化文件、搜索、Git、AGENTS.md
  permissions.rs                     Ask / Workspace / YOLO 逐目标审批与审计
        ↑
apps/desktop/src-tauri
  projects.rs                        项目注册、文件/Git/规则 command、默认/团队工作流
  commands.rs                        run_workflow 绑定项目、会话历史、权限策略
  runs.rs                            SQLite 项目/会话/消息/审计
        ↑
apps/desktop/src
  ProjectWorkbench.tsx               项目/会话/文件树、时间线、composer、辅助面板
```

Phase 1.7 没有把项目能力塞进 Scheduler：项目是一个普通节点 `core.project_workspace`，它把不透明的 workspace 句柄交给 Agent；调度器仍只认识端口、边和激活。

## 2. 项目身份

`project_open(root)` 只接受已存在的目录：

1. `Workspace::open_existing` 规范化根目录（canonicalize），不创建目录。
2. `project_id_for(root)` 用 FNV-1a 对规范路径做稳定哈希，格式 `proj-{16 hex}`。同一路径重复打开得到同一 ID；移动目录会得到新 ID。
3. 项目名默认取根目录名，写入 SQLite `projects`，记录 `last_opened_at_ms`。
4. 返回 `{ project, workspaceHandle, tree, git }`。`tree` 只含顶层条目。

项目路径是 host 侧数据。Runtime 的事件、工作流 JSON、日志、Agent 工具参数里都不出现绝对根路径，只出现 `projectId`、项目名和 `WorkspaceHandle`。

## 3. `WorkspaceHandle` 与目录

```rust
pub struct ProjectRef {
    pub project_id: String,
    pub name: String,
}

pub struct WorkspaceHandle {
    pub handle_id: String,
    pub project: ProjectRef,
    pub relative_cwd: String,
}
```

- `handle_id` 形如 `ws-{...}`，由项目 ID 与根路径派生；它不是文件路径，也不能被节点解释成路径。
- `WorkspaceCatalog` 是**每次运行**的注册表：`register(ProjectRef, root, cwd)`、`register_workspace(ProjectRef, Arc<Workspace>, cwd)`、`handle(id)`、`workspace(id)`、`workspace_for_project(project_id)`、`handles()`、`remove()`。
- 会话运行只注册当前项目；工作流里若写另一个项目的 `projectId`，节点执行返回 `workspace.not_found`，错误文本为 `project ... is not open; select the folder again` 或 `no project catalog is attached to this run`。
- 没有会话的独立画布运行使用应用默认 Agent 工作区；它不声明项目绑定，也不显示项目文件/Git。

## 4. `core.project_workspace` 节点契约

`PROJECT_KIND = "core.project_workspace"`。

| 项目 | 名称 | 类型 | 说明 |
| --- | --- | --- | --- |
| 输入 | `projectId` | Text | 优先于参数；为空时用参数 |
| 输入 | `cwd` | Text | 项目内相对目录，默认根目录 |
| 输入 | `policy` | Json | 预留运行策略输入，当前不由节点解释 |
| 输出 | `workspace` | Text | `WorkspaceHandle.handle_id`，交给 Agent 的 workspace 端口 |
| 输出 | `project` | Json | `ProjectRef`，不含根路径 |
| 输出 | `metadata` | Json | `{ projectId, name, cwd, topLevelEntries, git, showIgnored }` |
| 输出 | `ready` | Control | 表示工作区绑定完成，控制下游 Agent 启动 |
| 参数 | `projectId` | Text | 工作区内嵌选择器写入 |
| 参数 | `cwd` | Text | 相对子目录 |
| 参数 | `showIgnored` | Boolean | 文件树是否显示忽略项，默认 false |

执行流程：解析输入/参数 → 查本次运行 catalog → 检查目录在项目根内 → 产出句柄与元数据 → 记录 `workspace bound to project {name}`。失败是节点失败，不是静默跳过；同一次运行中其他项目无法被这个句柄访问。

## 5. 版本化文件

`Workspace` 的写操作必须带期望版本：

```rust
read(path) -> FileSnapshot { path, version, content, bytes }
write(path, content, expected_version)
delete(path, expected_version)
```

- 新文件以常量 `"absent"` 作为期望版本；已存在文件的版本由内容派生。
- 期望版本不匹配返回冲突，不覆盖；前端提示重新读取。
- 所有路径解析到项目根内；绝对路径、`..`、NUL 和解析后逃出根目录的符号链接都被拒绝。
- 读上限 4 MiB，搜索上限 1 MiB；文件树/搜索结果不返回根路径。
- `project_tree` 返回 `FileEntry { path, name, kind, size, version }`；`kind` 固定为 `"dir"` 或 `"file"`，前端用同一值决定展开目录或打开文件。
- `project_read`、`project_write`、`project_delete`、`project_search`、`project_tree` 是 host command；Agent 的 `read_file`/`write_file` 等工具走同一 `Workspace`。

## 6. 权限模型

`PermissionMode` 三档，默认 `Ask`：

| 能力 | Ask | Workspace | YOLO |
| --- | --- | --- | --- |
| 文件读（项目内安全相对路径） | 自动 | 自动 | 自动 |
| 文件写/删（项目内安全相对路径） | 询问 | 自动 | 自动 |
| 项目检查/构建命令 | 询问 | 仅白名单命令自动 | 白名单命令自动 |
| 任意进程 | 询问 | 询问 | 仅 `safe_process` 自动，高风险仍拒绝 |
| 网络 | 询问 | 询问 | 自动 |
| 工具 | 询问 | 询问 | 自动 |

补充规则：

- `sensitive_target`（`.env`、`.ssh/`、`id_rsa`、`.aws/credentials`、`.npmrc` 等）任何模式都不自动放行。
- `high_risk_target`（`rm -rf`、`sudo`、`git push`、`cargo publish`、`git reset --hard`、`mkfs`、`shutdown` 等）任何模式都不自动放行。
- Workspace 进程白名单：`cargo test/check/build/clippy/fmt/metadata/tree/bench`；`npm|pnpm test/run/build/lint/check/typecheck`（禁止 install/add/publish/exec）；`go test/build/vet`；`dotnet build/test`；`pytest`；`node --test`；`python|python3 -m pytest`。
- 声明能力不等于授权。节点先过 `DeclaredCapabilityPolicy`，再由 `PermissionManager` 逐目标审批；批准按 `run + node + class + target` 缓存并带过期时间。组合节点内部不例外。
- Agent 节点只能收紧运行策略：`set_agent_mode` 不会把 Ask 放宽成 YOLO。
- 运行中切换模式递增 policy revision 并清空旧缓存，下一次操作按新模式判断。
- 三种模式都**不沙箱**任意子进程；Workspace 白名单只限制自动批准，不限制用户手动批准的进程。UI 必须明示这一点。
- 每个决策写 `permission_audit`：run、node、mode、capability、target、decision、detail、时间；`permission_audit` command 可查。

## 7. 会话与持久化

`conversation` 是“一个项目里的持续任务”，不是一次运行：

```sql
projects(project_id PK, name, root, created_at_ms, updated_at_ms, last_opened_at_ms)
conversations(conversation_id PK, project_id FK, title, workflow_json, created_at_ms, updated_at_ms)
conversation_messages(message_id PK, conversation_id FK, run_id,
  agent_node_id, agent_instance_id, role, content, created_at_ms)
conversation_runs(run_id PK, conversation_id FK, created_at_ms)
permission_audit(id, run_id, node_id, mode, capability, target,
  decision, detail, at_ms)
```

- 新建会话先确保项目 workspace，再生成默认工作流并校验；校验失败拒绝创建。
- 会话保存工作流草稿（`workflow_json`），运行开始时作为快照提交；composer 文本只注入本次运行的 Agent 指令，不改写已保存草稿。
- 每次运行写 `conversation_runs`，用 `run_id` 关联事件与消息。
- 运行完成后 assistant 结果写入 `conversation_messages`；下一次运行按 Agent 节点组装历史：全部 user 消息 + 该节点自己的 assistant 消息。
- `projectId` 由会话决定；工作流节点参数里的项目必须与之一致，否则运行前或节点执行时拒绝。

## 8. 默认工作流与团队工作流

默认单 Agent：

```
project(workspace) ──data──▶ agent.workspace
project(ready) ───control──▶ agent.start
agent(userResponse) ──data──▶ log.value
agent(completed) ──control──▶ log.run
```

默认工具集：`read_file,write_file,list_files,delete_file,search_files,run_command,git_status,git_diff,git_log`。

团队工作流：

```
project ──workspace──▶ PM / Coder / Tester
PM.completed ──▶ LoopGate.start
LoopGate.continue ──▶ Coder.start
Coder.completed ──▶ Tester.start
Tester.failed ──▶ LoopGate.next
Tester.completed ──▶ LoopGate.stop
LoopGate.exit ──▶ Log.run
PM/Coder.agentMessage ──▶ 下一角色.task
Tester.agentMessage ──▶ Coder.messages
```

Loop Gate 的 `maxIterations = 4`、`timeoutMs = 120000`。团队模式仍是用户连出来的图，不是引擎内置 Agent Loop；Phase 1.7 不新增并发调度。

## 9. 项目规则

`project_rules(path)` 返回从项目根到目标目录路径上的 `AGENTS.md` 链，按由外到内排序。当前实现：

- `path = ""`：只返回根 `AGENTS.md`（若存在）。
- `path = "src/index.ts"`：返回根 `AGENTS.md` 与 `src/AGENTS.md`。
- `path = "src"`（无尾斜杠）：按文件处理，只返回根规则；需要目录规则时传目录内的文件或带尾斜杠。

规则只作为上下文注入，不是权限来源；文件内容不会自动获得执行权。

## 10. 错误与边界

| 情况 | 结果 |
| --- | --- |
| 打开不存在的目录 | `project_open` 拒绝，不创建目录 |
| 工作流引用未注册项目 | `workspace.not_found`，节点失败 |
| 路径越界 / 符号链接逃逸 | 文件操作拒绝，错误包含 `escapes` |
| 写入过期版本 | 冲突拒绝，保留磁盘内容 |
| Ask 模式写文件被拒 | Agent 在该工具处失败，运行按既有失败传播 |
| YOLO 高风险命令 | 拒绝并审计，不执行 |
| 项目被移除 | 已有会话仍保留记录；下次运行需重新打开项目 |

## 11. 兼容性

- 工作流 Schema 仍为 `1.2`，没有新增必填字段；旧工作流没有 `core.project_workspace` 节点时按原方式运行。
- SQLite 从 `user_version = 2` 迁移到 `3`，只新增 `projects`、`conversations`、`conversation_messages`、`conversation_runs`、`permission_audit`，不删除旧表。
- 默认 Agent 工作区保留，Phase 1.6 的独立画布/公司示例不因项目绑定而失效。
