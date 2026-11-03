# Phase 0 · 已知问题

按影响排序。每条都注明现状、影响与后续处理，**没有隐瞒未完成项**。

## P0 — 验收范围内的缺口

### 1. Windows / Linux 仅编译，未运行验收

- 现状：macOS 完成全部手工验收；Windows/Linux 由 CI 做 `cargo check/test` 与 `pnpm build`，没有实机启动记录。
- 影响：跨平台「构建链路」可验证，「运行行为」不可承诺。WebView2 / WebKitGTK 的拖拽、文件对话框、事件时序均可能与 macOS 不同。
- 计划：Phase 1 起在 Windows 11 与 Ubuntu 24.04 上跑同一份验收清单，结果写入 `04-testing-and-acceptance.md`。

### 2. 安装包未签名、未公证

- 现状：`tauri build` 产出未签名 `.app`/`.dmg`；macOS 首次打开需右键，Windows SmartScreen 会告警。
- 影响：不能分发给终端用户，只适合开发验证。
- 计划：Phase 1 接入 Apple Developer ID + notarytool、Windows 代码签名；证书与密钥不进入仓库。

## P1 — 功能与交互

### 3. 运行事件不可重放

- 现状：事件只通过 `lingxi:run-event` 单向推送，没有序号缓冲或快照。WebView 中途刷新/重载会丢失已发事件，Rust 侧运行仍继续到结束。
- 影响：刷新后 UI 显示「未运行」，但后台任务可能仍在跑；此时再点运行会叠加第二个 run。
- 计划：Phase 1 给事件加全局递增序号 + 每 run 环形缓冲，重连时补发；或运行中禁止重载并提示。

### 4. UI 只允许单运行

- 现状：`status === "running"` 时运行按钮禁用；引擎本身支持多 run 并发。
- 影响：无法对比两条分支，也无法在后台保留长任务。
- 计划：Phase 2 引入 run 列表与每 run 独立日志，不改引擎。

### 5. 无撤销/重做、复制/粘贴

- 现状：React Flow 提供选中、删除；没有 history stack 与剪贴板。
- 影响：误删只能重新拖节点，复杂图编辑效率低。
- 计划：Phase 1 用命令式 `useHistory` 包住节点/边变更，快捷键 Cmd/Ctrl+Z、Shift+Cmd/Ctrl+Z、Cmd/Ctrl+C/V。

### 6. 关闭窗口不提示未保存

- 现状：没有 dirty 标记与 `beforeunload` 拦截。
- 影响：直接关窗丢失画布修改。
- 计划：Phase 1 增加 dirty 状态与关闭确认。

### 7. 日志上限 600 行，无导出

- 现状：`App.tsx` 只保留最近 600 条；无搜索、过滤、导出。
- 影响：长运行会丢早期日志；排障只能看尾部。
- 计划：Phase 1 增加级别过滤与「导出 JSONL」；持久化留给运行历史。

### 8. 交互弹窗只支持批准/拒绝

- 现状：协议里 `options[]` 已定义并传输，`InteractionDialog` 固定渲染两个按钮，忽略自定义选项。
- 影响：需要多选/自由输入的节点无法表达。
- 计划：Phase 2 扩展 `InteractionDecision` 为 `Choice { value }` / `Text { value }`，弹窗按 options 渲染。

## P2 — 架构与扩展点

### 9. 插件只能编译期注册

- 现状：`NodeRegistry` 公开 `register`，但宿主只注册内置 7 个节点；没有动态库加载、清单、版本协商。
- 影响：第三方节点需重新编译应用。
- 计划：Phase 2 设计进程内 WASM 或子进程 JSON-RPC 插件宿主；明确拒绝 2.0 的 C ABI/dlopen 路线（见 `00-reuse-audit.md`）。

### 10. 能力策略生产环境为 AllowAll

- 现状：`apps/desktop/src-tauri/src/lib.rs` 注入 `AllowAllPolicy`；执行器已经过 `CapabilityPolicy::authorize`，但没有用户可见的授权界面，也没有持久化规则。
- 影响：节点可声明任意 capability 并被放行；权限层目前是「结构就位、策略为空」。
- 计划：Phase 2 引入按工作流/节点的授权清单、首次运行询问与审计日志；默认拒绝未知 capability。

### 11. 无运行历史与 SQLite

- 现状：工作流存 JSON 文件；run 结果只在内存与 UI 日志里，不落库。SQLite 未引入。
- 影响：无法回看历史运行、统计耗时、对比输出。
- 计划：Phase 1 末引入 SQLite（`runs`/`run_events`/`node_outputs` 三表），JSON 仍为工作流交换格式。

### 12. 校验不检查不可达节点

- 现状：`validation.rs` 检查 schema、参数、边、端口、类型、环、必填输入；孤立节点（无入边且非源头）不会报错。
- 影响：画布上的废弃节点仍会执行（无依赖节点按文档顺序执行）。
- 计划：Phase 1 增加 `graph.unreachable` 警告（有向可达性从无入边节点出发），不阻断运行。

### 13. 只支持中文 UI

- 现状：所有文案硬编码中文，无 i18n 框架。
- 影响：非中文用户体验不完整；代码中的可访问性标签中英混用。
- 计划：Phase 2 抽 `messages.ts`，按 locale 切换，默认跟随系统。

## P3 — 工程卫生

### 14. CI 只覆盖编译与单测

- 现状：`.github/workflows/ci.yml` 跑 fmt、clippy、test、前端 build；不跑 Tauri 打包，不做 UI 自动化。
- 影响：打包回归只能在本地发现。
- 计划：Phase 1 在 macOS runner 上跑 `tauri build`（不签名），Windows/Linux 先保持编译门禁。

### 15. 前端无组件测试

- 现状：UI 逻辑靠手工验收与浏览器 mock；没有 Vitest/Playwright。
- 影响：画布交互回归成本高。
- 计划：Phase 1 引入 Playwright，用 mock transport 覆盖「拖入节点→连线→保存」主路径。

### 16. 大工作流未做性能验证

- 现状：每次命令克隆整份 `Workflow`；React Flow 未开虚拟化。已验证规模仅十余节点。
- 影响：上千节点时序列化与渲染可能卡顿。
- 计划：Phase 1 用 500/2000 节点基准测 `validate_workflow` 与画布帧率，再决定是否改为增量 patch。

### 17. 依赖审计未接入

- 现状：无 `cargo deny` / `pnpm audit` 门禁；锁文件已提交。
- 影响：供应链漏洞不会自动暴露。
- 计划：Phase 1 加只读审计 job，不阻塞合并，先观察噪音。
