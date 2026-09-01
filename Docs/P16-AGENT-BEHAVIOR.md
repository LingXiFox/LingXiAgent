# P16 Agent Behavior

## Scope

P16 uses the existing `SessionRuntime` tool loop. It does not add providers, workflows, tools, or LSP behavior.

## Execution Profiles

`AgentBehaviorProfile` has three modes:

| Profile | Capability policy | Required behavior |
| --- | --- | --- |
| Build | Existing workspace policy | Inspect before mutation, verify after mutation, use diagnostics to recover, inspect diff before reporting completion. |
| Plan | `readOnly` enforced by `ToolRuntime` | Gather evidence and produce an executable plan. |
| Explore | `readOnly` enforced by `ToolRuntime` | Search and report evidence, including uncertainty. |

Plan and Explore pass `SubagentExecutionProfile(permissionProfile: "readOnly")` through the same Agent Runtime and Tool Runtime as Build. Available definitions exclude mutation tools and direct mutation calls are denied by the runtime. A prompt alone is not the enforcement boundary.

The optional `agent.behaviorProfile` configuration enables the behavior system prompt. Omission preserves prior request bytes while retaining Build capability semantics.

## Agent Loop

`SessionRuntime` owns one serialized turn per Session. For each step it builds context, selects the allowed tool set, streams a model response, persists tool calls and results, then sends settled structured results back to the model for the next step.

- Tool failures and typed timeout results remain in history, so the next step can recover or state a blocker.
- Read-only duplicate calls are blocked after a successful identical read.
- Tool batches run in parallel but settle in provider order.
- Mutations are surfaced as structured results; Build instructions require narrow verification before completion.
- A turn completes only when the model finishes without tool calls. The bounded step limit fails instead of looping indefinitely.
- Question and Permission wait through their existing runtimes; Question changes the AgentRun state to `waitingForUser` and resumes after a reply.
- Subagents remain independent AgentRuns; their result is returned through the existing `subagent` tool and root-run ownership checks.

## AGENTS.md

`AgentInstructionSet` first loads the optional global `~/.lingxiagent/AGENTS.md`, then discovers UTF-8 `AGENTS.md` files below the workspace root, excluding generated/VCS dependency directories. It records source path, scope directory, and content. Files outside the resolved workspace, files reached through a link to another filename, and files larger than 64 KiB are ignored.

For a target path, applicable sources are ordered Global, project root, then root-to-leaf nested scopes. A nested scope has higher priority and overrides conflicting parent instructions. The rendered system context carries each source, scope, and priority; it directs the Agent to apply only ancestors of the target path.

Priority is deterministic:

1. Runtime safety and the active execution profile.
2. Global `~/.lingxiagent/AGENTS.md`.
3. Project root and nested `AGENTS.md`, from root to nearest target scope.
4. Current user task.

Repository instructions cannot grant a capability rejected by the active profile or runtime safety policy.

## Diagnostics

Instruction provenance appears in system context as `[AGENTS source=... scope=... priority=...]`. Existing lifecycle diagnostics remain opt-in via `LINGXI_EXECUTION_TRACE=1`; no environment or credential values are included.
