import Foundation
import LingXiProtocol
import LingXiPlatform

// MARK: - Attachment store
//
// Attachments used to be prepared inside the turn: the user picked a file, nothing happened,
// and only after ⏎ did Core read, decode, resize and encode it, in series with the model
// request. This store takes that work off the send path. The composer calls `prepare` the
// moment a file is picked; by the time the user has typed the question the image is
// normalized, hashed and — where the provider has a Files API — already uploaded. A turn then
// only looks the result up (`resolve`), and if preparation is still running it waits for that
// same task instead of starting over.
//
// Deliberately mechanical: it reads, resizes, hashes, caches and uploads. It does no OCR, no
// captioning, no summarising, and it never decides whether a model can read a file.

/// A local file made ready to go on the wire.
public struct PreparedAttachment: Sendable, Equatable {
    public let path: String
    public let filename: String
    /// SHA-256 of the original bytes for an image; nil for a file sent by path only.
    public let sha256: String?
    public let mediaType: String
    public let originalBytes: Int
    /// The normalized bytes a provider receives inline; nil for a non-image.
    public let payload: Data?
    /// Provider file references by endpoint key, so a reused attachment is never uploaded twice.
    public var remoteRefs: [String: String]
    public let selectedAt: Date
    public let preprocessStarted: Date
    public let preprocessDone: Date
    public var uploadStarted: Date?
    public var providerFileReady: Date?
    public let fromCache: Bool

    public var isImage: Bool { payload != nil }
}

/// A provider that can hold a file and be pointed at it by reference.
public protocol ProviderFileUploading: Sendable {
    /// Whether this endpoint really has a Files API the adapter can reference later.
    var supportsFileUploads: Bool { get }
    /// Uploads bytes and returns the provider's file id. Throws when the upload fails; the
    /// caller then sends the attachment inline, so a failed upload never fails a turn.
    func uploadFile(_ data: Data, mediaType: String, filename: String) async throws -> String
}

public actor AttachmentStore {
    public static let imageMediaTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "heic": "image/heic", "heif": "image/heif", "bmp": "image/bmp",
        "tif": "image/tiff", "tiff": "image/tiff",
    ]

    private let cacheDirectory: URL?
    /// path|size|mtime → the preparation for that exact version of the file.
    private var tasks: [String: Task<PreparedAttachment, Error>] = [:]
    private var uploads: [String: Task<String, Error>] = [:]
    /// When each content hash's most recent provider upload started and finished.
    private var uploadTimes: [String: (started: Date, ready: Date?)] = [:]

    public init(cacheDirectory: URL?) {
        self.cacheDirectory = cacheDirectory
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: Preparation

    /// Starts (or joins) preparation of a file. Idempotent per file version.
    @discardableResult
    public func prepare(path: String, selectedAt: Date = Date()) throws -> Task<PreparedAttachment, Error> {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let key = try Self.signature(of: url)
        if let existing = tasks[key] { return existing }
        let cache = cacheDirectory
        let task = Task.detached(priority: .userInitiated) {
            try Self.prepareNow(url: url, selectedAt: selectedAt, cacheDirectory: cache)
        }
        // Finished preparations hold the normalized bytes; the disk cache has them too, so the
        // in-memory index only needs to cover what a composer is plausibly still holding.
        if tasks.count >= 64, let oldest = tasks.keys.first { tasks[oldest] = nil }
        tasks[key] = task
        return task
    }

    /// What a turn uses: the finished preparation, waiting for one already running rather than
    /// starting again. A file that changed since it was picked is prepared afresh.
    public func resolve(path: String) async throws -> PreparedAttachment {
        var prepared = try await prepare(path: path).value
        if let sha = prepared.sha256 {
            if let refs = remoteRefs(sha: sha) { prepared.remoteRefs.merge(refs) { a, _ in a } }
            if let times = uploadTimes[sha] {
                prepared.uploadStarted = times.started
                prepared.providerFileReady = times.ready
            }
        }
        return prepared
    }

    /// Uploads an image to a provider ahead of the send and caches the file id by content hash
    /// and endpoint. Returns the id, or nil when the attachment is not an image.
    public func upload(path: String, endpointKey: String, using uploader: any ProviderFileUploading)
        async throws -> (attachment: PreparedAttachment, fileID: String?) {
        var prepared = try await prepare(path: path).value
        guard let sha = prepared.sha256, let payload = prepared.payload else { return (prepared, nil) }
        if let cached = remoteRefs(sha: sha)?[endpointKey] {
            prepared.remoteRefs[endpointKey] = cached
            return (prepared, cached)
        }
        let uploadKey = "\(sha)|\(endpointKey)"
        let task: Task<String, Error>
        if let running = uploads[uploadKey] {
            task = running
        } else {
            let media = prepared.mediaType, name = prepared.filename
            task = Task.detached { try await uploader.uploadFile(payload, mediaType: media, filename: name) }
            uploads[uploadKey] = task
        }
        let started = Date()
        prepared.uploadStarted = started
        uploadTimes[sha] = (started, nil)
        do {
            let fileID = try await task.value
            uploads[uploadKey] = nil
            storeRemoteRef(sha: sha, endpointKey: endpointKey, fileID: fileID)
            prepared.remoteRefs[endpointKey] = fileID
            let ready = Date()
            prepared.providerFileReady = ready
            uploadTimes[sha] = (started, ready)
            return (prepared, fileID)
        } catch {
            uploads[uploadKey] = nil
            throw error
        }
    }

    /// A finished upload for this content and endpoint, without waiting for one in flight:
    /// the send path inlines rather than blocking on an upload.
    public func readyFileID(sha: String, endpointKey: String) -> String? {
        remoteRefs(sha: sha)?[endpointKey]
    }

    // MARK: Work

    private static func signature(of url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(size)|\(modified)"
    }

    private static func prepareNow(url: URL, selectedAt: Date, cacheDirectory: URL?) throws -> PreparedAttachment {
        let started = Date()
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CoreError(code: .resourceNotFound, message: "附件「\(name)」已不在原位置：\(url.path)")
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard let imageType = imageMediaTypes[url.pathExtension.lowercased()] else {
            // Not an image: the model is told the path and reads it with its tools if needed.
            return PreparedAttachment(path: url.path, filename: name, sha256: nil,
                                      mediaType: "application/octet-stream", originalBytes: size,
                                      payload: nil, remoteRefs: [:], selectedAt: selectedAt,
                                      preprocessStarted: started, preprocessDone: Date(), fromCache: false)
        }
        let original: Data
        do { original = try Data(contentsOf: url) }
        catch { throw CoreError(code: .resourceNotFound, message: "读取附件「\(name)」失败：\(error.localizedDescription)") }
        let sha = LingXiPlatform.crypto.sha256Hex(original)

        if let cached = cached(sha: sha, in: cacheDirectory) {
            return PreparedAttachment(path: url.path, filename: name, sha256: sha, mediaType: cached.mediaType,
                                      originalBytes: original.count, payload: cached.data,
                                      remoteRefs: cached.refs, selectedAt: selectedAt,
                                      preprocessStarted: started, preprocessDone: Date(), fromCache: true)
        }
        let normalized = ImagePayload.prepared(original, mediaType: imageType)
        store(sha: sha, data: normalized.data, mediaType: normalized.mediaType, in: cacheDirectory)
        return PreparedAttachment(path: url.path, filename: name, sha256: sha, mediaType: normalized.mediaType,
                                  originalBytes: original.count, payload: normalized.data, remoteRefs: [:],
                                  selectedAt: selectedAt, preprocessStarted: started, preprocessDone: Date(),
                                  fromCache: false)
    }

    // MARK: Disk cache — <sha>.bin plus <sha>.json {mediaType, refs}

    private struct Meta: Codable {
        var mediaType: String
        var refs: [String: String]
    }

    private static func cached(sha: String, in directory: URL?) -> (data: Data, mediaType: String, refs: [String: String])? {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("\(sha).bin")),
              let metaData = try? Data(contentsOf: directory.appendingPathComponent("\(sha).json")),
              let meta = try? JSONDecoder().decode(Meta.self, from: metaData) else { return nil }
        return (data, meta.mediaType, meta.refs)
    }

    private static func store(sha: String, data: Data, mediaType: String, in directory: URL?) {
        guard let directory else { return }
        try? data.write(to: directory.appendingPathComponent("\(sha).bin"), options: .atomic)
        if let meta = try? JSONEncoder().encode(Meta(mediaType: mediaType, refs: [:])) {
            try? meta.write(to: directory.appendingPathComponent("\(sha).json"), options: .atomic)
        }
    }

    private func remoteRefs(sha: String) -> [String: String]? {
        guard let directory = cacheDirectory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("\(sha).json")),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return nil }
        return meta.refs
    }

    private func storeRemoteRef(sha: String, endpointKey: String, fileID: String) {
        guard let directory = cacheDirectory else { return }
        let url = directory.appendingPathComponent("\(sha).json")
        guard let data = try? Data(contentsOf: url), var meta = try? JSONDecoder().decode(Meta.self, from: data) else { return }
        meta.refs[endpointKey] = fileID
        if let encoded = try? JSONEncoder().encode(meta) { try? encoded.write(to: url, options: .atomic) }
    }
}
