import Foundation
import LingXiKernel

let dataDirectory = ProcessInfo.processInfo.environment["LINGXI_DATA_DIR"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/LingXiAgent")
try FileManager.default.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)

// Startup is a status report, not a run: with no provider the host must print availability and
// configuration guidance without writing a meaningless failed run to the journal (QA-013).
do {
    let journalURL = URL(fileURLWithPath: dataDirectory).appendingPathComponent("events.jsonl")
    let log = try DurableEventLog(sink: FileEventLogSink(url: journalURL))
    let recovered = try await KernelRecovery.recover(log: log)
    let router = ModelRouter()
    let toolRegistry = ToolRegistry()

    print("LingXiAgent 2.0 core host")
    print("  providers:      \(await router.providerCount)")
    print("  models:         \(await router.offeredModels.map(\.rawValue).joined(separator: ", "))")
    print("  tools:          \(await toolRegistry.manifest().count)")
    print("  journal:        \(await log.recordCount) records, repaired tail: \(await log.repairedTailRecordCount)")
    print("  recovered runs: \(recovered.report.restoredRunCount), failed: \(recovered.report.failedRunIDs.count), unknown execution: \(recovered.report.executionStateUnknownRunIDs.count)")

    if await router.providerCount == 0 {
        print("No provider plugin is active. Install and enable a provider plugin to start a conversation; the core runs without one.")
        print("No inference was attempted; nothing was added to the journal.")
    } else {
        print("Provider plugins are active. Connect a frontend to start a conversation.")
    }
} catch {
    FileHandle.standardError.write(Data("LingXiAgent core failed to start: \(error)\n".utf8))
    exit(1)
}
