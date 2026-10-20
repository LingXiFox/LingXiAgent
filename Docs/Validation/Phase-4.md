# Phase 4 验收记录：可交互 Core + TUI

> **状态：已验收（自动化与离线端到端）；真实 API 的 TUI 手动验收待主人执行** —— 合并提交 `5251a0b`，
> 139 tests（104 内核 + 35 契约，主套件跳过 PTY 与 live，PTY 由 CI 独立步骤执行），CI run `39407552292`
> success，零告警。TUI 端到端使用真实 Core 进程、真实 MiMo 插件进程与脱敏 cassette；真实网络验证见第四节。

## 一、交付

| 能力 | 落点 |
|---|---|
| 常驻 Core 前端服务 | `Sources/LingXiCoreHost/FrontendServer.swift` + `LINGXI_FRONTEND=stdio`；请求/回复/事件按行 JSON |
| 流式聊天 | `AgentLoop.run(..., observe:)` 只观测不改判定；文本增量经 `delta` 事件直达 TUI |
| 会话 | `sessions.list` / `session.history` / `session.new`；历史来自 SessionStore（事件日志恢复） |
| 取消 | `run.cancel` 取消 Run Task 与在途 Provider 请求；TUI Esc/Ctrl-C 触发 |
| 插件管理 | `plugins.list` / `plugin.enable` / `plugin.disable`；能力与权限来自注册表缓存；启停即时更新模型路由与 Hook |
| TUI | `Sources/LingXiTUI`：raw mode、备用屏、行编辑（含中文 UTF-8）、CJK 宽度换行、滚动、Markdown 子集（代码块/标题/行内代码/加粗）、流式光标、状态栏 |
| 协议文档 | `Docs/Frontend-Protocol.md` |
| 一键打包 | `Scripts/tui-setup.sh`：构建、组装并 ad-hoc 签名 MiMo `.lxap`、写 `dist/data/plugins.json`，打印运行命令 |

视觉：炭黑背景、奶白正文、狐橙强调；无动画特效。TUI **不加载**任何 Provider 或动态库。

## 二、证据

| 要求 | 用例 |
|---|---|
| 真实 Core + 真实 MiMo 插件跑流式聊天 | `FE_007_protocolEndToEnd`（cassette 回放，断言增量拼接出 `pong`） |
| 会话列表与会话历史 | 同上（标题为中文首条消息，历史含 user/assistant） |
| 插件禁用 → 模型消失、再启用 → 恢复 | 同上（禁用后模型列表为空，新请求在触达插件前被拒；重新启用后再次聊天成功） |
| 真实 PTY 中运行 TUI、中文输入、流式回复、插件面板、干净退出 | `TUI_001_ptyChatWithMiMo`（`/usr/bin/script` 提供 PTY，真实 TUI + 真实 Core + 真实 MiMo 插件） |
| 原 137 项不回归 | 139 = 104 + 35，连跑 3 次全绿 |

## 三、过程中修掉的真实缺陷

1. **启动竞态**：Core 启用插件需要时间，用户在 `hello` 返回前发送消息会被吞掉；现在无模型时把文本放回输入框并提示“正在加载”。
2. **grants 未接线**：Core 启动恢复插件时没把注册表里的 `grants` 传下去，VCR 测试直接打到真实网络并报缺凭据；三处启用路径已统一。

## 四、真实 API 手动验收（待主人）

```bash
./Scripts/tui-setup.sh
MIMO_API_KEY=... LINGXI_PLUGIN_POLICY=development LINGXI_DATA_DIR="$PWD/dist/data" swift run LingXiTUI
```

预期：进入备用屏，标题显示 `mimo-v2.6-flash`；输入中文得到真实流式回复；`/plugins` 显示 MiMo 的
`provider.mimo` 能力；`/models` 列出两个模型；Esc 可取消；`/quit` 退出且无残留 Host 进程。

## 五、未完成与风险

1. **Stage 3 能力插件**（Skills/MCP/Project Rules/Coding）未开始，按指示后续按需开发。
2. **终端尺寸变化**已实现（每帧重读 winsize、SIGWINCH 重绘），但自动化只覆盖固定尺寸；FE-006 保持进行中。
3. **Markdown 是子集**：代码块、标题、行内代码、加粗；无表格/图片/嵌套列表。
4. **会话排序**按 id 字典序，没有时间戳；TUI 不自动载入最近会话。
5. **输入编辑**是单行，无历史回溯（↑/↓ 用于滚动）。
6. **控制面/前端协议**都没有鉴权：仅本机 stdio，TUI 与 Core 是父子进程；不得暴露到网络。
7. **TUI 测试依赖 `/usr/bin/script`** 提供 PTY（macOS 自带），CI 上已验证。

## 六、CI

| 项 | 值 |
|---|---|
| Run ID | `39407552292` |
| URL | https://github.com/LingXiFox/LingXiAgent/actions/runs/39407552292 |
| head SHA | `5251a0b` |
| Conclusion | success |
| runner 工具链 | Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)；xcode: /Applications/Xcode_26.6.0.app |
| 主套件 | `Test run with 139 tests ... passed`（live ×2 与 PTY 跳过） |
| PTY 步骤 | `LINGXI_RUN_TUI_PTY_TEST=1 swift test --filter TUI_001_ptyChatWithMiMo`，主套件之后单独执行，不与进程密集测试竞争 |

CI 期间修复的真实问题：协议测试的回复游标竞态、CI 负载下过紧的慢速窗口与超时上界、PTY 测试与十余个进程测试并行导致的饥饿（改为独立步骤）。
