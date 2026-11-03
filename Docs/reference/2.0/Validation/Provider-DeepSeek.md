# Provider 验收记录：DeepSeek（Responses API）

> **状态：离线与 CI 验收通过，真实 API 录制待主人执行** —— 合并提交 `7f3c3c0`，124 tests 全绿（104 内核 + 20 契约），CI run `39373895994` success，零告警。离线回归使用手工 fixture；`Scripts/deepseek-record.sh` 录制的真实 cassette 将替换它后完成最终验收。

## 一、协议事实（2026-10-20 核对）

| 项 | 值 | 来源 |
|---|---|---|
| 端点 | `POST https://api.deepseek.com/responses` | 官方 API 文档 / 指南 |
| 模型 | `deepseek-flash` | 官方 create-response 参考 |
| 流式 | SSE，`response.created`、`output_item.added/done`、`output_text.delta`、`function_call_arguments.delta/done`、`reasoning_text.delta`、`completed`（含 usage）、`failed` | 官方指南 |
| 不支持字段 | `store`、`previous_response_id`、`prompt_cache_key` | 官方指南 |
| 结论 | **采用 Responses API，不切换 Chat Completions** | 协议满足流式、工具与 usage 需求 |

## 二、实现落点

- `Plugins/DeepSeekProvider`：独立动态库、独立 `.lxap`、capability `provider.deepseek`。Core 与内核无任何 DeepSeek 标识。
- `DeepSeekWire`：请求编码、SSE 事件解析、归一化为 `ProviderWireEvent`（文本/推理增量、工具开始/增量/完成、usage、终态、失败）。
- `DeepSeekTransport`：URLSession SSE 真流式；取消经 `Task.cancel` 中断连接；VCR 录制/回放。
- `PluginProviderAdapter`（Runtime）：把 `ProviderWireEvent` 映射为内核 `ModelEvent`，并提供 `endExecution` 取消。
- 凭据：Core 读 `<data>/credentials.json`（能力 id → 环境变量名），每次 invoke 把值放入 `ProviderWireRequest.credential`；Host 环境仍是 allow-list，值不进日志、不进注册表、不进 cassette（digest 先剔除凭据）。

## 三、证据

| 要求 | 用例 |
|---|---|
| 真流式（非整段输出） | `DEEPSEEK_cassetteDrivesMultiTurnAndToolLoop`：断言 ≥2 个 `textDelta` 事件 |
| 多轮对话 | 同一 Session 连续两轮，第二轮携带历史 |
| 完整工具调用循环 | 第二轮：模型调用 echo → 工具执行 → 第二次模型请求 → 最终文本；`steps == 2`、`toolOutcomes == 1` |
| usage 映射 | 首轮 `inputTokens == 12` |
| 超时/取消不悬挂 | `DEEPSEEK_providerStreamCancellation`：慢速回放下 150ms deadline → `deadlineExceeded`，Host 存活，退出后 PID 消失 |
| 启停与路由撤销 | `DEEPSEEK_disableRemovesProviderRoute` |
| 核心无厂商依赖 | `rg DeepSeek Sources/LingXiKernel Sources/LingXiCoreHost` 无命中；L0 门禁通过 |

## 四、真实 API 与 cassette（待主人执行）

```bash
# 冒烟（不录制）
DEEPSEEK_API_KEY=... ./Scripts/deepseek-smoke.sh

# 录制脱敏 cassette（三幕：文本、工具调用、追问）
DEEPSEEK_API_KEY=... ./Scripts/deepseek-record.sh
```

录制产物为归一化事件序列（无请求头、无凭据）。拿到后替换 `ContractTests/Fixtures/deepseek-responses-fixture.json`，复跑离线用例并提交。

## 五、CI 记录

| 项 | 值 |
|---|---|
| Run ID | `39373895994` |
| URL | https://github.com/LingXiFox/LingXiAgent/actions/runs/39373895994 |
| head SHA | `7f3c3c0` |
| Conclusion | success |
| runner 工具链 | Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)；xcode: /Applications/Xcode_26.6.0.app |
| `swift test` 汇总 | `Test run with 124 tests in 0 suites passed after 1.653 seconds.` |
| live 用例 | `DEEPSEEK live Responses API smoke` **skipped**（无付费密钥时按设计跳过） |
| 空核步骤 | success |

## 六、残余风险

1. **并行工具调用声明为 false**（保守）：一个响应内的多个 `function_call` 会按顺序结算；是否支持并行需真实录制验证后再放开。
2. **推理 token / 缓存字段**按候选字段名解析，未用真实响应核对；映射为 nil 时保持「缺失 ≠ 0」。
3. **重试与退避**未实现：错误按分类上报，交由内核终态化；Provider 侧重试策略随第二个 Provider 一起提炼。
4. **fixture 是手工构造**，用于验证管线；最终验收以真实录制的 cassette 为准，二者在文件中可区分（fixture 的 `requestDigest` 为空）。
