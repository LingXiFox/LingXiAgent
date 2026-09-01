# P16 Acceptance

## Deterministic Coverage

- `AgentBehaviorTests/buildRecoversFromFailedVerificationAndCompletes`
  - Read source, mutate, run a failing verification, repair, verify, and complete.
- `AgentBehaviorTests/planAndExploreRejectMutationAtRuntime`
  - Plan and Explore do not expose mutation tools and reject a direct mutation call without changing the workspace.
- `AgentBehaviorTests/nestedAgentInstructionsHaveScopedPrecedenceAndProvenance`
  - Verifies root and nested scope selection, nearest-scope precedence, and source/scope priority rendering.
- Existing `AgentToolLoopTests`
  - Verifies structured tool recovery, bounded loops, duplicate suppression, batch settlement, and Question pause/resume.
- Existing `SubagentRuntimeTests`
  - Verifies child delegation, result routing, question escalation, recovery, and limits.

## Required Gates

| Gate | Result |
| --- | --- |
| `swift build` | PASS |
| P16 specialist tests | PASS |
| Agent loop regression | PASS |
| Golden replay | PASS |
| `swift test --no-parallel` | PASS |
| `swift test` | PASS |
| Parallel stability | PASS |
| Golden unchanged | PASS |
| `git diff --check` | PASS |
| Trivy | 0 findings |
