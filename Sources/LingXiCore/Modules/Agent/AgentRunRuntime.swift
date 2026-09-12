import Foundation
import LingXiProtocol

public struct SubagentRuntimeLimits: Sendable, Equatable {
    public let maxConcurrentSubagents: Int
    public let maxSubagentDepth: Int
    public let maxTotalRunsPerRootRun: Int

    public init(maxConcurrentSubagents: Int = 4, maxSubagentDepth: Int = 3, maxTotalRunsPerRootRun: Int = 32) {
        self.maxConcurrentSubagents = max(1, maxConcurrentSubagents)
        self.maxSubagentDepth = max(1, maxSubagentDepth)
        self.maxTotalRunsPerRootRun = max(1, maxTotalRunsPerRootRun)
    }
}

public actor SubagentModelResolver {
    private var runtimes: [String: ModelRuntimeAssembly]
    private let allowedModels: Set<String>?
    private var defaultSelection: ModelSelection?
    private let defaultSubagentSelection: ModelSelection?

    public init(defaultRuntime: ModelRuntimeAssembly, runtimes: [String: ModelRuntimeAssembly] = [:], allowedModels: Set<String>? = nil, defaultSelection: ModelSelection? = nil, defaultSubagentSelection: ModelSelection? = nil) {
        var values = runtimes
        values["default"] = values["default"] ?? defaultRuntime
        values[defaultRuntime.endpoint.providerID] = values[defaultRuntime.endpoint.providerID] ?? defaultRuntime
        self.runtimes = values
        self.allowedModels = allowedModels
        self.defaultSelection = defaultSelection
        self.defaultSubagentSelection = defaultSubagentSelection
    }

    public func registerAssembly(_ assembly: ModelRuntimeAssembly, for selection: ModelSelection) {
        let providerID = selection.providerID
        runtimes[providerID] = assembly
        runtimes["default"] = assembly
        if let accountID = selection.accountID, let profileID = selection.profileID {
            runtimes["\(accountID)::\(profileID)"] = assembly
        }
    }

    public func resolve(_ requested: ModelSelection?, subagent: Bool = false) throws -> (selection: ModelSelection, assembly: ModelRuntimeAssembly) {
        let requested = requested ?? (subagent ? defaultSubagentSelection ?? defaultSelection : defaultSelection)
        let providerID = requested?.providerID ?? "default"
        guard (requested?.accountID == nil) == (requested?.profileID == nil) else { throw CoreError(code: .subagentModelNotAllowed, message: "ModelSelection 必须同时提供 accountID 与 profileID") }
        let key = requested?.accountID.flatMap { account in requested?.profileID.map { "\(account)::\($0)" } }
        var assembly = key.flatMap({ runtimes[$0] }) ?? (requested?.accountID == nil ? runtimes[providerID] : nil)
        if assembly == nil {
            assembly = runtimes[providerID] ?? runtimes["default"]
        }
        guard let resolvedAssembly = assembly else { throw CoreError(code: .subagentModelNotAllowed, message: "Subagent Provider 不可用: \(providerID)") }
        guard !resolvedAssembly.modelID.rawValue.isEmpty else { throw CoreError(code: .provider, message: "未配置模型 Provider") }

        let selection = requested ?? ModelSelection(providerID: providerID, modelID: resolvedAssembly.modelID.rawValue)
        guard allowedModels?.contains(selection.modelID) ?? true else { throw CoreError(code: .subagentModelNotAllowed, message: "Subagent Model 未获用户许可: \(selection.modelID)") }

        // 若 modelID 属于该 provider 且与初始 assembly 声明的缺省 modelID 不同，动态派生出对应 modelID 的 assembly
        let effectiveAssembly: ModelRuntimeAssembly
        if selection.modelID != resolvedAssembly.modelID.rawValue {
            effectiveAssembly = ModelRuntimeAssembly(
                provider: resolvedAssembly.provider,
                modelID: ModelID(selection.modelID),
                contextProfile: resolvedAssembly.contextProfile,
                endpoint: ResolvedModelEndpoint(
                    providerID: resolvedAssembly.endpoint.providerID,
                    productID: resolvedAssembly.endpoint.productID,
                    endpointID: resolvedAssembly.endpoint.endpointID,
                    accountID: resolvedAssembly.endpoint.accountID,
                    profileID: selection.profileID ?? resolvedAssembly.endpoint.profileID,
                    modelID: ModelID(selection.modelID),
                    baseURL: resolvedAssembly.endpoint.baseURL,
                    wireProtocol: resolvedAssembly.endpoint.wireProtocol,
                    contextProfile: resolvedAssembly.endpoint.contextProfile,
                    capabilities: resolvedAssembly.endpoint.capabilities,
                    rateLimits: resolvedAssembly.endpoint.rateLimits
                )
            )
        } else {
            effectiveAssembly = resolvedAssembly
        }

        return (selection, effectiveAssembly)
    }

    public func setDefaultSelection(_ selection: ModelSelection, assembly: ModelRuntimeAssembly? = nil) throws {
        if let assembly {
            registerAssembly(assembly, for: selection)
        }
        _ = try resolve(selection)
        defaultSelection = selection
    }

    public func currentDefaultSelection() -> ModelSelection? { defaultSelection }
}

/// One scheduler owns queuing, limits, and cancellation for every descendant run.
public actor AgentRunScheduler {
    private let limits: SubagentRuntimeLimits
    private var active: [AgentRunID: Task<Void, Never>] = [:]
    private var queued: [(AgentRunID, @Sendable () async -> Void)] = []

    public init(limits: SubagentRuntimeLimits = SubagentRuntimeLimits()) { self.limits = limits }

    public func submit(runID: AgentRunID, operation: @escaping @Sendable () async -> Void) -> AgentRunStatus {
        if active.count < limits.maxConcurrentSubagents {
            start(runID, operation)
            return .starting
        }
        queued.append((runID, operation))
        return .queued
    }

    public func cancel(_ runID: AgentRunID) {
        if let index = queued.firstIndex(where: { $0.0 == runID }) {
            queued.remove(at: index)
            return
        }
        active.removeValue(forKey: runID)?.cancel()
    }

    public func cancelAll(_ runIDs: [AgentRunID]) {
        for runID in runIDs { cancel(runID) }
    }

    public func complete(_ runID: AgentRunID) {
        active.removeValue(forKey: runID)
        guard active.count < limits.maxConcurrentSubagents, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        start(next.0, next.1)
    }

    public func snapshot() -> (active: [AgentRunID], queued: [AgentRunID]) {
        (Array(active.keys), queued.map(\.0))
    }

    private func start(_ runID: AgentRunID, _ operation: @escaping @Sendable () async -> Void) {
        active[runID] = Task { await operation() }
    }
}

enum AgentExecutionContext {
    @TaskLocal static var current: (sessionID: SessionID, runID: AgentRunID, rootSessionID: SessionID, parentSessionID: SessionID?)?
}
