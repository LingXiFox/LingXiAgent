# MCP、Commands、Skills、Plugins 与 Behaviors

## Common configuration path

```text
Settings section / config store
  -> OpenChamber config entity route
  -> OpenCode config file layer or managed supporting file
  -> response: restartDeferred
  -> user applies POST /api/config/reload
  -> managed OpenCode restart, or external-runtime manual-restart guidance
```

`registerConfigEntityRoutes()` owns Agent, Command, MCP and snippet HTTP routes. Writes are deliberately deferred rather than restarting OpenCode on every keystroke. Source: `packages/web/server/lib/opencode/config-entity-routes.js`.

| Entity | Configuration owner/storage | Loader/executor | UI feedback / remote behavior | Classification |
| --- | --- | --- | --- | --- |
| Agents | OpenCode config and agent markdown roots | OpenCode | UI reads/writes through server; reconnecting remote UI reads the same host files | OPENCODE WRAPPER |
| Commands | OpenCode config/markdown command roots | OpenCode | same deferred reload | OPENCODE WRAPPER |
| MCP servers | OpenCode config `mcp` entries | OpenCode | same deferred reload; runtime state comes from OpenCode API/events where exposed | OPENCODE WRAPPER |
| Plugins | OpenCode config plugin entries | OpenCode | OpenChamber config UI/proxy only, except injected managed plugins below | OPENCODE WRAPPER |
| Skills | OpenCode/OpenChamber-recognized user/project roots; supporting files | OpenCode consumes skills; OpenChamber scans/CRUD/catalog installs | routes select explicit/request/active directory; remote sees host filesystem | MIXED |
| Snippets / prompt expansion | managed snippet files and config entity routes | OpenCode command/prompt handling after forwarding | OpenChamber supports CRUD and hashtag expansion | MIXED |
| Behaviors | `settings.json` | OpenChamber decides whether to inject optimizer on restart | applies only to managed process | OPENCHAMBER OWNED |

## Storage roots

`opencode/shared.js` names `OPENCODE_CONFIG_DIR`, `AGENT_DIR`, `COMMAND_DIR`, `SKILL_DIR` and supports user, project and custom configuration layers. User config is `~/.config/opencode/opencode.json`; project config is `<workingDirectory>/.opencode/opencode.json` or `opencode.json`; custom config follows `OPENCODE_CONFIG`. Provider config uses the same layering. Source: `opencode/DOCUMENTATION.md`.

## OpenChamber's managed injection

| Injection | Installation | Runtime |
| --- | --- | --- |
| `openchamber` tool | generated under `<openchamber-data-dir>/agent-tool/`, appended to `OPENCODE_CONFIG_CONTENT` | agent sends typed callback to loopback `/api/openchamber/agent-tool`; server executes fixed allowlist through shared control service |
| `openchamber_web` tool | same mechanism, separately enabled | browser panel control only |
| system prompt optimizer | generated under `<openchamber-data-dir>/system-prompt/`, appended to plugin config | replaces a detected prompt prefix for built-in build/plan agents when enabled |

The callback needs a child-only random bearer token, accepts loopback only and cannot proxy arbitrary shell, route or URL calls. It is absent for external OpenCode and VS Code. Evidence: `agent-tool/runtime.js`, `openchamber-control/service.js`.

## Other OpenChamber features around OpenCode

- **Scheduled tasks:** server-owned persistence and timers; Session creation/prompt dispatch is OpenCode. See `scheduled-tasks/runtime.js` and `project-config.js`.
- **Session Goal:** server-owned control loop and metadata, while each actual continuation is OpenCode `prompt_async`. See `session-goal/runtime.js`.
- **Session knowledge / agent memory / context obligatory:** OpenChamber modules exist under `packages/web/server/lib/`. Their exact public contracts were not fully traced in this pass and remain `UNKNOWN / NEEDS FURTHER VERIFICATION`; do not classify them as OpenCode internals based on names alone.

## Remote behavior

No separate remote MCP/Command/Skill runtime exists. A remote client invokes the selected OpenChamber host, so configuration files, reload and resulting OpenCode process all live on that host. Relay merely transports the authenticated request.
