# Plugin System

Plugin service 在 directory InstanceState 初始化 internal 与 external plugins，按加载顺序保存 hook；`trigger` 顺序 await 每个 hook（`plugin/index.ts:127-308`）。external plugin origin 由 Config 按 global/local source 保留，加载前等待 config dependency。

已确认可修改的 runtime 边界：

- `tool.definition`：变更模型可见 tool description/parameters/schema（ToolRegistry:318）。
- `experimental.chat.system.transform`：变更 agent generation 的 system 内容（Agent:380-382）；其他 chat hooks 的确切表面应以 plugin package `Hooks` 为准。
- provider/auth hooks：ProviderAuth 从 plugin auth hook 提供 OAuth/API methods。
- plugin tools：Plugin ToolDefinition 变成 registry Tool.Def 并由 host context 执行。
- event/config/dispose：接收 instance event、config、生命周期回调。

插件获得 SDK client、project/worktree/directory 与可能的 Bun shell handle（plugin/index.ts:143-168），故是强扩展和安全边界。当前 evidence 不支持“插件可直接替换 canonical SessionExecution loop”这一断言；它可影响其输入、tool 与 provider adapter，不自动取得 runner ownership。
