# ADR-0009：Responses 推理历史的真实续接

状态：已采纳（Phase 4.2.2）

## 背景

MiMo 官方 Responses 文档（https://mimo.mi.com/docs/zh-CN/api/chat/responses）明确：

- 思考模式下多轮工具调用会同时返回工具调用与思考内容；
- 后续请求应在 `input` 数组中保留**所有历史思考内容**；
- 不支持 `previous_response_id`；
- Reasoning 输出项结构为 `id` + `content[{type:"reasoning_text", text}]` + `type:"reasoning"` + `status`。

Phase 4.2.1 只保存了拼接后的 reasoning 文本，并在 Responses body 里凭 OpenAI 的 `summary`
形状拼了一个 item，既没有保留 id/status，也没有放在对应 function_call 前面。Chat 与
Responses 共用同一个字符串字段，协议边界不清晰。

## 决定

1. `ProviderReasoningItem`（id/text/status）与 `ProviderReasoningTurn`（callIDs/items）进入
   Provider Wire；`previousReasoningTurns` 为可选数组，空数组不编码，保持旧 cassette 的请求
   digest 不变；旧的 `previousReasoning` 字符串保留给旧插件和 Chat 消费者。
2. Responses SSE Normalizer 保留 `response.output_item.*` 的 reasoning item 元数据，也接受
   `response.reasoning_text.*` 增量；同一 `item_id` 的最终 item 覆盖增量文本，重复 sequence 被
   丢弃。输出项顺序按事件顺序保留。
3. Responses 请求把每个 reasoning item 插到对应 function_call 之前，使用文档中的
   `type/id/status/content[type=reasoning_text]`，不发送 `previous_response_id`、不伪装成
   user/assistant/system 文本。
4. Chat Completions 仍用 `reasoning_content`，但按 function_call 的 call id 匹配对应 turn，
   不把 Responses 的结构误塞进 Chat。
5. `ModelProvider.finishExecution` 在 Run 最终边界调用；Adapter 在此清空该 execution 的
   reasoning turns。工具轮中间的 `endExecution` 仍保留下一轮所需 turn。缓存上限 64 个
   execution、每个 execution 16 turns / 64 items / 64 KiB。
6. Reasoning 不写 journal、不持久化；取消、失败、超时和正常结束都清理。

## 剩余风险

- 离线测试验证了文档给出的结构，真实 MiMo 服务端是否接受历史 `status`/`id` 仍待在线验收。
- 若服务端在某次 Run 中返回未文档化的 reasoning item 形状，Normalizer 会丢弃而不会猜测字段。
- 缓存是内存级、按 execution 有界；进程崩溃不会留下磁盘推理内容。
