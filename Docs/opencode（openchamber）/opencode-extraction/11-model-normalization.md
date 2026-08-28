# Model Request Normalization

## 分层

1. `Provider`：catalog/config/auth -> runtime Model / `LanguageModelV3`。
2. Session request：将 Session Parts/工具定义转换为 AI SDK `ModelMessage` 与 stream options。
3. `ProviderTransform`：按 provider/npm/model 清洗消息、cache point、reasoning、schema、providerOptions。
4. AI SDK adapter：发起实际 provider request。

`provider/transform.ts:101-355` 显式处理 Anthropic/Bedrock 空内容与 reasoning signature、Claude/Mistral toolCall ID、DeepSeek reasoning、OpenAI-compatible interleaved reasoning。`1156-1324` 对 OpenAI/Azure/Gemini/Zhipu/Kimi/Alibaba/OpenRouter/Gateway 等设置 `store`、usage、thinking、reasoning effort/summary、cache key、encrypted reasoning；`1511-1651` 分别降级 OpenAI、Moonshot、Gemini tool JSON schema。

因此规范化是“共享 ModelMessage + 多次兼容改写”，不是纯 provider-neutral request DTO。影响 runtime 的泄漏点包括：

- provider-specific reasoning replay 与加密 reasoning include；
- model ID 条件的 max/reasoning/verbosity defaults；
- cache control 放在消息级还是 content-part 级；
- 工具 schema 能力与细节；
- media modality 回退为文字错误；
- adapter transport 选项与 OpenAI-compatible naming。

`options()` 以 Session ID 放 prompt cache key，但这是 provider prompt caching affinity，非 agent long-term memory。
