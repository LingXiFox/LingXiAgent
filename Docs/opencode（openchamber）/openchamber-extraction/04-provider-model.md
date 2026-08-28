# Provider 与 Model 边界

## Flow

```text
ProvidersPage / model picker
  -> config store and scoped SDK client
  -> OpenChamber Server routes or OpenCode proxy
  -> OpenCode config/auth/catalog APIs
  -> provider OAuth/API endpoint
```

OpenChamber has a provider **management UI and file/config orchestration layer**. It is not the primary provider runtime. OpenCode determines what a configured provider/model does for normal Agent requests.

## Sources and persistence

| Data | Owner | Storage / source | OpenChamber action |
| --- | --- | --- | --- |
| Provider/model catalog | OpenCode | OpenCode API snapshot | proxy/SDK reads it; server can snapshot `fetchProvidersSnapshot()` / `fetchModelsSnapshot()` |
| Custom provider declaration | OpenCode config | user `~/.config/opencode/opencode.json`, project `<dir>/.opencode/opencode.json` or `opencode.json`, `OPENCODE_CONFIG` custom layer | validates then reads/writes selected layer |
| Provider credential | OpenCode | `~/.local/share/opencode/auth.json` | provider auth routes/API; never returns secret |
| Provider OAuth callback | OpenCode | OpenCode auth mechanism | proxy forwards callback with special 15-minute timeout |
| Model selection | OpenCode request/Message selection | selection carried in prompt/session operations | UI's `selection-store.ts` holds current picker choices |
| Capability / pricing metadata used by UI | models.dev metadata cache, plus OpenCode catalog | `GET /api/openchamber/models-metadata` | server exposes cached metadata |

Evidence: `packages/web/server/lib/opencode/{routes,providers,auth,proxy,shared}.js`, `openchamber-routes.js`, `packages/ui/src/components/sections/providers/`.

`providers.js` writes only custom OpenAI-compatible config blocks. It requires a base URL and model definitions, writes no key, and demands `config.env` or proof that auth was saved through OpenCode `auth.set`. Configuration layer precedence is custom > project > user.

## Model capability and selection

The model picker uses OpenCode provider/model data and supplemental models.dev metadata. The small-model subsystem reads context/output limits and structured-output flags from that metadata, but it is an OpenChamber utility path, not the normal Agent path. No separate OpenChamber Agent model registry was found.

The UI persists selected model/agent/variant as UI selection state. The request path sends selections to OpenCode. `openchamber-control/service.js` validates explicitly requested model/agent/variant against the target directory's OpenCode snapshots before it creates or dispatches a Session. Normal send/fork can reuse the Session's last user-message selection before defaults.

Per-agent default model is an OpenCode configuration/runtime concept as exposed by its agent data. OpenChamber does not implement model inference or tool capability enforcement itself.

## Refresh

The UI config stores retain values per directory and a flat mirror for the active project. Loads/mutations receive an explicit directory, so inspecting Settings for another project does not retarget chat. Failures preserve previous entries instead of pretending the provider list is empty. Evidence: `packages/ui/src/stores/DOCUMENTATION.md` “Configuration stores and the Settings directory”.

## OpenChamber additions

| Addition | Why it exists | Boundary |
| --- | --- | --- |
| `GET /api/openchamber/models-metadata` | capabilities/pricing metadata used by UI and utility calls | OpenChamber cache over models.dev data |
| `GET /api/zen/models` | OpenChamber endpoint | compatibility/product metadata; exact current UI dependence is `UNKNOWN` |
| provider env aliases | make known credential variable names visible to managed OpenCode | managed child environment only |
| small model | direct server-side utility LLM calls for Goals, walkthrough, assist | OpenChamber owned, reuses OpenCode login/config |
| quota dashboard | reads supported provider usage APIs | OpenChamber owned, separate from per-message usage |

The small-model runtime must not be confused with OpenCode's provider runtime. It reads existing credentials and config, performs server-side provider-format calls, and is unavailable as a generic client-side credential API. Source: `packages/web/server/lib/small-model/DOCUMENTATION.md`.

## Unknowns

- OpenCode's authoritative catalog update algorithm and all model capability definitions were not inspected.
- Exact persistence scope of a model selection within OpenCode is not inferred beyond OpenChamber's request and UI state.
