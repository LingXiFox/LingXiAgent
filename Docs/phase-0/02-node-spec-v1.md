# Node Specification v1（Phase 0）

本文件定义 LingXiAgent 3.0 的工作流文档格式与节点执行契约。版本号 `schemaVersion: "1.0"`，实现位于 `crates/lingxi-spec` 与 `crates/lingxi-runtime`。

设计原则：

1. **文档即协议**：工作流是可序列化 JSON，不包含 React Flow 的内部字段（`measured`、`selected`、`dragging` 等）。
2. **规格与实现分离**：`NodeSpec` 描述节点「长什么样、要什么权限」，`NodeExecutor` 描述「怎么执行」；两者在注册表里成对注册。
3. **稳定错误码**：校验与运行错误使用字符串常量，前端不解析自然语言。
4. **前向兼容**：读取时忽略未知字段，便于旧版本打开新文档；保存会丢弃未知字段（已知限制，见 05）。

## 一、工作流文档

```json
{
  "schemaVersion": "1.0",
  "id": "wf-18f2c3a1b2-1",
  "name": "hello",
  "description": "",
  "nodes": [
    {
      "id": "n-1",
      "kind": "core.text_input",
      "label": null,
      "position": { "x": 80, "y": 120 },
      "params": { "text": "hello" },
      "enabled": true
    },
    {
      "id": "n-2",
      "kind": "core.text_uppercase",
      "position": { "x": 420, "y": 120 },
      "params": {},
      "enabled": true
    }
  ],
  "edges": [
    {
      "id": "n-1:text->n-2:text",
      "source": "n-1",
      "sourcePort": "text",
      "target": "n-2",
      "targetPort": "text"
    }
  ],
  "viewport": { "x": 0, "y": 0, "zoom": 1 },
  "metadata": {}
}
```

### 字段

| 字段 | 类型 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- | --- |
| `schemaVersion` | string | 否 | `"1.0"` | 文档格式版本；不支持的主版本直接报错 |
| `id` | string | 否 | 生成 | 文档 ID，仅需安装内唯一；运行 ID 由桌面壳生成 |
| `name` | string | 否 | `""` | 展示名；保存时以文件名为准 |
| `description` | string | 否 | `""` | 备注 |
| `nodes` | Node[] | 否 | `[]` | 节点列表；顺序参与拓扑排序的稳定 tie-break |
| `edges` | Edge[] | 否 | `[]` | 连线列表 |
| `viewport` | object | 否 | 省略 | 上次的画布视口，仅编辑器使用 |
| `metadata` | object | 否 | `{}` | 任意 JSON，运行时忽略 |

### Node

| 字段 | 类型 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- | --- |
| `id` | string | 是 | — | 文档内唯一；建议 `n-<8 hex>` |
| `kind` | string | 是 | — | 节点类型，如 `core.log`；必须已注册 |
| `label` | string \| null | 否 | null | 覆盖显示名；空字符串等同 null |
| `position` | `{x,y}` | 否 | `{0,0}` | 画布坐标（逻辑坐标，不是屏幕坐标） |
| `params` | object | 否 | `{}` | 参数值，键为 `ParamSpec.name` |
| `enabled` | bool | 否 | `true` | false 时节点被跳过，下游随之 skip |

### Edge

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `id` | string | 是 | 唯一；约定 `source:port->target:port` |
| `source` / `target` | string | 是 | 节点 ID |
| `sourcePort` / `targetPort` | string | 否 | 端口名；空字符串会在校验中报未知端口 |

约束：一个输入端口最多一条入边（`edge.input_conflict`）；不允许自环；不允许重复端点（`edge.duplicate`）；端口必须存在且类型兼容。

## 二、节点规格（NodeSpec）

`NodeSpec` 是节点类型的唯一描述源，前端节点库、参数面板、校验器、运行时注册表都读它。

```rust
pub struct NodeSpec {
    pub kind: String,              // 稳定标识，建议 "<namespace>.<name>"
    pub title: String,             // 显示名
    pub description: String,
    pub category: String,          // 左侧节点库分组
    pub inputs: Vec<PortSpec>,
    pub outputs: Vec<PortSpec>,
    pub params: Vec<ParamSpec>,
    pub capabilities: Vec<String>, // 资源权限声明
}

pub struct PortSpec {
    pub name: String,              // 连线句柄名，文档里存这个
    pub label: String,             // 显示名
    pub data_type: DataType,
    pub required: bool,            // 必填输入未连接 → port.unconnected 错误
}

pub struct ParamSpec {
    pub name: String,
    pub label: String,
    pub kind: ParamKind,
    pub default_value: Option<serde_json::Value>,
    pub required: bool,
    pub options: Vec<ParamOption>,  // 仅 Select 使用
    pub help: Option<String>,
}
```

### DataType 与兼容规则

```
Text | Number | Boolean | Json | Any
```

`accepts(target, source)` 的规则只有一条：任一端为 `Any` 即兼容；否则类型必须相等。没有隐式数值/字符串转换——转换应由显式节点完成，避免运行期出现「看起来能连、跑起来才报错」。

### ParamKind 与编辑器控件

| kind | JSON 值 | UI 控件 |
| --- | --- | --- |
| `text` | string | 单行输入 |
| `text_area` | string | 多行文本域 |
| `number` | number | 数字输入 |
| `boolean` | bool | 开关 |
| `select` | string | 下拉，值必须在 `options` 中 |

未提供的参数由运行时回退到 `defaultValue`；`required` 且无默认值的参数缺失 → `param.missing`。

### 能力声明

能力是字符串常量，当前定义：

| 常量 | 值 | 含义 |
| --- | --- | --- |
| `capabilities::INTERACTION` | `interaction` | 需要向用户发起交互 |
| `NETWORK` | `network` | 需要出站网络 |
| `FILESYSTEM` | `filesystem` | 需要读写文件 |
| `PROCESS` | `process` | 需要启动子进程 |

引擎在执行前把每个能力交给 `CapabilityPolicy` 授权；任一拒绝即 `node.failed`，executor 不会运行。桌面壳 Phase 0 注入 `AllowAllPolicy`，但检查点已经在正确的位置。

## 三、执行接口

```rust
#[async_trait]
pub trait NodeExecutor: Send + Sync {
    async fn execute(&self, ctx: &NodeContext<'_>) -> Result<NodeOutput, NodeError>;
}

pub struct NodeOutput {
    outputs: BTreeMap<String, serde_json::Value>,
}

impl NodeOutput {
    pub fn new() -> Self;
    pub fn with(self, port: impl Into<String>, value: Value) -> Self;
}
```

`NodeContext` 暴露给节点的能力：

| 方法 | 用途 |
| --- | --- |
| `param(name) -> Option<&Value>` | 原始参数（含默认值回退） |
| `string_param / number_param / bool_param` | 类型化读取，类型不符报 `node.invalid_param` |
| `input(name) -> Option<&Value>` | 上游输出 |
| `text_input / number_input` | 类型化输入，缺失报 `node.missing_input` |
| `log(level, message)` | 写入本次运行日志（`RunEvent::Log`） |
| `check_cancelled()` | 协作式取消检查 |
| `request_interaction(prompt, options)` | 发起交互并等待决议 |

节点**不能**直接访问文件系统、网络、进程或 Tauri API；它只拿到上下文。需要这些资源时，能力声明 + 未来的资源句柄才是入口。

### 注册一个节点

```rust
use std::sync::Arc;
use lingxi_runtime::{NodeRegistry, NodeExecutor, NodeOutput, NodeError, NodeContext};
use lingxi_spec::{NodeSpec, PortSpec, DataType};

let mut registry = NodeRegistry::builtin();
registry.register(
    NodeSpec::new("example.echo", "Echo", "Example")
        .description("Emits its input unchanged.")
        .input(PortSpec::new("value", "Value", DataType::Any).required())
        .output(PortSpec::new("value", "Value", DataType::Any)),
    Arc::new(Echo),
)?;
```

注册表拒绝重复 `kind`；引擎不认识任何具体节点名，内置节点也走同一入口。这就是未来插件注册的接缝。

## 四、内置节点目录

| kind | 标题 | 分类 | 输入 | 输出 | 参数 | 能力 |
| --- | --- | --- | --- | --- | --- | --- |
| `core.text_input` | Text Input | Input | — | `text: Text` | `text` (text_area) | — |
| `core.number_input` | Number Input | Input | — | `number: Number` | `value` (number) | — |
| `core.text_uppercase` | Uppercase | Text | `text: Text`* | `text: Text` | — | — |
| `core.text_concat` | Concat | Text | `a: Text`*, `b: Text`* | `text: Text` | `separator` (text) | — |
| `core.number_add` | Add | Number | `a: Number`*, `b: Number`* | `number: Number` | — | — |
| `core.log` | Log | Output | `value: Any`* | — | `prefix` (text) | — |
| `core.approval` | Approval Gate | Control | `payload: Any` | `payload: Any` | `prompt` (text_area) | `interaction` |

`*` = required。这些节点只用于验证骨架，不构成产品能力。

## 五、校验规则与错误码

`validate(workflow, resolver)` 是纯函数，不执行任何节点。报告结构：

```json
{
  "ok": false,
  "schemaVersion": "1.0",
  "nodeCount": 2,
  "edgeCount": 1,
  "errors": 1,
  "warnings": 0,
  "issues": [
    {
      "code": "port.unconnected",
      "severity": "error",
      "path": "nodes[1].inputs.text",
      "message": "required input \"text\" is not connected"
    }
  ]
}
```

### 错误码表

| code | 级别 | 触发条件 |
| --- | --- | --- |
| `schema.unsupported_version` | error | `schemaVersion` 主版本不是 1 |
| `workflow.empty` | warning | 没有节点（空白文档仍可保存） |
| `node.duplicate_id` | error | 节点 ID 重复 |
| `node.empty_id` | error | 节点 ID 为空 |
| `node.unknown_kind` | error | 类型未注册 |
| `node.invalid_position` | error | 坐标非有限数 |
| `param.missing` | error | 必填参数无值且无默认值 |
| `param.type_mismatch` | error | 参数 JSON 类型与 ParamKind 不符 |
| `param.invalid_option` | error | Select 值不在选项内 |
| `param.unknown` | warning | 文档里有规格未声明的参数 |
| `edge.duplicate_id` | error | 连线 ID 重复 |
| `edge.self_loop` | error | 自连 |
| `edge.dangling_source` / `edge.dangling_target` | error | 端点不存在 |
| `edge.unknown_port` | error | 端口名不在规格里 |
| `edge.type_mismatch` | error | 端口类型不兼容 |
| `edge.input_conflict` | error | 同一输入端口多条入边 |
| `edge.duplicate` | error | 同一组端点重复连接 |
| `port.unconnected` | error | 必填输入未连接 |
| `graph.cycle` | error | 存在环（Kahn 无法覆盖全部节点） |

运行期错误码（`NodeError.code`）：`capability.denied`、`node.invalid_param`、`node.invalid_input`、`node.missing_input`、`node.interaction_denied`、`node.interaction_timeout`、`node.cancelled`、`node.executor_failed`。

## 六、版本化与兼容

- `schemaVersion` 采用 `major.minor`。Phase 0 只接受 `1.x`；主版本不同直接拒绝。
- 在 1.x 内新增**可选**字段、新的 `ParamKind`、新的能力常量属于兼容变更；前端与运行时都必须容忍未知字段/未知参数（未知参数记 warning，不阻断保存）。
- 删除字段、改变既有字段语义、改变类型匹配规则属于破坏性变更，必须升到 2.0。
- 节点 `kind` 一经发布不改名；废弃用新 kind + 迁移说明。
- 运行事件（`RunEvent`）与文档格式独立版本化；新增事件类型时前端必须忽略未知 `type`（当前实现是 switch 穷举，未知类型会被忽略）。

## 七、边界

Node Specification v1 只覆盖「静态图 + 单次执行」。以下内容**不在** v1 内：

- 条件分支、循环、子工作流；
- 流式端口（token 流）；
- 每节点超时/重试/并发度；
- 端口多值（一个输出连多个输入是允许的，但一个输入只能一条边）；
- 跨运行持久状态；
- 动态 UI schema（当前参数控件由 ParamKind 固定映射）。

这些都需要在 2.0 文档格式里显式设计，不能靠 `metadata` 偷偷扩展。
