public enum ToolResultPlacement: String, Sendable {
    case immediatelyAfterCall
    case anywhereInHistory
}

public struct ModelCapabilities: Sendable {
    public let supportsReasoning: Bool
    public let supportsParallelToolCalls: Bool
    public let toolResultPlacement: ToolResultPlacement

    public init(supportsReasoning: Bool, supportsParallelToolCalls: Bool, toolResultPlacement: ToolResultPlacement) {
        self.supportsReasoning = supportsReasoning
        self.supportsParallelToolCalls = supportsParallelToolCalls
        self.toolResultPlacement = toolResultPlacement
    }
}

public enum ModelStopReason: String, Sendable {
    case stop
    case toolCalls
    case maxTokens
    case contentFilter
    case refusal
    case unknown
}

/// The retryable kinds are the plugin's concern; the kernel only carries the classification so a
/// failure can be reported with its cause intact (PROV-004, LOOP-006).
public struct ModelFailure: Error, Sendable {
    public enum Kind: String, Sendable {
        case transport
        case rateLimited
        case serverOverloaded
        case gatewayTimeout
        case badGateway
        case internalServerError
        case contextExceeded
        case contentFilter
        case invalidRequest
        case unauthorized
        case streamProtocol
        case unknown
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public struct ModelUsage: Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?

    /// Absent is not zero: a provider that reports nothing must stay distinguishable from one
    /// that reports a cache miss (CACHE-006).
    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

public struct ToolCallStart: Hashable, Sendable {
    public let callID: ToolCallID
    public let toolName: String

    public init(callID: ToolCallID, toolName: String) {
        self.callID = callID
        self.toolName = toolName
    }
}

public struct ToolCallDelta: Hashable, Sendable {
    public let callID: ToolCallID
    public let argumentFragment: String

    public init(callID: ToolCallID, argumentFragment: String) {
        self.callID = callID
        self.argumentFragment = argumentFragment
    }
}

/// Provider-reported request phase timings, in milliseconds. The kernel only forwards this to an
/// observer; it never persists it and never treats it as execution state. Numbers only, so no
/// request content can be mistaken for diagnostics.
public struct ModelTiming: Sendable, Equatable {
    public let prepareMs: Int?
    public let sendMs: Int?
    public let firstResponseMs: Int?
    public let firstSSEMs: Int?
    public let firstReasoningMs: Int?
    public let firstTextMs: Int?
    public let terminalMs: Int?
    public let totalMs: Int?

    public init(
        prepareMs: Int? = nil, sendMs: Int? = nil, firstResponseMs: Int? = nil,
        firstSSEMs: Int? = nil, firstReasoningMs: Int? = nil, firstTextMs: Int? = nil,
        terminalMs: Int? = nil, totalMs: Int? = nil
    ) {
        self.prepareMs = prepareMs
        self.sendMs = sendMs
        self.firstResponseMs = firstResponseMs
        self.firstSSEMs = firstSSEMs
        self.firstReasoningMs = firstReasoningMs
        self.firstTextMs = firstTextMs
        self.terminalMs = terminalMs
        self.totalMs = totalMs
    }
}

public enum ModelEvent: Sendable {
    case providerRequestID(String)
    case started
    case heartbeat
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallStarted(ToolCallStart)
    case toolCallDelta(ToolCallDelta)
    case toolCallCompleted(ToolCall)
    case usage(ModelUsage)
    /// A provider's own phase timings, emitted once per request just before its terminal event.
    case timing(ModelTiming)
    case completed(ModelStopReason)
    case failed(ModelFailure)

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed:
            true
        default:
            false
        }
    }
}

public struct ModelRequest: Sendable {
    public let requestID: RequestID
    public let continuationOf: RequestID?
    public let executionID: ExecutionID
    public let model: ModelID
    public let entries: [ContextEntry]
    public let tools: [ToolDescriptor]
    public let overallTimeout: Duration?

    public init(
        requestID: RequestID,
        continuationOf: RequestID?,
        executionID: ExecutionID,
        model: ModelID,
        entries: [ContextEntry],
        tools: [ToolDescriptor],
        overallTimeout: Duration? = nil
    ) {
        self.requestID = requestID
        self.continuationOf = continuationOf
        self.executionID = executionID
        self.model = model
        self.entries = entries
        self.tools = tools
        self.overallTimeout = overallTimeout
    }
}

public protocol ModelProvider: Sendable {
    var capabilities: ModelCapabilities { get }
    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error>
    func endExecution(_ executionID: ExecutionID) async
    /// Final Run boundary, called after every step and terminal path have finished. Unlike
    /// `endExecution`, which also runs between tool steps, this must release any continuation
    /// state that is no longer reachable by a future request.
    func finishExecution(_ executionID: ExecutionID) async
}

public extension ModelProvider {
    func endExecution(_ executionID: ExecutionID) async {}
    func finishExecution(_ executionID: ExecutionID) async { await endExecution(executionID) }
}

public enum ModelRouterError: Error, Equatable {
    case noProviderRegistered
    case modelNotOffered(ModelID)
    /// A second registration for the same provider id. The first one is left untouched.
    case duplicateProvider(ProviderID)
    /// A model id already owned by another provider (or repeated in the same registration). The
    /// whole registration is refused before anything is mutated, so a failed registration cannot
    /// leave a partial route behind.
    case duplicateModel(ModelID, existing: ProviderID)

    public var guidance: String {
        switch self {
        case .noProviderRegistered:
            "No provider plugin is active. Install and enable a provider plugin to start a conversation; the core runs without one."
        case .modelNotOffered(let model):
            "No active provider offers model \(model.rawValue)."
        case .duplicateProvider(let provider):
            "Provider \(provider.rawValue) is already registered."
        case .duplicateModel(let model, let existing):
            "Model \(model.rawValue) is already offered by provider \(existing.rawValue)."
        }
    }
}

public actor ModelRouter {
    private var providers: [ProviderID: any ModelProvider] = [:]
    private var modelIndex: [ModelID: ProviderID] = [:]

    public init() {}

    /// Registers a provider and its models atomically: either every route is installed or none is.
    /// Conflicts are named, never resolved by overwriting someone else's route.
    public func register(provider: any ModelProvider, id: ProviderID, models: [ModelID]) throws {
        guard providers[id] == nil else { throw ModelRouterError.duplicateProvider(id) }
        var seen: Set<ModelID> = []
        for model in models {
            if let existing = modelIndex[model] {
                throw ModelRouterError.duplicateModel(model, existing: existing)
            }
            guard seen.insert(model).inserted else {
                throw ModelRouterError.duplicateModel(model, existing: id)
            }
        }
        providers[id] = provider
        for model in models {
            modelIndex[model] = id
        }
    }

    /// Removes a provider and exactly the routes it owns. Other providers are untouched; a provider
    /// that is not registered is a no-op.
    @discardableResult
    public func unregister(providerID: ProviderID) -> [ModelID] {
        guard providers.removeValue(forKey: providerID) != nil else { return [] }
        let owned = modelIndex.filter { $0.value == providerID }.map(\.key)
        for model in owned {
            modelIndex.removeValue(forKey: model)
        }
        return owned.sorted { $0.rawValue < $1.rawValue }
    }

    public func providerIDs() -> [ProviderID] {
        providers.keys.sorted { $0.rawValue < $1.rawValue }
    }

    public func models(providerID: ProviderID) -> [ModelID] {
        modelIndex.filter { $0.value == providerID }.map(\.key).sorted { $0.rawValue < $1.rawValue }
    }

    public var providerCount: Int { providers.count }
    public var offeredModels: [ModelID] { Array(modelIndex.keys) }

    public func resolve(model: ModelID) throws -> any ModelProvider {
        guard !providers.isEmpty else { throw ModelRouterError.noProviderRegistered }
        guard let providerID = modelIndex[model], let provider = providers[providerID] else {
            throw ModelRouterError.modelNotOffered(model)
        }
        return provider
    }
}

public extension ModelRouter {
    /// The loop asks for capabilities without exposing which vendor supplies them.
    func capabilities(for model: ModelID) throws -> ModelCapabilities {
        try resolve(model: model).capabilities
    }
}
