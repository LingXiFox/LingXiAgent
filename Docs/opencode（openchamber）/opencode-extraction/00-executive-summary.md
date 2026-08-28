# OpenCode Runtime 抽离研究摘要

## 范围与结论

本研究只描述参考实现，不提出 LingXiAgent 设计或迁移实现。结论基于 `opencode-source` 当前 HEAD 的静态源码；核心 V2 runtime、HTTP handler、context 主路径的 blob 已和 `v1.18.21` tag 直接核对相同。

OpenCode 当前运行时的关键链路不是单一传统 `while` 循环：`SessionV2.prompt` 先将输入作为 durable event / inbox state 准入，`SessionExecution` 的进程内协调器按 Session ID 合并 wake/resume；位置作用域内的 `SessionRunner` 消费 inbox、组织 V1 session projection、调用一次 `llm.stream`，由 processor 逐事件写入消息/Parts、执行工具并决定下一 provider turn。旧 V1 Session/Message/Part 仍是可见转录与多数工具的直接 domain contract，V2 为 durable admission、执行调度与事件投影增加了新边界。

最重要的拆分事实：

- Context 的主要组装在 Session LLM request/processor 路径，输入来自 Session 历史、system/instruction、agent、tool registry 与 provider transform；不是 HTTP 或 TUI 行为。
- SQLite 是 durable event、V2 inbox 与 Session/Message/Part projection 的真实存储；旧 JSON `Storage` 仍服务于快照等独立资源，不应误认为 canonical Session 数据库。
- Provider metadata 由 models.dev catalog、config 和 auth 合并；AI SDK 是传输抽象，但 `provider/transform.ts` 留存大量按 npm/provider/model 分支。
- 工具的 model schema 来自 ToolRegistry；Permission 先决定可见性和执行 ask，MCP 以动态工具定义并入该 registry，三者不是同一状态机。
- `opencode serve` 可概念上拆成 transport 与 runtime，但当前 HTTP layer 仍负责实例/工作区定位、授权以及 V2 Location service graph 的装配。

## 当前最关心的十问

| 问题 | 结论 |
| --- | --- |
| 1. Agent loop 入口 | durable prompt 通过 `SessionV2.prompt` 准入并 `SessionExecution.wake`；本机 canonical drain 由 `packages/core/src/session/execution/local.ts:17` 调用位置作用域 `SessionRunner.run`。 |
| 2. 完整 Context 在何处组装 | 主要入口是 `SessionRunner.runTurnAttempt`：`SessionContextEpoch.initialize/prepare` 后，由 `SessionHistory.entriesForRunner` 和 `toLLMMessages` 形成请求；再经 ProviderTransform 变换。详见 05。 |
| 3. pruning/compaction | 不是检索式 memory；按模型 context limit 和 buffer 触发，生成 compaction summary、保留最近 turn，并在消息选择时过滤 compacted 历史。详见 06。 |
| 4. L1/L2/L3 最关键替换层 | 基于当前结构，必须替换/截获 Context selection + compaction + snapshot epoch 的 Session runner 层；只替换 HTTP、provider 或 prompt 文本不足以改变每轮历史选择。 |
| 5. Provider 抽象边界 | `Provider` 解析 catalog/config/auth 到 `LanguageModelV3`；AI SDK 接收规范化消息和 schema。边界之后仍有大量 provider/npm/model transform。 |
| 6. 参数泄漏程度 | 中等偏高：通用 capabilities/variants 存在，但 reasoning、cache、tool schema、message replay、store、timeout 等在 `ProviderTransform` 和 provider loader 明确分支。 |
| 7. Tool/MCP/Permission 关系 | MCP 维护连接和原生 definitions；ToolRegistry 选择/描述模型 tools；Permission 对工具可见性和实际 `ask` 决策，tool executor 在受许可后执行。 |
| 8. Session/Persistence 与 loop 耦合 | 高：prompt admission、event commit、message/part projection、usage 与 context history 都围绕 Session aggregate；runner 是 Session-ID 驱动。 |
| 9. HTTP 与 Core 能否概念分离 | 可以。`server.ts` 装配 typed HTTP handlers、SSE、授权和 Location service；核心 Session/Provider/Tool services 不依赖 HttpApi 类型。实际启动图仍在 server 组装它们。 |
| 10. 最难复现的五个 subsystem | Session durable event/projector 与恢复语义、上下文压缩/历史重建、跨厂商 Provider transform、工具/MCP/权限的可取消执行、事件与工作区路由/并发协调。 |

## 证据入口

- `packages/core/src/session/execution/local.ts`：进程内 Session drain。
- `packages/opencode/src/session/{prompt,processor,llm,compaction}.ts`：V1 prompt、turn、流与 compaction 适配路径。
- `packages/core/src/session/{store,projector,runner}.ts`：V2 durable state、投影、runner。
- `packages/opencode/src/provider/{provider,transform}.ts`：模型 catalog、SDK 与厂商变换。
- `packages/opencode/src/tool/registry.ts`、`mcp/index.ts`、`permission/index.ts`：工具、MCP、权限边界。
- `packages/core/src/{event.ts,database/database.ts}`：durable event 与 SQLite 事务。

所有未通过当前 HEAD 静态路径确认的细节列入 `27-open-questions.md`，而非推断为事实。
