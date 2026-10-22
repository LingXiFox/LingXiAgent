import Darwin
import Foundation
import LingXiFrontendProtocol
import LingXiKernel
import LingXiPluginABI
import LingXiPluginRuntime
import Testing

final class ProtocolCore: @unchecked Sendable {
    private enum Stream { case stdout, stderr }
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var lines: [Data] = []
    private var errors: [Data] = []
    private var nextID = 1
    private var cursor = 0

    init(dataDirectory: URL, keychainService: String = "site.lingxi.credentials.test.\(UUID().uuidString)") throws {
        process.executableURL = builtProduct("LingXiCoreHost")
        var environment = ProcessInfo.processInfo.environment
        environment["LINGXI_DATA_DIR"] = dataDirectory.path
        environment["LINGXI_KEYCHAIN_SERVICE"] = keychainService
        environment.removeValue(forKey: "LINGXI_CREDENTIAL_SOURCE")
        environment["LINGXI_FRONTEND"] = "stdio"
        environment["LINGXI_PLUGIN_POLICY"] = "development"
        environment.removeValue(forKey: "LINGXI_CORE_CONTROL")
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        drain(stdout, stream: .stdout)
        drain(stderr, stream: .stderr)
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
                    let line = Data(pending[pending.startIndex..<newline])
                    pending.removeSubrange(pending.startIndex...newline)
                    self.lock.lock()
                    switch stream {
                    case .stdout: self.lines.append(line)
                    case .stderr: self.errors.append(line)
                    }
                    self.lock.unlock()
                }
            }
        }
    }

    var stderrText: String {
        lock.lock(); defer { lock.unlock() }
        return errors.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
    }

    func send(_ method: FrontendMethod, sessionID: String? = nil, model: String? = nil,
              text: String? = nil, runID: String? = nil, bundleID: String? = nil,
              provider: String? = nil, secret: String? = nil) -> Int {
        lock.lock(); let id = nextID; nextID += 1; lock.unlock()
        var request = FrontendRequest(id: id, method: method)
        request.sessionID = sessionID; request.model = model; request.text = text
        request.runID = runID; request.bundleID = bundleID
        request.provider = provider; request.secret = secret
        stdin.fileHandleForWriting.write((try! JSONEncoder().encode(request)) + Data([UInt8(ascii: "\n")]))
        return id
    }

    func waitReply(_ id: Int, timeout: Duration = .seconds(90)) async -> FrontendReply? {
        // Reply ids are unique, so the whole buffer is safe to search: a fast reply must not be
        // missed because it arrived before the cursor was taken.
        guard await waitUntil(timeout: timeout, { self.snapshot().contains { data in
            (try? JSONDecoder().decode(FrontendReply.self, from: data))?.id == id
        } }) else { return nil }
        return snapshot().compactMap { try? JSONDecoder().decode(FrontendReply.self, from: $0) }
            .last { $0.id == id }
    }

    func waitEvent(_ name: String, after start: Int, timeout: Duration = .seconds(90)) async -> FrontendEvent? {
        guard await waitUntil(timeout: timeout, { self.snapshot().dropFirst(start).contains { data in
            (try? JSONDecoder().decode(FrontendEvent.self, from: data))?.event == name
        } }) else { return nil }
        return snapshot().dropFirst(start).compactMap { try? JSONDecoder().decode(FrontendEvent.self, from: $0) }
            .first { $0.event == name }
    }

    func collectDeltas(after start: Int) -> String {
        snapshot().dropFirst(start).compactMap { try? JSONDecoder().decode(FrontendEvent.self, from: $0) }
            .filter { $0.event == "delta" }
            .compactMap(\.delta)
            .joined()
    }

    func snapshot() -> [Data] {
        lock.lock(); defer { lock.unlock() }; return lines
    }

    func terminate() {
        if process.isRunning { stdin.fileHandleForWriting.closeFile(); process.terminate() }
        if !waitForProcessExit(process, timeout: 3) {
            kill(process.processIdentifier, SIGKILL)
            #expect(waitForProcessExit(process, timeout: 2), "Core test process did not exit after SIGKILL")
        }
    }

    var exitStatus: Int32 { process.terminationStatus }
    var isRunning: Bool { process.isRunning }

    func closeInput() { stdin.fileHandleForWriting.closeFile() }
}

func seedTUICore(_ directory: URL) async throws {
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

@Test("FE-007 the protocol drives the real Core and MiMo plugin: chat, history, sessions, plugin toggle")
func FE_007_protocolEndToEnd() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("frontend-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await seedTUICore(directory)

    let core = try ProtocolCore(dataDirectory: directory)
    defer { core.terminate() }

    let helloID = core.send(.hello)
    let hello = try #require(await core.waitReply(helloID), "stderr: \(core.stderrText)")
    #expect(hello.ok)
    #expect(hello.models == ["mimo-v2.6-flash", "mimo-v2.6-pro"])
    // Every offered model gets a detail entry even when the plugin declares no thinking levels.
    #expect(hello.modelDetails?.map(\.id) == hello.models)
    #expect(hello.modelDetails?.allSatisfy { $0.thinkingLevels.isEmpty } == true)
    let plugin = try #require(hello.plugins?.first)
    #expect(plugin.bundleID == "site.lingxi.provider.mimo")
    #expect(plugin.running)
    #expect(plugin.capabilities.contains("provider.mimo"))

    let before = core.snapshot().count
    let chatID = core.send(.chatSend, model: "mimo-v2.6-flash", text: "你好")
    let chatReply = try #require(await core.waitReply(chatID))
    #expect(chatReply.ok)
    let runID = try #require(chatReply.runID)
    #expect(runID.hasPrefix("run-"))
    let terminal = try #require(await core.waitEvent("run.terminal", after: before))
    #expect(terminal.status == "completed", "status=\(terminal.status ?? "") cause=\(terminal.cause ?? "") detail=\(terminal.detail ?? "") stderr=\(core.stderrText)")
    let streamed = core.collectDeltas(after: before)
    #expect(streamed.lowercased().contains("pong"))

    let sessionsID = core.send(.sessionsList)
    let sessions = try #require(await core.waitReply(sessionsID))
    #expect(sessions.sessions?.count == 1)
    #expect(sessions.sessions?.first?.title == "你好")

    let sessionID = try #require(chatReply.sessionID)
    let historyID = core.send(.sessionHistory, sessionID: sessionID)
    let history = try #require(await core.waitReply(historyID))
    #expect(history.history?.contains { $0.role == "user" && $0.text == "你好" } == true)
    #expect(history.history?.contains { $0.role == "assistant" && $0.text.lowercased().contains("pong") } == true)

    // Disabling removes the model immediately, and a new chat is refused before any plugin work.
    let disableID = core.send(.pluginDisable, bundleID: "site.lingxi.provider.mimo")
    let disabled = try #require(await core.waitReply(disableID))
    #expect(disabled.ok)
    #expect(disabled.models?.isEmpty == true)
    let refusedID = core.send(.chatSend, model: "mimo-v2.6-flash", text: "again")
    let refused = try #require(await core.waitReply(refusedID))
    #expect(!refused.ok)
    #expect(refused.error?.contains("no model") == true || refused.error?.contains("not offered") == true)

    // Re-enable restores the route; the fresh plugin process replays the first exchange again.
    let enableID = core.send(.pluginEnable, bundleID: "site.lingxi.provider.mimo")
    let enabled = try #require(await core.waitReply(enableID))
    #expect(enabled.ok)
    #expect(enabled.models == ["mimo-v2.6-flash", "mimo-v2.6-pro"])
    let secondStart = core.snapshot().count
    let againID = core.send(.chatSend, model: "mimo-v2.6-flash", text: "又一条")
    let again = try #require(await core.waitReply(againID))
    #expect(again.ok)
    #expect(await core.waitEvent("run.terminal", after: secondStart) != nil)

    _ = core.send(.shutdown)
    core.closeInput()
    #expect(await waitUntil { core.isRunning == false })
    #expect(core.exitStatus == 0)
}
