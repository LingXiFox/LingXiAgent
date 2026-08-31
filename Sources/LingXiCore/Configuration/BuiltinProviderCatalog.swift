import Foundation
import LingXiProtocol

/// Product-owned definitions only. User accounts, credential references, model overrides, and
/// default selection are persisted separately in providers.json.
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

    private static func endpoint(_ id: String, _ baseURL: String, _ wire: ProviderWire, _ authentication: RequestAuthentication, headers: [String: String] = [:], override: Bool = true) -> ProviderProductEndpoint {
        ProviderProductEndpoint(id: ProviderEndpointID(rawValue: id), baseURL: URL(string: baseURL), wire: wire, requestAuthentication: authentication, requiredHeaders: headers, allowsEndpointOverride: override, verificationStatus: .verified)
    }
}
