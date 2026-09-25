import Foundation

/// Location of the LingXiAgent data root, resolved exactly like the Application
/// layer (`LINGXI_DATA_ROOT` override, else `~/.lingxiagent`).
public enum LingXiDataRoot {
    public static var url: URL {
        let override = ProcessInfo.processInfo.environment["LINGXI_DATA_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lingxiagent", isDirectory: true)
    }

    public static func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

/// A typed path into `config.json`. `fallback` mirrors the bundled Core default
/// (`LingXiCore/Resources/Configuration/Defaults/config.json`) and is shown when
/// the user has not overridden the key.
struct ConfigKey<Value>: Sendable where Value: Sendable {
    let path: [String]
    let fallback: Value

    init(_ path: String, _ fallback: Value) {
        self.path = path.split(separator: ".").map(String.init)
        self.fallback = fallback
    }

    var id: String { path.joined(separator: ".") }
}

/// Global Core defaults read from `config.json` (schema: `config.schema.json`).
/// Only keys Core actually consumes are listed; schema keys with no reader
/// (`core.locale`, `core.logLevel`, `context.fabric.contextRecallEnabled`) and the
/// legacy `runtime.commandTimeoutSeconds` fallback are deliberately absent.
enum ConfigKeys {

    static let permissionPolicy = ConfigKey("agent.permissionPolicy", "ask")
    static let executionProfile = ConfigKey("agent.executionProfile", "workspace")
    static let behaviorProfile = ConfigKey("agent.behaviorProfile", "build")
    static let codeIntelligence = ConfigKey("agent.codeIntelligenceEnabled", false)
    static let systemContext = ConfigKey("agent.systemContext", "")
    static let maxConcurrentSubagents = ConfigKey("agent.maxConcurrentSubagents", 4)
    static let maxSubagentDepth = ConfigKey("agent.maxSubagentDepth", 3)
    static let maxTotalRuns = ConfigKey("agent.maxTotalRunsPerRootRun", 32)
    static let maxAgentLoopSteps = ConfigKey("agent.maxAgentLoopSteps", 32)
    static let l1ProjectMaxCharacters = ConfigKey("agent.l1ProjectMaxCharacters", 32_768)
    static let l2MaxCharacters = ConfigKey("agent.l2MaxCharacters", 262_144)
    // Dual-core conceptual aliases
    static let projectInstructionBudget = l1ProjectMaxCharacters
    static let eCoreWorkingSetMaxCharacters = l2MaxCharacters

    static let quickFilesystemSeconds = ConfigKey("runtime.execution.quickFilesystemSeconds", 10.0)
    static let searchSeconds = ConfigKey("runtime.execution.searchSeconds", 30.0)
    static let foregroundShellSeconds = ConfigKey("runtime.execution.foregroundShellSeconds", 60.0)
    static let buildTestSeconds = ConfigKey("runtime.execution.buildTestSeconds", 300.0)
    static let mcpSeconds = ConfigKey("runtime.execution.mcpSeconds", 60.0)
    static let providerSeconds = ConfigKey("runtime.execution.providerSeconds", 120.0)
    static let providerIdleSeconds = ConfigKey("runtime.execution.providerIdleSeconds", 45.0)
    static let subagentSeconds = ConfigKey("runtime.execution.subagentSeconds", 600.0)
    static let agentRunSeconds = ConfigKey("runtime.execution.agentRunSeconds", 1800.0)
    static let maximumSeconds = ConfigKey("runtime.execution.maximumSeconds", 3600.0)

    static let addressableBudget = ConfigKey("context.addressableBudget", 1_048_576)
    static let reserve = ConfigKey("context.reserve", 22_000)
    static let economicThreshold = ConfigKey("context.economicThreshold", 272_000)

    // P-Core 双核预算体系
    static let pCoreTarget = ConfigKey("context.pCore.target", 220_000)
    static let pCoreSoftLimit = ConfigKey("context.pCore.softLimit", 235_000)
    static let pCoreHardLimit = ConfigKey("context.pCore.hardLimit", 250_000)

    // E-Core 对象存储与召回策略
    static let eCoreStorageBudget = ConfigKey("context.eCore.storageBudget", 456_576)
    static let eCoreRecallBudget = ConfigKey("context.eCore.recallBudget", 350_000)
    static let eCorePressureThreshold = ConfigKey("context.eCore.pressureThreshold", 0.85)

    // Legacy aliases
    static let l1Target = pCoreTarget
    static let l1SoftLimit = pCoreSoftLimit
    static let l1HardLimit = pCoreHardLimit
    static let l2Max = eCoreRecallBudget
    static let l3UseRemaining = ConfigKey("context.eCore.useRemainingBudget", true)

    static let ecoreStorage = ConfigKey("context.fabric.ecoreStorageEnabled", true)
    static let observationProjection = ConfigKey("context.fabric.observationProjectionEnabled", true)
    static let heatTracking = ConfigKey("context.fabric.heatTrackingEnabled", true)

    /// Every exposed key with its fallback, for drift checks against the Core schema.
    static var all: [(id: String, fallback: Any)] {
        [
            (permissionPolicy.id, permissionPolicy.fallback),
            (executionProfile.id, executionProfile.fallback),
            (behaviorProfile.id, behaviorProfile.fallback),
            (codeIntelligence.id, codeIntelligence.fallback),
            (systemContext.id, systemContext.fallback),
            (maxConcurrentSubagents.id, maxConcurrentSubagents.fallback),
            (maxSubagentDepth.id, maxSubagentDepth.fallback),
            (maxTotalRuns.id, maxTotalRuns.fallback),
            (maxAgentLoopSteps.id, maxAgentLoopSteps.fallback),
            (l1ProjectMaxCharacters.id, l1ProjectMaxCharacters.fallback),
            (l2MaxCharacters.id, l2MaxCharacters.fallback),
            (quickFilesystemSeconds.id, quickFilesystemSeconds.fallback),
            (searchSeconds.id, searchSeconds.fallback),
            (foregroundShellSeconds.id, foregroundShellSeconds.fallback),
            (buildTestSeconds.id, buildTestSeconds.fallback),
            (mcpSeconds.id, mcpSeconds.fallback),
            (providerSeconds.id, providerSeconds.fallback),
            (providerIdleSeconds.id, providerIdleSeconds.fallback),
            (subagentSeconds.id, subagentSeconds.fallback),
            (agentRunSeconds.id, agentRunSeconds.fallback),
            (maximumSeconds.id, maximumSeconds.fallback),
            (addressableBudget.id, addressableBudget.fallback),
            (reserve.id, reserve.fallback),
            (economicThreshold.id, economicThreshold.fallback),
            (pCoreTarget.id, pCoreTarget.fallback),
            (pCoreSoftLimit.id, pCoreSoftLimit.fallback),
            (pCoreHardLimit.id, pCoreHardLimit.fallback),
            (eCoreStorageBudget.id, eCoreStorageBudget.fallback),
            (eCoreRecallBudget.id, eCoreRecallBudget.fallback),
            (eCorePressureThreshold.id, eCorePressureThreshold.fallback),
            (ecoreStorage.id, ecoreStorage.fallback),
            (observationProjection.id, observationProjection.fallback),
            (heatTracking.id, heatTracking.fallback),
        ]
    }
}

/// Read-modify-write access to `config.json` that never drops keys it does not
/// know about and refuses to overwrite a file it cannot parse.
final class CoreConfigFile {
    enum WriteError: LocalizedError {
        case unparseable(URL)

        var errorDescription: String? {
            switch self {
            case .unparseable(let url):
                return "\(url.lastPathComponent) 无法解析，为避免覆盖手写内容已停止写入。"
            }
        }
    }

    let url: URL
    private(set) var root: [String: Any] = [:]
    private(set) var isReadable = true

    init(url: URL = LingXiDataRoot.file("config.json")) {
        self.url = url
        reload()
    }

    func reload() {
        guard let data = try? Data(contentsOf: url) else {
            root = [:]
            isReadable = true   // missing file: every key falls back to the Core default
            return
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = object
            isReadable = true
        } else {
            root = [:]
            isReadable = false
        }
    }

    func value(at path: [String]) -> Any? {
        var node: Any? = root
        for component in path {
            node = (node as? [String: Any])?[component]
        }
        return node is NSNull ? nil : node
    }

    /// Writes `value` at `path`; `nil` removes the override so the Core default applies.
    func set(_ value: Any?, at path: [String]) throws {
        guard isReadable else { throw WriteError.unparseable(url) }
        root = Self.setting(value, at: path[...], in: root)
        if root["version"] == nil { root["version"] = 1 }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private static func setting(_ value: Any?, at path: ArraySlice<String>, in node: [String: Any]) -> [String: Any] {
        guard let head = path.first else { return node }
        var node = node
        if path.count == 1 {
            node[head] = value
        } else {
            let child = node[head] as? [String: Any] ?? [:]
            let updated = setting(value, at: path.dropFirst(), in: child)
            node[head] = updated.isEmpty ? nil : updated
        }
        return node
    }
}
