# LingXi Unified Model Registry — source

This directory is the **only** authority for what the registry publishes. Every
HTTP view (`/v1/catalog`, `/v1/providers`, `/v1/products`, `/v1/models/{id}`) is
derived from these files plus the discovery cache. There is no per-provider JSON
endpoint and no second source of truth.

| File | Holds |
|:--|:--|
| `vendors.json` | Vendor identities (`openai`, `google`, …). |
| `providers.json` | API products: endpoint, protocol, auth, quirks, request profiles. |
| `oauth-products.json` | OAuth / subscription products, including authorization-server facts. |
| `overlays.json` | Model-level metadata supplement. **Never an allowlist.** |
| `discovery-profiles.json` | How to read a model list off an upstream endpoint. |

## What is deliberately NOT here

**Model ID lists.** A product's models come from upstream discovery, not from a
hand-maintained roster. `openai-api` does not list `gpt-4o`; it declares that its
models are discovered from `https://api.openai.com/v1/models`.

**Credentials.** The public registry holds none. A discovery profile marked
`"public": true` is the only kind this service will ever execute. Everything
account-scoped is discovered by the client against the user's own credential —
user keys are never uploaded here.

## overlays.json semantics

An overlay answers "what else does LingXi know about this model?" — context
window, reasoning mode and levels, tool calling, structured output, modalities,
aliases, deprecation status. It is keyed by product, then by canonical model ID.

The rule that matters: **an overlay supplements, it never filters.** A model the
upstream listing returns but no overlay mentions is still published, with
`metadataIncomplete: true`. Do not add an entry expecting it to hide something.

`overlays.json` ships empty on purpose. The legacy model rosters that used to
live in per-provider overlays (`gpt-4o`, `o1`, `o3-mini`, `gemini-2.0-flash`, …)
were deleted rather than migrated: keeping them would have re-anchored the
catalog to a frozen model set, which is the problem this registry exists to fix.

## Discovery profile kinds

`kind` selects the response parser, and that selection is the *only* place a
provider-specific listing shape is allowed to appear:

- `openai-models` — `{"data":[{"id":…}]}`
- `openrouter-models` — `{"data":[{…,"supported_parameters":[…]}]}`
- `anthropic-models` — `{"data":[{"id":…,"display_name":…}]}`
- `gemini-models` — `{"models":[{"name":"models/…"}]}`
- `ollama-tags` — `{"models":[{"name":…}]}`
- `plain-array` — a bare JSON array of IDs or objects

Profiles with `"public": false` describe how the *client* should discover models
with the user's own credential. They are published as metadata; this service
never executes them.

## Editing

1. Edit the JSON source here.
2. `systemctl restart lingxi-registry` — the service reloads the registry on
   start and rebuilds the catalog.
3. `catalogRevision` changes only when content changes; whitespace-only edits do
   not move it.

Adding a provider means adding a product entry plus a discovery profile. It does
**not** mean adding a model list.
