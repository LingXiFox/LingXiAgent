import Foundation
import LingXiProtocol
import LingXiClient

/// 业务命令执行上下文。
public struct ApplicationCommandContext: Sendable {
    public let rawInput: String
    public let commandName: String
    public let arguments: [String]
    public let sessionID: SessionID?
    public let client: LingXiClientVNext
    public let state: ApplicationState

    public init(
        rawInput: String,
        commandName: String,
        arguments: [String],
        sessionID: SessionID?,
        client: LingXiClientVNext,
        state: ApplicationState
    ) {
        self.rawInput = rawInput
        self.commandName = commandName
        self.arguments = arguments
        self.sessionID = sessionID
        self.client = client
        self.state = state
    }
}

public struct ApplicationCommandResult: Sendable, Equatable {
    public let output: String
    public let sessionIDToSwitch: SessionID?
    public let nextTurnMode: AgentMode?
    public let nextTurnPermission: PermissionConfiguration?
    public let nextTurnReasoningEffort: ReasoningEffort?

    public init(
        output: String,
        sessionIDToSwitch: SessionID? = nil,
        nextTurnMode: AgentMode? = nil,
        nextTurnPermission: PermissionConfiguration? = nil,
        nextTurnReasoningEffort: ReasoningEffort? = nil
    ) {
        self.output = output
        self.sessionIDToSwitch = sessionIDToSwitch
        self.nextTurnMode = nextTurnMode
        self.nextTurnPermission = nextTurnPermission
        self.nextTurnReasoningEffort = nextTurnReasoningEffort
    }
}

/// 统一业务命令描述与执行体。
public struct ApplicationCommand: Sendable {
    public let name: String
    public let aliases: [String]
    public let description: String
    public let category: String
    public let argumentSchema: String
    public let handler: @Sendable (ApplicationCommandContext) async throws -> ApplicationCommandResult

    public init(
        name: String,
        aliases: [String] = [],
        description: String,
        category: String = "General",
        argumentSchema: String = "",
        handler: @Sendable @escaping (ApplicationCommandContext) async throws -> ApplicationCommandResult
    ) {
        self.name = name
        self.aliases = aliases
        self.description = description
        self.category = category
        self.argumentSchema = argumentSchema
        self.handler = handler
    }
}
