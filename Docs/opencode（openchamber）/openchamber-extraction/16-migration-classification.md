# 分类矩阵

这是当前能力的分类，不是 LingXiAgent 设计。

| Current capability | Current classification | LingXi Core candidate | Protocol candidate | macOS Client candidate | Remote Gateway candidate | Platform Adapter candidate | Remove candidate |
| --- | --- | --- | --- | --- | --- | --- |
| OpenCode Session/Message/Part API adapter | OPENCODE WRAPPER | adapter coordination | Session/event contract | rendering/cache | remote API proxy | no | only when OpenCode replaced |
| OpenCode child lifecycle | SERVER GLUE | lifecycle policy | status/control | status UI | no | process spawn | no while adapter exists |
| Agent loop / tools / MCP runtime | OPENCODE WRAPPER | no current ownership | API contract only | UI | no | no | only with a replacement runtime |
| Session UI sync/cache | CLIENT UI | no | event/reconciliation contract | yes | no | no | no |
| Goal, scheduled task, assist, auto-accept | OPENCHAMBER CORE LOGIC | yes | control/events | controls | authenticated remote access | no | optional product scope |
| project context/folders | OPENCHAMBER CORE LOGIC | yes | project APIs | views | host API | filesystem storage | optional product scope |
| provider config/auth UI | OPENCODE WRAPPER | adapter policy only | config contract | yes | host API | credential access | no while OpenCode used |
| quota dashboard | OPENCHAMBER OWNED | optional | quota payload | yes | host API | credential sources | yes if feature dropped |
| Git | OPENCHAMBER OWNED | orchestration policy | Git operations | UI | host API | OS git | yes if external Git client only |
| filesystem | OPENCHAMBER OWNED | access policy | FS operations | UI | host API | filesystem | no for code workspace product |
| terminal/PTTY | OPENCHAMBER OWNED | terminal lifecycle | WS protocol | terminal UI | host proxy | PTY/process | optional |
| Relay, pairing, client auth | REMOTE SERVICE | identity/policy | pairing/auth/event protocol | onboarding | yes | key storage | only if remote removed |
| Cloudflare/ngrok tunnels | SERVER GLUE | no | connect URL data | settings UI | optional | provider subprocess | yes if Relay/direct only |
| notifications | REMOTE SERVICE | trigger policy | push payload | permission/settings UI | delivery routing | APNs/native notice | optional |
| Electron windows/updater/SSH | PLATFORM SERVICE | no | desktop bridge only | native UI | no | yes | web-only deployment |
| Appearance / drafts / navigation | CLIENT UI | no | no | yes | no | desktop image picker only | no |
| static web/PWA hosting | LEGACY/CLIENT HOSTING | no | no | web client only | optional | no | when not serving web |
| LingXi Sub2API quota/background/motion/patch graph | LINGXI CUSTOM | decide per feature | only if cross-client | likely visual parts | quota remote if retained | desktop background | optional |

## Minimal preservation statement

If OpenCode Server remains, preserving basic chat needs an authenticated adapter to its directory-scoped REST/SSE APIs, event resume/reconciliation, Session directory routing, config/model selection, attachment transport and a client UI. Preserving today's multi-device product additionally needs the Remote Gateway rows. Every other row is an independent product decision; none should be silently assumed necessary because it exists in OpenChamber.
