import Foundation
import LingXiProtocol

public protocol ToolExecutor: Sendable {
    var definition: ToolDefinition { get }
    func resource(for arguments: String) throws -> String
    func execute(arguments: String) async throws -> String
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

    public func execute(
        _ call: ToolCall,
        sessionID: SessionID,
        onPermissionAsked: @escaping @Sendable (PermissionRequest) async -> Void
    ) async -> ToolResult {
        do {
            try Task.checkCancellation()
            guard let tool = registry.tool(for: call.toolID) else {
                throw CoreError(code: .toolNotFound, message: "未注册 Tool: \(call.toolID.rawValue)")
            }
            let resource = try tool.resource(for: call.arguments)
            let request = PermissionRequest(
                permissionID: PermissionID(UUID().uuidString),
                sessionID: sessionID,
                toolCallID: call.callID,
                toolID: call.toolID,
                resource: resource,
                description: "允许 \(call.toolID.rawValue) 读取 \(resource)"
            )
            let decision = await permissions.request(request) {
                await onPermissionAsked(request)
            }
            guard decision == .allow else {
                throw CoreError(code: .permissionDenied, message: "已拒绝 \(call.toolID.rawValue): \(resource)")
            }
            try Task.checkCancellation()
            return ToolResult(callID: call.callID, success: true, content: try await tool.execute(arguments: call.arguments))
        } catch let error as CoreError {
            return ToolResult(
                callID: call.callID,
                success: false,
                content: "",
                error: ToolError(code: error.code.rawValue, message: error.message)
            )
        } catch is CancellationError {
            return ToolResult(
                callID: call.callID,
                success: false,
                content: "",
                error: ToolError(code: CoreError.Code.permissionCancelled.rawValue, message: "Tool 执行已取消")
            )
        } catch {
            return ToolResult(
                callID: call.callID,
                success: false,
                content: "",
                error: ToolError(code: CoreError.Code.toolExecutionFailed.rawValue, message: String(describing: error))
            )
        }
    }
}
