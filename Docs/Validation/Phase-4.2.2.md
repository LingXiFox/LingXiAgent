# Phase 4.2.2 验收记录

日期：2026-10-24
基线：`764699f8835c055bef390f4bb51ec02208c1497c`
状态：离线实现与回归测试完成，GitHub CI 待本轮推送后记录。

## 一、P0：插件启动配置恢复校验

**根因**：`PluginCoordinator.enable` 只在启动前调用 `session.invoke(.apply)`，没有像
`applySettings` 一样解码 `SettingsResponse` 并检查 `ok`；插件明确拒绝、返回 `ok:false` 或
IPC 响应无效时仍会继续注册 ModelRouter 路由，等同于“偷偷使用默认配置”。

**修复**：
- 抽出唯一路径 `applySettingsSnapshot`，启动恢复和运行时保存共用；`SettingsResponse.ok` 必须为
  `true`，否则抛 `PluginSettingsApplyError.rejected`。
- 保存有配置但插件未声明 settings capability 时直接失败，不再静默回退。
- 没有配置文件时仍跳过 apply，使用插件默认值。
- 失败路径沿用既有 catch：回滚已注册路由、Hook、Session 和 Host；配置文件保持原样。
- `PluginSettingsStore` 的损坏/版本错误继续显式抛出，启动失败不会被吞掉。

**回归测试**（`ContractTests/PluginStartupSettingsTests.swift` 及 Settings 集成测试）：
- `startupSettingsRestoreSucceeds`
- `startupSettingsRejectionFailsEnable`
- `startupSettingsWithoutCapabilityFails`
- `startupSettingsAbsentUsesDefaults`
- `startupSettingsReadFailureFailsEnable`
- `startupSettingsCrashFailsEnable`
- `startupValidConfigRegistersRoutes`
- `startupCorruptConfigRegistersNoRoutes`（非法 JSON、版本 99、非法配置各一轮）
- `settingsIPCTimeout`

**验收**：恢复失败时 `router.offeredModels` 为空、`runningBundleIDs` 为空；Core 启动失败时
`hello.models` 为空，配置文件未被覆盖。

## 二、P0：Responses 推理上下文真实续接

**根因**：Phase 4.2.1 只保留拼接文本，`MiMoWire.responsesBody` 用 `summary_text` 拼了一个
非官方 reasoning item，且没有把历史 item 放到对应 function_call 之前；Chat 与 Responses 共用
同一个字符串字段。

**官方依据**（`https://mimo.mi.com/docs/zh-CN/api/chat/responses`）：
- Reasoning item 字段：`id`、`content[{type:"reasoning_text", text}]`、`type:"reasoning"`、
  `status`。
- 思考模式多轮工具调用需在后续 `input` 保留所有历史思考内容。
- 不支持 `previous_response_id`。

**修复**：
- `ProviderReasoningItem` / `ProviderReasoningTurn` 进入 Provider Wire；`previousReasoningTurns`
  可选，空数组不编码，旧 cassette digest 与旧插件兼容。
- Responses Normalizer 保留 `response.output_item.*` 的 item id/status/content，也接受
  `response.reasoning_text.*` 增量；同一 item id 的最终 item 覆盖增量，重复 sequence 丢弃。
- Responses body 在对应 function_call 之前插入完整 reasoning item，不发送
  `previous_response_id`，不伪装成 user/assistant/system。
- Chat Completions 仍使用 `reasoning_content`，按 call id 匹配 turn；两种协议不交叉复用结构。
- `ModelProvider.finishExecution` 在 Run 最终边界清理 reasoning turns；工具轮中间的
  `endExecution` 只保留下一轮所需 turn。缓存上限 64 个 execution、每个 execution 16 turns /
  64 items / 64 KiB，不写 journal。
- 取消、失败、超时、正常结束均清理。

**回归测试**：
- `MIMO_chatReasoningToolRoundTrip`
- `MIMO_responsesReasoningToolRoundTrip`（含重复 SSE、两个 reasoning item、结构/id/顺序断言）
- `MIMO_responsesMultipleReasoningTurns`（三轮工具续接，两个历史 turn 顺序正确）
- `reasoningStoreBoundsAndClears`（不同 execution 隔离、最终清理、100 个 execution 上限）
- `MIMO_providerStreamCancellation`、`MIMO_responsesCancellationDropsLateEvents`、
  `MIMO_httpFailures` 的缓存清零断言
- 既有 `MIMO_cassetteDrivesMultiTurnAndToolLoop`、`MIMO_responsesCancellationDropsLateEvents`

**剩余风险**：真实 MiMo 服务端是否接受回传的 `status`/`id` 只能在线验收；未文档化形状会被丢弃，
不猜字段。

## 三、P0：设置取消/保存回滚与 preferredModel

**根因 A**：`cancel` 在保存中只设置标记后返回，部分早期 `throw` 分支没有统一 Host 清理路径；
`shutdown` 正在保存的 Host 可能遗留；重复释放缺少幂等保护。

**修复 A**：
- `save` 拆成 `performSave` + 单一外层退出路径：成功、取消、Host 死亡都在这里关闭一次；
  `close` 用 `closedSessions` 幂等。
- 取消在 prepareSave/写盘/apply/commit 各阶段都有检查；commit 成功后若已取消，恢复文件、
  运行配置、preferredModel，并尝试把插件 commit 状态恢复旧配置，失败报 `rollbackFailed`。
- 非取消的插件拒绝保留可重试的 Session/Host；Host 崩溃/超时/取消关闭 Session。
- `shutdown` 将所有进行中的 session 标记 cancelled 后关闭，Host 最终退出。
- TUI 不因迟到回复重开窗口；100 次打开/保存/取消后 Session 与 Host 均为零。

**根因 B**：`preferredModels` 在 commit 之前写入，commit 失败时磁盘/运行态回滚但内存偏好仍是新值。

**修复 B**：保存前记录旧 preferredModel，只有 commit 成功后才发布新值；失败/取消恢复旧值或删除；
`FrontendReply.preferredModel` 只在成功路径返回；Core 重启从设置文件读取同一值。

**回归测试**：
- `settingsCancelDuringSave`、`settingsCancelDuringApply`、`settingsCancelDuringCommit`
- `settingsCommitRejection`、`settingsCommitCrash`、`settingsCommitTimeout`
- `settingsRollbackRuntimeFailure`
- `settingsPreferredModelCommit`
- `settingsSaveCancelChurn`（100 次）
- 既有 `settingsConcurrentSave`、`settingsHostCrashIsolation`、`settingsSessionChurn`

## 四、回归与兼容性

- 固定 C ABI v1 未修改；`ProviderWireRequest` 只新增可选字段，空值不编码。
- 旧 Chat cassette digest 未变；`MIMO_cassetteDrivesMultiTurnAndToolLoop` 通过。
- 未新增 Provider、MCP、Skills、Coding 或 Settings View 架构。
- 未删除 Phase 4.2.1 安全测试；Settings-Only 空 grants、凭据会话绑定、删除确认保持。
- 未使用真实 API Key；CI 默认离线。

## 五、本地验证

- `swift build --build-tests`：成功。
- 完整 `swift test`：**219** 个测试通过（104 kernel + 4 credential + 111 contract）。
- Settings/MiMo 过滤：**70** 个测试通过。
- MiMo 双协议过滤：**24** 个测试通过。
- TUI/Settings PTY：**6** 个测试通过。
- Keychain：**9** 个测试通过（4 + 5）。
- 新增测试：**20** 个（启动恢复 8、设置取消/提交/偏好/关闭 11、推理缓存 1，另含既有测试增强断言）。
- CI 主套件使用 `swift test --no-parallel`：首次 run `40048372786` 在 Run tests 卡住，原因是
  219 个测试并行启动大量真实 Plugin Host，runner 进程/文件描述符压力过大；同时发现
  `FileHandle.writeData` 在管道满/关闭时会抛 Objective-C 异常并终止 Core。已改为有界
  `poll`+POSIX 写，并让 CI 串行运行完整套件。

## 六、真实 API / 未验证边界

- 真实 MiMo Responses 在线续接未执行（无 `MIMO_API_KEY`）；loopback/cassette 成功不等同真实服务端
  成功。真实 API 作为单独阶段保留。
- Responses 历史 reasoning 的 `status`/`id` 回传接受度未在线确认。
- 设置 Host 的协议隔离不是 OS 沙箱；原生不可信插件仍需系统级隔离。
- GitHub CI URL：待本轮推送后填写。
