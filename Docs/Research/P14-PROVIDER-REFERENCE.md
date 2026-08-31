# P14 Provider Research Reference

**状态：RESEARCH READY**
**验证日期：2026-08-31**
**范围：只读研究；未调用真实付费 API；未修改 Provider Runtime；未新增 Provider 实现。**

## 证据规则

- `VERIFIED`：关键字段由厂商官方文档或官方 API schema 直接确认。
- `PARTIAL`：产品或部分字段已由官方资料确认，其余字段明确标为 `UNVERIFIED`。
- `UNVERIFIED`：本次没有足够的官方资料；不得据此实现或推断。
- `可使用（非官方）`：厂商官方只明确支持自家 Agent/工具，未明确授予第三方；但已有第三方实现和可运行证据。该标记不是官方背书，也不是合规承诺。
- OpenCode、Sub2API、models.dev 只用于理解实现形态，不替代厂商事实来源。
- 所有模型能力、上下文和输出上限均是“官方文档当前列出的值”；不把模型名或兼容性当作证据。

## 1. Sub2API

研究对象：`Wei-Shaw/sub2api` `main`，读取日期 2026-08-31。主要证据：

- [Account service](https://github.com/Wei-Shaw/sub2api/blob/main/backend/internal/service/account.go)
- [OAuth service](https://github.com/Wei-Shaw/sub2api/blob/main/backend/internal/service/oauth_service.go)
- [Token refresh service](https://github.com/Wei-Shaw/sub2api/blob/main/backend/internal/service/token_refresh_service.go)
- [Credential persistence](https://github.com/Wei-Shaw/sub2api/blob/main/backend/internal/service/account_credentials_persistence.go)
- [Header override](https://github.com/Wei-Shaw/sub2api/blob/main/backend/internal/service/account_header_override.go)
- [Gateway handler](https://github.com/Wei-Shaw/sub2api/blob/main/backend/internal/handler/gateway_handler.go)
- [Domain constants](https://github.com/Wei-Shaw/sub2api/blob/main/backend/internal/domain/constants.go)
- [Project README](https://github.com/Wei-Shaw/sub2api/blob/main/README.md)

### 1.1 抽象与生命周期

Sub2API 把 `Account` 作为一个可调度的上游账号，而不是单纯的 Provider 定义。账号包含平台、类型、凭据 JSON、代理、优先级、并发、负载、状态、过期时间、限流窗口、临时不可调度窗口、会话窗口、账号组和父账号/影子账号关系。

账号类型实际包括 `oauth`、`setup-token`、`apikey`、`upstream`、`bedrock`、`service_account`；平台和账号类型共同决定转发协议与凭据解释。`upstream`/`bedrock`/`service_account` 说明“认证方式”不能只用一个 API key 字符串表示。

OAuth 流程使用 state、PKCE code verifier/challenge、短期内存 session；callback 成功后保存 access、refresh、expires、scope，以及厂商特有的 org/account/email/project 等字段。刷新按 `expires_at` 窗口触发，后台分页扫描候选账号，按 provider 限制 QPS 和并发，使用刷新锁/状态重读避免重复刷新；成功后持久化、失效 token cache、同步 scheduler cache，失败按不可重试/可重试/厂商级错误区分。

Anthropic 还存在 setup-token（inference-only）形态。当前源码明确存在三套 OAuth service/refresher：Claude/Anthropic、Gemini、Antigravity；另有 OpenAI 和 Grok 专用 refresher。这说明 OAuth refresh 不是一个可无条件共享的通用 endpoint。

**重要维度区分：** “Sub2API 已实现 OAuth”是实现事实；“厂商官方允许 LingXiAgent 这类第三方客户端取得并使用订阅额度”是厂商授权事实。前者由 Sub2API 源码确认，后者仍必须由厂商官方资料确认，不能互相替代。若厂商只支持自家 Agent、但第三方已有可运行证据，则状态写为 `可使用（非官方）`，而不是简单写成 `UNVERIFIED`。

三套实现的具体形态：

- Claude：`OAuthService` 使用 state/PKCE，支持 full OAuth scope 和 inference-only setup token；callback 交换 access/refresh token，保存 expires/scope/org/account/email；按 refresh token 刷新。
- Gemini：`GeminiOAuthService` 支持 `code_assist`、`google_one`、`ai_studio`；使用 OAuth client/redirect 策略、state/PKCE；refresh 时保留 `oauth_type`，并可重新探测 project/tier。Google One 还通过 Drive quota 推断 tier，Code Assist 使用 LoadCodeAssist/onboard/project 逻辑。
- Antigravity：`AntigravityOAuthService` 使用 Google OAuth 授权码 + PKCE；交换和刷新 token 后读取用户信息、project/subscription，并保存 email/project/plan metadata；refresh 失败按 retryable/non-retryable 分类。

### 1.2 转发、选择与模型

- Gateway handler 接受客户端协议，按平台分流到 Anthropic、OpenAI、Gemini/Antigravity 等转发服务。
- 账号选择考虑模型可服务性、账号组、优先级、并发槽、RPM、限流/过载/过期/临时冷却、sticky session；失败且尚未写出流内容时可 failover，已写出流内容时禁止拼接式 failover。
- `model_mapping` 是账号级精确/末尾通配符映射；请求模型与实际 `UpstreamModel` 分开记录，mapping chain 进入 usage log。
- `base_url` 可按账号覆盖；国产平台还按 `account_mode`（payg/coding）和 `api_protocol`（chat completions/anthropic/responses/adaptive）选择端点。
- header override 只对有限平台/账号类型开放，禁止覆盖 Authorization、Cookie、Content-Type、WebSocket 握手和会话隔离头；有数量、名称和值长度及合法性校验。

### 1.3 用量、额度与持久化

Sub2API 的 usage log 同时记录用户 API key、账号、请求模型、上游模型、入站/上游 endpoint、token/cache token、cost、请求类型、响应耗时和 subscription。账号状态还承载余额/配额/限流/订阅窗口，调度会依据这些状态冷却账号。网关公开 `/v1/models` 时可依据账号 mapping/账号组产生可用模型列表，并在没有动态列表时回退静态默认列表。

凭据以账号的 JSON 字段持久化；集中保存路径会防止 spark 影子账号写入凭据。refresh token 轮换要求保留旧字段并合并新 token，避免丢失 provider-specific metadata。

### 1.4 可借鉴与明确排除

**可借鉴：** Provider 与 Account 分离；凭据类型由平台/产品共同解释；OAuth state + PKCE；refresh window、token rotation、过期/撤销/临时冷却；model mapping 与 requested/upstream model 双记录；endpoint 和 header 的受限覆盖；用量结果与账号选择状态分开。

**不进入 LingXi Core Provider Runtime：** 面向下游用户的 API key 发放与计费；账号池轮换、sticky session、failover 重试；代理池及 proxy fallback；并发/RPM/余额/订阅配额调度；gateway 入站协议转换；usage billing ledger；影子账号；OpenAI/Claude/Grok 私有订阅流量代理；通过 session cookie 或未公开客户端流程取得订阅 token。它们属于 Gateway/Account orchestration 层，且可能带来厂商条款和安全风险。

## 2. OpenCode

研究对象：OpenCode 官方文档与 `anomalyco/opencode` `dev` 分支源码，读取日期 2026-08-31。主要证据：

- [Providers documentation](https://opencode.ai/docs/providers/)
- [Models documentation](https://opencode.ai/docs/models/)
- [Provider runtime source](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/provider/provider.ts)
- [Provider auth source](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/provider/auth.ts)
- [Models.dev](https://models.dev/)

### 2.1 Provider catalog 与 model identity

OpenCode 使用 Models.dev 作为 75+ provider 的外部目录来源，同时允许配置 provider 和 model。运行时 provider 信息由 catalog、config、环境变量、`auth.json` 和 plugin/custom loader 合并得到。完整模型引用是 `provider_id/model_id`；custom provider 的 key 就是 provider ID，model key 就是 model ID。

Models.dev 负责目录级的 provider env/key 约定、API URL/npm adapter、模型 limits、cost、reasoning、tool call、modalities、release/status 等 metadata。它不是厂商认证服务器，也不是厂商模型能力的法律/事实替代来源。

### 2.2 SDK/wire adapter

Provider runtime 根据 model 的 API 元数据选择 bundled AI SDK：Anthropic、Google、OpenAI、OpenAI-compatible、OpenRouter、xAI、Alibaba 等。custom loader 可以改变 model 解析、headers、fetch、环境变量和 discovery。OpenAI 与 xAI 的部分模型使用 Responses；普通兼容端点使用 Chat Completions；Anthropic 使用 Messages。ProviderTransform 在 SDK 之前处理 reasoning、tool ID、schema、cache、provider options 等 provider/model-specific 差异。

因此“Provider brand = wire protocol”不成立。一个产品可以按 model 或 endpoint 使用多个 wire；wire adapter 也可能携带 provider-specific request transform。

### 2.3 Auth、custom provider 与 availability

- `/connect` 的 API credential 存于 `~/.local/share/opencode/auth.json`；当前 auth schema 区分 `api` 和 `oauth`，OAuth 结果可写入 access/refresh/expires 与额外 metadata。
- plugin auth 暴露 methods、prompts、authorize、callback；callback 可以返回 API key 或 OAuth credentials。pending OAuth state 在 provider auth service 中与 provider ID 关联。
- custom provider 通过 config 设置 npm adapter、name、`options.baseURL`、`options.apiKey`、`options.headers` 和 model limits。OpenAI-compatible 用 `@ai-sdk/openai-compatible`，Responses 用 `@ai-sdk/openai`。
- provider 可由 env、auth、config 或 plugin 变为 available；`enabled_providers`/`disabled_providers` 和 credential presence 影响可用性。无 credential 的 OpenCode Zen 免费模型是一个特殊 loader 行为，不应抽象成普通公共 API。
- local provider 通过相同的 custom/compatible adapter 接入；OpenCode 只负责调用，不负责启动或管理本地进程。

### 2.4 可借鉴与明确排除

**可借鉴：** 稳定的 `provider_id/model_id` 命名；catalog 与 runtime model 分离；provider-level 与 model-level options；baseURL/header override；按 model 选择 wire/adapter；显式 capability/limit/variant/status；env/auth/config/plugin 的 availability 叠加；每次运行显式选择 model。

**不作为事实或 Core 依赖：** Models.dev 的字段不能覆盖厂商官方文档；AI SDK/npm 包不能成为 LingXiAgent 的必需 runtime；OpenCode plugin auth 不能自动推导厂商 OAuth 合规性；OpenCode 的 auth.json 路径、其 UI 命令和 public/free loader 不应照搬；provider-specific transform 不能被假装成统一协议保证。

## 3. 官方 Provider 证据摘要

以下详细记录与矩阵保持一致。`—` 表示厂商官方资料没有确认，不表示“不存在”。

### Anthropic

- **stable product ID / 名称 / 类型：** `anthropic-api` / Anthropic Claude API / cloud API；`anthropic-claude-subscription` 是独立的 subscription/agent Product。
- **Base URL / Auth：** `https://api.anthropic.com`；`x-api-key` API key 或 `Authorization: Bearer` 短期 token。官方认证页确认 API key 和 Workload Identity Federation；未确认面向任意第三方客户端的消费级 OAuth。
- **OAuth/subscription：** WIF 是 OAuth/OIDC 风格的工作负载认证；官方资料未明确 Claude Pro/Max 订阅额度对任意第三方客户端开放。API key 从 Claude Console 获取。
- **Sub2API implementation evidence / classification：** 已确认支持 Claude OAuth full scope 与 inference-only setup-token；结合第三方已有可运行实现，订阅 OAuth 标记为 **可使用（非官方）**。这不是 Anthropic 对 LingXiAgent 的授权或兼容性保证。
- **Wire：** 原生 Anthropic Messages；官方 OpenAI SDK compatibility 另有兼容面，但能力有明确缺口，不等同于 Messages。
- **Discovery/catalog/capabilities：** `GET /v1/models`；Models API 可返回 `max_input_tokens`、`max_tokens` 和 capabilities。context/output、reasoning、tool、vision/PDF 以该 API 或对应官方模型页为准。
- **Headers/special：** `anthropic-version` 必填；`x-api-key` 或 Authorization；beta headers 按功能启用。Gateway/custom baseURL：官方未声明任意代理能力，但 HTTP client 可由调用方配置，记为 `UNVERIFIED`。
- **Usage：** response usage；quota/rate-limit headers；独立 quota endpoint `UNVERIFIED`。
- **官方资料：** [Getting started](https://docs.anthropic.com/en/api/getting-started)、[Authentication](https://platform.claude.com/docs/en/manage-claude/authentication)、[Messages](https://docs.anthropic.com/en/api/messages)、[Models list](https://docs.anthropic.com/en/api/models-list)、[OpenAI compatibility](https://docs.anthropic.com/en/api/openai-sdk)。**status：PARTIAL（API verified，consumer subscription OAuth unverified）。**

### Cloudflare AI Gateway

- **stable product ID / 名称 / 类型：** `cloudflare-ai-gateway` / Cloudflare AI Gateway / gateway。
- **Base URL / Auth：** REST `https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/v1`；provider-specific `https://gateway.ai.cloudflare.com/v1/{account_id}/{gateway_id}/{provider}`。Cloudflare API token/Bearer；上游可用 Unified Billing、BYOK 或请求头带 provider key。
- **OAuth/subscription：** Cloudflare API token 是 gateway account auth，不是模型厂商 OAuth；Unified Billing 是 Cloudflare 计费能力，不是第三方订阅额度。第三方订阅转发 `UNVERIFIED`。
- **Wire：** `/ai/v1/chat/completions`、`/ai/v1/responses`、`/ai/run`；provider-specific passthrough 保持上游 wire。统一网关不能据此保证每个上游模型支持相同能力。
- **Discovery/catalog/capabilities：** Cloudflare account/provider catalog 与 Workers AI model catalog；统一 endpoint 的模型发现和 capability 合并规则 `UNVERIFIED`，不得直接用 gateway 列表替代上游官方能力。
- **Headers/special：** `cf-aig-gateway-id`（Workers AI 请求必需）；provider-specific endpoint、`cf-aig-authorization`、`cf-aig-collect-log`、`cf-aig-collect-log-payload` 等。支持 gateway ID、account ID、BYOK、custom metadata。
- **Usage：** Gateway logs 可记录 provider、model、tokens、cost、duration；独立 API quota/usage 以 Cloudflare account API 为准，具体统一计费余额 endpoint `UNVERIFIED`。
- **官方资料：** [Getting started](https://developers.cloudflare.com/ai-gateway/get-started/)、[REST/provider endpoints](https://developers.cloudflare.com/ai-gateway/usage/providers/openai/)、[Logging](https://developers.cloudflare.com/ai-gateway/observability/logging/)。**status：VERIFIED（gateway auth/wire/headers；upstream capability per model）。**

### DeepSeek

- **stable product ID / 名称 / 类型：** `deepseek` / DeepSeek API / cloud API。
- **Base URL / Auth：** OpenAI `https://api.deepseek.com`；Anthropic-compatible `https://api.deepseek.com/anthropic`；Bearer API key，需先创建 API key。
- **OAuth/subscription：** 官方 API key；OAuth、Coding Plan/订阅第三方接入 `UNVERIFIED`。
- **Wire：** OpenAI Chat Completions；官方 Responses API；官方 Anthropic-compatible Messages。不同 wire 的兼容字段必须按 DeepSeek compatibility table 处理。
- **Discovery/catalog/capabilities：** `GET /models` 返回 id/owner/availability；官方 Models & Pricing/模型页提供 context/output、thinking、tool/json/vision 等字段。当前官方资料列出 V4 系列的 1M context、最大 384K output，仍需按模型页更新。
- **Headers/special：** `Authorization: Bearer`；Anthropic-compatible 文档确认 `x-api-key` 支持且 `anthropic-version` ignored。Anthropic API 还会映射不支持的 Claude model name，不能被 Core 当作通用 model alias。
- **Usage：** response usage；`GET /user/balance` 官方存在；rate-limit 文档存在。
- **官方资料：** [Quick start](https://api-docs.deepseek.com/)、[Authentication](https://api-docs.deepseek.com/api/deepseek-api/)、[Models](https://api-docs.deepseek.com/api/list-models/)、[Pricing/capabilities](https://api-docs.deepseek.com/quick_start/pricing/)、[Anthropic compatibility](https://api-docs.deepseek.com/guides/anthropic_api/)。**status：VERIFIED。**

### Hugging Face

- **stable product ID / 名称 / 类型：** `hugging-face` / Hugging Face Inference Providers / gateway/aggregator。
- **Base URL / Auth：** `https://router.huggingface.co/v1`；fine-grained HF token，权限为 Make calls to Inference Providers。
- **OAuth/subscription：** HF token、PRO/Team credits 是 HF 账号/计费，不是第三方 provider OAuth；OAuth model access `UNVERIFIED`。
- **Wire：** OpenAI-compatible Chat Completions；Hugging Face native Inference Clients 支持更广任务。服务端/客户端可选择 `auto`、`fastest`、`cheapest`、`preferred` 或具体 partner provider。
- **Discovery/catalog/capabilities：** 官方称 `GET /v1/models` 返回跨 provider 模型，模型页/Inference Providers catalog 提供 provider、pricing、context、latency/throughput（可用时）。精确 model capability 由 HF/partner model page 决定。
- **Headers/special：** Bearer HF token；model policy suffix/provider selection；custom baseURL `UNVERIFIED`。
- **Usage：** HF billing/credits 与 response usage；provider-specific quota `UNVERIFIED`。
- **官方资料：** [Inference Providers](https://huggingface.co/docs/inference-providers/index)、[Hub tokens](https://huggingface.co/docs/hub/en/security-tokens)。**status：VERIFIED（gateway形态；partner-specific capability partial）。**

### llama.cpp

- **stable product ID / 名称 / 类型：** `llama-cpp` / llama.cpp `llama-server` / local runtime。
- **Base URL / Auth：** 默认示例 `http://localhost:8080/v1`；server 可通过 `--api-key`/`LLAMA_API_KEY` 开启 API key，也可无认证。
- **OAuth/subscription：** 不适用；不应访问远程订阅。
- **Wire：** OpenAI Chat Completions、Responses、Embeddings；Anthropic Messages-compatible；另有 completion endpoint。
- **Discovery/catalog/capabilities：** `GET /v1/models` 只反映 server 当前模型信息；模型能力取决于加载 checkpoint、chat template、编译和运行参数；context/output 的实际值不能由 provider brand 推断。
- **Headers/special：** Authorization Bearer 或 `X-Api-Key`；自定义端口、host、API prefix 等 server 参数。Gateway/custom baseURL 是调用方本地配置能力。
- **Usage：** response usage/性能统计；服务级 quota `UNVERIFIED`。
- **官方资料：** [llama-server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)、[function calling](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md)。**status：VERIFIED（local/wire/auth；per-model capability runtime-dependent）。**

### LM Studio

- **stable product ID / 名称 / 类型：** `lm-studio` / LM Studio / local runtime。
- **Base URL / Auth：** OpenAI-compatible `http://localhost:1234/v1`；native REST `http://localhost:1234/api/v1`；默认 no-auth，可在 Developer > Server Settings 开启 API token。
- **OAuth/subscription：** 不适用；LM Studio 本地 server 不应被当成云订阅。
- **Wire：** OpenAI Chat Completions、Responses、Completions、Embeddings；Anthropic-compatible Messages；native `/api/v1/chat`。
- **Discovery/catalog/capabilities：** OpenAI `GET /v1/models`；native REST 的 model management/loaded state/max context 等信息更丰富；能力受本地模型与 server 版本影响。
- **Headers/special：** token 开启后 `Authorization: Bearer`；端口、JIT loading、模型加载状态是本地配置。
- **Usage：** native REST 可给 token/speed/TTFT；quota `UNVERIFIED`。
- **官方资料：** [OpenAI compatibility](https://lmstudio.ai/docs/developer/openai-compat)、[Authentication](https://lmstudio.ai/docs/developer/core/authentication)、[REST API](https://lmstudio.ai/docs/developer/rest)、[List models](https://lmstudio.ai/docs/developer/openai-compat/models)。**status：VERIFIED。**

### MiniMax

- **stable product ID / 名称 / 类型：** `minimax-api` / MiniMax API / cloud API；`minimax-token-plan` / MiniMax Token Plan / subscription，是独立 Product。
- **Base URL / Auth：** OpenAI `https://api.minimax.io/v1`；API key。Token Plan 使用控制台显示的专用 Base URL 和 subscription key，不能与 pay-as-you-go key 混用。
- **OAuth/subscription：** API key；Token Plan 使用独立 `subscriptionAccount`，官方资料确认其专用 key，但 OAuth authorize/token/refresh 未确认。是否允许任意第三方工具使用 subscription quota 需按 Token Plan 条款，不能泛化。
- **Wire：** OpenAI-compatible Chat Completions；Anthropic-compatible API（官方推荐）；OpenAI Responses/provider-native 的完整范围 `UNVERIFIED`。
- **Discovery/catalog/capabilities：** 官方 API overview/model tables；本次未确认公开 model discovery endpoint。官方列出 M3 context 1,000,000，其余 M2.x 204,800；M3 reasoning、tools、vision/video 等能力按官方兼容文档。
- **Headers/special：** `reasoning_split`、`thinking`、`service_tier`、`stream_options.include_usage`；interleaved reasoning 要求完整保留 assistant message。
- **Usage：** response usage；subscription quota endpoint `UNVERIFIED`。
- **官方资料：** [API overview](https://platform.minimax.io/docs/api-reference/api-overview)、[OpenAI API](https://platform.minimax.io/docs/api-reference/text-openai-api)、[Token Plan](https://platform.minimax.io/docs/token-plan/intro)。**status：PARTIAL。**

### Ollama

- **stable product ID / 名称 / 类型：** `ollama` / Ollama local / local runtime。
- **Base URL / Auth：** native `http://localhost:11434/api`；OpenAI-compatible `http://localhost:11434/v1/`；OpenAI key 参数 required but ignored，默认 local no-auth。
- **OAuth/subscription：** 不适用；本地 Ollama 不使用云额度。
- **Wire：** native Ollama API；OpenAI Chat Completions、Responses、Embeddings。
- **Discovery/catalog/capabilities：** native `GET /api/tags`；OpenAI `GET /v1/models`；model details、digest、family、quantization 来自本地实例。模型 context 由 Modelfile `num_ctx`/本地配置影响。
- **Headers/special：** local API key ignored；自定义 host/port 是本地配置。
- **Usage：** native response metrics；quota `UNVERIFIED`。
- **官方资料：** [API](https://docs.ollama.com/api)、[OpenAI compatibility](https://docs.ollama.com/openai)、[List models](https://docs.ollama.com/api/tags)。**status：VERIFIED。**

### Ollama Cloud

- **stable product ID / 名称 / 类型：** `ollama-cloud` / Ollama Cloud / cloud API。
- **Base URL / Auth：** `https://ollama.com/api`；`OLLAMA_API_KEY`，Bearer；官方说明从 settings/keys 创建。
- **OAuth/subscription：** 需要 ollama.com account/sign-in；API key 是官方接入方式。subscription/plan quota endpoint `UNVERIFIED`。
- **Wire：** native Ollama API；云 host 可使用 Ollama client；OpenAI-compatible cloud `/v1` 细节 `UNVERIFIED`，不要从 local compatibility 自动推断。
- **Discovery/catalog/capabilities：** `GET https://ollama.com/api/tags`；cloud model library。context/output/tool/vision 以具体 cloud model 官方页为准。
- **Headers/special：** Bearer API key；cloud model 与 local model retirement 生命周期不同。
- **Usage：** account/plan usage `UNVERIFIED`。
- **官方资料：** [Cloud](https://docs.ollama.com/cloud)、[API](https://docs.ollama.com/api)。**status：PARTIAL。**

### OpenAI

- **stable product ID / 名称 / 类型：** `openai-api` / OpenAI API / cloud API；`openai-codex` / Codex subscription/agent，是独立 Product，不能与 API key 合并。
- **Base URL / Auth：** `https://api.openai.com/v1`；Bearer API key。Responses 与 Chat Completions 均有官方 API；models endpoint 官方存在。本次只确认 `apiKeyAccount`，没有 OpenAI API 官方 workload identity/WIF 证据。
- **OAuth/subscription：** API key 官方支持。OpenAI 官方 Codex/自家 Agent 支持不等于 ChatGPT/Codex consumer OAuth 对任意第三方开放。Sub2API/OpenCode 已有第三方 OAuth 运行实现，因此该形态标记为 **可使用（非官方）**；OpenAI API 官方资料仍未确认对 LingXiAgent 的授权，不能使用私有流程代替官方 API。
- **Sub2API implementation evidence：** OpenAI OAuth client 支持 authorization-code exchange、refresh token、client ID 变体和 account credential metadata；token refresh service 对 OpenAI OAuth 单独注册 refresher，并区分 personal access token。
- **Wire：** OpenAI Responses、Chat Completions；provider-native endpoint 还有更多产品 API，P14 model runtime 只把已验证 wire 作为能力。
- **Discovery/catalog/capabilities：** `GET /v1/models`；官方 model pages/API schema；reasoning/tool/vision/context/output 以每个模型页和 API schema 为准，不能使用模型名猜测。
- **Headers/special：** Authorization Bearer、组织/project headers（按账户配置）；Responses 的 input/output、tools、reasoning 参数按官方 schema。
- **Usage：** response usage；organization/project usage and costs APIs 存在，但 quota 具体权限/范围 `UNVERIFIED`。
- **官方资料：** [Authentication](https://platform.openai.com/docs/api-reference/authentication)、[Models](https://platform.openai.com/docs/api-reference/models/list)、[Responses](https://platform.openai.com/docs/api-reference/responses)、[API spec](https://platform.openai.com/docs/static/api-definition.yaml)。**status：PARTIAL（API verified，Codex subscription OAuth unverified）。**

### Gemini

- **stable product ID / 名称 / 类型：** `gemini-api` / Gemini API / cloud API；`gemini-code-assist` / Gemini Code Assist/consumer agent subscription，是独立 Product。
- **Base URL / Auth：** Gemini API REST `https://generativelanguage.googleapis.com`，通常 `/v1beta/models/{model}:generateContent`；API key 官方支持；OAuth/ADC 也由官方文档支持。
- **OAuth/subscription：** 官方 OAuth quickstart 面向 Google Cloud project/user credentials/ADC；官方自家 Gemini CLI/Code Assist 支持不等于任意第三方客户端获授权。
- **Sub2API implementation evidence / classification：** 已确认支持 `code_assist`、`google_one`、`ai_studio` 三种 Gemini OAuth 类型，并实现 code exchange、refresh、project/tier 识别及 Drive tier 查询；结合第三方已有可运行实现，相关订阅/Agent OAuth 标记为 **可使用（非官方）**。Google 官方第三方授权范围仍需单独核验。
- **Wire：** provider-native Gemini `generateContent`/stream；官方 OpenAI-compatible endpoint/SDK compatibility；Responses/Anthropic Messages `UNVERIFIED`。
- **Discovery/catalog/capabilities：** `GET /v1beta/models`；官方 models pages/API schema；context/output/reasoning/tool/vision 以每个 model 的 `inputTokenLimit`、`outputTokenLimit`、supportedGenerationMethods 和官方模型页为准。
- **Headers/special：** API key query/header；OAuth Bearer 与 project/location headers；Vertex AI 是独立 Google Cloud product，不能与 Gemini API stable ID 自动合并。
- **Usage：** response usageMetadata；Cloud quota/usage 由 Google Cloud IAM/quotas 提供，具体 endpoint `UNVERIFIED`。
- **官方资料：** [API models](https://ai.google.dev/api/models)、[Models](https://ai.google.dev/gemini-api/docs/models)、[OAuth](https://ai.google.dev/gemini-api/docs/oauth)、[OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai)。**status：PARTIAL。**

### Antigravity

- **stable product ID / 名称 / 类型：** `antigravity` / Antigravity OAuth product / subscription or gateway product type is `UNVERIFIED` from vendor docs。
- **Sub2API implementation evidence：** `AntigravityOAuthService` 已实现 Google OAuth authorize URL、state/PKCE、authorization-code exchange、refresh、user info、LoadCodeAssist project/subscription lookup 和 credential persistence；因此研究分类应记录为“oauth implementation observed”，不能记录为“没有 OAuth”。
- **Official Base URL/Auth/Wire/Discovery/limits/usage：** 官方公开资料未在本次核验中确认；这些字段保持 `UNVERIFIED`。
- **Official OAuth/subscription permission / classification：** Sub2API 已有可运行的第三方 OAuth 实现，因此标记为 **可使用（非官方）**；厂商是否允许 LingXiAgent 这类第三方客户端及是否能使用订阅额度仍 `UNVERIFIED`。不得因为 Sub2API 已实现就把私有 endpoint 当作官方公共 API。
- **官方资料：** 未找到足以确认上述高风险字段的官方开发者文档。**status：UNVERIFIED / 暂不实现。**

### OpenCode Zen

- **stable product ID / 名称 / 类型：** `opencode-zen` / OpenCode Zen / gateway。
- **Base URL / Auth：** `https://opencode.ai/zen/v1`；登录 Zen 后创建 API key。Responses 示例 endpoint `/responses`，models `/models`。
- **OAuth/subscription：** web login 是获取 API key 的账户流程；公开文档没有确认第三方 OAuth token exchange。按 `apiKey` 处理，不把 web login 当 Core OAuth。
- **Wire：** model-specific OpenAI Responses 和 OpenAI-compatible Chat Completions；官方表格按模型给出 adapter/package。
- **Discovery/catalog/capabilities：** `GET /zen/v1/models`；官方 verified model list/metadata。具体 limits/capabilities 以该 endpoint/官方 model table 更新。
- **Headers/special：** Bearer API key；模型 ID 在 OpenCode config 中为 `opencode/{model}`，这是 OpenCode naming，不是上游 model ID。
- **Usage：** Zen account/billing；公开 quota endpoint `UNVERIFIED`。
- **官方资料：** [Zen](https://opencode.ai/docs/zen/)、[Providers](https://opencode.ai/docs/providers/)。**status：VERIFIED（产品 API key/wire/discovery；OAuth/usage details partial）。**

### OpenCode Go

- **stable product ID / 名称 / 类型：** `opencode-go` / OpenCode Go / subscription gateway。
- **Base URL / Auth：** `https://opencode.ai/zen/go/v1`；订阅 Go 后获得 API key；model list `/models`。
- **OAuth/subscription：** `subscriptionAccount` 由订阅产生专用 API key；未确认 OAuth authorize/token/refresh。官方明确 Go 是 $10/month subscription，且与 Zen provider 分开。
- **Wire：** Responses 与 OpenAI-compatible Chat Completions 按 model 分配，不能只按 product 选一个 wire。
- **Discovery/catalog/capabilities：** `GET /zen/go/v1/models` 与 Go 官方模型表；上下文/输出/能力按返回 metadata/模型表，未在本次逐模型复核的字段标 `UNVERIFIED`。
- **Headers/special：** Bearer API key；model IDs 仍是 `opencode-go/{model}` 的 OpenCode 侧表示。
- **Usage：** subscription credits/limits 公开说明存在；具体 quota/usage API `UNVERIFIED`。
- **官方资料：** [Go](https://opencode.ai/docs/go/)、[Providers](https://opencode.ai/docs/providers/)。**status：VERIFIED（subscription product/wire/model endpoint；quota API partial）。**

### OpenRouter

- **stable product ID / 名称 / 类型：** `openrouter` / OpenRouter / gateway/aggregator。
- **Base URL / Auth：** `https://openrouter.ai/api/v1`；Bearer API key；OpenRouter key page 创建。
- **OAuth/subscription：** 官方 docs 明确 API keys 可用于 OAuth flows；但不同 OAuth client/product 的 authorize/token/refresh 细节未在本次记录，标 `oauth` + `UNVERIFIED`。不能将上游厂商订阅当成 OpenRouter auth。
- **Wire：** OpenAI-compatible Chat Completions；Responses API 另有官方 endpoint；provider routing 是 OpenRouter native behavior。
- **Discovery/catalog/capabilities：** `GET /api/v1/models`、`GET /api/v1/model/{author}/{slug}`、`/endpoints`；返回 context_length、pricing、supported_parameters、modalities、reasoning、top_provider 等。
- **Headers/special：** `HTTP-Referer`、`X-OpenRouter-Title` 可选；model slug/variant suffix 如 `:free`；provider routing options 是 gateway-specific。
- **Usage：** generation/credits/account endpoints；response usage 和 pricing metadata。
- **官方资料：** [Authentication](https://openrouter.ai/docs/api_reference/authentication)、[Models](https://openrouter.ai/docs/guides/overview/models)、[Model API](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties)。**status：VERIFIED（API/gateway/catalog；OAuth lifecycle partial）。**

### xAI

- **stable product ID / 名称 / 类型：** `xai-api` / xAI API / cloud API；`xai-grok-subscription` / Grok consumer subscription/agent，是独立 Product。
- **Base URL / Auth：** `https://api.x.ai/v1`；Bearer xAI API key。官方 quickstart 使用 Responses。
- **OAuth/subscription：** 官方 API key；xAI 官方资料未明确 Grok consumer subscription OAuth 对任意第三方开放。Sub2API 的 Grok OAuth 属于第三方可运行证据，因此该订阅 OAuth 形态标记为 **可使用（非官方）**，不代表厂商官方授权。
- **Sub2API implementation evidence：** `GrokOAuthClient`/`GrokOAuthService` 支持 authorization-code exchange、refresh，并将订阅 entitlement 与 API-key 账号区分；这只证明第三方实现形态存在。
- **Wire：** OpenAI Responses；Chat Completions/其他 API 是否完整支持按官方 REST reference/model page，未逐项确认的字段 `UNVERIFIED`。
- **Discovery/catalog/capabilities：** 官方 models/pricing pages；本次未确认稳定 public `/v1/models` discovery contract，标 `UNVERIFIED`。官方模型页列出当前 context、reasoning/tool/vision 等具体能力。
- **Headers/special：** Authorization Bearer；search/tools、Imagine/Voice 是额外 API，不应合并为 text model capability。
- **Usage：** response usage；account billing/quota endpoint `UNVERIFIED`。
- **官方资料：** [Get started](https://docs.x.ai/docs/overview)、[Models](https://docs.x.ai/docs/models)、[REST inference](https://docs.x.ai/docs/api-reference)。**status：PARTIAL。**

### Z.AI

- **stable product ID / 名称 / 类型：** `zai-api` / Z.AI Open Platform / cloud API；`zhipu-coding-plan` / GLM Coding Plan / subscription，是独立 Product。
- **Base URL / Auth：** `https://api.z.ai/api/paas/v4`；Bearer API key；API key 在 Z.AI Open Platform 创建。
- **OAuth/subscription：** API key verified；GLM Coding Plan 是独立 subscription product，单独记录为 `zhipu-coding-plan`。通用 OAuth authorize/token/refresh `UNVERIFIED`。
- **Wire：** OpenAI Chat Completions；provider-native/Anthropic-compatible 需按具体官方页，未确认的 wire `UNVERIFIED`。
- **Discovery/catalog/capabilities：** 官方 Models & Agents/model pages；公开 list endpoint 本次未确认，标 `UNVERIFIED`。Quick Start 当前列出 GLM-5.3/Flash 等，但不把展示列表当稳定 discovery API。
- **Headers/special：** `Accept-Language` 示例出现；Bearer Authorization；coding plan 有专用 endpoints。
- **Usage：** Open Platform billing/charge page；quota API `UNVERIFIED`。
- **官方资料：** [Quick start](https://docs.z.ai/guides/overview/quick-start)、[API reference](https://docs.z.ai/api-reference)、[Coding Plan](https://docs.z.ai/devpack/quick-start)。**status：PARTIAL。**

### Zhi Pu Coding Plan

- **stable product ID / 名称 / 类型：** `zhipu-coding-plan` / GLM Coding Plan / subscription。
- **Base URL / Auth：** Anthropic `https://api.z.ai/api/anthropic`；OpenAI Chat `https://api.z.ai/api/coding/paas/v4`；OpenAI Responses `https://api.z.ai/api/v1`；订阅后在 Individual/Team Coding Plan 页面取得专用 API key。
- **OAuth/subscription：** `subscriptionAccount` 使用专用 API key transport；官方明确 Team key 与其他 Z.AI key 不可互换；OAuth lifecycle 未确认。
- **Wire：** Anthropic Messages、OpenAI Chat Completions、OpenAI Responses，按官方 Coding Plan quick start。
- **Discovery/catalog/capabilities：** Coding Plan docs 当前列出 GLM-5.3、GLM-5.3-Flash、vision/MCP benefits；稳定 models discovery 和完整 context/output per model `UNVERIFIED`。
- **Headers/special：** endpoint 随 wire 改变；Key 只用于 Coding Plan supported tools/products；官方使用政策限制非 coding 自动化/自定义 backend 的场景，第三方工具必须在 supported list 内。
- **Usage：** 5-hour 与 weekly credits；billing/charge type page；公开 usage endpoint `UNVERIFIED`。
- **官方资料：** [Coding Plan quick start](https://docs.z.ai/devpack/quick-start)、[Coding Plan overview](https://docs.z.ai/devpack/overview)。**status：VERIFIED（subscription/endpoint/policy；model discovery partial）。**

### MiMo API

- **stable product ID / 名称 / 类型：** `mimo-api` / Xiaomi MiMo API Open Platform / cloud API。
- **Base URL / Auth：** OpenAI `https://api.xiaomimimo.com/v1`；Anthropic `https://api.xiaomimimo.com/anthropic/v1/messages`；`api-key: MIMO_API_KEY` 或 Bearer。
- **OAuth/subscription：** API key；MiMo Code 有登录授权但不等于 API Open Platform 通用 OAuth。Token Plan 单独为 `mimo-coding-plan`。
- **Wire：** OpenAI Chat Completions；Anthropic Messages-compatible；Responses `UNVERIFIED`。
- **Discovery/catalog/capabilities：** 官方 model docs/static model list；当前列出 MiMo V2.5 Pro/V2.5、1M context、128K output、thinking/function call/structured output/web search 等能力，需按具体 model page 更新；list endpoint `UNVERIFIED`。
- **Headers/special：** `api-key` 或 Authorization；`thinking`、model-specific parameters；API 与 Token Plan key prefix/endpoint 不可混用。
- **Usage：** 官方 account usage 页面可查看/导出 token/request data；API endpoint `UNVERIFIED`。
- **官方资料：** [OpenAI compatibility](https://platform.xiaomimimo.com/docs/en-US/api/chat/openai-api)、[Anthropic compatibility](https://platform.xiaomimimo.com/docs/zh-CN/api/chat/anthropic-api)、[Models](https://platform.xiaomimimo.com/static/docs/quick-start/model.md)、[First API call](https://mimo.mi.com/docs/en-US/quick-start/summary/first-api-call)。**status：VERIFIED。**

### MiMo Coding Plan

- **stable product ID / 名称 / 类型：** `mimo-coding-plan` / MiMo Token Plan / subscription。
- **Base URL / Auth：** China `https://token-plan-cn.xiaomimimo.com/v1`，Singapore `https://token-plan-sgp.xiaomimimo.com/v1`，Europe `https://token-plan-ams.xiaomimimo.com/v1`；Anthropic 对应 `/anthropic`；key 为 `tp-xxxxx`。
- **OAuth/subscription：** `subscriptionAccount`；订阅后在 Token Plan 页面取得 key/base URL；OAuth authorize/token/refresh `UNVERIFIED`。
- **Wire：** OpenAI-compatible、Anthropic-compatible；以 Token Plan 页面显示的协议/base URL 为准。
- **Discovery/catalog/capabilities：** 使用 MiMo 官方模型资料；Token Plan 专用 model discovery/quota endpoint `UNVERIFIED`。
- **Headers/special：** API key `tp-` 与 pay-as-you-go `sk-` 独立不可混用；官方明确 Token Plan 仅限 programming tools，禁止明显非 coding 的自动化脚本/custom backend。
- **Usage：** 共享订阅 quota；可在 Token Plan 页面查看，公开 endpoint `UNVERIFIED`。
- **官方资料：** [Token Plan quick access](https://mimo.mi.com/docs/en-US/tokenplan/Token%20Plan/quick-access)、[Subscription policy](https://mimo.mi.com/docs/en-US/tokenplan/Token%20Plan/subscription)、[OpenCode integration](https://platform.xiaomimimo.com/docs/en-US/tokenplan/integration/opencode)。**status：VERIFIED（subscription policy/endpoints；quota API partial）。**

### 阿里百炼

- **stable product ID / 名称 / 类型：** `alibaba-bailian` / Alibaba Cloud Model Studio (百炼/DashScope) / cloud API。
- **Base URL / Auth：** regional OpenAI-compatible base URLs, e.g. Beijing `https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1`；also `https://dashscope-us.aliyuncs.com/compatible-mode/v1` and other regions；Bearer DashScope API key from console。
- **OAuth/subscription：** API key；OAuth、Qwen Coding Plan third-party quota `UNVERIFIED`，Qwen Coding Plan 不能并入此 product ID。
- **Wire：** OpenAI-compatible Chat Completions；DashScope native HTTP/SDK；Responses compatibility exists in official docs but not fully rechecked here, mark `UNVERIFIED` unless endpoint-specific adapter is verified。
- **Discovery/catalog/capabilities：** official Model Studio models list and per-model API reference；Qwen/DeepSeek/Kimi/GLM/MiniMax third-party supplied models have region/access conditions。context/output/reasoning/tool/vision must come from selected model page。
- **Headers/special：** API key is region-bound；WorkspaceId/base URL region must match key；native API uses `input/messages/parameters` shapes；OpenAI-compatible uses `/compatible-mode/v1/chat/completions`。
- **Usage：** response usage；Alibaba billing/cost center and account balance；quota endpoint `UNVERIFIED`。
- **官方资料：** [First Qwen API call](https://help.aliyun.com/zh/model-studio/get-started-with-models/)、[OpenAI Chat compatibility](https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope)、[Models](https://help.aliyun.com/zh/model-studio/models)。**status：VERIFIED（API/region/wire/key/catalog source；per-model fields partial）。**

### Qwen Coding Plan

- **stable product ID / 名称 / 类型：** `qwen-coding-plan` / Qwen Coding Plan / subscription。
- **Base URL/Auth/OAuth/Wire/Discovery/Usage：** 本次未从阿里云官方资料确认一个独立、稳定且允许第三方客户端使用的 Qwen Coding Plan authorize/token/endpoint/额度契约；全部 `UNVERIFIED`。阿里百炼 API key 与此产品不能因为品牌相同而合并。
- **官方资料：** 阿里百炼模型 API 文档只足以证明 `alibaba-bailian` API key 产品；Qwen Coding Plan 的独立官方开发者契约待补证。**status：UNVERIFIED / 不阻塞全局研究。**

## 4. 结论

真实 Provider 形态至少包括：单 key cloud API、同一厂商多个 API product、OAuth/WIF、subscription-only key、local no-auth、local optional key、gateway delegated auth、gateway BYOK、provider-specific headers，以及一个产品内多 wire。LingXiAgent 不应把这些形态压缩成 `apiKey | oauth` 二选一，也不应把 Gateway 的账号池/计费/轮换逻辑下沉到 Core Provider Runtime。
