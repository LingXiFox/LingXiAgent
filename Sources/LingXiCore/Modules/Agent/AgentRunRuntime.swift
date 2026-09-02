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
    private let runtimes: [String: ModelRuntimeAssembly]
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

    public func resolve(_ requested: ModelSelection?, subagent: Bool = false) throws -> (selection: ModelSelection, assembly: ModelRuntimeAssembly) {
        let requested = requested ?? (subagent ? defaultSubagentSelection ?? defaultSelection : defaultSelection)
        let providerID = requested?.providerID ?? "default"
        guard (requested?.accountID == nil) == (requested?.profileID == nil) else { throw CoreError(code: .subagentModelNotAllowed, message: "ModelSelection 必须同时提供 accountID 与 profileID") }
        let key = requested?.accountID.flatMap { account in requested?.profileID.map { "\(account)::\($0)" } }
        guard let assembly = key.flatMap({ runtimes[$0] }) ?? (requested?.accountID == nil ? runtimes[providerID] : nil) else { throw CoreError(code: .subagentModelNotAllowed, message: "Subagent Provider 不可用: \(providerID)") }
        guard !assembly.modelID.rawValue.isEmpty else { throw CoreError(code: .provider, message: "未配置模型 Provider") }
        let selection = requested ?? ModelSelection(providerID: providerID, modelID: assembly.modelID.rawValue)
        guard selection.providerID == assembly.endpoint.providerID || selection.providerID == "default" else { throw CoreError(code: .subagentModelNotAllowed, message: "ModelSelection Provider 与 resolved endpoint 不一致") }
        guard selection.accountID == nil || selection.accountID == assembly.endpoint.accountID, selection.profileID == nil || selection.profileID == assembly.endpoint.profileID else { throw CoreError(code: .subagentModelNotAllowed, message: "ModelSelection account/profile 与 resolved endpoint 不一致") }
        guard selection.modelID == assembly.modelID.rawValue else { throw CoreError(code: .subagentModelNotAllowed, message: "Subagent Model 不可用: \(selection.modelID)") }
        guard allowedModels?.contains(selection.modelID) ?? true else { throw CoreError(code: .subagentModelNotAllowed, message: "Subagent Model 未获用户许可: \(selection.modelID)") }
        return (selection, assembly)
    }

    public func setDefaultSelection(_ selection: ModelSelection) throws {
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
