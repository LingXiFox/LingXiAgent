# ADR-0007：MiMo 在同一 Provider 身份下支持 Chat Completions 与 Responses

状态：已采纳（Phase 4.2）

## 背景

MiMo 官方提供两个 wire family。若注册成两个 Provider，会出现同一模型重复路由、插件设置分裂、
用户在 `/models` 看到重复项；若只保留 Chat Completions，又无法使用 Responses 的 reasoning effort
和工具续接。需要在不改内核、不复制 Provider 身份的前提下选择协议。

## 决定

1. **一个 Provider 身份，两个协议实现**：`provider.mimo` 路由与模型清单不变；协议选择属于插件设置，
   不产生第二个 Provider。
2. **协议默认值**：旧用户默认 `chatCompletions`，不因升级悄然改变行为。
3. **端点在插件内**：`/v1/chat/completions` 与 `/v1/responses` 由 MiMo 插件选择，Core 不感知。
4. **思考参数**：
   - Chat：`thinking.type = enabled|disabled`，默认省略。
   - Responses：`reasoning.effort`，`none/minimal/low/medium/high/xhigh/max/ultra` 合法；
     `minimal→low`、`xhigh/max/ultra→high`，默认省略。
   - `/thinking` 与 Ctrl-T 仍只控制推理文本展开，和请求参数无关。
5. **配置快照**：Core 保存设置后通知运行中的插件；插件按 `executionID` 首次请求快照，工具轮复用，
   新 Run 才读取新配置。一个 Run 内不允许切换协议或思考参数。
6. **Responses 历史**：使用 `input` 续接，不使用 `previous_response_id`/`background`/
   `context_management`。SSE 按 sequence/output item 去重，`response.incomplete`/`failed` 不作为普通
   成功。
7. **真实 API 与离线证据分离**：cassette 与 loopback 只证明请求形状和归一化；真实端点验收需要
   `MIMO_API_KEY`，没有 Key 时必须如实标注未验证。

## 代价

- 两套 SSE 解析与请求编码增加插件维护面；Chat 旧 cassette 需要 digest 兼容路径。
- Responses 的思考档位目前只有 `none` 与 `enabled` 有实际区别；UI 必须明示，不能假装档位已控制
  token 预算。
- 协议切换只能在新的 Run 生效；正在执行的 Run 保持旧快照是刻意行为，不是延迟缺陷。

## 可逆性

可逆。插件设置中的 `protocolKind` 可随时切回 `chatCompletions`；Core、ABI 与模型路由不需要回滚。
