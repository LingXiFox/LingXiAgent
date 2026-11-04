# Phase 1.5 测试与验收

状态：代码与自动化验收完成；跨平台结果以提交后的 CI 为准
分支：`rewrite/3.0`

## 1. 验收环境

| 项目 | 值 |
| --- | --- |
| 主机 | macOS 27.3 arm64（Apple Silicon） |
| Rust | rustc 1.99.1（Homebrew） |
| Node / pnpm | Node v26.13.0 / pnpm 9.15.9 |
| Tauri | 2.x，debug binary `target/debug/lingxi-desktop` |
| 浏览器 E2E | Playwright 1.56.1 + 对应 Chromium 141（CI 同一浏览器） |
| 原生 E2E | WebdriverIO + `@wdio/tauri-service` embedded driver |
| Provider mock | 本地 HTTP/SSE 服务 `127.0.0.1:11434`，分别模拟三条 wire protocol |

所有命令在仓库根目录或 `apps/desktop` 执行。没有真实 OpenAI/Anthropic 凭据，没有访问外部模型服务。

## 2. 自动化结果

### 2.1 Rust

`cargo test --workspace`：exit 0，**121 passed / 0 failed / 0 ignored**。

| 测试二进制 | 数量 | 覆盖 |
| --- | ---: | --- |
| desktop unit tests | 25 | SQLite、脱敏、工作流/模板资产闭包、Windows 覆盖保存、单实例、运行恢复、资产导入/预览 |
| runtime library unit tests | 1 | 媒体合并到最后一个 user turn |
| `agent_end_to_end.rs` | 13 | ReAct 工具闭环、Provider 错误、预算、取消、MCP、Skill、多实例隔离 |
| `agent_template.rs` | 1 | 标准 Agent 模板静态校验 |
| `composite.rs` | 10 | 组合执行、作用域事件、内部失败/取消/能力拒绝 |
| `control_flow.rs` | 7 | 条件分支、Loop Gate、预算耗尽、节点失败、取消 |
| `engine.rs` | 7 | DAG 顺序、依赖、能力拒绝、审批、超时、禁用节点 |
| `event_sequence.rs` | 2 | 事件序号连续、按运行重置 |
| `mcp_and_skills.rs` | 5 | stdio/HTTP MCP、崩溃、Skill 注入 |
| `media_assets.rs` | 5 | 资产去重/摘要、能力拒绝、图片 ContentPart、PDF/DOCX 抽取、媒体顺序 |
| `protocols.rs` | 10 | 三条协议的真实 HTTP/SSE 编解码、工具结果、推理分离、错误/超时/取消/断流 |
| `assets.rs`（spec） | 6 | 根资产表、非法 ID/摘要、引用校验、JSON 往返 |
| `control_flow_validation.rs` | 8 | 循环出口、预算、触发器、绕过 Gate 拒绝 |
| `subgraph_validation.rs` | 9 | 子图绑定、递归、嵌套、循环边界 |
| `validation.rs` | 12 | Schema、端口、边、参数、类型、JSON 往返 |

`protocols.rs` 的 10 项分别覆盖：OpenAI Chat 图片/音频编码；Responses SSE 与 usage；HTTP 错误与取消；超时与截断流；Responses `function_call_output` 与 `previous_response_id`；reasoning summary 不混入正文；Anthropic header/system/tool_result；Anthropic 图片与 thinking 分离；Anthropic 拒绝原生音频；两轮工具调用往返。

另有 `cargo fmt --all -- --check` 与 `cargo clippy --workspace --all-targets -- -D warnings` 在最终门禁执行，结果见第 7 节。

### 2.2 前端单元测试与构建

| 命令 | 结果 |
| --- | --- |
| `pnpm test:events` | 6 passed |
| `pnpm test:routing` | 13 passed |
| `pnpm test:composite` | 8 passed |
| `pnpm -C apps/desktop build` | tsc + Vite 成功；219 modules，主 JS 445.27 kB（gzip 140.82 kB） |

### 2.3 Playwright（浏览器 UI，mock transport）

命令：`pnpm -C apps/desktop test:e2e:web --reporter=line`

结果：**19 passed**，exit 0。总套件包含 5 项 Phase 1.4 回归（DAG 创建/连线/运行/持久化；移动与删除不逐帧 IPC；组合节点展开/模板；Agent 模板流式预览；静态校验错误）与下列 14 项本阶段验收。

| # | 用例 | 断言要点 |
| ---: | --- | --- |
| 1 | 侧栏折叠/展开 | rail 宽度、画布余量、toggle 可恢复 |
| 2 | 分组折叠记忆 | 刷新后 `localStorage` 状态保持 |
| 3 | 中文标签/描述 | 模型调用、工具调度、循环门等中文名与分组名可见 |
| 4 | 中英文搜索 | 中文、英文、kind 均命中并自动展开分组 |
| 5 | 三条 Provider 节点 | 三个 kind 均可从节点库创建 |
| 6 | 连接 Reasoning | 思考等级节点可接入 Model 的 `reasoning` 端口 |
| 7 | 能力状态展示 | 模型能力面板显示输入/输出支持与来源 |
| 8 | 图片选择/预览 | 导入后出现缩略图、尺寸与移除按钮 |
| 9 | 音频选择/预览 | 导入后出现音频卡与格式/大小 |
| 10 | 视频选择/抽帧参数 | 视频卡、帧间隔、最大帧数可见 |
| 11 | 文档选择/预览 | PDF/DOCX 卡片、页数与抽取提示可见 |
| 12 | 多模态保存/重载 | 资产引用往返后卡片恢复，JSON 不含 base64 |
| 13 | 非法模态连接 | 图片端口接文本输入被拒绝并显示错误 |
| 14 | 能力变化后的 UI 刷新 | 修改模型后能力面板与推理选项同步更新 |

Playwright 使用前端 mock transport，只证明编辑器、节点库、预览与能力展示；真实执行以下一节为准。

### 2.4 原生 Tauri E2E

命令：`pnpm -C apps/desktop test:e2e:tauri`

该命令依次执行 `tauri build --debug --no-bundle --features e2e` 与 `wdio run wdio.conf.mjs`。结果：**7 passing**，exit 0。

| 用例 | 关键结果 |
| --- | --- |
| DAG 真实执行与持久化 | 3 节点/2 连线，日志 `HELLO RUST E2E`，run completed，3 个 `node.finished` |
| 标准 Agent 工具循环 | 审批网络；calculator `128 * 256` -> 32768；最终 `The answer is 32768.` |
| 刷新重连 | 等待审批时刷新；恢复事件流，seq 唯一且无重复，model started/finished 配对 |
| 运行中取消 | 审批等待期间终止；`run cancelled`，有 `node.cancelled` |
| OpenAI Chat 多模态 | 13 节点/18 连线；真实图片/音频/视频抽帧/PDF/DOCX；reasoning high；请求命中 `/chat/completions`；最终 `Mock OpenAI Chat accepted.` |
| OpenAI Responses 多模态 | 同一工作流切换协议；命中 `/responses`；工具/媒体/推理编码通过；最终 `Mock OpenAI Responses accepted.` |
| Anthropic Messages 多模态 | 同一工作流切换协议；命中 `/messages`；thinking 预算、图片/文档块通过；最终 `Mock Anthropic Messages accepted.` |

三条协议用例在真实 macOS Tauri 窗口、真实 IPC、真实 Rust Runtime 中执行；媒体文件由 `asset_import` 导入，视频帧由 Rust 调 ffmpeg 抽取，PDF/DOCX 文本由 Rust 抽取。Provider 是本地 wire-format mock，不是外部云服务。

## 3. 验收条目对照

| 场景 | 结论 | 证据 |
| --- | --- | --- |
| A. 中文可折叠节点库、搜索、记忆、整体收起 | 通过 | Playwright 1-4；NodeLibrary/i18n 实现 |
| B. 三条 Provider 协议接同一个 Model | 通过 | Playwright 5；原生三条协议 E2E；`ProviderFactory` 按协议分派 |
| C. Reasoning 独立节点、优先级、按协议映射 | 通过 | Playwright 6/14；`protocols.rs`；原生 reasoning high |
| D. 模型能力展示与运行前校验 | 通过 | Playwright 7/14；`capabilities.rs`；`model.unsupported_reasoning/modality` 测试 |
| E. 图片/音频/视频/文档真实导入与预览 | 通过 | Playwright 8-11；原生 E2E 真实资产与帧 |
| F. 资产引用保存/重载/模板闭包 | 通过 | Playwright 12；原生重载断言；desktop 资产测试 |
| G. 三条协议的多模态编码顺序与不支持拒绝 | 通过 | `protocols.rs` 10 项；媒体矩阵 |
| H. Responses 工具结果/previous_response_id | 通过 | `protocols.rs` 的 `function_call_output` 与多轮测试 |
| I. Anthropic tool_result/thinking/system | 通过 | `protocols.rs` 的 header/system/tool_result 与 thinking 测试 |
| J. Phase 1.4 回归 | 通过 | 121 Rust tests 全绿；旧 Agent 模板、MCP、Skills、Composite、恢复/取消均保留 |
| K. Phase 1.4 三项修复 | 通过 | provider discovery 审批、MCP 明细、Windows `ReplaceFileW` 与原文件完整性测试 |
| L. 真实外部模型 | **未验证** | 无凭据，未调用外部服务 |

## 4. 真实 Tauri 验收步骤

1. `pnpm -C apps/desktop tauri dev` 启动，窗口显示中文可折叠节点库、中央画布、右上运行/终止、底部日志。
2. 从“模型与协议”分别添加三个 Provider 节点，接同一个 Model；从“思考与推理”接 Reasoning。
3. 从“输入与媒体”添加图片/音频/视频/文档节点，分别选择本地文件，确认预览与参数。
4. 将媒体节点接入 Context，Context 接 Model；视频选抽帧，文档选文本抽取，音频选 native 或显式转写。
5. 连接 Model → Log，保存工作流。
6. 关闭并重开工作流：资产卡、协议、参数、连线全部恢复，JSON 中没有 base64 或绝对路径。
7. 点击运行：首次网络请求弹出审批；批准后 Rust 按协议发请求，日志显示模型输出、工具调用/结果与 usage。
8. 运行中刷新 WebView：事件从 `active_run` 恢复，seq 连续且不重复。
9. 运行中终止：运行进入 cancelled，节点状态与日志一致。

## 5. 跨平台

| 平台 | 编译 / 静态检查 / 单测 | 真实桌面运行 |
| --- | --- | --- |
| macOS | 本地通过 | **通过**（原生 WDIO 7 项，真实窗口与 IPC） |
| Windows | 由提交后 CI 验证 | **未验收** |
| Linux | 由提交后 CI 验证 | **未验收** |

CI 在 macOS、Ubuntu 24.04、Windows 上执行 clippy、`cargo test --workspace`，前端 job 执行构建、三组单元测试、Playwright Chromium 安装与 19 项浏览器 E2E。CI 编译通过不等同于 Windows/Linux 实机运行验收。

## 6. 已知问题与边界

- **未调用真实外部模型**：三条协议由本地 wire-format mock 验证，真实 OpenAI/Anthropic 的账号、配额、区域网络和模型差异未实测。
- **原生视频不支持**：三条协议都拒绝 native video；必须显式抽帧。视频抽帧依赖系统 `ffmpeg`，缺失时明确失败。
- **不内置语音识别**：音频 native 仅限真正支持音频输入的模型；否则必须由用户或上游节点提供转写文本，Runtime 不会暗中转写。
- **文档抽取有损**：PDF/DOCX 抽取保留页标记，但图片、表格和复杂版式可能丢失；UI 明确提示，不宣称无损。
- **资产无自动 GC**：内容寻址存储会去重，但删除工作流不会回收仍被其他工作流/模板引用的资产。
- **模型能力仍可能未知**：模型列表不等于能力清单；没有可信元数据时媒体为 `unknown` 并拒绝，需人工覆盖或后续 probe。
- **Responses 会话对齐是保守启发式**：只有本地消息前缀与服务端记录一致才使用 `previous_response_id`，否则重发完整 transcript。
- **Anthropic thinking 预算受 max_tokens 限制**：high/xhigh 需要更大的输出预算；不足时请求前失败，不静默降级。
- **Windows/Linux 运行行为未验收**：只能确认 CI 编译与测试；平台相关的 keyring、WebView、路径和 ffmpeg 行为仍需实机验证。
- **调度仍是顺序执行**：不宣称并行 Agent 或多 Agent 协作。
- **未做安装包、签名与公证**：验收使用 debug binary 与 embedded WebDriver。

## 7. 最终门禁记录

提交前在本机（macOS Apple Silicon）执行：

```text
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
pnpm -C apps/desktop build
PLAYWRIGHT_CHANNEL=chromium pnpm -C apps/desktop test:e2e:web --reporter=line
pnpm -C apps/desktop test:e2e:tauri
```

实际结果：

| 检查 | 结果 |
| --- | --- |
| `cargo fmt --all -- --check` | 通过，无改动 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 通过，0 warning |
| `cargo test --workspace` | **121 passed / 0 failed** |
| `pnpm -C apps/desktop build` | 通过；219 modules，主 JS 445.30 kB（gzip 140.83 kB） |
| 前端单元测试 | events 6、routing 13、composite 8，全部通过 |
| Playwright 浏览器 E2E | **19 passed**（5 回归 + 14 Phase 1.5，40.0s） |
| 原生 Tauri WDIO | **7 passed**（runtime 4 + multimodal 3，真实窗口与 IPC） |

本机 Google Chrome 156 比 Playwright 1.56.1 固定的 Chromium 141 更新，直接使用系统 Chrome 会出现 CDP `guid handle ... was not bound` 等随机错误；因此本地门禁显式使用 `PLAYWRIGHT_CHANNEL=chromium`，CI 使用官方固定 Chromium。这不是产品断言失败。
