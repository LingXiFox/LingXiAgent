# CEF 原生浏览器验证 — 2026-09-30

结论：SwiftUI 原生嵌入 CEF、用户与 Playwright 操作同一 document 的基础链路已经通过。整体替换方案尚未通过：持续连接驱动时的新弹窗接管失败，完整退出流程也未通过。本轮不修改产品 GUI、Core、TUI 或 sidecar，不据此启动全量迁移。

## 环境与隔离

macOS 27.2（26B5091g），Apple Silicon arm64，Swift 6.4。使用官方 CEF 154.0.32+g682c378 / Chromium 154.0.8037.58 minimal SDK；压缩包 SHA-1 与官方构建索引一致。使用项目已有 Playwright 1.63.0，通过 CDP 接入独立测试宿主。

宿主由本地编译的 Objective-C++ 代码、NSHostingView / NSViewRepresentable 和官方 CEF wrapper 组成。页面采用原生窗口视图，没有使用截图串流。CEF Helper 沙箱初始化保持开启，未使用 `--no-sandbox`。Framework 按官方版本目录及 symlink 布局打包；主程序、Helper 与 framework 完成本地 ad hoc 开发签名，`codesign --verify --deep --strict` 通过。这不代表 Developer ID 签名或公证通过。

测试页面、iframe、上传及下载文件均由本轮自行生成，服务器仅绑定 127.0.0.1，浏览器使用独立临时配置目录。后续自动化构建使用 Chromium 的 `--use-mock-keychain` 测试选项，避免请求真实钥匙串；没有测试真实登录或密码持久化，也不将此选项作为产品配置。没有读取或填写用户的钥匙串密码。

## 实测结果

| 检查 | 结果 | 证据范围 |
| --- | --- | --- |
| SwiftUI 内原生页面可见 | PASS | 原生窗口 AX 树含完整 HTML 页面与 iframe，实际窗口观察通过 |
| 窗口缩放 | PASS | 原生 zoom 后页面 viewport 从 1000×679 变为 1920×1030 |
| 原生中文、emoji 粘贴 | PASS | DOM 收到 trusted input，文本完整 |
| 原生 ⌘A 全选、键盘替换、点击提交 | PASS | 原文被替换，提交结果一致，点击为 trusted |
| 原生窗口与 Playwright 的同页确认 | PASS | 两者 document ID 均为 `a74330c6-47a9-49c8-a092-f60ba36dc9f3` |
| 页面语义快照 | PASS | 包含输入框、按钮及 iframe；不是通过图片识别定位 |
| Playwright 中文输入、点击与 ⌘A 替换 | PASS | 核对实际输入值及提交结果 |
| iframe 输入 | PASS | 读取值与写入值一致；仅同源 iframe |
| 文件上传 | PASS | 自建文件赋值，change 后页面显示正确文件名；未验证原生文件选择器 |
| 下载 | PASS | 自建下载文件内容逐字核对；由 Playwright 接管下载，未验证产品原生下载界面 |
| 10 轮写入、点击、读取确认 | PASS | 所有结果正确，document ID 始终不变 |
| 驱动持续连接时新弹窗自动接管 | FAIL | 两次复现，详见下文 |
| 驱动断开后的原生弹窗、随后重连 | PASS | 原生弹窗能打开和提交；重连识别相同弹窗 document 并操作 |
| 所有窗口关闭后完整 CEF 退出 | FAIL | 主页面释放可通过，完整退出未出现 `CEF_SHUTDOWN_OK` |

基础输入与性能结果对应第 5 次测试构建。第 6、7 次仅验证弹窗退出的替代处理，两次失败，均未采纳；不能将基础检查的通过结果表述为这些失败构建整体通过。

## 弹窗阻塞

默认 Alloy 弹窗在持续连接 Playwright 时，CEF 已触发 `OnAfterCreated`，但新目标最初以 `type: "other"`、`waitingForDebugger: true` 上报。Playwright 随后发送 `Runtime.runIfWaitingForDebugger`，该命令没有在检查时限内返回，新页面事件等待超时，弹窗目标 URL 保持为空。

断开驱动后，原生点击创建的弹窗能正常加载及交互。重连 Playwright 可识别已经加载的弹窗，并验证相同 document ID；这证明“原生弹窗”和“已存在弹窗控制”可行，不能把断开重连作为自动弹窗接管已经修复的证据。

保留的 [协议片段](browser-cef-poc-2026-09-30/popup-protocol-excerpt.log) 记录该现象。尚未将原因定位到 CEF SDK、Playwright 或宿主初始化中的某一处，因此不作上游缺陷归因。

## 宿主修正与失败保留

1. 最初在 SwiftUI 容器获得尺寸前创建浏览器，实测 viewport 为 0×0。改为容器挂入窗口并取得非零尺寸后创建，并传播原生布局尺寸，页面显示与窗口缩放通过。
2. 后续白屏期间，用户指出尚未输入钥匙串密码；授权完成后页面显示。不能把这段白屏当作渲染兼容性失败。
3. 通过 `/private/tmp` 的实际路径启动后，不再出现 `/tmp` 别名对应的 sandbox-extension 警告。
4. 主窗口关闭时释放 NSHostingView / 容器引用后，记录到主浏览器 `OnBeforeClose`；默认原生弹窗仍未完成关闭回调，进程仍驻留。
5. 在 `DoClose` 中同步拆除弹窗视图的实验记录到弹窗关闭回调后触发 SIGSEGV，已弃用。
6. 通过 `OnBeforePopup` 请求 Chrome 风格弹窗的混合配置，在创建时触发 SIGSEGV，已弃用。API 存在不等于该混合配置已确认兼容。

[宿主日志与崩溃摘要](browser-cef-poc-2026-09-30/evidence.json) 保留所有结论对应的构建尝试。失败仍可能包含本轮最小宿主自身的生命周期问题，不能据此声称 CEF 整体不可用。

## 性能

主窗口 zoom 后，1920×1030 的静态页面及一个 iframe，驱动断开、弹窗关闭、无串流；采样覆盖宿主及所有后代进程，6 个进程，15 个约 1 秒区间。

| 指标 | 实测值 | 限制 |
| --- | --- | --- |
| 空闲 CPU | 平均约 0.0017% 单核，区间峰值约 0.0071% | 通过 `proc_pid_rusage` 累计 CPU 时间差计算；只代表本地静态页面的短时空闲 |
| 任务物理占用合计 | 中位数约 305.65 MiB | 合计内核报告的 per-task footprint，不能视为整个进程树的独占物理内存 |
| RSS 合计 | 中位数约 766.89 MiB | 会重复计算共享内存 |
| 写入 + 点击 + 读取 | 10 轮中位数约 32.98 ms | 热 CDP 连接、本地简单页面；不含模型、授权、Core 调度 |
| 开发 app 体积 | 约 323.45 MiB | CEF、wrapper、SwiftUI 宿主与 Helpers；不是正式产品增量的精确测量 |
| GPU | NOT RUN | 未进行需要管理员权限的 GPU 采样，不能宣称 GPU 已降低 |

这些指标不能直接与上一轮独立 Chrome 的两个标签页配置比较，也不代表 LingXiAgent 完整 GUI 的资源占用。第一轮较小窗口测得的任务 footprint 约 235 MiB，不作为铺满屏幕配置的最终数字。

## 尚未验证与后续判断

中文输入法组合输入、候选窗未测；Unicode 粘贴或 CDP insertText 不等于 IME 验证。GUI/TUI/Core 共享会话、权限链、Agent 暂停、用户接管、取消、隔离、崩溃恢复、真实网站与登录持久化均未验证；桌面 computer-use 后端也未验证。

共享 Chromium document 的目标得到支持。当前 CEF + Playwright 原型仍有弹窗接管和完整退出阻塞，暂不作为“最优解”定案，也不启动产品全量替换。下一步应先完成这两个阻塞的最小复现与兼容性判断，再决定继续 CEF 还是调整宿主方案。

## 证据与官方参考

- [原始检查、签名信息、采样和失败记录](browser-cef-poc-2026-09-30/evidence.json)
- [实际页面截图](browser-cef-poc-2026-09-30/shared-native-page.png)：CDP 页面截图，原生窗口嵌入另由窗口 AX 与实际观察核验。
- [CEF 官方构建](https://cef-builds.spotifycdn.com/index.html)
- [CEF macOS 示例主程序](https://github.com/chromiumembedded/cef/blob/master/tests/cefsimple/cefsimple_mac.mm)
- [CEF Helper 沙箱示例](https://github.com/chromiumembedded/cef/blob/master/tests/cefsimple/process_helper_mac.cc)
- [CEF 生命周期处理契约](https://github.com/chromiumembedded/cef/blob/master/include/cef_life_span_handler.h)
- [Playwright CDP 连接说明](https://playwright.dev/docs/api/class-browsertype#browser-type-connect-over-cdp)：官方说明其连接保真度低于 Playwright 协议连接。
- [Playwright 自身使用的 Chromium 测试参数](https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/server/chromium/chromiumSwitches.ts)
