# 运行拓扑

## 进程和服务

| Component | How it starts | Process boundary | Evidence |
| --- | --- | --- | --- |
| Electron Main | Electron entry `packages/electron/main.mjs` | Native desktop process | `packages/electron/README.md` |
| OpenChamber Server in Desktop | Main imports `@openchamber/web/server/index.js`, calls `startWebUiServer()` | **In-process**, not a sidecar | `packages/electron/README.md`, `main.mjs` |
| OpenChamber Server in web/CLI | `packages/web/bin/cli.js` -> serve command -> server bootstrap | CLI process, optionally daemon/service | `packages/web/bin/lib/DOCUMENTATION.md` |
| OpenCode Server, managed mode | OpenChamber lifecycle resolves a CLI and spawns/manages it | Separate child process | `packages/web/server/lib/opencode/lifecycle.js`, `env-runtime.js` |
| OpenCode Server, external mode | `OPENCODE_HOST` / `OPENCODE_SKIP_START` | External process/service | `packages/web/README.md`, `env-config.js` |
| React renderer | Web asset, Electron BrowserWindow, PWA, mobile webview | Browser renderer | `packages/web/src/{main,mobile-main,mini-chat-main}.tsx` |
| Capacitor mobile | Native shell around mobile web assets and an existing server | Native shell + browser view | `packages/mobile/README.md`, `capacitor.config.ts` |

OpenChamber Server is independent from Electron as a runtime, but Electron Desktop deliberately hosts it in the Electron main process. CLI/headless installations host the same server outside Electron.

## Managed OpenCode lifecycle

`createOpenCodeLifecycleRuntime()` owns `startOpenCode()`, `restartOpenCode()`, readiness polling, health monitoring, port release and kill-on-port behavior. It chooses the binary through explicit settings, environment overrides, bundled Desktop CLI, PATH and platform discovery. It injects OpenChamber plugins only into a managed child process. External OpenCode is never injected or restarted by OpenChamber.

Call direction:

```text
server startup pipeline
  -> OpenChamber listener binds and publishes port
  -> lifecycle.bootstrapOpenCodeAtStartup()
  -> managed child: opencode serve ...
  -> readiness / health monitoring
  -> proxy admits browser requests
```

The listener binds before managed OpenCode starts so the injected `openchamber` tool receives the final loopback callback URL even when port `0` was requested. Evidence: `startup-pipeline-runtime.js`, `agent-tool/runtime.js`, `opencode/DOCUMENTATION.md`.

## Transport map

| Link | Protocol | Purpose | Scope |
| --- | --- | --- | --- |
| UI -> OpenChamber Server | HTTP, browser WS, SSE | OpenChamber APIs and proxied OpenCode APIs | local and remote |
| OpenChamber -> OpenCode | HTTP + SSE | API proxy, `/global/event`, `/event?directory=...`, health checks | server-local / configured external host |
| Server -> Browser | WebSocket | `/api/global/event/ws`, `/api/event/ws`; browser-oriented translation of upstream SSE | local and remote |
| UI -> terminal | WebSocket | `/api/terminal/ws` | local and remote |
| Desktop renderer -> Electron Main | IPC through preload | native-only commands | Electron only |
| Remote client -> Relay -> host server | outbound WebSocket, E2EE, multiplexed HTTP/SSE/WS | NAT traversal | Relay only |
| Server -> tunnel provider | provider subprocess/connection | public URL exposure | optional |

OpenCode remains SSE based. The WebSocket layer is an OpenChamber browser transport bridge, not an OpenCode API change. Evidence: `packages/web/server/lib/event-stream/DOCUMENTATION.md`.

## Direct access question

The React UI normally obtains an SDK client configured for the selected OpenChamber runtime through `OpencodeService.getSdkClient()` / `getScopedSdkClient()` in `packages/ui/src/lib/opencode/client.ts`. For a local/remote OpenChamber runtime that SDK base URL is OpenChamber, then `/api/*` is proxied to OpenCode. Therefore normal product clients do **not** directly target the managed OpenCode server.

An external OpenCode can be attached behind an OpenChamber Server, but the UI still uses OpenChamber as its product endpoint. Direct raw OpenCode use is possible only outside this product flow and loses OpenChamber services and authentication policy.

## Lifecycle after close

| Situation | Services remaining |
| --- | --- |
| Close a browser tab/PWA | Server, managed OpenCode, scheduled tasks, goals, auto-accept and remote host remain alive if server process remains alive. |
| Close Electron window but app stays in tray | Same as above. |
| Quit Electron | In-process OpenChamber Server shuts down; its managed OpenCode child is terminated by graceful shutdown. |
| Stop CLI server | Its managed child is terminated; external OpenCode is not owned or stopped. |
| External OpenCode | Continues independently of OpenChamber. |

Evidence: `shutdown-runtime.js`, `lifecycle.js`, Electron tray/window lifecycle in `main.mjs`. Exact behavior for a platform-specific forced crash is `UNKNOWN`.
