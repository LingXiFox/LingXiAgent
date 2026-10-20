import Darwin
import Foundation
import LingXiKernel
import LingXiPluginABI
import LingXiPluginRuntime
import Testing

/// Runs the real TUI inside a PTY (via /usr/bin/script) against a real Core and the real MiMo
/// plugin process, replaying a recorded cassette. No part of the UI is mocked.
final class PTYProcess: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var captured = Data()

    init(environment: [String: String], columns: Int = 120, rows: Int = 30) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/sh", "-c",
            "/bin/stty cols \"$1\" rows \"$2\"; exec \"$3\"", "tui-test",
            String(columns), String(rows), builtProduct("LingXiTUI").path]
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = output
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        DispatchQueue.global().async { [weak self] in
            while true {
                let chunk = stderr.fileHandleForReading.availableData
                guard !chunk.isEmpty else { return }
                self?.lock.lock(); self?.captured.append(chunk); self?.lock.unlock()
            }
        }
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            while true {
                let chunk = self.output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { break }
                self.lock.lock(); self.captured.append(chunk); self.lock.unlock()
            }
        }
    }

    var transcript: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: captured, as: UTF8.self)
    }

    var latestFrame: String {
        let text = transcript
        guard let end = text.range(of: "\u{1B}[?2026l", options: .backwards),
              let start = text[..<end.lowerBound].range(of: "\u{1B}[?2026h", options: .backwards) else { return "" }
        return String(text[start.upperBound..<end.lowerBound])
    }

    var screenText: String {
        latestFrame.replacingOccurrences(of: "\u{1B}\\[[0-9]+;1H", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[a-zA-Z]", with: "", options: .regularExpression)
    }

    func write(_ text: String) {
        stdin.fileHandleForWriting.write(Data(text.utf8))
    }

    func waitFor(_ text: String, after start: Int = 0, timeout: Duration = .seconds(90)) async -> Bool {
        await waitUntil(timeout: timeout) { self.transcript.dropFirst(start).contains(text) }
    }

    func terminate() {
        if process.isRunning {
            // `script` does not guarantee forwarding SIGTERM to its child. Exit the TUI first.
            write("\u{03}\u{03}/quit\r")
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }

    var isRunning: Bool { process.isRunning }
    var status: Int32? { process.isRunning ? nil : process.terminationStatus }
}

func seedTUI(_ directory: URL) async throws {
    let bundle = try makeBundle(
        bundleID: "site.lingxi.provider.mimo", executableName: "MiMoProvider",
        dylib: builtProduct("libMiMoProvider.dylib"), capabilities: ["provider.mimo"]
    )
    let cassette = Bundle.module.url(forResource: "mimo-chat-tui", withExtension: "json", subdirectory: "Fixtures")!
    let registry = try PluginRegistry(configURL: directory.appendingPathComponent("plugins.json"))
    try await registry.upsert(.init(
        bundleID: "site.lingxi.provider.mimo", version: "1.0.0", bundlePath: bundle.url.path,
        enabled: true, grants: ["vcr=\(cassette.path)"]
    ))
}

@Test("TUI-001 the real TUI chats with MiMo over a PTY, shows plugins and exits cleanly", .enabled(if: ProcessInfo.processInfo.environment["LINGXI_RUN_TUI_PTY_TEST"] == "1"))
func TUI_001_ptyChatWithMiMo() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tui-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedTUI(directory)

    var environment = ProcessInfo.processInfo.environment
    environment["LINGXI_DATA_DIR"] = directory.path
    environment["LINGXI_CORE_HOST"] = builtProduct("LingXiCoreHost").path
    environment["LINGXI_PLUGIN_POLICY"] = "development"
    environment["LINGXI_KEYCHAIN_SERVICE"] = "site.lingxi.credentials.test.\(UUID().uuidString)"
    environment.removeValue(forKey: "LINGXI_CREDENTIAL_SOURCE")
    environment["TERM"] = "xterm-256color"
    environment.removeValue(forKey: "LINGXI_CORE_CONTROL")
    environment.removeValue(forKey: "LINGXI_FRONTEND")

    let tui = try PTYProcess(environment: environment)
    defer { tui.terminate() }

    // The Core activates plugins at startup; wait until the greeting reports a live model.
    #expect(await tui.waitFor("mimo-v2.6-flash"), "startup transcript tail: \(tui.transcript.suffix(800))")
    #expect(tui.transcript.contains("mimo-v2.6-flash"))

    // Chinese input goes through the real key parser; the reply streams from the recorded provider.
    tui.write("你好\r")
    if !(await tui.waitFor("pong")) {
        let clean = tui.transcript.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[a-zA-Z]", with: "", options: .regularExpression)
        Issue.record("TRANSCRIPT=[\(clean.suffix(2500))]")
    }

    tui.write("/plugins\r")
    #expect(await tui.waitFor("site.lingxi.provider.mimo"), "plugins transcript tail: \(tui.transcript.suffix(1500))")
    #expect(tui.transcript.contains("provider.mimo"))
    tui.write("\u{1B}")
    try #require(await waitUntil { !tui.screenText.contains("esc 关闭") })

    tui.write("/quit\r")
    #expect(await waitUntil(timeout: .seconds(60)) { tui.isRunning == false })
    #expect(tui.status == 0, "transcript tail: \(tui.transcript.suffix(800))")
}

@Test("TUI-002 complete cell-bounded frames erase command remnants and support keyboard pickers", .enabled(if: ProcessInfo.processInfo.environment["LINGXI_RUN_TUI_PTY_TEST"] == "1"))
func TUI_002_frameAndPickers() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tui-frame-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedTUI(directory)
    var environment = ProcessInfo.processInfo.environment
    environment["LINGXI_DATA_DIR"] = directory.path
    environment["LINGXI_PLUGIN_POLICY"] = "development"
    environment["LINGXI_CORE_HOST"] = builtProduct("LingXiCoreHost").path
    environment["LINGXI_KEYCHAIN_SERVICE"] = "site.lingxi.credentials.test.\(UUID().uuidString)"
    environment.removeValue(forKey: "LINGXI_CREDENTIAL_SOURCE")
    let tui = try PTYProcess(environment: environment)
    defer { tui.terminate() }
    // Core boot includes the existing 30-second plugin handshake.
    try #require(await waitUntil(timeout: .seconds(30)) { tui.screenText.contains("mimo-v2.6-flash") })
    #expect(tui.screenText.contains("L I N G X I"))

    tui.write("/auth mimo")
    try #require(await waitUntil { tui.screenText.contains("/auth mimo") })
    tui.write("\r")
    try #require(await waitUntil { tui.screenText.contains("隐藏输入中") })
    #expect(!tui.screenText.contains("/auth mimo"))
    #expect(tui.screenText.contains("Keychain"))
    let sentinel = "hidden-input-frame-sentinel"
    tui.write(sentinel)
    try #require(await waitUntil { tui.screenText.contains("已输入 \(sentinel.count) 个字符") })
    #expect(!tui.transcript.contains(sentinel))
    for row in 1...30 { #expect(tui.latestFrame.contains("\u{1B}[\(row);1H")) }
    #expect(tui.latestFrame.components(separatedBy: "\u{1B}[2K").count == 31)
    tui.write("\u{1B}")
    try #require(await waitUntil { tui.screenText.contains("已取消凭据输入") })
    #expect(!tui.screenText.contains("隐藏输入中"))

    tui.write("\u{10}切换模型\r")
    try #require(await waitUntil { tui.screenText.contains("mimo-v2.6-pro") && tui.screenText.contains("esc 关闭") })
    tui.write("\u{1B}[B\r")
    try #require(await waitUntil { tui.screenText.contains("模型已切换为 mimo-v2.6-pro") })
    #expect(!tui.screenText.contains("esc 关闭"))

    tui.write(String(repeating: "中e\u{301}🙂", count: 100))
    try #require(await waitUntil { tui.screenText.contains("中e\u{301}🙂") })
    for line in tui.screenText.split(separator: "\n") {
        // This fixture uses ASCII, box drawing, CJK, combining accents and emoji.
        let cells = line.reduce(0) { $0 + ($1.unicodeScalars.contains { $0.value >= 0x2E80 } ? 2 : 1) }
        #expect(cells <= 120)
    }
    tui.write("\u{15}")
    try #require(await waitUntil { tui.screenText.contains("输入消息，或按 / 选择命令") })
    #expect(!tui.screenText.contains("中e\u{301}🙂"))
    tui.write("/quit\r")
    #expect(await waitUntil { !tui.isRunning })
    #expect(tui.status == 0)

    // A separate small PTY checks that row addressing never relies on an 80-column fallback.
    let narrow = try PTYProcess(environment: environment, columns: 40, rows: 12)
    defer { narrow.terminate() }
    try #require(await waitUntil(timeout: .seconds(30)) { narrow.screenText.contains("mimo-v2.6-flash") })
    #expect(narrow.latestFrame.components(separatedBy: "\u{1B}[2K").count == 13)
    narrow.write("/quit\r")
    #expect(await waitUntil { !narrow.isRunning })
}
