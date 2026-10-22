# Phase 4.2.1 验收记录

日期：2026-10-22
基线：`85a9c38f3e526fbe547f4602be3d07472dc9e181` + Phase 4.2.1 修复

## P0-1 设置保存事务

**根因**：`PluginSettingsCoordinator.save` 只检查 `prepareSave` 的 `ok` 为 false，`applySettings`
只检查 IPC 成功；`MiMoPlugin.invokeImpl` 用 `try? core.applySettings(config)` 吞掉插件语义错误；
`commit` 失败被 `try?` 忽略；回滚失败被 `try?` 吞掉；并发保存没有互斥；取消与保存没有竞态标记。

**修复**：
- `PluginCoordinator.applySettings` 解码 `SettingsResponse` 并要求 `ok == true`，新增
  `PluginSettingsApplyError.rejected`。
- `save` 要求 `prepareSave.ok == true` + JSON object；写盘后 `apply`、`commit` 均检查；
  失败恢复旧文件并重新 apply 旧配置；回滚失败返回 `rollbackFailed` 文本。
- `saving` 集合拒绝同一 bundle 的并发保存；`cancelled` 标记让取消优先于写盘/提交。
- `MiMoPlugin` 把 `core.applySettings` 抛错转换成 `SettingsResponse(ok:false)`，不再吞掉。
- `PluginSettingsStore` 写文件采用原子写入；读取损坏/版本错误显式抛出。
- TUI 保存失败保留窗口并在容器页脚显示错误；输入队列在保存成功/取消/重开时清空。

**回归测试**：`settingsPrepareSaveRejection`、`settingsApplyRejection`、`settingsConcurrentSave`、
`settingsDiskFailure`、`settingsApplyCrashRollsBack`、`settingsCancelDuringSave`、
`SETTINGS-003`（PTY 可见错误）。

## P0-2 跨插件凭据权限

**根因**：插件返回的 `SettingsCommand(providerID)` 被 TUI 直接转为 `auth.*`，Core 未把命令绑定到
设置会话的 Bundle ID，恶意设置页可以指定别的 Provider。

**修复**：
- 新增 `plugin.settings.credential`；Core 用 `settingsSessionID` 找 live session，验证
  `plugin.bundleID == live.bundleID`，并只接受该插件 `ProviderIdentity` 声明过的 provider/credential。
- 删除凭据要求 `settingsCredentialConfirmed=true`；TUI 先显示宿主确认框。
- `auth.set/status` 携带 `settingsSessionID` 时使用同一绑定；不带会话仍走运行中 Provider 的既有路径。
- 设置帧、日志、配置中不含 Key；Key 输入仍走 TUI 隐藏输入。

**回归测试**：`settingsCredentialCrossPluginDenied`、`settingsDisabledCredentialIsolation`（Keychain
门控：禁用 MiMo 首次写入、错误插件删除被拒、MiMo 自己确认删除）、`SETTINGS-004`（真实 PTY +
Keychain）。

## P0-3 Settings-Only Host 权限

**修复**：设置 Host 以空 grants 启动，不再继承 `vcr`/`record`/故障注入；Bundle ID 与注册表记录
校验；不注册 Provider、Hook、Tool。**回归**：`settingsOnlyHostDropsRunGrants` 用 `badframe` grant
证明设置 Host 没有收到运行授权；MiMo 禁用时 `hello.models` 为空。

剩余风险：Host 仍加载插件动态库，协议级隔离不是 OS 沙箱；已写入 ADR-0008。

## P0-4 会话残留与竞态

**根因**：`open` 关闭旧 session 但没有先 `sessions.removeValue`；`input/save` 在 Host 崩溃后不清理
会话；取消与保存没有互斥；100 次打开关闭会累积 addressable session。

**修复**：先移除旧 session 再关闭；`input/resize` 失败移除并关闭 Host；`cancel` 插入 cancelled
标记，保存中取消由保存回滚；`close` 防御性移除 map；`open` 用 `opening` 防重复；保存成功/取消
清空 TUI 队列。**回归**：`settingsSessionReplaced`、`settingsSessionChurn`（100 次）、
`settingsCancelDuringSave`、`settingsHostCrashIsolation`、`SETTINGS-003`。

## P0-5 禁用插件凭据

**修复**：`settings.credential` 的绑定来自插件声明而非运行中 Provider；`auth.set` 允许带
`settingsSessionID` 的禁用插件路径。禁用插件不注册路由，但可配置自己的 Key。**回归**：
`settingsDisabledCredentialIsolation`（真实 Keychain，禁用 MiMo 写/读/删除，其他插件删除被拒）、
`SETTINGS-004`（设置页面隐藏输入、删除确认、重开状态）。

## P0-6 CI 门禁

`.github/workflows/ci.yml`：
- TUI 专用步骤 filter 改为 `TUI_00[123]_|SETTINGS_00[123]_`，并 `tee`/`grep 'Test run with'` 记录数量。
- Keychain 步骤 filter 增加 `settingsDisabledCredentialIsolation|SETTINGS_004`。
- 新增 Plugin settings/MiMo offline contract 步骤，记录执行数量。
- 不使用真实 API Key，不把失败标绿。

## P1 审计结果

- **P1-1 推理上下文**：Provider Adapter 现在按 execution 内存保留 reasoning（上限 16 KiB、64 个
  execution），工具轮之间传给 MiMo Chat `reasoning_content` 与 Responses reasoning item；最终终态/
  失败/取消清理，不写入事件日志。新增 `MIMO_chatReasoningToolRoundTrip`。Responses 真实 item 形状
  未在线验证。
- **P1-2 双协议边界**：新增 HTTP 401/429/500、Chat EOF 无终态、Responses 重复 sequence/重复终态
  测试；已有 Responses incomplete/failed、取消、usage、工具调用去重测试。
- **P1-3 设置/模型一致性**：MiMo 在 `modelDetails` 声明 3 个思考选项但**不声明默认等级**，TUI
  不再把静态默认当成生效值；设置页是实际模式唯一来源。`preferredModel` 作为 TUI 新会话选择提示
  持久化，Core 路由仍是唯一决定者。新增 `mimoSettingsPage` 重启后 `preferredModel` 断言。
- **P1-4 配置恢复**：文件不存在 → 默认；损坏/版本/读取失败 → 显式错误，不自动清空。新增
  `settingsCorruptConfigIsExplicit`、`settingsStoreRejectsUnknownVersion`。
- **P1-5 Unicode**：宽度按 grapheme 计算，组合附加符号/VS/ZWJ 不消耗额外单元格；新增 CJK、
  emoji 家庭、零宽组合符、超长 span、颜色/控制字符测试。小终端/快速 resize 由 TUI 容器自适应，
  仍建议主人做一次视觉确认。

## 测试结果

离线主套件：199 个测试通过（104 + 4 + 91）。
CI TUI/Settings PTY 门禁：6 个测试通过（TUI-001/002/003、SETTINGS-001/002/003）。
CI Keychain 门禁：9 个测试通过（4 + 5：AUTH_、settingsDisabledCredentialIsolation、SETTINGS-004）。
CI settings/MiMo 契约门禁：51 个测试通过。
`swift test --filter 'MiMo|MIMO'`：21 个测试通过。

## 未验证 / 需要用户确认

- **真实 API 未执行**：无 `MIMO_API_KEY`；Responses、思考参数、真实工具续接仍只有离线证据。
  录制脚本已保留：`Scripts/mimo-record-responses.sh`。
- **主观视觉**：窄终端、Emoji 混排、设置页布局仍建议主人用真实终端扫一眼；自动化只保证不越界、
  不破坏边框、不泄漏控制序列。
- **OS 沙箱**：Settings-Only Host 是进程隔离 + 权限最小化，不是系统级沙箱。
