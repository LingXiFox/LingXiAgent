# 领域依赖图

```text
Electron Main (native shell, IPC)
  -> OpenChamber Server composition root
  -> packaged UI protocol / BrowserWindows

React UI
  -> Runtime switch + runtime fetch/socket/auth
  -> OpenChamber Server
       -> UI auth / pairing / relay / tunnels
       -> event-stream bridge
            -> OpenCode SSE
       -> OpenCode proxy + lifecycle
            -> OpenCode Server
                 -> Agent, Sessions, Providers, MCP, tools
       -> project/task/goal/assist/auto-accept
            -> OpenCode HTTP APIs
       -> Git / FS / Terminal / browser / notifications
            -> OS, local filesystem, subprocesses, external APIs
```

## Dependency direction by domain

| Domain | Depends on | Must not be treated as |
| --- | --- | --- |
| UI session sync | Runtime SDK, browser event transport | canonical Session storage |
| OpenCode proxy/lifecycle | OpenCode HTTP/SSE and child process | Agent implementation |
| Goals/tasks/assist | OpenCode Session APIs/events, OpenChamber settings/small-model | OpenCode built-in capabilities |
| Config entities | OpenCode config files/process reload | independent MCP/Agent/Command runtime |
| Remote | auth, server API, event transport | direct OpenCode mobile protocol |
| Git/FS/terminal | host OS/filesystem/subprocess | renderer local capability |
| Electron | server + UI runtime bootstrap | general product business core |

## Important horizontal coupling

- **OpenCode events** fan out to UI sync, notifications, Session status/attention, Goals, assist and permission auto-accept. `global-hub.js` is the shared event seam.
- **Runtime identity** crosses stores, message queues, Git/PR caches, folders/drafts and remote transports. It prevents remote host cache collisions.
- **Directory** is the join key for OpenCode Session calls, project/worktree UI and host operations. Session record `directory` is more authoritative than a sidebar container.
- **Settings** cross operational server modules and UI preferences. It needs a split before assuming all settings have the same owner.
- **Electron** adds native affordances via preload, but remote pages are barred from most IPC by sender-origin checks.

## Cycles and risks

No direct source-level cycle was asserted without a graph query. Architecturally, the risk loops are UI state <- events <- server side effects <- OpenCode events, and configuration write -> managed OpenCode restart -> event reconnect -> UI reconciliation. The code addresses these with generation keys, `Last-Event-ID`, explicit restart interruption and authoritative refresh. See `sync/DOCUMENTATION.md`, `event-stream/DOCUMENTATION.md`, `opencode/lifecycle.js`.
