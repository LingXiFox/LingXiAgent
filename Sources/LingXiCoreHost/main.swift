import Foundation
import LingXiKernel

let dataDirectory = ProcessInfo.processInfo.environment["LINGXI_DATA_DIR"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/LingXiAgent")
try FileManager.default.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)

let log = try DurableEventLog(sink: FileEventLogSink(url: URL(fileURLWithPath: dataDirectory).appendingPathComponent("events.jsonl")))
let router = ModelRouter()
let loop = AgentLoop(
    router: router,
    toolRegistry: ToolRegistry(),
    executor: UnavailableToolExecutor(),
    log: log,
    runs: RunRegistry(),
    store: SessionStore(),
    instructions: "LingXiAgent 2.0 core"
)

print("LingXiAgent 2.0 core host")
print("  providers: \(await router.providerCount)")
print("  tools:     \(await ToolRegistry().manifest().count)")

let runID = RunID("boot-\(Date().timeIntervalSince1970)")
let result = await loop.run(
    RunRequest(
        sessionID: "boot",
        turnID: "boot",
        runID: runID,
        executionID: ExecutionID("boot"),
        model: ModelID("none"),
        prompt: ""
    ),
    policy: LoopPolicy()
)

print("  run:       \(result.status.rawValue) / \(result.cause.rawValue)")
if let detail = result.detail {
    print("  guidance:  \(detail)")
}
print("The core runs without a provider, but cannot start a conversation until a provider plugin is enabled.")

struct UnavailableToolExecutor: ToolExecutor {
    func execute(_ call: ToolCall, descriptor: ToolDescriptor) async throws -> ToolOutcome {
        ToolOutcome(callID: call.callID, content: "no task plugin is enabled", isError: true, effect: .unknown)
    }
}
