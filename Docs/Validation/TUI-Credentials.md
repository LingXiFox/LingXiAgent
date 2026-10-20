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
