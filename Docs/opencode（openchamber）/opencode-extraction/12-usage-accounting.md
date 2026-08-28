# Usage 与 Token Accounting

usage 的来源是 provider stream/AI SDK step finish；Session projector 识别 `step-finish` Part 中的 `cost` 与 tokens `{input, output, reasoning, cache:{read,write}}`（`core/src/session/projector.ts:25-41`）。Part 更新时会增量反映到 Session aggregate token/cost 列（89-108、310-327）。

```text
provider stream usage
  -> assistant step-finish Part
  -> durable PartUpdated
  -> SessionProjector usage delta
  -> Session table/API projection
```

价格 metadata 来自 models.dev -> `Provider.cost()`（`provider/provider.ts:1217-1248`），包含 cache read/write、tier、200K+ experimental price。准确 token/cost 值由 provider response 与 current model metadata 的结合形成，非 OpenCode tokenizer 全量重算。

失败请求、部分 stream、跨多 step turn 的最终计费细节需要以 `session/processor.ts` 与 provider stream tests 做 release-level trace；当前静态证据足以确认 Session 层按每个 persisted step-finish Part 累计，未见另一个 Session 总账逻辑。
