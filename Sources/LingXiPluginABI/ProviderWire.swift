import Foundation

/// A provider capability as declared by a plugin and reported by the host. No defaults: the models a
/// plugin offers and the request shape it accepts are explicit, not assumed.
public struct ProviderIdentity: Codable, Sendable, Equatable {
    public let id: String
    public let models: [String]
    public let supportsParallelToolCalls: Bool
    public let toolResultPlacement: String

    public init(id: String, models: [String], supportsParallelToolCalls: Bool, toolResultPlacement: String) {
        self.id = id
        self.models = models
        self.supportsParallelToolCalls = supportsParallelToolCalls
        self.toolResultPlacement = toolResultPlacement
    }
}

/// One item of provider input. `role` covers message items; `callID`/`name`/`arguments` cover the
/// function-call pair the loop produces, so a tool round trip survives the boundary unchanged.
public struct ProviderWireItem: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case message
        case functionCall = "function_call"
        case functionCallOutput = "function_call_output"
    }

    public let kind: Kind
    public let role: String?
    public let text: String?
    public let callID: String?
    public let name: String?
    public let arguments: String?
    public let output: String?

    public init(
        kind: Kind, role: String? = nil, text: String? = nil,
        callID: String? = nil, name: String? = nil, arguments: String? = nil, output: String? = nil
    ) {
        self.kind = kind
        self.role = role
        self.text = text
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.output = output
    }
}

public struct ProviderWireTool: Codable, Sendable, Equatable {
    public let name: String
    public let description: String?
    /// JSON Schema as a string; the kernel never re-encodes or interprets it.
    public let parametersJSON: String

    public init(name: String, description: String?, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

public struct ProviderWireRequest: Codable, Sendable, Equatable {
    public let model: String
    public let instructions: String?
    public let input: [ProviderWireItem]
    public let tools: [ProviderWireTool]
    public let maxOutputTokens: Int?
    /// Supplied per invocation by the Core from its own environment. The host environment is never
    /// widened, and the value is never logged.
    public let credential: String?

    public init(
        model: String, instructions: String?, input: [ProviderWireItem],
        tools: [ProviderWireTool], maxOutputTokens: Int?, credential: String?
    ) {
        self.model = model
        self.instructions = instructions
        self.input = input
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
        self.credential = credential
    }
}

public struct ProviderWireUsage: Codable, Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let reasoningTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?

    public init(
        inputTokens: Int? = nil, outputTokens: Int? = nil, reasoningTokens: Int? = nil,
        cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

/// Normalized streaming event. The plugin translates its wire format into this; the runtime maps it
/// to the kernel's `ModelEvent`. Unknown types are decoded as `unknown`, never thrown away silently.
public struct ProviderWireEvent: Codable, Sendable, Equatable {
    public let type: String
    public let text: String?
    public let callID: String?
    public let name: String?
    public let arguments: String?
    public let stopReason: String?
    public let failureKind: String?
    public let message: String?
    public let requestID: String?
    public let usage: ProviderWireUsage?

    public init(
        type: String, text: String? = nil, callID: String? = nil, name: String? = nil,
        arguments: String? = nil, stopReason: String? = nil, failureKind: String? = nil,
        message: String? = nil, requestID: String? = nil, usage: ProviderWireUsage? = nil
    ) {
        self.type = type
        self.text = text
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.stopReason = stopReason
        self.failureKind = failureKind
        self.message = message
        self.requestID = requestID
        self.usage = usage
    }
}

/// The envelope a plugin emits on the host's `emit` channel. `requestID` routes the event to the
/// invoke that is still in flight.
public struct ProviderWireEnvelope: Codable, Sendable {
    public let requestID: String
    public let event: ProviderWireEvent

    public init(requestID: String, event: ProviderWireEvent) {
        self.requestID = requestID
        self.event = event
    }
}
