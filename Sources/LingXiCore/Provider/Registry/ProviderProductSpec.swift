import Foundation
import LingXiProtocol

/// Raw specification deserialized from product JSON files under `Provider/Products/`.
public struct ProviderProductSpec: Codable, Sendable, Equatable {
    public struct Distribution: Codable, Sendable, Equatable {
        public let cn: String
        public let global: String

        public init(cn: String, global: String) {
            self.cn = cn
            self.global = global
        }
    }

    public struct OAuthSpec: Codable, Sendable, Equatable {
        public let authURL: String
        public let tokenURL: String
        public let scopes: [String]
        public let clientID: String?
        public let redirectURI: String?

        public init(
            authURL: String,
            tokenURL: String,
            scopes: [String],
            clientID: String? = nil,
            redirectURI: String? = nil
        ) {
            self.authURL = authURL
            self.tokenURL = tokenURL
            self.scopes = scopes
            self.clientID = clientID
            self.redirectURI = redirectURI
        }
    }

    public let id: String
    public let vendor: String
    public let displayName: String
    public let credentialKind: String
    public let authStrategy: String
    public let discoveryStrategy: String
    public let distribution: Distribution
    public let protocolBindings: [String]
    public let defaultProtocol: String?
    public let requiredFields: [String]?
    public let quirks: [String]?
    public let oauth: OAuthSpec?

    public init(
        id: String,
        vendor: String,
        displayName: String,
        credentialKind: String,
        authStrategy: String,
        discoveryStrategy: String,
        distribution: Distribution,
        protocolBindings: [String],
        defaultProtocol: String? = nil,
        requiredFields: [String]? = nil,
        quirks: [String]? = nil,
        oauth: OAuthSpec? = nil
    ) {
        self.id = id
        self.vendor = vendor
        self.displayName = displayName
        self.credentialKind = credentialKind
        self.authStrategy = authStrategy
        self.discoveryStrategy = discoveryStrategy
        self.distribution = distribution
        self.protocolBindings = protocolBindings
        self.defaultProtocol = defaultProtocol
        self.requiredFields = requiredFields
        self.quirks = quirks
        self.oauth = oauth
    }
}

/// Raw specification deserialized from protocol binding JSON files under `Provider/Protocols/<Protocol>/Bindings/`.
public struct ProviderProtocolBindingSpec: Codable, Sendable, Equatable {
    public let productID: String
    public let `protocol`: String
    public let baseURL: String
    public let path: String
    public let quirks: [String]
    public let defaultHeaders: [String: String]?

    public init(
        productID: String,
        protocol: String,
        baseURL: String,
        path: String,
        quirks: [String] = [],
        defaultHeaders: [String: String]? = nil
    ) {
        self.productID = productID
        self.protocol = `protocol`
        self.baseURL = baseURL
        self.path = path
        self.quirks = quirks
        self.defaultHeaders = defaultHeaders
    }
}

/// Fully resolved provider product combining product metadata with all available protocol bindings.
public struct ResolvedProviderProduct: Sendable, Equatable {
    public let spec: ProviderProductSpec
    public let bindings: [String: ProviderProtocolBindingSpec]

    public var id: String { spec.id }
    public var vendorID: String { spec.vendor }
    public var displayName: String { spec.displayName }
    public var credentialKind: String { spec.credentialKind }
    public var authStrategy: String { spec.authStrategy }
    public var discoveryStrategy: String { spec.discoveryStrategy }
    public var supportedProtocols: [String] { spec.protocolBindings }
    public var primaryProtocol: String {
        spec.defaultProtocol ?? spec.protocolBindings.first ?? "openaiChat"
    }
    public var requiredFields: [String] { spec.requiredFields ?? [] }
    public var quirks: [String] {
        var set = Set(spec.quirks ?? [])
        for binding in bindings.values {
            set.formUnion(binding.quirks)
        }
        return Array(set).sorted()
    }

    public init(spec: ProviderProductSpec, bindings: [String: ProviderProtocolBindingSpec] = [:]) {
        self.spec = spec
        self.bindings = bindings
    }

    public func binding(for protocolName: String) -> ProviderProtocolBindingSpec? {
        bindings[protocolName]
    }

    /// Checks if this product has no public upstream model discovery endpoint
    /// (e.g. zai-api, zhipu-coding-plan, cloudflare-ai-gateway, qwen-coding-plan, etc.)
    public var hasNoPublicDiscoveryEndpoint: Bool {
        discoveryStrategy == "noModelDiscovery" || discoveryStrategy == "none" || discoveryStrategy == "unsupported"
    }

    /// Translates to legacy ProviderProductDefinition for backward compatibility during phased rollout.
    public func toLegacyDefinition() -> ProviderProductDefinition {
        func ep(_ id: String, _ url: String, _ wire: ProviderWire, _ auth: RequestAuthentication, headers: [String: String] = [:]) -> ProviderProductEndpoint {
            ProviderProductEndpoint(
                id: ProviderEndpointID(rawValue: id),
                baseURL: URL(string: url),
                wire: wire,
                requestAuthentication: auth,
                requiredHeaders: headers,
                allowsEndpointOverride: true,
                verificationStatus: .verified
            )
        }

        switch spec.id {
        case "anthropic-api":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .cloudAPI, accountTypes: [.apiKey, .workloadIdentity], endpoints: [ep("messages", "https://api.anthropic.com", .anthropicMessages, .apiKeyHeader(name: "x-api-key"), headers: ["anthropic-version": "2023-06-01"])], verificationStatus: .verified)
        case "anthropic-claude-subscription":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .subscription, accountTypes: [.oauthUser, .subscription], endpoints: [], verificationStatus: .nonOfficialRunnableEvidence)
        case "cloudflare-ai-gateway":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .gateway, accountTypes: [.gateway, .apiKey], endpoints: [], verificationStatus: .partial)
        case "deepseek-api":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .cloudAPI, accountTypes: [.apiKey], endpoints: [ep("chat", "https://api.deepseek.com", .openAIChatCompletions, .bearerToken), ep("responses", "https://api.deepseek.com", .openAIResponses, .bearerToken), ep("anthropic", "https://api.deepseek.com/anthropic", .anthropicMessages, .apiKeyHeader(name: "x-api-key"), headers: ["anthropic-version": "2023-06-01"])], verificationStatus: .verified)
        case "hugging-face-inference":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .gateway, accountTypes: [.apiKey, .gateway], endpoints: [], verificationStatus: .partial)
        case "llama-cpp-local":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .localRuntime, accountTypes: [.anonymousLocal, .localInstance, .apiKey], endpoints: [ep("openai", "http://localhost:8080/v1", .openAICompatible, .none), ep("openai-auth", "http://localhost:8080/v1", .openAICompatible, .bearerToken)], verificationStatus: .verified)
        case "lm-studio-local":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .localRuntime, accountTypes: [.anonymousLocal, .localInstance, .apiKey], endpoints: [ep("openai", "http://localhost:1234/v1", .openAICompatible, .none), ep("openai-auth", "http://localhost:1234/v1", .openAICompatible, .bearerToken)], verificationStatus: .verified)
        case "minimax-api":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .cloudAPI, accountTypes: [.apiKey], endpoints: [ep("chat", "https://api.minimax.io/v1", .openAICompatible, .bearerToken)], verificationStatus: .partial)
        case "minimax-token-plan":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .subscription, accountTypes: [.subscription], endpoints: [], verificationStatus: .partial)
        case "ollama-local":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .localRuntime, accountTypes: [.anonymousLocal, .localInstance], endpoints: [ep("openai", "http://localhost:11434/v1", .openAICompatible, .none)], verificationStatus: .verified)
        case "ollama-cloud":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .cloudAPI, accountTypes: [.apiKey], endpoints: [], verificationStatus: .partial)
        case "openai-api":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .cloudAPI, accountTypes: [.apiKey], endpoints: [ep("responses", "https://api.openai.com/v1", .openAIResponses, .bearerToken), ep("chat", "https://api.openai.com/v1", .openAIChatCompletions, .bearerToken)], verificationStatus: .verified)
        case "openai-codex":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .subscription, accountTypes: [.oauthUser], endpoints: [], verificationStatus: .nonOfficialRunnableEvidence)
        case "gemini-api":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .cloudAPI, accountTypes: [.apiKey, .workloadIdentity], endpoints: [ep("openai", "https://generativelanguage.googleapis.com/v1beta/openai", .openAICompatible, .bearerToken)], verificationStatus: .verified)
        case "gemini-code-assist":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .subscription, accountTypes: [.oauthUser, .subscription], endpoints: [], verificationStatus: .nonOfficialRunnableEvidence)
        case "antigravity":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .subscription, accountTypes: [.oauthUser], endpoints: [], verificationStatus: .nonOfficialRunnableEvidence)
        case "opencode-zen":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .gateway, accountTypes: [.gateway, .apiKey], endpoints: [], verificationStatus: .partial)
        case "opencode-go":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .subscription, accountTypes: [.subscription], endpoints: [], verificationStatus: .partial)
        case "openrouter":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .gateway, accountTypes: [.gateway, .apiKey], endpoints: [ep("chat", "https://openrouter.ai/api/v1", .openAICompatible, .bearerToken), ep("responses", "https://openrouter.ai/api/v1", .openAIResponses, .bearerToken)], verificationStatus: .verified)
        case "xai-api":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .cloudAPI, accountTypes: [.apiKey], endpoints: [ep("responses", "https://api.x.ai/v1", .openAIResponses, .bearerToken)], verificationStatus: .partial)
        case "xai-grok-subscription":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .subscription, accountTypes: [.oauthUser, .subscription], endpoints: [], verificationStatus: .nonOfficialRunnableEvidence)
        case "zai-api":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .cloudAPI, accountTypes: [.apiKey], endpoints: [ep("chat", "https://api.z.ai/api/paas/v4", .openAICompatible, .bearerToken)], verificationStatus: .partial)
        case "zhipu-coding-plan":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .subscription, accountTypes: [.subscription], endpoints: [], verificationStatus: .partial)
        case "mimo-api":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .cloudAPI, accountTypes: [.apiKey], endpoints: [ep("chat", "https://api.xiaomimimo.com/v1", .openAICompatible, .apiKeyHeader(name: "api-key"))], verificationStatus: .partial)
        case "mimo-coding-plan":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .subscription, accountTypes: [.subscription], endpoints: [], verificationStatus: .partial)
        case "alibaba-bailian-api":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .cloudAPI, accountTypes: [.apiKey], endpoints: [ep("chat", "https://dashscope.aliyuncs.com/compatible-mode/v1", .openAICompatible, .bearerToken), ep("responses", "https://dashscope.aliyuncs.com/compatible-mode/v1", .openAIResponses, .bearerToken)], verificationStatus: .verified, requiredAccountFields: ["region", "workspace"])
        case "qwen-coding-plan":
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .subscription, accountTypes: [.subscription], endpoints: [], verificationStatus: .unverified)
        default:
            return ProviderProductDefinition(id: ProviderProductID(rawValue: spec.id), vendorID: VendorID(rawValue: spec.vendor), displayName: spec.displayName, type: .cloudAPI, accountTypes: [.apiKey], endpoints: [], verificationStatus: .verified)
        }
    }
}
