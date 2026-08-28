# Renderer 状态管理

## Layers

| Layer | Owner | Examples | Authority |
| --- | --- | --- | --- |
| React context | provider subtree | sync/runtime contexts, SDK access | wiring/lifecycle |
| Directory sync child stores | `sync-context.tsx` ChildStoreManager | Session, Message, Part, permission, question, todo | OpenCode snapshot + SSE events |
| Global stores | Zustand `packages/ui/src/stores` | projects, global Sessions, folders, Git, config, update, UI | feature cache / client state |
| Request/cache services | SDK and Runtime APIs | runtime switch, runtime fetch/socket/auth | selected OpenChamber runtime |
| Persistent client state | safe storage/localStorage | draft, viewport, pins, session snapshots, preferences | continuity only |
| Ephemeral component state | React | dialogs, input state, rendering | local UI only |

## Important state owners

- `ChildStoreManager`: lazy directory bootstrap and per-directory live data.
- `SessionMessageLoader`: initial/paged Message loading, reconciliation and retry.
- `global-session-status.ts`: incremental cross-directory busy/retry index.
- `session-ordering.ts`: activity-derived display ordering.
- `session-activity-timing.ts`: running/just-finished duration projection.
- `session-ui-store.ts`: selected Session, draft lifecycle, abort prompt and SDK-facing actions.
- `useGlobalSessionsStore`: cold/global active and archive coverage, never live stream truth.
- `input-store`, `selection-store`, `viewport-store`, `voice-store`: high-frequency or interaction-scoped UI state.
- `useGitStore`, `useGitHubPrStatusStore`, `useTerminalStore`, project/config stores: keyed feature caches.

Source: `packages/ui/src/sync/DOCUMENTATION.md`, `packages/ui/src/stores/DOCUMENTATION.md`.

## Runtime switching

`runtime-switch.ts` establishes a runtime key and changes the endpoint. SDK clients are acquired via `OpencodeService.getSdkClient()` or scoped equivalent. State and inflight work use runtime + directory + Session identity. A switch invalidates old generations so old responses/events cannot mutate the newly selected remote instance.

This is a deliberate mirror of remote server state. It is not a second business backend. Key duplicated representations are:

- OpenCode Session list: global cold cache plus live directory stores.
- OpenCode status: server derived activity state plus client global live status index.
- OpenCode Message/Part: canonical remote data plus materialized/paginated UI records.

The duplication is bounded and has explicit authority/reconciliation rules. Treat it as a future Protocol/Client concern, not proof it belongs in the core.

## Allocation for a future split, classification only

| State | Current facts imply |
| --- | --- |
| canonical Session/Message/Part/Agent/Permission | runtime/core adapter |
| event cursor/replay/reconnect contract | protocol/remote gateway |
| server activity, schedules, goal, auto-accept policy | core logic |
| directory snapshot, selected Session, drafts, tabs, scroll, dialogs | client |
| Git/FS/PTY resource state | platform adapter with protocol projection |
| settings split | server-owned operational settings vs client-only appearance/navigation preferences |
