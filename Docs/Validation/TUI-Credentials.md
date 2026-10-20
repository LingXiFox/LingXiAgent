# TUI 凭据托管验收（2026-10-20）

## 已实现

- `/auth mimo` 首次配置；`update`、`remove`、`status` 分别更新、移除、查看状态。
- `Security.framework` 文件型 Keychain；Core 独占存储接口，Host 继续使用原有独立进程与环境白名单。
- 通用声明限一个 API Key；凭据按 bundle/provider/requirement 隔离，每次调用重新获取，不缓存。
- 隐藏输入不使用聊天缓冲；拒绝多行粘贴；取消、更新和移除后均可继续交互。
- 环境源需显式选择且有操作者映射；脚本只在文件缺失时创建注册表和变量名映射，不覆盖现有文件。

## 本机证据

平台：Apple Silicon，macOS 27.2；Apple Swift 6.4.2。生产目标仍为 Package.swift 声明的 macOS 26。

| 检查 | 结果 | 证据 |
|---|---|---|
| `swift test` | 140 实际通过，6 门禁跳过；总计 146 项 | `.tmp/auth-final-tests.log` |
| `LINGXI_RUN_KEYCHAIN_TESTS=1 LINGXI_RUN_TUI_PTY_TEST=1 swift test --skip-build --filter 'AUTH_\|TUI_001_ptyChatWithMiMo'` | 8 实际通过，0 跳过 | `.tmp/auth-final-keychain-pty.log` |
| 真实 Keychain | 写、读、更新、删；Core 退出重启后实际解密并完成回放请求 | `AUTH_002_realKeychain`、`AUTH_002_coreKeychainRestart` |
| 隐藏输入与重启 | 两次启动，无 MIMO_API_KEY；隐藏输入、多行粘贴拒绝、取消、更新、删除、随后聊天 | `AUTH_003_hiddenInputPTY` |
| 每次请求重新授权 | 原值→新值→nil，经过真实 adapter 与插件 IPC，无旧值缓存 | `AUTH_001_eachRequestUsesFreshGrant` |
| 禁用/启用保留 | 已保存 Key 在禁用期间仍有状态，启用后仍存在 | `AUTH_002_coreKeychainRestart` |
| 泄漏检查 | PTY、Core stdout/stderr、事件日志、注册表无测试 Key；Source/Plugins 的 Trivy secret scan 无发现 | 上述测试与 Trivy 扫描 |
| 设置脚本 | 真实运行两次，保留 disabled 状态、grants、自定义变量映射，SHA-256 完全相同 | `.tmp/auth-setup-first.log`、`.tmp/auth-setup-second.log` |

早期验收中修复了测试误读不存在的空 journal、以及全屏重绘使旧提示被误当作新输入状态的同步问题。
最终检查不把这些早期失败计为通过。Swift 6.4 本机 xUnit 输出为空，未把空报告当作执行证据；计数取实际 Swift Testing 运行结果。

## 仍须区分的边界

- 上述模型回复使用已有 cassette；不把回放称为真实 MiMo 调用。有效 Key 的真实网络验收需用户在隐藏输入中提供。
- macOS CI 新增独立 Keychain/PTY 步骤，不依赖真实 API Key；远端结果另行核对。
- SwiftPM ad-hoc 签名的 designated requirement 包含 cdhash，同一构建的重启访问已经验证。
  代码重建后可能需要 Keychain 重新授权；没有把 ACL 放宽到全部应用或可伪造的 identifier。
  发布版须使用稳定签名身份。参考 Apple [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
  与 [SecAccessCreate](https://developer.apple.com/documentation/security/secaccesscreate(_:_:_:))。


## 截图反馈后的 TUI 修复

用户截图：`Snapzy_2026-10-20_20-19-08_263.png`。原重绘只在整帧末尾清除屏幕，较短的行不能擦除旧命令，
且全量 reset 使背景回落到 Terminal profile。修复为绝对行坐标 + 每行清除、单元格裁剪、统一背景；
增加居中首页/输入区、Ctrl-P 和斜杠命令选择器、模型/会话/插件选择器，以及独立认证面板。

- `LINGXI_RUN_KEYCHAIN_TESTS=1 LINGXI_RUN_TUI_PTY_TEST=1 swift test --filter 'AUTH_|TUI_00'`：9 项实际通过，0 跳过。
- 新版 `swift test`：147 项中 140 实际通过、7 按门禁跳过，见 `.tmp/tui-redesign-all.log`。
- `TUI_002_frameAndPickers` 逐帧确认隐藏输入无 `/auth mimo` 残留，Key 字符不进入渲染，30 行均被定位并清除；
  同时覆盖模型键盘选择、中文/组合音标/emoji 长输入清除和 40×12 小终端。
- 实际 PTY 帧已输出首页、命令面板和认证区的 PNG，已人工检查；这是终端数据渲染，不是 macOS Terminal 原生截图。
- 独立测试 Keychain 命名空间下，真实 MiMo 上游对旧/更新后的无效 Key 均返回 HTTP 401；
  移除后下一次请求因 `no credential was granted` 在发网前失败；前端/事件日志/注册表未出现测试 Key。
- 初版凭据代码 `58a70a3` 的 macOS CI 已全通过：
  [39420969190](https://github.com/LingXiFox/LingXiAgent/actions/runs/39420969190)。新版 UI 另行执行 CI。
- 有效 Key 的真实 MiMo 成功响应仍待用户在隐藏输入中配置，不能拿 401 或 cassette 作为成功调用证据。


## macOS CI 调度问题

新版首轮 CI `39423513585` 未通过：`LOOP_023_disableDuringInFlightProviderRequest` 等待 `inFlightRequestCount > 0`
超时。CI 的 SwiftPM 将全部 147 项放在同一个测试进程，本机 Swift 6.4 分为三个进程。
公共 `waitUntil` 在 async 循环里调用 `usleep`，对同步条件的轮询可独占协作线程，阻止被观察的 Task 启动。
已把 deadline 轮询间隔改为可挂起的 Task.sleep；保留条件与截止时间，不扩大超时、不跳过测试。
对应 QA-002。修复后重新执行本机和远端验证，首轮失败仍保留为失败证据。


QA-002 的反例已实测：恢复旧阻塞轮询后用例在 10.028 秒失败，异步轮询版本在 0.027 秒通过。
随后全量启用 PTY/Keychain 的压力运行发现 TUI-002 的 5 秒启动断言短于实际插件 30 秒握手预算；
只把两处进程启动检查对齐该已有预算，输入/状态/重绘断言仍保留原截止时间。


最终本机全量运行 `LINGXI_RUN_KEYCHAIN_TESTS=1 LINGXI_RUN_TUI_PTY_TEST=1 swift test`：
148 项中 146 实际通过，仅 2 项有效凭据上游 smoke 按门禁跳过；见 `.tmp/tui-final-complete.log`。


CI `39424745991` 的轮询回归已通过，但暴露 `PLG_018_pluginCrashIsIsolated` 的提前断言：
Host 退出与协调器异步移除 Hook 并非同一时刻。已改为等待 Hook 实际移除，仍按原 deadline 超时失败，
不以 Host 已退出代替清理结果；生产代码没有为此改变。

## 继续对标 OpenCode v2：编辑与会话

参考 v2 分支的 [prompt](https://github.com/anomalyco/opencode/blob/v2/packages/tui/src/component/prompt/index.tsx)
与 [session](https://github.com/anomalyco/opencode/blob/v2/packages/tui/src/routes/session/index.tsx) 的交互分层，
沿用现有 Swift 渲染器，不增加依赖、不改变 Kernel、Core 协议或 Plugin Host。

- 多行编辑、Ctrl-J 换行、独立序列的 Shift/Alt-Enter；输入区最多显示 6 行，随光标滚动。
- 带括号粘贴仅插入文字；CRLF/CR/LF 统一为换行。选择器粘贴只过滤，不能触发确认。
- 本进程最多 100 条聊天输入召回并保留原草稿；命令和隐藏凭据不进入召回。
- 思考与正式回答按到达顺序显示，默认折叠，Ctrl-T 展开；无持久化的推理不伪造历史。
- 修复丢弃 `chat.send` 会话 ID 导致每轮新建会话的问题；生成中保留草稿并限制切换会话。
- 调整用户消息底色、回答标识、会话标题与输入区信息层次；单行区域不允许原始换行破坏行定位。

本机全量 `LINGXI_RUN_KEYCHAIN_TESTS=1 LINGXI_RUN_TUI_PTY_TEST=1 swift test`：
149 项中 147 实际通过、2 项有效凭据真实上游 smoke 按门禁跳过，零告警；
证据 `.tmp/tui-v2-final-tests.log`。AUTH-003 额外断言凭据不能被 ↑ 召回。

`TUI_003_editorAndSessionContinuity` 跨真实 PTY、Core 与 MiMo 回放：混合换行粘贴、行内编辑、草稿保留、
历史往返、思考展开/收起、连续两轮、重启后的单会话两轮历史全部通过。
临时注回丢弃会话 ID 的旧行为，该用例在“2 轮”断言失败（9.085 秒），见
`.tmp/tui-v2-session-counterexample.log`；已恢复修复版本后执行上述全量回归。
Trivy 对 `Sources/`、`ContractTests/` 的 secret scan 均无发现。

有效 Key 的真实 MiMo 成功调用仍未复验；本轮模型输出使用 cassette。
原生 Terminal 窗口的手工验收未执行；PTY 渲染预览不作为原生窗口截图。

`69280fd` 的 macOS CI 全绿：[39434186422](https://github.com/LingXiFox/LingXiAgent/actions/runs/39434186422)。
随后复核补齐 AUTH-003 的分段粘贴取消场景：取消后一直丢弃到 paste-end，不把迟到的密钥尾部插回普通草稿。
移除该保护后测试能检测尾部泄漏并失败（2.047 秒）；恢复保护后通过。
证据 `.tmp/tui-v2-paste-cancel-counterexample.log`、`.tmp/tui-v2-paste-cancel-test.log`；
这次全量并发压力运行（`.tmp/tui-v2-security-final-tests.log`）在测试清理中挂起，已终止，不计为通过。

`834dd8a` 的 macOS CI 全绿：[39434805678](https://github.com/LingXiFox/LingXiAgent/actions/runs/39434805678)。
本机上述挂起的采样显示 Core 已退出，测试辅助 `ProtocolCore.terminate()` 仍停在 Foundation `waitUntilExit()` 的
RunLoop 中，见 `.tmp/tui-v2-test-wait-sample.txt`。Apple 的
[API 文档](https://developer.apple.com/documentation/foundation/process/waituntilexit()) 也说明其内部轮询当前 RunLoop。
现将 Core/PTY 测试清理改为有截止时间的状态轮询，必要时强制回收；强制回收后未退出必须报错。
`QA_002_processCleanupIsBounded` 覆盖尚未退出时到期、自然退出和已退出时立即返回，不修改产品代码。
修复后全量开启 Keychain/PTY 的本机回归：150 项中 148 实际通过、2 项真实上游 smoke 按门禁跳过；
契约组 42 项在 5.978 秒内结束，证据 `.tmp/tui-v2-cleanup-final-tests.log`。此前挂起不被这次通过覆盖。
