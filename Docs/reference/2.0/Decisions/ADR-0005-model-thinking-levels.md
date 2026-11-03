# ADR-0005：模型思考等级由插件声明、Core 透传、前端只读显示

状态：已采纳（Phase 4.1）

## 背景

TUI 的模型区需要显示模型的思考等级。只有 Provider 插件知道自己的上游模型支持哪些等级；
Core 不应内置任何厂商的等级表。同时思考等级属于模型元数据，不属于 Kernel 的 Agent Loop，
不应为了显示它而扩展 `ModelRequest` 或改变 C ABI 的内存布局。

## 决定

1. **声明位置**：在插件 `describe` 返回的 `ProviderIdentity` JSON 中新增可选字段
   `modelDetails`。每项为一个 `ProviderModel`：稳定 `id`、可选的 `thinkingLevels`
   （`id` + `label`，按推理强度从低到高排序）、可选的 `defaultThinkingLevel`。
2. **兼容策略**：保留 `models: [String]` 给未升级插件。一旦提供 `modelDetails`，它必须与
   `models` 的 id 顺序完全一致；不一致在 handshake 阶段以 `protocolViolation` 拒绝，不静默修补。
3. **ABI 不变**：`describe` 的 JSON 本来就是可扩展边界，新增可选字段不改变 `LingXiPluginAPI`
   的 struct 布局，因此 ABI major 保持 1。
4. **加载器校验**：模型 id 唯一；思考等级 id 非空且唯一；`defaultThinkingLevel` 必须属于
   声明的等级集合；空 `thinkingLevels` 视为“未声明”。非法声明使该插件启用失败并整体回滚。
5. **Core 汇总**：`PluginCoordinator` 提供运行中 Provider 的模型声明；CoreHost 用
   `ModelRouter` 实际接受的路由过滤，避免展示未注册成功的幽灵模型。
6. **前端协议**：`models` 字段保持 `[String]`；新增可选 `modelDetails: [ModelSummary]`，
   包含 `id`、`provider`、`thinkingLevels`、`defaultThinkingLevel`。TUI 优先使用
   `modelDetails`，旧前端可继续只读 `models`。
7. **TUI 行为**：模型区在模型名后显示默认思考等级；没有默认值时显示可用等级集合。
   本版只读，不提供切换，也不在 `ProviderWireRequest` 中发送等级。原因：官方 Provider 的
   上游参数尚未核实，先显示“插件声明的事实”，不显示一个不会生效的选中态。
8. **预留**：`ProviderWireRequest` 可增加可选 `thinkingLevel` 由插件映射到上游；
   等官方 Provider API 核实后再接线，届时前端增加选择入口。

## 代价

- 声明是静态的：同一模型在不同账号、不同 API 版本下的等级差异无法表达，刷新需要重启插件。
- 只读显示，用户暂时不能切换；切换需要同时改前端、Core 注入点与插件上游映射。
- `models` 与 `modelDetails` 双写，靠加载器校验保持一致。

## 可逆性

可逆。删除可选字段即可回到纯字符串模型列表，不需要 ABI 升级，也不影响已通过校验的插件。
