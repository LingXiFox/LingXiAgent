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
        var chunkDigests: [UInt64: String]
        var receivedIndices: Set<UInt64>
        var nextExpectedChunkIndex: UInt64
        var totalBytesWritten: Int
    }

    private struct StoredMetadata: Sendable {
        let id: ContentID
        let byteCount: Int
        let mediaType: String?
        let digest: String
        let filename: String?
        let scope: ContentAuthorizationScope
        let createdAt: Date
    }

    private struct PersistedMeta: Codable {
        let id: String
        let byteCount: Int?
        let mediaType: String?
        let digest: String
        let filename: String?
        let scope: ContentAuthorizationScope
        let createdAt: Date
    }

    private var inProgress: [String: InProgressUpload] = [:]
    private var metaCache: [ContentID: StoredMetadata] = [:]
    private var byteCache: [ContentID: Data] = [:]
    private var memoryKeys: [ContentID] = []
    private var currentMemoryBytes: Int = 0
    private let maxMemoryBytes: Int = 32 * 1024 * 1024 // 32MB 内存上限
    private let maxCacheableSingleItemBytes: Int = 8 * 1024 * 1024 // 单个项目 <=8MB 才进 byteCache
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

    private func rememberMetadata(_ meta: StoredMetadata) {
        metaCache[meta.id] = meta
    }

    private func cacheBytes(id: ContentID, data: Data) {
        guard data.count <= maxCacheableSingleItemBytes else { return }
        if let old = byteCache[id] {
            currentMemoryBytes -= old.count
            memoryKeys.removeAll(where: { $0 == id })
        }
        byteCache[id] = data
        currentMemoryBytes += data.count
        memoryKeys.append(id)

        while currentMemoryBytes > maxMemoryBytes, !memoryKeys.isEmpty {
            let evictedKey = memoryKeys.removeFirst()
            if let evicted = byteCache.removeValue(forKey: evictedKey) {
                currentMemoryBytes -= evicted.count
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
            chunkDigests: [:],
            receivedIndices: [],
            nextExpectedChunkIndex: 0,
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

        let chunkDigest = LingXiPlatform.crypto.sha256Hex(data)

        // 幂等处理网络重试导致的重复分片，避免重复追加损坏数据；生产磁盘与内存模式均严格冲突校验 (Audit Round 9 Phase B & Round 10 Phase B)
        if upload.receivedIndices.contains(chunkIndex) {
            if let existingDigest = upload.chunkDigests[chunkIndex] {
                if existingDigest != chunkDigest {
                    throw RuntimeError(
                        category: .validation,
                        code: "chunkConflict",
                        message: "Chunk index \(chunkIndex) payload conflicts with previously received chunk",
                        retryability: .none,
                        source: .client
                    )
                }
            } else if let existing = upload.chunks[chunkIndex], existing != data {
                throw RuntimeError(
                    category: .validation,
                    code: "chunkConflict",
                    message: "Chunk index \(chunkIndex) payload conflicts with previously received chunk",
                    retryability: .none,
                    source: .client
                )
            }
            return
        }

        // 关键防御：严格强制分片顺序，杜绝乱序分片静默损坏文件内容 (Audit Round 8 Phase D)
        guard chunkIndex == upload.nextExpectedChunkIndex else {
            throw RuntimeError(
                category: .validation,
                code: "outOfOrderChunk",
                message: "Chunk index \(chunkIndex) is out of order; expected \(upload.nextExpectedChunkIndex)",
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
        guard upload.receivedIndices.count < 10000 else {
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
            // 磁盘暂存：精确寻道写入，写入异常立即 truncate 回滚，杜绝重试数据拼接损坏 (Audit Round 10 Phase B)
            let handle = try FileHandle(forWritingTo: stagingURL)
            defer { try? handle.close() }
            let writeOffset = UInt64(upload.totalBytesWritten)
            do {
                try handle.seek(toOffset: writeOffset)
                try handle.write(contentsOf: data)
            } catch {
                try? handle.truncate(atOffset: writeOffset)
                throw error
            }
        } else {
            upload.chunks[chunkIndex] = data
        }

        upload.chunkDigests[chunkIndex] = chunkDigest
        upload.receivedIndices.insert(chunkIndex)
        upload.nextExpectedChunkIndex += 1
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

        if let stagingURL = upload.stagingFileURL, let dir = storageDirectory {
            let calculatedDigest: String
            do {
                let handle = try FileHandle(forReadingFrom: stagingURL)
                defer { try? handle.close() }
                var hasher = LingXiPlatform.crypto.makeSHA256Hasher()
                while true {
                    let chunk = handle.readData(ofLength: 64 * 1024)
                    if chunk.isEmpty { break }
                    hasher.update(data: chunk)
                }
                calculatedDigest = "sha256:" + hasher.finalizeHex()
            } catch {
                try? FileManager.default.removeItem(at: stagingURL)
                inProgress.removeValue(forKey: request.uploadID)
                throw RuntimeError(
                    category: .runtime,
                    code: "digestCalculationFailed",
                    message: "Failed to compute digest: \(error.localizedDescription)",
                    retryability: .none,
                    source: .core
                )
            }
            digestString = calculatedDigest

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

            // 原子重命名 staging 文件为正式内容文件，并严格校验写入 metadata，严禁静默吞错 (Audit Round 8 Phase D)
            let finalFileURL = dir.appendingPathComponent(contentID.rawValue)
            let metaURL = dir.appendingPathComponent("\(contentID.rawValue).meta.json")
            try? FileManager.default.removeItem(at: finalFileURL)
            try FileManager.default.moveItem(at: stagingURL, to: finalFileURL)

            let meta = PersistedMeta(
                id: contentID.rawValue,
                byteCount: upload.totalBytesWritten,
                mediaType: upload.proposedMediaType,
                digest: digestString,
                filename: upload.filename,
                scope: upload.scope,
                createdAt: Date()
            )
            do {
                let metaData = try JSONEncoder().encode(meta)
                try metaData.write(to: metaURL, options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: finalFileURL)
                try? FileManager.default.removeItem(at: metaURL)
                throw RuntimeError(
                    category: .runtime,
                    code: "metadataWriteFailed",
                    message: "Failed to persist content metadata: \(error.localizedDescription)",
                    retryability: .none,
                    source: .core
                )
            }

            let storedMeta = StoredMetadata(
                id: contentID,
                byteCount: upload.totalBytesWritten,
                mediaType: upload.proposedMediaType,
                digest: digestString,
                filename: upload.filename,
                scope: upload.scope,
                createdAt: meta.createdAt
            )
            rememberMetadata(storedMeta)

            // 仅对不超过单项阈值的小文件进行内存 byte 预热缓存，严禁将空 Data 写入 byte 缓存 (Audit Round 9 Phase B)
            if upload.totalBytesWritten <= maxCacheableSingleItemBytes {
                if let smallData = try? Data(contentsOf: finalFileURL) {
                    cacheBytes(id: contentID, data: smallData)
                }
            }
        } else {
            var memData = Data()
            for idx in sortedIndices {
                if let chunk = upload.chunks[idx] {
                    memData.append(chunk)
                }
            }
            digestString = "sha256:" + LingXiPlatform.crypto.sha256Hex(memData)

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

            let createdAt = Date()
            if let dir = storageDirectory {
                let finalFileURL = dir.appendingPathComponent(contentID.rawValue)
                let metaURL = dir.appendingPathComponent("\(contentID.rawValue).meta.json")
                do {
                    try memData.write(to: finalFileURL, options: .atomic)
                    let meta = PersistedMeta(
                        id: contentID.rawValue,
                        byteCount: memData.count,
                        mediaType: upload.proposedMediaType,
                        digest: digestString,
                        filename: upload.filename,
                        scope: upload.scope,
                        createdAt: createdAt
                    )
                    let metaData = try JSONEncoder().encode(meta)
                    try metaData.write(to: metaURL, options: .atomic)
                } catch {
                    try? FileManager.default.removeItem(at: finalFileURL)
                    try? FileManager.default.removeItem(at: metaURL)
                    throw RuntimeError(
                        category: .runtime,
                        code: "storageWriteFailed",
                        message: "Failed to persist content body or metadata: \(error.localizedDescription)",
                        retryability: .none,
                        source: .core
                    )
                }
            }

            let storedMeta = StoredMetadata(
                id: contentID,
                byteCount: memData.count,
                mediaType: upload.proposedMediaType,
                digest: digestString,
                filename: upload.filename,
                scope: upload.scope,
                createdAt: createdAt
            )
            rememberMetadata(storedMeta)
            cacheBytes(id: contentID, data: memData)
        }

        inProgress.removeValue(forKey: request.uploadID)

        let finalByteCount = upload.totalBytesWritten
        let tokenEstimate = max(1, finalByteCount / 4)
        return ContentRef(
            id: contentID,
            mediaType: upload.proposedMediaType,
            byteCount: finalByteCount,
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
    ) throws -> ContentRef {
        let digestString = "sha256:" + LingXiPlatform.crypto.sha256Hex(data)
        let contentID = ContentID(UUID().uuidString)
        let createdAt = Date()

        if let dir = storageDirectory {
            let fileURL = dir.appendingPathComponent(contentID.rawValue)
            let metaURL = dir.appendingPathComponent("\(contentID.rawValue).meta.json")
            do {
                try data.write(to: fileURL, options: .atomic)
                let meta = PersistedMeta(
                    id: contentID.rawValue,
                    byteCount: data.count,
                    mediaType: mediaType,
                    digest: digestString,
                    filename: filename,
                    scope: scope,
                    createdAt: createdAt
                )
                let metaData = try JSONEncoder().encode(meta)
                try metaData.write(to: metaURL, options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                try? FileManager.default.removeItem(at: metaURL)
                throw RuntimeError(
                    category: .runtime,
                    code: "storageWriteFailed",
                    message: "Failed to persist content body or metadata: \(error.localizedDescription)",
                    retryability: .none,
                    source: .core
                )
            }
        }

        let storedMeta = StoredMetadata(
            id: contentID,
            byteCount: data.count,
            mediaType: mediaType,
            digest: digestString,
            filename: filename,
            scope: scope,
            createdAt: createdAt
        )
        rememberMetadata(storedMeta)
        cacheBytes(id: contentID, data: data)

        let tokenEstimate = max(1, data.count / 4)
        return ContentRef(
            id: contentID,
            mediaType: mediaType,
            byteCount: data.count,
            tokenEstimate: tokenEstimate,
            digest: digestString
        )
    }

    /// 仅解析元数据与文件大小，绝对不将冷文件正文加载至内存 (Audit Round 7 Phase E & Round 9 Phase B)
    private func resolveMetadata(id: ContentID) throws -> StoredMetadata {
        if let stored = metaCache[id] {
            return stored
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

                let actualByteCount: Int
                if let count = meta.byteCount {
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                       let fileSize = attrs[.size] as? Int,
                       fileSize != count {
                        throw RuntimeError(
                            category: .validation,
                            code: "contentLengthMismatch",
                            message: "Content body size (\(fileSize) bytes) does not match metadata (\(count) bytes) for \(id.rawValue)",
                            retryability: .none,
                            source: .core
                        )
                    }
                    actualByteCount = count
                } else {
                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                          let fileSize = attrs[.size] as? Int else {
                        throw RuntimeError(
                            category: .runtime,
                            code: "storageReadFailed",
                            message: "Failed to read content attributes for \(id.rawValue)",
                            retryability: .none,
                            source: .core
                        )
                    }
                    actualByteCount = fileSize
                }

                let storedMeta = StoredMetadata(
                    id: id,
                    byteCount: actualByteCount,
                    mediaType: meta.mediaType,
                    digest: meta.digest,
                    filename: meta.filename,
                    scope: meta.scope,
                    createdAt: meta.createdAt
                )
                metaCache[id] = storedMeta
                return storedMeta
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
        let meta = try resolveMetadata(id: id)
        guard authorization.isAuthorized(for: meta.scope) else {
            throw RuntimeError(
                category: .permission,
                code: "contentAccessDenied",
                message: "Access to Content \(id.rawValue) with scope \(meta.scope) is denied for given authorization context",
                retryability: .none,
                source: .core
            )
        }

        if let cachedData = byteCache[id] {
            return cachedData
        }

        if let dir = storageDirectory {
            let fileURL = dir.appendingPathComponent(id.rawValue)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw RuntimeError(
                    category: .tool,
                    code: "resourceNotFound",
                    message: "Content ID \(id.rawValue) 不存在于磁盘",
                    retryability: .none,
                    source: .core
                )
            }
            do {
                let data = try Data(contentsOf: fileURL)
                cacheBytes(id: id, data: data)
                return data
            } catch {
                throw RuntimeError(
                    category: .runtime,
                    code: "storageReadFailed",
                    message: "Failed to read content file: \(error.localizedDescription)",
                    retryability: .none,
                    source: .core
                )
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

    /// 纯 Cold 磁盘范围读取：直接通过 FileHandle seek & read，绝不将全量大文件载入内存 (Audit Round 7 Phase E & Round 9 Phase B)
    public func readRange(id: ContentID, offset: Int, length: Int, authorization: ContentAuthorizationContext = .system) throws -> Data {
        let meta = try resolveMetadata(id: id)
        guard authorization.isAuthorized(for: meta.scope) else {
            throw RuntimeError(
                category: .permission,
                code: "contentAccessDenied",
                message: "Access to Content \(id.rawValue) with scope \(meta.scope) is denied for given authorization context",
                retryability: .none,
                source: .core
            )
        }
        guard offset >= 0, length > 0, offset < meta.byteCount else {
            return Data()
        }

        // 安全计算范围终点，防止 offset + length 整数溢出导致 Swift trap (Audit Round 10 Phase B)
        let end: Int
        let (sum, overflow) = offset.addingReportingOverflow(length)
        if overflow || sum >= meta.byteCount {
            end = meta.byteCount
        } else {
            end = sum
        }
        let sliceLength = end - offset
        guard sliceLength > 0 else {
            return Data()
        }

        if let cachedData = byteCache[id] {
            return cachedData.subdata(in: offset..<end)
        }

        if let dir = storageDirectory {
            let fileURL = dir.appendingPathComponent(id.rawValue)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw RuntimeError(
                    category: .tool,
                    code: "resourceNotFound",
                    message: "Content ID \(id.rawValue) 不存在于磁盘",
                    retryability: .none,
                    source: .core
                )
            }
            do {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(offset))
                let chunk = try handle.read(upToCount: sliceLength) ?? Data()
                return chunk
            } catch {
                throw RuntimeError(
                    category: .runtime,
                    code: "storageReadFailed",
                    message: "Failed to read content range from disk: \(error.localizedDescription)",
                    retryability: .none,
                    source: .core
                )
            }
        }

        return Data()
    }

    /// 纯元数据读取：完全不读取正文数据，零正文内存开销 (Audit Round 7 Phase E & Round 9 Phase B)
    public func metadata(id: ContentID, authorization: ContentAuthorizationContext = .system) throws -> ContentMetadata {
        let meta = try resolveMetadata(id: id)
        guard authorization.isAuthorized(for: meta.scope) else {
            throw RuntimeError(
                category: .permission,
                code: "contentAccessDenied",
                message: "Access to Content \(id.rawValue) with scope \(meta.scope) is denied for given authorization context",
                retryability: .none,
                source: .core
            )
        }
        let tokenEstimate = max(1, meta.byteCount / 4)
        let ref = ContentRef(
            id: id,
            mediaType: meta.mediaType,
            byteCount: meta.byteCount,
            tokenEstimate: tokenEstimate,
            digest: meta.digest
        )
        return ContentMetadata(ref: ref, createdAt: meta.createdAt, filename: meta.filename, scope: meta.scope)
    }
}
