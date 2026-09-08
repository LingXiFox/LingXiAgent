import Foundation
import LingXiProtocol

public enum ClientError: Error, Sendable, Equatable {
    case uploadFailed(String)
    case downloadFailed(String)
    case timeout(String)
    case connectionFailed(String)
    case internalError(String)
}

public struct ResourceDomainClient: Sendable {
    private let transport: any ClientTransport

    public init(transport: any ClientTransport) {
        self.transport = transport
    }

    /// 高层便捷 API：上传二进制数据（自动分块、校验并提交，失败自动中止）
    public func upload(
        data: Data,
        filename: String,
        mediaType: String? = nil,
        scope: ContentAuthorizationScope = .global,
        chunkSize: Int = 64 * 1024
    ) async throws -> ContentRef {
        let beginReq = BeginContentUploadRequest(
            filename: filename,
            proposedMediaType: mediaType,
            expectedByteCount: data.count,
            scope: scope
        )
        let beginReceipt = try await transport.beginContentUpload(envelope: CommandEnvelope(payload: beginReq))
        guard let uploadID = beginReceipt.result?.uploadID else {
            throw ClientError.uploadFailed("beginContentUpload did not return uploadID")
        }

        do {
            var offset = 0
            var chunkIndex: UInt64 = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                let chunk = data.subdata(in: offset..<end)
                try await transport.uploadContentChunk(uploadID: uploadID, chunkIndex: chunkIndex, data: chunk)
                offset = end
                chunkIndex += 1
            }

            if data.isEmpty {
                try await transport.uploadContentChunk(uploadID: uploadID, chunkIndex: 0, data: Data())
            }

            let commitReq = CommitContentUploadRequest(uploadID: uploadID, expectedDigest: nil)
            let commitReceipt = try await transport.commitContentUpload(envelope: CommandEnvelope(payload: commitReq))
            guard let ref = commitReceipt.result else {
                throw ClientError.uploadFailed("commitContentUpload did not return ContentRef")
            }
            return ref
        } catch {
            let abortReq = AbortContentUploadRequest(uploadID: uploadID)
            _ = try? await transport.abortContentUpload(envelope: CommandEnvelope(payload: abortReq))
            throw error
        }
    }

    /// 高层便捷 API：下载完整内容（授权上下文由 Transport 连接层安全注入）
    public func download(ref: ContentRef) async throws -> Data {
        try await transport.getContent(ref: ref, authorization: transport.authorizationContext)
    }

    /// 高层便捷 API：按区间读取内容字节
    public func range(ref: ContentRef, offset: Int, length: Int) async throws -> Data {
        try await transport.getContentRange(ref: ref, offset: offset, length: length, authorization: transport.authorizationContext)
    }

    /// 高层便捷 API：查询内容元数据
    public func metadata(ref: ContentRef) async throws -> ContentMetadata {
        try await transport.getContentMetadata(ref: ref, authorization: transport.authorizationContext)
    }

    // MARK: - 低层分步上传控制面接口

    public func beginUpload(
        filename: String,
        expectedByteCount: Int,
        mediaType: String? = nil,
        scope: ContentAuthorizationScope = .global
    ) async throws -> CommandReceipt<BeginContentUploadResponse> {
        let req = BeginContentUploadRequest(
            filename: filename,
            proposedMediaType: mediaType,
            expectedByteCount: expectedByteCount,
            scope: scope
        )
        return try await transport.beginContentUpload(envelope: CommandEnvelope(payload: req))
    }

    public func uploadChunk(uploadID: String, chunkIndex: UInt64, data: Data) async throws {
        try await transport.uploadContentChunk(uploadID: uploadID, chunkIndex: chunkIndex, data: data)
    }

    public func commitUpload(uploadID: String, expectedDigest: String? = nil) async throws -> CommandReceipt<ContentRef> {
        let req = CommitContentUploadRequest(uploadID: uploadID, expectedDigest: expectedDigest)
        return try await transport.commitContentUpload(envelope: CommandEnvelope(payload: req))
    }

    public func abortUpload(uploadID: String) async throws -> CommandReceipt<VoidResult> {
        let req = AbortContentUploadRequest(uploadID: uploadID)
        return try await transport.abortContentUpload(envelope: CommandEnvelope(payload: req))
    }
}
