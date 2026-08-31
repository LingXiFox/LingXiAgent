# P14 Provider Design Input

**来源：** P14 Provider Research，验证日期 2026-08-31。
**状态：RESEARCH READY。**
本文件只记录架构约束，不定义具体实现方案，不修改 Provider Runtime。

## 最终 P14 Core Contract

### 1. 术语与边界

Core contract 使用五类核心实体，不能互相替代：

| 实体 | 含义 | 不负责 |
|---|---|---|
| `Vendor` | Anthropic、OpenAI、Google、Xiaomi 等品牌/厂商 | 不决定一个品牌只有一个产品 |
| `Product` | 一个独立的 API、Gateway、subscription 或 coding-plan 产品；拥有稳定 Product ID | 不持用户 credential |
| `ProductEndpoint` | Product 的一个可调用 endpoint；包含 base URL、wire、request auth、headers、discovery 能力 | 不决定模型是否支持某能力 |
| `ModelProfile` | 某 Product 的某模型在某 endpoint 上的 ID、limits、capabilities、variants 和来源 | 不作为跨 Product 的裸模型别名 |
| `Account` | 某 Product 的一个可使用账户/本地实例/网关连接及其 credential reference、状态、metadata | 不承担账号池轮换、billing ledger 或 sticky session |

同品牌的 API 与订阅产品必须有不同 Product ID 和不同矩阵行。研究中的稳定 ID 方向包括：`openai-api` / `openai-codex`、`minimax-api` / `minimax-token-plan`、`xai-api` / `xai-grok-subscription`、`mimo-api` / `mimo-coding-plan`、`alibaba-bailian-api` / `qwen-coding-plan`；未验证产品仍可先登记为独立 `UNVERIFIED` Product。

### 2. Credential acquisition/account type

订阅凭据获取属于 account type，不属于 HTTP request authentication。Core 至少需要能表达以下类型：

| Account type | 凭据取得方式 | 典型 request authentication |
|---|---|---|
| `apiKeyAccount` | 控制台/API Keys 创建 key | `apiKeyHeader` 或 `bearerToken` |
| `oauthUserAccount` | 交互式用户 OAuth authorize/code/PKCE | `oauthAccessToken` |
| `workloadIdentityAccount` | 服务账号、OIDC/WIF、ADC 或 cloud identity | 短期 `bearerToken`、cloud-signed request 或 provider-native |
| `subscriptionAccount` | 购买/激活订阅后取得专用 key/base URL/额度 | 通常 `apiKeyHeader` 或 `bearerToken` |
| `localInstance` | 本地运行时地址/实例配置 | `none` 或 operator token |
| `gatewayAccount` | 网关账户、gateway ID、BYOK/Unified Billing 配置 | `gatewayToken`、provider key 或 `customHeader` |
| `anonymousLocalAccount` | 无持久凭据的本地 endpoint | `none` |

订阅 key 即使最终放进 `Authorization: Bearer`，仍是 `subscriptionAccount`；不能因为 HTTP 头相同就把它归为 `apiKeyAccount`。同理，WIF 取得的短期 bearer 不能归为交互式 `oauthUserAccount`。

### 3. Request authentication

request authentication 是 endpoint 级契约，至少需要表达：

- `none`
- `apiKeyHeader(name)`，例如 `api-key`、`x-api-key`
- `bearerToken`
- `oauthAccessToken`
- `workloadIdentityToken`
- `gatewayToken`
- `customHeaderSet`
- `providerNative`

`customHeader` 只表示请求认证/路由所需的额外 header 集合，不表示 credential acquisition 类型。Authorization、Cookie、会话隔离、连接控制和 WebSocket 握手头不能被普通用户 header override 任意替换。

### 4. Interactive OAuth 与 workload identity

- `oauthUser` 是用户交互授权：需要 authorize URL、state、PKCE verifier、redirect/callback、code exchange、access/refresh 生命周期、scope 和 provider account metadata。
- `workloadIdentity` 是服务身份：需要 issuer/audience/subject、credential source、短期 token expiry、token exchange 或 cloud signing metadata；不假设有 refresh token，也不进入用户 callback UI。
- 两者都可能在请求时产生 bearer token，但其取得方、撤销主体、持久化字段、刷新方式和合规边界不同，不能共用一个无标签的 `oauth` 枚举。
- pending OAuth state 是短期授权会话；access/refresh credential 是持久账户状态；两者必须分开保存和清理。

### 5. ProductEndpoint 与 ModelProfile

wire 不是 Product 或 Vendor 的单值属性。一个 Product 可以声明多个 endpoint/wire；一个 ModelProfile 选择其实际 endpoint。允许的 wire 枚举至少包括：`openAIChatCompletions`、`openAIResponses`、`anthropicMessages`、`openAICompatible`、`providerNative`。

每个 `ProductEndpoint` 至少记录 base URL、path construction、wire、request authentication、required headers、custom baseURL policy、discovery method 和 evidence status。每个 `ModelProfile` 至少记录 Product ID、endpoint ID、provider model ID、display name、context/output limits、reasoning/tool/vision/structured-output/modalities、variants、catalog source、verified/unverified status。

同一产品内的 wire 选择可由 endpoint capability、ModelProfile 和请求类型共同决定；不得仅凭 Vendor、Provider 名称或“OpenAI-compatible”推断 Responses、tools、reasoning 或 vision 支持。

### 6. Catalog、discovery 与 availability

模型目录来源优先级：

1. 厂商官方模型 API、官方 API schema 和官方模型页；
2. 厂商官方静态产品目录；
3. Gateway 自己的模型/端点目录，仅代表 gateway 可用性；
4. OpenCode、models.dev、Sub2API，仅作 implementation/reference evidence；
5. 用户显式配置的 model profile，必须携带 `unverified`，不能伪装成官方能力。

discovery 可以是 API、静态目录、本地实例 discovery 或 unavailable。availability 必须独立判断 credential presence、token validity、subscription validity、gateway account、model existence、endpoint capability 和 request policy。

### 7. Evidence status

高风险字段使用 `verified`、`partial`、`可使用（非官方）`、`unverified`、`unsupported`。`可使用（非官方）` 仅表示：官方支持自家 Agent/工具，未明确第三方授权，但已有第三方可运行证据；它不是官方背书，也不是合规承诺。该状态可以附着在某个 Account/Product auth mode 上，不得覆盖其他 endpoint/model 字段的不确定性。

### 8. Scope exclusions

Sub2API 的下游 API key 发放、计费、账号池轮换、sticky session、proxy pool、failover、并发/RPM/余额调度、影子账号和订阅流量代理属于 Gateway/Account orchestration。它们不进入 LingXi Core Provider Runtime。

## 研究约束

1. API Product 与 subscription/coding-plan Product 必须独立登记、独立认证、独立额度和独立 Product ID；不得继续用一个 Provider Product 合并它们。
2. `subscriptionAccount` 只描述订阅凭据/账户获取和资格，不代替 request authentication。
3. `oauthUser` 与 `workloadIdentity` 必须分开建模，即使二者最终都发送 bearer token。
4. wire 只能挂在 ProductEndpoint/ModelProfile，不能作为 Provider brand 的单值属性。
5. Provider-specific adapter 由 endpoint/request/response 事实触发：Gemini native、Anthropic Messages、Cloudflare gateway、MiniMax/MiMo reasoning、百炼 region/workspace、Responses 等均可独立触发。
6. Base URL override 只影响 inference forwarding；OAuth、discovery、quota 的官方端点不得被静默替换。
7. capability、limit、pricing、quota 和 policy 必须保留来源与验证状态；未知字段不得从模型名猜测。
8. 未验证 Product 只阻塞自身实现，不阻塞整体 P14；研究阶段不读取 credential、不执行 OAuth callback、不调用真实付费 API。

## 明确不带入 Core 的能力

## 验收结论

官方资料不足的 Product/endpoint/auth mode 已保留 `UNVERIFIED`；第三方有运行证据但官方未授权的形态标记为 `可使用（非官方）`，没有阻塞其余研究。当前最终 Core contract 为：

**RESEARCH READY**

等待人工审查；在审查完成前停止 P14 Provider 编码。
