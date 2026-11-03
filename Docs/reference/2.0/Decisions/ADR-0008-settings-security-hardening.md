# ADR-0008：Phase 4.2.1 设置安全与事务加固

状态：已采纳（Phase 4.2.1）

## 背景

Phase 4.2 的自绘设置容器已经能工作，但审查发现几处需要收紧的边界：设置 Host 继承了注册表
grant；设置页返回的凭据命令没有经过宿主授权；`applySettings` 只检查 IPC 成功、不检查插件
`ok:false`；保存/取消/重复打开存在会话与文件竞态；配置读取错误可能被当成“没有配置”。

## 决定

1. **Settings-Only Host 最小授权**：启动设置 Host 时传空的 grants，不传 `vcr`/`record`/故障注入
   等运行期权限；只加载设置能力所需的插件，不注册 Provider、Hook、Tool。插件 Bundle ID 必须与
   注册表记录一致，否则拒绝。
2. **凭据操作绑定会话**：`plugin.settings.credential` 必须携带 `settingsSessionID`。Core 用该会话
   的 Bundle ID 和插件 `ProviderIdentity` 验证 provider/credential 归属；未知 provider、别的插件
   的 provider、无设置会话的伪造请求一律拒绝。删除 Keychain 项必须显式
   `settingsCredentialConfirmed=true`，TUI 先显示宿主确认框。
3. **保存事务**：`prepareSave` 必须返回 `ok:true` 且配置为 JSON object；Core 原子写文件后才
   `apply`。`apply`/`commit` 的 IPC 回复必须同时满足 `ok:true`；任一失败恢复旧文件并重新 apply
   旧配置；回滚失败写入错误文本，不静默吞掉。
4. **会话唯一性**：同一 bundle 的旧会话先从 map 移除再关闭；关闭的 session 不接受 input/save；
   `open/input/resize` 的 Host 错误会移除会话并关闭进程；保存进行中取消通过 cancelled 标记让保存
   回滚，不关闭 Host 造成崩溃竞态。
5. **配置读取**：设置文件不存在才是默认；损坏、版本不支持、读取失败都是显式错误。保存文件
   保留原文件，不自动清空。
6. **偏好模型**：插件设置可返回 `preferredModel`，作为 TUI 新会话初始选择提示；它不绕过 Core
   路由，也不覆盖用户显式 `/model`。实际请求模型始终是 Core 请求中的 model。
7. **推理数据生命周期**：Provider Adapter 只在同一 execution 的工具轮内存中保存 reasoning（上限
   16 KiB、最多 64 个 execution），不写入事件日志；工具轮完成才传递下一轮，最终终态/取消/失败
   清除。Responses 的 reasoning input 形状已离线序列化，但真实服务端接受度待在线验证。

## 剩余风险

- 设置帧仍是协议级绘制隔离，不是 OS 沙箱；Settings-Only Host 仍运行插件动态库。完全不可信
  原生插件需要 macOS OS 级权限隔离。
- 保存回滚只覆盖 Core 管理的配置文件与运行态，不撤销插件自行发起的外部网络/文件副作用。
- Responses reasoning 项与真实 `response.incomplete` 形状仍需真实 API 验证；cassette/loopback 不算
  真实上游验收。

## 可逆性

可逆。移除 `settings.view.v1` 或恢复普通 grant 语义即可回到 4.2 的容器行为；ABI v1 未改变。
