import Foundation
import LingXiProtocol

/// Client for fetching and caching models metadata from `https://models.lingxifox.cn/models.json`.
/// Provides high-fidelity metadata (context limits, pricing, reasoning options, tool capability)
/// and supplies fallback model rosters for providers without dynamic `/v1/models` discovery endpoints.
public actor LingXiModelsCatalogClient {
    public static let shared = LingXiModelsCatalogClient()

    public static let defaultCatalogURL = URL(string: "https://models.lingxifox.cn/models.json")!
    public static let defaultMaxAge: TimeInterval = 1800 // 30 minutes

    public struct ModelEntry: Codable, Sendable {
        public let id: String
        public let name: String?
        public let description: String?
        public let reasoning: Bool?
        public let attachment: Bool?
        public let tool_call: Bool?
        public let limit: Limit?
        public let cost: Cost?
        public let swiftDriver: String?
        public let reasoningField: String?

        public struct Limit: Codable, Sendable {
            public let context: Int?
            public let output: Int?
        }

        public struct Cost: Codable, Sendable {
            public let input: Double?
            public let output: Double?
        }
    }

    public struct ProviderEntry: Codable, Sendable {
        public let id: String
        public let name: String?
        public let baseURL: String?
        public let swiftDriver: String?
        public let models: [String: ModelEntry]?
    }

    public struct CatalogPayload: Codable, Sendable {
        public let version: String?
        public let updatedAt: String?
        public let totalProviders: Int?
        public let totalModels: Int?
        public let providers: [String: ProviderEntry]?
    }

    private let fileManager: FileManager
    private let cacheFileURL: URL
    private let catalogURL: URL
    private var inMemoryCatalog: CatalogPayload?
    private var lastFetchedAt: Date?
    private var cachedEtag: String?

    public init(
        catalogURL: URL = LingXiModelsCatalogClient.defaultCatalogURL,
        cacheDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.catalogURL = catalogURL
        self.fileManager = fileManager
        if let cacheDirectory {
            self.cacheFileURL = cacheDirectory.appendingPathComponent("lingxi-models-catalog.json")
        } else {
            let home = fileManager.homeDirectoryForCurrentUser
            self.cacheFileURL = home
                .appendingPathComponent(".lingxiagent/cache/models-site", isDirectory: true)
                .appendingPathComponent("lingxi-models-catalog.json")
        }
    }

    /// Loads the cached catalog from disk or memory without network I/O.
    public func loadCached() -> CatalogPayload? {
        if let inMemoryCatalog { return inMemoryCatalog }
        guard let data = try? Data(contentsOf: cacheFileURL),
              let payload = try? JSONDecoder().decode(CatalogPayload.self, from: data) else {
            return nil
        }
        self.inMemoryCatalog = payload
        return payload
    }

    /// Fetches the catalog from `models.lingxifox.cn`, revalidating with ETag.
    @discardableResult
    public func fetch(
        forceRefresh: Bool = false,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async -> CatalogPayload? {
        if !forceRefresh,
           let cached = inMemoryCatalog ?? loadCached(),
           let lastFetched = lastFetchedAt,
           Date().timeIntervalSince(lastFetched) < Self.defaultMaxAge {
            return cached
        }

        var request = URLRequest(url: catalogURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LingXiAgent/2.0 (macOS; Swift)", forHTTPHeaderField: "User-Agent")
        if let etag = cachedEtag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let data: Data
            let response: URLResponse
            if let httpClient {
                (data, response) = try await httpClient(request)
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }

            guard let http = response as? HTTPURLResponse else {
                return loadCached()
            }

            if http.statusCode == 304, let cached = loadCached() {
                self.lastFetchedAt = Date()
                return cached
            }

            guard http.statusCode == 200 else {
                return loadCached()
            }

            let payload = try JSONDecoder().decode(CatalogPayload.self, from: data)
            self.inMemoryCatalog = payload
            self.lastFetchedAt = Date()
            self.cachedEtag = http.value(forHTTPHeaderField: "ETag")

            // Write to disk cache
            let dir = cacheFileURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: dir.path) {
                try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try? data.write(to: cacheFileURL, options: .atomic)

            return payload
        } catch {
            return loadCached()
        }
    }

    /// Resolves models for a LingXi Product ID from the cached models.dev catalog (zero network I/O).
    public func cachedModelsForProduct(productID: String) -> [DiscoveredRemoteModel] {
        guard let providers = (inMemoryCatalog ?? loadCached())?.providers else { return [] }

        let candidateProviderKeys: [String]
        switch productID {
        case "zai-api", "zhipu-coding-plan":
            candidateProviderKeys = ["zai", "zhipu-coding-plan", "zai-coding-plan"]
        case "qwen-coding-plan":
            candidateProviderKeys = ["alibaba-coding-plan", "alibaba-coding-plan-cn", "qwen-coding-plan"]
        case "cloudflare-ai-gateway":
            candidateProviderKeys = ["cloudflare-ai-gateway", "cloudflare"]
        case "opencode-zen":
            candidateProviderKeys = ["opencode", "opencode-zen"]
        case "opencode-go":
            candidateProviderKeys = ["opencode-go"]
        case "xai-api", "xai-grok-subscription":
            candidateProviderKeys = ["xai"]
        case "deepseek-api":
            candidateProviderKeys = ["deepseek"]
        case "minimax-api", "minimax-token-plan":
            candidateProviderKeys = ["minimax"]
        default:
            candidateProviderKeys = [productID]
        }

        var result: [DiscoveredRemoteModel] = []
        for key in candidateProviderKeys {
            guard let provider = providers[key], let models = provider.models else { continue }
            for (mid, entry) in models {
                var reasoningEfforts: [ReasoningEffort] = []
                if entry.reasoning == true {
                    reasoningEfforts = [.low, .medium, .high]
                }

                let discovered = DiscoveredRemoteModel(
                    id: mid,
                    displayName: entry.name ?? mid,
                    priority: 100,
                    visibility: "public",
                    isDefault: false,
                    supportedReasoningEfforts: reasoningEfforts,
                    contextWindow: entry.limit?.context,
                    maxOutputTokens: entry.limit?.output,
                    toolCalling: entry.tool_call ?? false,
                    vision: entry.attachment ?? false,
                    metadataIncomplete: false,
                    canonicalModelID: "\(productID)/\(mid)"
                )
                result.append(discovered)
            }
            if !result.isEmpty { break }
        }

        return result
    }

    /// Resolves models for a LingXi Product ID from the models.dev catalog, fetching if needed.
    public func modelsForProduct(
        productID: String,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async -> [DiscoveredRemoteModel] {
        _ = await fetch(httpClient: httpClient)
        return cachedModelsForProduct(productID: productID)
    }
}
