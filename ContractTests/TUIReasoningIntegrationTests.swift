import Darwin
import Foundation
import LingXiPluginRuntime
import Testing

/// End-to-end acceptance for Phase 4.3 in a real PTY: a mouse click reaches a plugin-drawn settings
/// page as relative coordinates through the real Core, the plugin saves a new protocol, and the
/// footer reflects it without another run. The footer/reasoning/perf path is covered by TUI-010.
private let phase43PTYEnabled = ProcessInfo.processInfo.environment["LINGXI_RUN_TUI_PTY_TEST"] == "1"

private func phase43Environment(_ directory: URL) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["LINGXI_DATA_DIR"] = directory.path
    environment["LINGXI_CORE_HOST"] = builtProduct("LingXiCoreHost").path
    environment["LINGXI_PLUGIN_POLICY"] = "development"
    environment["LINGXI_KEYCHAIN_SERVICE"] = "site.lingxi.credentials.test.\(UUID().uuidString)"
    environment["TERM"] = "xterm-256color"
    environment.removeValue(forKey: "LINGXI_CREDENTIAL_SOURCE")
    environment.removeValue(forKey: "LINGXI_CORE_CONTROL")
    environment.removeValue(forKey: "LINGXI_FRONTEND")
    return environment
}

private func phase43Directory(_ name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test(
    "TUI-014 a mouse click on a plugin-drawn settings tab switches the MiMo page and the saved protocol reaches the footer",
    .enabled(if: phase43PTYEnabled)
)
func TUI_014_mouseReachesPluginSettingsAndFooterRefreshes() async throws {
    let directory = try phase43Directory("tui-mouse-settings")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedTUI(directory)
    let tui = try PTYProcess(environment: phase43Environment(directory))
    defer { tui.terminate() }
    try #require(await waitUntil(timeout: .seconds(30)) { tui.screenText.contains("mimo-v2.6-flash") })

    tui.write("/mouse\r")
    try #require(await tui.waitFor("已开启鼠标"))
    tui.write("/plugins\r")
    try #require(await tui.waitFor("site.lingxi.provider.mimo"))
    tui.write("\r")
    try #require(await tui.waitFor("MiMo Provider"))
    try #require(await tui.waitFor("Connection"))

    // Click the plugin's own "Protocol" tab: the host forwards relative coordinates, the plugin
    // decides what that row means.
    var target = try #require(locate("Protocol", in: frameRows(tui.latestFrame)))
    tui.write(sgrPress(row: target.row, column: target.column) + sgrRelease(row: target.row, column: target.column))
    try #require(await tui.waitFor("API Protocol"))
    try #require(await tui.waitFor("Chat Completions"))

    // Click the Responses radio, then save with Ctrl-S (unchanged host key).
    target = try #require(locate("Responses", in: frameRows(tui.latestFrame)))
    tui.write(sgrPress(row: target.row, column: target.column) + sgrRelease(row: target.row, column: target.column))
    try #require(await tui.waitFor("● 未保存"))
    tui.write("\u{13}")
    try #require(await tui.waitFor("设置已保存"))
    try #require(await waitUntil { tui.screenText.contains("输入消息，或按 / 选择命令") })

    // The save reply and providers.state event refresh the footer without another run.
    try #require(await tui.waitFor("协议 Responses"))
    // The plugin's saved state is now "enabled" thinking (the page's default choice was Responses
    // with the thinking mode the fixture starts in, so only the protocol must have changed).
    try #require(await tui.waitFor("effort: 服务端默认"))

    tui.write("/quit\r")
    #expect(await waitUntil(timeout: .seconds(60)) { !tui.isRunning })
    #expect(tui.status == 0)

    let stored = directory.appendingPathComponent("plugin-settings/site.lingxi.provider.mimo.json")
    let data = try Data(contentsOf: stored)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let config = try #require(root["config"] as? [String: Any])
    #expect(config["protocolKind"] as? String == "responses")
}

@Test(
    "TUI-016 the Responses effort ladder is selectable from the footer and shown as effort: <level>",
    .enabled(if: phase43PTYEnabled)
)
func TUI_016_responsesEffortLadder() async throws {
    let directory = try phase43Directory("tui-effort-ladder")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedTUI(directory)

    // Pre-seed the plugin's saved configuration: Responses with thinking enabled at medium effort.
    let settingsDirectory = directory.appendingPathComponent("plugin-settings")
    try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
    let payload: [String: Any] = [
        "version": 1,
        "config": [
            "protocolKind": "responses",
            "model": "mimo-v2.6-flash",
            "thinkingMode": "enabled",
            "reasoningEffort": "medium",
        ],
        "preferredModel": "mimo-v2.6-flash",
    ]
    try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        .write(to: settingsDirectory.appendingPathComponent("site.lingxi.provider.mimo.json"))

    let tui = try PTYProcess(environment: phase43Environment(directory))
    defer { tui.terminate() }
    try #require(await waitUntil(timeout: .seconds(30)) { tui.screenText.contains("mimo-v2.6-flash") })
    try #require(await waitUntil { tui.screenText.contains("effort: medium") })

    tui.write("/mouse\r")
    try #require(await tui.waitFor("已开启鼠标"))
    var target = try #require(locate("effort: medium", in: frameRows(tui.latestFrame)))
    tui.write(sgrPress(row: target.row, column: target.column) + sgrRelease(row: target.row, column: target.column))
    try #require(await tui.waitFor("推理强度"))
    try #require(await tui.waitFor("xhigh"))
    // The plugin-owned official limitation travels with the ladder.
    try #require(await tui.waitFor("各档位实际推理强度相同"))

    // Click the xhigh row (the picker is a normal hit-tested panel).
    target = try #require(locate("xhigh", in: frameRows(tui.latestFrame)))
    tui.write(sgrPress(row: target.row, column: target.column) + sgrRelease(row: target.row, column: target.column))
    try #require(await waitUntil { tui.screenText.contains("已临时切换思考模式：xhigh") })
    try #require(await waitUntil { tui.screenText.contains("effort: xhigh（临时）") })

    // The temporary choice is not written to the plugin's configuration file.
    let stored = try Data(contentsOf: settingsDirectory.appendingPathComponent("site.lingxi.provider.mimo.json"))
    let root = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
    let config = try #require(root["config"] as? [String: Any])
    #expect(config["reasoningEffort"] as? String == "medium")

    tui.write("/reasoning follow\r")
    try #require(await waitUntil { tui.screenText.contains("effort: medium") && !tui.screenText.contains("（临时）") })

    tui.write("/quit\r")
    #expect(await waitUntil(timeout: .seconds(60)) { !tui.isRunning })
    #expect(tui.status == 0)
}
