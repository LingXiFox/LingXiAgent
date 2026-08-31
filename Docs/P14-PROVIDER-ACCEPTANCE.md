# P14 Provider Acceptance

**日期：2026-08-31**
**Real Smoke：本轮未调用真实付费 API，全部为 No。**

| Product | Catalog | Contract | Runnable | Offline Contract Tested | Real Smoke Tested | Official Verification |
|---|---:|---:|---:|---:|---:|---|
| anthropic-api | Yes | Yes | Yes | Yes | No | Verified API |
| anthropic-claude-subscription | Yes | No | No | No | No | Non-official runnable evidence; vendor permission unverified |
| cloudflare-ai-gateway | Yes | No | No | No | No | Partial gateway contract |
| deepseek-api | Yes | Yes | Yes | Yes | No | Verified |
| hugging-face-inference | Yes | No | No | No | No | Partial gateway/catalog |
| llama-cpp-local | Yes | Yes | Yes | Yes | No | Verified local contract |
| lm-studio-local | Yes | Yes | Yes | Yes | No | Verified local contract |
| minimax-api | Yes | No | No | No | No | Partial |
| minimax-token-plan | Yes | No | No | No | No | Verified product separation; policy partial |
| ollama-local | Yes | Yes | Yes | Yes | No | Verified local contract |
| ollama-cloud | Yes | No | No | No | No | Partial |
| openai-api | Yes | Yes | Yes | Yes | No | Verified API key |
| openai-codex | Yes | No | No | No | No | Non-official runnable evidence; official permission unverified |
| gemini-api | Yes | Yes | Yes | Yes | No | Verified API/compatibility endpoint |
| gemini-code-assist | Yes | No | No | No | No | Non-official runnable evidence |
| antigravity | Yes | No | No | No | No | Non-official runnable evidence; vendor contract unverified |
| opencode-zen | Yes | No | No | No | No | Partial product endpoint |
| opencode-go | Yes | No | No | No | No | Verified subscription product; no runtime implementation |
| openrouter | Yes | Yes | Yes | Yes | No | Verified API/catalog |
| xai-api | Yes | No | No | No | No | Partial API |
| xai-grok-subscription | Yes | No | No | No | No | Non-official runnable evidence |
| zai-api | Yes | No | No | No | No | Partial |
| zhipu-coding-plan | Yes | No | No | No | No | Verified product/policy; no runtime implementation |
| mimo-api | Yes | No | No | No | No | Verified API; no runtime implementation |
| mimo-coding-plan | Yes | No | No | No | No | Verified product/policy; no runtime implementation |
| alibaba-bailian-api | Yes | Yes | Yes | Yes | No | Verified API/region/key |
| qwen-coding-plan | Yes | No | No | No | No | Unverified |

## Verification commands

- `swift build` passed.
- `swift test --no-parallel --filter 'ConfigurationStoreTests|ProductionConfigurationResolutionTests|ProviderPlatformContractTests|BuiltinProviderCatalogTests'` passed: 19 tests.
- `swift test --no-parallel` passed: 247 tests, 30 suites, including Golden repository replay.
- `swift test` passed: 246 tests, 30 suites, including Golden repository replay before the final acceptance-only P14 gate test was added.
- `git diff --check` passed.
- Trivy filesystem vulnerability/misconfiguration/secret scan passed: 0 findings.

## Acceptance interpretation

`Offline Contract Tested` proves only that the local product/endpoint/auth/wire contract is deterministic. It does not imply `Real Smoke Tested` or official vendor approval. `Official Verification` remains a separate evidence dimension. Catalog entries with `UNVERIFIED` or partial contract are intentionally not runnable.

## Runnable Contract Evidence

`ProviderPlatformContractTests.runnableBuiltinContractsPreserveProductWireModelAndCredentialBoundary` is one parameterized test with 10 cases covering 9 runnable Products. Each case resolves the Product and explicit Endpoint, selects the existing wire adapter, validates the request authentication header, asserts required path/headers, preserves the request model ID, and checks the request body does not contain the credential value.

| Product | Parameterized case | Evidence |
|---|---|---|
| `openai-api` | Responses | `/v1/responses`, Bearer, model preserved |
| `anthropic-api` | Messages | `/v1/messages`, `x-api-key` + `anthropic-version`, model preserved |
| `deepseek-api` | Chat | `/chat/completions`, Bearer, model preserved |
| `openrouter` | Chat | `/api/v1/chat/completions`, Bearer, model preserved |
| `gemini-api` | OpenAI-compatible Chat | `/v1beta/openai/chat/completions`, Bearer, model preserved |
| `alibaba-bailian-api` | Responses | `/compatible-mode/v1/responses`, Bearer, model preserved |
| `llama-cpp-local` | OpenAI no-auth | loopback `/v1/chat/completions`, no auth, model preserved |
| `llama-cpp-local` | OpenAI optional-token | loopback `/v1/chat/completions`, Bearer, model preserved |
| `lm-studio-local` | OpenAI no-auth | loopback `/v1/chat/completions`, no auth, model preserved |
| `ollama-local` | OpenAI no-auth | loopback `/v1/chat/completions`, no auth, model preserved |

The same suite separately tests authentication mismatch and explicit endpoint/wire mismatch. `everyNonVerifiedBuiltinProductFailsClosed` iterates every partial, non-official, and unverified Catalog Product and requires `providerProductUnverified`. Existing adapter suites cover SSE/response decoding; this P14 matrix covers resolution-to-adapter request construction.

## Final status

**P14 READY**

停止进入 P15，等待人工验收。
