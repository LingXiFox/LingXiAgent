# Persistence

## 引擎与路径

`packages/core/src/database/database.ts:22-35` 使用 Effect Drizzle SQLite。启动设置 `journal_mode=WAL`、`synchronous=NORMAL`、`busy_timeout=5000`、64MB cache、foreign keys，并运行 migrations。默认库路径为 `Global.Path.data/opencode.db`（非 prod channel 可能按 channel 后缀）；`OPENCODE_DB` 可覆盖。

## 真实 canonical 数据

| Entity | Persistence | Owner |
| --- | --- | --- |
| durable domain events | `event` / `event_sequence` | EventV2 |
| Session projection | Session table | SessionProjector |
| legacy Message/Part API projection | message / part tables | SessionProjector |
| runner message state | session_message table | SessionProjector + SessionMessageUpdater |
| admitted/pending prompts | session_input table | SessionInput projector |
| aggregate usage | Session row token/cost columns | step-finish Part projection |

`packages/core/src/session/projector.ts:214-452` 注册 event projectors。创建/更新/删除 Session、Message、Part 与 input inbox 均由 durable event 投影；`PartUpdated` 会对 step-finish usage 先回滚旧值再累计新值（310-327）。这不是把 HTTP payload 直接写数据库。

## 事务与一致性

`packages/core/src/event.ts:205-395` 将 durable event 的 sequence check、投影、可选 local commit、sequence row 与 event row 放在 `IMMEDIATE` SQLite transaction 内；成功后才发布内存通知。每 aggregate 严格递增 seq，replay 会检测 event ID、type、data 与 sequence 分叉。Session projection handler 要求 durable seq。

## 非 canonical JSON storage

`packages/opencode/src/storage/storage.ts` 是 `Global.Path.data/storage` 下按 key JSON 文件的带 reentrant lock 存储，含旧 session migration；它服务快照/资源等路径。不要将其当成当前 Session/Message/Part 的主数据库。

## 清理与损坏

当前源码中确认了 DB migrations 和 event replay divergence 防护；未发现通用数据库修复、自动 vacuum 或全面 corruption recovery 策略。`UNKNOWN / NEEDS VERIFICATION`：生产损坏时的用户恢复 UX。
