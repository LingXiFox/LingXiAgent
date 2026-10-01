import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What can go wrong reading a catalog.
public enum ModelCatalogError: Error, Equatable, Sendable {
    /// The document is not readable as a catalog, or is shaped for a schema this
    /// SDK does not understand.
    case invalidCatalog(String)
    case unsupportedSchemaVersion(String)
    /// The data source answered with something other than the catalog.
    case unexpectedStatus(Int)
    case transport(String)
    /// Nothing was available: no fresh fetch, no cache to fall back on.
    case unavailable(String)
}

extension ModelCatalogError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidCatalog(reason): return "模型目录数据无效：\(reason)"
        case let .unsupportedSchemaVersion(version): return "模型目录 schema 版本不受支持：\(version)"
        case let .unexpectedStatus(code): return "模型目录请求失败：HTTP \(code)"
        case let .transport(reason): return "模型目录网络错误：\(reason)"
        case let .unavailable(reason): return "模型目录不可用：\(reason)"
        }
    }
}

/// Where a catalog comes from and how long a copy may be reused.
public struct ModelCatalogConfiguration: Sendable, Hashable, Equatable {
    /// The public model catalog. This is the only remote source the SDK reads.
    public static let defaultEndpoint = URL(string: "https://models.lingxifox.cn/models.json")!

    public var endpoint: URL
    /// How long a fetched copy is served without touching the network.
    public var maxAge: TimeInterval
    /// Where a copy is kept between processes. `nil` keeps the cache in memory
    /// only, which is what a short-lived consumer wants.
    public var cacheDirectory: URL?
    public var requestTimeout: TimeInterval
    public var userAgent: String

    public init(
        endpoint: URL = ModelCatalogConfiguration.defaultEndpoint,
        maxAge: TimeInterval = 1800,
        cacheDirectory: URL? = nil,
        requestTimeout: TimeInterval = 30,
        userAgent: String = "LingXiModelSDK/1.0"
    ) {
        self.endpoint = endpoint
        self.maxAge = maxAge
        self.cacheDirectory = cacheDirectory
        self.requestTimeout = requestTimeout
        self.userAgent = userAgent
    }
}

/// The network call, injectable so a consumer controls retries and tests stay offline.
public protocol ModelCatalogTransport: Sendable {
    func respond(to request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionModelCatalogTransport: ModelCatalogTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func respond(to request: URLRequest) async throws -> (Data, URLResponse) {
        #if canImport(FoundationNetworking)
        // Linux's Foundation still exposes only the completion-handler form.
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: ModelCatalogError.transport("empty response"))
                }
            }
            task.resume()
        }
        #else
        return try await session.data(for: request)
        #endif
    }
}

/// A fetched catalog plus what is needed to revalidate it.
public struct CachedModelCatalog: Sendable, Equatable {
    public let catalog: LingXiModelCatalog
    public let fetchedAt: Date
    public let etag: String?

    public init(catalog: LingXiModelCatalog, fetchedAt: Date, etag: String?) {
        self.catalog = catalog
        self.fetchedAt = fetchedAt
        self.etag = etag
    }

    public func isFresh(maxAge: TimeInterval, asOf date: Date = Date()) -> Bool {
        maxAge > 0 && date.timeIntervalSince(fetchedAt) < maxAge
    }
}

/// Memory plus optional disk copy of the catalog, with ETag revalidation.
public actor ModelCatalogCache {
    private struct Metadata: Codable {
        let etag: String?
        let fetchedAt: Date
    }

    private let configuration: ModelCatalogConfiguration
    private let fileManager: FileManager
    private var memory: CachedModelCatalog?

    public init(configuration: ModelCatalogConfiguration = ModelCatalogConfiguration(), fileManager: FileManager = .default) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    private var catalogFileURL: URL? {
        configuration.cacheDirectory?.appendingPathComponent("models.json")
    }

    private var metadataFileURL: URL? {
        configuration.cacheDirectory?.appendingPathComponent("models.json.meta.json")
    }

    /// The newest copy on hand, without touching the network.
    public func cached() -> CachedModelCatalog? {
        if let memory { return memory }
        guard let url = catalogFileURL,
              let data = try? Data(contentsOf: url),
              let catalog = try? ModelCatalogDecoder.decode(data) else { return nil }
        let metadata: Metadata?
        if let metadataURL = metadataFileURL, let raw = try? Data(contentsOf: metadataURL) {
            metadata = try? JSONDecoder().decode(Metadata.self, from: raw)
        } else {
            metadata = nil
        }
        let record = CachedModelCatalog(
            catalog: catalog,
            fetchedAt: metadata?.fetchedAt ?? (catalog.revision.generatedAt ?? .distantPast),
            etag: metadata?.etag
        )
        memory = record
        return record
    }

    /// Stores a freshly fetched document as published bytes, so nothing the SDK
    /// does not model is lost on the way back to disk.
    public func store(data: Data, catalog: LingXiModelCatalog, etag: String?, fetchedAt: Date) {
        memory = CachedModelCatalog(catalog: catalog, fetchedAt: fetchedAt, etag: etag)
        guard let directory = configuration.cacheDirectory, let url = catalogFileURL else { return }
        write(to: url, data: data, in: directory)
        let metadata = Metadata(etag: etag, fetchedAt: fetchedAt)
        if let metadataURL = metadataFileURL, let encoded = try? JSONEncoder().encode(metadata) {
            write(to: metadataURL, data: encoded, in: directory)
        }
    }

    /// The server confirmed the stored revision is current: keep the bytes,
    /// advance the fetch time so the next read does not revalidate again.
    public func markRevalidated(etag: String?, fetchedAt: Date) {
        guard let memory else { return }
        self.memory = CachedModelCatalog(catalog: memory.catalog, fetchedAt: fetchedAt, etag: etag)
        guard let directory = configuration.cacheDirectory, let metadataURL = metadataFileURL else { return }
        let metadata = Metadata(etag: etag ?? self.memory?.etag, fetchedAt: fetchedAt)
        if let encoded = try? JSONEncoder().encode(metadata) {
            write(to: metadataURL, data: encoded, in: directory)
        }
    }

    private func write(to url: URL, data: Data, in directory: URL) {
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try? data.write(to: url, options: .atomic)
    }
}

/// One cache per configuration, kept for the life of the process. A fresh cache
/// per call would re-fetch on every load, which is the opposite of what a cache
/// is for.
public actor ModelCatalogCacheStore {
    public static let shared = ModelCatalogCacheStore()

    private var caches: [ModelCatalogConfiguration: ModelCatalogCache] = [:]

    public init() {}

    public func cache(for configuration: ModelCatalogConfiguration) -> ModelCatalogCache {
        if let existing = caches[configuration] { return existing }
        let created = ModelCatalogCache(configuration: configuration)
        caches[configuration] = created
        return created
    }
}

extension LingXiModelCatalog {
    /// The published catalog, fetched when the cached copy is stale.
    ///
    /// A failed fetch is not a failed load: as long as any copy is on hand it is
    /// returned, because an upstream outage must never empty a model picker. When
    /// nothing is available the error is raised rather than answered with an
    /// empty catalog that would look like "the source has no models".
    public static func load(
        configuration: ModelCatalogConfiguration = ModelCatalogConfiguration(),
        transport: ModelCatalogTransport = URLSessionModelCatalogTransport(),
        cache: ModelCatalogCache? = nil,
        forceRefresh: Bool = false
    ) async throws -> LingXiModelCatalog {
        let store: ModelCatalogCache
        if let cache {
            store = cache
        } else {
            store = await ModelCatalogCacheStore.shared.cache(for: configuration)
        }
        let cached = await store.cached()
        if !forceRefresh, let cached, cached.isFresh(maxAge: configuration.maxAge) {
            return cached.catalog
        }

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        if let etag = cached?.etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await transport.respond(to: request)
            guard let http = response as? HTTPURLResponse else {
                throw ModelCatalogError.transport("响应不是 HTTP")
            }
            if http.statusCode == 304, let cached {
                await store.markRevalidated(etag: cached.etag, fetchedAt: Date())
                return cached.catalog
            }
            guard (200...299).contains(http.statusCode) else {
                throw ModelCatalogError.unexpectedStatus(http.statusCode)
            }
            var catalog = try ModelCatalogDecoder.decode(data)
            catalog.rawDocument = data
            await store.store(
                data: data,
                catalog: catalog,
                etag: http.value(forHTTPHeaderField: "ETag"),
                fetchedAt: Date()
            )
            return catalog
        } catch {
            if let cached { return cached.catalog }
            if let catalogError = error as? ModelCatalogError { throw catalogError }
            throw ModelCatalogError.unavailable("\(error)")
        }
    }

    /// Decodes a catalog the caller already has — a bundled file, a test fixture,
    /// or a copy downloaded by the consumer's own networking.
    public static func decoded(from data: Data) throws -> LingXiModelCatalog {
        try ModelCatalogDecoder.decode(data)
    }
}
