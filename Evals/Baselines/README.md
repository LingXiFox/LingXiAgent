# Evaluation Baselines & Non-Inferiority Criteria
# 评测基线与非劣性判定规则

本目录维护 LingXiAgent 各正式发布版本的基准评测数据（`summary.json` 及各任务明细），为后续版本优化提供不可辩驳的比较基准。

## 非劣性判定规则 (Non-Inferiority Rules)

依据 Roadmap V1.1 §1 原则 5（"任何声称降低成本 / 提升稳定性的能力必须能在评测集上与基线对比"），CI / Release 门禁比对 `Baselines/<base>/summary.json` 与当前评测结果时，遵循如下硬性判据：

1. **绝对成功率守恒 (Zero Success Regression)**：
   - 任何在基线中标记为成功的任务，若在待测版本翻转为失败，即视为**硬失败 (Hard Failure)**，门禁立即变红并阻止发布。
2. **中位数指标非劣性 (p50 Metric Guardrail)**：
   - 全体任务的 p50 耗时（Wall Time）、p50 工具调用次数（Tool Calls）、p50 估算成本（Cost Estimated USD）劣化不得超过 **5%**。
   - 超过 5% 的劣化必须提交架构设计决策说明，否则视为性能倒退。
3. **确定性运行约束 (Deterministic Constraints)**：
   - 评测执行必须 Pin 住模型 ID、Temperature、`AgentMode`。
   - `summary.json` 必须完整记录 `ProtocolVersion`、Git SHA、平台标识（darwin/linux/windows）与执行时间戳。
4. **离线 VCR 与在线 Provider 分轨**：
   - PR CI 门禁运行离线 VCR 录制回放以确保零成本确定性校验。
   - 周期性 Scheduled 与手动 `workflow_dispatch` 运行全量真凭据评测并刷新发布基线。
