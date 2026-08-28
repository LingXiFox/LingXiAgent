# Agent Runtime 边界

## Judgement

OpenChamber is **B. Agent Runtime wrapper plus C. Agent UI**, with several server-side orchestration features. It is not the primary Agent Runtime.

OpenCode executes the normal Agent loop, picks/executes its tools, constructs its canonical prompts, owns agent definitions at runtime, publishes Session status and writes tool/reasoning Parts. OpenChamber invokes those APIs, observes their events, and adds product-level loops and tools.

## Evidence

| Question | Answer | Evidence |
| --- | --- | --- |
| Who runs the Agent loop? | OpenCode Server | UI observes `session.status`, `message.part.*`; server only proxies and consumes SSE. `sync-context.tsx`, `opencode/proxy.js` |
| Who defines normal agents? | OpenCode config/runtime | `config-entity-routes.js` persists agent config for OpenCode reload. |
| Who builds normal system prompt? | OpenCode | OpenChamber optimizer can replace part only when it owns the child process. `system-prompt/runtime.js` |
| Who selects normal tools/subagents? | OpenCode | no OpenChamber execution loop for normal turns found. |
| Who reports running/thinking/idle? | OpenCode status/events; OpenChamber derives display activity | `session-runtime.js`, `global-session-status.ts` |
| Who stops a normal Agent? | OpenCode Session API | UI action/SDK invokes it; Goal pause adds a product-level abort. |

## OpenChamber orchestration that is real business logic

- `session-goal/runtime.js` observes idle Sessions, audits progress with its small-model service and submits `prompt_async` continuations. It is a server loop that survives disconnected UIs.
- `scheduled-tasks/runtime.js` creates a Session and calls `prompt_async` at scheduled times with cross-process occurrence locking.
- `session-assist/runtime.js` produces recap/suggestion metadata after an idle delay.
- `permission-auto-accept/runtime.js` observes OpenCode permission events and sends replies under persisted policy.
- `agent-tool/runtime.js` injects an `openchamber` custom tool into a **managed** OpenCode process. Its fixed allowlist controls OpenChamber projects, Sessions, worktrees and schedules; it does not turn OpenChamber into the Agent runtime.
- `system-prompt/runtime.js` optionally injects a managed plugin that transforms one portion of the prompt for built-in build/plan agents.

## Managed versus external runtime

Only when OpenChamber spawns OpenCode may it inject the custom `openchamber`/`openchamber_web` tools or managed system-prompt plugin. For `OPENCODE_HOST`, `OPENCODE_SKIP_START` and VS Code's independent lifecycle, injection is intentionally absent. Evidence: `agent-tool/DOCUMENTATION.md`, `system-prompt/DOCUMENTATION.md`, `opencode/lifecycle.js`.

## Behavior settings

“Behaviors” are primarily OpenChamber product settings that control additions around OpenCode, notably the opt-in `optimizeSystemPrompt` managed plugin. They are not evidence that OpenChamber owns OpenCode's standard plan/build behavior. The plugin preserves project instructions, MCP instructions, skills, history and tool set, and leaves a prompt unchanged if its boundary is not found.
