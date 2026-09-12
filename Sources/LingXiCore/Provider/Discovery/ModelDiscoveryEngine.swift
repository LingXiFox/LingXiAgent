import Foundation
import LingXiProtocol

/// Unified engine for discovering models available to a specific user account.
/// Adheres strictly to the principle that account discovery is the primary authority on model availability.
public final class ModelDiscoveryEngine: Sendable {
    public static let shared = ModelDiscoveryEngine()

    private let cacheStore: ModelCacheStore

    public init(cacheStore: ModelCacheStore = .shared) {
        self.cacheStore = cacheStore
    }

    public enum DiscoveryError: Error, LocalizedError, Equatable {
        case noPublicDiscoveryEndpoint(productID: String)
        case missingCredential(productID: String)
        case requestBuildFailed(String)
        case transport(String)
        case emptyListing(productID: String)
        case unsupportedStrategy(String)

        public var errorDescription: String? {
            switch self {
            case let .noPublicDiscoveryEndpoint(productID):
                return "Product '\(productID)' has no public model discovery endpoint declared."
            case let .missingCredential(productID):
                return "Product '\(productID)' requires an authenticated credential for model discovery."
            case let .requestBuildFailed(reason):
                return "Failed to build discovery request: \(reason)"
            case let .transport(detail):
                return "Transport error during model discovery: \(detail)"
            case let .emptyListing(productID):
                return "Upstream returned an empty model list for '\(productID)'."
            case let .unsupportedStrategy(strategy):
                return "Unsupported discovery strategy: '\(strategy)'"
            }
        }
    }

    /// Discovers models for a given product and account credential.
    ///
    /// - Parameters:
    ///   - product: The resolved provider product.
    ///   - credential: The account credential or token (if required).
    ///   - endpointOverride: Optional custom baseURL override.
    ///   - httpClient: Optional custom HTTP transport for testing.
    /// - Returns: A result containing discovered models or an error.
    public func discoverModels(
        product: ResolvedProviderProduct,
        credential: String?,
        endpointOverride: URL? = nil,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async -> Result<[DiscoveredRemoteModel], Error> {
        let accountHash = ModelCacheStore.computeAccountHash(credential)
        let endpointHash = ModelCacheStore.computeEndpointHash(endpointOverride)

        // 1. Check for products with no public discovery endpoint:
        // zai-api, cloudflare-ai-gateway, zhipu-coding-plan, qwen-coding-plan,
        // gemini-code-assist, anthropic-claude-subscription, xai-grok-subscription
        if product.hasNoPublicDiscoveryEndpoint {
            if let cached = await cacheStore.load(productID: product.id, accountHash: accountHash, endpointHash: endpointHash) {
                return .success(cached.models)
            }
            // Strictly zero speculative network requests against unknown endpoints.
            // Only consult local disk/memory cached models catalog if present.
            let offlineFallback = await LingXiModelsCatalogClient.shared.cachedModelsForProduct(productID: product.id)
            if !offlineFallback.isEmpty {
                return .success(offlineFallback)
            }
            return .success([])
        }

        // 2. Perform live network discovery according to strategy
        do {
            let discoveredModels: [DiscoveredRemoteModel]
            switch product.discoveryStrategy {
            case "openaiModels":
                discoveredModels = try await discoverOpenAIModels(product: product, credential: credential, endpointOverride: endpointOverride, httpClient: httpClient)
            case "anthropicModels":
                discoveredModels = try await discoverAnthropicModels(product: product, credential: credential, endpointOverride: endpointOverride, httpClient: httpClient)
            case "geminiModels":
                discoveredModels = try await discoverGeminiModels(product: product, credential: credential, endpointOverride: endpointOverride, httpClient: httpClient)
            case "ollamaTags":
                discoveredModels = try await discoverOllamaTags(product: product, endpointOverride: endpointOverride, httpClient: httpClient)
            case "openrouterModels":
                discoveredModels = try await discoverOpenRouterModels(product: product, credential: credential, endpointOverride: endpointOverride, httpClient: httpClient)
            case "openaiCodexBackend", "codexAuthenticatedCatalog":
                discoveredModels = try await discoverOpenAICodexBackend(product: product, credential: credential, httpClient: httpClient)
            case "antigravityFetchAvailableModels", "antigravityAuthenticatedCatalog":
                discoveredModels = try await discoverAntigravityModels(product: product, credential: credential, httpClient: httpClient)
            default:
                throw DiscoveryError.unsupportedStrategy(product.discoveryStrategy)
            }

            guard !discoveredModels.isEmpty else {
                throw DiscoveryError.emptyListing(productID: product.id)
            }

            // Save to account-isolated LKG cache
            _ = try? await cacheStore.save(
                productID: product.id,
                accountHash: accountHash,
                endpointHash: endpointHash,
                endpointURL: endpointOverride,
                models: discoveredModels,
                source: "Live Upstream Discovery"
            )

            return .success(discoveredModels)
        } catch {
            // On discovery failure: check if isolated LKG cache exists
            await cacheStore.markStale(productID: product.id, accountHash: accountHash, endpointHash: endpointHash)
            if let cached = await cacheStore.load(productID: product.id, accountHash: accountHash, endpointHash: endpointHash), !cached.models.isEmpty {
                return .success(cached.models)
            }
            return .failure(error)
        }
    }

    // MARK: - Private Strategy Handlers

    private func discoverOpenAIModels(
        product: ResolvedProviderProduct,
        credential: String?,
        endpointOverride: URL?,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    ) async throws -> [DiscoveredRemoteModel] {
        let baseURL = endpointOverride ?? URL(string: product.binding(for: "openaiChat")?.baseURL ?? "https://api.openai.com/v1")
        guard let baseURL else {
            throw DiscoveryError.requestBuildFailed("Invalid base URL for \(product.id)")
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let path = components?.path ?? ""
        if path.hasSuffix("/chat/completions") {
            components?.path = path.replacingOccurrences(of: "/chat/completions", with: "/models")
        } else if !path.hasSuffix("/models") {
            components?.path = (path as NSString).appendingPathComponent("models")
        }
        guard let url = components?.url else {
            throw DiscoveryError.requestBuildFailed("Could not construct /models URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let credential, !credential.isEmpty {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await send(request, httpClient: httpClient)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DiscoveryError.transport("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        return try ModelListAdapters.parse(kind: ModelListAdapters.openAIModels, data: data, source: url.absoluteString)
    }

    private func discoverAnthropicModels(
        product: ResolvedProviderProduct,
        credential: String?,
        endpointOverride: URL?,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    ) async throws -> [DiscoveredRemoteModel] {
        let url = endpointOverride?.appendingPathComponent("v1/models") ?? URL(string: "https://api.anthropic.com/v1/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let credential, !credential.isEmpty {
            request.setValue(credential, forHTTPHeaderField: "x-api-key")
        }

        let (data, response) = try await send(request, httpClient: httpClient)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DiscoveryError.transport("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        return try ModelListAdapters.parse(kind: ModelListAdapters.anthropicModels, data: data, source: url.absoluteString)
    }

    private func discoverGeminiModels(
        product: ResolvedProviderProduct,
        credential: String?,
        endpointOverride: URL?,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    ) async throws -> [DiscoveredRemoteModel] {
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        if let credential, !credential.isEmpty {
            components.queryItems = [URLQueryItem(name: "key", value: credential)]
        }
        guard let url = components.url else {
            throw DiscoveryError.requestBuildFailed("Invalid Gemini models URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await send(request, httpClient: httpClient)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DiscoveryError.transport("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        return try ModelListAdapters.parse(kind: ModelListAdapters.geminiModels, data: data, source: url.absoluteString)
    }

    private func discoverOllamaTags(
        product: ResolvedProviderProduct,
        endpointOverride: URL?,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    ) async throws -> [DiscoveredRemoteModel] {
        let baseURL = endpointOverride ?? URL(string: "http://localhost:11434")!
        let url = baseURL.appendingPathComponent("api/tags")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await send(request, httpClient: httpClient)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DiscoveryError.transport("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        return try ModelListAdapters.parse(kind: ModelListAdapters.ollamaTags, data: data, source: url.absoluteString)
    }

    private func discoverOpenRouterModels(
        product: ResolvedProviderProduct,
        credential: String?,
        endpointOverride: URL?,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    ) async throws -> [DiscoveredRemoteModel] {
        let url = URL(string: "https://openrouter.ai/api/v1/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let credential, !credential.isEmpty {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await send(request, httpClient: httpClient)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DiscoveryError.transport("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        return try ModelListAdapters.parse(kind: ModelListAdapters.openRouterModels, data: data, source: url.absoluteString)
    }

    private func discoverOpenAICodexBackend(
        product: ResolvedProviderProduct,
        credential: String?,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    ) async throws -> [DiscoveredRemoteModel] {
        guard let credential, !credential.isEmpty else {
            throw DiscoveryError.missingCredential(productID: product.id)
        }
        let url = URL(string: "https://chatgpt.com/backend-api/codex/models?client_version=\(ClientFingerprint.codexVersion())")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        let headers = ClientFingerprint.headers(for: "openai-codex", authToken: credential)
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await send(request, httpClient: httpClient)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DiscoveryError.transport("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        return try ModelListAdapters.parse(kind: ModelListAdapters.chatGPTBackend, data: data, source: url.absoluteString)
    }

    private func discoverAntigravityModels(
        product: ResolvedProviderProduct,
        credential: String?,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    ) async throws -> [DiscoveredRemoteModel] {
        guard let credential, !credential.isEmpty else {
            throw DiscoveryError.missingCredential(productID: product.id)
        }
        let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        let headers = ClientFingerprint.headers(for: "antigravity", authToken: credential)
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.httpBody = "{}".data(using: .utf8)

        let (data, response) = try await send(request, httpClient: httpClient)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DiscoveryError.transport("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        return try ModelListAdapters.parse(kind: ModelListAdapters.plainArray, data: data, source: url.absoluteString)
    }

    private func send(_ request: URLRequest, httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?) async throws -> (Data, URLResponse) {
        if let httpClient {
            return try await httpClient(request)
        }
        return try await URLSession.shared.data(for: request)
    }
}
