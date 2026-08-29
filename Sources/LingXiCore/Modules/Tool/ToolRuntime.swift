import Foundation
import LingXiProtocol

public protocol ToolExecutor: Sendable {
    var definition: ToolDefinition { get }
    func resource(for arguments: String, profile: ExecutionProfile) throws -> String
    func execute(arguments: String, profile: ExecutionProfile) async throws -> String
}

/// 静态注册表。本阶段无动态插件或运行时注册。
public struct ToolRegistry: Sendable {
    private let tools: [ToolID: any ToolExecutor]

    public init(_ tools: [any ToolExecutor]) {
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.definition.id, $0) })
    }

    public var definitions: [ToolDefinition] {
        tools.values.map(\.definition).sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func tool(for id: ToolID) -> (any ToolExecutor)? {
        tools[id]
    }

    public func tool(named name: String) -> (any ToolExecutor)? {
        tools.values.first { $0.definition.name == name }
    }
}

/// Provider 无关的 Tool 执行入口：参数解析、路径预检、权限、执行和错误归一化。
public struct ToolRuntime: Sendable {
    private let registry: ToolRegistry
    private let permissions: PermissionEngine

    public init(registry: ToolRegistry, permissions: PermissionEngine) {
        self.registry = registry
        self.permissions = permissions
    }

    public var definitions: [ToolDefinition] { registry.definitions }

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
        onPermissionAsked: @escaping @Sendable (PermissionRequest) async -> Void
    ) async -> ToolResult {
        await executeWithMetrics(call, sessionID: sessionID, onPermissionAsked: onPermissionAsked).result
    }

    public func executeWithMetrics(
        _ call: ToolCall,
        sessionID: SessionID,
        onPermissionAsked: @escaping @Sendable (PermissionRequest) async -> Void
    ) async -> ExecutionOutcome {
        let clock = ContinuousClock()
        var permissionWait: Duration = .zero
        var permissionAsked = false
        var execution: Duration = .zero
        do {
            try Task.checkCancellation()
            guard let tool = registry.tool(for: call.toolID) else {
                throw CoreError(code: .toolNotFound, message: "未注册 Tool: \(call.toolID.rawValue)")
            }
            let configuration = await permissions.currentConfiguration()
            guard tool.definition.capability.readOnly || configuration.profile != .readOnly else {
                throw CoreError(code: .permissionDenied, message: "readOnly Profile 不允许 \(call.toolID.rawValue)")
            }
            let resource = try tool.resource(for: call.arguments, profile: configuration.profile)
            let request = PermissionRequest(
                permissionID: PermissionID(UUID().uuidString),
                sessionID: sessionID,
                toolCallID: call.callID,
                toolID: call.toolID,
                resource: resource,
                description: "允许 \(call.toolID.rawValue) 读取 \(resource)"
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
            let content = try await tool.execute(arguments: call.arguments, profile: configuration.profile)
            execution = executionStart.duration(to: clock.now)
            return ExecutionOutcome(
                result: ToolResult(callID: call.callID, success: true, content: content),
                permissionWait: permissionWait,
                permissionAsked: permissionAsked,
                execution: execution,
                toolName: tool.definition.name,
                resource: resource
            )
        } catch let error as CoreError {
            return ExecutionOutcome(
                result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: error.code.rawValue, message: error.message)),
                permissionWait: permissionWait,
                permissionAsked: permissionAsked,
                execution: execution,
                toolName: call.toolName,
                resource: nil
            )
        } catch is CancellationError {
            return ExecutionOutcome(
                result: ToolResult(callID: call.callID, success: false, content: "", error: ToolError(code: CoreError.Code.permissionCancelled.rawValue, message: "Tool 执行已取消")),
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

    private static func canonicalArguments(_ arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return arguments }
        return String(decoding: normalized, as: UTF8.self)
    }
}
