import Darwin
import Foundation
import LingXiFrontendProtocol
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
    guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    var resolved: [String: String] = [:]
    for (capability, variable) in raw {
        guard let name = variable as? String, let value = ProcessInfo.processInfo.environment[name] else { continue }
        resolved[capability] = value
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

// A resident Core publishes status and control replies to a pipe; block buffering would hide them.
setvbuf(stdout, nil, _IONBF, 0)

let dataDirectory = ProcessInfo.processInfo.environment["LINGXI_DATA_DIR"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/LingXiAgent")
try FileManager.default.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)

// The default is the strict tier. Development is an explicit opt-in, never a fallback.
let environmentPolicy = ProcessInfo.processInfo.environment["LINGXI_PLUGIN_POLICY"]
let policy: SignaturePolicy = environmentPolicy == "development" ? .development : .restricted
let controlMode = ProcessInfo.processInfo.environment["LINGXI_CORE_CONTROL"] == "1"

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
    let credentialMap = try loadCredentialMap(dataDirectory: dataDirectory)
    let coordinator = PluginCoordinator(
        hostExecutableURL: pluginHostExecutable(), registry: registry, pipeline: pipeline, router: router,
        credential: { capability in credentialMap[capability] }
    )

    let installed = await registry.all()
    var failures: [String] = []
    for entry in installed where entry.enabled {
        do {
            _ = try await coordinator.enable(
                bundleID: entry.bundleID, policy: policy, grantedPermissions: entry.grants ?? []
            )
        } catch {
            // A plugin that cannot be restored must not take the Core down with it.
            failures.append("\(entry.bundleID): \(error)")
        }
    }

    // The actual Agent Loop is built around the same pipeline the plugins mounted on.
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

    func statusLines() async -> [String] {
        let handlers = await pipeline.mountedHandlerIDs
        let running = await coordinator.runningBundleIDs()
        var lines = [
            "providers:      \(await router.providerCount)",
            "models:         \(await router.offeredModels.map(\.rawValue).sorted().joined(separator: ", "))",
            "plugin policy:  \(policy.rawValue)\(policy == .development ? " (explicit development opt-in; ad-hoc signatures are admitted as untrusted)" : "")",
            "plugins:        \(installed.count) installed, \(installed.filter(\.enabled).count) enabled, \(running.count) running",
            "plugin handlers:\(handlers.isEmpty ? " none" : " " + handlers.joined(separator: ", "))",
        ]
        for bundleID in running {
            if let pid = await coordinator.processIdentifier(bundleID: bundleID) {
                lines.append("plugin host pid: \(bundleID)=\(pid)")
            }
        }
        for failure in failures { lines.append("plugin error:   \(failure)") }
        return lines
    }

    print("LingXiAgent 2.0 core host")
    for line in await statusLines() { print("  \(line)") }
    if await router.providerCount == 0 {
        print("No provider plugin is active. Install and enable a provider plugin to start a conversation; the core runs without one.")
        print("No inference was attempted; nothing was added to the journal.")
    } else {
        print("Provider plugins are active. Connect a frontend to start a conversation.")
    }

    if ProcessInfo.processInfo.environment["LINGXI_FRONTEND"] == "stdio" {
        let server = FrontendServer(
            loop: loop, store: recovered.store, router: router,
            registry: registry, coordinator: coordinator, policy: policy
        )
        await server.serve()
    } else if controlMode {
        // A line-oriented control surface for verifying runtime switching without a frontend. It
        // touches plugin routes and processes only; the journal is never written.
        print("control: ready")
        func emit(_ line: String) {
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
        var pending = Data()
        loop: while true {
            let chunk = FileHandle.standardInput.availableData
            guard !chunk.isEmpty else { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let raw = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
                guard let command = parts.first else { continue }
                switch command {
                case "models":
                    emit("models: " + (await router.offeredModels.map(\.rawValue).sorted().joined(separator: ",")))
                case "plugins":
                    var states: [String] = []
                    for entry in await registry.all() {
                        states.append("\(entry.bundleID)=\(await coordinator.isRunning(bundleID: entry.bundleID) ? "running" : "stopped")")
                    }
                    emit("plugins: " + states.sorted().joined(separator: ","))
                case "enable", "disable":
                    guard parts.count == 2 else { emit("error: \(command) needs a bundle id"); continue }
                    do {
                        if command == "enable" {
                            let grants = await registry.entry(parts[1])?.grants ?? []
                            _ = try await coordinator.enable(
                                bundleID: parts[1], policy: policy, grantedPermissions: grants
                            )
                        } else {
                            try await coordinator.disable(bundleID: parts[1])
                        }
                        emit("\(command) \(parts[1]): ok")
                    } catch {
                        emit("\(command) \(parts[1]): error=\(error)")
                    }
                case "quit":
                    break loop
                default:
                    emit("error: unknown command \(command)")
                }
            }
        }
    }

    // No plugin process outlives the Core.
    await coordinator.shutdown()
} catch {
    FileHandle.standardError.write(Data("LingXiAgent core failed to start: \(error)\n".utf8))
    exit(1)
}
