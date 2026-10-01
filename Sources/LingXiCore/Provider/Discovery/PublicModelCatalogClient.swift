import Foundation
import LingXiProtocol
import LingXiModelSDK

/// Core's view of the public model catalog.
///
/// The catalog answers one question — what a model *is*: its roster, limits,
/// price and capabilities — and it answers nothing about how LingXi talks to it.
/// Protocol family, authentication and endpoint overrides come from the runtime
/// provider contract (`BuiltinProviderCatalog` plus the user's own configuration),
/// and the account's own discovery decides what the user can actually select.
///
/// Decoding, caching and schema compatibility live in `LingXiModelSDK`; this
/// actor only adapts the SDK's answer into the shapes Core already uses.
public actor PublicModelCatalogClient {
    public static let shared = PublicModelCatalogClient()

    /// How long a fetched copy may be reused without revalidating.
    public static let defaultMaxAge: TimeInterval = 1800

    private let configuration: ModelCatalogConfiguration
    private let cache: ModelCatalogCache
    private let transport: (any ModelCatalogTransport)?
    private var snapshot: LingXiModelCatalog?

    public init(
        endpoint: URL = ModelCatalogConfiguration.defaultEndpoint,
        cacheDirectory: URL? = nil,
        maxAge: TimeInterval = PublicModelCatalogClient.defaultMaxAge,
        transport: (any ModelCatalogTransport)? = nil,
        fileManager: FileManager = .default
    ) {
        let directory = cacheDirectory ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".lingxiagent/cache/models-site", isDirectory: true)
        self.configuration = ModelCatalogConfiguration(endpoint: endpoint, maxAge: maxAge, cacheDirectory: directory)
        self.cache = ModelCatalogCache(configuration: configuration)
        self.transport = transport
    }

    // MARK: - Reading

    /// The newest copy on hand, without touching the network.
    public func cached() async -> LingXiModelCatalog? {
        if let snapshot { return snapshot }
        let loaded = await cache.cached()
        snapshot = loaded?.catalog
        return snapshot
    }

    public var revision: LingXiModelCatalog.Revision? {
        get async { await cached()?.revision }
    }

    /// Brings the catalog up to date. A failure is not a failure of the caller:
    /// an upstream outage leaves the previous copy in place, and only a reader
    /// that never had any copy at all gets `nil`.
    @discardableResult
    public func refresh(force: Bool = false) async -> LingXiModelCatalog? {
        do {
            let loaded = try await LingXiModelCatalog.load(
                configuration: configuration,
                transport: transport ?? URLSessionModelCatalogTransport(),
                cache: cache,
                forceRefresh: force
            )
            snapshot = loaded
            return loaded
        } catch {
            if snapshot == nil { snapshot = await cache.cached()?.catalog }
            return snapshot
        }
    }

    /// Warms the cache in the background; startup never waits on it.
    public func warmup(force: Bool = false) async {
        _ = await refresh(force: force)
    }

    // MARK: - Lookups

    public func model(providerID: String, modelID: String) async -> CatalogModel? {
        await cached()?.model(provider: providerID, id: modelID)
    }

    public func provider(_ providerID: String) async -> CatalogProvider? {
        await cached()?.provider(providerID)
    }

    /// The endpoint the catalog publishes for a provider, if the source stated one.
    public func providerBaseURL(_ providerID: String) async -> String? {
        await provider(providerID)?.baseURL
    }

    /// Published models of one provider, in the catalog's documented order.
    public func models(providerID: String) async -> [CatalogModel] {
        await cached()?.models(provider: providerID) ?? []
    }

    /// A model found under any provider, for a user who named a model without
    /// saying which vendor ships it.
    public func model(named modelID: String) async -> CatalogModel? {
        await cached()?.allModels.first { $0.id == modelID }
    }

    /// Every provider the public catalog publishes.
    public var providers: [CatalogProvider] {
        get async { await cached()?.sortedProviders() ?? [] }
    }

    // MARK: - Product adapter

    /// A LingXi product is configured under its own id; the public catalog knows
    /// the vendor by its upstream name. These are the two names for the same
    /// vendor, verified against the published roster — not a guess about models.
    static let productProviderAliases: [String: [String]] = [
        "openai-api": ["openai"],
        "openai-codex": ["openai"],
        "anthropic-api": ["anthropic"],
        "anthropic-claude-subscription": ["anthropic"],
        "gemini-api": ["google"],
        "gemini-code-assist": ["google"],
        "deepseek-api": ["deepseek"],
        "xai-api": ["xai"],
        "xai-grok-subscription": ["xai"],
        "minimax-api": ["minimax"],
        "minimax-token-plan": ["minimax"],
        "mimo-api": ["xiaomi"],
        "mimo-coding-plan": ["xiaomi"],
        "alibaba-bailian-api": ["alibaba"],
        "qwen-coding-plan": ["alibaba-coding-plan", "alibaba-coding-plan-cn"],
        "hugging-face-inference": ["huggingface"],
        "zai-api": ["zai", "zhipuai", "zai-coding-plan"],
        "zhipu-coding-plan": ["zai-coding-plan", "zai", "zhipuai"],
        "cloudflare-ai-gateway": ["cloudflare-ai-gateway", "cloudflare-workers-ai"],
        "opencode-zen": ["opencode", "opencode-zen"],
    ]

    /// Published models for one LingXi product.
    public func models(forProduct productID: String) async -> [CatalogModel] {
        guard let catalog = await cached() else { return [] }
        for key in Self.candidateProviderKeys(for: productID) {
            let found = catalog.models(provider: key)
            if !found.isEmpty { return found }
        }
        return []
    }

    /// An explicitly mapped vendor name wins over the product's own id: the
    /// mapping was checked against the published roster, the coincidence of an
    /// id is not.
    static func candidateProviderKeys(for productID: String) -> [String] {
        (productProviderAliases[productID] ?? []) + [productID]
    }

    /// The same models in the shape account discovery produces, so a product with
    /// no `/v1/models` endpoint still has a roster to offer.
    public func discoveredModels(forProduct productID: String) async -> [DiscoveredRemoteModel] {
        await models(forProduct: productID).map { model in
            DiscoveredRemoteModel(
                id: model.id,
                displayName: model.name,
                priority: 100,
                visibility: model.status.isSelectable ? "public" : "hide",
                isDefault: false,
                supportedReasoningEfforts: model.capabilities.reasoning
                    ? [.low, .medium, .high]
                    : [],
                contextWindow: model.contextWindow,
                maxOutputTokens: model.maxOutputTokens,
                toolCalling: model.capabilities.toolCalling,
                vision: model.capabilities.vision,
                metadataIncomplete: model.contextWindow == nil,
                canonicalModelID: "\(productID)/\(model.id)"
            )
        }
    }

    /// The public catalog as the metadata leg of model resolution: it states what
    /// is known about a model, while account discovery decides what is reachable.
    public func publishedRecords(forProduct productID: String) async -> [RegistryModelRecord] {
        let source = await cached()?.revision.source ?? "public-catalog"
        return await models(forProduct: productID).map { model in
            RegistryModelRecord(
                id: model.id,
                productID: productID,
                displayName: model.name,
                status: model.status.rawValue,
                capabilities: RegistryCapabilities(
                    contextWindow: model.contextWindow,
                    maxOutputTokens: model.maxOutputTokens,
                    toolCalling: model.capabilities.toolCalling,
                    vision: model.capabilities.vision,
                    reasoning: model.capabilities.reasoning,
                    supportedReasoningEfforts: model.capabilities.reasoningEfforts.isEmpty
                        ? nil : model.capabilities.reasoningEfforts,
                    structuredOutput: model.capabilities.structuredOutput,
                    modalities: model.capabilities.inputModalities.isEmpty
                        ? nil : model.capabilities.inputModalities
                ),
                metadataIncomplete: model.contextWindow == nil,
                source: source,
                upstreamModelID: model.canonicalModelID,
                sourceAuthority: source,
                discoveredFrom: model.providerID
            )
        }
    }
}
