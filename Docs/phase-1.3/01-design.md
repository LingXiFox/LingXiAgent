# Phase 1.3 · Composite Node / Subgraph 设计

状态：设计已冻结，进入实现。本文只描述契约与语义；未被测试覆盖的能力一律按“未实现”处理。
范围：组合节点的文档协议、静态校验、Rust 分层执行、前端展开/解组/模板、事件关联与验收测试。
非目标：云端模板市场、并发执行、嵌套循环、新 Agent Loop、真实 LLM/MCP/Skills、权限模型扩展。

## 一、目标

用户框选多个普通节点后，可以：

1. 组合为一个 `core.composite` 节点；
2. 自动把跨边界连接转换为子图输入/输出端口；
3. 双击进入子图，继续编辑内部节点与连线；
4. 解组，恢复基础节点和原来的外部连接；
5. 复制组合节点，或保存为本地模板并从节点库拖入；
6. 由 Rust Runtime 真实执行，事件、取消、失败、循环预算与现有运行完全一致。

组合是工作流组合能力，不是特殊 Agent。Runtime 不因为节点是组合节点而启动任何固定循环或模型调用。

## 二、兼容性与版本

- 文档版本从 `1.0` 升为 `1.1`。`1.0` 仍可加载；缺失的新字段按空值处理。
- 唯一新增字段：
  - `Workflow.subgraphs`: `BTreeMap<String, Subgraph>`，默认空；
  - `WorkflowNode.subgraphId`: `Option<String>`，默认空。
- `1.0 -> 1.1` 不重写节点、边或参数；保存时写 `1.1`。校验器接受 `1.0` 与 `1.1`，其他版本报 `schema.unsupported_version`。
- 不通过“把新字段塞进 metadata”伪装兼容；协议字段直接出现在 JSON 中，旧前端忽略未知字段也能加载普通工作流。

## 三、Subgraph 协议

```rust
pub struct Subgraph {
    pub id: String,
    pub version: u32,                 // 当前只支持 1
    pub name: String,
    pub description: Option<String>,
    pub workflow: Workflow,           // 内部节点与内部连线
    pub inputs: Vec<SubgraphInput>,
    pub outputs: Vec<SubgraphOutput>,
}

pub struct SubgraphInput {
    pub port: PortSpec,               // 组合节点对外的输入端口
    pub targets: Vec<PortBinding>,    // 一个外部输入可映射到多个内部输入
}

pub struct SubgraphOutput {
    pub port: PortSpec,               // 组合节点对外的输出端口
    pub source: PortBinding,          // 一个内部输出映射到一个外部端口
}

pub struct PortBinding {
    pub node_id: String,              // 内部节点 ID，不是根层 ID
    pub port: String,
    pub edge_id: Option<String>,      // 原外部边 ID，仅用于尽量保留身份
}
```

`WorkflowNode { kind: "core.composite", subgraphId: Some("sg-...") }`。`core.composite` 不注册普通执行器，由引擎识别。

### 3.1 ID 命名空间

- `Subgraph.id` 在整个工作流文档内全局唯一。
- 内部节点 ID 只在其所属的 `Subgraph.workflow` 内唯一；不同子图可以重复。
- 运行期身份是 `(subgraph_id, node_id)`，事件再由 `scope` 栈标识实例链。
- 根层节点 ID 与内部节点 ID 不共享命名空间；因此组合/解组只在目标层内解决冲突。
- 子图定义统一存放在根 `Workflow.subgraphs`。内部 `Workflow.subgraphs` 必须为空，禁止局部定义造成作用域歧义。

### 3.2 嵌套与递归

- 组合节点内部可以再包含组合节点；被引用定义仍查根层 `subgraphs`。
- 从定义 `A` 的内部组合节点沿 `subgraphId` 做 DFS；回到已访问定义即 `subgraph.recursive_reference`。
- 未知引用 `subgraph.unknown_reference`；重复/空 ID `subgraph.duplicate_id`；非法版本 `subgraph.unsupported_version`。
- 内部 `Workflow.subgraphs` 非空报 `subgraph.nested_definitions`。

### 3.3 端口映射约束

- 输入/输出端口名在各自方向内唯一。
- 绑定的内部节点和端口必须存在；`port.control` 与内部端口 `control` 必须一致。
- 数据方向：内部输入端口必须接受外部输入端口类型；外部输出端口必须接受内部输出端口类型。
- 一个输入端口可以映射多个内部输入；一个输出端口只能有一个内部来源。
- 输入绑定的内部目标端口不得已有内部入边；否则外部输入与内部数据无法定义合并顺序，直接拒绝。
- 同一内部输入端口不得被多个外部输入绑定。
- 外部必填输入未连接仍由现有 `port.unconnected` 检查。

## 四、静态校验

新增稳定错误码：

| code | 含义 |
| --- | --- |
| `subgraph.duplicate_id` | 定义 ID 为空、重复或 map key 与 `id` 不一致 |
| `subgraph.unknown_reference` | 组合节点引用了不存在的定义 |
| `subgraph.invalid_port` | 端口重名、端口类型/控制属性不匹配 |
| `subgraph.invalid_binding` | 绑定节点/端口不存在、重复绑定、目标已有内部入边 |
| `subgraph.unsupported_version` | 定义版本不是 1 |
| `subgraph.recursive_reference` | 定义递归引用自身 |
| `subgraph.nested_definitions` | 内部 Workflow 自带 subgraphs |
| `subgraph.nested_loop_unsupported` | 外层循环经过一个内部含 Loop Gate 的组合节点 |

校验顺序：

1. 根文档 schema、节点 ID、参数、普通边；
2. 所有子图定义的结构、内部 Workflow（递归使用同一套节点/边规则）；
3. 组合节点动态端口：从定义生成临时 `NodeSpec`，参与边类型、控制边、必填输入检查；
4. 端口映射、递归、嵌套循环规则。

静态循环规则保持 Phase 1.1 不变；此外，若外层 SCC 包含组合节点，且该定义传递闭包内含 `LoopGate`，报 `subgraph.nested_loop_unsupported`。这是本阶段明确的“拒绝而不是猜测”边界：内层 Gate 自己的迭代/预算尚未与外层 Gate 合并语义，不能声称支持。完全位于组合内部、外层无循环的 Loop Gate 合法。

## 五、Runtime 分层执行

采用“分层执行”，不做全局内联展开。理由：内联会改变 Loop Gate 的 SCC、激活次数与事件归属；分层执行能为每次组合激活创建独立 Scheduler，天然隔离循环状态。

### 5.1 执行路径

1. 顶层 `Engine::execute` 发出 `run.started`，校验根文档；
2. 选择 DAG 或 Token/Activation Scheduler（与 Phase 1.1 相同）；
3. 遇到 `kind == "core.composite"`：
   - 从根 `subgraphs` 解析定义；
   - 根据外部输入构造内部初始值：`(inner_node, inner_port) -> Value`；
   - 压入 `ScopeFrame { instance_id, subgraph_id, label }`；
   - 用同一个 `RunControl`、`CapabilityPolicy`、`InteractionBroker`、`EventEmitter` 执行内部 Workflow；
   - 内部执行不发出 `run.started` / `run.finished`，不创建第二个 run 记录，不重置 seq；
   - 内部完成后按 `SubgraphOutput.source` 收集值，映射为组合节点的 `NodeOutput`；
   - 弹出 scope。
4. 内部失败/取消转换为组合节点的失败/取消；外层只产生一个最终 `run.finished`。

### 5.2 组合输入/输出

- 输入值注入内部目标节点的端口；目标节点因此可在内部作为根节点启动。
- 输出只从内部运行结束时的节点输出快照读取；分支未激活则对应端口无值，外部的控制边按现有语义失活。
- 组合节点没有自身能力声明；内部每个节点仍逐个经过 `CapabilityPolicy`，不存在绕过。
- 组合节点自身不执行参数逻辑，只有内部节点参数生效。

### 5.3 循环、取消与失败

- 每次组合激活创建新的内部 Scheduler；内部 Loop Gate 的 iteration/deadline 不跨激活、不跨实例共享。
- 内部取消检查使用同一 `RunControl`；取消会中断内部当前节点，组合节点发 `node.cancelled`，运行只结束一次。
- 内部节点失败会发内部 `node.failed`，组合节点再发外层 `node.failed`；外层调度器按既有规则失活下游。
- 外层循环经过含 Loop Gate 的组合节点在静态阶段拒绝；不依赖运行期补救。
- 本阶段仍为单任务顺序执行，不引入并发。

### 5.4 事件关联

所有 `node.*`、`log`、`interaction.*` 事件新增可选 `scope`：

```rust
pub struct ScopeFrame {
    pub instance_id: String,   // 外层组合节点 ID
    pub subgraph_id: String,
    pub label: String,
}
```

- 顶层事件 `scope = []`，序列化时省略。
- 内部事件由 `EventEmitter` 自动注入当前栈，节点 ID 保持内部 ID。
- 嵌套组合产生多帧，顺序从外到内。
- 事件 seq 仍由同一个 `EventEmitter` 分配；SQLite 行结构与 `last_seq` 不变，事件 JSON 原样保存 `scope`。
- 前端按 `scope` 与当前导航路径匹配更新节点状态；日志显示内部事件时可加组合标签。

## 六、前端交互

保持四区布局，不新增右侧属性栏或聊天区。

- 工具栏新增：`组合`、`解组`、`复制`、`存为模板`，均依据当前选择启用。
- 画布支持多选；组合节点折叠渲染：名称、输入/输出端口、内部节点数、运行状态。
- 双击组合节点进入内部画布；顶部面包屑显示 `顶层 / 组合名 / ...`，可逐级返回。
- 当前层节点/连线是编辑状态；保存、校验、运行前先 `assembleRoot()` 把当前层写回根文档。
- 组合/解组、模板实例化等结构操作放在纯函数模块，便于 Node 测试。
- 内部运行状态按 scope 路径缓存；切换层级时重新套用，避免状态串层。
- 模板从左侧节点库拖入；每个实例复制整棵定义依赖并重新分配 ID，实例之间不共享定义或运行状态。模板更新只影响之后拖入的实例，不修改已有工作流。

### 6.1 组合算法

1. 选中节点集合 S，内部边 = 两端都在 S。
2. 边界入边按 `(外部 source, sourcePort, kind)` 分组，每组生成一个组合输入端口，记录所有内部目标绑定。
3. 边界出边按 `(内部 source, sourcePort, kind)` 分组，每组生成一个组合输出端口。
4. 删除 S 及所有关联边；把内部节点/边放入定义，位置归一化；在包围盒中心放置组合节点。
5. 外部源连接到组合输入；组合输出连接到原外部目标。

### 6.2 解组算法

1. 复制被解组组合的定义，避免影响其他引用。
2. 把内部节点按组合节点位置偏移放回当前层；仅在同层 ID 冲突时重映射。
3. 恢复内部边；按输入/输出绑定和当前外部边重建跨边界边。
4. 移除组合节点；只有没有任何层再引用该定义时才删除定义。
5. 嵌套组合作为普通组合节点恢复，不递归展开。

### 6.3 模板存储

桌面壳新增本地模板存储（app data 下的 JSON 文件），命令：

- `template_list() -> TemplateSummary[]`
- `template_load(id) -> TemplateBundle`
- `template_save(name, bundle) -> TemplateSummary`
- `template_delete(id) -> bool`

`TemplateBundle { rootId, subgraphs }` 保存组合定义及其依赖闭包。模板文件与工作流文件分离；加载后前端重新分配全部定义 ID。模板注册不改变工作流 JSON 格式。

## 七、测试与验收

Rust 自动化至少覆盖：

1. 普通 DAG 封装前后运行结果一致；
2. 多输入/多输出映射；
3. 外部边在组合/解组后正确（前端纯函数测试 + 真实文档校验）；
4. 内部节点失败向外传播；
5. 取消中断内部执行；
6. 同一模板多个实例互不干扰；
7. 子图 ID 唯一/命名空间；
8. 递归引用被拒绝；
9. 保存、重载后正常执行；
10. 含 Condition 与 Loop Gate 的子图正常执行；
11. 事件正确关联内外节点（scope 与 seq）；
12. SQLite 历史保留完整事件序号（Tauri 实机验收）。

另有：外层循环经过含 Gate 的组合节点被拒绝；组合输入目标已有内部入边被拒绝；未知引用/非法端口映射被拒绝；旧 `schemaVersion = "1.0"` 文档仍可校验和加载。

演示：把 Phase 1.1 的 Counter Loop 封装为顶层唯一组合节点；内部保留 seed → Loop Gate → Counter → Condition 闭环和内部 Log。运行后日志仍出现 `count: 3.0`，顶层只显示组合节点及其运行状态。

## 八、已知边界

- 不支持外层循环包含内层 Loop Gate 的组合；静态拒绝。
- 组合输入只能绑定内部根输入（该端口无内部入边）；复杂的“中途注入”不在此阶段。
- 不实现并发、断点续跑、跨运行状态恢复。
- 模板是本地文件，不做版本迁移、远程分发或签名。
- Windows/Linux 只保证 CI 编译与单元测试；运行行为需实机验收。
