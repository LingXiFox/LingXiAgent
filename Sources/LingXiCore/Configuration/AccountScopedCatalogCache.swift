import Foundation
import CryptoKit
import LingXiProtocol

public struct DiscoveredRemoteModel: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let priority: Int
    public let visibility: String
    public let isDefault: Bool
    public let supportedReasoningEfforts: [ReasoningEffort]
    public let minimalClientVersion: String?
    public let contextWindow: Int?
    public let maxOutputTokens: Int?
    public let toolCalling: Bool
    public let vision: Bool
    public let metadataIncomplete: Bool

    public init(
        id: String,
        displayName: String,
        priority: Int = 100,
        visibility: String = "public",
        isDefault: Bool = false,
        supportedReasoningEfforts: [ReasoningEffort] = [],
        minimalClientVersion: String? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        toolCalling: Bool = true,
        vision: Bool = false,
        metadataIncomplete: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.priority = priority
        self.visibility = visibility
        self.isDefault = isDefault
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.minimalClientVersion = minimalClientVersion
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.toolCalling = toolCalling
        self.vision = vision
        self.metadataIncomplete = metadataIncomplete
    }
}

public struct AccountCatalogCacheRecord: Codable, Sendable, Equatable {
    public let accountRef: String
    public let fetchedAt: Date
    public let expiresAt: Date
    public var isStale: Bool
    public let source: String
    public let upstreamVersion: String?
    public let models: [DiscoveredRemoteModel]

    public init(
        accountRef: String,
        fetchedAt: Date,
        expiresAt: Date,
        isStale: Bool = false,
        source: String = "ChatGPT Remote Model Catalog",
        upstreamVersion: String? = nil,
        models: [DiscoveredRemoteModel]
    ) {
        self.accountRef = accountRef
        self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt
        self.isStale = isStale
        self.source = source
        self.upstreamVersion = upstreamVersion
        self.models = models
    }

    public var isExpired: Bool {
        Date() > expiresAt
    }
}

public actor AccountScopedCatalogCache {
    public static let shared = AccountScopedCatalogCache()

    private let fileManager: FileManager
    private let baseCacheDirectory: URL

    public init(baseCacheDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let baseCacheDirectory {
            self.baseCacheDirectory = baseCacheDirectory
        } else {
            let home = fileManager.homeDirectoryForCurrentUser
            self.baseCacheDirectory = home.appendingPathComponent(".lingxiagent/cache/provider-catalog", isDirectory: true)
        }
    }

    public func cacheFileURL(productID: String, accountRef: String) -> URL {
        let safeAccountID = sanitizeIdentifier(accountRef)
        return baseCacheDirectory
            .appendingPathComponent(productID, isDirectory: true)
            .appendingPathComponent("\(safeAccountID).json")
    }

    public func load(productID: String, accountRef: String) -> AccountCatalogCacheRecord? {
        let fileURL = cacheFileURL(productID: productID, accountRef: accountRef)
        if fileManager.fileExists(atPath: fileURL.path), let record = tryDecodeRecord(at: fileURL) {
            return record
        }

        // Fallback: If specific accountRef file is not found or empty, search existing cached accounts for this product
        let existingAccounts = listAccounts(productID: productID)
        for acc in existingAccounts {
            let candidateURL = cacheFileURL(productID: productID, accountRef: acc)
            if let record = tryDecodeRecord(at: candidateURL), !record.models.isEmpty {
                return record
            }
        }

        return nil
    }

    private func tryDecodeRecord(at fileURL: URL) -> AccountCatalogCacheRecord? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AccountCatalogCacheRecord.self, from: data)
    }

    @discardableResult
    public func save(
        productID: String,
        accountRef: String,
        models: [DiscoveredRemoteModel],
        source: String = "ChatGPT Remote Model Catalog",
        upstreamVersion: String? = nil,
        ttl: TimeInterval = 3600 // 1 hour TTL
    ) throws -> AccountCatalogCacheRecord {
        let now = Date()
        let expiresAt = now.addingTimeInterval(ttl)
        let record = AccountCatalogCacheRecord(
            accountRef: accountRef,
            fetchedAt: now,
            expiresAt: expiresAt,
            isStale: false,
            source: source,
            upstreamVersion: upstreamVersion,
            models: models
        )

        let fileURL = cacheFileURL(productID: productID, accountRef: accountRef)
        let parentDir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: fileURL, options: .atomic)

        return record
    }

    public func markStale(productID: String, accountRef: String) {
        guard var record = load(productID: productID, accountRef: accountRef) else { return }
        record.isStale = true
        let fileURL = cacheFileURL(productID: productID, accountRef: accountRef)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(record) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    public func listAccounts(productID: String) -> [String] {
        let dir = baseCacheDirectory.appendingPathComponent(productID, isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return [] }
        return files.filter { $0.hasSuffix(".json") }.map { $0.replacingOccurrences(of: ".json", with: "") }
    }

    private func sanitizeIdentifier(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return id.components(separatedBy: allowed.inverted).joined(separator: "_")
    }

    public static func accountHash(fromTokenOrIdentifier identifier: String) -> String {
        let token: String
        if let json = try? JSONSerialization.jsonObject(with: Data(identifier.utf8)) as? [String: Any],
           let tok = (json["accessToken"] as? String) ?? (json["access_token"] as? String) {
            token = tok
        } else {
            token = identifier
        }

        // If JWT token, try extracting 'sub' or 'account_id'
        if let jwtPayload = extractJWTPayload(token: token) {
            if let sub = jwtPayload["sub"] as? String, !sub.isEmpty {
                return sub
            }
            if let acc = jwtPayload["account_id"] as? String, !acc.isEmpty {
                return acc
            }
        }
        // Fallback: SHA256 deterministic prefix
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private static func extractJWTPayload(token: String) -> [String: Any]? {
        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}
