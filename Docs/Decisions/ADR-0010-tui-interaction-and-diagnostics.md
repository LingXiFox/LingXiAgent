# ADR-0010：TUI 交互状态、临时思考选择与分段耗时

日期：2026-10-24
状态：接受（Phase 4.3）

## 背景

Phase 4.3 要让 TUI 同时具备鼠标与键盘操作，并让用户看得见、调得动“实际生效”的模型/协议/思考
参数；还要能区分上游延迟、思考耗时与本地渲染开销。约束不变：微内核、插件自绘设置页、固定 C ABI，
Core 不得认识厂商词汇（不能写死 MiMo）。

## 决策

### 1. 临时思考选择：插件声明 + 每请求字段，不落盘

- Provider 已在 `describe` 中按模型声明 `thinkingLevels`（`ADReceiver`），TUI 的 `/reasoning` 只列出
  当前模型声明的等级，外加“跟随插件设置”。没有任何厂商名或等级表在 Core/TUI 里硬编码。
- 选择通过 `provider.reasoning.set` 交给 Core；Core 用**插件声明**校验 provider/model/level 三元组，
  未声明一律拒绝（不猜测、不透传任意字符串）。
- 校验通过后 Core 把等级存到该 Provider 适配器（一个进程内、Provider 级的内存值），并在后续每个
  `ProviderWireRequest.reasoningLevel` 上携带；插件决定如何映射到自己的 wire 参数。清空即恢复插件
  保存的配置。该值不写设置文件、不写会话日志，Core 重启即消失——“临时”是明确的语义。
- 配置快照仍按 Run 隔离（Phase 4.2.2 的 `executionConfigs`）：插件把 override 应用到本次请求的有效
  配置上，digest 与 HTTP body 都反映它，因此“快捷切换真的改变了请求”可被离线 cassette/loopback 断言。

### 2. 生效状态查询：可选的 `provider.state.v1` 能力

- 协议新增可选的 `ProviderIdentity.state`（能力名由插件给）。Core 在 `hello`、`models.list`、插件启停、
  设置保存后询问该能力，插件返回 `ProviderState {protocolKind, thinkingLevel, thinkingLabel, source, detail}`。
- Core 只做合并：临时选择优先，`source` 标为 `session-override` 并带 `overridden=true`；否则原样透传
  插件的 `plugin-settings` / `server-default`。没有声明该能力的 Provider 不显示状态，绝不虚构默认值。
- 面板底栏因此能显示模型、协议与真正会生效的思考模式；Ctrl-T 仍只控制思考内容展开。

### 3. 分段耗时：一次请求一个 `timing` 事件

- 插件在 HTTP 边界记录单调时钟：准备、发送、首个响应头、首个 SSE、首个 reasoning、首个正文、终态。
  一次请求只发一条 `ProviderWireEvent(type: "timing")`，紧挨终态事件之前。
- Core 增加内核中性类型 `ModelTiming`（只用于观察，不进入 Run 状态），映射为前端 `RunTiming` 并补上
  Core 准备与 Run 总耗时；TUI 再补自己的渲染毫秒与帧数。
- 全部字段是整数毫秒，没有字段能携带 prompt、回复、header 或密钥；不写 journal，不写 cassette
  （录制器显式跳过 `timing`）。成本是每请求常数次读时钟，不是每 delta。
- TUI 显示一行紧凑诊断（首字/上游/思考/总耗时/渲染），`/perf` 给出完整分解。

### 4. 设置窗口的 Dirty 与退出

- 插件在 `SettingsResponse.dirty` 里回答“草稿是否与保存结果不同”；Core 原样透传到 `SettingsSnapshot`。
  `nil` 表示插件不跟踪，宿主按“脏”处理（宁可多问一次，不可静默丢草稿）。
- Esc：`dirty == false` 直接关闭；`true`/`nil` 由宿主弹出“保存 / 放弃 / 继续编辑”对话框，按钮可点击。
- Ctrl-S 保持不变。保存失败保留会话与草稿、显示错误；插件 Host 崩溃或超时则关闭窗口并提示，
  `/quit`、Ctrl-C 不被设置 Host 阻塞。Core 的配置事务、权限与敏感输入流程未改动。

### 5. 鼠标：宿主命中测试，插件只见相对坐标

- TUI 解析 SGR 鼠标报告（按下/滚轮），`/mouse` 仍控制是否捕获；关闭时不拦截终端原生拖选。
- 宿主维护每帧命中表：输入区、消息区滚动、选择器/插件列表行、宿主弹窗按钮、设置面板内区域。
  插件仅收到 `SettingsInput(kind: .mouse, row, column, delta)`，坐标是**插件帧内部**的相对行列，
  永不暴露终端绝对坐标；保存、退出、凭据确认仍由宿主独占。
- 点击与键盘共享同一个选中状态（点击即选中并激活），键盘路径全部保留。

## 兼容与影响

- C ABI v1 表未改。新增的都是可选 wire 字段/可选能力：旧插件不声明 `state`、不返回 `dirty`、不发
  `timing`，Core 与 TUI 都退化为“没有该信息”，不影响原有行为。
- 旧 cassette 的 digest 未变（`reasoningLevel` 缺省时不参与有效配置）；新增耗时事件不写入 cassette。
- 未新增外部依赖；未改 Core 的设置事务、凭据托管与插件签名策略。

## 未决

- 真实 MiMo 服务端对“临时关闭思考”的接受度只能在线验收；离线只证明请求形状。
- 鼠标协议只覆盖 SGR（1000/1006）；不支持旧 X10 编码的终端仍可用键盘。
- 设置 Host 的隔离仍是协议级，不是 OS 沙箱。
