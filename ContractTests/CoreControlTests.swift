import Foundation
import LingXiKernel
import LingXiPluginABI
import LingXiPluginRuntime
import Testing

/// Drives the real CoreHost in its line-oriented control mode. This is the only way to prove
/// runtime switching on a resident Core without a frontend.
private final class CoreControl: @unchecked Sendable {
    private enum Stream { case lines, errors }
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var lines: [String] = []
    private var errors: [String] = []
    private var cursor = 0

    init(dataDirectory: URL) throws {
        process.executableURL = builtProduct("LingXiCoreHost")
        var environment = ProcessInfo.processInfo.environment
        environment["LINGXI_DATA_DIR"] = dataDirectory.path
        environment["LINGXI_CORE_CONTROL"] = "1"
        environment["LINGXI_PLUGIN_POLICY"] = "development"
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        drain(stdout, stream: .lines)
        drain(stderr, stream: .errors)
    }

    private func drain(_ pipe: Pipe, stream: Stream) {
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            var pending = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                guard !chunk.isEmpty else { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    self.lock.lock()
                    switch stream {
                    case .lines: self.lines.append(line)
                    case .errors: self.errors.append(line)
                    }
                    self.lock.unlock()
                }
            }
        }
    }

    var capturedLines: [String] {
        lock.lock(); defer { lock.unlock() }; return lines
    }

    var capturedErrors: [String] {
        lock.lock(); defer { lock.unlock() }; return errors
    }

    func waitForLine(prefix: String, timeout: Duration = .seconds(90)) async -> String? {
        let found = await waitUntil(timeout: timeout) {
            self.capturedLines.contains { $0.hasPrefix(prefix) }
        }
        guard found else { return nil }
        return capturedLines.last { $0.hasPrefix(prefix) }
    }

    func send(_ command: String) async -> String? {
        let prefix: String
        switch command.split(separator: " ").first.map(String.init) ?? command {
        case "enable", "disable": prefix = "\(command):"
        case "models": prefix = "models:"
        case "plugins": prefix = "plugins:"
        default: return nil
        }
        let start = capturedLines.count
        stdin.fileHandleForWriting.write(Data((command + "\n").utf8))
        // Only a reply that arrived after this command counts; stale banner/reply lines must not
        // satisfy the wait.
        let found = await waitUntil { self.capturedLines.dropFirst(start).contains { $0.hasPrefix(prefix) } }
        guard found else { return nil }
        return capturedLines.dropFirst(start).last { $0.hasPrefix(prefix) }
    }

    func quit(timeout: Duration = .seconds(60)) async -> Int32 {
        stdin.fileHandleForWriting.write(Data("quit\n".utf8))
        let exited = await waitUntil(timeout: timeout) { self.process.isRunning == false }
        if !exited, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        return process.status
    }

    func forceStop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}

private extension Process {
    var status: Int32 { terminationStatus }
}

private func seedEnabledRegistry(_ dataDirectory: URL) async throws {
    let registry = try PluginRegistry(configURL: dataDirectory.appendingPathComponent("plugins.json"))
    let mimo = try makeBundle(
        bundleID: "site.lingxi.provider.mimo", executableName: "MiMoProvider",
        dylib: builtProduct("libMiMoProvider.dylib"), capabilities: ["provider.mimo", "settings.view.v1"]
    )
    let deepseek = try makeBundle(
        bundleID: "site.lingxi.provider.deepseek", executableName: "DeepSeekProvider",
        dylib: builtProduct("libDeepSeekProvider.dylib"), capabilities: ["provider.deepseek"]
    )
    try await registry.upsert(.init(
        bundleID: "site.lingxi.provider.mimo", version: "1.0.0", bundlePath: mimo.url.path, enabled: true
    ))
    try await registry.upsert(.init(
        bundleID: "site.lingxi.provider.deepseek", version: "1.0.0", bundlePath: deepseek.url.path, enabled: true
    ))
}

@Test("PLG-001 a resident Core switches providers at runtime and restores the user's choice on restart")
func PLG_001_residentCoreRuntimeSwitching() async throws {
    let dataDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-control-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dataDirectory) }
    try await seedEnabledRegistry(dataDirectory)

    let first = try CoreControl(dataDirectory: dataDirectory)
    defer { first.forceStop() }
    #expect(await first.waitForLine(prefix: "control: ready") != nil, "stderr: \(first.capturedErrors)")

    #expect(await first.send("models") == "models: deepseek-flash,mimo-v2.6-flash,mimo-v2.6-pro")
    let startupPlugins = await first.send("plugins")
    #expect(startupPlugins?.contains("site.lingxi.provider.mimo=running") == true)
    #expect(startupPlugins?.contains("site.lingxi.provider.deepseek=running") == true)

    // Capture host PIDs so cleanup can be checked after quit.
    let pidLines = first.capturedLines.filter { $0.contains("plugin host pid:") }
    let pids = pidLines.compactMap { line -> Int32? in
        guard let value = line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) else { return nil }
        return Int32(value)
    }
    #expect(pids.count == 2)

    #expect(await first.send("disable site.lingxi.provider.mimo") == "disable site.lingxi.provider.mimo: ok")
    #expect(await first.send("models") == "models: deepseek-flash")
    let afterDisable = await first.send("plugins")
    #expect(afterDisable?.contains("site.lingxi.provider.mimo=stopped") == true)
    #expect(afterDisable?.contains("site.lingxi.provider.deepseek=running") == true)

    // Re-enable without restarting the Core.
    #expect(await first.send("enable site.lingxi.provider.mimo") == "enable site.lingxi.provider.mimo: ok")
    #expect(await first.send("models") == "models: deepseek-flash,mimo-v2.6-flash,mimo-v2.6-pro")

    // Leave MiMo disabled for the restart check.
    #expect(await first.send("disable site.lingxi.provider.mimo") == "disable site.lingxi.provider.mimo: ok")
    #expect(await first.quit() == 0)
    for pid in pids { #expect(await waitUntil { kill(pid, 0) != 0 }) }

    // No journal pollution from control commands or plugin starts.
    let journal = dataDirectory.appendingPathComponent("events.jsonl")
    let journalEmpty = !FileManager.default.fileExists(atPath: journal.path)
        || (try? Data(contentsOf: journal).isEmpty) == true
    #expect(journalEmpty)

    // Restart: the user's disable survives; DeepSeek comes back on its own.
    let second = try CoreControl(dataDirectory: dataDirectory)
    defer { second.forceStop() }
    #expect(await second.waitForLine(prefix: "control: ready") != nil, "stderr: \(second.capturedErrors)")
    let plugins = await second.send("plugins")
    #expect(plugins?.contains("site.lingxi.provider.mimo=stopped") == true)
    #expect(plugins?.contains("site.lingxi.provider.deepseek=running") == true)
    #expect(await second.send("models") == "models: deepseek-flash")
    #expect(await second.quit() == 0)
}
