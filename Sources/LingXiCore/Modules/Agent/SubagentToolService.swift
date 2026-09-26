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
    let permissionProfile: String?
    let budgetProfile: String?
    let contextProfile: String?
    let maxSteps: Int?
    let timeoutSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case action, task, title, content, reasoning
        case runID = "run_id"
        case sessionID = "session_id"
        case providerID = "provider_id"
        case modelID = "model_id"
        case permissionProfile = "permission_profile"
        case budgetProfile = "budget_profile"
        case contextProfile = "context_profile"
        case maxSteps = "max_steps"
        case timeoutSeconds = "timeout_seconds"
    }

    var executionProfile: SubagentExecutionProfile? {
        guard permissionProfile != nil || budgetProfile != nil || contextProfile != nil || maxSteps != nil || timeoutSeconds != nil else {
            return nil
        }
        return SubagentExecutionProfile(
            permissionProfile: permissionProfile,
            budgetProfile: budgetProfile,
            contextProfile: contextProfile,
            maxSteps: maxSteps,
            timeoutSeconds: timeoutSeconds
        )
    }
}

/// The Tool Plane calls this actor; it owns no Session state and delegates only through explicit runtime closures.
public actor SubagentToolService {
    private var spawn: (@Sendable (SessionID, AgentRunID, String, String?, ModelSelection?, SubagentExecutionProfile?, ToolCallID) async throws -> (SessionID, AgentRunInfo))?
    private var status: (@Sendable (AgentRunID, AgentRunID) async throws -> AgentRunInfo)?
    private var result: (@Sendable (AgentRunID, AgentRunID) async throws -> SubagentResult)?
    private var cancel: (@Sendable (AgentRunID, AgentRunID) async throws -> Void)?
    private var message: (@Sendable (SessionID, AgentRunID, String) async throws -> AgentRunInfo)?

    public init() {}

    public func bind(
        spawn: @escaping @Sendable (SessionID, AgentRunID, String, String?, ModelSelection?, SubagentExecutionProfile?, ToolCallID) async throws -> (SessionID, AgentRunInfo),
        status: @escaping @Sendable (AgentRunID, AgentRunID) async throws -> AgentRunInfo,
        result: @escaping @Sendable (AgentRunID, AgentRunID) async throws -> SubagentResult,
        cancel: @escaping @Sendable (AgentRunID, AgentRunID) async throws -> Void,
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
            guard let parentRunID = AgentExecutionContext.current?.runID,
                  let task = (input.task ?? input.content)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !task.isEmpty,
                  let spawn else {
                throw CoreError(code: .toolArgumentInvalid, message: "spawn 需要当前 AgentRun 与 task")
            }
            if let scope = AgentExecutionContext.currentCapabilityScope {
                try scope.validateChildScope(requestedTools: input.executionProfile?.toolProfile, requestedPermission: input.permissionProfile)
            }
            let providerID = input.providerID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelID = input.modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let reasoning = input.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedSelection: ModelSelection?
            switch (providerID?.isEmpty == false ? providerID : nil, modelID?.isEmpty == false ? modelID : nil) {
            case (nil, nil):
                requestedSelection = nil
            case let (providerID?, modelID?):
                requestedSelection = ModelSelection(providerID: providerID, modelID: modelID, reasoning: reasoning?.isEmpty == false ? reasoning : nil)
            default:
                throw CoreError(code: .toolArgumentInvalid, message: "subagent 的 provider_id 与 model_id 必须同时提供")
            }
            let title = input.title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            let (childSessionID, run) = try await spawn(sessionID, parentRunID, task, title, requestedSelection, input.executionProfile, callID)
            return try encode(SubagentSpawnResponse(childSessionID: childSessionID, run: run))
        case "status":
            guard let id = input.runID, let requester = AgentExecutionContext.current?.runID, let status else { throw CoreError(code: .toolArgumentInvalid, message: "status 需要 run_id 与当前 AgentRun") }
            return try encode(try await status(AgentRunID(id), requester))
        case "result":
            guard let id = input.runID, let requester = AgentExecutionContext.current?.runID, let result, let status else { throw CoreError(code: .toolArgumentInvalid, message: "result 需要 run_id 与当前 AgentRun") }
            let target = AgentRunID(id)
            // An in-flight child has no settled result. Reporting that as a pollable state
            // rather than an error matters: on an error the parent abandons this run_id and
            // spawns a duplicate child for the same task, which then conflicts.
            let info = try await status(target, requester)
            if !info.status.isTerminal {
                return try encode(SubagentPendingResponse(runID: id, runStatus: info.status.rawValue))
            }
            return try encode(try await result(target, requester))
        case "cancel":
            guard let id = input.runID, let requester = AgentExecutionContext.current?.runID, let cancel else { throw CoreError(code: .toolArgumentInvalid, message: "cancel 需要 run_id 与当前 AgentRun") }
            try await cancel(AgentRunID(id), requester); return #"{"status":"cancelled"}"#
        case "message":
            guard let child = input.sessionID, let content = input.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty, let parentRunID = AgentExecutionContext.current?.runID, let message else { throw CoreError(code: .toolArgumentInvalid, message: "message 需要 session_id、content 与当前 AgentRun") }
            return try encode(try await message(SessionID(child), parentRunID, content))
        default: throw CoreError(code: .toolArgumentInvalid, message: "未知 subagent action: \(input.action)")
        }
    }
}

private struct SubagentSpawnResponse: Codable {
    let childSessionID: SessionID
    let run: AgentRunInfo
}

private struct SubagentPendingResponse: Codable {
    let status: String
    let runID: String
    let runStatus: String
    let nextAction: String

    init(runID: String, runStatus: String) {
        self.status = "running"
        self.runID = runID
        self.runStatus = runStatus
        self.nextAction = "Poll action=status with this run_id until it reaches a terminal state, then call action=result once. Do not spawn a second child for the same task."
    }

    enum CodingKeys: String, CodingKey {
        case status
        case runID = "run_id"
        case runStatus = "run_status"
        case nextAction = "next_action"
    }
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void
    init(_ value: some Encodable) { encodeValue = value.encode }
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}
