# Event System

## 链路

```text
Runtime service
  -> EventV2Bridge.publish (补充 Instance/Location)
  -> EventV2 durable transaction / in-memory PubSub
  -> GlobalBus event and optional sync derivative
  -> instance HTTP `/event` listener queue
  -> SSE `{ id, type, properties }`
```

`EventV2Bridge` 在没有显式 location 时补入 directory/workspace/project，并为 durable event 额外发出 `sync` projection（`event-v2-bridge.ts:19-60`）。`EventV2` 有 typed/all/durable stream、listener、projector、replay 与 owner claim；durable history 按 aggregate/seq 查询并和 live wake 串接（`core/src/event.ts:63-107, 565-604`）。

HTTP SSE 在 `handlers/event.ts:25-85` 建立 unbounded queue 后立即注册 listener，按 instance directory 和 workspace filter，首事件 `server.connected`、10 秒 heartbeat，实例 dispose 后结束。SSE event data 的 `id` 字段未使用，JSON body 内保留事件 ID；因此浏览器 Last-Event-ID 不是此 route 的 replay 协议。

分类：

| 类别 | 例子 | 持久性 |
| --- | --- | --- |
| domain/durable | Session V1/V2 event、input、part、step、compaction | Event table + sequence |
| domain/transient | permission ask/reply、MCP tool changed、toast | process InstanceState / bus |
| transport | `server.connected`、heartbeat、instance.disposed | SSE-only |
| derived | GlobalBus `sync` envelope | 由 durable event 派生 |

背压：SSE handler 使用 unbounded Queue；EventV2 有可选 `allBounded` dropping queue，但此 SSE route 未采用。慢客户端内存背压策略为 `NEEDS VERIFICATION` 风险。
