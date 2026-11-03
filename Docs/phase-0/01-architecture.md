# Phase 0 · 架构说明

## 一、目标与非目标

Phase 0 交付一个可启动、可编辑、可保存、可由 Rust 执行并回传事件的节点工作流底座。

**目标**

- Rust workspace：运行时与桌面壳解耦，桌面壳可替换。
- 工作流是纯 JSON，前端组件结构不进入存储格式。
- 前端只编辑与展示；校验、调度、执行、取消都在 Rust。
- ComfyUI 式布局与交互：中央画布、左侧节点库、右上运行/终止、底部可收起日志。
- 为插件注册、交互总线、运行状态事件、资源权限层预留稳定接口。

**非目标（本阶段明确不做）**

- 真实 LLM 推理、Provider、Agent Loop。
- 多 Agent 协作、子工作流、循环/迭代节点。
- 动态插件加载（`.so/.dylib/.dll`）、插件市场。
- 运行历史持久化、SQLite、崩溃恢复。
- 并行调度、每节点超时、重试策略。
- 代码签名、公证、安装包分发。

## 二、Workspace 布局

```
Cargo.toml                     # workspace：resolver 2，共享版本与依赖
crates/
  lingxi-spec/                 # 纯数据层：Workflow / NodeSpec / Edge / 校验
    src/model.rs               # 工作流文档模型（serde camelCase）
    src/node.rs                # NodeSpec、端口、参数、DataType、能力常量
    src/validation.rs          # 静态校验与稳定错误码
    tests/validation.rs
  lingxi-runtime/              # 执行层：不依赖 Tauri
    src/engine.rs              # DAG 调度、能力检查、取消、终态
    src/registry.rs            # NodeSpec + NodeExecutor 注册表
    src/builtin.rs             # 7 个内置节点（普通注册项）
    src/context.rs             # 节点执行上下文（参数/输入/日志/交互）
    src/event.rs               # RunEvent / EventSink
    src/interaction.rs         # 交互请求与决议
    src/control.rs             # RunControl 取消令牌
    tests/engine.rs
apps/desktop/
  src-tauri/                   # Tauri 2 桌面壳（仅此层依赖 tauri）
    src/lib.rs                 # AppState 组装、命令注册
    src/commands.rs            # IPC 命令、事件桥
    src/store.rs               # 工作流 JSON 文件存储
  src/                         # React + TypeScript 前端
    App.tsx                    # 画布状态与命令编排
    components/                # Canvas / LingXiNode / NodeLibrary / Toolbar / LogPanel ...
    lib/                       # 协议类型、transport、mock、工作流工具
```

依赖方向严格单向：`lingxi-spec ← lingxi-runtime ← lingxi-desktop`。`lingxi-runtime` 不引用 `tauri`，可以单独作为库嵌入 CLI、测试或其他宿主；`lingxi-spec` 不引用运行时，可被任意工具消费。

## 三、进程与边界

```
┌────────────────────────────── WebView (React) ──────────────────────────────┐
│ App.tsx 状态：nodes / edges / meta / logs / status                           │
│   │ 用户编辑（拖拽、连线、参数）——本地完成，不逐帧跨进程                      │
│   │ 显式命令：validate / run / stop / save / load / respond                 │
│   ▼                                                                          │
│ transport.ts  ── Tauri invoke ──┐         ▲  lingxi:run-event（emit）        │
└─────────────────────────────────┼─────────┼──────────────────────────────────┘
                                  ▼         │
┌──────────────────────────── Tauri shell (Rust) ─────────────────────────────┐
│ commands.rs：参数反序列化、RunStartResponse、事件转发                          │
│ AppState { registry, engine, interactions, runs, store }                     │
│   │                                                                          │
│   ▼                                                                          │
│ lingxi-runtime::Engine                                                       │
│   validate → Kahn 排序 → 逐节点：能力检查 → executor → 输出/失败/跳过          │
│   EventSink → RunEvent → app.emit("lingxi:run-event")                        │
└──────────────────────────────────────────────────────────────────────────────┘
```

关键点：WebView 里没有任何调度逻辑。前端提交的是完整 `Workflow` 文档；Rust 返回校验报告或运行 ID，之后只消费事件。

## 四、一次运行的完整数据流

1. 前端把画布序列化为 `WorkflowDoc`（`buildDoc()`），节点参数与位置全部来自本地状态。
2. `invoke("run_workflow", { workflow })`；Tauri 用 serde 反序列化为 `lingxi_spec::Workflow`。
3. `Engine::validate` 先跑完整静态校验；不通过则直接返回 `{started:false, report}`，不创建运行。
4. 通过后生成 UUID `run_id`，把 `Arc<RunControl>` 放入 `runs` 表，`tauri::async_runtime::spawn` 执行，命令立刻返回 `{started:true, runId}`。
5. 引擎先发 `run.started`，再用 Kahn 算法得到拓扑序（同层按文档顺序稳定排序）。
6. 每个节点：
   - 未注册类型 → `node.failed`（`node.unknown_kind`）；
   - `enabled=false` → `node.skipped`，并让下游不可用；
   - 任一上游不可用 → `node.skipped`；
   - 输入端口缺值 → `node.failed`（`node.missing_input`）；
   - 声明的能力未获授权 → `node.failed`（策略错误码）；
   - 否则发 `node.started`，在 `tokio::select!` 中与取消信号竞速执行 executor。
7. 成功：`node.finished` 携带 `outputs`，输出只保存在内存 Map 中供下游读取；失败：`node.failed`，节点进入 `unavailable`，独立分支继续执行；取消：`node.cancelled` 后终止循环。
8. 终态：`cancelled` > `failed` > `completed`（按优先级判定），发一次 `run.finished`，随后从 `runs` 表移除控制句柄。

运行态数据不落盘：日志、节点输出、运行摘要都只存在于本次进程内。这是 Phase 0 的刻意取舍，见「已知问题」。

## 五、调度与并发模型

- **顺序执行**：按拓扑序逐节点执行，不并行。好处是事件顺序确定、日志可读、调试简单；代价是独立分支不能重叠执行。并行调度留给后续版本，接口（`Engine::execute`）不需要改。
- **无内置 Agent Loop**：引擎只认 DAG 与 executor，不认「模型」「工具」「轮次」。任何 Agent 语义都必须表现为节点或节点组合。
- **取消**：`RunControl` 是 `tokio` 的取消令牌封装。停止命令只置位；引擎在节点边界检查，并在 `select!` 中优先响应取消。executor 若不 await，取消无法抢占——协作式取消，测试里用 30s sleep 的节点验证了这一点。
- **失败隔离**：单节点失败不中止整张图；只有依赖它的下游被 skip。这样多分支工作流可以一次跑出所有独立错误。

## 六、能力与权限（预留层）

- 节点通过 `NodeSpec.capabilities` 声明 `interaction / network / filesystem / process` 等能力。
- 引擎在执行 executor **之前**逐项调用 `CapabilityPolicy::authorize`；拒绝即失败，executor 根本不会运行。
- 桌面壳当前注入 `AllowAllPolicy`（Phase 0 没有危险节点），这是唯一的放行点；未来替换为按工作流/用户授权的策略即可，节点侧无需改动。
- 这条检查位于引擎而不是节点内部，因此「普通节点绕过权限层」在结构上不成立——节点拿不到执行机会。

## 七、交互总线

`Approval Gate` 节点演示了完整闭环：

1. executor 调 `ctx.request_interaction(prompt, options)`；
2. `PendingInteractions` 生成 `request_id`，保存 `oneshot::Sender`，发 `interaction.requested`；
3. 前端弹窗，用户选择后 `invoke("respond_interaction", { requestId, approved })`；
4. broker 唤醒等待者，发 `interaction.resolved`；批准则节点输出 payload，拒绝则节点以 `interaction.denied` 失败；
5. 运行被取消时，等待中的交互随节点一起结束，不会泄漏挂起任务。

`InteractionBroker` 是 trait，桌面壳只是把事件接到 WebView；未来可以接 CLI、HTTP 或测试替身。

## 八、存储

- 位置：Tauri `app_data_dir()/workflows/<name>.json`（macOS 为 `~/Library/Application Support/site.lingxi.desktop/workflows`，Windows 为 `%APPDATA%\site.lingxi.desktop\workflows`，Linux 为 `~/.local/share/site.lingxi.desktop/workflows`）。
- 一文件一工作流，人可读、可 diff、可手工备份。
- 写入用「临时文件 + rename」原子替换，避免半截 JSON。
- 名称即文件名，因此保存前校验：非空、≤64 字符、不以 `.` 开头、不以 `.`/空格结尾、只允许字母/数字/空格/`-`/`_`/`.`。路径分隔符与 `..` 因此无法进入文件系统。
- SQLite 暂未引入：Phase 0 只有「打开/保存/列出/删除」，JSON 文件足够；等运行历史、索引、并发写入出现真实需求再引入，避免为一个列表查询背上迁移成本。

## 九、前端结构

| 模块 | 职责 |
| --- | --- |
| `App.tsx` | 唯一状态源：nodes/edges/meta/logs/status/report；命令编排；键盘快捷键 |
| `Canvas.tsx` | React Flow 容器：拖拽落点、连线校验、视口变化、运行态只读 |
| `LingXiNode.tsx` | 自定义节点：端口、参数控件、启用开关、运行态样式；参数变更本地更新 |
| `NodeLibrary.tsx` | 左侧分类库；点击添加、HTML5 拖拽、键盘 Enter/Space |
| `Toolbar.tsx` | 名称编辑、新建/打开/保存/校验/运行/终止、状态与计数 |
| `LogPanel.tsx` | 底部可收起日志；级别着色、自动滚动、清空 |
| `ProblemsPanel.tsx` | 校验问题列表（错误/警告、路径、代码） |
| `WorkflowDialog.tsx` | 工作流列表、加载、删除 |
| `InteractionDialog.tsx` | 审批弹窗（批准/拒绝） |

高频交互（拖动节点、缩放、平移、连线预览）全部由 React Flow 在本地完成，只有落点、连线完成、参数变更才写入 React 状态；没有任何逐帧 IPC。

### 浏览器开发模式

`api.ts` 在 `import.meta.env.DEV && !isTauri()` 时启用 `mock.ts`：内置 7 个节点规格、简化校验、模拟运行事件、内存文件列表。用途是让 UI 可以在普通浏览器里开发与自动化测试；`tauri dev` 下 `isTauri()` 为真，走的始终是真实 Rust 后端。mock 不是第二套产品逻辑：生产构建仍会静态打入这段代码，但 `isTauri()` 为真时不会启用；后续可改为动态 import 以减小体积。

## 十、安全边界

- Tauri 只注册 9 个命令，没有 `shell`、`fs`、`http` 插件，WebView 无法直接触达文件系统或进程。
- CSP：`default-src 'self'`，脚本仅同源，`connect-src` 只允许 IPC；没有远程资源。
- 工作流名称校验阻止路径穿越；文件读写被限制在 app data 的 `workflows/` 目录。
- 运行输入完全来自前端提交的 JSON，Rust 侧反序列化失败即拒绝；不会拼接命令、不会执行工作流里的字符串。
- 已知缺口：能力策略当前是 `AllowAllPolicy`；在真实网络/文件节点出现前必须替换，否则「权限层」只是结构预留。

## 十一、可扩展点

| 扩展点 | 现状 | 后续 |
| --- | --- | --- |
| `NodeRegistry::register` | 编译期注册 spec + executor | 动态插件宿主通过同一 API 注册 |
| `CapabilityPolicy` | `AllowAllPolicy` | 按工作流/用户/资源授权 |
| `EventSink` | Tauri emit | 追加 JSONL 运行日志、远程订阅 |
| `InteractionBroker` | oneshot + Tauri 事件 | 多前端、超时、批量决议 |
| `schemaVersion` | `"1.0"` | 迁移器与向后兼容读取 |
| `metadata` | 任意 JSON | 编辑器布局、作者、标签等 |

## 十二、阶段结论

架构上最重要的三个决定：

1. **运行时是库，不是壳的一部分**：`lingxi-runtime` 不依赖 Tauri，桌面壳只是事件与命令的适配器。
2. **前端不拥有执行语义**：校验、拓扑排序、能力检查、取消、终态判定全部在 Rust；前端即使被替换成 CLI，行为也不变。
3. **契约先于实现**：Node Specification v1 与 `RunEvent` 是稳定面，内置节点只是第一批消费者。

这三条决定了 Phase 0 的代码量不大，但后续加节点、加插件、换前端时不需要重写骨架。
