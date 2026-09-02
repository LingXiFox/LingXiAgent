# P18 Subagent Workflow

## Durable state

`WorkflowSnapshot` is the single recoverable workflow fact. It contains immutable task definitions, dependency IDs, per-task status/result, canonical parent and child provenance, pending human input, and a monotonically increasing checkpoint.

SQLite schema v5 writes the snapshot and normalized `workflow_tasks`, `workflow_dependencies`, and `workflow_pending_inputs` rows in one transaction. A checkpoint is updated with every state transition. A terminal `SubagentResult` records the originating child Session and Run on the task.

## Scheduling

`WorkflowRuntime` validates duplicate IDs, missing dependencies, self dependencies, and cycles before it persists a workflow. It only releases a pending agent Task when every dependency is `completed`. Sibling-ready Tasks are released together; the existing `AgentRuntime.spawn` path supplies canonical child Sessions, model/profile isolation, child deadline clamping, and `AgentRunScheduler` concurrency limits. A failed, cancelled, timed out, or blocked prerequisite marks pending descendants `blocked`.

Each task carries explicit `role`, `instructions`, `context`, `ModelSelection`, and `SubagentExecutionProfile`. The runtime renders only that task's fields into its child request; sibling session histories are never reused.

## Recovery

Completed tasks remain completed and are never resubmitted. Waiting Question, Permission, and Decision states retain their structured request plus origin provenance; continuations themselves are deliberately not persisted. A running task becomes `recoveryRequired` after Core restart and cannot be scheduled until an operator explicitly acknowledges recovery. This prevents blind replay of a task with unknown side effects.

## HITL routing

When a workflow child starts, its canonical child Session/Run is checkpointed before waiting for the result. Core routes Question by origin Run and Permission by origin Session to the matching workflow task. The workflow retains the pending input for presentation and later reattachment; ownership remains with the originating child, not the root session.
