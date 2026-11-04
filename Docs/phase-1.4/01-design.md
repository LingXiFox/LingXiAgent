# Phase 1.4 设计：首个完整文本 Agent 闭环

状态：设计冻结，进入实现（2026-11-04）
基线：`rewrite/3.0` @ 68c6657

## 1. 范围与不变量

本轮交付一个可由节点组合、由 Rust Runtime 真实执行的文本 Agent：Provider、Model、Prompt、Context、ToolSet、Tool Dispatcher、MCP、Skills，以及 CLI 自动验收体系。

保持不变：

- Engine 没有固定 Agent Loop。ReAct 循环由 Agent 组合模板中的 Loop Gate、Condition、Context 节点表达。
- 工作流 JSON 可序列化，不包含前端组件、连接对象或凭据。
- 前端不执行节点逻辑；画布高频交互仍在本地完成。
- `crates/lingxi-spec` 不依赖 runtime/Tauri；runtime 不依赖 Tauri/React/macOS API。
- 普通节点执行前经过 CapabilityPolicy；网络与工具目标在执行期再次向用户授权，Composite 内部走同一个运行作用域。
- 不修改许可证，不执行 `cargo clean`，不删除或弱化既有测试。

## 2. 运行期分层

```text
Tauri commands
  ├─ Settings / credentials (keyring)
  ├─ Workflow / template / run history
  └─ run_workflow
        ↓
Engine (validation + scheduling)
        ↓
RunServices (one per run)
  ├─ credentials: CredentialResolver
  ├─ providers: ProviderFactory
  ├─ permissions: PermissionManager (interaction broker)
  ├─ contexts: ContextStore
  ├─ toolsets: ToolSetRegistry
  ├─ mcp: McpManager
  └─ budgets: model calls / tokens
        ↓
Node executors (provider/model/prompt/context/toolset/dispatch/mcp/skill)
```

`RunServices` 由 Engine 每次 `execute` 创建，运行结束显式关闭 MCP 子进程。不同运行、不同 Composite 实例之间不共享 Context、工具句柄或预算。

## 3. 控制流与数据流语义

Phase 1.3 的 data edge 是一次性 token，无法支持常量配置反复喂给循环中的 Model。本轮把边语义明确拆开：

- `control` 边：一次性事件 token。节点消费后清除；某次激活未产生该输出时，边进入 inactive，避免上一轮 token 残留。
- `data` 边：电平保持（latched）。上游输出写入后保留值并递增版本号；下游在下次激活时读取最新值。节点的必需 data 输入缺失时不得执行。
- 触发规则：
  - 有 control 入边的节点只由 control token 触发，data 仅作为最新参数。
  - 没有 control 入边、只有 data 入边的节点由“必需 data 版本变化”触发。Condition 因此可在每轮 Model 输出变化时重新判断。
- 节点每次激活前记录已见 data 版本；未变化的 latched 值不会造成重复执行。
- 上游执行但未产生某 data 输出时，对应边清空并标记 inactive，禁止下游读到旧输出。
- DAG 快速路径保持 Kahn 行为；控制流路径才使用上述规则。既有 JSON 与 DAG 测试必须全部通过。

Loop Gate、Condition、Composite 的预算/取消/失败传播沿用 Phase 1.1–1.3；Agent 模板不引入新的硬编码循环。

## 4. 新节点契约

所有节点使用 Node Specification v1。端口类型为 `text|number|boolean|json|any`，control 端口无数据值。

| kind | 控制 | 数据输入 | 数据输出 | 关键参数 |
| --- | --- | --- | --- | --- |
| `core.provider` | run → done | — | provider(json) | providerId, baseUrl, credentialRef, organization, timeoutMs |
| `core.model` | run | provider, context, contextUpdate?, tools | text, toolCalls, hasToolCalls, messages, usage | model, temperature, maxTokens, reasoningEffort, stream, timeoutMs, maxCalls, maxTotalTokens |
| `core.prompt` | run → done | input(any) | messages(json), system(text), user(text) | system, user, variables(json) |
| `core.context` | run → done | messages, toolResults, context? | context, messages, count | operation(init/update/snapshot), maxMessages, maxTokens, overflow(trim_oldest/error) |
| `core.tool_set` | run → done | mcp(json)? | toolset, definitions | builtins |
| `core.tool_dispatch` | run → done | toolset, toolCalls | results, count | timeoutMs |
| `core.mcp_server` | run → done | — | tools, server | transport(stdio/http), command, args, url, credentialRef, namespace, timeoutMs |
| `core.skill` | run → done | — | instructions, metadata | skill, resources |
| `core.log` | run | value | text | prefix |

隐藏运行对象（Context 内容、ToolSet 执行器、MCP 连接）只以不透明 handle 在 data 边传递，不写入工作流 JSON。Provider 节点只保存 `credentialRef`，不保存密钥。

## 5. Provider / Model

Provider 适配器是独立 Rust trait：

```rust
#[async_trait]
pub trait ChatProvider: Send + Sync {
    async fn complete(&self, request: ChatRequest, delta: DeltaSink, cancel: Arc<RunControl>)
        -> Result<ChatResponse, RuntimeError>;
}
```

默认实现为 OpenAI-compatible `POST {baseUrl}/chat/completions`，支持自定义 Base URL、模型 ID、SSE streaming、tool_calls、usage、reasoning_effort（仅当配置非空时发送）。HTTP 状态映射稳定错误码：401/403 → `provider.auth`，429 → `provider.rate_limited`，5xx → `provider.http`，超时 → `provider.timeout`，连接失败 → `provider.network`，非法 JSON/流 → `provider.invalid_response`。

模型调用预算在 RunServices 内按 Model 节点累计：超过 `maxCalls` 返回 `budget.calls_exhausted`，累计 token 超过 `maxTotalTokens` 返回 `budget.tokens_exhausted`。取消时 drop 请求 future，并返回 `node.cancelled`。

Streaming：Provider 产生文本增量，Model 执行器最多每 250ms 发一条 `model.delta` 事件；`node.finished` 只保存最终完整文本。避免逐 token 写 SQLite。

## 6. Context

Context 消息结构包含 role（system/user/assistant/tool）、content、tool_calls、tool_call_id、name。运行期 `ContextStore` 以 `(run_id, handle)` 隔离。

- `init`：从 Prompt 的 messages 创建上下文，返回 handle。
- `update`：追加 assistant 消息与 tool 结果；工具结果按 ToolCall ID 回填。
- `snapshot`：输出当前消息，不修改。
- 超限策略：`trim_oldest` 保留 system 消息、丢弃最旧消息并记录 warning；`error` 返回 `context.overflow`。token 以字符数/4 估算，属于预算控制而非精确计费。

## 7. Tool / 权限 / 凭据

Tool 定义：唯一名称、描述、JSON Schema、执行器、capability、超时、错误码。内置三个安全工具：

- `calculator`：仅数字与 `+ - * / ( )`，不使用 eval/Shell。
- `text_transform`：upper/lower/trim/length/replace。
- `json_query`：点路径读取，只读。

Dispatcher 校验参数 JSON（必填、类型、未知字段），逐个执行并保证 ToolCall ID 对应；单个工具失败生成结构化错误结果，不使调度器失去控制；支持多 ToolCall、超时、取消。工具结果写回 Context，而不是直接拼 prompt。

权限：

- Engine 的 `DeclaredCapabilityPolicy` 只允许已声明的基础 capability（compute/interaction/network）；未知 capability 返回 `capability.unsupported`。
- 网络、MCP 进程/URL、工具执行在 RunServices 的 `PermissionManager` 中按目标请求用户授权，结果按 run+target 缓存。
- 拒绝返回 `capability.denied`，取消返回 `node.cancelled`。Composite 内部使用同一 RunServices，无法绕过。
- 审批复用 InteractionBroker 与现有 UI 审批对话框。

凭据：`CredentialResolver` 支持 `env:NAME` 与 `keyring:NAME`。桌面设置只写入操作系统 keyring；读取只返回“已配置/未配置”和来源，不回传明文。keyring 不可用时写入失败并显示错误，绝不降级明文。日志/事件经过既有 redact，并新增对 Authorization、api key、token 字段的覆盖测试。

## 8. MCP / Skills

MCP Client 实现 JSON-RPC 2.0：

- stdio：换行分隔消息，spawn 前授权 command+args；initialize → notifications/initialized → tools/list → tools/call；超时、进程退出、取消均返回稳定错误。
- Streamable HTTP：POST JSON-RPC，Accept application/json + text/event-stream，保存 Mcp-Session-Id；同样完成 initialize/tools/list/tools/call。
- 工具名统一为 `mcp:<namespace>:<tool>`，命名空间冲突拒绝；所有 MCP 工具默认不可信，进入 ToolSet 后仍经过 CapabilityPolicy 与目标审批。
- 提供本地测试 MCP Server（Rust 示例），通过真实 stdio 协议完成端到端调用。
- OAuth 远程服务本轮不宣称支持；只支持无认证或静态 Bearer（通过 credentialRef）。

Skills：

- 发现数据目录 `skills/` 与 `LINGXI_SKILLS_DIR`，解析 `SKILL.md` 的 front matter（name/description/metadata）和正文。
- 按需加载正文与 resources；内容作为模型上下文，不执行 Skill 内脚本。
- 示例 `examples/skills/calculator/SKILL.md` 指示模型使用 calculator 工具；验收时模型能按说明调用工具。

## 9. Agent 模板

内置组合模板 `React Agent`（可展开、可复制、可改参数）：

```text
Agent.start → Prompt.run
Prompt.done → Provider.run → ToolSet.run → InitContext.run → Gate.start
Gate.continue → Model.run
Model.hasToolCalls → Condition.condition
Condition.true → Dispatcher.run → LoopContext.run → Gate.next
Condition.false → Gate.stop
Gate.exit → Log.run
Model.text → Log.value / Condition.payload
```

数据边把 Provider 配置、ToolSet 定义、Context handle、Model 消息/工具调用保持给下一轮。模板参数暴露 system/user prompt、provider、model、temperature、max tokens、max iterations、timeout、tools；展开后均可编辑。默认 Agent 不包含 MCP；MCP 场景通过展开加入 MCP 节点并接入 ToolSet。

## 10. UI 与自动化

UI 保持 ComfyUI 布局，只新增：Provider/Model/Prompt/Context/Tool/MCP/Skill 节点库条目、设置对话框（凭据与模型发现）、Agent 模板条目、运行事件中的模型/工具状态。所有交互元素加稳定 `data-testid`。

- Playwright：headless Chromium，自动启动 Vite（mock transport），测试节点创建/拖拽/连接/参数编辑/组合展开/模板/日志/运行控制；模拟 Provider 和 ToolCall 仅用于前端 UI 测试，不参与最终验收。失败保存 screenshot/trace/console。
- WebdriverIO + Tauri embedded WebDriver：macOS 真实窗口、真实 IPC、真实 Rust Runtime；独立 `LINGXI_DATA_DIR`；测试运行/终止/审批/历史/Subgraph；结束后清理进程与数据目录。
- 测试 mock Provider/MCP 使用真实 HTTP/stdio 协议与脚本响应，不伪造 Runtime 执行。无真实模型凭据，真实 Provider 调用标记未实测。

## 11. 验收对照

- 场景 A：Rust 集成测试 + 真实 Tauri（mock OpenAI-compatible HTTP）。
- 场景 B：真实 ToolCall → calculator → Context → 最终回答。
- 场景 C：真实本地 stdio MCP fixture。
- 场景 D：示例 Skill 注入并触发 calculator。
- 场景 E：两个 Agent 模板实例并行/先后运行，Context、事件 scope、工具结果隔离。
- 场景 F：运行中关闭/刷新 WebView，重连读取 active_run + 事件回放，不重复调用。
- 场景 G：401/429/500、超时、流中断、非法 ToolCall、MCP 崩溃、拒绝审批、取消、预算耗尽。

平台：macOS 真实 Tauri 验收；Windows/Linux 由 CI 编译、clippy、Rust 测试验证，运行期明确标记未实测。
