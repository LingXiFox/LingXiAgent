# Usage

本页区分两种被 UI 称作“usage”的数据，不能混为一谈。

| Data | Source | Owner | Persistence |
| --- | --- | --- | --- |
| Per-turn token/cost/context display | OpenCode assistant Message/Part metadata and Session data | OpenCode | OpenCode canonical store; OpenChamber UI cache only |
| Provider subscription quota/balance | provider-specific external usage APIs | OpenChamber quota module | provider-owned credentials; in-memory cached result; selected quota files |

## Per-message usage

OpenChamber does not calculate normal Chat billing from raw prompts. It renders the usage fields it receives with completed assistant message data. `session-goal/runtime.js` explicitly reads the newest completed assistant snapshot as `input + cache.read + output` for its *goal budget*, because prior context appears in later cache usage. That is a control-loop accounting decision, not a general product billing ledger.

The inspected code confirms no OpenChamber SQLite usage ledger. It also confirms `packages/ui/src/components/chat/work-status` and usage surfaces display OpenCode-shaped data. Whether OpenCode stores provider/model aggregates or calculates a final cost internally is out of scope and `UNKNOWN`.

| Requested field | Boundary evidence | Current conclusion |
| --- | --- | --- |
| input tokens | latest completed assistant usage snapshot | OpenCode sourced |
| output tokens | same | OpenCode sourced |
| cache read | `cache.read` used by goal accounting | OpenCode sourced |
| cache write | no independent OpenChamber aggregation found | OpenCode sourced when present; exact persistence `UNKNOWN` |
| reasoning tokens | rendered from upstream part/message metadata if present | OpenCode sourced |
| cost | rendered from upstream metadata/model metadata if present | OpenCode/model-catalog sourced; no recalculation proven |

## Provider quota service

`packages/web/server/lib/quota/` is an OpenChamber-owned server service. It dispatches supported provider IDs, resolves credentials from permitted local sources, calls provider quota APIs and normalizes result windows such as `5h`, `7d`, daily and model-specific windows. It is a subscription/credit monitor, not a transcript/token aggregator.

Source: `quota/DOCUMENTATION.md`, `quota/routes.js`, `quota/providers/index.js`.

Key rules:

- credentials are not returned through the UI API;
- results contain `providerId`, `providerName`, `ok`, `configured`, `usage`, `fetchedAt`, optional `accountId`/error;
- different provider refreshes can run in parallel; concurrent refreshes for the same provider are coalesced where implemented;
- Claude quota preserves last known data through a bounded 429 cooldown;
- the only SQLite invocation found is a read-only Cursor credential import, not product persistence.

### LingXiFox addition

Sub2API quota is a downstream addition. It reads `~/.config/openchamber/quota/sub2api.json`, keyed by the exact OpenCode provider key, queries the Sub2API panel APIs and may atomically rotate its panel token pair. It does not change the OpenCode model API base URL and never exposes the tokens. Evidence: `packages/web/server/lib/quota/providers/sub2api.js`, `quota/DOCUMENTATION.md`, commits `8e733a91c`, `26373096a`, `8ef8fa276`, `e4f985b58`.

## What a replacement needs

Keeping OpenCode but discarding OpenChamber means per-turn display can read the OpenCode API directly. Rebuilding OpenChamber's quota dashboard additionally requires provider registry, credential-safe reads, provider-specific external API adapters, normalized windows, error/cache policy and UI. It does not require recreating a general SQLite usage database, because none was found here.
