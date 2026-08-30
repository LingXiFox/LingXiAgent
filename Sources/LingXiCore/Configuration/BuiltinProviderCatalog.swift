import Foundation

public enum BuiltinProviderCategory: String, Sendable, Equatable, Codable {
    case modelProvider, gateway, aggregator, localRuntime, codingPlan
}

public enum BuiltinProviderStatus: String, Sendable, Equatable, Codable {
    case declared, unsupported, unverified, requiresAdapterOrAuthImplementation
}

public struct BuiltinProviderDefinition: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let category: BuiltinProviderCategory
    public let defaultBaseURL: URL?
    public let endpointEditable: Bool
    public let supportedWires: [StoredProviderWireProtocol]
    public let status: BuiltinProviderStatus
    public let officialSources: [URL]

    public init(
        id: String,
        displayName: String,
        category: BuiltinProviderCategory,
        defaultBaseURL: URL? = nil,
        endpointEditable: Bool = false,
        supportedWires: [StoredProviderWireProtocol] = [],
        status: BuiltinProviderStatus = .unverified,
        officialSources: [URL] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.defaultBaseURL = defaultBaseURL
        self.endpointEditable = endpointEditable
        self.supportedWires = supportedWires
        self.status = status
        self.officialSources = officialSources
    }
}

/// Product-owned definitions only. User accounts and credentials are persisted separately.
public enum BuiltinProviderCatalog {
    public static let definitions: [BuiltinProviderDefinition] = [
        .init(id: "anthropic", displayName: "Anthropic", category: .modelProvider, status: .unverified),
        .init(id: "cloudflare-ai-gateway", displayName: "Cloudflare AI Gateway", category: .gateway, status: .unverified),
        .init(id: "deepseek", displayName: "DeepSeek", category: .modelProvider, status: .unverified),
        .init(id: "hugging-face", displayName: "Hugging Face", category: .modelProvider, status: .unverified),
        .init(id: "llama-cpp", displayName: "llama.cpp", category: .localRuntime, status: .unverified),
        .init(id: "lm-studio", displayName: "LM Studio", category: .localRuntime, status: .unverified),
        .init(id: "minimax", displayName: "MiniMax", category: .modelProvider, status: .unverified),
        .init(id: "ollama", displayName: "Ollama", category: .localRuntime, status: .unverified),
        .init(id: "ollama-cloud", displayName: "Ollama Cloud", category: .modelProvider, status: .unverified),
        .init(id: "openai", displayName: "OpenAI / Codex OAuth", category: .modelProvider, status: .unverified),
        .init(id: "gemini", displayName: "Gemini / OAuth", category: .modelProvider, status: .unverified),
        .init(id: "antigravity", displayName: "Antigravity / OAuth", category: .modelProvider, status: .unsupported),
        .init(id: "opencode-zen", displayName: "OpenCode Zen", category: .aggregator, status: .unverified),
        .init(id: "opencode-go", displayName: "OpenCode Go", category: .aggregator, status: .unverified),
        .init(id: "openrouter", displayName: "OpenRouter", category: .aggregator, status: .unverified),
        .init(id: "xai", displayName: "xAI", category: .modelProvider, status: .unverified),
        .init(id: "z-ai", displayName: "Z.AI", category: .modelProvider, status: .unverified),
        .init(id: "zhipu-coding-plan", displayName: "Zhi Pu Coding Plan", category: .codingPlan, status: .unverified),
        .init(id: "mimo-api", displayName: "MIMO API", category: .modelProvider, status: .unverified),
        .init(id: "mimo-coding-plan", displayName: "MIMO Coding Plan", category: .codingPlan, status: .unverified),
        .init(id: "alibaba-bailian", displayName: "Alibaba Bailian", category: .modelProvider, status: .unverified),
        .init(id: "qwen-coding-plan", displayName: "Qwen Coding Plan", category: .codingPlan, status: .unverified),
    ]

    public static func definition(id: String) -> BuiltinProviderDefinition? {
        definitions.first { $0.id == id }
    }
}
