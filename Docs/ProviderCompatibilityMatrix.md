# LingXiAgent Provider Compatibility Matrix (v2)

> Auto-generated from `builtin-provider-catalog.json`
> Upstream Source: https://models.dev/api.json (rev 2026.09-live)

| Product | Vendor | Protocol | Auth | Model Discovery | OAuth Status | Models | Tools | Parallel Tools | Vision | Reasoning | Levels | Structured Output | Context | Max Output | Cache | Continuation | Profile | Status | Quirks |
|:---|:---|:---|:---|:---|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---|:---:|:---|
| `alibaba-bailian-api` | alibaba | `openai_responses` | bearerToken | Static / models.dev | — | 3 | ✅ | ✅ | ❌ | ❌ | — | ❌ | 1000k | 32k | ❌ | responses_api | `default` | verified | none |
| `anthropic-api` | anthropic | `anthropic_messages` | apiKey, workloadIdentity | Static / models.dev | — | 3 | ✅ | ✅ | ✅ | 🧠 | high, low, max, medium, minimal | ✅ | 200k | 64k | ✅ | stateless | `default` | verified | requiresAnthropicVersionHeader |
| `anthropic-claude-subscription` | anthropic | `anthropic_messages` | oauth, subscription | Static / models.dev | — | 1 | ✅ | ✅ | ✅ | ❌ | — | ✅ | 200k | 64k | ✅ | stateless | `default` | compatibleNonOfficial | none |
| `antigravity` | google | `openai_chat` | oauth | Static / models.dev | ✅ Ready | 1 | ✅ | ✅ | ✅ | ❌ | — | ✅ | 1048k | 65k | ✅ | stateless | `antigravity@2026-09` | compatibleNonOfficial | none |
| `deepseek-api` | deepseek | `openai_chat` | bearerToken | Static / models.dev | — | 2 | ✅ | ✅ | ❌ | 🧠 | auto | ❌ | — | — | ❌ | stateless | `default` | verified | statelessContinuationOnly |
| `gemini-api` | google | `openai_chat` | apiKey, bearerToken, workloadIdentity | Static / models.dev | — | 4 | ✅ | ✅ | ✅ | 🧠 | high, low, max, medium, minimal | ✅ | 1048k | 65k | ✅ | stateless | `default` | verified | none |
| `gemini-code-assist` | google | `openai_chat` | oauth | Static / models.dev | ✅ Ready | 2 | ✅ | ✅ | ✅ | ❌ | — | ✅ | 1048k | 65k | ✅ | stateless | `gemini-code-assist@2026-09` | compatibleNonOfficial | none |
| `llama-cpp-local` | local | `openai_chat` | bearerToken, none | Static / models.dev | — | 1 | ✅ | ❌ | ❌ | ❌ | — | ✅ | 128k | 4k | ✅ | stateless | `default` | verified | localRuntime |
| `lm-studio-local` | local | `openai_chat` | bearerToken, none | Static / models.dev | — | 1 | ✅ | ❌ | ❌ | ❌ | — | ✅ | 128k | 4k | ✅ | stateless | `default` | verified | localRuntime |
| `minimax-api` | minimax | `openai_chat` | bearerToken | Static / models.dev | — | 2 | ✅ | ✅ | ❌ | ❌ | — | ❌ | — | — | ❌ | stateless | `default` | verified | none |
| `minimax-token-plan` | minimax | `openai_chat` | subscription | Static / models.dev | — | 1 | ✅ | ✅ | ❌ | ❌ | — | ❌ | — | — | ❌ | stateless | `default` | compatibleNonOfficial | none |
| `ollama-local` | local | `openai_chat` | none | Static / models.dev | — | 2 | ✅ | ✅ | ❌ | ❌ | — | ✅ | 128k | 8k | ✅ | stateless | `default` | verified | localRuntime |
| `openai-api` | openai | `openai_responses` | apiKey, bearerToken | Static / models.dev | — | 4 | ✅ | ✅ | ✅ | 🧠 | high, low, medium | ✅ | 200k | 100k | ✅ | responses_api | `default` | verified | none |
| `openai-codex` | openai | `openai_responses` | oauth | Authenticated ChatGPT Remote Catalog | ✅ Ready | dynamic | ✅ | ✅ | ✅ | 🧠 | high, low, medium | ✅ | 200k | 100k | ✅ | responses_api | `openai-codex@2026-09` | compatibleNonOfficial | none |
| `openrouter` | openrouter | `openai_chat` | apiKey, bearerToken | Static / models.dev | — | 2 | ✅ | ✅ | ✅ | ❌ | — | ✅ | 200k | 16k | ✅ | stateless | `default` | verified | none |
| `qwen-coding-plan` | alibaba | `openai_chat` | subscription | Static / models.dev | — | 1 | ✅ | ✅ | ❌ | ❌ | — | ❌ | 1000k | 32k | ❌ | stateless | `default` | unverified | none |
| `xai-api` | xai | `openai_responses` | apiKey, bearerToken | Static / models.dev | — | 3 | ✅ | ✅ | ❌ | 🧠 | high, low, medium | ✅ | 131k | 16k | ✅ | responses_api | `default` | verified | statelessContinuationOnly |
| `xai-grok-subscription` | xai | `openai_responses` | oauth, subscription | Static / models.dev | — | 1 | ✅ | ✅ | ❌ | ❌ | — | ❌ | — | — | ❌ | responses_api | `default` | compatibleNonOfficial | none |
