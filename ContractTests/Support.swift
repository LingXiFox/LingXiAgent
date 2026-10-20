import Foundation
import LingXiKernel
import LingXiPluginABI

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let buildProducts = repoRoot.appendingPathComponent(".build/debug")

func builtProduct(_ name: String) -> URL {
    buildProducts.appendingPathComponent(name)
}

struct TestBundle {
    let bundleID: String
    let url: URL
}

/// Assembles a real `.lxap` around an already built dylib and signs it ad-hoc. This is the packaging
/// step the design assigns to the release tooling; doing it here keeps the test honest about what an
/// installed plugin actually looks like.
func makeBundle(
    bundleID: String,
    executableName: String,
    dylib: URL,
    capabilities: [String],
    permissions: [String] = [],
    abiMajor: Int = 1,
    omitPermissions: Bool = false
) throws -> TestBundle {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lxap-\(bundleID)-\(UUID().uuidString)")
    let contents = root.appendingPathComponent("Contents")
    let macos = contents.appendingPathComponent("MacOS")
    try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: dylib, to: macos.appendingPathComponent(executableName))

    let plist: [String: Any] = [
        "CFBundleIdentifier": bundleID,
        "CFBundleShortVersionString": "1.0.0",
        "CFBundleVersion": "1",
        "CFBundleExecutable": executableName,
        "CFBundlePackageType": "BNDL",
        "LSMinimumSystemVersion": "26.0",
        "LingXiPlugin": omitPermissions ? [
            "ABIMajor": abiMajor,
            "MinimumCoreVersion": "2.0.0",
            "EntryPoint": "LingXiPlugin_Init",
            "Capabilities": capabilities,
        ] as [String: Any] : [
            "ABIMajor": abiMajor,
            "MinimumCoreVersion": "2.0.0",
            "EntryPoint": "LingXiPlugin_Init",
            "Capabilities": capabilities,
            "Permissions": permissions,
        ] as [String: Any],
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))

    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["--force", "--deep", "--sign", "-", "--identifier", bundleID, root.path]
    let errorPipe = Pipe()
    sign.standardError = errorPipe
    try sign.run()
    let errorText = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    sign.waitUntilExit()
    guard sign.terminationStatus == 0 else {
        throw NSError(domain: "codesign", code: Int(sign.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorText])
    }
    return TestBundle(bundleID: bundleID, url: root)
}

final class InMemorySink: EventLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(line: String) throws {
        lock.lock(); lines.append(line); lock.unlock()
    }

    func truncate(toLineCount count: Int) throws {
        lock.lock(); lines = Array(lines.prefix(count)); lock.unlock()
    }

    func readLines() throws -> [String] {
        lock.lock(); defer { lock.unlock() }; return lines
    }
}

final class ScriptedProvider: ModelProvider, @unchecked Sendable {
    let capabilities = ModelCapabilities(
        supportsReasoning: false, supportsParallelToolCalls: false, toolResultPlacement: .anywhereInHistory
    )
    private let lock = NSLock()
    private var recorded: [ModelRequest] = []
    private let script: [ModelEvent]

    init(script: [ModelEvent] = [.started, .textDelta("ok"), .completed(.stop)]) {
        self.script = script
    }

    var requests: [ModelRequest] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }

    private func record(_ request: ModelRequest) {
        lock.lock(); recorded.append(request); lock.unlock()
    }

    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        record(request)
        let script = self.script
        return AsyncThrowingStream { continuation in
            for event in script { continuation.yield(event) }
            continuation.finish()
        }
    }

    func endExecution(_ executionID: ExecutionID) async {}
}

struct NoopExecutor: ToolExecutor {
    func execute(_ call: ToolCall, descriptor: ToolDescriptor) async throws -> ToolOutcome {
        ToolOutcome(callID: call.callID, content: "noop", isError: false, effect: descriptor.effect)
    }
}

func makeTestLoop(provider: any ModelProvider, pipeline: HookPipeline) async throws -> AgentLoop {
    let router = ModelRouter()
    try? await router.register(provider: provider, id: "test.provider", models: ["test-model"])
    return AgentLoop(
        router: router,
        toolRegistry: ToolRegistry(),
        executor: NoopExecutor(),
        log: try DurableEventLog(sink: InMemorySink()),
        runs: RunRegistry(),
        store: SessionStore(),
        hooks: pipeline,
        instructions: "instructions"
    )
}

func runRequest(session: String, turn: Int) -> RunRequest {
    RunRequest(
        sessionID: SessionID(session),
        turnID: TurnID("turn-\(turn)"),
        runID: RunID("run-\(session)-\(turn)"),
        executionID: ExecutionID("exec-\(session)-\(turn)"),
        model: ModelID("test-model"),
        prompt: "prompt \(turn)"
    )
}

/// Poll to a deadline instead of sleeping a fixed amount: the condition is the thing being waited
/// for, and a missed deadline fails rather than silently continuing.
func waitUntil(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(
        Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
    )
    while Date() < deadline {
        if await condition() { return true }
        usleep(10_000)
    }
    return await condition()
}
