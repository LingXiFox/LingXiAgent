import Foundation
import CryptoKit
import LingXiProtocol

/// ContentStore：管理不可变、带授权和校验的资源与大内容（ContentRef）。
public actor ContentStore {
    private struct InProgressUpload {
        let uploadID: String
        let proposedMediaType: String?
        let expectedByteCount: Int?
        let filename: String?
        let scope: ContentAuthorizationScope
        var chunks: [UInt64: Data]
    }

    private struct StoredContent {
        let id: ContentID
        let data: Data
        let mediaType: String?
        let digest: String
        let filename: String?
        let scope: ContentAuthorizationScope
        let createdAt: Date
    }

    private struct PersistedMeta: Codable {
        let id: String
        let mediaType: String?
        let digest: String
        let filename: String?
        let scope: ContentAuthorizationScope
        let createdAt: Date
    }

    private var inProgress: [String: InProgressUpload] = [:]
    private var contents: [ContentID: StoredContent] = [:]
    private let storageDirectory: URL?

    public init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory
        if let dir = storageDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public func beginUpload(request: BeginContentUploadRequest) -> BeginContentUploadResponse {
        let uploadID = UUID().uuidString
        inProgress[uploadID] = InProgressUpload(
            uploadID: uploadID,
            proposedMediaType: request.proposedMediaType,
            expectedByteCount: request.expectedByteCount,
            filename: request.filename,
            scope: request.scope,
            chunks: [:]
        )
        return BeginContentUploadResponse(uploadID: uploadID)
    }

    public func writeChunk(uploadID: String, chunkIndex: UInt64, data: Data) throws {
        guard inProgress[uploadID] != nil else {
            throw RuntimeError(
                category: .validation,
                code: "uploadNotFound",
                message: "Upload ID \(uploadID) 不存在或已结束",
                retryability: .none,
                source: .client
            )
        }
        inProgress[uploadID]?.chunks[chunkIndex] = data
    }

    public func commitUpload(request: CommitContentUploadRequest) throws -> ContentRef {
        guard let upload = inProgress[request.uploadID] else {
            throw RuntimeError(
                category: .validation,
                code: "uploadNotFound",
                message: "Upload ID \(request.uploadID) 不存在或已结束",
                retryability: .none,
                source: .client
            )
        }
        inProgress.removeValue(forKey: request.uploadID)

        let sortedIndices = upload.chunks.keys.sorted()
        var assembledData = Data()
        for idx in sortedIndices {
            if let chunk = upload.chunks[idx] {
                assembledData.append(chunk)
            }
        }

        let sha256 = SHA256.hash(data: assembledData)
        let digestString = "sha256:" + sha256.compactMap { String(format: "%02x", $0) }.joined()

        if let expected = request.expectedDigest, !expected.isEmpty {
            guard expected.lowercased() == digestString.lowercased() else {
                throw RuntimeError(
                    category: .validation,
                    code: "digestMismatch",
                    message: "Digest mismatch: expected \(expected), got \(digestString)",
                    retryability: .none,
                    source: .client
                )
            }
        }

        let contentID = ContentID(UUID().uuidString)
        let stored = StoredContent(
            id: contentID,
            data: assembledData,
            mediaType: upload.proposedMediaType,
            digest: digestString,
            filename: upload.filename,
            scope: upload.scope,
            createdAt: Date()
        )
        contents[contentID] = stored

        if let dir = storageDirectory {
            let fileURL = dir.appendingPathComponent(contentID.rawValue)
            try? assembledData.write(to: fileURL)
            let meta = PersistedMeta(
                id: contentID.rawValue,
                mediaType: upload.proposedMediaType,
                digest: digestString,
                filename: upload.filename,
                scope: upload.scope,
                createdAt: stored.createdAt
            )
            if let metaData = try? JSONEncoder().encode(meta) {
                let metaURL = dir.appendingPathComponent("\(contentID.rawValue).meta.json")
                try? metaData.write(to: metaURL)
            }
        }

        let tokenEstimate = max(1, assembledData.count / 4)
        return ContentRef(
            id: contentID,
            mediaType: upload.proposedMediaType,
            byteCount: assembledData.count,
            tokenEstimate: tokenEstimate,
            digest: digestString
        )
    }

    public func abortUpload(uploadID: String) {
        inProgress.removeValue(forKey: uploadID)
    }

    public func store(
        data: Data,
        mediaType: String? = nil,
        filename: String? = nil,
        scope: ContentAuthorizationScope = .global
    ) -> ContentRef {
        let sha256 = SHA256.hash(data: data)
        let digestString = "sha256:" + sha256.compactMap { String(format: "%02x", $0) }.joined()
        let contentID = ContentID(UUID().uuidString)
        let stored = StoredContent(
            id: contentID,
            data: data,
            mediaType: mediaType,
            digest: digestString,
            filename: filename,
            scope: scope,
            createdAt: Date()
        )
        contents[contentID] = stored

        if let dir = storageDirectory {
            let fileURL = dir.appendingPathComponent(contentID.rawValue)
            try? data.write(to: fileURL)
            let meta = PersistedMeta(
                id: contentID.rawValue,
                mediaType: mediaType,
                digest: digestString,
                filename: filename,
                scope: scope,
                createdAt: stored.createdAt
            )
            if let metaData = try? JSONEncoder().encode(meta) {
                let metaURL = dir.appendingPathComponent("\(contentID.rawValue).meta.json")
                try? metaData.write(to: metaURL)
            }
        }

        let tokenEstimate = max(1, data.count / 4)
        return ContentRef(
            id: contentID,
            mediaType: mediaType,
            byteCount: data.count,
            tokenEstimate: tokenEstimate,
            digest: digestString
        )
    }

    private func resolveContent(id: ContentID) throws -> StoredContent {
        if let stored = contents[id] {
            return stored
        }
        if let dir = storageDirectory {
            let fileURL = dir.appendingPathComponent(id.rawValue)
            if let data = try? Data(contentsOf: fileURL) {
                let metaURL = dir.appendingPathComponent("\(id.rawValue).meta.json")
                if let metaData = try? Data(contentsOf: metaURL),
                   let meta = try? JSONDecoder().decode(PersistedMeta.self, from: metaData) {
                    let loaded = StoredContent(
                        id: id,
                        data: data,
                        mediaType: meta.mediaType,
                        digest: meta.digest,
                        filename: meta.filename,
                        scope: meta.scope,
                        createdAt: meta.createdAt
                    )
                    contents[id] = loaded
                    return loaded
                } else {
                    let sha256 = SHA256.hash(data: data)
                    let digestString = "sha256:" + sha256.compactMap { String(format: "%02x", $0) }.joined()
                    let fallback = StoredContent(
                        id: id,
                        data: data,
                        mediaType: nil,
                        digest: digestString,
                        filename: nil,
                        scope: .global,
                        createdAt: Date()
                    )
                    contents[id] = fallback
                    return fallback
                }
            }
        }
        throw RuntimeError(
            category: .tool,
            code: "resourceNotFound",
            message: "Content ID \(id.rawValue) 不存在",
            retryability: .none,
            source: .core
        )
    }

    public func read(id: ContentID, authorization: ContentAuthorizationContext = .system) throws -> Data {
        let stored = try resolveContent(id: id)
        guard authorization.isAuthorized(for: stored.scope) else {
            throw RuntimeError(
                category: .permission,
                code: "contentAccessDenied",
                message: "Access to Content \(id.rawValue) with scope \(stored.scope) is denied for given authorization context",
                retryability: .none,
                source: .core
            )
        }
        return stored.data
    }

    public func readRange(id: ContentID, offset: Int, length: Int, authorization: ContentAuthorizationContext = .system) throws -> Data {
        let full = try read(id: id, authorization: authorization)
        guard offset >= 0, offset < full.count else {
            return Data()
        }
        let end = min(full.count, offset + length)
        return full.subdata(in: offset..<end)
    }

    public func metadata(id: ContentID, authorization: ContentAuthorizationContext = .system) throws -> ContentMetadata {
        let stored = try resolveContent(id: id)
        guard authorization.isAuthorized(for: stored.scope) else {
            throw RuntimeError(
                category: .permission,
                code: "contentAccessDenied",
                message: "Access to Content \(id.rawValue) with scope \(stored.scope) is denied for given authorization context",
                retryability: .none,
                source: .core
            )
        }
        let tokenEstimate = max(1, stored.data.count / 4)
        let ref = ContentRef(
            id: id,
            mediaType: stored.mediaType,
            byteCount: stored.data.count,
            tokenEstimate: tokenEstimate,
            digest: stored.digest
        )
        return ContentMetadata(ref: ref, createdAt: stored.createdAt, filename: stored.filename, scope: stored.scope)
    }
}
