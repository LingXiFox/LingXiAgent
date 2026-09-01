# P15 Coding Toolchain Gap Audit

**审计日期：2026-08-31**  
**范围：仅 P15 Coding Toolchain；P16 Agent Behavior、P17 LSP/Codebase Intelligence 均不纳入实现。**

## 审计对象

- Tool runtime：`Sources/LingXiCore/Modules/Tool/ToolRuntime.swift`
- 内置工具：`Sources/LingXiCore/Modules/Tool/BuiltinTools.swift`
- 进程与 sandbox：`Sources/LingXiCore/Infrastructure/ToolExecutionSupport.swift`
- 权限：`Sources/LingXiCore/Modules/Permission/PermissionEngine.swift`、`Sources/LingXiProtocol/PermissionTypes.swift`
- Workspace 与敏感路径：`WorkspaceRoot`、`SensitivePathPolicy`
- 输出/上下文/持久化：`ToolOutputPolicy`、`ToolOutputArchive`、`SQLitePersistenceStore`
- 一致性：`ToolMutationCoordinator`

## 参考实现能力

| 能力 | Codex | OpenCode | Claude Code | LingXi 审计结论 |
| --- | --- | --- | --- | --- |
| Read range/page | 文件读与受控输出 | `read` 支持行范围 | `Read` 支持大文件限制 | LingXi 仅整文件读取，需补齐 |
| Glob/Grep | 专用 `rg`/文件工具 | `rg`，默认尊重 `.gitignore` | `Glob`/`Grep` | LingXi 手写遍历与 regex，需替换为受控 `rg` |
| Exact edit | 精确替换与错误恢复 | 精确替换 | 唯一精确匹配 | LingXi 已有；需统一 mutation 锁和编码/换行保留 |
| Patch primitive | `apply_patch` create/update/delete | `apply_patch` add/update/move/delete | Edit/Write 等效能力 | LingXi 已有正式 primitive 与回滚；需补齐 precondition、结果摘要和一致性 |
| Shell/process | cwd、超时、受控环境、sandbox | bash 权限与外部目录审批 | Bash + sandbox | LingXi 已有基础进程管理；需补齐诊断结果、显式 sandbox policy/capability 与进程组终止 |
| Permission domain | shell / patch hooks | `read`、共享 `edit`、`shell`、`external_directory` | Read/Edit/Bash path rules | LingXi 只有 ToolID/capability 粒度，需增加资源动作与外部目录双重授权 |
| Result/output paging | bounded result | 专用工具输出 | bounded output | LingXi 已有 archive；Shell 失败时诊断丢失，需修复 |
| LSP | 可选 | experimental | 可选 | P17+，本阶段不变更 |

参考：OpenAI `apply_patch` 与 shell 文档、OpenCode Tools/Permissions、Anthropic Claude Code Text editor/Permissions/Security 文档（2026-08-31）。

## 能力矩阵

| 项目 | 状态 | 当前事实 | P15 处置 |
| --- | --- | --- | --- |
| Tool runtime 与 schema 预检 | 已有且足够 | Provider 无关注册、参数 JSON/schema 校验、统一失败归一化 | 复用 |
| Read 基础安全 | 已有但不足 | workspace canonicalization、敏感路径与 UTF-8 guard 已有；大文件直接失败 | 增加 line/range、分页、行号、二进制/截断 metadata |
| Glob/Grep | 已有但不足 | 手写枚举，不遵循 `.gitignore`，没有 generated/vendor 策略或结果截断 metadata | 使用已安装 `rg`，受控参数，不经 shell command |
| Edit | 已有但不足 | exact replacement、0/多匹配、content hash、atomic write 已有 | 保留原始换行/编码，加入通用 mutation 一致性 |
| Write | 已有但不足 | create 与已有文件 hash/overwrite 已有 | 敏感/二进制覆盖防护、统一 edit 权限与结果 |
| Apply Patch | 已有但不足 | 正式 Add/Update/Delete/Move、解析、预检、快照回滚已有 | 增加 expected precondition、changed files/diff summary、全局 mutation 锁 |
| Shell | 已有但不足 | cwd、sanitized env、timeout、stdout/stderr 分离、workspace sandbox 调用已存在 | nonzero 保留结构化诊断、output limit/continuation、shell action 权限 |
| Background process | 已有但不足 | start/poll/input/stop、cursor ring buffer 已有 | 显式 PID/handle、输出限制 metadata、进程组/子进程终止 |
| Sandbox | 已有但不足 | macOS `sandbox-exec` 不可用时 workspace shell fail-closed | 建立 `SandboxPolicy`/`SandboxExecutor`、报告 enforceable capability；网络策略不能可靠实现时拒绝声明 |
| Permission engine | 已有但不足 | allow/ask/deny、ToolID/capability rule 已有 | 增加 `read(path)`、共享 `edit(path)`、`shell(command)`、`externalDirectory(path)` 资源规则 |
| Git | 已有且足够 | 结构化 allow-list，默认无 push/clean/reset hard | 复用；补齐 diff cached action |
| ToolResult/输出归档 | 已有但不足 | success/error/outcome/output metadata/blob archive 已有 | Coding 结果补充 diagnostics、changed files、continuation、exitCode |
| Context integration | 已有且足够 | mutation 后已可重建 project index；输出可归档 | 复用且不引入 P17 代码 intelligence |
| Persistence | 已有且足够 | Tool output blob 由 SQLite store 管理 | 复用，不增加 coding workflow 状态 |
| 并发 mutation | 已有但不足 | CoreHost 注入时串行；独立 ToolRuntime 不保证 | 默认强制 mutation coordinator，stale 写失败 |
| Agent behavior / prompting | P16+ | 非工具 primitive | 不实现 |
| LSP / symbol intelligence | P17+ | 已有 context 索引工具不扩展为 LSP | 不实现 |
| Workflow / GUI / Remote runtime / Provider | P16+ 或非 P15 | 非本阶段范围 | 不实现 |

## Sandbox 实际基线

当前平台目标为 macOS 13+。`/usr/bin/sandbox-exec` 可用时，workspace profile 使用 OS 级 filesystem allow-list，且不在可用时 silent fallback。它不是跨平台保证；网络、命名空间、容器与子进程资源隔离不能由现有 backend 可靠表达。P15 会把此能力正式建模：不能满足策略的 backend 必须返回 `sandboxUnavailable`，由 Permission Engine 升级审批，而非伪称已 sandboxed。

## P15 实施边界

1. 复用现有 `ToolRuntime`、`PermissionEngine`、`ToolOutputArchive`、`ToolMutationCoordinator` 与受控 Git；不建第二套 runtime。
2. 保留已有 patch 格式，增强其事务/结果/并发约束，不通过 `shell("apply_patch ...")` 伪造工具。
3. 仅使用 Foundation、已安装 `rg` 和系统 `sandbox-exec`；不引入第三方依赖。
4. 新增 `CodingToolContractTests` 与纯本地 fixture scenario；不调用真实 LLM，不修改 Golden。
