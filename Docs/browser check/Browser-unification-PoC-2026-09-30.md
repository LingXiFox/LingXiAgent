# 浏览器统一方案最小验证 — 2026-09-30

结论：浏览器驱动基础验证完成，整体原生嵌入方案尚未通过。当前证据不足以启动 CEF + agent-browser 全量替换。Playwright 在相同页面上的 macOS 全选操作通过；agent-browser 的已安装版本及当前发布版本均失败。后续应保留共享 Chromium 页面这一目标，根据实际兼容性选择驱动。

## 范围与环境

- macOS 27.2 / Apple Silicon arm64。
- Google Chrome 153.0.8010.53；使用独立的临时用户数据目录，只访问绑定在 127.0.0.1 的自建页面。
- agent-browser 0.33.2（本机安装版本）及 0.38.1（本次独立下载，未升级全局版本）。两者均核对官方 release SHA-256，并通过本机 Mach-O 签名校验。
- Playwright 1.63.0，来自项目已有依赖，通过 CDP 连接同一受管 Chrome。
- CEF 154.0.32 / Chromium 154.0.8037.58 官方 ARM64 client 包，SHA-1 与官方索引一致，但 bundle/Mach-O 签名检查报告 `code has no resources but signature indicates they must be present`。未运行、未重新签名、未修改系统安全策略。签名校验失败不等同于 CEF 浏览器兼容性失败。
- 未修改产品 GUI、TUI、Core 或现有 sidecar。下载、测试代码、浏览器配置和进程均在临时目录，测试结束清理。

## 实测结果

| 检查 | agent-browser 0.33.2 | agent-browser 0.38.1 |
| --- | --- | --- |
| 页面语义快照及 iframe 输入框 | PASS | PASS |
| 中文、英文、emoji 写入及点击 | PASS | PASS |
| 操作前后 document ID 一致 | PASS | PASS |
| `Meta+A` 后输入应替换原文 | FAIL | FAIL |
| iframe 元素引用写入 | PASS | PASS |
| 上传文件赋值及 change 事件 | PASS | PASS |
| 下载文件内容核对 | PASS | PASS |
| 页面按钮弹出第二标签页 | PASS | PASS |

上传和下载均使用自行生成的无敏感内容文件。上述命令直接调用驱动，没有经过 LingXiAgent 的模型、权限及工具链，不代表产品授权流程已验证。

共享页面的 `window.poc.documentId` 在两套驱动间保持为 `29902658-b55b-4000-bd3b-5767bdac9fcc`。这证明驱动连接并操作的是同一个 document；不代表 GUI/TUI 共享会话已实现。

### 全选失败复现

对本地页面输入框执行以下操作：

```text
fill #message "中文共享页面验证 LingXiAgent 🦊"
focus #message
press Meta+a
keyboard inserttext "快捷键替换成功"
get value #message
```

期望：`快捷键替换成功`。

实际：`中文共享页面验证 LingXiAgent 🦊快捷键替换成功`。

`press` 命令报告成功，但没有完成全选。此问题在 0.33.2、0.38.1 均复现。使用同一 Chrome、同一页面的 Playwright `keyboard.press('Meta+A')` 后再 `keyboard.insertText(...)`，实际得到替换后的文本，检查通过。未用 DOM 脚本替代全选来掩盖失败。

该问题与上游报告的 macOS 原生编辑命令缺失有关，但本轮未追踪 Rust 驱动源码，不能将该报告作为已证实的根因。

## 性能

| 指标 | 实测值 | 限制 |
| --- | --- | --- |
| 静态页面 CPU | 平均约 0.064% 单核；采样峰值约 0.96% | Chrome 进程树，关闭串流，2 个本地标签页和 iframe，15 个约 1 秒区间；由累计 CPU 时间差计算，短时采样精度有限 |
| 进程树 RSS 合计 | 中位数约 1121.73 MiB | 7 个进程；共享内存会重复计数，不能视为独占内存或 CEF 的内存数据 |
| Playwright 写入 + 点击 + 读取确认 | 10 轮，中位数约 32.82 ms | 热连接、本地简单页面；不含模型推理、工具授权、跨进程 Core 调度、截图及 GUI 绘制 |
| GPU | NOT RUN | `powermetrics` 要求管理员权限；未提升权限，不能声称 GPU 下降 |
| CEF 官方 sample 包 | 压缩约 126.65 MiB；展开 app 约 326.38 MiB | 开发 sample 包大小，并非未来产品新增体积的精确估计 |

无法从本轮结果判断 CEF 比 WKWebView 更省 GPU，也无法将驱动命令响应时间当作整个 Agent 的响应时间。

## 未验证项目

- CEF 与 agent-browser/Playwright 的 CDP 互操作、SwiftUI 原生嵌入。
- GUI/TUI 真实共享控制、用户接管与 Agent 暂停、取消及窗口关闭。
- 中文输入法组合输入与候选窗、原生复制粘贴。Unicode 写入通过不等同于输入法验证。
- 登录状态持久化、多个会话隔离、真实网站的导航/弹窗/跨域 iframe。
- Cua Driver 桌面操作及其与产品权限链的结合。
- GPU 归因和不同展示路径的对比。

## 下一步判断

优先验证具有合规开发签名的原生 CEF 宿主与 CDP 驱动，而非直接修改主 GUI。驱动目前优先使用已通过键盘检查的 Playwright；这是实测行为的选择，不是保留历史实现的理由。自研 browser-host 和页面选择器逻辑仍可重构，GUI 的独立 WKWebView 不应继续充当 Agent 页面。

如继续评估 agent-browser，应先解决或明确屏蔽其不受支持的 macOS 编辑操作，并测试中文输入法、接管、剪贴板与权限。不能把命令返回成功作为页面操作成功的依据。

## 证据

- [原始检查、签名记录与采样数据](browser-poc-2026-09-30/evidence.json)
- [同一页面的 Playwright 操作结果截图](browser-poc-2026-09-30/shared-page.png)
- [CEF 官方构建](https://cef-builds.spotifycdn.com/index.html)
- [agent-browser 0.38.1 发布](https://github.com/vercel-labs/agent-browser/releases/tag/v0.38.1)
- [macOS 编辑快捷键上游报告](https://github.com/vercel-labs/agent-browser/issues/1453)
