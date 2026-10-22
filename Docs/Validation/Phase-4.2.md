# Phase 4.2 验收记录

日期：2026-10-22
基线：`5cf4504d88c5165e13cc89fd997c64ae9cea1091` + 本次改动

## 已实现并经过离线测试

### 插件自绘设置容器

- `settings.view.v1` 能力：插件在 `PluginIdentity.settings` 声明，manifest 的 `Capabilities` 必须一致。
- 受约束 `SettingsFrame`：行/spans 风格、主题 token 或 `#RRGGBB`；Core 校验控制字符、颜色、尺寸并裁剪。
  限制：120×40、每行 128 span、单 span 4 KiB、整帧 256 KiB。
- `plugin.settings.open/input/resize/save/cancel` 前端协议；每次打开独立 `settingsSessionID`。
- 设置 Host 与 Provider Host 分离：打开设置不注册路由、Hook、Tool；禁用插件也能打开。
- 事务保存：`prepareSave` → Core 校验 JSON 对象/64 KiB/版本 1 → 原子写入
  `<data>/plugin-settings/<bundleID>.json`；写盘失败或应用失败恢复旧配置。`Esc` 丢弃草稿。
- TUI `/plugins` 两级：Enter 打开设置，Space 立即启停；设置容器由 TUI 画外框、标题、页脚，插件画内容。
- 测试证据：
  - `SettingsContainerTests`：真实 Plugin Host，打开/编辑/保存/取消、非法帧、未知版本、Host 崩溃隔离。
  - `SettingsFrameTests`：CJK 裁剪、控制字符、颜色、行数限制。
  - `SETTINGS-001` / `SETTINGS-002`：真实 PTY，插件自绘页面、保存后重开、Space 即时启停。
  - `MiMoSettingsTests`：MiMo 自绘页切换 Responses 并写入配置。

### MiMo 双协议与思考参数

- 同一 `site.lingxi.provider.mimo` 身份支持 `/v1/chat/completions` 与 `/v1/responses`。
- Chat：`thinking.type = enabled|disabled`；默认省略。
- Responses：`reasoning.effort` 合法值 `none/minimal/low/medium/high/xhigh/max/ultra`；`minimal→low`，
  `xhigh/max/ultra→high`，默认省略。不含 `previous_response_id`/`background`/`context_management`。
- Responses SSE 解析覆盖文本、推理、工具调用、usage/cache、`response.completed/incomplete/failed`，
  按 sequence/item 去重，终态只发一次；取消后丢弃迟到事件。
- 每个 `executionID` 首次 Provider 请求快照配置，工具轮复用；保存设置影响后续 Run。
- 测试证据：
  - `swift test --filter MiMo`：18 个测试通过（含 Chat 三模式、Responses effort 映射、SSE 去重、
    多轮工具、取消、cassette digest、设置快照）。
  - `MIMO_settingsDriveRealRequests`：真实 Core 配置注入 + 本地 loopback 捕获请求，证明设置保存后
    下一次请求使用 Responses `reasoning.effort`，再切回 Chat 后使用 `thinking.type=disabled`。
  - `TUI-001`：真实 PTY 中打开 MiMo 自绘设置页、快捷键切换协议、Ctrl-S 保存。

## 已通过真实 API 验收

无。当前环境没有 `MIMO_API_KEY`，`MIMO live smoke` 未执行；Respones 真实端点也未验收。不能把
cassette / loopback 测试称为真实 API 已生效。

## 目前只有部分支持

- 设置帧是协议级绘制隔离，不是 OS 沙箱。Settings-Only Host 仍会加载插件动态库；未来运行完全不可信
  原生插件需要 macOS OS 级权限隔离。
- 设置草稿回滚只覆盖 Core 管理的配置文件，不撤销插件自行产生的网络或文件副作用。
- MiMo 设置页的“测试连接”不会自动发起付费请求；真实连接测试需另行执行。
- 设置页 Key 更新走 TUI 隐藏输入；插件只收到 `configured/source` 状态。该路径的完整 Keychain 交互
  复用 Phase 4.1 的 AUTH-003 证据，尚无设置页面专用的真实 Keychain PTY 用例。
- MiMo Responses 的真实服务端参数、`response.incomplete` 真实形状与 usage/cache 字段仍需真实 API
  录制确认；当前只有合成 SSE 和本地 loopback。

## 官方 API 本身暂不支持

- MiMo 目前实际只区分关闭思考与开启思考；`minimal`/`low`/`medium`/`high`/`xhigh`/`max`/`ultra`
  的请求字段合法，但服务端是否形成不同推理强度未验证，设置页已明确提示。
- `GET /v1/models` 的动态能力发现不属于本阶段。

## 验证命令

```sh
swift build
swift test
LINGXI_RUN_KEYCHAIN_TESTS=1 LINGXI_RUN_TUI_PTY_TEST=1 swift test --filter 'AUTH_|TUI_|SETTINGS_'
swift test --filter MiMo
```

离线结果：主套件 104 + 4 + 69 = 177 个测试通过；门控套件 4 + 8 个测试通过；MiMo 18 个测试通过。
