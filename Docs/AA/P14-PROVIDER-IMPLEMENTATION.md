# P14 Provider Implementation

**状态：P14 READY**
**验证日期：2026-08-31**

## 实现范围

P14 建立了 `VendorID`、`ProviderProductID`、`ProviderProductDefinition`、`ProviderProductEndpoint`、`ProviderAccount`、`ModelProfile`、`ModelLimits`、`ModelCapabilities`、`ModelCatalogSource`、`ProviderVerificationStatus`、`ProviderAvailability`、`RequestAuthentication` 和 `ProviderWire`。

认证获取/账户类型与请求认证分离：`apiKeyAccount`、`oauthUserAccount`、`workloadIdentityAccount`、`subscriptionAccount`、`localInstance`、`gatewayAccount`、`anonymousLocal` 不再与请求 header 语义混用。现有 `CredentialRef`/`CredentialStore`/`credentials.vault` 继续是唯一 secret storage。

`ResolvedModelEndpoint` 保持 Runtime 最终事实，并新增 `productID`、`endpointID`；既有 OpenAI Chat、OpenAI Responses、Anthropic Messages adapter 继续复用。请求认证只在 resolver 解析后进入 adapter，required headers 也由解析 endpoint 注入。

## Builtin Catalog

Catalog 共有 27 个稳定 Product ID。API 与 subscription/coding-plan 已拆成独立 Product；Catalog 存在不代表 Runtime runnable。

P0 runnable definitions：

- `openai-api`
- `anthropic-api`
- `deepseek-api`
- `openrouter`
- `gemini-api`（官方 OpenAI compatibility endpoint）
- `alibaba-bailian-api`（Chat/Responses compatibility endpoints）
- `llama-cpp-local`
- `lm-studio-local`
- `ollama-local`

P2/P3 或官方 endpoint/auth 不完整的 Product 只登记 Catalog/metadata，resolver 会 fail closed。没有实现私有 OAuth、消费订阅 token 抓取或未公开 endpoint。

## Resolver 行为

1. 根据 Account 的显式 Product ID 查找 Builtin Product 或显式 Custom Provider。
2. 根据 ModelProfile 的显式 wire/endpoint 选择 ProductEndpoint；不按 provider name/model name 猜测。
3. 校验 Product、Endpoint、Wire、Account type、credential ref 和 URL policy。
4. 仅在所有必要信息已验证且兼容时构造现有 wire adapter。
5. 失败返回 `ProviderResolutionError`：`providerProductUnverified`、`providerEndpointUnverified`、`providerWireUnsupported`、`authenticationUnsupported` 等。
6. `ProviderAvailability` 记录解析后的状态；未解析 Product 不伪装成 available。

## Custom Provider

Custom Provider 仍持久化在 `providers.json`，Builtin Catalog 不写入用户配置。用户配置的 endpoint、wire、auth、credential reference 和 ModelProfile 与官方 Catalog 分开；用户 metadata 默认属于 `userConfiguration`/`unverified`，不继承官方 capability。

## 测试

`ProviderPlatformContractTests` 使用临时本地 CredentialStore 和纯内存 URLRequest 构造。一个参数化测试包含 10 个 case，覆盖 9 个 runnable Product：Product ID、endpoint path、wire、认证 header、required headers、模型 ID 保留、loopback local、credential 不泄露；另有 Catalog 全量非 verified Product gate、认证不匹配和 endpoint/wire 冲突测试。测试不访问公网、不调用真实付费 API。

## 未实现

- Model discovery 的真实网络客户端和 provider-specific native Gemini/DashScope discovery
- OAuth authorize/token/refresh 的厂商实现
- subscription quota/usage client
- Provider pool、rotation、sticky session、billing ledger、proxy pool、gateway failover
- P2/P3 private OAuth 和消费订阅 token flow
