import Foundation
import LingXiProtocol

/// Unified access point for built-in provider product specifications and metadata.
/// Backed entirely by `ProviderRegistry.shared` and the modular product/binding definitions.
public enum BuiltinProviderCatalog {
    public static var definitions: [ProviderProductDefinition] {
        ProviderRegistry.shared.legacyDefinitions()
    }

    public static func definition(id: String) -> ProviderProductDefinition? {
        ProviderRegistry.shared.legacyDefinition(id: id)
    }

    public static func connectableProducts() -> [ProviderProductSummary] {
        ProviderRegistry.shared.connectableProducts()
    }

    // MARK: - Product Metadata

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

        public var activeRequestProfile: OverlayRequestProfile? {
            guard let requestProfileID else { return nil }
            return requestProfiles[requestProfileID]
        }

        public func registryProduct(definition: ProviderProductDefinition) -> RegistryProduct {
            RegistryProduct(
                id: definition.id.rawValue,
                vendorID: definition.vendorID.rawValue,
                displayName: definition.displayName,
                type: definition.type.rawValue,
                authStrategy: discovery == .authenticatedRemote ? "oauth" : "apiKey",
                authMethods: definition.accountTypes.map(\.rawValue),
                protocolFamily: BuiltinProviderCatalog.protocolFamily(for: definition),
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
    }

    public static func metadata(for productID: String) -> ProductMetadata {
        guard let product = ProviderRegistry.shared.product(id: productID) else {
            return ProductMetadata(discovery: .staticCatalog)
        }

        let strategy: ModelDiscoveryStrategy = {
            if product.credentialKind == "oauth" || product.credentialKind == "subscriptionKey" {
                return .authenticatedRemote
            }
            switch product.discoveryStrategy {
            case "openaiModels", "anthropicModels", "geminiModels", "openrouterModels", "ollamaTags":
                return .endpoint
            case "codexAuthenticatedCatalog", "openaiCodexBackend", "antigravityAuthenticatedCatalog", "antigravityFetchAvailableModels":
                return .authenticatedRemote
            default:
                if product.spec.distribution.cn == "default" || product.spec.distribution.global == "default" {
                    return .endpoint
                }
                return .staticCatalog
            }
        }()

        let discoveryProfile: RegistryDiscoveryProfile? = {
            switch productID {
            case "anthropic-api":
                return RegistryDiscoveryProfile(id: "anthropic-api-models", kind: "anthropic-models", url: "https://api.anthropic.com/v1/models", auth: "apiKeyHeader", headers: ["anthropic-version": "2023-06-01"])
            case "openai-api":
                return RegistryDiscoveryProfile(id: "openai-api-models", kind: "openai-models", url: "https://api.openai.com/v1/models", auth: "bearer")
            case "deepseek-api":
                return RegistryDiscoveryProfile(id: "deepseek-api-models", kind: "openai-models", url: "https://api.deepseek.com/models", auth: "bearer")
            case "gemini-api":
                return RegistryDiscoveryProfile(id: "gemini-api-models", kind: "gemini-models", url: "https://generativelanguage.googleapis.com/v1beta/models", auth: "apiKeyQuery", authKeyParam: "key")
            case "openrouter":
                return RegistryDiscoveryProfile(id: "openrouter-public", kind: "openrouter-models", url: "https://openrouter.ai/api/v1/models", auth: "none", isPublic: true)
            case "ollama-local":
                return RegistryDiscoveryProfile(id: "ollama-local-tags", kind: "ollama-tags", url: "http://localhost:11434/api/tags", auth: "none")
            case "ollama-cloud":
                return RegistryDiscoveryProfile(id: "ollama-cloud-public", kind: "ollama-tags", url: "https://ollama.com/api/tags", auth: "none", isPublic: true)
            case "llama-cpp-local":
                return RegistryDiscoveryProfile(id: "llama-cpp-local-models", kind: "openai-models", url: "http://localhost:8080/v1/models", auth: "none")
            case "lm-studio-local":
                return RegistryDiscoveryProfile(id: "lm-studio-local-models", kind: "openai-models", url: "http://localhost:1234/v1/models", auth: "none")
            case "xai-api":
                return RegistryDiscoveryProfile(id: "xai-api-models", kind: "openai-models", url: "https://api.x.ai/v1/models", auth: "bearer")
            case "minimax-api":
                return RegistryDiscoveryProfile(id: "minimax-api-models", kind: "openai-models", url: "https://api.minimax.io/v1/models", auth: "bearer")
            case "alibaba-bailian-api":
                return RegistryDiscoveryProfile(id: "alibaba-bailian-models", kind: "openai-models", url: "https://dashscope.aliyuncs.com/compatible-mode/v1/models", auth: "bearer")
            default:
                // No public discovery endpoint for zai-api, zhipu-coding-plan, cloudflare-ai-gateway, etc.
                return nil
            }
        }()

        let oauthConfig: OverlayOAuth? = {
            guard let oauthSpec = product.spec.oauth else { return nil }
            return OverlayOAuth(
                provider: product.vendorID,
                clientID: oauthSpec.clientID ?? "lingxiagent-client",
                authURL: oauthSpec.authURL,
                tokenURL: oauthSpec.tokenURL,
                scopes: oauthSpec.scopes,
                usePKCE: true,
                requestProfileID: "\(productID)@2026-09",
                redirectURI: oauthSpec.redirectURI ?? "http://localhost:1455/auth/callback"
            )
        }()

        let discoveryImplementation: DiscoveryImplementation? = {
            if productID == "openai-codex" {
                return DiscoveryImplementation(status: "implemented", backend: "codexAuthenticatedCatalog")
            }
            if productID == "antigravity" {
                return DiscoveryImplementation(status: "implemented", backend: "antigravityAuthenticatedCatalog")
            }
            if productID == "gemini-code-assist" {
                return DiscoveryImplementation(status: "missing", backend: "googleCodeAssistCatalog")
            }
            return nil
        }()

        let requestProfiles: [String: OverlayRequestProfile] = {
            switch productID {
            case "antigravity":
                return [
                    "antigravity@2026-09": OverlayRequestProfile(
                        id: "antigravity@2026-09",
                        version: "2026-09",
                        compatibilityMode: "officialLike",
                        endpointOverride: "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
                        requiredHeaders: ClientFingerprint.headers(for: "antigravity"),
                        userAgentProfile: ClientFingerprint.userAgent(for: "antigravity")
                    )
                ]
            case "gemini-code-assist":
                return [
                    "gemini-code-assist@2026-09": OverlayRequestProfile(
                        id: "gemini-code-assist@2026-09",
                        version: "2026-09",
                        compatibilityMode: "officialLike",
                        requiredHeaders: ClientFingerprint.headers(for: "gemini-code-assist"),
                        userAgentProfile: ClientFingerprint.userAgent(for: "gemini-code-assist")
                    )
                ]
            case "openai-codex":
                return [
                    "openai-codex@2026-09": OverlayRequestProfile(
                        id: "openai-codex@2026-09",
                        version: "2026-09",
                        compatibilityMode: "officialLike",
                        endpointOverride: "https://chatgpt.com/backend-api/codex/models?client_version=\(ClientFingerprint.codexVersion())",
                        requiredHeaders: ClientFingerprint.headers(for: "openai-codex"),
                        userAgentProfile: ClientFingerprint.userAgent(for: "openai-codex")
                    )
                ]
            case "anthropic-claude-subscription":
                return [
                    "anthropic-claude-subscription@2026-09": OverlayRequestProfile(
                        id: "anthropic-claude-subscription@2026-09",
                        version: "2026-09",
                        compatibilityMode: "officialLike",
                        requiredHeaders: ClientFingerprint.headers(for: "anthropic-claude-subscription"),
                        userAgentProfile: ClientFingerprint.userAgent(for: "anthropic-claude-subscription")
                    )
                ]
            case "xai-grok-subscription":
                return [
                    "xai-grok-subscription@2026-09": OverlayRequestProfile(
                        id: "xai-grok-subscription@2026-09",
                        version: "2026-09",
                        compatibilityMode: "officialLike",
                        requiredHeaders: ClientFingerprint.headers(for: "xai-grok-subscription"),
                        userAgentProfile: ClientFingerprint.userAgent(for: "xai-grok-subscription")
                    )
                ]
            default:
                return [:]
            }
        }()

        return ProductMetadata(
            discovery: strategy,
            discoveryProfile: discoveryProfile,
            runtimeSupport: .implemented,
            quirks: product.quirks,
            oauth: oauthConfig,
            discoveryImplementation: discoveryImplementation,
            requestProfileID: "\(productID)@2026-09",
            requestProfiles: requestProfiles,
            accountFields: product.requiredFields
        )
    }

    // MARK: - Profiles

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

    public static var profiles: [ProviderProfile] {
        ProviderRegistry.shared.allProducts().map { product in
            let meta = metadata(for: product.id)
            let def = definition(id: product.id)
            let auth = def.map(authMethods(for:)) ?? authMethods(for: product)
            let endpoint = product.binding(for: product.primaryProtocol)?.baseURL ?? ""
            return ProviderProfile(
                id: product.id,
                vendor: product.vendorID,
                displayName: product.displayName,
                protocolFamily: protocolFamily(for: product),
                endpoint: endpoint,
                authMethods: auth,
                concurrencyLimit: nil,
                quirks: product.quirks,
                modelDiscovery: meta.discovery,
                runtimeSupport: meta.runtimeSupport,
                models: []
            )
        }
    }

    public static func profile(for providerID: String) -> ProviderProfile? {
        profiles.first { $0.id == providerID }
    }

    public static func quirks(providerID: String) -> Set<String> {
        Set(ProviderRegistry.shared.quirks(for: providerID))
    }

    public static func hasQuirk(providerID: String, quirk: String) -> Bool {
        ProviderRegistry.shared.hasQuirk(productID: providerID, quirk: quirk)
    }

    public static var registryProducts: [RegistryProduct] {
        definitions.map { definition in
            metadata(for: definition.id.rawValue).registryProduct(definition: definition)
        }
    }

    public static func registryProduct(id: String) -> RegistryProduct? {
        guard let definition = definition(id: id) else { return nil }
        return metadata(for: id).registryProduct(definition: definition)
    }

    // MARK: - Internal Helpers

    public static func protocolFamily(for definition: ProviderProductDefinition) -> String {
        switch definition.endpoints.first?.wire {
        case .anthropicMessages: return "anthropic_messages"
        case .openAIResponses: return "openai_responses"
        default: return "openai_chat"
        }
    }

    public static func protocolFamily(for product: ResolvedProviderProduct) -> String {
        switch product.primaryProtocol {
        case "anthropicMessages": return "anthropic_messages"
        case "openaiResponses": return "openai_responses"
        default: return "openai_chat"
        }
    }

    public static func authMethods(for definition: ProviderProductDefinition) -> [String] {
        var methods = Set(definition.accountTypes.map(authMethodName(for:)))
        if definition.endpoints.contains(where: { $0.requestAuthentication == .none }) {
            methods.insert("none")
        }
        return Array(methods).sorted()
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

    public static func authMethods(for product: ResolvedProviderProduct) -> [String] {
        var methods = Set<String>()
        switch product.credentialKind {
        case "oauth":
            methods.insert("oauth")
        case "apiKey":
            methods.insert("apiKey")
        case "subscriptionKey":
            methods.insert("subscription")
        case "none":
            methods.insert("none")
        default:
            methods.insert("apiKey")
        }
        if product.spec.authStrategy == "none" {
            methods.insert("none")
        }
        return Array(methods).sorted()
    }
}
