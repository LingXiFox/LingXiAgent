# P14.11 Application Provider Connection

**状态：P14.11 READY**

## 边界

```text
TUI / GUI / Web
        -> LingXiApplication
        -> LingXiClient
        -> LingXiProtocol typed primitives
        -> LingXiCore
```

`LingXiApplication` 只依赖 `LingXiClient` 和 `LingXiProtocol`，不依赖 `LingXiCore`。Core 不包含 `/connect`、`/providers`、`/models` 或 `/disconnect` UX；TUI 的 `/connect` 与 `/providers` 只是 Application adapter。

## ProviderConnectionService

Application 暴露：

- `listConnectableProducts()`
- `beginConnection(productID:)`
- `state(flowID:)`
- `submitCredential(flowID:credential:)`
- `submitAccountFields(flowID:fields:)`
- `submitLocalEndpoint(flowID:endpoint:)`
- `continueOAuth(flowID:callback:)`（本阶段只保留 typed reservation）
- `cancelConnection(flowID:)`
- `disconnect(accountID:deleteUnusedCredential:)`
- `accounts()`

ProductSummary 由 Core Catalog 提供 connectability、account types、request authentication、credential/local endpoint requirement、required metadata 和 verification status。Application 按这些字段推进 Flow，不按 Product ID 写 provider-specific switch。

## ProviderConnectionFlow

状态包括 `idle`、`requestingCredential`、`requestingAccountFields`、`requestingLocalEndpoint`、`validating`、`creatingAccount`、`connected`、`failed`、`cancelled`。模型选择不属于 Flow；连接成功只返回 Account，后续通过独立 ModelSelectionFlow 选择 ModelProfile。

当前只允许 Catalog 中 `verificationStatus == verified` 且有可验证 endpoint 的 Product 进入连接。OAuth/订阅 private flow 仍不可连接。

## Credential ownership

Application 可以短暂接收 UI secret，并立即交给 `LingXiClient.storeProviderCredential`。Application 只保留返回的 `CredentialRef`，不持有 vault、不创建 CredentialStore、不写 `providers.json`。Core 通过已有 `CredentialStore` 写入 `credentials.vault`，Protocol response 只返回 `CredentialRef`。

连接失败时 Application 请求删除尚未被 Account 使用的临时 credential；已 connected 的 Flow 调用 cancel 不删除 Account 所引用的 credential。secret 不进入 Flow state、Account response、事件、Session、AgentRun、日志、fixture 或 VCR。

## OAuth ownership

`OAuthAuthorizationRequest`、`OAuthAuthorizationResult` 和 `OAuthConnectionState` 只属于 Protocol/Application 的预留契约。未来 Application 展示 authorization URL 并接收 callback；Core/provider primitive 负责 state/PKCE、code exchange、token lifecycle 和 CredentialStore。OpenAI Codex、Claude subscription、Gemini consumer/Code Assist、Grok subscription、Antigravity 的 private OAuth 本阶段没有实现。

## Core primitives

Protocol 新增的只是 typed primitives：列出 Product/Account、写入/删除 credential、创建/删除 Account。没有加入 `connectProvider`、`loginProvider` 或 `runConnectWizard`。CoreHost 通过已有 ConfigurationStore/CredentialStore 执行原子操作，并在断开选中 Account 时清理失效 default selection；共享 Credential 默认保留。

## TUI adapter

TUI 只负责读取命令和渲染 Flow state：`/connect` 选择 Summary、收集 key/metadata/endpoint、调用 Application；`/providers` 显示 Account summary。TUI 不 import Core，不操作 vault，不读取或修改 `providers.json`。

## Tests

`ProviderConnectionApplicationTests` 使用 `LingXiClient.inProcess`、fake `CoreEndpoint` 和真实的临时 `CoreHost`/配置存储，覆盖：API key、local no-auth、required metadata、unverified refusal、credential write failure、account create failure、cancellation cleanup、disconnect delegation、shared credential policy、providers.json 不含 raw secret。测试不访问网络。

## Verification

- `swift build`：通过
- `swift test --no-parallel`：通过，255 tests / 31 suites
- `swift test`：通过，255 tests / 31 suites
- Golden Replay：未修改
- Real Provider：未调用
- P15：未开始
