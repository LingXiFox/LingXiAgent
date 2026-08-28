# 数据与持久化

## Storage map

| Data | Owner | Storage | Lifetime / sensitivity | Future classification |
| --- | --- | --- | --- | --- |
| Normal Session, Message, Part, tool/reasoning records | OpenCode | OpenCode-owned persistence, schema not inspected | durable, sensitive | runtime adapter data |
| OpenChamber settings | OpenChamber Server | `<OPENCHAMBER_DATA_DIR>/settings.json`, default `~/.config/openchamber` | durable; may include endpoints/settings | core/client preference split |
| OpenCode auth | OpenCode | `~/.local/share/opencode/auth.json` | durable secret | runtime adapter credential store |
| OpenCode user/project/custom config | OpenCode | `~/.config/opencode/opencode.json`, `<dir>/.opencode/opencode.json`/`opencode.json`, `OPENCODE_CONFIG` | durable; may include config secrets | runtime adapter config |
| trusted remote clients | OpenChamber | `remote-clients.json`, stored hashes | durable secret-equivalent | remote gateway |
| pairing sessions | OpenChamber | `client-pairing-sessions.json`, hashed one-time secret | short-lived secret | remote gateway |
| Relay identity/claim | OpenChamber | data dir identity files and `relay-host.lock` | durable key/ephemeral lock, sensitive | remote gateway |
| project metadata, task state | OpenChamber | per-project config via `projects/project-config.js` | durable | core logic |
| Session Goal objective | OpenChamber | `<data-dir>/goals/<sessionId>.md`; compact state in Session metadata | durable, potentially sensitive | core logic |
| Session assist | OpenChamber metadata | `metadata.openchamber.assist` through OpenCode Session update | durable | core logic |
| managed Chat working directory | OpenChamber | `~/.config/openchamber/chats/YYYY-MM-DD/session-<id>` | durable filesystem | platform/core policy |
| custom theme/wallpaper | OpenChamber | `~/.config/openchamber/themes/`, managed desktop assets | durable local assets | client/platform preference |
| browser UI cache | UI | localStorage, runtime/directory/session scoped | bounded, noncanonical | client only |
| drafts, mentions, pins, todos, folders | UI | safe storage/localStorage, some server folder state | durable client continuity | client only / core only if cross-device desired |
| terminal scrollback | terminal server runtime | in-memory, capped 512 KiB per terminal | session lifetime | platform adapter |
| terminal tab arrangement | UI | persisted browser state; output excluded | durable UI preference | client only |
| Git identity | OpenChamber Git module | Git config / identity storage | durable, sensitive | platform adapter |
| GitHub auth | OpenChamber | `github-auth.json` under OpenChamber storage | durable secret | integration service |
| Push subscriptions/APNs tokens | OpenChamber | notification runtime files/settings | durable secret/device metadata | remote service |
| quota credentials | provider/native stores, selected OpenChamber files | e.g. `quota/sub2api.json`, Ollama quota dir | durable secrets | optional integration |

## SQLite conclusion

No OpenChamber Session SQLite schema exists in the inspected source. `grep` finds SQLite only for a **read-only Cursor credential import** in `packages/web/server/lib/quota/providers/cursor.js` and VS Code counterpart. Do not infer that OpenChamber owns OpenCode's DB because it invokes OpenCode APIs. The exact OpenCode DB/schema remains out of scope.

## Settings authority

`createSettingsRuntime()` reads, migrates and atomically persists settings. Successful server settings sync is authoritative; transport/load failure preserves client state instead of resetting it. Some device-local selections, sticky headers, drafts and caches intentionally do not enter `settings.json`. Evidence: `opencode/settings-runtime.js`, `settings-helpers.js`, `stores/DOCUMENTATION.md`.

## Cross-device boundary

Remote clients operate the selected host's server/OpenCode data. Browser localStorage follows the individual device and is not shared. Server project config, OpenCode Session data, goals, pairing/relay identity and remote tokens reside on the host, not a cloud sync database.
