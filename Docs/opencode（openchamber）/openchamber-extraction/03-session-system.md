# Session 系统

## Canonical ownership

OpenChamber treats OpenCode as the canonical owner of Session, Message, Part, Session status and permission/question records. The UI directly uses OpenCode-shaped SDK records. OpenChamber does not introduce a second Session ID or an ID mapping layer.

Evidence:

- `session-actions.ts` calls SDK Session APIs and stores the returned record unchanged enough to use its `id` and `directory` as authority.
- `SessionMessageLoader` keys records by runtime + normalized directory + OpenCode session ID.
- Server routes such as `openchamber-sessions/routes.js`, session goal and scheduled task create Sessions via OpenCode HTTP APIs.
- `sync/DOCUMENTATION.md` explicitly describes official OpenCode APIs as the source of directory session/message/part/permission/question state.

The exact algorithm that generates a Session ID is inside OpenCode and out of scope. `OpenChamber generates no alternate ID`: **confirmed at the boundary**. `OpenCode's persistence schema`: **UNKNOWN / not inspected**.

## End-to-end turn

```text
Composer / session action
  -> OpencodeService scoped SDK client
  -> OpenChamber /api/session/:sessionId/message or generic /api proxy
  -> OpenCode directory-scoped Session API
  -> canonical Session/Message/Part storage and Agent execution in OpenCode
  -> OpenCode SSE /global/event and /event?directory=...
  -> OpenChamber SSE reader / shared global hub
  -> browser WS bridge or proxied SSE
  -> sync-context.tsx ordered reducer batch
  -> directory Zustand child store + targeted message projection
  -> chat, sidebar, permission/question UI
```

`POST /api/session/:sessionId/message` is a special forwarder in `opencode/proxy.js`; it does not create an OpenChamber message model. It has long-request handling appropriate for streamed chat. Generic OpenCode routes are also forwarded by the proxy.

## Creation, routing and directory binding

| Operation | Executor / canonical result | OpenChamber contribution |
| --- | --- | --- |
| Create | OpenCode Session create API returns Session and canonical `directory` | `session-actions.createSession()` updates local/global caches; managed Chat prepares a dedicated local directory before creation. |
| Prompt/send | OpenCode message/prompt API | UI prepares parts/optimistic UI; proxy forwards; queue handles ambiguous transport failure without duplicate resend. |
| Abort | OpenCode Session API | UI owns confirmation and cache projection. Server Goal pause may also trigger abort. |
| Retry, revert, fork, delete, archive, title/share update | OpenCode Session APIs | `session-actions.ts` resolves authoritative session directory and updates global cache after confirmation. |
| Summarize | OpenCode capability if exposed by its SDK | No OpenChamber reimplementation found. |
| Scheduled create/prompt | OpenCode create + `prompt_async` | OpenChamber scheduler selects execution inputs, persistence and occurrence lock. |

The server may canonicalize a requested worktree path. `getDirectoryForSession()` and `session-directory-resolution.ts` rank the returned Session's own `directory` over selected/persisted hints. A project store may contain worktree Sessions, but that containment must not be used as ownership.

## Streaming and state

OpenChamber consumes OpenCode SSE upstream. `createGlobalMessageStreamHub()` owns one shared `/global/event` reader for server side effects and global browser WebSockets. Directory WS connections own scoped `/event?directory=...` readers. The reader tracks `Last-Event-ID`, detects stalls and reconnects. Event classes carried to the UI include:

| Event family | Client data changed |
| --- | --- |
| `session.created`, `session.updated`, `session.deleted` | Session list, permission/todo/part cleanup when needed |
| `session.status` | live phase, global busy/retry index, activity timing |
| `session.diff` | diff record |
| `message.updated`, `message.removed` | Message and Part records |
| `message.part.updated`, `message.part.removed`, `message.part.delta` | streamed text, reasoning, tools/files and per-part state |
| `permission.asked`, `permission.replied` | pending approval projection |
| `question.asked`, `question.replied`, `question.rejected` | pending question projection |
| `todo.updated`, `lsp.updated`, `vcs.branch.updated` | respective sidecars |

Source: `packages/ui/src/sync/DOCUMENTATION.md`, `sync-context.tsx`, `event-reducer.ts`, `event-stream/DOCUMENTATION.md`.

The server's `createSessionRuntime()` derives OpenChamber-only session activity, attention, notification and restart-interruption state from those events. It does not become the canonical message store. Its synthetic events include `openchamber:session-status`, `openchamber:session-activity`, `openchamber:notification` and heartbeat.

## Message, Part, tool and reasoning data

| Concept | Canonical source | OpenChamber handling |
| --- | --- | --- |
| Session | OpenCode | Directory child store, global cache, selected-session UI state |
| Message | OpenCode | `SessionMessageLoader` pages and materializes chronological records |
| Part | OpenCode | keyed/ordered part buckets; delta updates are throttled before Markdown rendering |
| Tool call/result | OpenCode Part records | rendered as tool cards; terminal/Git refresh hints may be OpenChamber additions |
| Reasoning | OpenCode Part records | streamed/rendered as reasoning parts; no separate OpenChamber reasoning store |
| Permission/question | OpenCode records/events | UI projection; server auto-accept can reply through OpenCode API |
| Agent State | OpenCode `session.status` plus OpenChamber derived activity | UI labels/status; server tracks active count and attention |
| Usage | completed OpenCode assistant message metadata | UI display and OpenChamber derived goals/usage views |

`SessionMessageLoader` guarantees chronological Messages by `message.time.created`, not lexical ID order; Part arrays preserve upstream response/event order. It carries pagination, retries, reconciliation and stale-generation rejection.

## Persistence and reload

OpenChamber persists only UI continuity and its own metadata, not canonical transcripts:

- directory Session snapshot in browser localStorage, bounded to 50 current records;
- bounded active managed-Chat snapshot in `useGlobalSessionsStore`;
- local UI state such as drafts, todos, pins, folders, selection and viewport state, all scoped by runtime/directory/session;
- OpenChamber metadata in Session metadata fields such as `metadata.openchamber.goal` and `.assist`, written back through OpenCode Session update;
- managed Chat directory at `~/.config/openchamber/chats/YYYY-MM-DD/session-<id>`.

On reload, stale UI snapshots may paint first but only a successful OpenCode fetch replaces them authoritatively. A failed fetch must not be treated as an empty Session list. Evidence: `sync/DOCUMENTATION.md` sections “Directory bootstrap scheduling”, “Session message loading” and “Managed chat directories”.

## Local versus remote Session

The record model stays OpenCode-shaped. A runtime identity differentiates hosts. The client reconfigures endpoint and invalidates old generations through `runtime-switch.ts`; all caches and queued work use runtime + directory + session ID, because equal IDs from distinct runtimes must not collide. A remote Session is a Session reached through a remote OpenChamber runtime, direct URL, SSH forward or Relay, not a second Session type.

## Abstract domain model

| Concept | Meaning in current product | Ownership |
| --- | --- | --- |
| Session | Conversation/task container tied to a directory, optional parent Session and metadata | OpenCode |
| Message | User/assistant lifecycle record | OpenCode |
| Part | Ordered units in a message: text, reasoning, tool, file and more | OpenCode |
| ToolCall | Tool-related Part state and result | OpenCode |
| Reasoning | Reasoning Part content | OpenCode |
| AgentState | OpenCode status; OpenChamber derives activity/attention presentation | MIXED |
| Permission | OpenCode approval record; OpenChamber policy can respond | MIXED |
| ProjectBinding | Session `directory`, mapped in UI to OpenChamber project/worktree configuration | MIXED |
| RuntimeBinding | Current OpenChamber endpoint/transport identity | OpenChamber |
| Usage | OpenCode assistant-message token/cost fields; OpenChamber displays/derives it | MIXED |

## Open questions

See `17-open-questions.md` for OpenCode-side table/schema, exact summarize/retry API, and upstream persistence retention details.
