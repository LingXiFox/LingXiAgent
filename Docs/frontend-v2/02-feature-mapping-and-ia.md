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

Second constraint, and the more dangerous one: **a large part of the protocol is
declared-but-stub.** `ProtocolFeature` even advertises `task.pause/resume/fork` and
`workspace.fork` as if shipped while `RuntimeCapabilities.supportedFeatures` is never
populated. Gating UI on `RuntimeCapabilities` would therefore lie. V2 gates on
`supportedModes` plus a hand-authored capability table, and every stub renders as
*unavailable*, never as an empty success state.

### Confirmed stubs — must not be shown as working

| Capability | Reality | V2 ruling |
|---|---|---|
| `submitSideQuestion` | Core default returns fabricated `"Processed side question: …"` with `modelUsed:"side-runner"` | **Live mock in the shipping path.** Quick Ask must say it is unsupported until Core implements it. |
| `workspace.worktree.*` (5 RPCs) | Protocol default only; no CoreHost impl, no route; `listWorktrees()` always `[]` | Worktree section must read *不受支持*, not *没有 worktree*. |
| `task.*` (11 RPCs) | Rich DTOs and a real `TaskRuntime` actor exist but `TaskRuntime` is never referenced by `CoreHost`; no `task.*` route | TaskCapsule surface stays out of the GUI. `/tasks` remains background shell tasks, labelled as such. |
| Branch Prediction | `VariableOrderMarkovPredictor` is a real algorithm and `PredictionSnapshot` a real DTO, but there is **no RPC, no event case, no diagnostic field** | Cannot be bound. No prediction UI in V2; recorded as Core debt. |
| `context.search` / `context.entry` | Return a fabricated snippet and `"Context content for <uri>"`, `tokenCount: 42` | Not exposed. Real retrieval exists only as agent tools. |
| `updateContextPolicy` | Ignores the request, echoes current policy | Context policy is read-only in the GUI. |
| `installExtension` | Records a hardcoded `version:"1.0.0", kind:.plugin` entry; no download | Settings offers enable/disable/reload, never "install". |
| `agentPreset.list`, `listAgentRuns`, `multiRun.compare` | Defaults / hardcoded arrays | Not surfaced. |
| `getRunTrace.spans` → `traceEvents` | `traceEvents` is declared and read by `TraceWindowView` but **never written anywhere** | Trace window is permanently empty today. Must state that plainly or not be offered. |
| Goal mode | No `AgentMode.goal`; `/goal` is a slash command that renders a text panel | Keep, but label it what it is: a standing instruction, not a scheduler. |
| Git branch | No RPC; `CoreProjection.gitBranch(at:)` reads `.git/HEAD` locally | Real data, client-side. Fine, but it is not Core state. |
| Workspace diff | `getWorkspaceDiffSummary` runs `git diff` vs HEAD, truncated at 20 000 chars, no untracked, no numstat | Show the truncation, and say untracked files are not covered. |

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
| Branch Prediction Fabric | none | D→blocked | not in V2 | — | no transport |
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

Recorded so the gap is owned rather than papered over: Branch Prediction transport;
`task.*` routes; worktree RPC; `getRunTrace.spans`; E-Core hot/cold counts; model
`cost`/`modalities` decoded then dropped by `cachedModelsForProduct`; side-question
execution; `supportedFeatures` population.
