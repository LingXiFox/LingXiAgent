# Open questions and verification limits

These are intentional boundaries, not guessed answers.

| Question | Current status | Why it remains open | Safe next verification |
| --- | --- | --- | --- |
| Exact OpenCode Session/Message/Part SQLite schema | UNKNOWN | task excludes OpenCode source | inspect OpenCode separately, later |
| Exact OpenCode Session ID generator | UNKNOWN | IDs arrive through its public APIs | inspect OpenCode separately |
| OpenCode title, summarize, retry/revert/fork implementation details | boundary confirmed, internals UNKNOWN | OpenChamber invokes SDK/API only | trace only API contracts when needed |
| Full `openchamber:invoke` argument schema and every switch arm | category inventory confirmed | switch has many desktop commands; replacement should generate from source/tests | extract a typed command table from `main.mjs` in a dedicated platform pass |
| Full public REST route inventory | domain inventory confirmed | routes are distributed/lazy registered | generate route list from `index.js` + `routes.js` modules |
| Exact Settings field-to-storage table | top-level settings and special cases confirmed | many fields and migrations | serialize schema from `settings-runtime.js` / UI persistence in a settings-focused pass |
| Session knowledge, agent memory, context-obligatory detailed runtime semantics | UNKNOWN | modules were not fully traced in this pass | read their routes/runtime before retaining feature |
| Plugin/Resource UI complete scope | partly confirmed | actual standalone resource page not proven | trace Settings navigation registry and OpenCode API contracts |
| Upstream-versus-LingXi attribution for every changed line | UNKNOWN beyond listed commits | fork includes upstream merge commits | use file/symbol blame when a particular feature matters |
| Electron forced-crash / OS-kill cleanup | UNKNOWN | no runtime experiment performed | test with isolated runtime, not production data |

## Explicit non-findings

- No OpenChamber general SQLite Session database was found.
- No OpenChamber implementation of the normal Agent loop was found.
- No OpenChamber-owned alternate Session ID mapping was found.
- No mobile client direct-to-OpenCode normal product path was found.

These are source-boundary conclusions, not statements about code that was intentionally excluded from research.
