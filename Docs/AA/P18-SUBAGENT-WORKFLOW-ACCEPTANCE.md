# P18 Durable Workflow Acceptance

## Deterministic coverage

- `WorkflowRuntimeTests/checkpointRestartPreservesCompletedDependenciesPendingInputsAndProvenance`
  - Persists and restores a completed child result, branch/join dependency state, and pending Question, Permission, and Decision records without changing originating child IDs.
- `WorkflowRuntimeTests/runningTaskRequiresExplicitRecoveryAcknowledgement`
  - Converts only an interrupted running task to `recoveryRequired`; it is not automatically replayed.
- `WorkflowRuntimeTests/branchJoinRunsBranchesBeforeJoinAndDoesNotRepeatCompletedTasks`
  - Releases A/B together, keeps D unavailable until both complete, then releases D exactly once.

## Verification

| Gate | Result |
| --- | --- |
| `swift build` | PASS |
| `swift test --filter WorkflowRuntimeTests` | PASS |
| `swift test --no-parallel` | PASS |
| `git diff --check` | PASS |
