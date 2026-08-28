# Session Domain

## Canonical state 与投影

当前 Session Engine 同时维持 durable V2 state 与 legacy V1-visible Session/Message/Part projection：

```text
Session aggregate durable events
  -> SessionProjector
  -> session / session_input / session_message
  -> legacy message / part projection
  -> HTTP/SDK/SSE consumers
```

`SessionProjector` 是 owner（`core/src/session/projector.ts:210-452`）。`SessionMessageUpdater.update` 将 Prompted 追加 user，Step.Started 建 assistant，text/reasoning/tool/step events更新其状态，Compaction.Ended 建 checkpoint（`message-updater.ts:101-393`）。因此 Message/Part 并非纯 HTTP API JSON；它们是 durable event 的 read projection。

## Schema 与关系

- `session`：id、project/workspace、parent、directory/path、title、agent/model、summary/diff、permission、revert、aggregate usage/timestamps。
- `session_input`：message ID、Session ID、normalized prompt、delivery、admitted/promoted sequence；用于 durable admission、steer/queue 和 exact retry。
- `session_message`：按 Session aggregate durable seq 排序的 runner message state。
- legacy `message` / `part`：保留 canonical conversation/part API projection，Part 更新驱动 usage。
- relation：subagent Session 以 `parentID` 指向 parent；不是共享 message list。



create/update/delete、prompt/admit/promote、abort/interrupt、revert、summary/compaction都会以 Session event -> projector 发生。Session usage 由 step-finish Part delta 聚合；Session status 是运行/事件投影而非单独持久 loop object。`resume:false` 是未运行 pending input，非“完成 Session”。
