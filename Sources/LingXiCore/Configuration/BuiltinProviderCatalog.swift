import Foundation
import LingXiProtocol

/// Product-owned definitions only. User accounts, credential references, model
/// overrides, and default selection are persisted separately in providers.json.
///
/// What lives here is exactly what LingXi maintains by hand: which products
/// exist, how they authenticate, which wire they speak, where their model list
/// comes from, and which compatibility quirks they need. What deliberately does
/// **not** live here is any list of model IDs — a product's models come from
/// upstream discovery or from the registry catalog, never from this file.
public enum BuiltinProviderCatalog {
    public static let definitions: [ProviderProductDefinition] = [
        product("anthropic-api", vendor: "anthropic", name: "Anthropic API", type: .cloudAPI, accounts: [.apiKey, .workloadIdentity], endpoints: [endpoint("messages", "https://api.anthropic.com", .anthropicMessages, .apiKeyHeader(name: "x-api-key"), headers: ["anthropic-version": "2023-06-01"])]),
        product("anthropic-claude-subscription", vendor: "anthropic", name: "Claude Subscription", type: .subscription, accounts: [.oauthUser, .subscription], status: .nonOfficialRunnableEvidence),
        product("cloudflare-ai-gateway", vendor: "cloudflare", name: "Cloudflare AI Gateway", type: .gateway, accounts: [.gateway, .apiKey], status: .partial),
        product("deepseek-api", vendor: "deepseek", name: "DeepSeek API", type: .cloudAPI, accounts: [.apiKey], endpoints: [endpoint("chat", "https://api.deepseek.com", .openAIChatCompletions, .bearerToken), endpoint("responses", "https://api.deepseek.com", .openAIResponses, .bearerToken), endpoint("anthropic", "https://api.deepseek.com/anthropic", .anthropicMessages, .apiKeyHeader(name: "x-api-key"), headers: ["anthropic-version": "2023-06-01"])]),
        product("hugging-face-inference", vendor: "hugging-face", name: "Hugging Face Inference Providers", type: .gateway, accounts: [.apiKey, .gateway], status: .partial),
        product("llama-cpp-local", vendor: "llama-cpp", name: "llama.cpp", type: .localRuntime, accounts: [.anonymousLocal, .localInstance, .apiKey], endpoints: [endpoint("openai", "http://localhost:8080/v1", .openAICompatible, .none), endpoint("openai-auth", "http://localhost:8080/v1", .openAICompatible, .bearerToken)]),
        product("lm-studio-local", vendor: "lm-studio", name: "LM Studio", type: .localRuntime, accounts: [.anonymousLocal, .localInstance, .apiKey], endpoints: [endpoint("openai", "http://localhost:1234/v1", .openAICompatible, .none), endpoint("openai-auth", "http://localhost:1234/v1", .openAICompatible, .bearerToken)]),
        product("minimax-api", vendor: "minimax", name: "MiniMax API", type: .cloudAPI, accounts: [.apiKey], endpoints: [endpoint("chat", "https://api.minimax.io/v1", .openAICompatible, .bearerToken)], status: .partial),
        product("minimax-token-plan", vendor: "minimax", name: "MiniMax Token Plan", type: .subscription, accounts: [.subscription], status: .partial),
        product("ollama-local", vendor: "ollama", name: "Ollama", type: .localRuntime, accounts: [.anonymousLocal, .localInstance], endpoints: [endpoint("openai", "http://localhost:11434/v1", .openAICompatible, .none, override: true)]),
        product("ollama-cloud", vendor: "ollama", name: "Ollama Cloud", type: .cloudAPI, accounts: [.apiKey], status: .partial),
        product("openai-api", vendor: "openai", name: "OpenAI API", type: .cloudAPI, accounts: [.apiKey], endpoints: [endpoint("responses", "https://api.openai.com/v1", .openAIResponses, .bearerToken), endpoint("chat", "https://api.openai.com/v1", .openAIChatCompletions, .bearerToken)]),
        product("openai-codex", vendor: "openai", name: "OpenAI Codex", type: .subscription, accounts: [.oauthUser], status: .nonOfficialRunnableEvidence),
        product("gemini-api", vendor: "google", name: "Gemini API", type: .cloudAPI, accounts: [.apiKey, .workloadIdentity], endpoints: [endpoint("openai", "https://generativelanguage.googleapis.com/v1beta/openai", .openAICompatible, .bearerToken)], status: .verified),
        product("gemini-code-assist", vendor: "google", name: "Gemini Code Assist", type: .subscription, accounts: [.oauthUser, .subscription], status: .nonOfficialRunnableEvidence),
        product("antigravity", vendor: "google", name: "Antigravity", type: .subscription, accounts: [.oauthUser], status: .nonOfficialRunnableEvidence),
        product("opencode-zen", vendor: "opencode", name: "OpenCode Zen", type: .gateway, accounts: [.gateway, .apiKey], status: .partial),
        product("opencode-go", vendor: "opencode", name: "OpenCode Go", type: .subscription, accounts: [.subscription], status: .partial),
        product("openrouter", vendor: "openrouter", name: "OpenRouter", type: .gateway, accounts: [.gateway, .apiKey], endpoints: [endpoint("chat", "https://openrouter.ai/api/v1", .openAICompatible, .bearerToken), endpoint("responses", "https://openrouter.ai/api/v1", .openAIResponses, .bearerToken)]),
        product("xai-api", vendor: "xai", name: "xAI API", type: .cloudAPI, accounts: [.apiKey], endpoints: [endpoint("responses", "https://api.x.ai/v1", .openAIResponses, .bearerToken)], status: .partial),
        product("xai-grok-subscription", vendor: "xai", name: "Grok Subscription", type: .subscription, accounts: [.oauthUser, .subscription], status: .nonOfficialRunnableEvidence),
        product("zai-api", vendor: "zai", name: "Z.AI API", type: .cloudAPI, accounts: [.apiKey], endpoints: [endpoint("chat", "https://api.z.ai/api/paas/v4", .openAICompatible, .bearerToken)], status: .partial),
        product("zhipu-coding-plan", vendor: "zai", name: "GLM Coding Plan", type: .subscription, accounts: [.subscription], status: .partial),
        product("mimo-api", vendor: "xiaomi", name: "MiMo API", type: .cloudAPI, accounts: [.apiKey], endpoints: [endpoint("chat", "https://api.xiaomimimo.com/v1", .openAICompatible, .apiKeyHeader(name: "api-key"))], status: .partial),
        product("mimo-coding-plan", vendor: "xiaomi", name: "MiMo Token Plan", type: .subscription, accounts: [.subscription], status: .partial),
        product("alibaba-bailian-api", vendor: "alibaba", name: "Alibaba Bailian API", type: .cloudAPI, accounts: [.apiKey], endpoints: [endpoint("chat", "https://dashscope.aliyuncs.com/compatible-mode/v1", .openAICompatible, .bearerToken), endpoint("responses", "https://dashscope.aliyuncs.com/compatible-mode/v1", .openAIResponses, .bearerToken)], status: .verified, requiredFields: ["region", "workspace"]),
        product("qwen-coding-plan", vendor: "alibaba", name: "Qwen Coding Plan", type: .subscription, accounts: [.subscription], status: .unverified),
    ]

    public static func definition(id: String) -> ProviderProductDefinition? {
        definitions.first { $0.id.rawValue == id }
    }

    public static func connectableProducts() -> [ProviderProductSummary] {
        definitions.filter(\.isRuntimeResolvable).map { product in
            let authentication: ProviderRequestAuthentication? = product.endpoints.first.map { endpoint in
                switch endpoint.requestAuthentication {
                case .none: .none
                case .bearerToken: .bearerToken
                case .apiKeyHeader: .apiKeyHeader
                case .oauthAccessToken: .oauthAccessToken
                case .workloadIdentityToken: .workloadIdentityToken
                case .gatewayToken: .gatewayToken
                case .customHeaderSet: .customHeaderSet
                case .providerNative: .providerNative
                }
            }
            let headerName = product.endpoints.first.flatMap { endpoint in
                if case let .apiKeyHeader(name) = endpoint.requestAuthentication { return name }
                return nil
            }
            return ProviderProductSummary(id: product.id.rawValue, displayName: product.displayName, vendorID: product.vendorID.rawValue, type: product.type, accountTypes: product.accountTypes, requestAuthentication: authentication, requestAuthenticationHeaderName: headerName, requiresCredential: authentication.map { $0 != .none } ?? false, requiresLocalEndpoint: product.type == .localRuntime, requiredAccountFields: product.requiredAccountFields, verificationStatus: product.verificationStatus, connectable: true)
        }
    }

    private static func product(_ id: String, vendor: String, name: String, type: ProviderProductType, accounts: [ProviderAccountType], endpoints: [ProviderProductEndpoint] = [], status: ProviderVerificationStatus = .verified, requiredFields: [String] = []) -> ProviderProductDefinition {
        ProviderProductDefinition(id: ProviderProductID(rawValue: id), vendorID: VendorID(rawValue: vendor), displayName: name, type: type, accountTypes: accounts, endpoints: endpoints, verificationStatus: status, requiredAccountFields: requiredFields)
    }

    public static func endpoint(_ id: String, _ baseURL: String, _ wire: ProviderWire, _ authentication: RequestAuthentication, headers: [String: String] = [:], override: Bool = true) -> ProviderProductEndpoint {
        ProviderProductEndpoint(id: ProviderEndpointID(rawValue: id), baseURL: URL(string: baseURL), wire: wire, requestAuthentication: authentication, requiredHeaders: headers, allowsEndpointOverride: override, verificationStatus: .verified)
    }

    // MARK: - Extended product metadata

    /// Everything LingXi maintains about a product beyond the endpoint table:
    /// compatibility quirks, request profiles, and where the model list comes
    /// from.
    ///
    /// This is the client-side twin of the registry's product entry. It carries
    /// no model IDs, so it cannot anchor the model list the way the previous
    /// generated catalog did.
    public struct ProductMetadata: Sendable, Equatable {
        public let discovery: ModelDiscoveryStrategy
        public let discoveryProfile: RegistryDiscoveryProfile?
        public let runtimeSupport: RuntimeSupport
        public let quirks: [String]
        public let oauth: OverlayOAuth?
        public let discoveryImplementation: DiscoveryImplementation?
        public let requestProfileID: String?
        public let requestProfiles: [String: OverlayRequestProfile]
        public let accountFields: [String]

        public init(
            discovery: ModelDiscoveryStrategy,
            discoveryProfile: RegistryDiscoveryProfile? = nil,
            runtimeSupport: RuntimeSupport = .implemented,
            quirks: [String] = [],
            oauth: OverlayOAuth? = nil,
            discoveryImplementation: DiscoveryImplementation? = nil,
            requestProfileID: String? = nil,
            requestProfiles: [String: OverlayRequestProfile] = [:],
            accountFields: [String] = []
        ) {
            self.discovery = discovery
            self.discoveryProfile = discoveryProfile
            self.runtimeSupport = runtimeSupport
            self.quirks = quirks
            self.oauth = oauth
            self.discoveryImplementation = discoveryImplementation
            self.requestProfileID = requestProfileID
            self.requestProfiles = requestProfiles
            self.accountFields = accountFields
        }

        /// The active request profile for this product, if configured.
        public var activeRequestProfile: OverlayRequestProfile? {
            guard let requestProfileID else { return nil }
            return requestProfiles[requestProfileID]
        }

        /// Builds a registry-shaped product from this metadata plus its
        /// definition, for the paths that need a `RegistryProduct` while the
        /// registry catalog is unavailable.
        public func registryProduct(definition: ProviderProductDefinition) -> RegistryProduct {
            RegistryProduct(
                id: definition.id.rawValue,
                vendorID: definition.vendorID.rawValue,
                displayName: definition.displayName,
                type: definition.type.rawValue,
                authStrategy: discovery == .authenticatedRemote ? "oauth" : "apiKey",
                authMethods: definition.accountTypes.map(\.rawValue),
                protocolFamily: Self.protocolFamily(for: definition),
                discoveryStrategy: discovery.rawValue,
                discoveryProfileID: discoveryProfile?.id,
                endpoint: definition.endpoints.first?.baseURL?.absoluteString,
                runtimeSupport: runtimeSupport.rawValue,
                quirks: quirks,
                verificationStatus: definition.verificationStatus.rawValue,
                discoveryImplementation: discoveryImplementation,
                requestProfileID: requestProfileID,
                accountFields: accountFields,
                modelIDs: [],
                discoveryProfile: discoveryProfile
            )
        }

        private static func protocolFamily(for definition: ProviderProductDefinition) -> String {
            switch definition.endpoints.first?.wire {
            case .anthropicMessages: return "anthropic_messages"
            case .openAIResponses: return "openai_responses"
            default: return "openai_chat"
            }
        }
    }

    /// Products whose metadata differs from the default. A product absent from
    /// this table is a plain API product with static metadata and no quirks.
    public static let metadataTable: [String: ProductMetadata] = [
        "anthropic-api": meta(.endpoint, profile: profile("anthropic-api-models", "anthropic-models", "https://api.anthropic.com/v1/models", auth: "apiKeyHeader", headers: ["anthropic-version": "2023-06-01"]), quirks: ["requiresAnthropicVersionHeader"], requestProfiles: ["anthropic-api@2026-09": requestProfile("anthropic-api@2026-09", headers: ["anthropic-version": "2023-06-01"])], requestProfileID: "anthropic-api@2026-09"),
        "deepseek-api": meta(.endpoint, profile: profile("deepseek-api-models", "openai-models", "https://api.deepseek.com/models", auth: "bearer"), quirks: ["statelessContinuationOnly"]),
        "openai-api": meta(.endpoint, profile: profile("openai-api-models", "openai-models", "https://api.openai.com/v1/models", auth: "bearer")),
        "gemini-api": meta(.endpoint, profile: profile("gemini-api-models", "gemini-models", "https://generativelanguage.googleapis.com/v1beta/models", auth: "apiKeyQuery", authKeyParam: "key")),
        "openrouter": meta(.endpoint, profile: profile("openrouter-public", "openrouter-models", "https://openrouter.ai/api/v1/models", auth: "none", isPublic: true)),
        "xai-api": meta(.endpoint, profile: profile("xai-api-models", "openai-models", "https://api.x.ai/v1/models", auth: "bearer"), runtime: .partial, quirks: ["statelessContinuationOnly"]),
        "zai-api": meta(.endpoint, profile: profile("zai-api-models", "openai-models", "https://api.z.ai/api/paas/v4/models", auth: "bearer"), runtime: .partial),
        "minimax-api": meta(.endpoint, profile: profile("minimax-api-models", "openai-models", "https://api.minimax.io/v1/models", auth: "bearer"), runtime: .partial),
        "alibaba-bailian-api": meta(.endpoint, profile: profile("alibaba-bailian-models", "openai-models", "https://dashscope.aliyuncs.com/compatible-mode/v1/models", auth: "bearer"), accountFields: ["region", "workspace"]),
        "ollama-cloud": meta(.endpoint, profile: profile("ollama-cloud-public", "ollama-tags", "https://ollama.com/api/tags", auth: "none", isPublic: true), runtime: .partial),
        "ollama-local": meta(.endpoint, profile: profile("ollama-local-tags", "ollama-tags", "http://localhost:11434/api/tags", auth: "none"), quirks: ["localRuntime"]),
        "llama-cpp-local": meta(.endpoint, profile: profile("llama-cpp-local-models", "openai-models", "http://localhost:8080/v1/models", auth: "none"), quirks: ["localRuntime"]),
        "lm-studio-local": meta(.endpoint, profile: profile("lm-studio-local-models", "openai-models", "http://localhost:1234/v1/models", auth: "none"), quirks: ["localRuntime"]),
        "mimo-api": meta(.custom, runtime: .partial, quirks: ["customApiKeyHeader"]),

        // OAuth products. Their model lists are resolved against the account,
        // never derived from an API product's catalog.
        "openai-codex": meta(
            .authenticatedRemote,
            runtime: .partial,
            oauth: OverlayOAuth(
                provider: "openai",
                clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
                authURL: "https://auth.openai.com/oauth/authorize",
                tokenURL: "https://auth.openai.com/oauth/token",
                scopes: ["openid", "profile", "email", "offline_access"],
                usePKCE: true,
                requestProfileID: "openai-codex@2026-09",
                redirectURI: "http://localhost:1455/auth/callback"
            ),
            discoveryImplementation: DiscoveryImplementation(status: "implemented", backend: "codexAuthenticatedCatalog"),
            requestProfiles: [
                "openai-codex@2026-09": requestProfile(
                    "openai-codex@2026-09",
                    endpointOverride: "https://chatgpt.com/backend-api/codex/models?client_version=0.154.0",
                    headers: [
                        "originator": "codex-cli",
                        "Accept": "application/json"
                    ],
                    userAgent: "codex-cli/0.154.0 (darwin; arm64)",
                    compatibilityMode: "officialLike"
                )
            ],
            requestProfileID: "openai-codex@2026-09"
        ),
        "gemini-code-assist": meta(
            .authenticatedRemote,
            runtime: .partial,
            oauth: OverlayOAuth(
                provider: "google",
                clientID: "lingxiagent-gca-client",
                authURL: "https://accounts.google.com/o/oauth2/v2/auth",
                tokenURL: "https://oauth2.googleapis.com/token",
                scopes: ["https://www.googleapis.com/auth/cloud-platform"],
                usePKCE: true,
                requestProfileID: "gemini-code-assist@2026-09"
            ),
            discoveryImplementation: DiscoveryImplementation(status: "missing", backend: "googleCodeAssistCatalog"),
            requestProfiles: ["gemini-code-assist@2026-09": requestProfile("gemini-code-assist@2026-09")],
            requestProfileID: "gemini-code-assist@2026-09"
        ),
        "antigravity": meta(
            .authenticatedRemote,
            runtime: .partial,
            discoveryImplementation: DiscoveryImplementation(status: "implemented", backend: "antigravityAuthenticatedCatalog"),
            requestProfiles: [
                "antigravity@2026-09": requestProfile(
                    "antigravity@2026-09",
                    endpointOverride: "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
                    headers: [
                        "Content-Type": "application/json",
                        "Accept": "application/json"
                    ],
                    userAgent: "antigravity/1.2.1 (darwin; arm64)",
                    compatibilityMode: "officialLike"
                )
            ],
            requestProfileID: "antigravity@2026-09"
        ),
        "anthropic-claude-subscription": meta(.authenticatedRemote, runtime: .partial, requestProfiles: ["anthropic-claude-subscription@2026-09": requestProfile("anthropic-claude-subscription@2026-09", headers: ["anthropic-version": "2023-06-01"])], requestProfileID: "anthropic-claude-subscription@2026-09"),
        "xai-grok-subscription": meta(.authenticatedRemote, runtime: .partial),
        "minimax-token-plan": meta(.authenticatedRemote, runtime: .partial),
        "zhipu-coding-plan": meta(.authenticatedRemote, runtime: .partial),
        "mimo-coding-plan": meta(.authenticatedRemote, runtime: .partial),
        "opencode-go": meta(.authenticatedRemote, runtime: .partial),
        "qwen-coding-plan": meta(.authenticatedRemote, runtime: .unsupported),

        "cloudflare-ai-gateway": meta(.custom, runtime: .partial),
        "hugging-face-inference": meta(.custom, runtime: .partial),
        "opencode-zen": meta(.custom, runtime: .partial),
    ]

    public static func metadata(for productID: String) -> ProductMetadata {
        metadataTable[productID] ?? ProductMetadata(discovery: .staticCatalog)
    }

    private static func meta(
        _ discovery: ModelDiscoveryStrategy,
        profile: RegistryDiscoveryProfile? = nil,
        runtime: RuntimeSupport = .implemented,
        quirks: [String] = [],
        oauth: OverlayOAuth? = nil,
        discoveryImplementation: DiscoveryImplementation? = nil,
        requestProfiles: [String: OverlayRequestProfile] = [:],
        requestProfileID: String? = nil,
        accountFields: [String] = []
    ) -> ProductMetadata {
        ProductMetadata(
            discovery: discovery,
            discoveryProfile: profile,
            runtimeSupport: runtime,
            quirks: quirks,
            oauth: oauth,
            discoveryImplementation: discoveryImplementation,
            requestProfileID: requestProfileID,
            requestProfiles: requestProfiles,
            accountFields: accountFields
        )
    }

    private static func profile(
        _ id: String,
        _ kind: String,
        _ url: String,
        auth: String,
        authKeyParam: String? = nil,
        headers: [String: String]? = nil,
        isPublic: Bool? = nil
    ) -> RegistryDiscoveryProfile {
        RegistryDiscoveryProfile(
            id: id, kind: kind, url: url, auth: auth,
            authKeyParam: authKeyParam, headers: headers,
            cacheTTL: "6h", isPublic: isPublic
        )
    }

    private static func requestProfile(
        _ id: String,
        endpointOverride: String? = nil,
        headers: [String: String] = [:],
        userAgent: String? = nil,
        compatibilityMode: String = "conservative"
    ) -> OverlayRequestProfile {
        OverlayRequestProfile(
            id: id,
            version: String(id.split(separator: "@").last ?? "2026-09"),
            compatibilityMode: compatibilityMode,
            endpointOverride: endpointOverride,
            requiredHeaders: headers.isEmpty ? nil : headers,
            userAgentProfile: userAgent
        )
    }

    // MARK: - Profile view

    /// A product's protocol/auth/quirk profile, as consumed by the CLI and the
    /// runtime resolver.
    ///
    /// `models` is always empty: a product's model list is discovered, never
    /// declared here. The field remains so callers that read it keep compiling
    /// against a stable shape.
    public struct ProviderProfile: Sendable, Equatable {
        public let id: String
        public let vendor: String
        public let displayName: String
        public let protocolFamily: String
        public let endpoint: String
        public let authMethods: [String]
        public let concurrencyLimit: Int?
        public let quirks: [String]
        public let modelDiscovery: ModelDiscoveryStrategy
        public let runtimeSupport: RuntimeSupport
        public let models: [ProviderModelProfile]

        public init(
            id: String,
            vendor: String,
            displayName: String,
            protocolFamily: String,
            endpoint: String,
            authMethods: [String],
            concurrencyLimit: Int? = nil,
            quirks: [String] = [],
            modelDiscovery: ModelDiscoveryStrategy = .staticCatalog,
            runtimeSupport: RuntimeSupport = .implemented,
            models: [ProviderModelProfile] = []
        ) {
            self.id = id
            self.vendor = vendor
            self.displayName = displayName
            self.protocolFamily = protocolFamily
            self.endpoint = endpoint
            self.authMethods = authMethods
            self.concurrencyLimit = concurrencyLimit
            self.quirks = quirks
            self.modelDiscovery = modelDiscovery
            self.runtimeSupport = runtimeSupport
            self.models = models
        }
    }

    public struct ProviderModelProfile: Sendable, Equatable {
        public let id: String
        public let displayName: String
        public let toolCall: Bool
        public let vision: Bool
        public let cache: Bool
        public let contextWindow: Int?
        public let maxOutputTokens: Int?
        public let reasoningCapability: ReasoningCapability?

        public init(
            id: String,
            displayName: String,
            toolCall: Bool = true,
            vision: Bool = false,
            cache: Bool = false,
            contextWindow: Int? = nil,
            maxOutputTokens: Int? = nil,
            reasoningCapability: ReasoningCapability? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.toolCall = toolCall
            self.vision = vision
            self.cache = cache
            self.contextWindow = contextWindow
            self.maxOutputTokens = maxOutputTokens
            self.reasoningCapability = reasoningCapability
        }
    }

    public static let profiles: [ProviderProfile] = definitions.map { definition in
        let id = definition.id.rawValue
        let metadata = metadata(for: id)
        return ProviderProfile(
            id: id,
            vendor: definition.vendorID.rawValue,
            displayName: definition.displayName,
            protocolFamily: protocolFamily(for: definition),
            endpoint: definition.endpoints.first?.baseURL?.absoluteString ?? "",
            authMethods: authMethods(for: definition),
            concurrencyLimit: nil,
            quirks: metadata.quirks,
            modelDiscovery: metadata.discovery,
            runtimeSupport: metadata.runtimeSupport,
            models: []
        )
    }

    /// The authentication methods a product exposes, in the vocabulary callers
    /// actually branch on (`"oauth"`, `"apiKey"`, `"none"`, …).
    ///
    /// Account types are the source, but their raw names are not the answer:
    /// an `oauthUser` account means the product authenticates with OAuth, and an
    /// `anonymousLocal` account means it accepts unauthenticated requests. A
    /// product whose endpoint also declares `.none` advertises it explicitly, so
    /// a local runtime is distinguishable from one that always demands a
    /// credential.
    static func authMethods(for definition: ProviderProductDefinition) -> [String] {
        var methods = Set(definition.accountTypes.map(authMethodName(for:)))
        if definition.endpoints.contains(where: { $0.requestAuthentication == .none }) {
            methods.insert("none")
        }
        return methods.sorted()
    }

    private static func authMethodName(for accountType: ProviderAccountType) -> String {
        switch accountType {
        case .oauthUser: return "oauth"
        case .apiKey: return "apiKey"
        case .subscription: return "subscription"
        case .workloadIdentity: return "workloadIdentity"
        case .gateway: return "gateway"
        case .localInstance: return "localInstance"
        case .anonymousLocal: return "none"
        }
    }

    public static func profile(for providerID: String) -> ProviderProfile? {
        profiles.first { $0.id == providerID }
    }

    public static func quirks(providerID: String) -> Set<String> {
        Set(metadata(for: providerID).quirks)
    }

    public static func hasQuirk(providerID: String, quirk: String) -> Bool {
        quirks(providerID: providerID).contains(quirk)
    }

    static func protocolFamily(for definition: ProviderProductDefinition) -> String {
        switch definition.endpoints.first?.wire {
        case .anthropicMessages: return "anthropic_messages"
        case .openAIResponses: return "openai_responses"
        default: return "openai_chat"
        }
    }

    // MARK: - Registry-shaped view

    /// The built-in products rendered as registry products, used when the
    /// registry catalog cannot be reached. Carries no model IDs.
    public static var registryProducts: [RegistryProduct] {
        definitions.map { definition in
            metadata(for: definition.id.rawValue).registryProduct(definition: definition)
        }
    }

    public static func registryProduct(id: String) -> RegistryProduct? {
        guard let definition = definition(id: id) else { return nil }
        return metadata(for: id).registryProduct(definition: definition)
    }
}
