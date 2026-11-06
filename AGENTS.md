# LingXiAgent 3.0 — Agent Development Guidelines

适用范围：本文件所在仓库及其子目录。自动化开发 Agent 必须遵守；用户的明确要求优先于一般工作习惯，但不能绕过安全边界。当前主开发分支为 `rewrite/3.0`，`rewrite/2.0` 仅作迁移参考，不要擅自改写。

## 1. 产品与架构约束

- **产品定位**：ComfyUI 式、可插拔、可交互的节点工作流平台。工作流由用户自由组合节点，不内置固定 Agent Loop。
- **UI 保持极简**：节点编辑器保持中央画布、左侧节点库、右上角运行与终止、底部可收起的实时日志，配置优先放在节点内部。Phase 1.7 明确授权普通用户以项目工作台为主视图：可折叠的左侧项目/会话/文件树，中央 Agent 对话时间线，底部常驻输入框，以及默认收起的右侧文件/diff/Git/规则/运行配置辅助面板；高级用户在同一项目中切换到节点编辑器。不要增加常驻仪表盘、与 Agent 执行无关的装饰面板或第二套工作流编辑器。
- **技术栈**：Rust workspace + Tauri 2 + React/TypeScript + `@xyflow/react`。`crates/lingxi-spec` 定义文档与节点契约；`crates/lingxi-runtime` 负责校验和执行；`apps/desktop/src-tauri` 仅为桌面适配层；`apps/desktop/src` 只负责编辑和展示。
- **依赖方向**：`lingxi-spec` ← `lingxi-runtime` ← Tauri 宿主。核心库不得依赖 Tauri、React 或 macOS 专属 API。前端不得实现另一套工作流调度器；拖拽、缩放等高频操作不得逐帧调用 Rust IPC。
- **跨平台是硬要求**：面向 macOS / Windows / Linux。平台差异封装在独立适配层，不要把某一系统的专属 API 渗透到核心。CI 编译通过不等于实机运行验收通过。
- **演进而非伪装完成**：当前 Phase 1.7 支持无环 DAG、受控循环、组合子图、SQLite 运行恢复、一等 `core.agent`、独立 AgentRunner、版本化协作协议与消息总线、双视图 Agent 工作台、安全暂停/配置修订/纠偏指令、TaskSession 恢复，以及项目注册表、`core.project_workspace` 的不透明 WorkspaceHandle、项目会话/多 run 连续性、Ask/Workspace/Yolo 三档 Rust 侧权限、版本化文件与 git 受控访问、工作台与节点编辑器双向定位；同时保留 OpenAI Chat / OpenAI Responses / Anthropic Messages 三条真实协议、独立 Reasoning、模型能力检查和图片/音频/视频/文档资产链路。Agent 并发调度、checkpoint 结构迁移、动态插件、共享资源总线、原生视频输入与内置语音识别尚未实现。新增功能必须给出真实的契约、测试和验收结果，不能用 UI 假交互冒充后端能力。

## 2. 节点、循环与资源安全

- **节点是最小执行单元**；通过 NodeSpec 声明类型化输入/输出、参数和能力，执行器在 Rust 侧注册。工作流 JSON 不得包含 React Flow 的内部临时状态。
- **Agent Loop 由节点构建**。可以用 Loop Gate 组合单层循环：必须存在流向 SCC 外的 `exit` 边，反馈路径必须经过 Gate，且显式配置 `maxIterations` 与 `timeoutMs`；静态只证明循环受控，终止由运行期预算强制。也可以使用一等 `core.agent`，由其内部 AgentRunner 完成多轮模型/工具循环；Runner 仍是节点执行器，不得把固定 Agent Loop 塞进 Scheduler。不可通过简单移除 `graph.cycle` 检查来“支持循环”。
- **工作流不配置文件并发细节**。并发由调度器执行，资源冲突由工具与总线处理。共享文件写入必须遵循 `read(version) → write(expected_version)` 的原子比较与提交；过期版本拒绝、要求重新读取，禁止静默覆盖或擅自合并。
- **能力声明不等于授权**。`DeclaredCapabilityPolicy` 只放行节点声明的 capability，并拒绝未知能力；网络、进程、文件与工具目标由 `PermissionManager` 在运行时逐目标审批，按 run + target 缓存。Provider 模型发现与推理使用同一个网络审批，目标为 `protocol://host:port`；MCP 审批必须列出可执行文件、参数、cwd 与相关环境键，不得把子进程审批说成沙箱。不得用预授权绕过用户审批，Composite 内部也不得绕过。受控工作区已提供版本化 `read(version) → write(expectedVersion)`，其他共享文件路径不得绕过它；共享资源总线仍未实现。
- **资产不是路径字符串**。工作流只保存 `AssetRef`/资产 ID，不保存 base64、绝对路径或文件句柄；导入、读取、缩放、抽帧和文档抽取必须在 Rust 的受控 `AssetStore` 中完成。不得让前端或工作流拼任意路径，不得静默丢弃不支持的原生媒体，也不得在未支持时假装原生输入。
- **凭据与密钥**不得进入工作流 JSON、日志、截图、测试夹具和提交。拒绝未经授权的危险操作，错误必须有可定位的稳定错误码。
- **插件方案保持开放**：保留 2.0 的能力声明、隔离和契约测试思想，但不要未经评估便认定 C ABI、WASM 或子进程 RPC 是唯一方案；影响兼容性的决定应记录 ADR。

## 3. 变更方式与 Git 纪律

- 动手前检查 `git status --short`，阅读受影响模块的实现、相关文档与测试；保护用户未提交的修改，不进行无关重构。
- 优先小批量、可验证的改动。改变节点协议、事件、错误码、权限语义时，同步更新相关测试和 `Docs/` 文档；对破坏性变更提供版本迁移方案。
- 不擅自执行 `git reset --hard`、`git clean -fdx`、强制推送、覆盖其他人的提交或清理用户文件。确需破坏性操作，先说明影响并获得明确授权。
- 不为了让测试通过而删测试、吞错误、放宽安全检查或把真实执行换成 mock。浏览器 mock 仅用于前端开发；最终行为以真实 Rust/Tauri 链路为准。
- 保留仓库现有 LICENSE 及模块授权边界，不随意修改许可证。

## 4. 按改动范围选择验证，不盲目全量编译

| 改动范围 | 最低验证 |
| --- | --- |
| 纯文档（见第 6 节） | 核对链接、路径、术语与修改范围；一般无需编译 |
| 仅前端 UI/CSS/TS | `pnpm -C apps/desktop build`；涉及交互时手工验证关键路径 |
| Rust spec/runtime | `cargo fmt --all -- --check`、`cargo clippy --workspace --all-targets -- -D warnings`、`cargo test --workspace` |
| Tauri IPC / Rust↔前端契约 | Rust 检查与测试 + 前端 build + 真实 `tauri dev` 验证 |
| 跨平台、插件、权限、依赖或 CI | 对应定向测试 + GitHub Actions 三平台结果；无法实测的平台明确标注 |

- 单测优先、按需扩大范围。不要对每一个微小改动都重复 `tauri build`、全量 Release 编译或安装包构建。
- 使用仓库锁文件；CI/可复现安装使用 `pnpm -C apps/desktop install --frozen-lockfile`。不要擅自升级 Rust、Node、Tauri 或依赖的大版本。
- 工具链以实际依赖和 CI 为准。Rust 可由 Homebrew 提供，不要求开发者必须安装 `rustup`；变更 MSRV 时同步校准 `Cargo.toml` 与 README。
- 任何“通过”结论必须注明实际执行的命令、平台及结果；没有执行就明确写“未验证”。

## 5. 磁盘与构建缓存：禁止例行 `cargo clean`

- **禁止每天、每次提交或每次构建后自动执行 `cargo clean`**。它会删除可复用构建产物，导致重新编译、增加耗时及写盘量。
- 默认保留 `target/`、Cargo 依赖缓存和前端依赖；`target/`、`node_modules/` 必须保持在 `.gitignore` 中。
- 怀疑空间膨胀时先测量而非清理：

  ```bash
  du -sh target apps/desktop/node_modules ~/.cargo/registry ~/.cargo/git 2>/dev/null
  df -h .
  ```

- 若空间确有压力，先定位哪个工作区、构建配置或工具占用空间；提出最小范围的清理方案并经用户同意，再执行。例如只清理当前 workspace 的 Release 构建：`cargo clean --release`。注意确认 `CARGO_TARGET_DIR` 是否重定向到共享目录。
- **不得未经授权删除**整个 `target/`、`~/.cargo`、其他项目的构建缓存、外置磁盘数据或用户工作区。不要擅自把频繁构建放到外置冷存储磁盘。

## 6. 纯文档提交与 CI 跳过规则

- 只有在**本次提交的所有变更都属于纯文档**时，才可考虑跳过 CI。允许范围例如：`README.md`、`AGENTS.md`、`Docs/**/*.md` 和纯展示用途的文档图片。`Docs/reference/2.0/` 保持只读，除非用户明确要求维护历史归档。
- **不算纯文档**：Rust/TS/JSON 源码、测试或夹具、`Cargo.toml`、`Cargo.lock`、`package.json`、`pnpm-lock.yaml`、配置、脚本、工作流 YAML、生成代码，以及会影响产品运行的资源文件。混合提交一律正常跑 CI。
- 提交前用 `git diff --cached --name-only` 核对暂存的全部文件；还需确认本次提交没有遗漏需要联动验证的代码变更。不要因为提交标题写了 `docs:` 就自动跳过。
- **若确认 CI 不是目标分支的必需状态检查**，纯文档提交可以在提交信息中使用 `[skip ci]`。例如：`docs: update developer guide [skip ci]`。仅在能确认不会阻塞合并时自动采用。
- **若 CI 是 Required Check，或无法确认分支保护规则：不要添加 `[skip ci]`**。GitHub 对因提交消息或路径过滤跳过的必需检查可能保持 `Pending`，导致 PR 无法合并。此时让 CI 正常运行；后续如需优化，应调整 workflow 的 job 级条件与独立的必需检查，而不是盲目使用 `paths-ignore`。
- **`AGENTS.md` 只能指导 Agent 的提交行为，不能自行改变 GitHub Actions 触发规则**；除非任务明确要求，不修改 `.github/workflows/ci.yml`。

## 7. 每轮交付的回复格式

完成任务后简要报告：

1. **改了什么**：关键文件与行为变化。
2. **验证结果**：实际运行的命令、通过/失败、未验证的平台或环节。
3. **风险与下一步**：剩余问题、兼容性影响、是否需要用户决策。
4. **Git 状态**：是否提交、提交 SHA（若有）、是否推送、CI 状态（若已核实）。

不要将计划写成已实现，不要承诺在后台继续执行未创建的任务。
