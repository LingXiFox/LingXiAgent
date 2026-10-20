# Provider 验收记录：Xiaomi MiMo（Chat Completions）

> **状态：离线与 CI 验收通过，真实 API 录制待主人执行** —— 合并提交 `0c0192a`，130 tests 全绿（104 内核 + 26 契约），CI run `39374459326` success，零告警。离线回归使用手工 fixture；`Scripts/mimo-record.sh` 录制的真实 cassette 将替换它后完成最终验收。

## 一、协议事实（2026-10-20 核对）

| 项 | 值 |
|---|---|
| Base URL | `https://api.xiaomimimo.com/v1` |
| 端点 | `POST /chat/completions` |
| 鉴权 | `Authorization: Bearer <MIMO_API_KEY>` |
| 模型 | `mimo-v2.6-flash`（默认）、`mimo-v2.6-pro` |
| 协议族 | OpenAI Chat Completions（**与 DeepSeek 的 Responses 不同族**，正是本轮要验证的差异面） |
| 流式 | `data:` 分块：`choices[].delta.content`、`reasoning_content`、`tool_calls[]`（index/id/function.name/arguments）、`finish_reason`；`stream_options.include_usage` 的末尾 usage 块；`data: [DONE]` |
| 工具 | OpenAI function schema；assistant `tool_calls` 与 `tool` 角色回传结果 |

## 二、实现落点

- `Plugins/MiMoProvider`：独立动态库与 `.lxap`，capability `provider.mimo`，模型两个。
- **与 DeepSeek 插件不共享兼容层**：请求编码、SSE 归一化、cassette 各自实现；只复用已冻结的 ABI、Host 与 Runtime。新增厂商不需要改 Core。
- 归一化要点：
  - 工具调用按 `index` 累积；id/name 可能分块到达，二者齐备前不发 `toolCallStarted`，参数碎片先缓存，避免内核看到未开始的调用。
  - **终态延迟到流末尾**：Chat Completions 的 usage 块在 `finish_reason` 之后到达；若在 finish 时立刻发 `completed`，内核的终态守卫会丢弃 usage。因此先发 usage，再在 finalize 发终态。
  - `finish_reason` 映射：`stop`、`tool_calls`、`length → maxTokens`、`content_filter`。
- 凭据：与 DeepSeek 相同——Core 从 `credentials.json` 解析并按次注入；Host 环境不放宽，密钥不进日志与 cassette。

## 三、证据

| 要求 | 用例 |
|---|---|
| 真流式（非整段输出） | `MIMO_cassetteDrivesMultiTurnAndToolLoop`：断言 ≥2 个 `textDelta` |
| 多轮对话 | 同一 Session 连续两轮 |
| 完整工具调用循环 | 模型调用 echo → 工具执行 → 第二次请求 → 最终文本；`steps == 2`、`toolOutcomes == 1` |
| usage 映射 | 首轮 `inputTokens == 11` |
| 超时/取消无悬挂 | `MIMO_providerStreamCancellation`：慢速回放 + 150ms deadline → `deadlineExceeded`，Host 存活，退出后 PID 消失 |
| 启停与路由撤销 | `MIMO_disableRemovesProviderRoute` |
| 录制真的落盘且不夹带 fixture | `MIMO_recordingWritesCassette`（回放+录制只得到 1 个 exchange） |
| 核心无厂商依赖 | `Sources/LingXiKernel`、`Sources/LingXiCoreHost` 无 MiMo 标识；L0 门禁通过 |

并行稳定性：全套 130 tests 连跑 3 次全绿。

**录制链路上的两个真 bug（首轮录制时暴露，已修复并回归）**：
1. 纯录制模式没有创建 cassette store，`append` 被静默跳过，脚本却打印成功——现在录制输出有独立 store，脚本还会校验文件非空并扫描敏感文本。
2. 回放与录制共用 store，录制文件把 fixture 中未消费的 exchange 一并写入（首轮产物出现 4 个 exchange 而非 1 个）——现在回放源与录制输出分离。
3. 终态事件发出后内核立即结束 Run，落盘若放在其后会与调用方读取/关闭竞争——现在在**发出 `completed` 之前**同步写盘。期间发现握手超时在并行负载下过紧（含 codesign + dlopen），默认值由 5s 调整为 15s。

## 四、真实 API 与 cassette（待主人执行）

```bash
# 冒烟（默认 mimo-v2.6-flash；需要 pro 时设 LINGXI_MIMO_MODEL=mimo-v2.6-pro）
MIMO_API_KEY=... ./Scripts/mimo-smoke.sh

# 录制脱敏 cassette（文本、工具调用、追问）
MIMO_API_KEY=... ./Scripts/mimo-record.sh
```

产物为归一化事件序列（无请求头、无凭据）。拿到后替换 `ContractTests/Fixtures/mimo-chat-fixture.json`，复跑离线用例并提交。

## 五、CI 记录

| 项 | 值 |
|---|---|
| Run ID | `39374459326` |
| URL | https://github.com/LingXiFox/LingXiAgent/actions/runs/39374459326 |
| head SHA | `0c0192a` |
| Conclusion | success |
| runner 工具链 | Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)；xcode: /Applications/Xcode_26.6.0.app |
| `swift test` 汇总 | `Test run with 128 tests in 0 suites passed after 2.230 seconds.` |
| live 用例 | DeepSeek 与 MiMo 的 live smoke 均 **skipped**（无付费密钥时按设计跳过） |
| 空核步骤 | success |

## 六、残余风险

1. **模型 id 与可用性**以实际调用为准：第三方资料显示 `mimo-v2.6-flash` / `mimo-v2.6-pro`；若 400，错误体会完整回传到 Run detail，便于校正。
2. **并行工具调用声明为 false**（保守）；同一响应的多个调用按 index 顺序结算。
3. **`reasoning_content`** 已映射为推理增量，但不同模型是否返回该字段未用真实响应核对。
4. **重试与退避**未实现；错误按分类上报。
5. fixture 为手工构造，`requestDigest` 为空；真实录制后由插件自动计算 digest。
