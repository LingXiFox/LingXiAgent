# Subagents / Task

`TaskTool.execute`（`tool/task.ts:92-358`）是真实入口。它先验证 nesting depth、执行 `task` permission、解析目标 Agent，再复用 task_id Session 或新建带 `parentID` 的 child Session。child session 继承经 `deriveSubagentSessionPermission` 收窄后的 session permission，并补充 todowrite/task/primary tool denies。

child model 默认继承调用它的 assistant message provider/model/variant；target agent 指定 model 时覆盖。prompt 只传 Task 参数经 `resolvePromptParts` 解析后的内容，child 不共享 parent 完整 history；可从 `parentID` 追踪关系。cwd/MCP/config 由同一 InstanceState 的 directory context 提供，故通常同工作区实例，而非复制其 Session history。

前台 task 等 child BackgroundJob 完成后把最后 text 包为 `<task_result>` 返回 parent tool result。实验性 background mode 启动 job 并在完成时向 parent 发送 synthetic prompt；foreground abort listener 会同时 cancel child Session/job（296、321-357）。失败 assistant/tool result 被转为 task error。

结论：subagent 是新 Session + shared location runtime resources + explicit prompt/result bridge；不是递归调用同一 message list。Usage 先记录 child Session；parent 只获得 task result，跨 Session aggregate 统计规则为 `NEEDS VERIFICATION`。
