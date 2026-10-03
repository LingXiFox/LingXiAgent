# Frontend V2 — UX Mapping and Information Architecture

Phases 3–5. Inputs: the OpenChamber visual model (`01-openchamber-ux-model.md`), a full
read of `Sources/LingXi*` and `Apps/LingXiApp`, and an audit of the current GUI's bindings.

## 0. The constraint that shapes everything

LingXiAgent talks to Core over **stdio JSON-lines RPC** (`LingXiClientVNext` →
`VNextStdioCoreServer`), and a V2 frontend must not consume the raw streams. The correct
binding surface is `ApplicationStore`: it folds `subscribeSessionEvents` /
`subscribeStreamFrames` / `subscribeRuntimeEvents` into `ApplicationState` +
`ApplicationChangeSet` (13 invalidation flags, incl. `transcriptNodesChanged`) and takes
`dispatch(ApplicationAction)`. `RuntimeFrontend` already wraps that and publishes four view
models. **V2 reuses that boundary unchanged** — it is a page-structure problem, not a
transport problem.

Second constraint, and the more dangerous one: **a large part of the protocol was
declared-but-stub.** `ProtocolFeature` advertised `task.pause/resume/fork` and
`workspace.fork` as if shipped while `RuntimeCapabilities.supportedFeatures` was never
populated, so gating UI on it would have lied.

That half is now closed from the other direction: `CoreHost.swift:2905-2913` declares
`supportedFeatures: [.taskPause, .taskResume, .taskFork, .workspaceFork, .gitRPC,
.gitRemoteSync]` explicitly, and `ProtocolSurfaceParityTests.advertisedFeaturesAreWired`
checks it in both directions — an advertised feature whose methods are not wired fails,
and a fully-wired feature CoreHost does not broadcast also fails. `RuntimeEvents.swift:48`
removed the default so a producer has to state it. Gating on `supportedFeatures` is now
sound. V2 still gates on `supportedModes` plus this document's table, and every stub
renders as *unavailable*, never as an empty success state.

### Confirmed stubs — must not be shown as working

| Capability | Reality | V2 ruling |
|---|---|---|
| `submitSideQuestion` | Real streamed model call: `CoreHost.swift:34-66` guards an empty question and a missing `gateway.modelID`, builds a `ModelRequest` from the last eight session messages, streams it and accumulates `.textDelta`. Neither fabricated string named here exists anywhere in `Sources/` any more. | Reachable end to end (`agent.sideQuestion` → `TurnDomainClient` → `RuntimeFrontend.swift:1002`). Stays in Quick Ask as a separate answer path, not a turn. |
| `workspace.worktree.*` (5 RPCs) | Implemented against real git: `CoreHost+Worktree.swift:16,37,46,66,76` run `git worktree add / merge --squash / remove / -D`. All five are routed (`VNextStdioCoreServer.swift:315-319`) and advertised as `.workspaceFork`. | Reachable: `SettingsStore.swift:303` reads `client.workspace.listWorktrees()`. An empty list now means *no worktree*, and can be read as such. |
| `task.*` (11 RPCs) | Superseded by `feature-coverage.json`, which is the accurate record: `CoreHost+TaskService.swift` is a real 116-line `extension CoreHost` driving `taskRuntime` through `register / transition / getCapsule / listCapsules`, and all eleven verbs are routed. | The GUI already reaches the surface (`WarmTasksPane`). The one open piece is `task.report`, which answers `payload: nil` — an honest nil, tracked as OPEN, not closed by formatting a report. |
| Branch Prediction | `BranchPredictionRuntime` is real and Core publishes it every turn: `PredictionRuntimeSnapshot` is a field on `ContextStateSnapshot` (`Snapshots.swift:591`), populated at `CoreHost.swift:2389,2447`. It reaches TUI (`ApplicationTUI.swift:2331-2350`) and WebUI (`Assets/js/state.js:355,1700,1854`). So there *is* a diagnostic field and a transport — inside `context.state`, not as its own RPC. | macOS has no product surface for it, which is correct for a forecast that must not steer the run. It is exposed in the Runtime Observatory (`AgentLoopPane`) as observability. A dedicated `prediction.*` RPC remains unbuilt and is not needed for that. |
| `context.search` / `context.entry` | Fabrication still true: `CoreHost.swift:5773-5794` answers with `"Context search query: \(query)"` and `"Context content for \(uri)"` at `tokenCount: 42`. What changed is reachability — both are wired into the context inspector window (`RuntimeFrontend.swift:852,859`). | Exposed but carrying invented content, which is `PROTOCOL_FAKE_SUCCESS` in `feature-coverage.json` and a worse state than hiding it: a reachable panel whose numbers are made up will be believed. Real retrieval exists only as agent tools. |
| `updateContextPolicy` | Ignores the request, echoes current policy | Context policy is read-only in the GUI. |
| `installExtension` | Records a hardcoded `version:"1.0.0", kind:.plugin` entry; no download | Settings offers enable/disable/reload, never "install". |
| `agentPreset.list`, `listAgentRuns`, `multiRun.compare` | No longer hardcoded arrays: all three now `throw CoreError(code: .unsupportedCommand)` with the reason in a comment (`ProtocolService.swift:1310-1321`), precisely because an empty list would read as *no runs* rather than *unsupported*. | Still not surfaced, and that is now the honest outcome rather than a stub pretending to be one. |
| `getRunTrace.spans` → `traceEvents` | `getRunTrace` does still throw `unsupportedCommand` (`CoreHost.swift:6229-6231`) — a real trace needs a span store. But `traceEvents` *is* written: `RuntimeFrontend.swift:206` fills it from the diagnostics bundle's trace, which `TraceEmitter` genuinely produces. | The 运行轨迹 window works and is offered. What remains unsupported is the per-run span query, and the row now says so instead of calling the window empty. |
| Goal mode | No `AgentMode.goal`; `/goal` is a slash command that renders a text panel | Keep, but label it what it is: a standing instruction, not a scheduler. |
| Git branch | Both halves of the old claim are false: `git.branch` is routed (`CoreHost+GitRPC.swift:41`), and `CoreProjection.gitBranch(at:)` does not exist. The branch is Core-side — `gitRunner.status()` porcelain `status.branch` published through `WorkspaceSummary` (`CoreHost.swift:5271-5297`) and read at `CoreProjection.swift:307`. | Core state, reachable via RPC. No client-side `.git/HEAD` read anywhere. |
| Workspace diff | Truncation and untracked are still true (`CoreHost.swift:1401,1405`). *no numstat* is not: `CoreHost.swift:5418-5430` runs `git diff --numstat` and fills `addedLines / deletedLines / changedFiles`, with a note that the frontend must not count `+`/`-` out of diff text. | Show the truncation; say untracked files are not covered. Line counts come from Core, not from the client parsing text. |

## 1. Feature → UX mapping

Decision codes: **A** borrow the pattern directly · **B** borrow the information
architecture, express it in LingXi's own terms · **C** LingXi already has the better UX ·
**D** LingXi-only, needs a new design · **E** keep out of the main GUI, Settings/Advanced only.

| LingXi feature | Closest OpenChamber UX | Verdict | V2 location | Default visibility | Real source |
|---|---|---|---|---|---|
| Session list / groups | sidebar groups, draggable rows | A | Sidebar | always | `listSessions`, `SessionCatalog.timeGroups` |
| New / rename / delete session | row menu, `新建会话` | A | Sidebar row menu | hover | `createSession` / `renameSession` / `deleteSession` |
| Workspace open / recents | project chip in headline + group header | B | Sidebar head · empty-state chip | always | `setWorkspace`, `getWorkspace`, `RecentWorkspaces` |
| Git branch | shown in toolbar breadcrumb | C | Toolbar subtitle | always | `CoreProjection.gitBranch` (local `.git/HEAD`) |
| Worktree | Git dock panel | D | Settings › 工作区, marked unsupported | settings only | stub |
| Build / Plan / Explore | composer mode chip | A | Composer action bar | always | `RuntimeCapabilities.supportedModes` |
| Stop / interrupt | Send becomes Stop | A | Composer | when running | `.stopCurrentRun`, `cancelTurn` |
| Re-entry / resume | — | D | 会话 dock panel when a run is paused | when active | `resumeRun`, `runPaused`/`runResumed` |
| Revert last turn | rewind-to-message | B | User-message hover action | hover | `revertLastTurn` |
| User / assistant message | prose, user block tinted | A | Timeline | always | `MessageSnapshot` → `MessageNode` |
| Thinking | inline, no card | A | Timeline | collapsed | `visibleReasoning` stream frames |
| Tool call / result | one-line row, expandable | A | Timeline | collapsed | `ToolNode`, `ToolResultSnapshot` |
| Permission request | inline blocking surface | A | Composer head (pending slot) | when pending | `InteractionSnapshot(kind:.permission)` |
| User question / decision | inline options | A | Composer head | when pending | `QuestionRequest`, `DecisionRequest` |
| Diff / file edit | inline rows + 更改 panel | B | Timeline + Changes dock panel | collapsed | `workspace.diff`, `ToolResult.changedFiles` |
| Completion | turn footer with terminal reason | A | Timeline | always | `turnCompleted(TerminalReason)` |
| Context usage % | dock header meter | A | Context dock panel head | when turn exists | `ContextStateSnapshot.estimatedTokens` |
| **P-Core** | no equivalent | D | Context panel, first section | panel open | `PCoreStateSnapshot` |
| **E-Core** | no equivalent | D | Context panel | panel open | `ECoreStateSnapshot` (hot/cold always nil → omit) |
| **Cache Debt** | 缓存命中率 only | D | Context panel + Advanced | panel open | `ProviderCacheStateSnapshot.cacheDebt` |
| Context observability (prefix stability, bust rate, volatile tail, epoch) | 轮次统计 | B | 诊断 panel | folded | `ContextStateSnapshot` telemetry |
| Branch Prediction Fabric | none in the main GUI | D→observability | Runtime Observatory only | — | on the wire via `context.state`; no product surface, because a forecast that steered the run would stop being a forecast |
| Todo | 计划 panel | A | 会话 panel | panel open | `SessionSnapshot.todos` |
| Subagents | 轮次统计 rows | B | 会话 panel | panel open | `SubagentNode`, `getAgentTree` |
| Background tasks | 终端 panel (different thing) | B | 会话 panel | panel open | `BackgroundTaskSnapshot` |
| Workflows | none | D | 会话 panel | when present | `ApplicationState.workflows` |
| Provider / account | 用量 disclosure with per-provider status | A | 会话 panel + Settings | panel open | `listProviders`, `ProviderStatus` |
| Model + reasoning + variants | composer chip | A | Composer | always | `listModels`, `selectModel`, `ReasoningEffort` |
| Model metadata | — | C | Settings + composer tooltip | on demand | `models.lingxifox.cn/models.json` via `LingXiModelsCatalogClient` |
| MCP servers | `MCP 4/4` + per-server toggles | A | 会话 panel + Settings | panel open | `ExtensionInfo(kind:.mcp)` |
| Skills / Plugins / Hooks | 上下文来源 counts | B | 会话 panel counts; management in Settings | panel open | `ExtensionInfo` |
| Computer Use | none | E | Settings only | settings only | `computer_batch` |
| Browser | 浏览器 dock panel | E | Settings only | settings only | `browser_navigate` / sidecar |
| Settings | 3-column modal | A | Modal sheet | transient | `config.json` + `preferences.json` + `UserDefaults` |

## 2. Frontend V2 information architecture

```
WorkbenchShell  (NavigationSplitView + .inspector)
├─ Sidebar                                   reuse SidebarView
│   workspace head · search · session groups · footer(settings/stats)
│
├─ Stage                                     reuse MainStageView / ReadingColumn
│   ├─ EmptyWorkspaceStage   headline+project chip · composer · starters
│   ├─ TimelineStage         prose column 720pt, turn-grouped, tools inline & collapsed
│   │                        user block · thinking · tool · result · diff ·
│   │                        permission · question · tasks · assistant · completion
│   └─ ComposerDock          pending interaction · /suggestions · editor · action bar
│
└─ WorkbenchDock  (NEW)  ── 40pt DockRail
    ├─ 会话        run status · context meter · todos · subagents · workflows ·
    │              background tasks · providers health · MCP · skills count
    ├─ 上下文      P-Core · E-Core · Provider cache · Cache Debt · tokens/rate
    ├─ 变更        branch · root · per-file diff (truncation and untracked caveats shown)
    └─ 诊断        link · prefix stability · bust rate · epoch · compaction history
```

Structural changes actually made by V2, and why:

1. **Three-tab inspector → rail + tabbed dock.** Ten secondary tools cost 40pt of rail
   width and zero vertical space. This is what lets the timeline stay prose-first instead
   of absorbing telemetry.
2. **Settings in-place swap → modal workbench** with an object column for the pages that
   genuinely are collections (`providers`, `mcp`, `skills`, `plugins`, `hooks`). The column
   drives the existing `settingsHighlight` anchor plumbing, so selecting an object scrolls
   and washes its row. Pages without a real object list stay two columns rather than
   growing a decorative one.
3. **No new mock surface.** Where Core has nothing, V2 says so. The one live violation
   found (`submitSideQuestion`) is called out below.

## 3. Deferred to Core, not fixable in V2

Closed since this list was written — Branch Prediction now travels inside `context.state`
and renders in TUI, WebUI and the Observatory; `task.*` and the five worktree RPCs are
implemented and routed; side-question is a real streamed model call; `supportedFeatures`
is populated and contract-checked; `git.branch` is a Core RPC.

Still owned here, and unchanged by that: `getRunTrace.spans` (needs a span store; the
handler throws rather than inventing two spans); E-Core hot/cold counts
(`CoreHost.swift:2409-2415` passes `nil` for both, and `structuralPrefixStability` can
only ever be 0.0 or 1.0); `observedGranularity`, hardcoded nil at `CoreHost.swift:2442`
with no producer anywhere; `context.search` / `context.entry` payload, reachable but
fabricated; `updateContextPolicy` echoing rather than applying; `installExtension`
recording a hardcoded entry; `task.report` answering `payload: nil`; and model
`cost`/`modalities`, which the discovery DTOs now carry but which this document cannot
confirm reaches the product, because the `cachedModelsForProduct` named here does not
exist in `Sources/` any more.

The Runtime Observatory reads all of these out of Core unchanged and labels their
provenance, so `observedGranularity` and the two nil hot/cold counts are now *visible* as
unknown instead of being absent from view. That is a difference from hiding them, not a
fix: none of them became measurable by being displayed.
