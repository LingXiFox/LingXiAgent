import Foundation
import LingXiPluginRuntime
import LingXiSettingsProtocol
import Testing

private let settingsPTYEnabled = ProcessInfo.processInfo.environment["LINGXI_RUN_TUI_PTY_TEST"] == "1"

@Test(
    "SETTINGS-001 the TUI opens a plugin-drawn settings page, edits and saves it, then reloads it",
    .enabled(if: settingsPTYEnabled)
)
func SETTINGS_001_tuiSettingsRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-pty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let bundle = try makeBundle(
        bundleID: "site.lingxi.probe.settings", executableName: "LingXiSettingsProbe",
        dylib: builtProduct("libLingXiSettingsProbe.dylib"), capabilities: ["settings.view.v1"]
    )
    let registry = try PluginRegistry(configURL: directory.appendingPathComponent("plugins.json"))
    try await registry.upsert(.init(
        bundleID: "site.lingxi.probe.settings", version: "1.0.0",
        bundlePath: bundle.url.path, enabled: false
    ))

    var environment = ProcessInfo.processInfo.environment
    environment["LINGXI_DATA_DIR"] = directory.path
    environment["LINGXI_CORE_HOST"] = builtProduct("LingXiCoreHost").path
    environment["LINGXI_PLUGIN_POLICY"] = "development"
    environment["LINGXI_KEYCHAIN_SERVICE"] = "site.lingxi.credentials.test.\(UUID().uuidString)"
    environment["TERM"] = "xterm-256color"
    environment.removeValue(forKey: "LINGXI_CREDENTIAL_SOURCE")

    let tui = try PTYProcess(environment: environment)
    defer { tui.terminate() }

    try #require(await tui.waitFor("没有可用模型"))
    var mark = 0
    tui.write("/plugins\r")
    try #require(await tui.waitFor("site.lingxi.probe.settings"), "tail: \(tui.transcript.suffix(2500))")
    tui.write("\r")
    try #require(await tui.waitFor("Settings Probe"))
    try #require(await tui.waitFor("插件自己绘制"))

    tui.write("X")
    try #require(await tui.waitFor("probeX"))
    tui.write("\u{13}")
    try #require(await tui.waitFor("设置已保存"))
    try #require(await waitUntil { tui.screenText.contains("输入消息，或按 / 选择命令") })

    // Reopening reads the committed file, still without enabling the plugin's routes.
    try await Task.sleep(for: .milliseconds(400))
    mark = tui.transcript.count
    tui.write("/plugins\r")
    try #require(await tui.waitFor("site.lingxi.probe.settings", after: mark))
    tui.write("\r")
    try #require(await tui.waitFor("probeX"))
    // Reopened without edits, so the plugin reports clean: Escape closes at once, no dialog.
    tui.write("\u{1B}")
    try #require(await waitUntil { tui.screenText.contains("输入消息，或按 / 选择命令") })
    #expect(!tui.transcript.contains("未保存的修改"))

    tui.write("/quit\r")
    #expect(await waitUntil(timeout: .seconds(60)) { !tui.isRunning })

    let file = directory.appendingPathComponent("plugin-settings/site.lingxi.probe.settings.json")
    let data = try Data(contentsOf: file)
    #expect(String(decoding: data, as: UTF8.self).contains("probeX"))
}


@Test(
    "SETTINGS-002 Space toggles a plugin immediately in the first-level list",
    .enabled(if: settingsPTYEnabled)
)
func SETTINGS_002_pluginListToggle() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-toggle-pty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let bundle = try makeBundle(
        bundleID: "site.lingxi.probe.settings", executableName: "LingXiSettingsProbe",
        dylib: builtProduct("libLingXiSettingsProbe.dylib"), capabilities: ["settings.view.v1"]
    )
    let registry = try PluginRegistry(configURL: directory.appendingPathComponent("plugins.json"))
    try await registry.upsert(.init(
        bundleID: "site.lingxi.probe.settings", version: "1.0.0",
        bundlePath: bundle.url.path, enabled: false
    ))

    var environment = ProcessInfo.processInfo.environment
    environment["LINGXI_DATA_DIR"] = directory.path
    environment["LINGXI_CORE_HOST"] = builtProduct("LingXiCoreHost").path
    environment["LINGXI_PLUGIN_POLICY"] = "development"
    environment["LINGXI_KEYCHAIN_SERVICE"] = "site.lingxi.credentials.test.\(UUID().uuidString)"
    environment["TERM"] = "xterm-256color"
    environment.removeValue(forKey: "LINGXI_CREDENTIAL_SOURCE")

    let tui = try PTYProcess(environment: environment)
    defer { tui.terminate() }
    try #require(await tui.waitFor("没有可用模型"))
    tui.write("/plugins\r")
    try #require(await tui.waitFor("site.lingxi.probe.settings"))
    tui.write(" ")
    try #require(await tui.waitFor("已启用"))
    let enabled = try String(contentsOf: directory.appendingPathComponent("plugins.json"), encoding: .utf8)
    #expect(enabled.contains("\"enabled\" : true"))
    tui.write(" ")
    try #require(await tui.waitFor("已禁用"))
    tui.write("\u{1B}")
    tui.write("/quit\r")
    #expect(await waitUntil(timeout: .seconds(60)) { !tui.isRunning })
}

@Test(
    "SETTINGS-003 a rejected save keeps the settings window open and shows the error",
    .enabled(if: settingsPTYEnabled)
)
func SETTINGS_003_saveFailureFeedback() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-fail-pty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bundle = try makeBundle(
        bundleID: "site.lingxi.probe.settings", executableName: "LingXiSettingsProbe",
        dylib: builtProduct("libLingXiSettingsProbe.dylib"), capabilities: ["settings.view.v1"]
    )
    let registry = try PluginRegistry(configURL: directory.appendingPathComponent("plugins.json"))
    try await registry.upsert(.init(
        bundleID: "site.lingxi.probe.settings", version: "1.0.0",
        bundlePath: bundle.url.path, enabled: true, grants: ["rejectApply"]
    ))
    var environment = ProcessInfo.processInfo.environment
    environment["LINGXI_DATA_DIR"] = directory.path
    environment["LINGXI_CORE_HOST"] = builtProduct("LingXiCoreHost").path
    environment["LINGXI_PLUGIN_POLICY"] = "development"
    environment["LINGXI_KEYCHAIN_SERVICE"] = "site.lingxi.credentials.test.\(UUID().uuidString)"
    environment["TERM"] = "xterm-256color"
    environment.removeValue(forKey: "LINGXI_CREDENTIAL_SOURCE")

    let tui = try PTYProcess(environment: environment)
    defer { tui.terminate() }
    try #require(await tui.waitFor("没有可用模型"))
    tui.write("/plugins\r")
    try #require(await tui.waitFor("site.lingxi.probe.settings"))
    tui.write("\r")
    try #require(await tui.waitFor("Settings Probe"))
    tui.write("X")
    try #require(await tui.waitFor("probeX"))
    tui.write("\u{13}")
    try #require(await tui.waitFor("rejected"))
    // A rejected save is not a dead session: the panel, the draft and the error all stay visible.
    #expect(tui.screenText.contains("probeX"))
    #expect(tui.screenText.contains("Settings Probe"))

    // The draft is dirty, so Escape must ask instead of silently discarding it.
    tui.write("\u{1B}")
    try #require(await tui.waitFor("未保存的修改"))
    #expect(tui.screenText.contains("[ 保存 ]"))
    #expect(tui.screenText.contains("[ 放弃 ]"))
    #expect(tui.screenText.contains("[ 继续编辑 ]"))
    // Esc means "keep editing": the dialog closes and the draft is still there.
    tui.write("\u{1B}")
    try #require(await waitUntil { !tui.screenText.contains("未保存的修改") })
    #expect(tui.screenText.contains("probeX"))

    // Escape again, then choose 放弃 (the safe default is 继续编辑, one step left).
    tui.write("\u{1B}")
    try #require(await tui.waitFor("未保存的修改"))
    tui.write("\u{1B}[D\r")
    try #require(await waitUntil { tui.screenText.contains("输入消息，或按 / 选择命令") })
    // Discarding never writes the draft: the failed save was rolled back to no file at all.
    let stored = directory.appendingPathComponent("plugin-settings/site.lingxi.probe.settings.json")
    #expect(!FileManager.default.fileExists(atPath: stored.path))
    tui.write("/quit\r")
    #expect(await waitUntil(timeout: .seconds(60)) { !tui.isRunning })
}

private let settingsKeychainPTY = ProcessInfo.processInfo.environment["LINGXI_RUN_KEYCHAIN_TESTS"] == "1"

@Test(
    "SETTINGS-004 the settings page manages a disabled plugin's Keychain credential",
    .enabled(if: settingsPTYEnabled && settingsKeychainPTY)
)
func SETTINGS_004_settingsPageCredential() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-cred-pty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bundle = try makeBundle(
        bundleID: "site.lingxi.provider.mimo", executableName: "MiMoProvider",
        dylib: builtProduct("libMiMoProvider.dylib"),
        capabilities: ["provider.mimo", "settings.view.v1"]
    )
    let registry = try PluginRegistry(configURL: directory.appendingPathComponent("plugins.json"))
    try await registry.upsert(.init(
        bundleID: "site.lingxi.provider.mimo", version: "1.0.0",
        bundlePath: bundle.url.path, enabled: false
    ))
    var environment = ProcessInfo.processInfo.environment
    environment["LINGXI_DATA_DIR"] = directory.path
    environment["LINGXI_CORE_HOST"] = builtProduct("LingXiCoreHost").path
    environment["LINGXI_PLUGIN_POLICY"] = "development"
    environment["LINGXI_KEYCHAIN_SERVICE"] = "site.lingxi.credentials.test.\(UUID().uuidString)"
    environment["TERM"] = "xterm-256color"
    environment.removeValue(forKey: "LINGXI_CREDENTIAL_SOURCE")
    environment.removeValue(forKey: "MIMO_API_KEY")

    let tui = try PTYProcess(environment: environment)
    defer { tui.terminate() }
    try #require(await tui.waitFor("没有可用模型"))
    tui.write("/plugins\r")
    try #require(await tui.waitFor("site.lingxi.provider.mimo"))
    tui.write("\r")
    try #require(await tui.waitFor("Connection"))
    // Connection selection 0 = update credential.
    tui.write("\r")
    try #require(await tui.waitFor("隐藏输入中"))
    let key = "settings-pty-sentinel-\(UUID().uuidString)"
    tui.write(key + "\r")
    try #require(await tui.waitFor("已配置"))
    #expect(!tui.transcript.contains(key))
    // Down to delete, Enter, then confirm in the host-owned dialog.
    tui.write("\u{1B}[B\r")
    try #require(await tui.waitFor("删除凭据"))
    tui.write("\r")
    try #require(await tui.waitFor("未配置"))
    tui.write("\u{1B}")
    try #require(await waitUntil { tui.screenText.contains("输入消息，或按 / 选择命令") })
    tui.write("/quit\r")
    #expect(await waitUntil(timeout: .seconds(60)) { !tui.isRunning })
}
