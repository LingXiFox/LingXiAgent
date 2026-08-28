# Permission Engine

`Permission.evaluate(permission, pattern, ...rulesets)` 采用最后匹配规则，默认 `ask`（`permission/index.ts:28-38`）。rulesets 由 agent defaults、global/project config、session override 以顺序合并。

执行时 `Permission.ask` 对每个 pattern 评估：任一 deny 立即失败；全 allow 直接继续；否则创建递增 request ID、放入 per-instance `pending` map、发布 Asked 事件并等待 Deferred reply（67-107）。`once` 只放行当前 request；`always` 把允许 rule 留在当前实例的 `approved` array，并解除同 Session 已等待且已满足的请求（109-167）。reject 会拒绝该 Session 的所有 pending 请求。

这说明 permission 是 runtime 内部 control point，不是 durable domain record：pending/approved 都在 `InstanceState`，实例 finalizer 会拒绝遗留请求；HTTP/client 仅是 Asked/Replied event 的观察与回复通道。`fromConfig` 支持 `$HOME`/`~` 展开和 wildcard rule；`disabled/visibleTools` 还在模型 schema 暴露前隐藏被全局 deny 的 tool。

默认 build agent 容许多数工具，但将 doom loop/external directory/.env read 等设为 ask，并由 plan/explore/subagent 覆盖（`agent/agent.ts:119-264`）。未确认 persistent grant 跨进程保存；当前证据为 `NOT FOUND`。
