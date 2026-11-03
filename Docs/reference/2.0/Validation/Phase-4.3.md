# Phase 4.3 验收记录

> 后续修正：Phase 4.3.1 将思考等级改为按「模型 × 协议」声明，并把耗时报告改为可分解口径。
> 本文件保留 4.3 当时的三档描述与“插件总计=最后一次请求”的历史记录，不再代表当前行为。

日期：2026-10-24
基线：`bdea962`（Phase 4.2.2 收尾）
实现提交：`1426dcd`（Core 协议/状态/耗时）、`6f0aab6`（MiMo 设置页与插件诊断）、
`731aa87`（TUI 鼠标/底栏/诊断/退出）、`2f60cc7`（旧工具链宏兼容修复）
状态：本地完整测试、PTY、Keychain 与 GitHub macOS CI 全部通过。

## 一、主界面思考模式

**需求**：底栏显示当前模型、协议与实际生效的思考模式；新增 `/reasoning` 快捷切换，选项由 Provider
插件声明；区分临时设置与插件默认；Ctrl-T 仍只控制思考内容显示。

**实现**：
- 协议新增可选能力 `provider.state.v1`（`ProviderIdentity.state`）。Core 在 `hello`、`models.list`、
  启停与设置保存后询问插件，得到 `ProviderState {protocolKind, protocolLabel, thinkingLevel,
  thinkingLabel, source, detail}`；未声明的 Provider 不显示状态，不虚构默认值。
- 临时选择走 `provider.reasoning.set`：Core 用插件声明校验 provider/model/level，未声明一律拒绝；
  通过后存入 Provider 适配器的内存选择，随每次 `ProviderWireRequest.reasoningLevel` 下发。
  它不写设置文件、不写会话日志，Core 重启即消失；清空即恢复插件配置。
- Core 合并状态时临时值优先，`source = session-override`、`overridden = true`；TUI 底栏显示
  `模型 · 协议 · 思考 等级（·临时）`，Ctrl-T 仍只展开/收起思考内容。
- MiMo 插件把等级映射到 `thinkingMode`（default/enabled/disabled），在有效配置上先生效再生成
  digest 与 HTTP body；未知 id 保持原配置（安全失败）。

**验收**：
- `REASONING_001`：未声明的 `ultra`、未知 provider、缺 model 三种请求都被 Core 拒绝，错误可读。
- `REASONING_002`：hello 显示插件态（responses/enabled/plugin-settings）；设置 `disabled` 后回复
  `session-override`/`overridden=true` 且标签为“关闭思考”；清空后恢复 `plugin-settings`。
- `REASONING_003`：同一配置下 `enabled` → Chat body `thinking.type=enabled`；`disabled` →
  `thinking.type=disabled`；`default` → 不发送 `thinking`。**证明切换影响真实 HTTP 参数。**
- `REASONING_004`：Responses 下 `disabled` → `reasoning.effort="none"`；`enabled` → 保存的
  `effort="medium"`；`default` → 不发送 `reasoning`。

## 二、生成速度诊断

**需求**：请求分段耗时埋点（Core 准备、HTTP 发送、首个 SSE、首个 reasoning、首个正文、生成结束、
TUI 渲染）；简洁诊断能区分上游延迟、思考耗时与本地处理；不记录 API Key 或敏感请求内容。

**实现**：
- 插件侧单调时钟记录 7 个阶段，生成一条 `ProviderWireEvent(type:"timing")`，紧挨终态事件之前；
  一次请求最多一条（`finish()` 只返回一次）。
- 内核新增中性 `ModelTiming`（观察用，不进入 Run 状态），适配器映射为 `ModelEvent.timing`；
  Core 补 `corePrepareMs`（请求受理→Provider 调用）与 `runTotalMs`，以 `timing` 事件在终态前发给
  TUI；TUI 再补渲染毫秒与帧数（每帧两次时钟读取）。
- 字段全部是整数毫秒；没有字段能携带 prompt、回复、header 或密钥；`timing` 不写 journal，
  录制器显式跳过，不写入 cassette。
- 回放路径只上报 `totalMs`，不伪造不存在的 HTTP 阶段。

**验收**：
- `TIMING_001`：一次 Run 恰好一条 timing，且早于 `run.terminal`；Core 准备与 Run 总耗时非负。
- `TIMING_002`：真实 loopback HTTP 下 prepare ≤ send ≤ firstResponse ≤ firstSSE ≤ firstText ≤
  providerTotal ≤ runTotal；未请求思考时 `firstReasoningMs` 缺失（缺失≠0）。
- `TIMING_003`：timing JSON < 1 KiB，字段全为非负整数；不包含 prompt 标记与凭据、`Bearer`。
- `TIMING_004`：≥2 个 delta 只对应 1 条 timing，回复内容不变。
- `MIMO-DIAG-004`~`MIMO-DIAG-006`：失败请求仍恰好一条；回放只有 total；旧 cassette 逐字节不变。

## 三、MiMo 设置页优化

**需求**：整理 Connection/Protocol/Model/Advanced；按协议动态展示有效思考参数；普通模式简洁、
高级 effort 折叠；优化留白与状态提示；插件自主绘制。

**实现**：`MiMoSettingsState` 重排为“Tab 行 + 一行状态（`● 未保存`/`已保存` + 协议/模型/思考摘要）+
正文”；Chat 页不显示 effort，Responses+enabled 才出现；“高级 effort”单行默认折叠，Enter/点击展开；
去掉多余空行；Esc/Ctrl-S 仍由宿主处理。

**验收**：`MIMO-SET-001`~`MIMO-SET-006`（四页结构、Tab 点击切页、思考单选点击后 frame 变化并置
dirty、Chat/Responses 动态展示、滚轮只动选择不应用、保存后重开为 clean）；`SETTINGS_004` 仍通过。

## 四、设置保存与退出

**需求**：保留 Ctrl-S；插件提供准确 dirty；无修改 Esc 直接退出，有修改弹“保存/放弃/继续编辑”；
保存失败保留草稿；插件崩溃不阻止宿主关闭；不改 Core 配置事务与权限。

**实现**：
- `SettingsResponse.dirty` → `SettingsSnapshot.dirty`；`nil` 表示插件不跟踪，宿主按脏处理。
- Esc：`dirty == false` 直接关闭；`true`/`nil` 弹宿主三按钮对话框（初始焦点“继续编辑”，可选可点）。
- 保存失败保留设置会话、窗口与草稿，显示错误；Host 崩溃/超时由 Core 移除会话，TUI 关闭窗口并提示；
  `/quit` 与 Ctrl-C 不等待设置 Host。

**验收**：`SETTINGS_001`（干净草稿 Esc 不弹框）、`SETTINGS_003`（保存失败保留草稿 → 三按钮对话框 →
继续编辑 → 放弃且未落盘）、`TUI_012`（设置 Host 在 apply 阶段崩溃后窗口关闭并提示）、`TUI_013`
（保存中 Ctrl-C 立即退出，<5s，status 0）、`PROBE-SET-001`（probe dirty 精确）；既有
`SettingsContainerTests` 29 条事务用例全绿。

## 五、TUI 鼠标操作

**需求**：点击、滚轮、焦点切换；插件列表、设置 Tab、单选项、弹窗按钮可点；插件只收帧内相对坐标；
宿主保留保存、退出与安全确认；保留 `/mouse` 与原生拖选；键盘全部保留、状态同步。

**实现**：
- `Terminal` 解析 SGR（`CSI <b;x;yM/m`）：左键按下/释放、滚轮 64/65，1 基行列；`/mouse` 控制
  `1000h/1006h` 捕获。
- Renderer 每帧产出命中表：消息区滚动、输入区、选择器/插件列表行、宿主弹窗按钮、设置面板内区域
  （裁剪到面板内框与插件 viewport）。
- 设置内点击转发 `SettingsInput(kind:.mouse, row, column, delta)`，坐标是插件帧内相对值；宿主边框、
  标题、页脚与弹窗按钮不转发。点击与键盘共享选中状态；点击弹窗按钮与 Enter 等价。

**验收**：`TUI_010`（滚轮与 `/mouse` 开关；未开启捕获时滚轮被忽略）、`TUI_011`（插件列表点击开设置、
插件帧内点击行 3/4、chrome 不穿透、弹窗「放弃」点击生效、release 不重复触发）、`TUI_014`（真实 MiMo：
点击 Protocol Tab → 点 Responses → Ctrl-S → 底栏刷新为“协议 Responses”且磁盘配置为 responses）、
`MIMO-SET-002/003/005`、`PROBE-SET-001`（相对坐标驱动插件）。

## 六、回归与兼容性

- 固定 C ABI v1 表未改；新增均为可选 wire 字段/可选能力，旧插件与旧前端退化到“没有该信息”。
- 旧 cassette digest 未变；`timing` 不进入 cassette；MiMo 既有测试全部通过。
- 未新增外部依赖；未改 Core 设置事务、凭据托管、签名策略与插件权限。
- 未使用真实 API Key；CI 默认离线。

## 七、本地验证

环境：macOS 26 arm64，Swift 6.4.2，`rewrite/2.0`。

| 套件 | 命令 | 结果 |
|---|---|---|
| 完整套件（串行，同 CI） | `swift test --no-parallel` | **246** tests passed（104 kernel + 4 credential + 138 contract），179.2s，0 失败 |
| TUI/Settings PTY | `LINGXI_RUN_TUI_PTY_TEST=1 swift test --filter 'TUI_\|SETTINGS_'` | **12** tests passed，4.3s（SETTINGS-004 由 keychain 门禁跳过） |
| Keychain + 隐藏输入 | `LINGXI_RUN_KEYCHAIN_TESTS=1 LINGXI_RUN_TUI_PTY_TEST=1 swift test --filter 'AUTH_\|settingsDisabledCredentialIsolation\|SETTINGS_004'` | **9** tests passed（4 + 5），2.5s |
| 设置与 MiMo 契约 | `swift test --no-parallel --filter 'settings\|Settings\|MiMo'` | **87** tests passed，155.8s |
| 思考选择与耗时 | `swift test --no-parallel --filter 'REASONING_\|TIMING_'` | **8** tests passed，2.9s |

新增测试 **27** 条（219 → 246）：Core 验收 8（`REASONING_001`~`004`、`TIMING_001`~`004`）、
MiMo 14（`MIMO-SET-001`~`007`、`PROBE-SET-001`、`MIMO-DIAG-001`~`006`）、TUI PTY 5
（`TUI_010` 底栏/`/reasoning`/`/perf`/滚轮，`TUI_011`~`013` 鼠标与设置宿主故障，`TUI_014`
鼠标→MiMo 设置页→保存→底栏刷新的端到端链路）；另增强既有 `SETTINGS_001`/`SETTINGS_003` 断言。

**耗时统计是否拖慢生成**：埋点只在一次请求的 7 个里程碑各读一次单调时钟，并用一条
<1 KiB 的数值事件随终态发出；`TIMING_004` 断言流式 delta 数量与 timing 事件数无关（不是每 delta），
`MIMO-DIAG-004` 断言每请求恰一条、字段单调且有界。TUI 渲染统计每帧仅两次时钟读取，PTY 实测
<1 ms/帧。本阶段 246 条用例整体 179s，与上一阶段（219 条）同一量级，未观察到生成路径变慢。

## 八、GitHub CI

- 实现提交 `2f60cc7`（代码 HEAD）在 `macos-26` arm64 上全步骤成功：
  <https://github.com/LingXiFox/LingXiAgent/actions/runs/40058097885>
- CI 日志计数：主套件 **246** tests passed（327s）；TUI/Settings PTY **12**；Keychain **9**；
  思考/耗时 **8**；Settings/MiMo **87**；空核启动步骤通过；构建 48.6s。
- 第一次运行（`40057904580`，提交 `731aa87`）在 **Build products and tests** 失败：CI 选用的旧
  Swift Testing 在展开 `#require(column(of:in:))` 时，把被声明的局部变量 `column` 当成函数而报
  “cannot call value of non-function type 'Int'”。本地 6.4.2 工具链不复现。把 helper 改名为
  `firstColumn` 后本地与 CI 一致，`2f60cc7` 全绿。
- 证据提交本身为纯文档变更；其 CI 结果见仓库 Actions 列表。

## 九、未验证边界

- 真实 MiMo 服务端对临时思考（尤其 `reasoning.effort=none`）的接受度未在线验证；离线只证明请求形状。
- 鼠标仅覆盖 SGR（1000/1006）终端；旧 X10 编码或未开启 SGR 的终端仍用键盘。
- 设置 Host 隔离仍是协议级，不是 OS 沙箱。
