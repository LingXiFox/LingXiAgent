import Foundation
import LingXiKernel
import LingXiPluginABI
import LingXiPluginRuntime

/// The Core has no tool implementation of its own; tools arrive as plugin capabilities. Until one
/// does, the port refuses with a named error instead of pretending.
private struct NoToolExecutor: ToolExecutor {
    struct Unavailable: Error, CustomStringConvertible {
        var description: String { "no tool plugin is active" }
    }

    func execute(_ call: ToolCall, descriptor: ToolDescriptor) async throws -> ToolOutcome {
        throw Unavailable()
    }
}

/// Reads `<data>/credentials.json` and resolves each capability id to the environment variable the
/// Core will read. Only the variable name is stored on disk; values exist in this process only.
private func loadCredentialMap(dataDirectory: String) throws -> [String: String] {
    let url = URL(fileURLWithPath: dataDirectory).appendingPathComponent("credentials.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    let data = try Data(contentsOf: url)
    guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
    var resolved: [String: String] = [:]
    for (capability, variable) in raw {
        if let value = ProcessInfo.processInfo.environment[variable] {
            resolved[capability] = value
        }
    }
    return resolved
}

private func pluginHostExecutable() -> URL {
    if let override = ProcessInfo.processInfo.environment["LINGXI_PLUGIN_HOST"] {
        return URL(fileURLWithPath: override)
    }
    let selfURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    return selfURL.deletingLastPathComponent().appendingPathComponent("LingXiPluginHost")
}

let dataDirectory = ProcessInfo.processInfo.environment["LINGXI_DATA_DIR"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/LingXiAgent")
try FileManager.default.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)

// The default is the strict tier. Development is an explicit opt-in, never a fallback, and it says
// out loud that signatures it admits are untrusted.
let environmentPolicy = ProcessInfo.processInfo.environment["LINGXI_PLUGIN_POLICY"]
let policy: SignaturePolicy = environmentPolicy == "development" ? .development : .restricted

// Startup is a status report, not a run: with no provider the host must print availability and
// configuration guidance without writing a meaningless failed run to the journal (QA-013).
do {
    let journalURL = URL(fileURLWithPath: dataDirectory).appendingPathComponent("events.jsonl")
    let log = try DurableEventLog(sink: FileEventLogSink(url: journalURL))
    let recovered = try await KernelRecovery.recover(log: log)
    let router = ModelRouter()
    let toolRegistry = ToolRegistry()

    // Plugin state comes from its own registry, never from the session journal (ADR-0003).
    let registryURL = URL(fileURLWithPath: dataDirectory).appendingPathComponent("plugins.json")
    let registry = try PluginRegistry(configURL: registryURL)
    let pipeline = HookPipeline()

    // credentials.json maps a capability id to the NAME of an environment variable the Core owns.
    // The value never enters a plugin process environment, a log line or the registry.
    let credentialMap = try loadCredentialMap(dataDirectory: dataDirectory)
    let coordinator = PluginCoordinator(
        hostExecutableURL: pluginHostExecutable(), registry: registry, pipeline: pipeline,
        credential: { capability in credentialMap[capability] }
    )

    let installed = await registry.all()
    var failures: [String] = []
    for entry in installed where entry.enabled {
        do {
            _ = try await coordinator.enable(bundleID: entry.bundleID, policy: policy)
            // A provider plugin becomes a model source for the loop; the kernel still sees only ids.
            for binding in await coordinator.providerBindings(bundleID: entry.bundleID) {
                await router.register(
                    provider: binding.adapter,
                    id: ProviderID(binding.declaration.id),
                    models: binding.declaration.models.map { ModelID($0) }
                )
            }
        } catch {
            // A plugin that cannot be restored must not take the Core down with it.
            failures.append("\(entry.bundleID): \(error)")
        }
    }

    // The actual Agent Loop is built around the same pipeline the plugins mounted on. A hook that
    // fires during a turn is a plugin call, not a copy.
    let loop = AgentLoop(
        router: router,
        toolRegistry: toolRegistry,
        executor: NoToolExecutor(),
        log: log,
        runs: recovered.runs,
        store: recovered.store,
        hooks: pipeline,
        instructions: "You are LingXi, a local agent."
    )
    _ = loop

    let handlers = await pipeline.mountedHandlerIDs
    let running = await coordinator.runningBundleIDs()

    print("LingXiAgent 2.0 core host")
    print("  providers:      \(await router.providerCount)")
    print("  models:         \(await router.offeredModels.map(\.rawValue).joined(separator: ", "))")
    print("  tools:          \(await toolRegistry.manifest().count)")
    print("  journal:        \(await log.recordCount) records, repaired tail: \(await log.repairedTailRecordCount)")
    print("  recovered runs: \(recovered.report.restoredRunCount), failed: \(recovered.report.failedRunIDs.count), unknown execution: \(recovered.report.executionStateUnknownRunIDs.count)")
    print("  plugin policy:  \(policy.rawValue)\(policy == .development ? " (explicit development opt-in; ad-hoc signatures are admitted as untrusted)" : "")")
    print("  plugins:        \(installed.count) installed, \(installed.filter(\.enabled).count) enabled, \(running.count) running")
    print("  plugin handlers:\(handlers.isEmpty ? " none" : " " + handlers.joined(separator: ", "))")
    for bundleID in running {
        if let pid = await coordinator.processIdentifier(bundleID: bundleID) {
            print("  plugin host pid: \(bundleID)=\(pid)")
        }
    }
    for failure in failures {
        print("  plugin error:   \(failure)")
    }

    if await router.providerCount == 0 {
        print("No provider plugin is active. Install and enable a provider plugin to start a conversation; the core runs without one.")
        print("No inference was attempted; nothing was added to the journal.")
    } else {
        print("Provider plugins are active. Connect a frontend to start a conversation.")
    }

    // No plugin process outlives the Core.
    await coordinator.shutdown()
} catch {
    FileHandle.standardError.write(Data("LingXiAgent core failed to start: \(error)\n".utf8))
    exit(1)
}
