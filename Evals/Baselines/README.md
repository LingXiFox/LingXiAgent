# Evaluation Baselines & Non-Regression Rules
# 评测基线与非劣性判定规则

Baselines against which release candidates are evaluated:
- `v1.0.0/summary.json`
- `v1.1.0/summary.json`

Non-regression criteria:
1. Any task flipping from success to failure = hard block.
2. p50 cost, wall-clock duration, or tool call count degradation > 5% = failure.
