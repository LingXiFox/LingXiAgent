# OpenChamber Server

## Why it exists

The server converts one OpenCode runtime into a complete multi-device product. It holds OS/filesystem/provider credentials and process lifecycle close to the machine, then exposes a guarded browser/remote API. It also makes the desktop, web server and Capacitor clients share the same backend behavior.

`packages/web/server/index.js` is the composition root. It wires dependency-injected module runtimes, route registration, OpenCode proxy/lifecycle, event stream, tunnel/relay and graceful shutdown. `feature-routes-runtime.js` lazy-loads some features. Evidence: `index.js`, `opencode/DOCUMENTATION.md`.

## Responsibility matrix

| Responsibility | What it does now | Future classification only |
| --- | --- | --- |
| OpenCode lifecycle/proxy | starts managed child, health/restart, auth headers, forwards HTTP/SSE | SERVER GLUE / runtime adapter |
| UI/client auth | password, cookie, passkey, bearer, pairing/client revocation | REMOTE GATEWAY |
| Event bridge | upstream SSE reader, browser WS fanout/replay, server side effects | PROTOCOL / REMOTE GATEWAY |
| Settings / custom themes | `settings.json`, migrations, validation, asset safety | CORE LOGIC + client preference split needed |
| Projects/context/folders | project config, notes/todos/plans, folders | CORE LOGIC |
| Session Goal/assist/tasks/auto accept | server loops and policy | CORE LOGIC |
| Git/FS/terminal/browser | machine-local operations | PLATFORM ADAPTER with server API today |
| Notifications | web push, APNs, desktop/SSE emission | REMOTE SERVICE / platform adapter |
| Tunnels/Relay | external reachability and pairing candidates | REMOTE GATEWAY |
| Update endpoints | web package update and restart coordination | LEGACY/PLATFORM SERVICE |
| Static assets/PWA manifest | serves web UI, PWA config/shortcuts | CLIENT HOSTING, removable from a non-web core |
| Quota / small model / walkthrough | OpenChamber product logic around provider credentials | CORE LOGIC |

## What it adds beyond OpenCode

- UI authentication, trusted device pairing and remote lifecycle.
- managed OpenCode lifecycle and managed plugin/tool injection.
- browser WebSocket event transport on top of OpenCode SSE.
- non-Agent product services: projects, scheduled tasks, Goal Mode, notes, folders, auto-accept, notifications, tunnel/relay.
- host features: Git, filesystem, terminal, browser panel, dictation/TTS, GitHub integration, update control.

Thus it is a real backend, although it delegates the central Agent conversation model and runtime to OpenCode.

## Process and persistence evidence

The composition root defines `SETTINGS_FILE_PATH`, `REMOTE_CLIENTS_FILE_PATH` and `CLIENT_PAIRING_SESSIONS_FILE_PATH` under `OPENCHAMBER_DATA_DIR`. It registers `createRemoteClientAuthRuntime` and the other owning modules. There is no OpenChamber general Session database or SQLite layer in the inspected server.

## Server API grouping

- **OpenCode boundary:** generic proxy, SSE forwarding, OpenCode/provider config/auth, status/health, managed restart/upgrade.
- **Client security:** auth session, passkey, pairing, client tokens, candidate refresh.
- **Workspace:** project config/context/folders, files, Git, terminal, browser control, GitHub.
- **Automation:** goals, scheduled tasks, assist, permission auto-accept, OpenChamber control endpoint/agent tool.
- **Connectivity:** remote instances, tunnel profiles/status, private Relay.
- **Presentation/device support:** notification stream/push/APNs, TTS/dictation, PWA manifest, custom themes, static assets, updates.

See module-level evidence in `packages/web/server/lib/*/DOCUMENTATION.md`.
