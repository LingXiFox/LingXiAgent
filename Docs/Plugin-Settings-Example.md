# 插件自绘设置页示例

本文给出一个最小 `settings.view.v1` 插件的骨架。完整可运行示例在
`Plugins/LingXiSettingsProbe/SettingsProbePlugin.swift`，它没有 Provider、Hook 或 Tool，仅用于证明
设置页确实由插件拥有。

## 1. 声明

`describe` 返回的 `PluginIdentity` 增加 `settings`，manifest 的 `Capabilities` 写入同一字符串：

```swift
let identity = PluginIdentity(
    bundleID: "site.example.settings", version: "1.0.0",
    hooks: [], providers: [],
    settings: SettingsDeclaration(capability: "settings.view.v1")
)
```

## 2. 处理 invoke

```swift
switch invocation.op {
case .open:
    // invocation.viewport 是宿主给的内容区；invocation.config 是已提交配置；
    // invocation.credentials 只有 configured/source，永远没有 Key。
    draft = try MiMoConfig(json: invocation.config ?? .object([:]))
    return SettingsResponse(frame: render(), title: "Example")
case .input:
    apply(invocation.input)       // 自己决定按键语义
    return SettingsResponse(frame: render())
case .resize:
    viewport = invocation.viewport ?? viewport
    return SettingsResponse(frame: render())
case .prepareSave:
    return SettingsResponse(config: try JSONValue.encode(draft), ok: true)
case .commit, .apply:
    return SettingsResponse(ok: true)
case .cancel:
    draft = applied
    return SettingsResponse(ok: true)
}
```

## 3. 绘制

```swift
SettingsFrame(rows: [
    SettingsRow([SettingsSpan("Connection", fg: "fox", bold: true)]),
    SettingsRow([SettingsSpan("API Key  "), SettingsSpan("已配置", fg: "success")]),
    SettingsRow([SettingsSpan("Enter 应用  Ctrl-S 保存  Esc 取消", fg: "muted")]),
])
```

颜色只能是主题 token（`fox`、`dim`、`cream`、`error`、`success`、`muted` 等）或 `#RRGGBB`。
文本禁止控制字符；宿主会裁剪超宽行、限制帧大小并拒绝非法颜色。插件不能写 stdout 或 ANSI。

## 4. 凭据

设置页不能要求宿主把 Key 交给插件。需要更新/删除 Key 时，返回：

```swift
SettingsResponse(frame: frame, command: SettingsCommand(type: "credential.update", providerID: "mimo"))
```

TUI 会调用现有的隐藏输入流程；成功后重新打开设置会话，让插件看到新的
`SettingsCredentialStatus(configured/source)`，但永远看不到值。

## 5. 保存与生效

Core 校验 `prepareSave` 返回的配置后原子写入 `<data>/plugin-settings/<bundleID>.json`。运行中的
Provider 会在保存成功后收到 `apply`；插件应按 `executionID` 快照配置，保证同一个 Run 的工具轮
不会中途改变协议或思考参数。禁用插件也能打开设置页，关闭后启停状态不变。
