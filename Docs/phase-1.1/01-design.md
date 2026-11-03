# Phase 1.1 · 控制流与自定义循环设计

状态：已实现。Rust 自动化测试与 macOS 实机 Tauri 验收通过；Windows/Linux 仅通过 CI 编译与单元测试，运行行为未验收。
范围：条件分支、受控循环、重复激活调度、静态循环校验、最小 UI 适配。

## 一、目标与非目标

目标：让用户仅通过节点组合出可执行、可退出、可取消的循环；Runtime 不知道循环是否属于 Agent。

非目标：LLM Provider、MCP、Skills、动态插件、并行调度、持久化运行状态。

## 二、兼容策略

协议仍然 `schemaVersion = "1.0"`。全部新增字段都是可选字段，旧文档加载后取默认值：

| 结构 | 新字段 | 默认 | 旧文档行为 |
| --- | --- | --- | --- |
| `Edge` | `kind: "data" \| "control"` | `"data"` | 与 Phase 0 完全一致 |
| `NodeSpec` | `control: "normal" \| "branch" \| "loop_gate"` | `"normal"` | 普通节点 |
| `PortSpec` | `control: bool` | `false` | 普通端口 |

不重命名、不删除既有字段；Edge ID 格式不变。含控制边或控制节点的文档走新调度器，其余文档继续走原 Kahn 路径，保证零回归。

## 三、节点契约

新增 4 个内置节点：

### core.boolean_input

- 参数：`value: boolean = false`
- 输出：`boolean`（Boolean）
- 用途：给 Condition 提供显式布尔源。

### core.condition

- 控制角色：`branch`
- 输入：`condition`（Boolean，必填）、`payload`（Any，可选）
- 输出：`true`（Any，control）、`false`（Any，control）
- 语义：只向被选中的输出端口发 token；另一条输出边标记为 inactive，不执行、不报错。

### core.loop_gate

- 控制角色：`loop_gate`
- 输入：`start`、`next`、`stop`（Any，均为 control）
- 输出：`continue`、`exit`（Any，均为 control）
- 参数：`maxIterations`（整数 1..=1_000_000）、`timeoutMs`（整数 1..=86_400_000），两者都必须显式写入工作流；UI 新建 Loop Gate 时预填 10 / 60000，但 Runtime 与校验器不提供隐式默认值。
- 语义：由 Engine 驱动，不走普通 executor。
  - `start`：第 1 次迭代，输出 `continue`。
  - `next`：迭代 +1，预算内输出 `continue`，否则失败 `loop.budget_exhausted`。
  - `stop`：输出 `exit`，不增加迭代。
  - 超时：`loop.timeout`。
- 端口类型是 Any，便于携带循环状态；Gate 不解释状态，只传递。

### core.counter

- 输入：`value`（Number，可选）
- 输出：`number`（Number）、`done`（Boolean）
- 参数：`start = 0`、`step = 1`、`threshold = 3`
- 语义：`next = (value ?? start) + step`；`done = next >= threshold`。用于演示和测试，不参与引擎调度。

## 四、执行模型

### 4.1 两条路径

```
validate()
  ├─ 无控制边且无控制节点 → Kahn DAG 执行器（Phase 0，原样保留）
  └─ 否则 → Token/Activation 调度器
```

控制工作流仍顺序执行，一次一个节点；并行留待后续。

### 4.2 Token 与激活

- 每条边最多持有一个 `Value` token；node 完成后按输出端口向所有出边写 token。
- 节点就绪：至少一个 control 输入有 token；所有必需 data 输入有 token；所有 data 入边已 token 或 inactive。
- 节点执行时消费全部入边 token，避免旧值残留。
- 节点可被多次激活；每次 `activation` 从 1 递增，节点事件携带 `activation` 与 `iteration`。
- 无入边节点是 source，本次运行只激活一次。
- 未被选中的分支：缺失输出端口的所有出边标记 inactive，并向下游传播；下游若因此缺少必需输入则 `node.skipped`，不导致运行失败。
- 节点失败/禁用：出边全部 inactive；已失败节点不会再次激活；运行终态仍只发一次。
- 取消：每个调度循环检查 `RunControl`，executor 外层继续用 `tokio::select!` 抢占。

### 4.3 Loop Gate 状态机

```
Idle --start--> Iteration 1 --continue--> body
body --next--> Iteration n+1 --continue--> body
body --stop--> Exit
Iteration > maxIterations --> Failed(loop.budget_exhausted)
now > startedAt + timeout --> Failed(loop.timeout)
```

- 状态保存在 Engine 的 `LoopRuntime`，不放进 NodeExecutor，也不写进工作流 JSON。
- 每次 continue 把 payload 原样传给 `continue` 输出；调用方通过数据边把最新状态送回 body。
- 超时从 `start` 开始计时；active loop 期间每个节点执行都受剩余时间约束。
- 退出时记录 `loop exited after N iteration(s)`；预算失败记录明确错误。

### 4.4 事件扩展

节点事件新增：

```json
{ "activation": 2, "iteration": 2 }
```

`iteration` 仅循环相关节点出现；DAG 事件省略该字段。事件类型与字段名保持不变。

## 五、静态校验

在 `lingxi-spec` 内实现迭代版 Kosaraju SCC（不引入新依赖）：

1. 对每个大小 > 1 或含自环的 SCC：
   - 不含 `loop_gate` → 保留 `graph.cycle`。
   - 含多个 `loop_gate` → `loop.multiple_gates`。
   - 移除 gate（及其边）后 SCC 内仍有环 → `loop.uncontrolled_cycle`（存在绕过 Loop Gate 的闭合路径）。
   - gate 没有 `exit` 出边指向 SCC 外 → `loop.no_exit_path`。
   - gate 缺少 `start` 或 `next` 入边 → `loop.missing_trigger`。
2. 任何 Loop Gate（无论是否成环）预算参数缺失/非整数/越界 → `loop.invalid_budget`。
3. branch/gate 的控制输出边必须是 `kind: "control"` → `edge.control_required`。
4. 普通无环图行为不变；自环、悬空、类型、端口、必填输入规则保持。

**不假设退出条件必然满足**：静态只证明“循环受控且预算存在”，终止由运行期预算强制。

## 六、UI

保持现有四区布局，不新增右侧栏/仪表盘：

- 节点库自动出现 4 个新节点。
- Condition 两个输出 handle；Loop Gate 三个输入、两个输出；控制边用虚线 + 冷色描边。
- 节点头部显示 `迭代 N` / `激活 N` 徽标；日志显示 loop iteration / exit / budget exhausted。
- 工具栏「示例」加载 Counter → Condition → Loop Gate → Log 图并可直接运行。
- 校验问题仍由底部 ProblemsPanel 展示，新增 code 直接显示路径。

演示拓扑：

```
number_input(0) ──start──> loop_gate
loop_gate.continue ──> counter.value
counter.number ──> condition.payload
counter.done ──> condition.condition
condition.false ──> loop_gate.next
condition.true  ──> loop_gate.stop
loop_gate.exit ──> log.value
```

阈值 3、maxIterations 10：计数 1→2→3，第三次 `done=true`，走 stop/exit，日志输出 3。

## 七、测试计划

Rust：

1. Phase 0 的 21 个测试全部保留且通过；新增 15 个控制流测试，总计 36 个。
2. Condition true 只执行 true 分支。
3. Condition false 只执行 false 分支。
4. 循环 3 次后 exit，Counter 输出 1/2/3。
5. 无 exit 路径的循环被拒绝。
6. 移除 gate 后仍有环被拒绝。
7. 预算耗尽 → `loop.budget_exhausted`，运行失败。
8. 循环中取消 → cancelled。
9. 循环 body 节点失败 → 运行失败且只发一次 RunFinished。
10. 每次迭代读取新值，不复用旧输出；gate 超时 → `loop.timeout`。

UI：真实 Tauri 窗口加载演示、运行、观察迭代徽标与日志、终止。

CI：macOS / Ubuntu / Windows 全绿。

## 八、实现顺序

1. spec：Edge.kind、NodeSpec.control、PortSpec.control、SCC 校验、4 个节点契约。
2. runtime：节点执行 helper、控制调度器、LoopRuntime、事件字段。
3. 测试：校验 + 引擎 10 项。
4. 前端：类型、控制边、节点徽标、演示按钮。
5. 文档、截图、真实 Tauri 验证、CI、提交。

## 九、实现结果

- spec：`Edge.kind`、`NodeSpec.control`、`PortSpec.control` 已落地；`crates/lingxi-spec/src/validation.rs` 使用迭代版 Kosaraju SCC，Phase 0 的无环校验路径保持原行为。
- runtime：`crates/lingxi-runtime/src/control_flow.rs` 实现控制调度器与 Loop Gate 状态机；普通 DAG 仍走原有 Kahn 调度器。具体差异见其模块文档。
- 内置节点：`core.boolean_input`、`core.condition`、`core.loop_gate`、`core.counter`，内置节点总数为 11。
- 校验：新增 6 个稳定 code（`loop.multiple_gates`、`loop.uncontrolled_cycle`、`loop.no_exit_path`、`loop.missing_trigger`、`loop.invalid_budget`、`edge.control_required`），总数 26。
- 前端：控制边虚线样式、Condition/Loop Gate handle、迭代徽标、示例工作流及自定义确认弹窗；未新增右栏或仪表盘。
- 验收证据、测试映射、平台矩阵与已知限制见 `Docs/phase-1.1/02-testing-and-acceptance.md`。
