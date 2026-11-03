# ADR-0011：按协议声明思考档位、Run 级快照与可分解耗时

日期：2026-10-24
状态：接受（Phase 4.3.1，修正 ADR-0010 的思考模式与耗时口径）

## 背景

Phase 4.3 把思考控制做成了“模型一组等级 + 底栏一句标签”，但对 MiMo 来说同一模型在两种协议下
接受完全不同的参数：Chat Completions 只有 `thinking.type` 开关，Responses 是
`reasoning.effort` 阶梯（`none/minimal/low/medium/high/xhigh/max/ultra`）。把两者混成一个列表，
或用“自动/开启/关闭”概括，都会让 UI 选择与实际请求参数脱节。同时 Phase 4.3 的“插件总计”只保留
最后一次 Provider 请求，而“运行总计”覆盖整轮；工具循环一旦发生，报告就会凭空多出数秒“未分解”。

## 决策

### 1. 思考档位按“模型 × 协议”声明

`ProviderThinkingProfile` 挂在 `ProviderModel` 上，字段：

- `protocolKind` / `protocolLabel`：只对这条协议生效；
- `axisLabel`：阶梯的显示名（如 `effort`），`nil` 表示普通开关；
- `levels`：该协议真正接受的 id/label 集合；
- `defaultLevel`：插件默认；
- `note`：官方限制或提示，由插件提供并原样展示。

Core 只校验“这个 id 是否被某个已声明 profile 接受”，不解释协议，也不知道 MiMo 的档位名。
TUI 用实时 `providerStates.protocolKind` 选择对应 profile；状态未知且只有一条 profile 时退化到它，
绝不相加两条阶梯。底栏显示 `协议 · effort: high（临时）`，临时值不写配置；`/reasoning follow` 恢复
插件配置。`/reasoning` 的选项和官方限制都来自声明，不需要进入插件设置页。

MiMo 的声明：Chat 为 `default/enabled/disabled`；Responses 为
`default/none/minimal/low/medium/high/xhigh/max/ultra`，并声明
“官方当前除 none 外各档位实际推理强度相同；仍按官方映射发送（minimal→low，xhigh/max/ultra→high）”。

### 2. Run 级思考快照

适配器在每个 `executionID` 的**首个** Provider 请求上捕获当时的临时选择，工具轮复用；Run 结束
（`finishExecution`）或取消/禁用时释放。UI/`/reasoning` 的变更只影响下一次 Run。这样工具循环中
协议、effort 与切换开关都不会中途变化；插件自身的配置快照（Phase 4.2.2）继续独立生效。

### 3. 耗时报告改为“可分解”，而不是一个总数

- 内核 `LoopTiming`：admission（含 journal 之外的工作）、上下文装配、`contextPrepare` Hook、预算、
  `beforeModelRequest` Hook、等待 Provider、工具执行、日志写入+fsync、终态提交、Provider 清理、
  total 与 **unaccounted**（total 减所有已知阶段）。
- `timing` 事件把内核阶段、Core 准备、插件 HTTP 阶段与 Run 总耗时一起送到 TUI；`/perf` 按
  “本地阶段 / 内核阶段 / 上游延迟 / 总计”分组，并明确打印未分解值。
- Provider 耗时**按 Run 聚合**：`providerCalls`、`providerTotalMs`（所有请求之和）、
  `providerLastCallMs`。运行总耗时与“最后一次请求”不可直接比较；报告不再暗示可以。
- “思考耗时”改名为“首思考→首字”：它只是两个首次输出的时间差，既不是完整思考时长，也不代表
  模型在首字后停止思考。

### 4. 主界面鼠标控件仍由 Renderer 命中图提供

模型名、思考状态、状态栏右下角命令提示、输入区发送按钮都是 `HitRegion`，不硬编码坐标；
发送按钮复用 Enter 的发送路径，运行中不产生命中的区域，草稿保留。`/mouse`、键盘与终端原生选择不变。

## 后果

- 旧插件不声明 `thinkingProfiles` 时继续使用扁平 `thinkingLevels`；旧前端忽略新字段。
- 设置页仍由插件自绘，高级 effort 留在插件设置中用于配置持久默认值；主界面选择是临时的。
- 报告多出若干字段，但每个都是可验证的毫秒数；未分解值不再被隐藏。
- 未改 C ABI 表；未改 Core 的配置事务、权限与 journal 持久化语义。
