# Context Assembly

## 主入口

`packages/core/src/session/runner/llm.ts:173-355` 的 `SessionRunner.runTurnAttempt` 是当前 Context Assembly 主入口。它不是把 HTTP payload 或 TUI state 原样转发，而是先初始化/prepare Session Context Epoch，再从 durable projection 选择 history、按模型能力降级为 LLM messages。

```text
Stored Session/Event/Message/Part/Input
  -> SessionContextEpoch.initialize / prepare
  -> SessionHistory.entriesForRunner
  -> loadSystemContext + agent.info.system
  -> toLLMMessages + materialized tool results
  -> ToolRegistry definitions + model limits/options
  -> llm.stream(request)
  -> ProviderTransform / AI SDK adapter
```

## System Context

`loadSystemContext` 并发加载三路，之后按固定顺序拼接：`SystemContextRegistry.load()`、`SkillGuidance.load(agent)`、`ReferenceGuidance.load()`（`runner/llm.ts:168-171`）。registry 对 source key 排序（`system-context/registry.ts:39-44`）。已确认 builtin source 含 runtime environment/date 与 AGENTS instructions（`system-context/builtins.ts:12-50`, `instruction-context.ts:22-100`）。

agent 的 `info.system` 和 epoch baseline 作为 system parts；skills/reference guidance 是 runner 附加 guidance。MCP server instructions 的注入应以 SystemContext source 逐项证实：MCP 自身确实持有 `instructions()`，但“所有 MCP instructions 必然进每一轮 system prompt”不能在未读 source registration 前断言，标 `NEEDS VERIFICATION`。

任一 required source 初始化失败会产生 `SystemContext.InitializationBlocked` 并阻止本 turn 模型调用（`system-context/index.ts:197-205`, `runner/index.ts:11-18`）。

## History、Parts 与媒体

`SessionHistory.entriesForRunner` 在最近一次 compaction 之后读取，且过滤 baseline sequence 前的旧 system update（`core/src/session/history.ts:24-99`）。结果经 `toLLMMessages` 转为 provider message；tool result 由已 materialize output 形成，下一 provider turn 会重新查询该 projection，而非复用内存 messages。

reasoning、text、tool、attachments 是 Part/message event 的可见状态；provider transform 会针对 capability 处理 unsupported image/file，并处理 reasoning replay/signature（`opencode/src/provider/transform.ts:101-445`）。最终是否把某种 provider metadata/attachment保留取决于 target Model capability。

## Token budget 与缓存

model context/output limits来自 Provider Model metadata（`provider/provider.ts:1068-1088`），compaction 使用 `context - max(output, buffer)` 判定请求预算。OpenCode provider prompt cache 在 transform 中对 system/末尾消息加 cache control或 session cache key（`provider/transform.ts:358-407,1156-1324`）；这优化 provider request，不是 Session memory cache，也不改变 canonical history selection。
