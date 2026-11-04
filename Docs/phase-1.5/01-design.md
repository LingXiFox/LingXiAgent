# Phase 1.5 设计：多协议、多模态与中文节点库

状态：实现完成，验收结果见 `02-testing-and-acceptance.md`
基线：`rewrite/3.0` @ `0c18a10`

## 1. 范围与不变量

本轮把 Phase 1.4 的单一 OpenAI Chat 文本链路扩展为三条真实协议、独立思考等级、图片/音频/视频/文档输入与统一资产层，同时把节点库改成可折叠的中文工作台。

保持不变：

- 工作流是纯 JSON；不包含 React Flow 实例、二进制、base64 或凭据。
- 节点逻辑只在 Rust Runtime 执行；前端只选择资产、编辑参数、展示事件。
- Provider、Model、Reasoning 仍是可组合节点。Runtime 没有按协议写死的 Agent Loop。
- `lingxi-spec` ← `lingxi-runtime` ← Tauri 的单向依赖不变；核心不依赖 macOS API。
- 节点 kind、端口名、事件字段与错误码是稳定协议；中文名称、描述和参数标签只存在于展示层。
- 旧工作流、旧 `core.provider` 与 Phase 1.4 标准 Agent 模板必须继续工作。

本轮不实现：真实云端账号验收、模型侧音频转写服务、原生视频输入、OAuth MCP、并行调度、安装包签名。

## 2. 分层

```text
节点库 / 画布 / 参数编辑（React）
        │  save_workflow / run_workflow / asset_import ...
        ▼
Tauri commands（27 个）
        │
        ▼
Engine（校验 + 调度 + 事件 + 权限）
        │
        ├─ Provider 节点：ProviderConfig → ProviderFactory
        │       ├─ OpenAiChatProvider      /chat/completions
        │       ├─ ResponsesProvider       /responses
        │       └─ AnthropicProvider       /v1/messages
        │
        ├─ Model 节点：能力检查 → ChatRequest → 适配器编码 → SSE/JSON 解析
        │
        ├─ Context 节点：有序 ContentPart + 会话快照
        │
        └─ 媒体输入节点：AssetStore → ContentPart / 帧 / 文本
```

三条协议共享 `ChatProvider` 抽象，而不是在 Model 节点里堆叠 `if protocol == ...`：

```rust
async fn complete(
    &self,
    request: ChatRequest,
    cancel: &RunControl,
    delta: &mut (dyn FnMut(String) + Send),
) -> Result<ChatResponse, NodeError>;

async fn list_models(&self) -> Result<Vec<String>, NodeError>;
```

`ChatRequest` 统一承载 `model / messages / temperature / max_tokens / reasoning_effort / stream / tools / timeout_ms / previous_response_id`；`ChatResponse` 统一返回 `text / tool_calls / finish_reason / usage / reasoning / response_id`。协议特有的字段只在适配器内部编码与解析。`reasoning` 永不并入 `text`。

## 3. 三条 Provider 协议

三个节点都输出相同的 `provider`（注册句柄）与 `config`（JSON），都接到同一个 Model 节点：

| 节点 kind | 协议 | 默认端点 | 认证 |
| --- | --- | --- | --- |
| `core.provider.openai_chat` | OpenAI Chat Completions | `{baseUrl}/chat/completions` | `Authorization: Bearer` |
| `core.provider.openai_responses` | OpenAI Responses | `{baseUrl}/responses` | `Authorization: Bearer` |
| `core.provider.anthropic_messages` | Anthropic Messages | `{baseUrl}/v1/messages`（baseUrl 已含 `/v1` 时不重复） | `x-api-key` + `anthropic-version: 2023-06-01` |

共同参数：`providerId`、`baseUrl`、`credentialRef`（默认 `env:OPENAI_API_KEY`）、`organization`、`supportsReasoning`、`protocol`、`capabilities`（JSON 人工覆盖）。`protocol` 参数允许把节点改成另一条线协议，默认跟随节点 kind。

### 3.1 OpenAI Chat

- 保留 Phase 1.4 行为：SSE、`tool_calls`、多轮工具结果、usage、超时、取消、401/403/429/5xx/断流错误映射。
- 图片编码为 `image_url` 的 data URL；音频编码为 `input_audio` 的 base64 + format；文本按原顺序保留。
- 原生视频/文档没有协议字段，明确返回 `model.unsupported_modality`，要求先抽帧或抽取文本，绝不静默丢弃。
- `reasoning_effort` 只在 `supportsReasoning` 为真时发送。

### 3.2 OpenAI Responses

- 请求使用 `input` items：文本 `input_text`、图片 `input_image`、音频 `input_audio`；工具调用用 `function_call`，工具结果用 `function_call_output` 并以 `call_id` 关联。
- 支持 `previous_response_id`。Context 与本地上一次消息前缀一致时，只发送新增轮次；本地历史被裁剪或替换时发送完整 transcript 并清空服务端会话，避免重复历史。
- SSE 解析 `response.created`、`response.output_text.delta`、`response.reasoning_summary_text.delta`、`response.function_call_arguments.delta`、`response.completed`，流结束后补全 item 与 usage。
- reasoning summary 作为独立字段返回，不进入正文；不暴露隐藏思维链。
- 原生视频/文档输入同样拒绝并给出预处理路径。

### 3.3 Anthropic Messages

- 系统消息拆成顶层 `system`；其余消息用 content blocks：`text`、`image`、`document`、`tool_use`、`tool_result`。
- 工具结果使用 `tool_use_id` 与 assistant 的 `tool_use` 对齐，保留多轮协议状态。
- `thinking` 预算：low 1024、medium 4096、high 8192、xhigh 16000；要求 `max_tokens > budget + 512`，否则在请求前以 `model.unsupported_reasoning` 拒绝。返回的 thinking 只进 `ChatResponse.reasoning`。
- 图片与原生 document 用 base64 block；音频/视频没有原生块，明确报错，转写或抽帧必须由上游显式完成。

所有适配器禁用重定向，凭据不会因 3xx 跳到另一个 host；网络目标为 `protocol://host:port`，由统一权限层审批。

## 4. 思考等级与模型能力

### 4.1 `core.reasoning`

端口：`run`（control 输入）、`capabilities`（JSON 输入）、`override`（JSON 输入）、`config`（JSON 输出）、`level`（text 输出）、`done`（control 输出）。参数 `level`：off / auto / low / medium / high / xhigh，默认 auto。

优先级：连接的 `override` 输入 > 节点参数；若连接了 `capabilities`，节点立即按该能力表校验并拒绝不支持的等级。Model 节点中，连接的 `reasoning` 输入 > Model 的旧 `reasoningEffort` 参数。这样既兼容 Phase 1.4，又允许上游控制节点动态驱动。

Reasoning 只产生配置，不调用模型；Model 把等级映射为各协议字段：

- OpenAI Chat：`reasoning_effort`；
- Responses：`reasoning: { effort, summary: "auto" }`；
- Anthropic：`thinking: { type: "enabled", budget_tokens }`。

### 4.2 能力模型

```text
ModelCapabilities
  input:   text/image/audio/video/document 的 Support、maxImages、maxFileSize、mediaTypes
  output:  text/image/audio 的 Support
  features: streaming / toolCalling / reasoning / structuredOutput
  limits:  maxContextTokens / maxOutputTokens
  reasoningLevels: off..xhigh
  source:  builtin / providerList / manual / probe / unknown
```

`Support` 为 `native / preprocessed / unsupported / unknown`。未知模型只认定文本可用，媒体一律 `unknown` 并拒绝，不能把“没查到”当成“支持”。内建推断保持保守：GPT-5 图片原生、推理原生；Claude 在 Anthropic 协议下图片/文档原生；GPT-4o 有视觉但不声称推理；其余媒体给预处理或未知。`capabilities` 参数可人工覆盖并标记 `manual`。

请求前 Model 检查全部 ContentPart 与推理等级：不支持直接失败并给出可执行原因；预处理类型必须已由上游节点转成文本/图片，不能把原生音频直接塞给不支持的协议。Model 节点输出 `capabilities`，前端据此显示可用输入、工具调用、流式与推理等级，并在不支持的选项旁解释原因。

## 5. 多模态与资产层

### 5.1 ContentPart 与 AssetRef

`ContentPart`：`Text`、`Image`、`Audio`（Native / Transcribed）、`Video`（Native / Frames，带时间戳区间）、`Document`（Native / Extracted，带页码）。`flatten()` 把转写音频变成带标签文本、把抽帧变成带时间戳的文本 + 图片、把抽取文档变成带页码文本；Native 保持原样，交给协议决定是否支持。

工作流 1.2 的根字段 `assets` 是 `BTreeMap<AssetId, AssetRef>`：

```json
{
  "id": "asset-<sha256>",
  "name": "sample.png",
  "mime": "image/png",
  "size": 12345,
  "sha256": "<hex>",
  "kind": "image",
  "source": "import",
  "metadata": { "width": 1, "height": 1 }
}
```

节点参数只保存资产 ID。JSON 中不出现 base64、绝对路径或文件句柄。

### 5.2 AssetStore

内容寻址目录 `<data-dir>/assets/<sha256>`：导入时计算摘要、去重、写临时文件、fsync 后原子改名；读取时按 ID 定位并校验摘要。ID 由内容决定，因此复制工作流、组合模板和多次导入同一文件不会重复占用空间。单个资产上限 128 MiB，`asset_preview` 的 data URL 上限 24 MiB。路径只从受控根目录拼接，不接受工作流提供的任意路径。

资产生命周期：保存/重载只读写引用；Composite 模板携带资产闭包；缺失文件在运行时显式报 `asset.missing`。当前没有自动垃圾回收，删除工作流不会删除共享资产（已知边界）。

### 5.3 四个媒体输入节点

| kind | 输出 | 关键参数 | 语义 |
| --- | --- | --- | --- |
| `core.input.image` | parts、images、count、summary、done | `assets`、`maxDimension`（默认 2048）、`detail` | Rust 读取并可选缩放；按选择顺序输出图片 ContentPart |
| `core.input.audio` | parts、assets、count、summary、done | `assets`、`mode`（native/transcribed）、`transcript` | native 只交给支持音频的模型；transcribed 必须有显式转写文本，否则失败，绝不偷偷调用转写服务 |
| `core.input.video` | parts、frames、count、summary、done | `assets`、`mode`（frames/native）、`frameIntervalMs`、`maxFrames`、`startMs`、`endMs` | 默认抽帧，Rust 调 ffmpeg 并写时间戳；缺 ffmpeg 明确报错；native 仅在模型/协议真正支持时可用 |
| `core.input.document` | parts、text、pages、summary、done | `assets`、`mode`（extracted/native） | PDF/DOCX/TXT/MD 抽取文本并保留页标记；native 仅在协议支持时使用；UI 提示图片/表格/版式可能丢失 |

图片/视频/文档的读取、缩放、抽帧、文本抽取都在 Rust；前端只负责选择文件、预览和保存引用。

### 5.4 协议的媒体编码

| 输入 | OpenAI Chat | Responses | Anthropic Messages |
| --- | --- | --- | --- |
| 文本 | text | input_text | text block |
| 图片 | image_url data URL | input_image data URL | image base64 block |
| 音频 Native | input_audio | input_audio | 明确拒绝，要求转写 |
| 音频 Transcribed | 带标签文本 | 带标签文本 | 带标签文本 |
| 视频 Frames | 时间戳文本 + 图片 | 时间戳文本 + 图片 | 时间戳文本 + 图片 |
| 视频 Native | 拒绝 | 拒绝 | 拒绝 |
| 文档 Extracted | 页标记文本 | 页标记文本 | 页标记文本 |
| 文档 Native | 拒绝，要求抽取 | 拒绝，要求抽取 | document base64 block |

顺序由 Context 的 `partOrder` 与消息本身的 ContentPart 顺序共同保持；媒体合并到最后一个 user turn，避免每轮重复上传。工具调用与媒体可以在同一轮共存。

## 6. 中文可折叠节点库

- 固定 10 个分组：输入与媒体、模型与协议、提示词与上下文、思考与推理、工具与 MCP、Skills、逻辑与控制、数据处理、输出、我的组合。
- 每组有图标、中文名、节点数、折叠状态；支持全部展开/收起；搜索同时匹配中文名、英文名、kind 与别名，命中时自动展开所属分组。
- 整个侧栏可收成 44px 的 rail，并记住状态；折叠状态存 `localStorage`（`lingxi.library.collapsed`、`lingxi.library.sidebar`），不写入工作流 JSON。
- 节点卡展示分类图标、中文名、一句描述与类型徽标；支持点击添加、拖拽添加、悬停/选中/禁用状态；没有渐变或发光。
- 中文资源集中在 `apps/desktop/src/lib/i18n.tsx`，默认 zh-CN，可切 en。翻译只作用于 label/description/param/port/status；`core.model`、`toolCalls`、`providerId` 等稳定标识不改。
- 参数名和帮助、端口标签、校验/运行错误、右键菜单均使用同一套资源。旧工作流保存的英文参数键不受影响。

## 7. 兼容性与 Schema 1.2

- `SCHEMA_VERSION = "1.2"`，接受 1.0 / 1.1 / 1.2。1.2 只新增可选的根 `assets` 与节点 `subgraphId`，不改变既有字段形状。
- 旧 `core.provider` 仍是 OpenAI Chat 兼容节点，旧 `core.model` 的 `reasoningEffort` 参数保留。
- 1.0/1.1 工作流没有 `assets` 时按空表加载；不含资产引用的旧图不需要迁移。
- 新增 2 个稳定校验码：`asset.unknown`（参数引用了根资产表中不存在的 ID）、`asset.invalid`（ID/摘要/大小等元数据非法），总数 36。
- 节点库分类、中文名与图标不进入协议；删除或重命名展示资源不会改变工作流。

## 8. 同轮修复的 Phase 1.4 问题

- **模型发现绕过审批**：`provider_models` 现在按 `PermissionClass::Network` 请求 `protocol://host:port` 目标，经 `HOST_INTERACTION` 用户批准后才请求；批准按 host+port 缓存，重定向关闭，错误明确区分拒绝、网络与协议。
- **MCP 审批信息不足**：审批明细现在包含解析后的可执行文件、参数、cwd、相关环境变量键，并明确声明 stdio 子进程继承当前用户权限、不是沙箱；不把“进程审批”伪装成隔离。
- **Windows 覆盖保存**：`replace_file` 在 Unix 用原子 rename；Windows 使用 `ReplaceFileW`，失败保留原文件，不再先删旧文件。回归覆盖重复保存、已存在覆盖、替换失败原文件完整性。

## 9. 测试与边界

自动化分三层：Rust 协议/资产/能力测试（真实 HTTP/SSE mock，覆盖三条 wire format、工具结果、推理分离、媒体编码、401/429/5xx、超时、取消、断流）；Playwright 19 项（5 项回归 + 14 项本阶段编辑器与能力展示）；真实 Tauri WDIO 三条协议各一项，使用真实本地图片/音频/视频/PDF/DOCX 和真实 Rust Runtime。

明确边界：

- 没有真实 OpenAI/Anthropic 凭据，因此未做真实云服务验收；本地 mock 只证明协议实现，不证明云端账号、配额和区域网络。
- 视频抽帧依赖系统 `ffmpeg`；缺失时显式失败，不伪造帧。
- 音频转写文本必须由用户或上游节点提供；本轮不内置语音识别。
- Anthropic 原生音频、三条协议的原生视频都不支持，必须显式预处理。
- 资产不做自动 GC；Windows/Linux 的真实桌面行为仍待实机验收。
