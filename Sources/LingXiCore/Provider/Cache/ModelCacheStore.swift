import Foundation
import CryptoKit
import LingXiProtocol

/// Record stored in `~/.lingxiagent/provider-cache/<productID>/<accountHash>/<endpointHash>/model_cache.json`.
public struct ModelCacheFileRecord: Codable, Sendable, Equatable {
    public let productID: String
    public let accountHash: String
    public let endpointHash: String
    public let endpointURL: String?
    public let updatedAt: Date
    public let expiresAt: Date
    public let isStale: Bool
    public let source: String
    public let models: [DiscoveredRemoteModel]

    public init(
        productID: String,
        accountHash: String,
        endpointHash: String,
        endpointURL: String?,
        updatedAt: Date = Date(),
        expiresAt: Date,
        isStale: Bool = false,
        source: String,
        models: [DiscoveredRemoteModel]
    ) {
        self.productID = productID
        self.accountHash = accountHash
        self.endpointHash = endpointHash
        self.endpointURL = endpointURL
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.isStale = isStale
        self.source = source
        self.models = models
    }

    public var isExpired: Bool {
        Date() > expiresAt
    }
}

/// Thread-safe multi-tenant cache store managing isolated model caches per product, account, and endpoint.
public actor ModelCacheStore {
    public static let shared = ModelCacheStore()

    private let baseDirectory: URL
    private let fileManager: FileManager

    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let home = fileManager.homeDirectoryForCurrentUser
            self.baseDirectory = home.appendingPathComponent(".lingxiagent/provider-cache", isDirectory: true)
        }
    }

    /// Computes safe account hash from credential or account reference (SHA256 prefix 16 chars).
    public static func computeAccountHash(_ credentialOrRef: String?) -> String {
        guard let text = credentialOrRef, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "anonymous"
        }
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// Computes safe endpoint hash from endpoint URL (SHA256 prefix 16 chars).
    public static func computeEndpointHash(_ endpoint: URL?) -> String {
        guard let url = endpoint, !url.absoluteString.isEmpty else {
            return "default"
        }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    public func cacheFileURL(productID: String, accountHash: String, endpointHash: String) -> URL {
        baseDirectory
            .appendingPathComponent(productID, isDirectory: true)
            .appendingPathComponent(accountHash, isDirectory: true)
            .appendingPathComponent(endpointHash, isDirectory: true)
            .appendingPathComponent("model_cache.json")
    }

    /// Loads the cached record for the specific (productID, accountHash, endpointHash) tuple.
    /// Strictly isolated: will NEVER fall back across accounts, endpoints, or products.
    public func load(productID: String, accountHash: String, endpointHash: String) -> ModelCacheFileRecord? {
        let fileURL = cacheFileURL(productID: productID, accountHash: accountHash, endpointHash: endpointHash)
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ModelCacheFileRecord.self, from: data)
    }

    /// Saves the discovery outcome as the Last-Known-Good (LKG) cache for this account and endpoint.
    @discardableResult
    public func save(
        productID: String,
        accountHash: String,
        endpointHash: String,
        endpointURL: URL?,
        models: [DiscoveredRemoteModel],
        source: String,
        ttl: TimeInterval = 21600 // 6 hours default
    ) throws -> ModelCacheFileRecord {
        let now = Date()
        let record = ModelCacheFileRecord(
            productID: productID,
            accountHash: accountHash,
            endpointHash: endpointHash,
            endpointURL: endpointURL?.absoluteString,
            updatedAt: now,
            expiresAt: now.addingTimeInterval(ttl),
            isStale: false,
            source: source,
            models: models
        )

        let fileURL = cacheFileURL(productID: productID, accountHash: accountHash, endpointHash: endpointHash)
        let directoryURL = fileURL.deletingLastPathComponent()

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: fileURL, options: .atomic)
        return record
    }

    /// Marks the cache as stale when live discovery encounters an error, retaining models for LKG.
    public func markStale(productID: String, accountHash: String, endpointHash: String) {
        guard let existing = load(productID: productID, accountHash: accountHash, endpointHash: endpointHash) else {
            return
        }
        let staleRecord = ModelCacheFileRecord(
            productID: existing.productID,
            accountHash: existing.accountHash,
            endpointHash: existing.endpointHash,
            endpointURL: existing.endpointURL,
            updatedAt: existing.updatedAt,
            expiresAt: existing.expiresAt,
            isStale: true,
            source: existing.source,
            models: existing.models
        )
        let fileURL = cacheFileURL(productID: productID, accountHash: accountHash, endpointHash: endpointHash)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(staleRecord) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
