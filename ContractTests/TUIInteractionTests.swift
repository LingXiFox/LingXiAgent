import Darwin
import Foundation
import LingXiPluginRuntime
import Testing

/// Host-owned TUI interactions, driven through a real PTY against a real Core and the settings probe
/// plugin: mouse reports, hit-testing, the plugin-relative coordinate conversion, and the crash-safe
/// settings window. The probe reports its own dirty state and interprets mouse rows 3 and 4, which is
/// what makes a forwarded click observable at all.
private let interactionPTYEnabled = ProcessInfo.processInfo.environment["LINGXI_RUN_TUI_PTY_TEST"] == "1"

// MARK: - frame introspection

struct ScreenRow {
    let row: Int
    let text: String
}

private let ansiSequence = "\u{1B}\\[[0-9;?<>=]*[a-zA-Z]"

private func stripped(_ text: String) -> String {
    text.replacingOccurrences(of: ansiSequence, with: "", options: .regularExpression)
        .replacingOccurrences(of: "\u{1B}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
}

/// Splits a drawn frame into its addressed rows. The renderer writes `ESC[<row>;1H` before every row,
/// so a test can map a piece of text back to the exact cell a mouse report must name.
func frameRows(_ frame: String) -> [ScreenRow] {
    let marker = try! NSRegularExpression(pattern: "\u{1B}\\[(\\d+);1H")
    let ns = frame as NSString
    let matches = marker.matches(in: frame, range: NSRange(location: 0, length: ns.length))
    var rows: [ScreenRow] = []
    for (index, match) in matches.enumerated() {
        let start = match.range.upperBound
        let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
        let row = Int(ns.substring(with: match.range(at: 1))) ?? 0
        rows.append(ScreenRow(row: row, text: stripped(ns.substring(
            with: NSRange(location: start, length: max(0, end - start))
        ))))
    }
    return rows
}

/// Display width in terminal cells, matching the renderer: CJK and fullwidth characters are wide,
/// everything else (including spaces) is one cell.
private func cells(_ text: String) -> Int {
    text.reduce(0) { total, character in
        let wide = character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
                 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F,
                 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF,
                 0x20000...0x3FFFD:
                return true
            default:
                return false
            }
        }
        return total + (wide ? 2 : 1)
    }
}

/// The 1-based cell where `needle` starts in the current frame, from the frame's own row addresses.
func locate(_ needle: String, in rows: [ScreenRow]) -> (row: Int, column: Int)? {
    for line in rows {
        guard let range = line.text.range(of: needle) else { continue }
        let prefix = String(line.text[line.text.startIndex..<range.lowerBound])
        return (line.row, cells(prefix) + 1)
    }
    return nil
}

// MARK: - mouse reports

/// SGR press report. `button` 0 is the left button; the terminal also sends `m` for the release.
func sgrPress(row: Int, column: Int, button: Int = 0) -> String {
    "\u{1B}[<\(button);\(column);\(row)M"
}

func sgrRelease(row: Int, column: Int, button: Int = 0) -> String {
    "\u{1B}[<\(button);\(column);\(row)m"
}

/// Wheel reports are presses on buttons 64 (up) and 65 (down).
func sgrWheel(up: Bool, row: Int, column: Int) -> String {
    sgrPress(row: row, column: column, button: up ? 64 : 65)
}

// MARK: - fixtures

private func seedProbe(_ directory: URL, enabled: Bool, grants: [String] = []) async throws {
    let bundle = try makeBundle(
        bundleID: "site.lingxi.probe.settings", executableName: "LingXiSettingsProbe",
        dylib: builtProduct("libLingXiSettingsProbe.dylib"), capabilities: ["settings.view.v1"]
    )
    let registry = try PluginRegistry(configURL: directory.appendingPathComponent("plugins.json"))
    try await registry.upsert(.init(
        bundleID: "site.lingxi.probe.settings", version: "1.0.0",
        bundlePath: bundle.url.path, enabled: enabled, grants: grants
    ))
}

private func probeEnvironment(_ directory: URL) -> [String: String] {
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

/// Writes the plugin's own saved configuration, which the probe reads when it opens. Used to make the
/// settings host take a crash path that no grant can reach: settings hosts deliberately get no grants.
private func seedProbeConfig(_ directory: URL, _ config: [String: Any]) throws {
    let root = directory.appendingPathComponent("plugin-settings")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let payload: [String: Any] = ["version": 1, "config": config]
    try JSONSerialization.data(withJSONObject: payload).write(
        to: root.appendingPathComponent("site.lingxi.probe.settings.json")
    )
}

private func makeProbeDirectory(_ name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Opens the probe's settings page through the plugin list with the keyboard.
private func openProbeSettings(_ tui: PTYProcess) async throws {
    tui.write("/plugins\r")
    try #require(await tui.waitFor("site.lingxi.probe.settings"))
    tui.write("\r")
    try #require(await tui.waitFor("Settings Probe"))
}

// MARK: - tests

@Test(
    "TUI-005 mouse clicks run completion rows, open plugin rows, reach the plugin frame and close dialogs",
    .enabled(if: interactionPTYEnabled)
)
func TUI_011_mouseDrivesHostChromeAndPluginFrame() async throws {
    let directory = try makeProbeDirectory("tui-mouse")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedProbe(directory, enabled: false)
    let tui = try PTYProcess(environment: probeEnvironment(directory))
    defer { tui.terminate() }
    try #require(await tui.waitFor("没有可用模型"))

    // Mouse reports only exist while capture is on, so the switch must come first.
    tui.write("/mouse\r")
    try #require(await tui.waitFor("已开启鼠标"))

    // A click on a slash-command completion row runs that command, exactly like Enter.
    tui.write("/")
    try #require(await waitUntil { tui.screenText.contains("性能诊断") })
    var target = try #require(locate("/perf", in: frameRows(tui.latestFrame)))
    tui.write(sgrPress(row: target.row, column: target.column + 1)
        + sgrRelease(row: target.row, column: target.column + 1))
    try #require(await tui.waitFor("还没有运行诊断"))

    // A click on a plugin-list row is Enter: it opens the plugin's own settings page.
    tui.write("/plugins\r")
    try #require(await tui.waitFor("site.lingxi.probe.settings"))
    try #require(await waitUntil { tui.screenText.contains("esc 关闭") })
    target = try #require(locate("site.lingxi.probe.settings", in: frameRows(tui.latestFrame)))
    tui.write(sgrPress(row: target.row, column: target.column + 2))
    try #require(await tui.waitFor("Settings Probe"))
    try #require(await waitUntil { tui.screenText.contains("启用示例选项") })

    // The probe treats mouse row 4 as its enable toggle. The press and its release are sent together:
    // a UI that acted on the release too would flip the checkbox twice and stay checked.
    target = try #require(locate("[x]", in: frameRows(tui.latestFrame)))
    tui.write(sgrPress(row: target.row, column: target.column)
        + sgrRelease(row: target.row, column: target.column))
    try #require(await waitUntil { tui.screenText.contains("[ ]") && tui.screenText.contains("● 未保存") })

    // Row 3 selects the name row inside the plugin: the keyboard's selection marker follows the click.
    target = try #require(locate("probe_", in: frameRows(tui.latestFrame)))
    tui.write(sgrPress(row: target.row, column: target.column))
    try #require(await waitUntil { tui.screenText.contains("▸ 名称") })

    // Host chrome never reaches the plugin: a click on the panel's own title border changes nothing.
    let chrome = try #require(frameRows(tui.latestFrame).first {
        $0.text.contains("┌") && $0.text.contains("Settings Probe")
    })
    let border = try #require(locate("┌", in: [chrome]))
    tui.write(sgrPress(row: chrome.row, column: border.column))
    try await Task.sleep(for: .milliseconds(400))
    #expect(tui.screenText.contains("Settings Probe"))
    #expect(tui.screenText.contains("[ ]"))
    #expect(!tui.screenText.contains("[x]"))

    // The draft is dirty, so Escape asks. A click on 放弃 closes without writing anything.
    tui.write("\u{1B}")
    try #require(await tui.waitFor("未保存的修改"))
    target = try #require(locate("放弃", in: frameRows(tui.latestFrame)))
    tui.write(sgrPress(row: target.row, column: target.column))
    try #require(await waitUntil { tui.screenText.contains("输入消息，或按 / 选择命令") })
    let stored = directory.appendingPathComponent("plugin-settings/site.lingxi.probe.settings.json")
    #expect(!FileManager.default.fileExists(atPath: stored.path))

    tui.write("/quit\r")
    #expect(await waitUntil(timeout: .seconds(60)) { !tui.isRunning })
    #expect(tui.status == 0)
}

@Test(
    "TUI-006 a settings host that dies during the save commit closes the window with a notice",
    .enabled(if: interactionPTYEnabled)
)
func TUI_012_deadSettingsHostClosesSafely() async throws {
    let directory = try makeProbeDirectory("tui-settings-crash")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedProbe(directory, enabled: false)
    // The probe's own configuration makes it exit inside the commit step, i.e. the settings host
    // itself dies while the TUI is waiting for the save.
    try seedProbeConfig(directory, ["name": "probe", "enabled": true, "probeCrashOnCommit": true])
    let tui = try PTYProcess(environment: probeEnvironment(directory))
    defer { tui.terminate() }
    try #require(await tui.waitFor("没有可用模型"))
    try await openProbeSettings(tui)
    tui.write("X")
    try #require(await tui.waitFor("probeX"))
    tui.write("\u{13}")
    // The session is gone for good, so the window closes with a notice rather than swallowing keys.
    try #require(await tui.waitFor("插件设置已关闭"))
    try #require(await waitUntil { tui.screenText.contains("输入消息，或按 / 选择命令") })
    #expect(!tui.screenText.contains("未保存的修改"))

    tui.write("/quit\r")
    #expect(await waitUntil(timeout: .seconds(60)) { !tui.isRunning })
    #expect(tui.status == 0)
}

@Test(
    "TUI-013 Ctrl-C exits immediately while a settings save is in flight against a dying host",
    .enabled(if: interactionPTYEnabled)
)
func TUI_013_ctrlCneverBlocksOnDeadSettingsHost() async throws {
    let directory = try makeProbeDirectory("tui-settings-interrupt")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedProbe(directory, enabled: true, grants: ["crashOnApply"])
    let tui = try PTYProcess(environment: probeEnvironment(directory))
    defer { tui.terminate() }
    try #require(await tui.waitFor("没有可用模型"))
    try await openProbeSettings(tui)
    tui.write("X")
    try #require(await tui.waitFor("probeX"))

    // Save and interrupt back to back: the save never gets a chance to settle, and the exit must not
    // wait for it (or for the dying plugin host).
    let started = Date()
    tui.write("\u{13}\u{03}")
    #expect(await waitUntil(timeout: .seconds(10)) { !tui.isRunning })
    #expect(Date().timeIntervalSince(started) < 5)
    #expect(tui.status == 0)
}

@Test(
    "TUI-015 main-view clicks open the model/thinking/command pickers and the send button follows Enter",
    .enabled(if: interactionPTYEnabled)
)
func TUI_015_mainViewClickTargets() async throws {
    let directory = try makeProbeDirectory("tui-main-mouse")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedTUI(directory, turns: 2, slow: true)
    let tui = try PTYProcess(environment: probeEnvironment(directory))
    defer { tui.terminate() }
    try #require(await waitUntil(timeout: .seconds(30)) { tui.screenText.contains("mimo-v2.6-flash") })
    tui.write("/mouse\r")
    try #require(await tui.waitFor("已开启鼠标"))

    // Model name -> model picker. The picker title proves which action ran, not just that a click
    // landed somewhere.
    var target = try #require(locate("mimo-v2.6-flash", in: frameRows(tui.latestFrame)))
    tui.write(sgrPress(row: target.row, column: target.column) + sgrRelease(row: target.row, column: target.column))
    try #require(await tui.waitFor("切换模型"))
    tui.write("\u{1B}")
    try #require(await waitUntil { tui.screenText.contains("思考 服务端默认") })

    // Thinking status -> thinking picker for the live protocol, with the plugin-owned hint.
    target = try #require(locate("思考 服务端默认", in: frameRows(tui.latestFrame)))
    tui.write(sgrPress(row: target.row, column: target.column) + sgrRelease(row: target.row, column: target.column))
    try #require(await tui.waitFor("思考模式"))
    try #require(await tui.waitFor("thinking.type"))
    tui.write("\u{1B}")
    try #require(await waitUntil { tui.screenText.contains("Ctrl-P 命令") })

    // Bottom-right command hint -> the command palette.
    target = try #require(locate("Ctrl-P 命令", in: frameRows(tui.latestFrame)))
    tui.write(sgrPress(row: target.row, column: target.column) + sgrRelease(row: target.row, column: target.column))
    try #require(await tui.waitFor("连接模型"))
    tui.write("\u{1B}")
    try #require(await waitUntil { tui.screenText.contains("输入消息，或按 / 选择命令") })

    // Send button: same path as Enter, and the draft is cleared by the send.
    tui.write("第一段")
    try #require(await waitUntil { tui.screenText.contains("[ 发送 ]") })
    target = try #require(locate("[ 发送 ]", in: frameRows(tui.latestFrame)))
    tui.write(sgrPress(row: target.row, column: target.column) + sgrRelease(row: target.row, column: target.column))
    try #require(await waitUntil { tui.screenText.contains("生成中") })

    // While the run is live the button is disabled: a click at the same cell must not submit, and the
    // draft typed during generation stays in the composer.
    tui.write("第二段")
    try #require(await waitUntil { tui.screenText.contains("第二段") })
    if let send = locate("[ 发送 ]", in: frameRows(tui.latestFrame)) {
        tui.write(sgrPress(row: send.row, column: send.column) + sgrRelease(row: send.row, column: send.column))
    }
    try await Task.sleep(for: .milliseconds(400))
    #expect(tui.screenText.contains("生成中"))
    #expect(tui.screenText.contains("第二段"))
    try #require(await waitUntil(timeout: .seconds(30)) { !tui.screenText.contains("生成中") })

    // Once the run is over the button works again and the preserved draft is submitted.
    target = try #require(locate("[ 发送 ]", in: frameRows(tui.latestFrame)))
    tui.write(sgrPress(row: target.row, column: target.column) + sgrRelease(row: target.row, column: target.column))
    try #require(await waitUntil { tui.screenText.contains("生成中") })
    try #require(await waitUntil(timeout: .seconds(30)) { !tui.screenText.contains("生成中") })
    #expect(!tui.screenText.contains("[ 发送 ]第二段"))

    tui.write("/quit\r")
    #expect(await waitUntil(timeout: .seconds(60)) { !tui.isRunning })
    #expect(tui.status == 0)
}
