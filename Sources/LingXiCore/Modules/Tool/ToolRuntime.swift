import CoreFoundation
import Foundation
import LingXiProtocol

public protocol ToolExecutor: Sendable {
    var definition: ToolDefinition { get }
    func resource(for arguments: String, profile: ExecutionProfile) throws -> String
    func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind>
    func execute(arguments: String, profile: ExecutionProfile) async throws -> String
}

public extension ToolExecutor {
    func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind> { definition.capability.kinds }
}

public protocol ToolProvider: Sendable {
    func register(into registry: inout ToolRegistry) throws
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
    private let mutations: ToolMutationCoordinator?
    private let outputPolicy: ToolOutputPolicy
    private let outputArchive: ToolOutputArchive?
    private let outputSink: (@Sendable (ToolOutputChunk) async -> Void)?
    private let mcpPager: MCPToolPager?
    private let subagents: SubagentToolService?

    public init(registry: ToolRegistry, permissions: PermissionEngine, mutations: ToolMutationCoordinator? = nil, outputPolicy: ToolOutputPolicy = ToolOutputPolicy(), outputArchive: ToolOutputArchive? = nil, outputSink: (@Sendable (ToolOutputChunk) async -> Void)? = nil, mcpPager: MCPToolPager? = nil, subagents: SubagentToolService? = nil) {
        self.registry = registry
        self.permissions = permissions
        self.mutations = mutations
        self.outputPolicy = outputPolicy
        self.outputArchive = outputArchive
        self.outputSink = outputSink
        self.mcpPager = mcpPager
        self.subagents = subagents
    }

    public var definitions: [ToolDefinition] { registry.definitions }

    public func availableDefinitions(sessionID: SessionID? = nil, interactive: Bool = false) async -> [ToolDefinition] {
        let configuration = await permissions.currentConfiguration()
        var definitions = registry.definitions.filter { definition in
            if definition.name == "question" && !interactive { return false }
            if configuration.profile == .readOnly {
                return definition.capability.readOnly
            }
            return true
        }
        definitions += [MCPDiscoveryTools.search, MCPDiscoveryTools.load]
        if subagents != nil { definitions.append(SubagentTool.definition) }
        if let sessionID, let mcpPager { definitions += await mcpPager.providerDefinitions(sessionID: sessionID) }
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
        onPermissionAsked: @escaping @Sendable (PermissionRequest) async -> Void
    ) async -> ToolResult {
        await executeWithMetrics(call, sessionID: sessionID, projectID: projectID, onPermissionAsked: onPermissionAsked).result
    }

    public func executeWithMetrics(
        _ call: ToolCall,
        sessionID: SessionID,
        projectID: ProjectID = ProjectID("ephemeral"),
        onPermissionAsked: @escaping @Sendable (PermissionRequest) async -> Void
    ) async -> ExecutionOutcome {
        let clock = ContinuousClock()
        var permissionWait: Duration = .zero
        var permissionAsked = false
        var execution: Duration = .zero
        do {
            try Task.checkCancellation()
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
                let resolution = await permissions.resolve(request) { await onPermissionAsked(request) }
                permissionWait = permissionStart.duration(to: clock.now)
                permissionAsked = resolution.asked
                guard resolution.decision == .allow else { throw CoreError(code: .permissionDenied, message: "已拒绝 subagent") }
                try Task.checkCancellation()
                let executionStart = clock.now
                let content = try await subagents.execute(arguments: call.arguments, sessionID: sessionID, callID: call.callID)
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
                return await executeMCP(call, sessionID: sessionID, projectID: projectID, pager: mcpPager, onPermissionAsked: onPermissionAsked)
            }
            guard let tool = registry.tool(for: call.toolID) else {
                throw CoreError(code: .toolNotFound, message: "未注册 Tool: \(call.toolID.rawValue)")
            }
            try ToolSchemaValidator.validate(arguments: call.arguments, schema: tool.definition.inputSchema)
            let configuration = await permissions.currentConfiguration()
            let capabilities = try tool.capabilities(for: call.arguments, profile: configuration.profile)
            guard configuration.profile != .readOnly || (!capabilities.contains(.projectWrite) && !capabilities.contains(.repositoryWrite) && !capabilities.contains(.processExecute)) else {
                throw CoreError(code: .permissionDenied, message: "readOnly Profile 不允许 \(call.toolID.rawValue)")
            }
            let resource = try tool.resource(for: call.arguments, profile: configuration.profile)
            let request = PermissionRequest(
                permissionID: PermissionID(UUID().uuidString),
                sessionID: sessionID,
                toolCallID: call.callID,
                toolID: call.toolID,
                capabilities: capabilities,
                resource: resource,
                description: "允许 \(call.toolID.rawValue) 访问 \(resource)"
            )
            let permissionStart = clock.now
            let resolution = await permissions.resolve(request) {
                await onPermissionAsked(request)
            }
            permissionWait = permissionStart.duration(to: clock.now)
            permissionAsked = resolution.asked
            guard resolution.decision == .allow else {
                throw CoreError(code: .permissionDenied, message: "已拒绝 \(call.toolID.rawValue): \(resource)")
            }
            try Task.checkCancellation()
            let executionStart = clock.now
            let mutates = capabilities.contains(.projectWrite) || capabilities.contains(.repositoryWrite)
            let operation: @Sendable () async throws -> String = { try await tool.execute(arguments: call.arguments, profile: configuration.profile) }
            let rawContent = mutates && mutations != nil ? try await mutations!.execute(operation) : try await operation()
            if !rawContent.isEmpty {
                await outputSink?(ToolOutputChunk(toolCallID: call.callID, stream: .stdout, sequence: 0, payload: rawContent))
            }
            let bounded = outputPolicy.excerpt(rawContent)
            let metadata = try await outputArchive?.archive(rawContent, metadata: bounded.metadata) ?? bounded.metadata
            execution = executionStart.duration(to: clock.now)
            return ExecutionOutcome(
                result: ToolResult(callID: call.callID, success: true, content: bounded.content, output: metadata),
                permissionWait: permissionWait,
                permissionAsked: permissionAsked,
                execution: execution,
                toolName: tool.definition.name,
                resource: resource
            )
        } catch let error as CoreError {
            return ExecutionOutcome(
                result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: error.code.rawValue, message: error.message), toolName: call.toolName, outcome: error.code == .permissionDenied ? .denied : error.code == .commandTimedOut ? .timedOut : .failure),
                permissionWait: permissionWait,
                permissionAsked: permissionAsked,
                execution: execution,
                toolName: call.toolName,
                resource: nil
            )
        } catch is CancellationError {
            return ExecutionOutcome(
                result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: CoreError.Code.permissionCancelled.rawValue, message: "Tool 执行已取消"), toolName: call.toolName, outcome: .cancelled),
                permissionWait: permissionWait,
                permissionAsked: permissionAsked,
                execution: execution,
                toolName: call.toolName,
                resource: nil
            )
        } catch {
            return ExecutionOutcome(
                result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: CoreError.Code.toolExecutionFailed.rawValue, message: String(describing: error))),
                permissionWait: permissionWait,
                permissionAsked: permissionAsked,
                execution: execution,
                toolName: call.toolName,
                resource: nil
            )
        }
    }

    public func finishMCPProviderStep(sessionID: SessionID) async { await mcpPager?.finishProviderStep(sessionID: sessionID) }

    private func executeMCP(_ call: ToolCall, sessionID: SessionID, projectID: ProjectID, pager: MCPToolPager, onPermissionAsked: @escaping @Sendable (PermissionRequest) async -> Void) async -> ExecutionOutcome {
        let clock = ContinuousClock()
        do {
            let lease = try await pager.resolve(sessionID: sessionID, providerToolID: call.toolID)
            let request = PermissionRequest(permissionID: PermissionID(UUID().uuidString), sessionID: sessionID, toolCallID: call.callID, toolID: lease.toolID, capabilities: [.externalService, .networkAccess, .destructive], resource: lease.toolID.rawValue, description: "允许外部 MCP Tool \(lease.toolID.rawValue)")
            let permissionStarted = clock.now
            let resolution = await permissions.resolve(request) { await onPermissionAsked(request) }
            let permissionWait = permissionStarted.duration(to: clock.now)
            guard resolution.decision == .allow else { throw CoreError(code: .permissionDenied, message: "已拒绝 \(lease.toolID.rawValue)") }
            let executionStarted = clock.now
            let response = try await pager.execute(sessionID: sessionID, projectID: projectID, providerToolID: call.toolID, arguments: call.arguments)
            if !response.content.isEmpty { await outputSink?(ToolOutputChunk(toolCallID: call.callID, stream: .stdout, sequence: 0, payload: response.content)) }
            let bounded = outputPolicy.excerpt(response.content)
            let metadata = try await outputArchive?.archive(response.content, metadata: bounded.metadata) ?? bounded.metadata
            return ExecutionOutcome(result: ToolResult(callID: call.callID, success: true, content: bounded.content, toolName: response.lease.toolID.rawValue, metadata: ["mcpToolID": response.lease.toolID.rawValue, "schemaHash": response.lease.schemaHash], output: metadata), permissionWait: permissionWait, permissionAsked: resolution.asked, execution: executionStarted.duration(to: clock.now), toolName: response.lease.toolID.rawValue, resource: response.lease.toolID.rawValue)
        } catch let error as MCPToolPagerError {
            let code: CoreError.Code = switch error { case .leaseMissing, .leaseExpired: .mcpToolLeaseMissing; case .schemaChanged: .mcpToolSchemaChanged; case .schemaTooLarge: .mcpToolSchemaTooLarge; case .schemaBudgetExceeded: .mcpToolSchemaBudgetExceeded; default: .mcpServerUnavailable }
            return ExecutionOutcome(result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: code.rawValue, message: String(describing: error)), toolName: call.toolID.rawValue), permissionWait: .zero, permissionAsked: false, execution: .zero, toolName: call.toolID.rawValue, resource: nil)
        } catch let error as CoreError {
            return ExecutionOutcome(result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: error.code.rawValue, message: error.message), toolName: call.toolID.rawValue), permissionWait: .zero, permissionAsked: false, execution: .zero, toolName: call.toolID.rawValue, resource: nil)
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
}

/// JSON object is decoded once at the runtime boundary before permission or side effects.
enum ToolSchemaValidator {
    static func validate(arguments: String, schema: ToolInputSchema) throws {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let values = object as? [String: Any]
        else { throw CoreError(code: .toolArgumentInvalid, message: "Tool 参数必须是 JSON object") }
        guard Set(values.keys).isSubset(of: Set(schema.properties.keys)) else {
            throw CoreError(code: .toolArgumentInvalid, message: "Tool 参数包含未知字段")
        }
        for name in schema.required where values[name] == nil {
            throw CoreError(code: .toolArgumentInvalid, message: "Tool 参数缺少必填字段: \(name)")
        }
        for (name, value) in values {
            guard let property = schema.properties[name], matches(value, property.type) else {
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
