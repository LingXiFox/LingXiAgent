import Foundation
import LingXiProtocol

/// Fetches and caches the unified model registry catalog.
///
/// The catalog is the registry's account-independent view: what products exist,
/// how to authenticate to them, where their model lists come from, and whatever
/// metadata LingXi maintains. It is never the last word on what a given user can
/// actually select — that comes from discovering the user's own account.
public actor ModelRegistryClient {
    public static let shared = ModelRegistryClient()

    /// Default endpoint for the unified registry.
    public static let defaultBaseURL = URL(string: "https://lingxiagent.lingxifox.cn")!

    public struct CachedCatalog: Codable, Sendable, Equatable {
        public let etag: String?
        public let fetchedAt: Date
        public let catalog: RegistryCatalog

        public init(etag: String?, fetchedAt: Date, catalog: RegistryCatalog) {
            self.etag = etag
            self.fetchedAt = fetchedAt
            self.catalog = catalog
        }
    }

    /// How long a cached catalog is served without revalidating.
    public static let defaultMaxAge: TimeInterval = 3600

    private let fileManager: FileManager
    private let cacheFileURL: URL
    private let baseURL: URL
    private var memory: CachedCatalog?

    public init(
        baseURL: URL = ModelRegistryClient.defaultBaseURL,
        cacheDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.baseURL = baseURL
        self.fileManager = fileManager
        if let cacheDirectory {
            self.cacheFileURL = cacheDirectory.appendingPathComponent("registry-catalog.json")
        } else {
            let home = fileManager.homeDirectoryForCurrentUser
            self.cacheFileURL = home
                .appendingPathComponent(".lingxiagent/cache/registry", isDirectory: true)
                .appendingPathComponent("registry-catalog.json")
        }
    }

    // MARK: - Cache access

    /// The catalog currently on disk, if any. Never performs network I/O, so a
    /// caller can render immediately and refresh afterwards.
    public func cachedCatalog() -> CachedCatalog? {
        if let memory { return memory }
        guard let data = try? Data(contentsOf: cacheFileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(CachedCatalog.self, from: data) else { return nil }
        memory = record
        return record
    }

    private func store(_ record: CachedCatalog) {
        memory = record
        let directory = cacheFileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        try? data.write(to: cacheFileURL, options: .atomic)
    }

    // MARK: - Fetching

    public enum FetchOutcome: Sendable, Equatable {
        /// A new catalog was downloaded and stored.
        case updated(RegistryCatalog)
        /// The server confirmed the cached revision is current (304).
        case notModified(RegistryCatalog)
        /// The fetch failed; the returned catalog is the last known good one.
        case stale(RegistryCatalog, reason: String)
        /// No catalog is available at all.
        case unavailable(reason: String)
    }

    /// Fetches the catalog, revalidating against the cached revision.
    ///
    /// - Parameter maxAge: how long a cached catalog may be used without
    ///   revalidating. Pass 0 to always revalidate (which still costs only a
    ///   304 when nothing changed).
    @discardableResult
    public func fetch(
        maxAge: TimeInterval = ModelRegistryClient.defaultMaxAge,
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async -> FetchOutcome {
        let cached = cachedCatalog()

        if let cached, maxAge > 0, Date().timeIntervalSince(cached.fetchedAt) < maxAge {
            return .notModified(cached.catalog)
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/catalog"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LingXiAgent/2.0 (macOS; registry)", forHTTPHeaderField: "User-Agent")
        if let etag = cached?.etag, !etag.isEmpty {
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
                return fallback(cached, reason: "registry returned a non-HTTP response")
            }

            if http.statusCode == 304, let cached {
                // Revalidation succeeded: keep the bytes, advance the fetch time
                // so the next read does not revalidate again immediately.
                let refreshed = CachedCatalog(etag: cached.etag, fetchedAt: Date(), catalog: cached.catalog)
                store(refreshed)
                return .notModified(cached.catalog)
            }

            guard (200...299).contains(http.statusCode) else {
                return fallback(cached, reason: "registry returned HTTP \(http.statusCode)")
            }

            let decoder = JSONDecoder()
            let catalog = try decoder.decode(RegistryCatalog.self, from: data)
            let etag = http.value(forHTTPHeaderField: "ETag")
            store(CachedCatalog(etag: etag, fetchedAt: Date(), catalog: catalog))
            return .updated(catalog)
        } catch {
            return fallback(cached, reason: error.localizedDescription)
        }
    }

    /// Convenience: the best catalog available, fetching if the cache is cold.
    /// A refresh failure degrades to the cached revision rather than to nothing.
    public func catalog(maxAge: TimeInterval = ModelRegistryClient.defaultMaxAge) async -> RegistryCatalog? {
        switch await fetch(maxAge: maxAge) {
        case let .updated(catalog), let .notModified(catalog): return catalog
        case let .stale(catalog, _): return catalog
        case .unavailable: return nil
        }
    }

    private func fallback(_ cached: CachedCatalog?, reason: String) -> FetchOutcome {
        if let cached {
            return .stale(cached.catalog, reason: reason)
        }
        return .unavailable(reason: reason)
    }
}
