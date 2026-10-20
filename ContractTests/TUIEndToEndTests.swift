import Foundation
import LingXiKernel
import LingXiPluginABI
import LingXiPluginRuntime
import Testing

/// Runs the real TUI inside a PTY (via /usr/bin/script) against a real Core and the real MiMo
/// plugin process, replaying a recorded cassette. No part of the UI is mocked.
private final class PTYProcess: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var captured = Data()

    init(environment: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", builtProduct("LingXiTUI").path]
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

    func write(_ text: String) {
        stdin.fileHandleForWriting.write(Data(text.utf8))
    }

    func waitFor(_ text: String, timeout: Duration = .seconds(90)) async -> Bool {
        await waitUntil(timeout: timeout) { self.transcript.contains(text) }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    var isRunning: Bool { process.isRunning }
    var status: Int32 { process.terminationStatus }
}

private func seedTUI(_ directory: URL) async throws {
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
    environment["TERM"] = "xterm-256color"
    environment.removeValue(forKey: "LINGXI_CORE_CONTROL")
    environment.removeValue(forKey: "LINGXI_FRONTEND")

    let tui = try PTYProcess(environment: environment)
    defer { tui.terminate() }

    // The Core activates plugins at startup; wait until the greeting reports a live model.
    #expect(await tui.waitFor("输入消息开始对话。用 /help"), "startup transcript tail: \(tui.transcript.suffix(800))")
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

    tui.write("/quit\r")
    #expect(await waitUntil(timeout: .seconds(60)) { tui.isRunning == false })
    #expect(tui.status == 0, "transcript tail: \(tui.transcript.suffix(800))")
}
