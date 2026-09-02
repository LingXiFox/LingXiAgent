public enum ExtensionKind: String, Sendable, Equatable, Codable, CaseIterable {
    case skill, command, hook, plugin, mcp
}

public struct ExtensionInfo: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let version: String
    public let kind: ExtensionKind
    public let scope: String
    public let enabled: Bool
    public let lifecycleState: String

    public init(id: String, version: String, kind: ExtensionKind, scope: String, enabled: Bool, lifecycleState: String) {
        self.id = id
        self.version = version
        self.kind = kind
        self.scope = scope
        self.enabled = enabled
        self.lifecycleState = lifecycleState
    }
}
