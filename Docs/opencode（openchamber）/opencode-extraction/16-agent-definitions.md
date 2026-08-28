# Agent Definitions

`Agent.Info` 是配置派生 runtime value：name、mode、model、variant、prompt、temperature/topP、steps、options、permission、hidden/native（`agent/agent.ts:35-80`）。service 在 directory InstanceState 中把 builtin defaults 与 config 合并，非每个 Session 单独 class instance。

Builtin：

| Agent | mode | 作用 |
| --- | --- | --- |
| build | primary | 默认可执行 agent |
| plan | primary | deny edits 的 plan policy |
| general | subagent | 一般并行工作 |
| explore | subagent | read/search-oriented policy |
| compaction/title/summary | hidden primary | runtime utility prompt |

custom `cfg.agent` 可覆盖 model、prompt、permissions、mode、steps、options 或 disable builtin（267-309）。选择 default agent 时拒绝 subagent 与 hidden agent（328-344）。Agent 本身不是完整 orchestration strategy；runner 从其配置选择模型、工具可见性、system prompt 与 step allowance。
