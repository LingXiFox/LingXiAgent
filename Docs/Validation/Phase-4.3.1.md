# Phase 4.3.1 验收记录

日期：2026-10-24
基线：`1a0e2cc`（Phase 4.3 收尾）
实现提交：（提交后回填）
状态：（测试与 CI 通过后回填）

本阶段修正 Phase 4.3 的两处口径：思考等级不简化为三档，而是按「模型 × 协议」声明；耗时报告不再把
“最后一次 Provider 请求”和“整轮 Run”放在一起暗示存在神秘开销。ADR-0011 记录决策。

## 一、思考等级系统（修正项）

**需求**：等级由 Provider 按模型和 API 协议声明，TUI 动态展示全部选项；区分开关与推理强度；
主界面可直接选择完整档位；底栏显示实际选择（如 `Responses · effort: high（临时）`）；临时选择不覆盖
持久配置；整个 Run 固定快照；Core 不得硬编码厂商档位。

**实现**：
- 协议新增 `ProviderThinkingProfile`（`protocolKind/protocolLabel/axisLabel/levels/defaultLevel/note`），
  挂在 `ProviderModel.thinkingProfiles`；加载器校验空协议、重复协议、空档位、重复档位、非法默认值。
  旧插件继续使用扁平 `thinkingLevels`，Core 两种都透传。
- MiMo 声明两条阶梯：
  - Chat Completions：`default / enabled / disabled`；
  - Responses：`default / none / minimal / low / medium / high / xhigh / max / ultra`，`axisLabel=effort`，
    `note` 说明“官方当前除 none 外各档位实际强度相同；仍按官方映射发送（minimal→low，xhigh/max/ultra→high）”。
- `/reasoning` 按实时 `providerStates.protocolKind` 选择 profile（状态未知且只有一条时退化到它，
  绝不相加）；选项、标题、限制提示都来自插件声明。点击底栏思考状态同样打开该选择器。
- 底栏显示 `模型 · 协议 · effort: high（临时）`；Chat 显示 `思考 开启思考（临时）`。临时值不写
  `plugin-settings/*.json`，`/reasoning follow` 恢复插件配置。
- 插件把档位映射到当前协议的实际参数：Chat 只接受 `default/enabled/disabled`；Responses 只接受
  `default/none/effort…`，未知或另一条阶梯的 id 保持保存配置（不崩溃、不猜）。
- **Run 级快照**：适配器在 Run 首个 Provider 请求捕获临时选择，工具轮复用；`finishExecution` /
  取消 / 禁用时释放。`/reasoning` 变更只影响下一次 Run。

**验收**：
- `REASONING_001`：未声明 id、未知 provider、缺 model 均拒绝。
- `REASONING_002`：Responses 保存配置 `enabled+medium` 报告 `effort: medium`；临时 `none` 报告
  `effort: none`+`session-override`；清空恢复 `medium`。
- `REASONING_003`：Chat body `thinking.type` 随临时档位变化，`default` 省略。
- `REASONING_004`：Responses `reasoning.effort` 随档位变化。
- `REASONING_005`：为 Responses 声明的档位在 Chat 下被 Core 接受、插件安全忽略（body 与保存配置一致）。
- `MIMO-DIAG-007`：九个 Responses 档位逐一断言真实请求体（default 省略；none→none；minimal→low；
  low→low；medium→medium；high→high；xhigh/max/ultra→high）。
- `MIMO-DIAG-008`：同一 execution 首次请求后修改选择，工具轮仍用旧档位；`finishExecution` 后新 Run
  才使用新档位；快照表有界并释放。
- `TUI-016`：真实 PTY 中底栏显示 `effort: medium`，点击状态打开完整档位（含官方限制），选 `xhigh`
  后显示 `effort: xhigh（临时）`，配置文件仍是 `medium`，`follow` 后恢复。

## 二、耗时差异调查（重点）

**现象**：Phase 4.3 报告“插件约 1.86s / Core 整轮约 7.23s”，差 5.37s 未解释。

**方法**：
- 内核新增 `LoopTiming`：admission、上下文装配、`contextPrepare` Hook、预算、`beforeModelRequest`
  Hook、等待 Provider、工具执行、日志写入+fsync、终态提交、Provider 清理、total，以及
  `unaccounted = total - 已知阶段之和`。
- Provider 耗时按 Run 聚合：`providerCalls`、所有调用之和、最后一次调用；报告显式显示步数。
- 三条真实路径测量：真实文件 journal + loopback HTTP（`PERF-001`）、2000 delta 长流
  （`PERF-002`）、两轮工具循环（`PERF-003`）、60 轮历史会话（`PERF-004`）。

**根因**：Phase 4.3 的“插件总计”字段只保留**最后一次** Provider 请求（`TimingBox` 覆盖写），
“运行总计”覆盖整轮。只要 Run 有工具循环（或重试），前面几轮 Provider 时间、工具执行与额外的
日志提交都不在那个数字里；5.37s 与“多出 2–3 轮请求”的量级一致。这不是上游延迟，也不是新的
内核黑洞，而是报告口径错误。

**修复**：
- 聚合 Run 内所有 Provider 调用（`providerCalls`/总和/最后值）；TUI 显示“插件总计 Xms（N 次，最后 Yms）”
  与“N 步”，避免拿一次请求和整轮比较。
- `/perf` 增加“内核阶段”和“未分解”两组数字；内核阶段缺失时显示未知而不是 0。
- “思考耗时”改名为“首思考→首字”，并注明它是两个首次输出的边界差，不是完整思考时长。
- 凭据解析单独计时：Keychain/环境读取发生在 Core、插件看不到；现在以 setup 事件上报
  `credentialMs`，并在 `/perf` 的“内核阶段”显示“凭据解析”。若本机 Keychain 慢，用户不会再把它
  误认为上游延迟。
- `loopTotalMs` 与“Core 队列/收尾”把 `run` 之外的时间也显示出来，报告中不再存在黑箱区间。
- journal 仍是每个事务 fsync；本机实测单次 append ≈0.02–0.05ms，`logWriteMs` 在毫秒精度下为 0。
  若用户磁盘/文件系统更慢，新报告会直接把它显示在“日志写入+同步”。

**实测**（本机 macOS 26 arm64，真实文件 journal）：
- `PERF-001`：单请求 loopback，`runTotal≈18ms`，`providerTotal≈16ms`，`unaccounted=2ms`（IPC/调度）。
- `PERF-002`：2000 个 delta 的长流，`runTotal=41ms`，`providerTotal=29ms`，`wait=40ms`，`unaccounted=1ms`。
- `PERF-003`：两轮工具循环，`steps=2`，`total=22ms`，`wait=21ms`，`log=0ms`，`commit=0ms`，
  `cleanup=0ms`，`unaccounted=1ms`。
- `PERF-004`：60 轮历史会话，`total=1–2ms`，装配/预算/日志均在 1ms 精度下为 0，`unaccounted=0–1ms`。
- 结论：本机内核没有隐藏的 5 秒级开销；报告的差异来自多轮聚合口径。真实 MiMo 在线请求未在本机
  重放（无 Key），但同一份报告现在会把每一段（含凭据解析与 IPC 在内的“等待 Provider”）显示出来。

## 三、主界面鼠标操作

- 底栏模型名 → 模型选择器；思考状态 → 当前协议的完整档位选择器；状态栏右下角 `Ctrl-P 命令`
  → 命令面板；输入区右侧 `[ 发送 ]` 与 Enter 同一发送路径。
- 生成中 `[ 发送 ]` 不产生命中区域（视觉置灰），草稿保留；运行结束后可继续发送。
- 全部通过 Renderer `HitRegion`（`modelName`/`thinkingStatus`/`commandHint`/`sendButton`），
  不硬编码终端坐标；`/mouse`、键盘、终端原生选择不变。
- 验收：`TUI-015`（真实 PTY：四个命中目标；运行中点击不提交且草稿保留；运行后发送成功）。

## 四、启动警告与脚本

- `LingXiCoreHost/main.swift` 的状态行改用快照方法（`providerCountSnapshot`、`offeredModelIDs`、
  `mountedHandlerIDsSnapshot`），消除旧工具链对 actor 属性 `await` 的误报警告；`PluginCoordinator`
  的未使用返回值也显式丢弃。`swift build --build-tests` 0 error / 0 warning。
- `Scripts/tui.sh` 只构建一次；需要刷新 bundle 时以 `--no-build` 调用 `tui-setup.sh`。
  `tui-setup.sh` 支持 `--no-build`，首次运行才打印完整引导，成功签名不再输出 codesign 噪声；
  失败时原样转发错误。安全提醒保留。

## 五、测试与 CI

环境：macOS 26 arm64，Swift 6.4.2，`rewrite/2.0`。

| 套件 | 命令 | 结果 |
|---|---|---|
| 完整套件（串行，同 CI） | `swift test --no-parallel` | **255** tests passed（104 kernel + 4 credential + 147 contract），184.6s，0 失败 |
| TUI/Settings PTY | `LINGXI_RUN_TUI_PTY_TEST=1 swift test --filter 'TUI_\|SETTINGS_'` | **14** tests passed，3.3s |
| Keychain + 隐藏输入 | `LINGXI_RUN_KEYCHAIN_TESTS=1 LINGXI_RUN_TUI_PTY_TEST=1 swift test --filter 'AUTH_\|settingsDisabledCredentialIsolation\|SETTINGS_004'` | **9** tests passed（4 + 5） |
| Settings/MiMo | `swift test --no-parallel --filter 'settings\|Settings\|MiMo'` | **90** tests passed，149.8s |
| 思考/耗时/内核账本 | `swift test --no-parallel --filter 'REASONING_\|TIMING_\|PERF_'` | **13** tests passed，8.6s |

新增 **9** 条（246 → 255）：`REASONING-005`（跨协议安全忽略）、`MIMO-DIAG-007`（九档真实请求体）、
`MIMO-DIAG-008`（Run 快照）、`PERF-001`~`004`（文件 journal + loopback / 长流 / 工具循环 / 长历史）、
`TUI-015`（主界面四个命中目标与发送禁用）、`TUI-016`（Responses 档位端到端）。另增强
`TIMING-002`（内核阶段/聚合/步数）与 `TUI-010`（耗时标签、内核阶段、未分解）。

构建：`swift build --build-tests` 0 error / 0 warning。

## 六、GitHub CI

（待填：run 链接与结论）

## 六、未验证边界

- 真实 MiMo 在线请求未重放；离线只证明序列化、映射与请求形状。
- 真实用户报告的 7.23s trace 没有原始数据；新报告字段可直接定位到具体阶段。
- Core 校验的是“插件为该模型声明的任一档位”，协议匹配由插件在请求时决定；跨协议误选会被安全忽略。
