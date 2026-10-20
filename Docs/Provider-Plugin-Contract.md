# Provider 插件契约

依据：项目书 §3.3（Provider 插件）、§3.1 约束（内核不内置 Provider）、§七第 2 条。
本文同时是**官方 Provider 插件的验收清单**。1.x 在这一面积累的协议知识几乎全部可继承，是本次挖矿里性价比最高的一块。

## 一、抽象边界

内核侧对 Provider 只认两个动作：

- `stream(request) → 事件流`：连接与传输层失败直接抛错；**流已开始之后**的失败以 `.failed` 事件交付。两种失败通道不得混用。
- `endExecution(executionId)`：清理该执行持有的 continuation 状态。有默认空实现。

能力不靠方法数量表达，靠**事件类型 + 声明**表达。事件集合固定 11 例，且为封闭集合：

`providerRequestID` / `started` / `heartbeat` / `textDelta` / `reasoningDelta` / `toolCallStarted` / `toolCallDelta` / `toolCallCompleted` / `usage` / `completed` / `failed`

请求面：`requestID` + `continuationOf`（串联同一执行）、`model`、`executionID`、`messages`、`tools`、`toolChoice`、`reasoning`、overall 与 idle 超时、`cachePlan`。
内容面：`text` / `image` / `imageFile` / `toolCall` / `toolResult`。
分段语义：`carriesPrivilegedInstructions`——**唯一**特权通道判据，不看 role。

明确**不在**接口里的东西：

- `countTokens`：不存在。token 估算由内核侧的保守估算器负责，只用于预算与限流预判，不进成本报告。
- 价格：不在 Provider 接口，只在模型目录（1.x `ModelPricing` 的设计正确，继承其"美元/百万 token + `isUnknown` 区分未标价与免费"）。
- 任意改写上游报文的"quirk 开关"：见第五章禁止事项。

## 二、按 wire family 划接口，不按厂商划

D-PR1：Provider 适配器只有三条 wire family——**Anthropic Messages**、**OpenAI Chat Completions**、**OpenAI Responses**。一个 Provider 插件实现其中一条 + 声明式能力，而不是一个厂商一个类。

首期只做少量主力 Provider（项目书 §3.3），6–8 家即可覆盖主力模型。1.x 的教训是 27 个 product × 56 份 binding JSON，官方文档自己承认只有 9 个可跑、真实 smoke 全为 No——规模带来的是分类负担，不是能力（E-04）。

**首批真实 Provider 三家**（Phase 0.1 决策第 5 条），按 wire family 归属：

| Provider | wire family | 备注 |
|---|---|---|
| Anthropic | Anthropic Messages | 特权 `system` 顶层、`cache_control` 单断点、`max_tokens` 必填 |
| OpenAI | OpenAI Chat Completions **与** OpenAI Responses | 三条 wire 里有两条在此一家，正好用来验证"按 family 划接口"是否成立 |
| DeepSeek | 官方同时提供 OpenAI 兼容与 Anthropic 兼容两种格式 | 见 §2.1 的额外约束 |

DeepSeek 落在哪条 family **不是实现细节而是产品判断**：同一个上游有兼容 Anthropic 格式的端点时，选错 family 会让我们白写一套 adapter。三家跑通后，family 划分若仍成立，再决定第二批。

### 2.1 DeepSeek 的额外约束（官方文档核对结果）

- 官方文档**未确认**单轮返回多个工具调用；
- Chat 兼容端点**不支持**在会话中间插入 tool 调用（tool 结果必须紧跟发出调用的 assistant 消息），其 Anthropic 兼容端点则允许；
- tool 结果使用 `role: "tool"`。

因此内核必须有两个**类型化能力字段**，而不是把它塞进 quirk 字符串（§5 第 1 条禁止项）：`supportsParallelToolCalls`、`toolResultPlacement`（`immediatelyAfterCall` / `anywhereInHistory`）。内核按声明降级：声明不支持并行时，工具批次仍按 Provider 给出顺序**串行执行**；声明 `immediatelyAfterCall` 时，装配器必须保证 assistant 与 tool 消息相邻，任何插入（附件、Hook 注入、告警尾部）都不得落在两者之间。声明与实际行为不符时按 `permissionViolation` 同级的契约违规处理，不静默容忍。

## 三、事件流终态契约（最高优先级）

1.x 在 `ModelGateway` 里定下的四条，是全内核最值钱的一条纪律，2.0 原样继承并写成跨进程契约：

1. **恰好一个终态**。
2. 终态之后**不得再有事件**。
3. **必须有终态**：既无 `[DONE]`、又无 finish_reason、又无 `message_stop` 时，必须报流协议错误，不得静默当成功。有 `[DONE]` 或"带 finish_reason 的 EOF"可宽容收尾。
4. `(完成过的 toolCall 数 > 0) == (终态 == .toolCalls)`。出现 `tool_use` 却终态为 stop，判失败。

补充四条：

5. **取消不得伪造失败**。取消路径静默结束流；Provider 自己先投递的 `.failed` 保留为真实原因。1.x 的 `f118d15` 记录过 Esc 被翻译成"Provider 流连接中断"并与真实故障抢同一终态槽位（LOOP-006）。
6. 工具参数最终不是 JSON object 时必须失败，不许猜。
7. 终态与原因的绑定信息一起交付，测试要同时钉 status 与 cause（QA 约定）。
8. **provider 自身的中止必须显式表达**：抛 `ModelFailure` 或交付 `.failed` 事件，不得用 `CancellationError` 表达业务原因（超时、限流、内容过滤等）。`CancellationError` 只属于用户取消/内核 deadline；若 Provider 仍抛出，内核会防御性归类为 `.failed / .providerFailure(.transport)`，不当作 `cancelled`（LOOP-006 加固，Phase 1.1）。

## 四、各家差异与吸收方式

这些是必须写进插件实现的硬知识，逐条来自 1.x 实测：

| 维度 | Chat Completions | Anthropic Messages | Responses |
|---|---|---|---|
| 流格式 | `choices[].delta` + `[DONE]` | `message_start` / `content_block_*` / `message_stop`，无 `[DONE]`，`error` 本身是事件 | 具名事件状态机 |
| 工具调用增量 | 按 `delta.index` 累积；id/name 可迟到、name 可跨 delta 分裂；参数须保证每个字符恰好出现一次 | 按 content block index 走 `partial_json` | arguments 有时增量有时**整体替换**（需 `hasPrefix` 判别）；`call_id` 与 `item_id` 需双向映射 |
| reasoning | 需同时读 `reasoning` 与 `reasoning_content` | `thinking_delta`（1.x 曾直接丢弃） | 必须显式请求 `reasoning.summary`，否则思考期 10–40s 全静默；且仅特定后端接受，另一后端对未验证组织直接 400 |
| stop reason | `stop`/`length`/`content_filter`/`tool_calls`，还要兼容顶层 `finish_reason`、`stop_reason`、camelCase 多形态 | `end_turn`/`stop_sequence`/`max_tokens`/`tool_use`/`refusal` | **没有 reason**：由 `completed` + 是否完成过调用推导 `stop` 或 `toolCalls`；`incomplete` 一律记 `maxTokens` |
| 工具结果位置 | `tool` role | **无 `tool` role**，结果折进 user 轮 | 按 item 回传 |
| system | 消息内 | **顶层字段**，唯一特权通道 | instructions |
| 多模态 | `content` parts + data URI | `source.base64` 或 `source.type=file` + beta 头（仅当请求出现 fileID 才加） | 按 input item |
| 缓存 | 读侧字段名多形态（见下） | `cache_control:{type:"ephemeral"}` 单断点，位置由内核 cachePlan 决定 | 由上游自动，客户端不可选断点 |
| 已知坑 | 孤儿 tool_call 必须本地剪掉；`tool_choice=auto` 必须**省略字段**而非发字面值 | base URL 已含 `/v1` 会拼成 `/v1/v1/messages`；assistant 轮含图片或 tool_result 必须报错而非静默丢；`max_tokens` 必填 | `store=false` 时要用 `include: reasoning.encrypted_content` 做无状态续写；opaque reasoning item 必须按原顺序回放 |

**领域 ID 规则（易错，单列）**：领域 `ToolCallID` 由内核合成为 `lingxi:<requestID>:<index>`；厂商原生 id 只作为 provenance 引用保存，跨轮回传必须经这层映射，**绝不拿厂商 id 当领域 id**。

**缓存读侧字段名**：1.x 实际收了 10 种拼法（`prompt_tokens_details` / `prompt_token_details` / `input_tokens_details` 等 × `cached_tokens` / `cached_prompt_tokens` / `cache_read_tokens` / `prompt_cache_hit_tokens` / `cache_read_input_tokens`）。2.0 把它做成归一化函数 + 表驱动单测，并允许"该 Provider 确实不报"这一独立结论。`cacheWrite` 目前只有 Anthropic 报得出。

## 五、1.x Provider 兼容面的死重（禁止继承）

四块（E-06），逐块说明为什么是死重：

1. **quirk 自由字符串表**：35 种 quirk 名，运行时只读 `requiresAnthropicVersionHeader` 一条，`hasQuirk()` 只出现在测试里。元数据变成了文档而非约束。**2.0 规则**：差异要么落成类型化能力字段，要么就是插件必须真的实现的请求/响应改写；不接受"记录在案但不生效"。
2. **双层抽象**：`UnifiedProtocolModelProvider` + `ProtocolDriverRegistry` 只是把请求转发回同样三个 Provider；两个所谓"原生 driver"根本没有原生 wire，纯 `return` 给 Chat driver；`resolveDriver` 遇到未知协议**静默 fallback 到 openaiChat**——配错要等到上游才炸。**2.0 规则**：只有一层；未知协议硬失败。
3. **迁移期硬编码桥**：`toLegacyDefinition()` 一个 30 分支 switch 把刚加载好的 JSON 又硬编码一遍。纯未删的桥。
4. **靠 host 名特判**：`chatgpt.com` → 强制 `store=false` + summary=auto；host 含 `opencode` → 注入 5 个私有头并伪造 UUID；`api.anthropic.com` 且非 OAuth 才开 Files API。每家一个特例，依据是"观测到的代理端点"而非契约。**2.0 规则**：不做 host 名特判；"是否支持远端状态续写 / Files / summary"作为显式能力返回，由插件自己声明。

## 六、必须原样继承的行为规则

### 6.1 错误分类与重试

可重试集合是**封闭**的：`rateLimited`、`serverOverloaded`、`gatewayTimeout`、`badGateway`、`internalServerError`、`networkFailure`。其余一律不重试。

**语义先于状态码**：很多网关用 400/500 装限流与额度，必须先嗅探 body——`rpm/tpm exhausted`、`429001`、`insufficient_quota`/额度不足/欠费（含 rpm/tpm 时不得判额度）、`context_length_exceeded`/`prompt is too long`、`content_filter`/合规、`model does not exist`。状态码映射需含 Cloudflare 520/521/522/523/524 与 529。

不可重试清单：401/402/403/404/409/413/415/422/423，以及 400 中的 context 超限与 content_filter。`contextExceeded` 唯一出路是压缩或新建会话。

退避：`Retry-After-Ms` 优先，其次 `Retry-After`（秒或 HTTP-date）；无 header 时 `2000ms × 2^(n-1)`，封顶 30000ms，抖动 0.25，最多 5 次。

**重试归属（D-PR2）**：重试由 **Provider 插件**负责，且只在**任何流事件交付之前**。一旦插件向内核交付了第一个事件，就不许再重试该请求，只能以 `.failed` 结束。内核对同一请求不做二次重试，只负责预算与截止。这条边界必须写进契约，否则两侧都会重试导致翻倍。重试次数与原因必须作为诊断上报，供延迟归因。

429 时按 `(provider, model, account)` 三元组设置冷却窗口；冷却计时的取时点必须在记录限流**之前**，否则出现 9.6ms vs 10ms 的假失败（QA-008）。

### 6.2 超时与心跳

Provider 类目下限 300s（配置更低时被抬高），idle 下限 120s。`heartbeat` 事件唯一作用是刷 idle 看门狗，**不得**外传给前端与模型。`URLError.timedOut → 命令超时`、`.cancelled → CancellationError`、其余归 `transportLost`。排队等待不得吃掉推理 deadline。

### 6.3 限流

本地按 60s 滑动窗计 TPM/RPM + 最大并发；预估 token 在真实 usage 到达后被真实值替换；本地 TPM 虚高时在若干轮后积极放行；长时间未回收的并发计数要有泄漏清理。**TPM 结算口径 = input + output + reasoning 之和。**

### 6.4 用量

`usage` 的 input/output/reasoning/cacheRead/cacheWrite 全部可缺省；**缺省不等于 0**，且要作为"该 Provider 无此项遥测"独立上报（有专门架构测试钉这条）。

### 6.5 窗口与输出预留

`contextWindowTokens`（默认 32768）、`maxOutputTokens`、`recommendedOutputReserveTokens`、来源标注。预留 = `max(requested, recommended ?? maxOutput ?? 4096)`。硬输入上限里 reservedOutput、toolSchema、protocolOverhead(256)、safetyMargin(1024) **各自单列扣一次**——1.x 注释专门警告合并字段会导致重复扣减。Anthropic 的 `max_tokens` 必填，取 `config.maxOutputTokens ?? 4096` 且 `max(1, …)`。

### 6.6 缓存断点

断点位置由内核 `cachePlan` 决定（1.x 打在 coreTools 数量对应位置），**插件无权自行判定 stable/volatile**（CACHE-002）。

### 6.7 可用性探测

用一次 one-token 流式请求定论：**429 视为可达**（限流发生在路由之后），仅 403/404 判不可用，其余 unknown。`/v1/models` 会超报（1.x 实测列 9 个其中 3 个不在套餐内），不得作为可用性依据。结果按账号记忆。

### 6.8 凭据零泄漏

请求体、错误信息、诊断日志、trace、录制回放文件中均不得出现密钥；错误文本过脱敏；插件子进程环境严格 allow-list（`Plugin-System-Design.md` 第八章）。

## 七、契约测试方法（必须继承的手法）

1. **替换传输层，不替换解析器**。1.x 的 VCR 手法只替换 `ProviderHTTPTransport`，adapter / SSE 解码 / Agent 循环 / 分页压缩 / 工具权限 / 持久化全部保持真实。这是 1.x 关于 Provider 测试最有效的一个决定。2.0 的等价做法：在 IPC 之下替换 HTTP 层，或由插件内暴露同样的 replay 开关（QA-005）。
2. record 模式**从不记录 Authorization 头**；对 model、run id、response id、item id、call id、UUID、时间戳、opaque 加密内容做归一化，但**保留 id 之间的关联关系**（否则测不出跨轮映射）。
3. replay 严格匹配，`CassetteMismatch` **不回落**到下一条。提升为金标准需过 secret scan + 人工批准 + 断网重放且必须消费完每一次 exchange。
4. 金标准仓库当前状态注意：1.x 的 `Evals/Baselines/*/summary.json` 里每任务恒 4000 cacheReadTokens 是合成值，**不能当实测**；1.x 金标准 cassette 实际近乎为空（README 自称 intentionally cassette-free）。2.0 要从阶段 2 就开始攒真实 cassette，别到阶段 5 才发现没有基线。
5. 契约层门禁（`ContractTests/` 的思路整体值得继承，因为它测的正是"边界"）：未知枚举降级、能力不得继承默认值、无消费者的契约类型判失败、IPC 帧上限、凭据不泄漏 tripwire、依赖图与平台边界结构断言。1.x 真正的 Provider 语义测试在 `Tests/LingXiAgentTests`（Anthropic/OpenAI/Responses adapter、tool call 消毒、错误分类状态机、跨 Provider 缓存架构、限流调度、SSE 解码），2.0 以它们为种子用例。

## 八、Provider 插件验收清单

判定"某个 Provider 插件合格"，逐条断言：

1. 首字节前失败用抛错、流内失败用 `.failed` 事件；两者不混用。
2. 一条流恰好一个终态；终态后再发事件即不合格。
3. 无终态信号必须报流协议错误，不得静默成功。
4. `(完成过的 toolCall > 0) == (终态 == .toolCalls)`。
5. 用户取消不得伪造失败，且保留已交付的真实故障。
6. 工具增量拼装：id/name 迟到或跨 delta 分裂时仍只发一次 started；arguments 每字符恰好一次；最终非 JSON object 时报错。
7. 不把厂商原生 call id 当领域 id 回传；跨轮回传走自带映射。
8. 不支持 reasoning 时不凭空产生 `reasoningDelta`；支持时区分"无 summary"与"无内容"。
9. `tool_choice=auto` 省略上游字段；`required` 且 tools 为空时本地拒绝。
10. 错误分类落在封闭枚举内，`isRetryable` 与状态码/语义表逐条一致；语义嗅探优先。
11. 退避严格 `Retry-After` > `2s×2^n`（封顶 30s、抖动 0.25、上限 5 次）。
12. 已交付任何事件后不得重试该请求。
13. 断流区分"网络中断（可重试）"与"协议违规（不可重试）"，不把 EOF 当 completed。
14. `usage` 允许缺失、缺失不填 0；缓存字段多形态归一；无遥测时明确上报。
15. 多模态：声明不支持则不发 image；支持则按本 wire 形状编码；assistant 轮含 image/tool_result 按协议拒绝。
16. 缓存断点只打在 cachePlan 指定位置。
17. `max_tokens` 与 contextWindow 按预留与安全边界计算，不重复扣减；`context_length_exceeded` 归不可重试并给出压缩建议。
18. 凭据零泄漏（六项位置全查）。
19. 超时与心跳遵守内核下限，不用无限等待绕过 idle。
20. 通过"替换传输、保留真实解析器"的录制回放契约测试，严格匹配不回落；未验证的能力报 `unverified`，不伪装成 verified。
21. 禁用该 Provider 插件后，内核仍能启动并引导配置，模型选择列表正确移除其模型。
22. 崩溃/挂死注入下，内核给出的错误是本文第五章分类之一，且不影响其他插件。

## 九、待决

| ID | 事项 |
|---|---|
| ~~Q-PR1~~ | **已解决**：首批 OpenAI、Anthropic、DeepSeek（见 §2 与 §2.1） |
| Q-PR4 | OpenAI 一家要同时覆盖 Chat 与 Responses 两条 wire：是先各做一个 Provider 能力，还是一个 Provider 内部按模型选择 family |
| Q-PR5 | `supportsParallelToolCalls` / `toolResultPlacement` 两个新能力字段的默认值：缺省即失败（无默认值纪律），还是缺省取最保守的"不并行 + 必须紧跟" |
| Q-PR2 | 模型目录随包分发还是内核内置最小目录（涉及"内核不含厂商信息"的边界解释） |
| Q-PR3 | 凭据取用是拉取式（插件请求）还是推流式（内核随请求下发），影响审计粒度 |
