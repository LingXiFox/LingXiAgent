# P14 Provider Matrix

**验证日期：2026-08-31**
**验收：RESEARCH READY。**
`UNVERIFIED` 表示本次没有足够官方证据，不是实现承诺。OpenCode/Sub2API/models.dev 不是官方事实来源。

| Product ID | Vendor / Provider | Product type | Account acquisition / auth modes | Wire | Model discovery | Official verification | Implementation priority |
|---|---|---|---|---|---|---|---|
| anthropic-api | Anthropic | cloud API | apiKeyAccount; workloadIdentityAccount | Anthropic Messages; OpenAI-compatible (limited) | `GET /v1/models` | VERIFIED API; consumer subscription not included | P0 |
| anthropic-claude-subscription | Anthropic | subscription | oauthUserAccount; subscriptionAccount; 可使用（非官方） | Anthropic Messages | official model docs; subscription discovery UNVERIFIED | 可使用（非官方）: Sub2API/runtime evidence | P2 |
| cloudflare-ai-gateway | Cloudflare | gateway | gatewayAccount; gatewayDelegatedAuth; BYOK; customHeader | OpenAI Chat; OpenAI Responses; provider passthrough; native gateway | account/catalog; unified discovery UNVERIFIED | VERIFIED gateway auth/endpoints/headers | P1 |
| deepseek-api | DeepSeek | cloud API | apiKeyAccount | OpenAI Chat; OpenAI Responses; Anthropic Messages; OpenAI-compatible | `GET /models` | VERIFIED | P0 |
| hugging-face-inference | Hugging Face | gateway/aggregator | apiKeyAccount; gatewayAccount | OpenAI Chat; provider-native HF client | `GET /v1/models` | PARTIAL: gateway/catalog verified | P1 |
| llama-cpp-local | llama.cpp | local | anonymousLocalAccount; localInstance; apiKey(optional) | OpenAI Chat; OpenAI Responses; Anthropic Messages; OpenAI-compatible | `GET /v1/models` | VERIFIED | P0 |
| lm-studio-local | LM Studio | local | anonymousLocalAccount; localInstance; apiKey(optional) | OpenAI Chat; OpenAI Responses; Anthropic Messages; OpenAI-compatible; native | `GET /v1/models` | VERIFIED | P0 |
| minimax-api | MiniMax | cloud API | apiKeyAccount | OpenAI Chat; Anthropic Messages; OpenAI-compatible | official static model docs; API discovery UNVERIFIED | PARTIAL | P1 |
| minimax-token-plan | MiniMax | subscription | subscriptionAccount | OpenAI Chat; Anthropic Messages; endpoint-specific compatibility | official plan/model docs; discovery/quota UNVERIFIED | VERIFIED product separation; third-party policy partial | P2 |
| ollama-local | Ollama | local | anonymousLocalAccount; localInstance | Ollama native; OpenAI Chat; OpenAI Responses; OpenAI-compatible | `/api/tags`, `/v1/models` | VERIFIED | P0 |
| ollama-cloud | Ollama | cloud API | apiKeyAccount | Ollama native; OpenAI-compatible cloud details UNVERIFIED | `https://ollama.com/api/tags` | PARTIAL | P1 |
| openai-api | OpenAI | cloud API | apiKeyAccount | OpenAI Responses; OpenAI Chat; provider-native | `GET /v1/models` | VERIFIED API | P0 |
| openai-codex | OpenAI | subscription/agent | oauthUserAccount; 可使用（非官方） | OpenAI Responses; provider-specific | official agent catalog; subscription discovery UNVERIFIED | 可使用（非官方）: Sub2API/OpenCode evidence | P2 |
| gemini-api | Google / Gemini | cloud API | apiKeyAccount; workloadIdentityAccount | provider-native Gemini; OpenAI-compatible | `GET /v1beta/models` | VERIFIED API; consumer subscription separate | P0 |
| gemini-code-assist | Google / Gemini | subscription/agent | oauthUserAccount; subscriptionAccount; 可使用（非官方） | provider-native; endpoint-specific | official agent catalog; discovery UNVERIFIED | 可使用（非官方）: Sub2API evidence | P2 |
| antigravity | Google / Antigravity | subscription/gateway UNVERIFIED | oauthUserAccount; 可使用（非官方） | UNVERIFIED | UNVERIFIED | 可使用（非官方）: Sub2API runtime evidence; vendor contract UNVERIFIED | P3 research gate |
| opencode-zen | OpenCode | gateway | gatewayAccount; apiKeyAccount | OpenAI Responses; OpenAI-compatible Chat | `/zen/v1/models` | VERIFIED product docs | P1 |
| opencode-go | OpenCode | subscription gateway | subscriptionAccount | OpenAI Responses; OpenAI-compatible Chat | `/zen/go/v1/models` | VERIFIED product/subscription docs | P1 |
| openrouter | OpenRouter | gateway/aggregator | gatewayAccount; apiKeyAccount; oauthUserAccount UNVERIFIED | OpenAI Chat; OpenAI Responses; gateway-native routing | `/api/v1/models`, `/model/...`, `/endpoints` | VERIFIED API/catalog; OAuth lifecycle partial | P0 |
| xai-api | xAI | cloud API | apiKeyAccount | OpenAI Responses; Chat support per model UNVERIFIED | official model pages; `/v1/models` UNVERIFIED | VERIFIED API partially | P1 |
| xai-grok-subscription | xAI | subscription/agent | oauthUserAccount; subscriptionAccount; 可使用（非官方） | provider-specific; OpenAI Responses UNVERIFIED | official agent docs; discovery/quota UNVERIFIED | 可使用（非官方）: Sub2API evidence | P3 research gate |
| zai-api | Z.AI | cloud API | apiKeyAccount | OpenAI Chat | discovery endpoint UNVERIFIED; official model pages | PARTIAL | P1 |
| zhipu-coding-plan | Z.AI / 智谱 | subscription | subscriptionAccount | Anthropic Messages; OpenAI Chat; OpenAI Responses | official plan/model docs; endpoint UNVERIFIED | VERIFIED product endpoints/policy | P1 |
| mimo-api | Xiaomi MiMo | cloud API | apiKeyAccount; customHeader | OpenAI Chat; Anthropic Messages | official model docs; endpoint UNVERIFIED | VERIFIED | P1 |
| mimo-coding-plan | Xiaomi MiMo | subscription | subscriptionAccount; customHeader | OpenAI-compatible; Anthropic-compatible | plan page/model docs; quota API UNVERIFIED | VERIFIED product endpoint/policy | P1 |
| alibaba-bailian-api | Alibaba Cloud Model Studio | cloud API | apiKeyAccount; workloadIdentityAccount UNVERIFIED; customHeader | OpenAI Chat; provider-native DashScope | official Model Studio catalog; discovery endpoint UNVERIFIED | VERIFIED API/region/key | P0 |
| qwen-coding-plan | Alibaba / Qwen | subscription | subscriptionAccount UNVERIFIED | UNVERIFIED | UNVERIFIED | P3 research gate |

## 分类说明

- `apiKeyAccount`、`oauthUserAccount`、`workloadIdentityAccount`、`subscriptionAccount`、`localInstance`、`gatewayAccount` 是 credential acquisition/account type。
- `subscriptionAccount` 只表示订阅凭据/账户获取和资格，不是 HTTP request authentication；订阅 key 仍可能通过 `apiKeyHeader` 或 `bearerToken` 发送。
- `oauthUserAccount` 表示交互式用户 OAuth；`workloadIdentityAccount` 表示服务身份/WIF/ADC，二者不能合并。
- `gatewayDelegatedAuth`、`customHeader` 是 request authentication/endpoint routing 形态，不是 Provider brand 的单值属性。
- `可使用（非官方）` 表示官方自家 Agent 支持 + 第三方已有运行证据；不是官方背书或合规承诺。

## 优先级约束

P0 只覆盖官方 API/本地产品资料充分、wire 清晰且不需要消费订阅私有流程的 Product。P1 覆盖 gateway、多 wire 或官方 coding-plan。P2 是有第三方运行证据但官方第三方授权未明确的独立 Product。P3 保持研究占位，不因矩阵存在而实现。
