import Foundation
import LingXiPlatform
import LingXiProtocol

/// ContentStore：管理不可变、带授权和校验的资源与大内容（ContentRef）。
public actor ContentStore {
    private struct InProgressUpload {
        let uploadID: String
        let proposedMediaType: String?
        let expectedByteCount: Int?
        let filename: String?
        let scope: ContentAuthorizationScope
        let createdAt: Date
        var updatedAt: Date
        var stagingFileURL: URL?
        var chunks: [UInt64: Data]
        var receivedIndices: Set<UInt64>
        var totalBytesWritten: Int
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
    private var memoryKeys: [ContentID] = []
    private var currentMemoryBytes: Int = 0
    private let maxMemoryBytes: Int = 32 * 1024 * 1024 // 32MB 内存上限
    private let storageDirectory: URL?

    // 内存与上传硬配额及超时限制 (Audit Round 7 Phase E)
    private let maxInflightUploads: Int = 16
    private let maxInflightBytes: Int = 128 * 1024 * 1024 // 128MB
    private let maxPerUploadBytes: Int = 64 * 1024 * 1024 // 64MB
    private let uploadTTL: TimeInterval = 600 // 10 minutes

    public init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory
        if let dir = storageDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func cleanupExpiredUploads() {
        let now = Date()
        var expiredIDs: [String] = []
        for (id, upload) in inProgress {
            if now.timeIntervalSince(upload.updatedAt) > uploadTTL {
                expiredIDs.append(id)
                if let stagingURL = upload.stagingFileURL {
                    try? FileManager.default.removeItem(at: stagingURL)
                }
            }
        }
        for id in expiredIDs {
            inProgress.removeValue(forKey: id)
        }
    }

    private func currentInflightBytes() -> Int {
        inProgress.values.reduce(0) { $0 + $1.totalBytesWritten }
    }

    private func rememberContent(_ stored: StoredContent) {
        if let old = contents[stored.id] {
            currentMemoryBytes -= old.data.count
            memoryKeys.removeAll(where: { $0 == stored.id })
        }
        contents[stored.id] = stored
        currentMemoryBytes += stored.data.count
        memoryKeys.append(stored.id)

        while currentMemoryBytes > maxMemoryBytes, !memoryKeys.isEmpty {
            let evictedKey = memoryKeys.removeFirst()
            if let evicted = contents.removeValue(forKey: evictedKey) {
                currentMemoryBytes -= evicted.data.count
            }
        }
    }

    public func beginUpload(request: BeginContentUploadRequest) throws -> BeginContentUploadResponse {
        cleanupExpiredUploads()
        guard inProgress.count < maxInflightUploads else {
            throw RuntimeError(
                category: .validation,
                code: "tooManyInflightUploads",
                message: "Current inflight uploads (\(inProgress.count)) reached maximum allowed capacity (\(maxInflightUploads))",
                retryability: .afterDelay,
                source: .core
            )
        }

        let uploadID = UUID().uuidString
        let now = Date()
        var stagingURL: URL? = nil
        if let dir = storageDirectory {
            let fileURL = dir.appendingPathComponent(".staging_\(uploadID).tmp")
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            stagingURL = fileURL
        }

        inProgress[uploadID] = InProgressUpload(
            uploadID: uploadID,
            proposedMediaType: request.proposedMediaType,
            expectedByteCount: request.expectedByteCount,
            filename: request.filename,
            scope: request.scope,
            createdAt: now,
            updatedAt: now,
            stagingFileURL: stagingURL,
            chunks: [:],
            receivedIndices: [],
            totalBytesWritten: 0
        )
        return BeginContentUploadResponse(uploadID: uploadID)
    }

    public func writeChunk(uploadID: String, chunkIndex: UInt64, data: Data) throws {
        cleanupExpiredUploads()
        guard var upload = inProgress[uploadID] else {
            throw RuntimeError(
                category: .validation,
                code: "uploadNotFound",
                message: "Upload ID \(uploadID) 不存在或已超时失效",
                retryability: .none,
                source: .client
            )
        }
        let maxChunkBytes = 32 * 1024 * 1024
        guard data.count <= maxChunkBytes else {
            throw RuntimeError(
                category: .validation,
                code: "chunkTooLarge",
                message: "Chunk byte count \(data.count) exceeds limit \(maxChunkBytes)",
                retryability: .none,
                source: .client
            )
        }
        guard upload.receivedIndices.count < 10000 || upload.receivedIndices.contains(chunkIndex) else {
            throw RuntimeError(
                category: .validation,
                code: "tooManyChunks",
                message: "Exceeded maximum chunk limit of 10000",
                retryability: .none,
                source: .client
            )
        }

        // 检查单文件配额
        guard upload.totalBytesWritten + data.count <= maxPerUploadBytes else {
            throw RuntimeError(
                category: .validation,
                code: "uploadByteQuotaExceeded",
                message: "Upload byte count would exceed maximum per-upload limit of \(maxPerUploadBytes) bytes",
                retryability: .none,
                source: .client
            )
        }

        // 检查全局 inflight 配额
        guard currentInflightBytes() + data.count <= maxInflightBytes else {
            throw RuntimeError(
                category: .validation,
                code: "inflightByteQuotaExceeded",
                message: "Global inflight upload bytes would exceed limit of \(maxInflightBytes) bytes",
                retryability: .afterDelay,
                source: .core
            )
        }

        if let stagingURL = upload.stagingFileURL {
            // 磁盘暂存：直接流式写入磁盘，避免大文件堆积在内存 (Audit Round 7 Phase E)
            let handle = try FileHandle(forWritingTo: stagingURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            upload.chunks[chunkIndex] = data
        }

        upload.receivedIndices.insert(chunkIndex)
        upload.totalBytesWritten += data.count
        upload.updatedAt = Date()
        inProgress[uploadID] = upload
    }

    public func commitUpload(request: CommitContentUploadRequest) throws -> ContentRef {
        cleanupExpiredUploads()
        guard let upload = inProgress[request.uploadID] else {
            throw RuntimeError(
                category: .validation,
                code: "uploadNotFound",
                message: "Upload ID \(request.uploadID) 不存在或已超时失效",
                retryability: .none,
                source: .client
            )
        }

        let sortedIndices = upload.receivedIndices.sorted()
        // 关键防御：严格检查 Chunk 连续性，杜绝空洞
        for (expectedIndex, actualIndex) in sortedIndices.enumerated() {
            guard actualIndex == UInt64(expectedIndex) else {
                throw RuntimeError(
                    category: .validation,
                    code: "incompleteChunks",
                    message: "Upload chunks are not contiguous: missing chunk \(expectedIndex)",
                    retryability: .none,
                    source: .client
                )
            }
        }

        if let expectedByteCount = upload.expectedByteCount {
            guard upload.totalBytesWritten == expectedByteCount else {
                throw RuntimeError(
                    category: .validation,
                    code: "byteCountMismatch",
                    message: "Uploaded byte count \(upload.totalBytesWritten) does not match expected \(expectedByteCount)",
                    retryability: .none,
                    source: .client
                )
            }
        }

        let contentID = ContentID(UUID().uuidString)
        let digestString: String
        let assembledData: Data

        if let stagingURL = upload.stagingFileURL, let dir = storageDirectory {
            let data = (try? Data(contentsOf: stagingURL)) ?? Data()
            digestString = "sha256:" + LingXiPlatform.crypto.sha256Hex(data)
            assembledData = data

            if let expected = request.expectedDigest, !expected.isEmpty {
                guard expected.lowercased() == digestString.lowercased() else {
                    try? FileManager.default.removeItem(at: stagingURL)
                    inProgress.removeValue(forKey: request.uploadID)
                    throw RuntimeError(
                        category: .validation,
                        code: "digestMismatch",
                        message: "Digest mismatch: expected \(expected), got \(digestString)",
                        retryability: .none,
                        source: .client
                    )
                }
            }

            // 原子重命名 staging 文件为正式内容文件，并原子写入 metadata
            let finalFileURL = dir.appendingPathComponent(contentID.rawValue)
            let metaURL = dir.appendingPathComponent("\(contentID.rawValue).meta.json")
            try? FileManager.default.removeItem(at: finalFileURL)
            try FileManager.default.moveItem(at: stagingURL, to: finalFileURL)

            let meta = PersistedMeta(
                id: contentID.rawValue,
                mediaType: upload.proposedMediaType,
                digest: digestString,
                filename: upload.filename,
                scope: upload.scope,
                createdAt: Date()
            )
            if let metaData = try? JSONEncoder().encode(meta) {
                try? metaData.write(to: metaURL, options: .atomic)
            }
        } else {
            var memData = Data()
            for idx in sortedIndices {
                if let chunk = upload.chunks[idx] {
                    memData.append(chunk)
                }
            }
            digestString = "sha256:" + LingXiPlatform.crypto.sha256Hex(memData)
            assembledData = memData

            if let expected = request.expectedDigest, !expected.isEmpty {
                guard expected.lowercased() == digestString.lowercased() else {
                    inProgress.removeValue(forKey: request.uploadID)
                    throw RuntimeError(
                        category: .validation,
                        code: "digestMismatch",
                        message: "Digest mismatch: expected \(expected), got \(digestString)",
                        retryability: .none,
                        source: .client
                    )
                }
            }
        }

        inProgress.removeValue(forKey: request.uploadID)

        let stored = StoredContent(
            id: contentID,
            data: assembledData,
            mediaType: upload.proposedMediaType,
            digest: digestString,
            filename: upload.filename,
            scope: upload.scope,
            createdAt: Date()
        )
        rememberContent(stored)

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
        if let upload = inProgress.removeValue(forKey: uploadID), let stagingURL = upload.stagingFileURL {
            try? FileManager.default.removeItem(at: stagingURL)
        }
    }

    public func store(
        data: Data,
        mediaType: String? = nil,
        filename: String? = nil,
        scope: ContentAuthorizationScope = .global
    ) -> ContentRef {
        let digestString = "sha256:" + LingXiPlatform.crypto.sha256Hex(data)
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
        rememberContent(stored)

        if let dir = storageDirectory {
            let fileURL = dir.appendingPathComponent(contentID.rawValue)
            let metaURL = dir.appendingPathComponent("\(contentID.rawValue).meta.json")
            try? data.write(to: fileURL, options: .atomic)
            let meta = PersistedMeta(
                id: contentID.rawValue,
                mediaType: mediaType,
                digest: digestString,
                filename: filename,
                scope: scope,
                createdAt: stored.createdAt
            )
            if let metaData = try? JSONEncoder().encode(meta) {
                try? metaData.write(to: metaURL, options: .atomic)
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

    /// 仅解析元数据与文件大小，绝对不将冷文件正文加载至内存 (Audit Round 7 Phase E)
    private func resolveMetadata(id: ContentID) throws -> (meta: PersistedMeta, byteCount: Int) {
        if let stored = contents[id] {
            let meta = PersistedMeta(
                id: id.rawValue,
                mediaType: stored.mediaType,
                digest: stored.digest,
                filename: stored.filename,
                scope: stored.scope,
                createdAt: stored.createdAt
            )
            return (meta, stored.data.count)
        }
        if let dir = storageDirectory {
            let fileURL = dir.appendingPathComponent(id.rawValue)
            let metaURL = dir.appendingPathComponent("\(id.rawValue).meta.json")
            if FileManager.default.fileExists(atPath: fileURL.path) {
                guard FileManager.default.fileExists(atPath: metaURL.path),
                      let metaData = try? Data(contentsOf: metaURL),
                      let meta = try? JSONDecoder().decode(PersistedMeta.self, from: metaData) else {
                    // 关键安全防御：元数据丢失或损坏时坚决 Fail-Closed，绝不自动降级为 .global 造成越权泄露！
                    throw RuntimeError(
                        category: .validation,
                        code: "corruptedContentMetadata",
                        message: "Content metadata for \(id.rawValue) is missing or corrupted; access rejected for security",
                        retryability: .none,
                        source: .core
                    )
                }
                let attrs = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) ?? [:]
                let fileSize = (attrs[.size] as? Int) ?? 0
                return (meta, fileSize)
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

    private func resolveContent(id: ContentID) throws -> StoredContent {
        if let stored = contents[id] {
            return stored
        }
        if let dir = storageDirectory {
            let fileURL = dir.appendingPathComponent(id.rawValue)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let (meta, _) = try resolveMetadata(id: id)
                let data = (try? Data(contentsOf: fileURL)) ?? Data()
                let loaded = StoredContent(
                    id: id,
                    data: data,
                    mediaType: meta.mediaType,
                    digest: meta.digest,
                    filename: meta.filename,
                    scope: meta.scope,
                    createdAt: meta.createdAt
                )
                rememberContent(loaded)
                return loaded
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

    /// 纯 Cold 磁盘范围读取：直接通过 FileHandle seek & read，绝不将全量大文件载入内存 (Audit Round 7 Phase E)
    public func readRange(id: ContentID, offset: Int, length: Int, authorization: ContentAuthorizationContext = .system) throws -> Data {
        let (meta, _) = try resolveMetadata(id: id)
        guard authorization.isAuthorized(for: meta.scope) else {
            throw RuntimeError(
                category: .permission,
                code: "contentAccessDenied",
                message: "Access to Content \(id.rawValue) with scope \(meta.scope) is denied for given authorization context",
                retryability: .none,
                source: .core
            )
        }
        guard offset >= 0, length > 0 else {
            return Data()
        }

        if let dir = storageDirectory {
            let fileURL = dir.appendingPathComponent(id.rawValue)
            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forReadingFrom: fileURL) {
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(offset))
                let chunk = try handle.read(upToCount: length) ?? Data()
                return chunk
            }
        }

        // 内存回退切片
        if let stored = contents[id] {
            guard offset < stored.data.count else {
                return Data()
            }
            let end = min(stored.data.count, offset + length)
            return stored.data.subdata(in: offset..<end)
        }

        return Data()
    }

    /// 纯元数据读取：完全不读取正文数据，零正文内存开销 (Audit Round 7 Phase E)
    public func metadata(id: ContentID, authorization: ContentAuthorizationContext = .system) throws -> ContentMetadata {
        let (meta, byteCount) = try resolveMetadata(id: id)
        guard authorization.isAuthorized(for: meta.scope) else {
            throw RuntimeError(
                category: .permission,
                code: "contentAccessDenied",
                message: "Access to Content \(id.rawValue) with scope \(meta.scope) is denied for given authorization context",
                retryability: .none,
                source: .core
            )
        }
        let tokenEstimate = max(1, byteCount / 4)
        let ref = ContentRef(
            id: id,
            mediaType: meta.mediaType,
            byteCount: byteCount,
            tokenEstimate: tokenEstimate,
            digest: meta.digest
        )
        return ContentMetadata(ref: ref, createdAt: meta.createdAt, filename: meta.filename, scope: meta.scope)
    }
}
