# GUI Automation Composer Path

Status: `GUI_AUTOMATION_COMPOSER_PATH = READY`.

## Product path

`lingxiagent gui` uses same-user UNIX IPC to the running macOS GUI. The GUI controller writes `RuntimeFrontend.composerModel.text`, which is the real SwiftUI/NSTextView binding. The native editor must draw in a visible, non-occluded window and acknowledge the same draft revision after a display-frame boundary. The controller then calls `RuntimeFrontend.submitComposer()`, also used by the user's Send button and Return key. That action clears the real draft and dispatches the normal ApplicationStore submit intent.

No fixed sleep determines presentation correctness. Merely assigning a draft or yielding a Task cannot release the boundary. A hidden editor remains pending until actual presentation or cancellation.

A nonempty draft (including whitespace) or attached files returns `composerOccupied`, without replacement. Goal-input mode and an active turn also reject automatic submission. User edits, Escape, the GUI Stop button, session/workspace changes, disconnects and cancellation release pending waits without sending the draft. Cancellation preserves the visible draft so the user can inspect/edit it. `gui cancel` cancels automation; use the normal GUI Stop action to stop an already executing turn.

`BenchmarkController.run` shares the same controller and performs each full Composer sequence, then waits for a terminal turn before filling the next task. Failed/cancelled turns stop the batch. If the user types a new draft between tasks, the next task returns `composerOccupied`.

Source and task IDs exist only in GUI IPC results and the bounded automation trace (latest 4096 events). They are never added to the submitted message or execution intent.

## Commands

```sh
lingxiagent gui send "运行全部测试"
lingxiagent gui batch /tmp/tasks.json
lingxiagent gui batch /tmp/tasks.json --benchmark
lingxiagent gui status
lingxiagent gui trace
lingxiagent gui cancel
```

Batch JSON is an array of unique task IDs and exact message text:

```json
[
  {"id":"T001","text":"第一轮任务"},
  {"id":"T002","text":"第二轮任务"}
]
```

For deliberate visual inspection, `--pause-before-send` is available in Developer Debug or explicit benchmark mode. It pauses only after real presentation; `gui resume` then uses the common Send action. Normal sends and batches proceed automatically without this flag. `--` preserves literal option-looking message arguments. There is no `--replace-draft` support.

Exit codes: 0 accepted, 2 GUI rejection, 1 CLI/IPC error. The GUI must already be running with a connected workspace; the CLI never starts an independent Core as a fallback.

## Verification on macOS, 2026-10-03

- GUI and CLI built locally; the signed bundled GUI was relaunched.
- Actual provider: LM Studio `qwen3.8-9b-q6k`, runtime context 65536.
- Eight-line CLI draft visibly appeared in the native Composer, increased editor height, and received keyboard focus. Presentation revision was 1. Clicking the GUI Stop button returned `cancelled`, retained the draft, and created no Turn. A subsequent send returned `composerOccupied`.
- Normal CLI send produced presentation/draft revision 3, cleared Composer, inserted the exact User Message, and completed a real Agent Turn with `COMPOSER_SEND_OK`.
- Visually inspected benchmark T001 and T002 at revisions 5 and 7. Each text was visible before Send; each turn completed before the next draft. Both returned `completed`.
- A second two-task batch without any pause also completed automatically at revisions 9 and 11.
- All successful tasks had strict trace order: `automation.command_received`, `composer.draft_set`, `composer.presented`, `composer.send_invoked`, `turn.created`; batch tasks additionally had `turn.terminal` before the next command.
- The final bundle was relaunched again; a fresh-session automatic batch completed both tasks at revisions 1 and 3, with Composer empty afterward.
- 16 Composer/IPC tests and 66 existing GUI/Application regression tests passed. Tests cover the real SwiftUI draft binding and native presentation, occupied drafts, stale acknowledgements, Stop/edit/cancel, concurrent commands, batch terminal ordering, telemetry isolation, routing without Core/client submission, deferred turn-created events, debug pause/resume, and same-user IPC permissions.

P/E scheduling, model/tool request format, Tool Loop and Agent prompts were unchanged.
