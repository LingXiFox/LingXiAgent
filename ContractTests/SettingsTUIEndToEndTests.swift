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
    tui.write("\u{1B}")
    try #require(await waitUntil { tui.screenText.contains("输入消息，或按 / 选择命令") })

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
