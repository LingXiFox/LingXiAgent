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

enum ToolExecutionContext {
    @TaskLocal static var observer: ToolExecutionObserver?
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

/// Provider 无关的 Tool 执行入口：参数解析、路径预检、权限、执行和错误归一化。
public struct ToolRuntime: Sendable {
    private let registry: ToolRegistry
    private let permissions: PermissionEngine
    private let mutations: ToolMutationCoordinator
    private let outputPolicy: ToolOutputPolicy
    private let outputArchive: ToolOutputArchive?
    private let outputSink: (@Sendable (ToolOutputChunk) async -> Void)?
    private let mcpPager: MCPToolPager?
    private let subagents: SubagentToolService?
    private let deadlinePolicy: ExecutionDeadlinePolicy

    public init(registry: ToolRegistry, permissions: PermissionEngine, mutations: ToolMutationCoordinator = ToolMutationCoordinator(), outputPolicy: ToolOutputPolicy = ToolOutputPolicy(), outputArchive: ToolOutputArchive? = nil, outputSink: (@Sendable (ToolOutputChunk) async -> Void)? = nil, mcpPager: MCPToolPager? = nil, subagents: SubagentToolService? = nil, deadlinePolicy: ExecutionDeadlinePolicy = ExecutionDeadlinePolicy()) {
        self.registry = registry
        self.permissions = permissions
        self.mutations = mutations
        self.outputPolicy = outputPolicy
        self.outputArchive = outputArchive
        self.outputSink = outputSink
        self.mcpPager = mcpPager
        self.subagents = subagents
        self.deadlinePolicy = deadlinePolicy
    }

    public var definitions: [ToolDefinition] { registry.definitions }

    public func availableDefinitions(sessionID: SessionID? = nil, interactive: Bool = false, executionProfile: SubagentExecutionProfile? = nil) async -> [ToolDefinition] {
        let configuration = await permissions.currentConfiguration()
        let profile = Self.attenuatedProfile(requested: executionProfile?.permissionProfile.flatMap(ExecutionProfile.init(rawValue:)), parent: configuration.profile)
        var definitions = registry.definitions.filter { definition in
            if definition.name == "question" && !interactive { return false }
            if definition.id == ToolID("skill"), let values = definition.inputSchema.properties["name"]?.enumValues, values.isEmpty { return false }
            if profile == .readOnly {
                return definition.capability.readOnly
            }
            return true
        }
        definitions += [MCPDiscoveryTools.search, MCPDiscoveryTools.load]
        if subagents != nil { definitions.append(SubagentTool.definition) }
        if let sessionID, let mcpPager { definitions += await mcpPager.providerDefinitions(sessionID: sessionID) }
        if let allowed = executionProfile?.toolProfile.map(Set.init) {
            definitions = definitions.filter { allowed.contains($0.id.rawValue) }
        }
        if profile == .readOnly { definitions = definitions.filter(\.capability.readOnly) }
        return definitions.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public struct ExecutionOutcome: Sendable {
        public let result: ToolResult
        public let permissionWait: Duration
        public let permissionAsked: Bool
        public let execution: Duration
        public let toolName: String
        public let resource: String?
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
        onPermissionAsked: @escaping @Sendable (PermissionRequest) async -> Void
    ) async -> ToolResult {
        await executeWithMetrics(call, sessionID: sessionID, projectID: projectID, executionProfile: executionProfile, onPermissionAsked: onPermissionAsked).result
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
        do {
            let outcome = try await ExecutionWatchdog.run(deadline) {
                try await self.executeWithMetricsUnbounded(call, sessionID: sessionID, projectID: projectID, executionProfile: executionProfile, onPermissionAsked: onPermissionAsked, observer: observer)
            }
            return outcome
        } catch let error as CoreError {
            let outcome: ToolOutcome = error.code == .idleTimedOut ? .idleTimedOut : error.code == .toolCancelled || error.code == .permissionCancelled ? .cancelled : .timedOut
            let unknown = !isReadOnly(call)
            var metadata = ["deadlineCategory": deadline.category.rawValue, "effectiveTimeoutSeconds": String(format: "%.3f", deadline.timeoutSeconds)]
            if unknown { metadata["executionState"] = "unknown"; metadata["verificationRequired"] = "true" }
            let code = unknown && outcome != .cancelled ? CoreError.Code.executionStateUnknown.rawValue : error.code.rawValue
            return ExecutionOutcome(result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: code, message: error.message), toolName: call.toolName, outcome: outcome, metadata: metadata), permissionWait: .zero, permissionAsked: false, execution: deadline.timeout, toolName: call.toolName, resource: nil)
        } catch is CancellationError {
            return ExecutionOutcome(result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: CoreError.Code.toolCancelled.rawValue, message: "Tool 执行已取消"), toolName: call.toolName, outcome: .cancelled), permissionWait: .zero, permissionAsked: false, execution: deadline.timeout, toolName: call.toolName, resource: nil)
        } catch {
            return ExecutionOutcome(result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: CoreError.Code.toolExecutionFailed.rawValue, message: "Tool 执行失败"), toolName: call.toolName), permissionWait: .zero, permissionAsked: false, execution: deadline.timeout, toolName: call.toolName, resource: nil)
        }
    }

    private func executeWithMetricsUnbounded(
        _ call: ToolCall,
        sessionID: SessionID,
        projectID: ProjectID,
        executionProfile: SubagentExecutionProfile?,
        onPermissionAsked: @escaping @Sendable (PermissionRequest) async -> Void,
        observer: ToolExecutionObserver?
    ) async throws -> ExecutionOutcome {
        let clock = ContinuousClock()
        var permissionWait: Duration = .zero
        var permissionAsked = false
        var execution: Duration = .zero
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
                let resolution = await permissions.resolve(request) {
                    await observer?.permissionAsked(request)
                    await onPermissionAsked(request)
                }
                permissionWait = permissionStart.duration(to: clock.now)
                permissionAsked = resolution.asked
                try Task.checkCancellation()
                await observer?.permissionResolved(request, PermissionReply(permissionID: request.permissionID, decision: resolution.decision))
                guard resolution.decision == .allow else { throw CoreError(code: .permissionDenied, message: "已拒绝 subagent") }
                try Task.checkCancellation()
                let executionStart = clock.now
                await observer?.executionClaimed(ToolExecutionClaim(mutatesProject: true))
                let content = try await ToolExecutionContext.$observer.withValue(observer) {
                    try await subagents.execute(arguments: call.arguments, sessionID: sessionID, callID: call.callID)
                }
                execution = executionStart.duration(to: clock.now)
                return ExecutionOutcome(result: ToolResult(callID: call.callID, success: true, content: content, toolName: call.toolID.rawValue), permissionWait: permissionWait, permissionAsked: permissionAsked, execution: execution, toolName: call.toolID.rawValue, resource: request.resource)
            }
            if call.toolID == MCPDiscoveryTools.search.id, let mcpPager {
                let content = try await mcpPager.searchToolResult(sessionID: sessionID, projectID: projectID, arguments: call.arguments)
                return ExecutionOutcome(result: ToolResult(callID: call.callID, success: true, content: content, toolName: call.toolID.rawValue), permissionWait: .zero, permissionAsked: false, execution: .zero, toolName: call.toolID.rawValue, resource: nil)
            }
            if call.toolID == MCPDiscoveryTools.load.id, let mcpPager {
                let content = try await mcpPager.loadToolResult(sessionID: sessionID, arguments: call.arguments, schemaTokenBudget: 16_000)
                return ExecutionOutcome(result: ToolResult(callID: call.callID, success: true, content: content, toolName: call.toolID.rawValue), permissionWait: .zero, permissionAsked: false, execution: .zero, toolName: call.toolID.rawValue, resource: nil)
            }
            if registry.tool(for: call.toolID) == nil, let mcpPager {
                return await executeMCP(call, sessionID: sessionID, projectID: projectID, profile: effectiveProfile, pager: mcpPager, onPermissionAsked: onPermissionAsked, observer: observer)
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
                let externalResolution = await permissions.resolve(externalRequest, action: .externalDirectory) {
                    await observer?.permissionAsked(externalRequest)
                    await onPermissionAsked(externalRequest)
                }
                permissionAsked = permissionAsked || externalResolution.asked
                try Task.checkCancellation()
                await observer?.permissionResolved(externalRequest, PermissionReply(permissionID: externalRequest.permissionID, decision: externalResolution.decision))
                guard externalResolution.decision == .allow else {
                    throw CoreError(code: .permissionDenied, message: "已拒绝 Workspace 外目录: \(resource)")
                }
            }
            let permissionStart = clock.now
            let resolution = await permissions.resolve(request, action: Self.permissionAction(for: tool.definition.id)) {
                await observer?.permissionAsked(request)
                await onPermissionAsked(request)
            }
            permissionWait = permissionStart.duration(to: clock.now)
            permissionAsked = resolution.asked
            try Task.checkCancellation()
            await observer?.permissionResolved(request, PermissionReply(permissionID: request.permissionID, decision: resolution.decision))
            guard resolution.decision == .allow else {
                throw CoreError(code: .permissionDenied, message: "已拒绝 \(call.toolID.rawValue): \(resource)")
            }
            try Task.checkCancellation()
            let executionStart = clock.now
            let mutates = !ToolCapability(capabilities).readOnly
            await observer?.executionClaimed(ToolExecutionClaim(mutatesProject: mutates))
            let operation: @Sendable () async throws -> String = {
                try await ToolExecutionContext.$observer.withValue(observer) {
                    try await tool.execute(arguments: call.arguments, profile: effectiveProfile)
                }
            }
            let rawContent = mutates ? try await mutations.execute(operation) : try await operation()
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
                toolName: tool.definition.name,
                resource: resource
            )
        } catch let error as CoreError {
            if let command = Self.commandResult(from: error.message) {
                let rawContent = command.stdout + (command.stdout.isEmpty || command.stderr.isEmpty ? "" : "\n") + command.stderr
                let bounded = outputPolicy.excerpt(rawContent)
                let metadata = (try? await outputArchive?.archive(rawContent, metadata: bounded.metadata)) ?? bounded.metadata
                let timedOut = error.code == .commandTimedOut
                return ExecutionOutcome(
                    result: ToolResult(callID: call.callID, success: false, content: bounded.content, error: ToolError(code: timedOut ? CoreError.Code.executionStateUnknown.rawValue : error.code.rawValue, message: timedOut ? "命令超时；执行状态需要验证" : "命令以状态 \(command.exitCode) 退出"), toolName: call.toolName, outcome: timedOut ? .timedOut : .failure, summary: "command failed", metadata: timedOut ? ["executionState": "unknown", "verificationRequired": "true"] : [:], output: metadata, exitCode: Int(command.exitCode), diagnostics: ToolDiagnostics(stdout: command.stdout, stderr: command.stderr), continuation: metadata.outputBlobRef),
                    permissionWait: permissionWait,
                    permissionAsked: permissionAsked,
                    execution: execution,
                    toolName: call.toolName,
                    resource: nil
                )
            }
            return ExecutionOutcome(
                result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: error.code.rawValue, message: error.message), toolName: call.toolName, outcome: error.code == .permissionDenied ? .denied : error.code == .commandTimedOut ? .timedOut : .failure),
                permissionWait: permissionWait,
                permissionAsked: permissionAsked,
                execution: execution,
                toolName: call.toolName,
                resource: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ExecutionOutcome(
                result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: CoreError.Code.toolExecutionFailed.rawValue, message: String(describing: error)), toolName: call.toolName),
                permissionWait: permissionWait,
                permissionAsked: permissionAsked,
                execution: execution,
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

    public func finishMCPProviderStep(sessionID: SessionID) async { await mcpPager?.finishProviderStep(sessionID: sessionID) }
    public func abortMCPTurn(sessionID: SessionID) async { await mcpPager?.abortTurn(sessionID: sessionID) }

    private func executeMCP(_ call: ToolCall, sessionID: SessionID, projectID: ProjectID, profile: ExecutionProfile, pager: MCPToolPager, onPermissionAsked: @escaping @Sendable (PermissionRequest) async -> Void, observer: ToolExecutionObserver?) async -> ExecutionOutcome {
        let clock = ContinuousClock()
        do {
            let lease = try await pager.resolve(sessionID: sessionID, providerToolID: call.toolID)
            let request = PermissionRequest(permissionID: PermissionID(UUID().uuidString), sessionID: sessionID, toolCallID: call.callID, toolID: lease.toolID, capabilities: [.externalService, .networkAccess, .destructive], resource: lease.toolID.rawValue, description: "允许外部 MCP Tool \(lease.toolID.rawValue)")
            guard profile != .readOnly || ToolCapability(request.capabilities).readOnly else { throw CoreError(code: .permissionDenied, message: "readOnly Profile 不允许 MCP Tool") }
            let permissionStarted = clock.now
            let resolution = await permissions.resolve(request) {
                await observer?.permissionAsked(request)
                await onPermissionAsked(request)
            }
            let permissionWait = permissionStarted.duration(to: clock.now)
            try Task.checkCancellation()
            await observer?.permissionResolved(request, PermissionReply(permissionID: request.permissionID, decision: resolution.decision))
            guard resolution.decision == .allow else { throw CoreError(code: .permissionDenied, message: "已拒绝 \(lease.toolID.rawValue)") }
            let executionStarted = clock.now
            await observer?.executionClaimed(ToolExecutionClaim(mutatesProject: true))
            let response = try await pager.execute(sessionID: sessionID, projectID: projectID, providerToolID: call.toolID, arguments: call.arguments)
            if !response.content.isEmpty { await outputSink?(ToolOutputChunk(toolCallID: call.callID, stream: .stdout, sequence: 0, payload: response.content)) }
            let bounded = outputPolicy.excerpt(response.content)
            let metadata = try await outputArchive?.archive(response.content, metadata: bounded.metadata) ?? bounded.metadata
            return ExecutionOutcome(result: ToolResult(callID: call.callID, success: true, content: bounded.content, toolName: response.lease.toolID.rawValue, metadata: ["mcpToolID": response.lease.toolID.rawValue, "schemaHash": response.lease.schemaHash], output: metadata), permissionWait: permissionWait, permissionAsked: resolution.asked, execution: executionStarted.duration(to: clock.now), toolName: response.lease.toolID.rawValue, resource: response.lease.toolID.rawValue)
        } catch let error as MCPToolPagerError {
            let code: CoreError.Code = switch error { case .leaseMissing, .leaseExpired: .mcpToolLeaseMissing; case .schemaChanged: .mcpToolSchemaChanged; case .schemaTooLarge: .mcpToolSchemaTooLarge; case .schemaBudgetExceeded: .mcpToolSchemaBudgetExceeded; default: .mcpServerUnavailable }
            return ExecutionOutcome(result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: code.rawValue, message: String(describing: error)), toolName: call.toolID.rawValue), permissionWait: .zero, permissionAsked: false, execution: .zero, toolName: call.toolID.rawValue, resource: nil)
        } catch let error as CoreError {
            let timedOut = error.code == .commandTimedOut || error.code == .idleTimedOut
            return ExecutionOutcome(result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: error.code.rawValue, message: error.message), toolName: call.toolID.rawValue, outcome: error.code == .idleTimedOut ? .idleTimedOut : timedOut ? .timedOut : .failure), permissionWait: .zero, permissionAsked: false, execution: .zero, toolName: call.toolID.rawValue, resource: nil)
        } catch {
            return ExecutionOutcome(result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: CoreError.Code.toolExecutionFailed.rawValue, message: String(describing: error)), toolName: call.toolID.rawValue), permissionWait: .zero, permissionAsked: false, execution: .zero, toolName: call.toolID.rawValue, resource: nil)
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
        if let operations = json as? [[String: Any]] {
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
