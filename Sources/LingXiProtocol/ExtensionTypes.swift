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
    public let summary: String?

    public init(
        id: String,
        version: String,
        kind: ExtensionKind,
        scope: String,
        enabled: Bool,
        lifecycleState: String,
        summary: String? = nil
    ) {
        self.id = id
        self.version = version
        self.kind = kind
        self.scope = scope
        self.enabled = enabled
        self.lifecycleState = lifecycleState
        self.summary = summary
    }
}

public struct ExecuteExtensionCommandRequest: Sendable, Equatable, Codable {
    public let name: String
    public let arguments: [String]
    public let sessionID: String?

    public init(name: String, arguments: [String] = [], sessionID: String? = nil) {
        self.name = name
        self.arguments = arguments
        self.sessionID = sessionID
    }
}

public struct ExtensionCommandExecutionResult: Sendable, Equatable, Codable {
    public let name: String
    public let output: String
    public let isPrompt: Bool
    public let presentation: String
    public let title: String?

    public init(name: String, output: String, isPrompt: Bool, presentation: String = "modal", title: String? = nil) {
        self.name = name
        self.output = output
        self.isPrompt = isPrompt
        self.presentation = presentation
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case name
        case output
        case isPrompt
        case presentation
        case title
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.output = try container.decode(String.self, forKey: .output)
        self.isPrompt = try container.decode(Bool.self, forKey: .isPrompt)
        self.presentation = try container.decodeIfPresent(String.self, forKey: .presentation) ?? "modal"
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
    }
}


