import Foundation

/// Runtime 健康状态。
public enum RuntimeHealthStatus: String, Codable, Sendable, Equatable {
    case healthy
    case degraded
    case unhealthy
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = RuntimeHealthStatus(rawValue: raw) ?? .unknown
    }
}

/// Runtime 健康指标。
public struct RuntimeHealth: Codable, Sendable, Equatable {
    public let status: RuntimeHealthStatus
    public let activeSessions: Int
    public let activeRuns: Int
    public let uptimeSeconds: Double
    public let details: [String: String]

    public init(
        status: RuntimeHealthStatus = .healthy,
        activeSessions: Int = 0,
        activeRuns: Int = 0,
        uptimeSeconds: Double = 0,
        details: [String: String] = [:]
    ) {
        self.status = status
        self.activeSessions = activeSessions
        self.activeRuns = activeRuns
        self.uptimeSeconds = uptimeSeconds
        self.details = details
    }
}

/// Runtime 能力特性协商。
public struct RuntimeCapabilities: Codable, Sendable, Equatable {
    public let supportsStreamReplay: Bool
    public let supportsContentUpload: Bool
    public let maxAttachmentBytes: Int
    public let supportedModes: [AgentMode]

    public init(
        supportsStreamReplay: Bool = true,
        supportsContentUpload: Bool = true,
        maxAttachmentBytes: Int = 100 * 1024 * 1024,
        supportedModes: [AgentMode] = [.build, .plan, .explore]
    ) {
        self.supportsStreamReplay = supportsStreamReplay
        self.supportsContentUpload = supportsContentUpload
        self.maxAttachmentBytes = maxAttachmentBytes
        self.supportedModes = supportedModes
    }
}

/// Runtime 实例基本信息。
public struct RuntimeInfo: Codable, Sendable, Equatable {
    public let instanceID: RuntimeInstanceID
    public let name: String
    public let version: String
    public let protocolVersion: ProtocolVersion
    public let startedAt: Date

    public init(
        instanceID: RuntimeInstanceID = RuntimeInstanceID(),
        name: String = "LingXiCore",
        version: String = "0.1.0",
        protocolVersion: ProtocolVersion = .current,
        startedAt: Date = Date()
    ) {
        self.instanceID = instanceID
        self.name = name
        self.version = version
        self.protocolVersion = protocolVersion
        self.startedAt = startedAt
    }
}

/// Extension 状态。
public struct ExtensionStatus: Codable, Sendable, Equatable {
    public let extensionID: String
    public let enabled: Bool
    public let state: String

    public init(extensionID: String, enabled: Bool, state: String) {
        self.extensionID = extensionID
        self.enabled = enabled
        self.state = state
    }
}

/// Session 摘要（Runtime 视图）。
public struct SessionSummary: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let title: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let turnCount: Int
    public let mode: AgentMode
    public let reasoningEffort: ReasoningEffort

    public init(
        sessionID: SessionID,
        title: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        turnCount: Int = 0,
        mode: AgentMode = .build,
        reasoningEffort: ReasoningEffort = .auto
    ) {
        self.sessionID = sessionID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turnCount = turnCount
        self.mode = mode
        self.reasoningEffort = reasoningEffort
    }
}

/// RuntimeEventPayload：全生命周期、非 Session 专属的事件。
public enum RuntimeEventPayload: Codable, Sendable, Equatable {
    case runtimeHealthChanged(RuntimeHealth)
    case runtimeCapabilitiesChanged(RuntimeCapabilities)
    case sessionCreated(SessionSummary)
    case sessionUpdated(SessionSummary)
    case sessionDeleted(SessionID)
    case providerCatalogChanged
    case providerStatusChanged(ProviderStatus)
    case modelCatalogChanged
    case extensionCatalogChanged
    case extensionStatusChanged(ExtensionStatus)
    case globalConfigurationChanged
    case unknown(String)

    private enum CodingKeys: String, CodingKey {
        case kind, health, capabilities, session, sessionID, providerStatus, extensionStatus, rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "runtimeHealthChanged":
            self = .runtimeHealthChanged(try container.decode(RuntimeHealth.self, forKey: .health))
        case "runtimeCapabilitiesChanged":
            self = .runtimeCapabilitiesChanged(try container.decode(RuntimeCapabilities.self, forKey: .capabilities))
        case "sessionCreated":
            self = .sessionCreated(try container.decode(SessionSummary.self, forKey: .session))
        case "sessionUpdated":
            self = .sessionUpdated(try container.decode(SessionSummary.self, forKey: .session))
        case "sessionDeleted":
            self = .sessionDeleted(try container.decode(SessionID.self, forKey: .sessionID))
        case "providerCatalogChanged":
            self = .providerCatalogChanged
        case "providerStatusChanged":
            self = .providerStatusChanged(try container.decode(ProviderStatus.self, forKey: .providerStatus))
        case "modelCatalogChanged":
            self = .modelCatalogChanged
        case "extensionCatalogChanged":
            self = .extensionCatalogChanged
        case "extensionStatusChanged":
            self = .extensionStatusChanged(try container.decode(ExtensionStatus.self, forKey: .extensionStatus))
        case "globalConfigurationChanged":
            self = .globalConfigurationChanged
        default:
            let raw = (try? container.decode(String.self, forKey: .rawValue)) ?? kind
            self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .runtimeHealthChanged(health):
            try container.encode("runtimeHealthChanged", forKey: .kind)
            try container.encode(health, forKey: .health)
        case let .runtimeCapabilitiesChanged(capabilities):
            try container.encode("runtimeCapabilitiesChanged", forKey: .kind)
            try container.encode(capabilities, forKey: .capabilities)
        case let .sessionCreated(session):
            try container.encode("sessionCreated", forKey: .kind)
            try container.encode(session, forKey: .session)
        case let .sessionUpdated(session):
            try container.encode("sessionUpdated", forKey: .kind)
            try container.encode(session, forKey: .session)
        case let .sessionDeleted(sessionID):
            try container.encode("sessionDeleted", forKey: .kind)
            try container.encode(sessionID, forKey: .sessionID)
        case .providerCatalogChanged:
            try container.encode("providerCatalogChanged", forKey: .kind)
        case let .providerStatusChanged(status):
            try container.encode("providerStatusChanged", forKey: .kind)
            try container.encode(status, forKey: .providerStatus)
        case .modelCatalogChanged:
            try container.encode("modelCatalogChanged", forKey: .kind)
        case .extensionCatalogChanged:
            try container.encode("extensionCatalogChanged", forKey: .kind)
        case let .extensionStatusChanged(status):
            try container.encode("extensionStatusChanged", forKey: .kind)
            try container.encode(status, forKey: .extensionStatus)
        case .globalConfigurationChanged:
            try container.encode("globalConfigurationChanged", forKey: .kind)
        case let .unknown(raw):
            try container.encode("unknown", forKey: .kind)
            try container.encode(raw, forKey: .rawValue)
        }
    }
}

/// RuntimeEventEnvelope：Runtime 级别事件封装，携带持久化 EventCursor。
public struct RuntimeEventEnvelope: Codable, Sendable, Equatable {
    public let cursor: EventCursor
    public let timestamp: Date
    public let payload: RuntimeEventPayload

    public init(cursor: EventCursor, timestamp: Date = Date(), payload: RuntimeEventPayload) {
        self.cursor = cursor
        self.timestamp = timestamp
        self.payload = payload
    }
}
