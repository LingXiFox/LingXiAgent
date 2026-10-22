# ADR-0006：插件自绘设置容器与事务式配置

状态：已采纳（Phase 4.2）

## 背景

Provider、Skills、MCP 等插件的配置项差异很大。若 Core 预定义 Form Schema，每新增一种配置都要改
TUI 和 Core，插件也无法表达自己的导航、校验与状态。需要的是一条“宿主给画布、插件画内容”的边界：
插件拥有设置页内部设计，宿主统一负责外框、输入路由、凭据安全、保存事务与故障隔离。

同时，设置不是会话事件，也不是安装状态：它必须独立持久化、可迁移、原子写入，并且永远不能保存
明文 API Key。

## 决定

1. **能力名**：`settings.view.v1`。插件在 `describe` 的 `PluginIdentity.settings` 声明，manifest 的
   `Capabilities` 必须包含同一字符串；加载器校验两者一致。未声明 `settings` 的插件由宿主显示基础
   详情页。
2. **绘制协议**：插件通过现有 `invoke` 返回 `SettingsResponse`，其中 `frame` 是受约束的
   `SettingsFrame`（行 + span + 颜色/样式）。不新增 C ABI 函数，不改变 `LingXiPluginAPI` 布局。
3. **宿主校验**：frame 限制 120×40、每行 128 span、每 span 4 KiB、整帧 256 KiB；拒绝控制字符与
   非 `#RRGGBB`/主题 token 的颜色；超宽行按视口裁剪。插件永远拿不到物理终端，也不能写 ANSI。
4. **输入路由**：TUI 捕获终端输入，按 key/paste/mouse/resize 事件发给 Core；Esc 立即关闭容器，
   Ctrl-S 请求保存。插件不能拦截宿主退出或强制关闭。
5. **会话**：每次打开获得独立 `settingsSessionID`；Core 为设置单独启动一个 Plugin Host，不注册
   Provider 路由、Hook 或 Tool。禁用插件同样可以打开设置页；关闭后原启停状态不变。
6. **事务**：`open` 读取已提交配置，插件在内存中编辑草稿；`prepareSave` 返回候选配置，Core 校验
   JSON 对象、大小与版本后原子写入 `<data>/plugin-settings/<bundleID>.json`；写盘成功后通知运行中的
   Provider 应用新配置，失败则恢复旧文件。`cancel` 丢弃草稿。
7. **凭据**：设置帧与普通配置永远不包含 Key。插件只能收到 `configured/source` 状态；更新/删除
   凭据通过 TUI 的隐藏输入和现有 `auth.*` 请求完成，插件看不到值。
8. **配置应用**：Provider 在 Run 开始时由插件按 `executionID` 快照配置；同一 Run 的工具轮复用该
   快照，设置保存只影响后续 Run。插件负责把配置映射到自己的上游协议。
9. **失败语义**：非法帧、超时、Host 崩溃都关闭设置会话并返回错误；TUI 保持运行，其他插件不受
   影响。设置保存失败保留原配置并保持窗口打开。

## 明确边界

协议级绘制隔离不等于操作系统沙箱。Settings-Only Session 只是不注册路由/Hook/Tool，插件动态库仍然
运行在独立 Host 进程里；若未来要求运行完全不可信的原生插件，需要额外的 macOS OS 级权限隔离，不能
用 Cell Canvas 的宣传替代。

设置草稿回滚只覆盖 Core 管理的配置文件，不能撤销插件自行发起的外部网络请求或文件副作用。设置页
不得在编辑阶段执行非必要的持久副作用；真实网络测试必须作为显式动作。

## 代价

- 插件需要自己实现布局与键盘处理，官方插件维护面变大。
- 宿主需要维护 frame 校验和设置会话生命周期，新增一条前端协议面。
- 每次打开设置都会多一个短期 Host 进程；关闭后必须回收，增加测试的进程计数断言。

## 可逆性

可逆。删除 `settings.view.v1` 声明即回到宿主基础详情页；`ProviderIdentity.models` 与现有 Provider
路由不受影响。
