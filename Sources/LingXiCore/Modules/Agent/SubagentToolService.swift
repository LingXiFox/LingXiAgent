import Foundation
import LingXiProtocol

public enum SubagentTool {
    public static let definition = ToolDefinition(
        id: ToolID("subagent"),
        description: "Spawn, inspect, message, retrieve results from, or cancel an independent child Agent Session.",
        inputSchema: ToolInputSchema(properties: [
            "action": ToolInputProperty(type: .string, description: "spawn, status, message, result, or cancel", enumValues: ["spawn", "status", "message", "result", "cancel"]),
            "task": ToolInputProperty(type: .string, description: "Child task for spawn"),
            "title": ToolInputProperty(type: .string, description: "Optional child title"),
            "run_id": ToolInputProperty(type: .string, description: "Agent run ID"),
            "session_id": ToolInputProperty(type: .string, description: "Child session ID"),
            "content": ToolInputProperty(type: .string, description: "Additional child message"),
            "provider_id": ToolInputProperty(type: .string, description: "Requested provider ID"),
            "model_id": ToolInputProperty(type: .string, description: "Requested model ID"),
            "reasoning": ToolInputProperty(type: .string, description: "Requested reasoning mode")
        ], required: ["action"]),
        capability: ToolCapability([.projectRead])
    )
}

private struct SubagentToolArguments: Decodable {
    let action: String
    let task: String?
    let title: String?
    let runID: String?
    let sessionID: String?
    let content: String?
    let providerID: String?
    let modelID: String?
    let reasoning: String?
}

/// The Tool Plane calls this actor; it owns no Session state and delegates only through explicit runtime closures.
public actor SubagentToolService {
    private var spawn: (@Sendable (SessionID, AgentRunID, String, String?, ModelSelection?, ToolCallID) async throws -> (SessionID, AgentRunInfo))?
    private var status: (@Sendable (AgentRunID) async throws -> AgentRunInfo)?
    private var result: (@Sendable (AgentRunID) async throws -> SubagentResult)?
    private var cancel: (@Sendable (AgentRunID) async throws -> Void)?
    private var message: (@Sendable (SessionID, AgentRunID, String) async throws -> AgentRunInfo)?

    public init() {}

    public func bind(
        spawn: @escaping @Sendable (SessionID, AgentRunID, String, String?, ModelSelection?, ToolCallID) async throws -> (SessionID, AgentRunInfo),
        status: @escaping @Sendable (AgentRunID) async throws -> AgentRunInfo,
        result: @escaping @Sendable (AgentRunID) async throws -> SubagentResult,
        cancel: @escaping @Sendable (AgentRunID) async throws -> Void,
        message: @escaping @Sendable (SessionID, AgentRunID, String) async throws -> AgentRunInfo
    ) {
        self.spawn = spawn; self.status = status; self.result = result; self.cancel = cancel; self.message = message
    }

    public func execute(arguments: String, sessionID: SessionID, callID: ToolCallID) async throws -> String {
        guard let data = arguments.data(using: .utf8) else { throw CoreError(code: .toolArgumentInvalid, message: "subagent 参数不是 UTF-8") }
        let input = try JSONDecoder().decode(SubagentToolArguments.self, from: data)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encode: @Sendable (any Encodable) throws -> String = { String(decoding: try encoder.encode(AnyEncodable($0)), as: UTF8.self) }
        switch input.action {
        case "spawn":
            guard let parentRunID = AgentExecutionContext.current?.runID, let task = input.task, !task.isEmpty, let spawn else { throw CoreError(code: .toolArgumentInvalid, message: "spawn 需要当前 AgentRun 与 task") }
            let selection = input.modelID.map { ModelSelection(providerID: input.providerID ?? "default", modelID: $0, reasoning: input.reasoning) }
            let (childSessionID, run) = try await spawn(sessionID, parentRunID, task, input.title, selection, callID)
            return try encode(SubagentSpawnResponse(childSessionID: childSessionID, run: run))
        case "status":
            guard let id = input.runID, let status else { throw CoreError(code: .toolArgumentInvalid, message: "status 需要 run_id") }
            return try encode(try await status(AgentRunID(id)))
        case "result":
            guard let id = input.runID, let result else { throw CoreError(code: .toolArgumentInvalid, message: "result 需要 run_id") }
            return try encode(try await result(AgentRunID(id)))
        case "cancel":
            guard let id = input.runID, let cancel else { throw CoreError(code: .toolArgumentInvalid, message: "cancel 需要 run_id") }
            try await cancel(AgentRunID(id)); return #"{"status":"cancelled"}"#
        case "message":
            guard let child = input.sessionID, let content = input.content, !content.isEmpty, let parentRunID = AgentExecutionContext.current?.runID, let message else { throw CoreError(code: .toolArgumentInvalid, message: "message 需要 session_id、content 与当前 AgentRun") }
            return try encode(try await message(SessionID(child), parentRunID, content))
        default: throw CoreError(code: .toolArgumentInvalid, message: "未知 subagent action: \(input.action)")
        }
    }
}

private struct SubagentSpawnResponse: Codable {
    let childSessionID: SessionID
    let run: AgentRunInfo
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void
    init(_ value: some Encodable) { encodeValue = value.encode }
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}
