import CoreFoundation
import Foundation
import LingXiProtocol

public protocol ToolExecutor: Sendable {
    var definition: ToolDefinition { get }
    func resource(for arguments: String, profile: ExecutionProfile) throws -> String
    func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind>
    /// 外部目录审批必须引用 canonical path；Shell 的主要权限资源仍是命令文本。
    func externalResource(for arguments: String, profile: ExecutionProfile) throws -> String?
    func execute(arguments: String, profile: ExecutionProfile) async throws -> String
}

public extension ToolExecutor {
    func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind> { definition.capability.kinds }
    func externalResource(for arguments: String, profile: ExecutionProfile) throws -> String? { nil }
}

public protocol ToolProvider: Sendable {
    func register(into registry: inout ToolRegistry) throws
}

public struct ToolExecutionObserver: Sendable {
    public let permissionAsked: @Sendable (PermissionRequest) async -> Void
    public let permissionResolved: @Sendable (PermissionRequest, PermissionReply) async -> Void
    public let executionClaimed: @Sendable (ToolExecutionClaim) async -> Void
    public let questionAsked: @Sendable (QuestionRequest) async -> Void
    public let questionResolved: @Sendable (QuestionRequest, QuestionReply) async -> Void

    public init(permissionAsked: @escaping @Sendable (PermissionRequest) async -> Void, permissionResolved: @escaping @Sendable (PermissionRequest, PermissionReply) async -> Void, executionClaimed: @escaping @Sendable (ToolExecutionClaim) async -> Void, questionAsked: @escaping @Sendable (QuestionRequest) async -> Void, questionResolved: @escaping @Sendable (QuestionRequest, QuestionReply) async -> Void) {
        self.permissionAsked = permissionAsked
        self.permissionResolved = permissionResolved
        self.executionClaimed = executionClaimed
        self.questionAsked = questionAsked
        self.questionResolved = questionResolved
    }
}

package enum ToolExecutionContext {
    @TaskLocal static var observer: ToolExecutionObserver?
    @TaskLocal static var sessionID: SessionID?
    @TaskLocal static var toolCallID: ToolCallID?
    @TaskLocal static var lifecycleTrace: ToolLifecycleTrace?
}

public struct BuiltInToolProvider: ToolProvider {
    public let tools: [any ToolExecutor]
    public init(tools: [any ToolExecutor]) { self.tools = tools }
    public func register(into registry: inout ToolRegistry) throws {
        for tool in tools { try registry.register(tool) }
    }
}

public enum ToolRegistryError: Error, Sendable, Equatable {
    case duplicateName(String)
}

/// 静态注册表。本阶段无动态插件或运行时注册。
public struct ToolRegistry: Sendable {
    private var tools: [ToolID: any ToolExecutor]

    public init(_ tools: [any ToolExecutor]) {
        self.tools = [:]
        for tool in tools {
            precondition(self.tools[tool.definition.id] == nil, "duplicate Tool: \(tool.definition.name)")
            self.tools[tool.definition.id] = tool
        }
    }

    public init(validating tools: [any ToolExecutor]) throws {
        self.tools = [:]
        for tool in tools { try register(tool) }
    }

    public mutating func register(_ tool: any ToolExecutor) throws {
        guard tools[tool.definition.id] == nil else { throw ToolRegistryError.duplicateName(tool.definition.name) }
        tools[tool.definition.id] = tool
    }

    public var definitions: [ToolDefinition] {
        tools.values.map(\.definition).sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func tool(for id: ToolID) -> (any ToolExecutor)? {
        tools[id]
    }

    public func tool(named name: String) -> (any ToolExecutor)? {
        tools[ToolID(name)]
    }
}

/// 会话级动态工具租借管理器：负责按需发现、租借与会话隔离。
public actor DynamicToolLeaseManager {
    private var leasedToolsBySession: [SessionID: Set<ToolID>] = [:]
    private var leasedToolsByRun: [AgentRunID: Set<ToolID>] = [:]
    private var discoveredCandidatesBySession: [SessionID: Set<ToolID>] = [:]

    public init() {}

    public func lease(sessionID: SessionID, runID: AgentRunID?, toolID: ToolID) {
        if let runID { leasedToolsByRun[runID, default: []].insert(toolID) }
        else { leasedToolsBySession[sessionID, default: []].insert(toolID) }
    }

    public func unlease(sessionID: SessionID, toolID: ToolID) {
        leasedToolsBySession[sessionID]?.remove(toolID)
    }

    public func leasedTools(for sessionID: SessionID, runID: AgentRunID? = nil) -> Set<ToolID> {
        (leasedToolsBySession[sessionID] ?? []).union(runID.flatMap { leasedToolsByRun[$0] } ?? [])
    }

    public func recordCandidates(sessionID: SessionID, tools: Set<ToolID>) {
        discoveredCandidatesBySession[sessionID, default: []].formUnion(tools)
    }

    public func candidateTools(for sessionID: SessionID) -> Set<ToolID> {
        discoveredCandidatesBySession[sessionID] ?? []
    }

    public func resetSession(_ sessionID: SessionID) {
        leasedToolsBySession.removeValue(forKey: sessionID)
        discoveredCandidatesBySession.removeValue(forKey: sessionID)
    }

    public func resetRun(_ runID: AgentRunID) { leasedToolsByRun.removeValue(forKey: runID) }
}

/// Provider 无关的 Tool 执行入口：参数解析、路径预检、权限、执行和错误归一化。
public struct ToolRuntime: Sendable {
    public static let coreToolOrder: [ToolID] = [
        ToolID("shell"),
        ToolID("read_file"),
        ToolID("write_file"),
        ToolID("edit_file"),
        ToolID("apply_patch"),
        ToolID("list_directory"),
        ToolID("glob"),
        ToolID("grep"),
        ToolID("web_search"),
        ToolID("web_fetch"),
        ToolID("search_tools"),
        ToolID("load_tool")
    ]
    public static let coreToolIDs: Set<ToolID> = Set(coreToolOrder)

    private let registry: ToolRegistry
    private let permissions: PermissionEngine
    private let mutations: ToolMutationCoordinator
    private let outputPolicy: ToolOutputPolicy
    private let outputArchive: ToolOutputArchive?
    private let outputSink: (@Sendable (ToolOutputChunk) async -> Void)?
    private let mcpPager: MCPToolPager?
    private let subagents: SubagentToolService?
    private let cacheController: ContextCacheController?
    private let deadlinePolicy: ExecutionDeadlinePolicy
    private let dynamicLeases: DynamicToolLeaseManager

    public init(
        registry: ToolRegistry,
        permissions: PermissionEngine,
        mutations: ToolMutationCoordinator = ToolMutationCoordinator(),
        outputPolicy: ToolOutputPolicy = ToolOutputPolicy(),
        outputArchive: ToolOutputArchive? = nil,
        outputSink: (@Sendable (ToolOutputChunk) async -> Void)? = nil,
        mcpPager: MCPToolPager? = nil,
        subagents: SubagentToolService? = nil,
        cacheController: ContextCacheController? = nil,
        deadlinePolicy: ExecutionDeadlinePolicy = ExecutionDeadlinePolicy(),
        dynamicLeases: DynamicToolLeaseManager = DynamicToolLeaseManager()
    ) {
        self.registry = registry
        self.permissions = permissions
        self.mutations = mutations
        self.outputPolicy = outputPolicy
        self.outputArchive = outputArchive
        self.outputSink = outputSink
        self.mcpPager = mcpPager
        self.subagents = subagents
        self.cacheController = cacheController
        self.deadlinePolicy = deadlinePolicy
        self.dynamicLeases = dynamicLeases
    }

    public var definitions: [ToolDefinition] { registry.definitions }

    public func resetSession(_ sessionID: SessionID) async {
        await dynamicLeases.resetSession(sessionID)
        await mcpPager?.discardSession(sessionID)
    }

    public func resetRun(_ runID: AgentRunID) async { await dynamicLeases.resetRun(runID) }

    public func availableDefinitions(sessionID: SessionID? = nil, runID: AgentRunID? = nil, interactive: Bool = false, executionProfile: SubagentExecutionProfile? = nil) async -> [ToolDefinition] {
        let configuration = await permissions.currentConfiguration()
        let profile = Self.attenuatedProfile(requested: executionProfile?.permissionProfile.flatMap(ExecutionProfile.init(rawValue:)), parent: configuration.profile)
        let effectiveSessionID = sessionID ?? SessionID("ephemeral")
        let leasedIDs = await dynamicLeases.leasedTools(for: effectiveSessionID, runID: runID)

        var definitions = registry.definitions.filter { definition in
            if profile == .readOnly && !definition.capability.readOnly {
                return false
            }
            if let allowed = executionProfile?.toolProfile.map(Set.init) {
                return allowed.contains(definition.id.rawValue)
            }
            if definition.name == "question" {
                return interactive
            }
            if definition.id == ToolID("skill") {
                let values = definition.inputSchema.properties["name"]?.enumValues ?? []
                return !values.isEmpty
            }
            // Always-on core tools + dynamically leased tools
            return Self.coreToolIDs.contains(definition.id) || leasedIDs.contains(definition.id)
        }
        definitions += [MCPDiscoveryTools.search, MCPDiscoveryTools.load]
        if subagents != nil {
            let subagentDef = SubagentTool.definition
            if let allowed = executionProfile?.toolProfile.map(Set.init) {
                if allowed.contains(subagentDef.id.rawValue) { definitions.append(subagentDef) }
            } else if leasedIDs.contains(subagentDef.id) {
                definitions.append(subagentDef)
            }
        }
        if let sessionID, let mcpPager { definitions += await mcpPager.providerDefinitions(sessionID: sessionID) }
        if let cacheController {
            let contextSearchDef = ContextRetrieveTool(id: "context_search", cacheController: cacheController).definition
            if let allowed = executionProfile?.toolProfile.map(Set.init) {
                if allowed.contains(contextSearchDef.id.rawValue) { definitions.append(contextSearchDef) }
            } else if leasedIDs.contains(contextSearchDef.id) {
                definitions.append(contextSearchDef)
            }
        }
        if let allowed = executionProfile?.toolProfile.map(Set.init) {
            definitions = definitions.filter { allowed.contains($0.id.rawValue) }
        }
        if profile == .readOnly { definitions = definitions.filter(\.capability.readOnly) }
        if profile == .fullAccess {
            definitions = definitions.map { definition in
                ToolDefinition(
                    id: definition.id,
                    name: definition.name,
                    description: "\(definition.description) Full Access: absolute paths and ordinary paths outside the workspace are allowed; sensitive paths remain blocked.",
                    inputSchema: definition.inputSchema,
                    capability: definition.capability,
                    rawInputSchema: definition.rawInputSchema
                )
            }
        }
        return definitions.sorted { lhs, rhs in
            let left = Self.coreToolOrder.firstIndex(of: lhs.id)
            let right = Self.coreToolOrder.firstIndex(of: rhs.id)
            switch (left, right) {
            case let (l?, r?): return l == r ? lhs.id.rawValue < rhs.id.rawValue : l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.id.rawValue < rhs.id.rawValue
            }
        }
    }

    public struct ExecutionOutcome: Sendable {
        public let result: ToolResult
        public let permissionWait: Duration
        public let permissionAsked: Bool
        public let execution: Duration
        public let queueDuration: Duration
        public let executionDuration: Duration
        public let toolName: String
        public let resource: String?
        var lifecycleTrace: ToolLifecycleTrace?

        public init(result: ToolResult, permissionWait: Duration, permissionAsked: Bool, execution: Duration, queueDuration: Duration = .zero, toolName: String, resource: String?) {
            self.permissionWait = permissionWait
            self.permissionAsked = permissionAsked
            self.execution = execution
            self.queueDuration = queueDuration
            self.executionDuration = execution
            self.toolName = toolName
            self.resource = resource
            self.lifecycleTrace = nil
            let execMs = ToolRuntime.durationMilliseconds(execution)
            let queueMs = ToolRuntime.durationMilliseconds(queueDuration)
            let permMs = ToolRuntime.durationMilliseconds(permissionWait)
            self.result = result.withTiming(ToolTiming(
                milliseconds: execMs,
                queueMilliseconds: queueMs,
                executionMilliseconds: execMs,
                permissionMilliseconds: permMs
            ))
        }
    }

    private static func durationMilliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    public struct ReadOnlySignature: Sendable, Equatable, Hashable {
        public let toolName: String
        public let canonicalArguments: String
        public let resource: String
    }

    public func readOnlySignature(for call: ToolCall) throws -> ReadOnlySignature? {
        guard let tool = registry.tool(for: call.toolID), tool.definition.capability.readOnly else { return nil }
        return ReadOnlySignature(
            toolName: tool.definition.name,
            canonicalArguments: Self.canonicalArguments(call.arguments),
            resource: try tool.resource(for: call.arguments, profile: .workspace)
        )
    }

    public func execute(
        _ call: ToolCall,
        sessionID: SessionID,
        projectID: ProjectID = ProjectID("ephemeral"),
        executionProfile: SubagentExecutionProfile? = nil,
        onPermissionAsked: (@Sendable (PermissionRequest) async -> Void)? = nil
    ) async -> ToolResult {
        await executeWithMetrics(call, sessionID: sessionID, projectID: projectID, executionProfile: executionProfile, onPermissionAsked: onPermissionAsked ?? { _ in }).result
    }

    public func executeWithMetrics(
        _ call: ToolCall,
        sessionID: SessionID,
        projectID: ProjectID = ProjectID("ephemeral"),
        executionProfile: SubagentExecutionProfile? = nil,
        onPermissionAsked: @escaping @Sendable (PermissionRequest) async -> Void,
        observer: ToolExecutionObserver? = nil,
        parentDeadline: ExecutionDeadline? = nil
    ) async -> ExecutionOutcome {
        let deadline = deadlinePolicy.deadline(for: category(for: call), requested: executionProfile?.timeoutSeconds.map { .seconds($0) }, parent: parentDeadline)
        let lifecycle = ToolLifecycleTrace(toolCallID: call.callID)
        lifecycle.record(.requested)
        return await ToolExecutionContext.$lifecycleTrace.withValue(lifecycle) {
            await ToolExecutionContext.$toolCallID.withValue(call.callID) {
                do {
                    var outcome = try await executeWithMetricsUnbounded(call, sessionID: sessionID, projectID: projectID, executionProfile: executionProfile, onPermissionAsked: onPermissionAsked, observer: observer, deadline: deadline)
                    lifecycle.record(.toolResultBuilt, processPID: lifecycle.snapshot().last?.processPID, exitCode: outcome.result.exitCode.map { Int32($0) })
                    outcome.lifecycleTrace = lifecycle
                    return outcome
                } catch let error as CoreError {
                    let outcome: ToolOutcome = error.code == .idleTimedOut ? .idleTimedOut : error.code == .toolCancelled || error.code == .permissionCancelled ? .cancelled : .timedOut
                    let unknown = !isReadOnly(call)
                    var metadata = ["deadlineCategory": deadline.category.rawValue, "effectiveTimeoutSeconds": String(format: "%.3f", deadline.timeoutSeconds)]
                    if unknown { metadata["executionState"] = "unknown"; metadata["verificationRequired"] = "true" }
                    let code = unknown && outcome != .cancelled ? CoreError.Code.executionStateUnknown.rawValue : error.code.rawValue
                    var result = ExecutionOutcome(result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: code, message: error.message), toolName: call.toolName, outcome: outcome, metadata: metadata), permissionWait: .zero, permissionAsked: false, execution: deadline.timeout, toolName: call.toolName, resource: nil)
                    lifecycle.record(.toolResultBuilt, processPID: lifecycle.snapshot().last?.processPID, exitCode: result.result.exitCode.map { Int32($0) })
                    result.lifecycleTrace = lifecycle
                    return result
                } catch is CancellationError {
                    var result = ExecutionOutcome(result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: CoreError.Code.toolCancelled.rawValue, message: "Tool 执行已取消"), toolName: call.toolName, outcome: .cancelled), permissionWait: .zero, permissionAsked: false, execution: deadline.timeout, toolName: call.toolName, resource: nil)
                    lifecycle.record(.toolResultBuilt)
                    result.lifecycleTrace = lifecycle
                    return result
                } catch {
                    var result = ExecutionOutcome(result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: CoreError.Code.toolExecutionFailed.rawValue, message: "Tool 执行失败"), toolName: call.toolName), permissionWait: .zero, permissionAsked: false, execution: deadline.timeout, toolName: call.toolName, resource: nil)
                    lifecycle.record(.toolResultBuilt)
                    result.lifecycleTrace = lifecycle
                    return result
                }
            }
        }
    }

    private func executeWithMetricsUnbounded(
        _ call: ToolCall,
        sessionID: SessionID,
        projectID: ProjectID,
        executionProfile: SubagentExecutionProfile?,
        onPermissionAsked: @escaping @Sendable (PermissionRequest) async -> Void,
        observer: ToolExecutionObserver?,
        deadline: ExecutionDeadline
    ) async throws -> ExecutionOutcome {
        let clock = ContinuousClock()
        let lifecycleTrace = ToolExecutionContext.lifecycleTrace
        let admissionStart = clock.now
        var permissionWait: Duration = .zero
        var permissionAsked = false
        var execution: Duration = .zero
        var queueDuration: Duration = .zero
        var executionStartedAt: ContinuousClock.Instant?
        do {
            try Task.checkCancellation()
            if let allowed = executionProfile?.toolProfile, !allowed.contains(call.toolID.rawValue) {
                throw CoreError(code: .permissionDenied, message: "Execution Profile 不允许 \(call.toolID.rawValue)")
            }
            let baseConfiguration = await permissions.currentConfiguration()
            let effectiveProfile = Self.attenuatedProfile(requested: executionProfile?.permissionProfile.flatMap(ExecutionProfile.init(rawValue:)), parent: baseConfiguration.profile)
            if call.toolID == SubagentTool.definition.id, let subagents {
                try ToolSchemaValidator.validate(arguments: call.arguments, schema: SubagentTool.definition.inputSchema)
                let request = PermissionRequest(
                    permissionID: PermissionID(UUID().uuidString),
                    sessionID: sessionID,
                    toolCallID: call.callID,
                    toolID: call.toolID,
                    capabilities: SubagentTool.definition.capability.kinds,
                    resource: "child Agent session",
                    description: "允许创建或控制 Child Agent"
                )
                let permissionStart = clock.now
                lifecycleTrace?.record(.permissionStart)
                let resolution = await permissions.resolve(request) {
                    await observer?.permissionAsked(request)
                    await onPermissionAsked(request)
                }
                permissionWait = permissionStart.duration(to: clock.now)
                lifecycleTrace?.record(.permissionEnd)
                permissionAsked = resolution.asked
                try Task.checkCancellation()
                await observer?.permissionResolved(request, PermissionReply(permissionID: request.permissionID, decision: resolution.decision))
                guard resolution.decision == .allow else { throw CoreError(code: .permissionDenied, message: "已拒绝 subagent") }
                try Task.checkCancellation()
                lifecycleTrace?.record(.admitted)
                let executionStart = clock.now
                executionStartedAt = executionStart
                queueDuration = admissionStart.duration(to: executionStart)
                await observer?.executionClaimed(ToolExecutionClaim(mutatesProject: true))
                lifecycleTrace?.record(.executorStart)
                let content = try await ExecutionWatchdog.run(freshExecutionDeadline(from: deadline)) {
                    try await ToolExecutionContext.$observer.withValue(observer) {
                        try await subagents.execute(arguments: call.arguments, sessionID: sessionID, callID: call.callID)
                    }
                }
                execution = executionStart.duration(to: clock.now)
                return ExecutionOutcome(result: ToolResult(callID: call.callID, success: true, content: content, toolName: call.toolID.rawValue), permissionWait: permissionWait, permissionAsked: permissionAsked, execution: execution, toolName: call.toolID.rawValue, resource: request.resource)
            }
            if call.toolID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CoreError(code: .toolNotFound, message: "Tool call name 为空")
            }
            if call.toolID == MCPDiscoveryTools.search.id {
                struct SearchInput: Decodable {
                    let query: String?
                    let server: String?
                    let capability: String?
                    let maxResults: Int?
                }
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let input = (try? decoder.decode(SearchInput.self, from: Data(call.arguments.utf8)))
                    ?? SearchInput(query: call.arguments, server: nil, capability: nil, maxResults: nil)
                let query = (input.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)

                var candidateEntries: [[String: String]] = []
                var discoveredIDs: Set<ToolID> = []

                // 1. Search specialized builtin tools
                var specialized: [ToolDefinition] = registry.definitions.filter { !Self.coreToolIDs.contains($0.id) && $0.id != ToolID("question") && $0.id != ToolID("skill") }
                if subagents != nil { specialized.append(SubagentTool.definition) }
                if let cacheController { specialized.append(ContextRetrieveTool(id: "context_search", cacheController: cacheController).definition) }

                for def in specialized {
                    let text = "\(def.id.rawValue) \(def.name) \(def.description)".lowercased()
                    let matches = terms.isEmpty || terms.contains(where: { text.contains($0) })
                    if matches {
                        discoveredIDs.insert(def.id)
                        candidateEntries.append([
                            "tool_id": def.id.rawValue,
                            "display_name": "builtin.\(def.name)",
                            "short_description": def.description,
                            "category": "specialized",
                            "availability": "available"
                        ])
                    }
                }
                await dynamicLeases.recordCandidates(sessionID: sessionID, tools: discoveredIDs)

                // 2. Search MCP tools via mcpPager (if available)
                var mcpResultContent: String?
                if let mcpPager {
                    if let result = try? await ExecutionWatchdog.run(freshExecutionDeadline(from: deadline), operation: {
                        try await mcpPager.searchToolResult(sessionID: sessionID, projectID: projectID, arguments: call.arguments)
                    }) {
                        if result.trimmingCharacters(in: .whitespacesAndNewlines) != "[]" {
                            mcpResultContent = result
                            if let data = result.data(using: .utf8),
                               let mcpItems = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                                for item in mcpItems {
                                    if let toolID = item["tool_id"] as? String {
                                        discoveredIDs.insert(ToolID(toolID))
                                        candidateEntries.append([
                                            "tool_id": toolID,
                                            "display_name": (item["displayName"] as? String) ?? toolID,
                                            "short_description": (item["shortDescription"] as? String) ?? "",
                                            "availability": (item["availability"] as? String) ?? "available"
                                        ])
                                    }
                                }
                            }
                        }
                    }
                }
                await dynamicLeases.recordCandidates(sessionID: sessionID, tools: discoveredIDs)

                if let mcpResultContent, candidateEntries.count == discoveredIDs.count {
                    return ExecutionOutcome(result: ToolResult(callID: call.callID, success: true, content: mcpResultContent, toolName: call.toolID.rawValue), permissionWait: .zero, permissionAsked: false, execution: .zero, toolName: call.toolID.rawValue, resource: query)
                }

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let content = (try? String(decoding: encoder.encode(candidateEntries), as: UTF8.self)) ?? "[]"
                return ExecutionOutcome(result: ToolResult(callID: call.callID, success: true, content: content, toolName: call.toolID.rawValue), permissionWait: .zero, permissionAsked: false, execution: .zero, toolName: call.toolID.rawValue, resource: query)
            }
            if call.toolID == MCPDiscoveryTools.load.id {
                struct LoadInput: Decodable {
                    let toolId: String?
                }
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let input = try? decoder.decode(LoadInput.self, from: Data(call.arguments.utf8))
                guard let rawToolID = input?.toolId?.trimmingCharacters(in: .whitespacesAndNewlines), !rawToolID.isEmpty else {
                    throw CoreError(code: .toolArgumentInvalid, message: "load_tool 需要 tool_id")
                }
                let normalized = rawToolID.hasPrefix("builtin.") ? String(rawToolID.dropFirst("builtin.".count)) : rawToolID
                let targetID = ToolID(normalized)

                // Check if targetID is a specialized builtin tool
                let isSpecialized = registry.definitions.contains(where: { $0.id == targetID })
                    || (subagents != nil && (targetID == SubagentTool.definition.id || normalized == "spawn_subagent" || normalized == "subagent"))
                    || (cacheController != nil && (targetID == ToolID("context_search") || normalized == "context_retrieve"))

                if isSpecialized {
                    await dynamicLeases.lease(sessionID: sessionID, runID: call.agentRunID, toolID: targetID)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    let content = (try? String(decoding: encoder.encode([
                        "status": "leased",
                        "tool": targetID.rawValue,
                        "provider_name": targetID.rawValue,
                        "message": "Tool '\(targetID.rawValue)' is now leased and will be available in your subsequent steps for this session."
                    ]), as: UTF8.self)) ?? #"{"status":"leased"}"#
                    return ExecutionOutcome(result: ToolResult(callID: call.callID, success: true, content: content, toolName: call.toolID.rawValue), permissionWait: .zero, permissionAsked: false, execution: .zero, toolName: call.toolID.rawValue, resource: targetID.rawValue)
                }

                if let mcpPager {
                    let content = try await ExecutionWatchdog.run(freshExecutionDeadline(from: deadline)) {
                        try await mcpPager.loadToolResult(sessionID: sessionID, arguments: call.arguments, schemaTokenBudget: 16_000)
                    }
                    return ExecutionOutcome(result: ToolResult(callID: call.callID, success: true, content: content, toolName: call.toolID.rawValue), permissionWait: .zero, permissionAsked: false, execution: .zero, toolName: call.toolID.rawValue, resource: nil)
                }

                throw CoreError(code: .toolNotFound, message: "Tool '\(rawToolID)' 未找到或不可租借")
            }
            if (call.toolID.rawValue == "context_search" || call.toolID.rawValue == "context_retrieve"), let cacheController {
                var query = call.arguments
                if let data = call.arguments.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let q = json["query"] as? String {
                    query = q
                }
                let content = try await cacheController.handleSearch(sessionID: sessionID, query: query, activeTask: "", activeFiles: [], limit: 5)
                return ExecutionOutcome(result: ToolResult(callID: call.callID, success: true, content: content, toolName: call.toolID.rawValue), permissionWait: .zero, permissionAsked: false, execution: .zero, toolName: call.toolID.rawValue, resource: query)
            }
            if registry.tool(for: call.toolID) == nil, let mcpPager {
                if await mcpPager.canHandle(sessionID: sessionID, providerToolID: call.toolID) {
                    return await executeMCP(call, sessionID: sessionID, projectID: projectID, profile: effectiveProfile, pager: mcpPager, onPermissionAsked: onPermissionAsked, observer: observer, deadline: deadline)
                }
            }
            guard let tool = registry.tool(for: call.toolID) else {
                throw CoreError(code: .toolNotFound, message: "未注册 Tool: \(call.toolID.rawValue)")
            }
            try ToolSchemaValidator.validate(arguments: call.arguments, schema: tool.definition.inputSchema, additionalProperties: Self.codingProperties(for: tool.definition.id))
            let capabilities = try tool.capabilities(for: call.arguments, profile: effectiveProfile)
            guard effectiveProfile != .readOnly || ToolCapability(capabilities).readOnly else {
                throw CoreError(code: .permissionDenied, message: "readOnly Profile 不允许 \(call.toolID.rawValue)")
            }
            let resource = try tool.resource(for: call.arguments, profile: effectiveProfile)
            let request = PermissionRequest(
                permissionID: PermissionID(UUID().uuidString),
                sessionID: sessionID,
                toolCallID: call.callID,
                toolID: call.toolID,
                capabilities: capabilities,
                resource: resource,
                description: "允许 \(call.toolID.rawValue) 访问 \(resource)"
            )
            if capabilities.contains(.externalFilesystem) {
                let externalRequest = PermissionRequest(
                    permissionID: PermissionID(UUID().uuidString),
                    sessionID: sessionID,
                    toolCallID: call.callID,
                    toolID: call.toolID,
                    capabilities: [.externalFilesystem],
                    resource: try tool.externalResource(for: call.arguments, profile: effectiveProfile) ?? resource,
                    description: "允许 \(call.toolID.rawValue) 访问 Workspace 外目录"
                )
                lifecycleTrace?.record(.permissionStart)
                let externalResolution = await permissions.resolve(externalRequest, action: .externalDirectory) {
                    await observer?.permissionAsked(externalRequest)
                    await onPermissionAsked(externalRequest)
                }
                permissionAsked = permissionAsked || externalResolution.asked
                lifecycleTrace?.record(.permissionEnd)
                try Task.checkCancellation()
                await observer?.permissionResolved(externalRequest, PermissionReply(permissionID: externalRequest.permissionID, decision: externalResolution.decision))
                guard externalResolution.decision == .allow else {
                    throw CoreError(code: .permissionDenied, message: "已拒绝 Workspace 外目录: \(resource)")
                }
            }
            let permissionStart = clock.now
            lifecycleTrace?.record(.permissionStart)
            let resolution = await permissions.resolve(request, action: Self.permissionAction(for: tool.definition.id)) {
                await observer?.permissionAsked(request)
                await onPermissionAsked(request)
            }
            permissionWait = permissionStart.duration(to: clock.now)
            permissionAsked = resolution.asked
            lifecycleTrace?.record(.permissionEnd)
            try Task.checkCancellation()
            await observer?.permissionResolved(request, PermissionReply(permissionID: request.permissionID, decision: resolution.decision))
            guard resolution.decision == .allow else {
                throw CoreError(code: .permissionDenied, message: "已拒绝 \(call.toolID.rawValue): \(resource)")
            }
            try Task.checkCancellation()
            lifecycleTrace?.record(.admitted)
                let executionStart = clock.now
                executionStartedAt = executionStart
                queueDuration = admissionStart.duration(to: executionStart)
            let mutates = capabilities.contains(.projectWrite) || capabilities.contains(.repositoryWrite) || capabilities.contains(.destructive)
            await observer?.executionClaimed(ToolExecutionClaim(mutatesProject: mutates))
            lifecycleTrace?.record(.executorStart)
            let operation: @Sendable () async throws -> String = {
                try await ToolExecutionContext.$observer.withValue(observer) {
                    try await ToolExecutionContext.$sessionID.withValue(sessionID) {
                        try await tool.execute(arguments: call.arguments, profile: effectiveProfile)
                    }
                }
            }
            let rawContent: String
            if call.toolID == ToolID("question") {
                rawContent = try await operation()
            } else {
                rawContent = try await ExecutionWatchdog.run(freshExecutionDeadline(from: deadline)) {
                    if mutates { return try await self.mutations.execute(operation) }
                    return try await operation()
                }
            }
            if !rawContent.isEmpty {
                await outputSink?(ToolOutputChunk(toolCallID: call.callID, stream: .stdout, sequence: 0, payload: rawContent))
            }
            let bounded = outputPolicy.excerpt(rawContent)
            let metadata = try await outputArchive?.archive(rawContent, metadata: bounded.metadata) ?? bounded.metadata
            execution = executionStart.duration(to: clock.now)
            let coding = Self.codingDetails(toolID: tool.definition.id, content: rawContent)
            return ExecutionOutcome(
                result: ToolResult(callID: call.callID, success: true, content: bounded.content, toolName: tool.definition.name, summary: coding.summary, metadata: coding.metadata, output: metadata, exitCode: coding.exitCode, diagnostics: coding.diagnostics, changedFiles: coding.changedFiles, continuation: metadata.outputBlobRef),
                permissionWait: permissionWait,
                permissionAsked: permissionAsked,
                execution: execution,
                queueDuration: queueDuration,
                toolName: tool.definition.name,
                resource: resource
            )
        } catch let error as CoreError {
            if let command = Self.commandResult(from: error.message) {
                if let executionStartedAt { execution = executionStartedAt.duration(to: clock.now) }
                let rawContent = command.stdout + (command.stdout.isEmpty || command.stderr.isEmpty ? "" : "\n") + command.stderr
                let bounded = outputPolicy.excerpt(rawContent)
                let metadata = (try? await outputArchive?.archive(rawContent, metadata: bounded.metadata)) ?? bounded.metadata
                let timedOut = error.code == .commandTimedOut
                return ExecutionOutcome(
                    result: ToolResult(callID: call.callID, success: false, content: bounded.content, error: ToolError(code: timedOut ? CoreError.Code.executionStateUnknown.rawValue : error.code.rawValue, message: timedOut ? "命令超时；执行状态需要验证" : "命令以状态 \(command.exitCode) 退出"), toolName: call.toolName, outcome: timedOut ? .timedOut : .failure, summary: "command failed", metadata: timedOut ? ["executionState": "unknown", "verificationRequired": "true"] : [:], output: metadata, exitCode: Int(command.exitCode), diagnostics: ToolDiagnostics(stdout: command.stdout, stderr: command.stderr), continuation: metadata.outputBlobRef),
                    permissionWait: permissionWait,
                    permissionAsked: permissionAsked,
                    execution: execution,
                    queueDuration: queueDuration,
                    toolName: call.toolName,
                    resource: nil
                )
            }
            let timedOut = error.code == .commandTimedOut || error.code == .idleTimedOut
            if let executionStartedAt { execution = executionStartedAt.duration(to: clock.now) }
            var metadata: [String: String] = [:]
            if timedOut {
                metadata["deadlineCategory"] = deadline.category.rawValue
                metadata["effectiveTimeoutSeconds"] = String(format: "%.3f", deadline.timeoutSeconds)
            }
            if timedOut && !isReadOnly(call) {
                metadata["executionState"] = "unknown"
                metadata["verificationRequired"] = "true"
            }
            return ExecutionOutcome(
                result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: timedOut && !isReadOnly(call) ? CoreError.Code.executionStateUnknown.rawValue : error.code.rawValue, message: error.message), toolName: call.toolName, outcome: error.code == .permissionDenied ? .denied : timedOut ? .timedOut : .failure, metadata: metadata),
                permissionWait: permissionWait,
                permissionAsked: permissionAsked,
                execution: execution,
                queueDuration: queueDuration,
                toolName: call.toolName,
                resource: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let executionStartedAt { execution = executionStartedAt.duration(to: clock.now) }
            return ExecutionOutcome(
                result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: CoreError.Code.toolExecutionFailed.rawValue, message: String(describing: error)), toolName: call.toolName),
                permissionWait: permissionWait,
                permissionAsked: permissionAsked,
                execution: execution,
                queueDuration: queueDuration,
                toolName: call.toolName,
                resource: nil
            )
        }
    }

    private func category(for call: ToolCall) -> ExecutionTimeoutCategory {
        switch call.toolID.rawValue {
        case "read_file", "list_directory", "skill": return .quickFilesystem
        case "glob", "grep", "symbol_lookup", "find_references", "dependency_query", "code_intelligence": return .search
        case "shell", "git", "process": return .foregroundShell
        default: return .foregroundShell
        }
    }

    private func isReadOnly(_ call: ToolCall) -> Bool {
        if call.toolID == MCPDiscoveryTools.search.id || call.toolID == MCPDiscoveryTools.load.id { return true }
        return registry.tool(for: call.toolID)?.definition.capability.readOnly ?? false
    }

    private func freshExecutionDeadline(from deadline: ExecutionDeadline) -> ExecutionDeadline {
        ExecutionDeadline(category: deadline.category, timeout: deadline.timeout, idleTimeout: deadline.idleTimeout)
    }

    public func finishMCPProviderStep(sessionID: SessionID) async { await mcpPager?.finishProviderStep(sessionID: sessionID) }
    public func abortMCPTurn(sessionID: SessionID) async { await mcpPager?.abortTurn(sessionID: sessionID) }

    private func executeMCP(_ call: ToolCall, sessionID: SessionID, projectID: ProjectID, profile: ExecutionProfile, pager: MCPToolPager, onPermissionAsked: @escaping @Sendable (PermissionRequest) async -> Void, observer: ToolExecutionObserver?, deadline: ExecutionDeadline) async -> ExecutionOutcome {
        let clock = ContinuousClock()
        let lifecycleTrace = ToolExecutionContext.lifecycleTrace
        do {
            let lease = try await pager.resolve(sessionID: sessionID, providerToolID: call.toolID)
            let request = PermissionRequest(permissionID: PermissionID(UUID().uuidString), sessionID: sessionID, toolCallID: call.callID, toolID: lease.toolID, capabilities: [.externalService, .networkAccess, .destructive], resource: lease.toolID.rawValue, description: "允许外部 MCP Tool \(lease.toolID.rawValue)")
            guard profile != .readOnly || ToolCapability(request.capabilities).readOnly else { throw CoreError(code: .permissionDenied, message: "readOnly Profile 不允许 MCP Tool") }
            let permissionStarted = clock.now
            lifecycleTrace?.record(.permissionStart)
            let resolution = await permissions.resolve(request) {
                await observer?.permissionAsked(request)
                await onPermissionAsked(request)
            }
            let permissionWait = permissionStarted.duration(to: clock.now)
            lifecycleTrace?.record(.permissionEnd)
            try Task.checkCancellation()
            await observer?.permissionResolved(request, PermissionReply(permissionID: request.permissionID, decision: resolution.decision))
            guard resolution.decision == .allow else { throw CoreError(code: .permissionDenied, message: "已拒绝 \(lease.toolID.rawValue)") }
            let executionStarted = clock.now
            lifecycleTrace?.record(.admitted)
            await observer?.executionClaimed(ToolExecutionClaim(mutatesProject: true))
            lifecycleTrace?.record(.executorStart)
            let response = try await ExecutionWatchdog.run(freshExecutionDeadline(from: deadline)) {
                try await pager.execute(sessionID: sessionID, projectID: projectID, providerToolID: call.toolID, arguments: call.arguments)
            }
            if !response.content.isEmpty { await outputSink?(ToolOutputChunk(toolCallID: call.callID, stream: .stdout, sequence: 0, payload: response.content)) }
            let bounded = outputPolicy.excerpt(response.content)
            let metadata = try await outputArchive?.archive(response.content, metadata: bounded.metadata) ?? bounded.metadata
            return ExecutionOutcome(result: ToolResult(callID: call.callID, success: true, content: bounded.content, toolName: response.lease.toolID.rawValue, metadata: ["mcpToolID": response.lease.toolID.rawValue, "schemaHash": response.lease.schemaHash], output: metadata), permissionWait: permissionWait, permissionAsked: resolution.asked, execution: executionStarted.duration(to: clock.now), toolName: response.lease.toolID.rawValue, resource: response.lease.toolID.rawValue)
        } catch let error as MCPToolPagerError {
            let code: CoreError.Code = switch error { case .leaseMissing, .leaseExpired: .mcpToolLeaseMissing; case .schemaChanged: .mcpToolSchemaChanged; case .schemaTooLarge: .mcpToolSchemaTooLarge; case .schemaBudgetExceeded: .mcpToolSchemaBudgetExceeded; default: .mcpServerUnavailable }
            let explanation = "Tool '\(call.toolID.rawValue)' unavailable: \(error)"
            return ExecutionOutcome(result: ToolResult(callID: call.callID, success: false, content: explanation, error: ToolError(code: code.rawValue, message: String(describing: error)), toolName: call.toolID.rawValue, outcome: .failure, summary: "Tool failed: \(code.rawValue)"), permissionWait: .zero, permissionAsked: false, execution: .zero, toolName: call.toolID.rawValue, resource: nil)
        } catch let error as CoreError {
            let timedOut = error.code == .commandTimedOut || error.code == .idleTimedOut
            return ExecutionOutcome(result: ToolResult(callID: call.callID, success: false, content: error.message, error: ToolError(code: error.code.rawValue, message: error.message), toolName: call.toolID.rawValue, outcome: error.code == .idleTimedOut ? .idleTimedOut : timedOut ? .timedOut : .failure, summary: "Tool failed: \(error.code.rawValue)"), permissionWait: .zero, permissionAsked: false, execution: .zero, toolName: call.toolID.rawValue, resource: nil)
        } catch {
            return ExecutionOutcome(result: ToolResult(callID: call.callID, success: false, content: String(describing: error), error: ToolError(code: CoreError.Code.toolExecutionFailed.rawValue, message: String(describing: error)), toolName: call.toolID.rawValue, outcome: .failure, summary: "Tool failed"), permissionWait: .zero, permissionAsked: false, execution: .zero, toolName: call.toolID.rawValue, resource: nil)
        }
    }

    private static func canonicalArguments(_ arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return arguments }
        return String(decoding: normalized, as: UTF8.self)
    }

    private static func attenuatedProfile(requested: ExecutionProfile?, parent: ExecutionProfile) -> ExecutionProfile {
        let rank: [ExecutionProfile: Int] = [.readOnly: 0, .workspace: 1, .fullAccess: 2]
        guard let requested, rank[requested, default: 0] < rank[parent, default: 0] else { return parent }
        return requested
    }

    private static func permissionAction(for toolID: ToolID) -> PermissionAction? {
        switch toolID.rawValue {
        case "read_file", "list_directory": return .read
        case "edit_file", "write_file", "apply_patch": return .edit
        case "shell", "process", "git": return .shell
        default: return nil
        }
    }

    private static func commandResult(from message: String) -> CommandResult? {
        guard let data = message.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CommandResult.self, from: data)
    }

    private static func codingDetails(toolID: ToolID, content: String) -> (summary: String, metadata: [String: String], exitCode: Int?, diagnostics: ToolDiagnostics?, changedFiles: [String]) {
        guard let data = content.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return ("", [:], nil, nil, []) }
        if ["apply_patch", "edit_file"].contains(toolID.rawValue), let operations = json as? [[String: Any]] {
            return ("applied \(operations.count) file operation(s)", [:], nil, nil, operations.compactMap { $0["path"] as? String }.sorted())
        }
        guard let object = json as? [String: Any] else { return ("", [:], nil, nil, []) }
        let changedFiles = object["changed_files"] as? [String] ?? []
        let summary = object["summary"] as? String ?? ""
        let exitCode = (object["exit_code"] as? NSNumber)?.intValue ?? (object["exitCode"] as? NSNumber)?.intValue
        let stdout = object["stdout"] as? String
        let stderr = object["stderr"] as? String
        let diagnostics = stdout.map { ToolDiagnostics(command: object["command"] as? String, stdout: $0, stderr: stderr ?? "") }
        return (summary, [:], exitCode, diagnostics, changedFiles)
    }

    private static func codingProperties(for toolID: ToolID) -> [String: ToolInputProperty] {
        switch toolID.rawValue {
        case "read_file": return ["start_line": ToolInputProperty(type: .integer, description: "", minimum: 1), "end_line": ToolInputProperty(type: .integer, description: "", minimum: 1), "max_lines": ToolInputProperty(type: .integer, description: "", minimum: 1, maximum: 2_000), "line_numbers": ToolInputProperty(type: .boolean, description: "")]
        case "glob": return ["include_hidden": ToolInputProperty(type: .boolean, description: ""), "include_ignored": ToolInputProperty(type: .boolean, description: ""), "include_generated": ToolInputProperty(type: .boolean, description: "")]
        case "grep": return ["glob": ToolInputProperty(type: .string, description: ""), "include_hidden": ToolInputProperty(type: .boolean, description: ""), "include_ignored": ToolInputProperty(type: .boolean, description: ""), "include_generated": ToolInputProperty(type: .boolean, description: "")]
        default: return [:]
        }
    }
}

/// JSON object is decoded once at the runtime boundary before permission or side effects.
enum ToolSchemaValidator {
    static func validate(arguments: String, schema: ToolInputSchema, additionalProperties: [String: ToolInputProperty] = [:]) throws {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let values = object as? [String: Any]
        else { throw CoreError(code: .toolArgumentInvalid, message: "Tool 参数必须是 JSON object") }
        var allowedProperties = schema.properties
        allowedProperties.merge(additionalProperties) { _, replacement in replacement }
        if schema.properties["action"] != nil && schema.properties["task"] != nil {
            allowedProperties["permission_profile"] = ToolInputProperty(type: .string, description: "Optional permission profile")
            allowedProperties["budget_profile"] = ToolInputProperty(type: .string, description: "Optional budget profile")
            allowedProperties["context_profile"] = ToolInputProperty(type: .string, description: "Optional context profile")
            allowedProperties["max_steps"] = ToolInputProperty(type: .integer, description: "Optional maximum steps", minimum: 1)
            allowedProperties["timeout_seconds"] = ToolInputProperty(type: .integer, description: "Optional timeout in seconds", minimum: 1)
        }
        guard Set(values.keys).isSubset(of: Set(allowedProperties.keys)) else {
            throw CoreError(code: .toolArgumentInvalid, message: "Tool 参数包含未知字段")
        }
        for name in schema.required where values[name] == nil {
            throw CoreError(code: .toolArgumentInvalid, message: "Tool 参数缺少必填字段: \(name)")
        }
        for (name, value) in values {
            guard let property = allowedProperties[name], matches(value, property.type) else {
                throw CoreError(code: .toolArgumentInvalid, message: "Tool 参数类型无效: \(name)")
            }
            if let values = property.enumValues, let value = value as? String, !values.contains(value) {
                throw CoreError(code: .toolArgumentInvalid, message: "Tool 参数枚举无效: \(name)")
            }
            if let number = value as? NSNumber, property.type == .integer || property.type == .number {
                if let minimum = property.minimum, number.doubleValue < minimum { throw CoreError(code: .toolArgumentInvalid, message: "Tool 参数小于最小值: \(name)") }
                if let maximum = property.maximum, number.doubleValue > maximum { throw CoreError(code: .toolArgumentInvalid, message: "Tool 参数大于最大值: \(name)") }
            }
        }
    }

    private static func matches(_ value: Any, _ type: ToolInputType) -> Bool {
        switch type {
        case .string: return value is String
        case .boolean: return value is Bool
        case .integer:
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) != CFBooleanGetTypeID() && floor(number.doubleValue) == number.doubleValue
        case .number:
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) != CFBooleanGetTypeID()
        case .object: return value is [String: Any]
        case .array: return value is [Any]
        }
    }
}
