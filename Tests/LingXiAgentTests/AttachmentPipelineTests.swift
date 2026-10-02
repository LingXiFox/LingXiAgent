#if canImport(ImageIO)
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
import LingXiProtocol
@testable import LingXiCore

@Suite("Attachment pipeline and latency trace", .serialized)
struct AttachmentPipelineTests {
    private static func photo(at url: URL, width: Int = 3000, height: Int = 2000) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for x in stride(from: 0, to: width, by: 5) {
            context.setFillColor(CGColor(red: CGFloat(x % 255) / 255, green: 0.3, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 2, height: height))
        }
        let image = try #require(context.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
    }

    private static func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lx-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private actor CountingUploader: ProviderFileUploading {
        nonisolated var supportsFileUploads: Bool { true }
        private(set) var count = 0
        func uploadFile(_ data: Data, mediaType: String, filename: String) async throws -> String {
            count += 1
            try await Task.sleep(for: .milliseconds(30))
            return "file-\(count)"
        }
    }

    @Test("Preparation runs once per file version and the disk cache survives a new store")
    func prepareIsDedupedAndCached() async throws {
        let dir = try Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("p.jpg")
        try Self.photo(at: photo)
        let cache = dir.appendingPathComponent("cache")

        let store = AttachmentStore(cacheDirectory: cache)
        let first = try await store.prepare(path: photo.path)
        let again = try await store.prepare(path: photo.path)
        #expect(first == again, "同一文件版本必须复用进行中的准备任务")
        let prepared = try await first.value
        #expect(prepared.isImage && !prepared.fromCache)
        #expect((prepared.payload?.count ?? .max) < prepared.originalBytes)
        #expect(prepared.sha256?.count == 64)

        let restarted = AttachmentStore(cacheDirectory: cache)
        let reused = try await restarted.resolve(path: photo.path)
        #expect(reused.fromCache, "按 SHA256 命中磁盘缓存时不应重新压缩")
        #expect(reused.payload == prepared.payload)
    }

    @Test("A non-image is referenced by path only: nothing read, nothing hashed")
    func nonImageIsPathOnly() async throws {
        let dir = try Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = dir.appendingPathComponent("n.md")
        try Data("# hi".utf8).write(to: note)
        let prepared = try await AttachmentStore(cacheDirectory: nil).resolve(path: note.path)
        #expect(!prepared.isImage && prepared.sha256 == nil)
    }

    @Test("The same content is uploaded to a provider once, even from two places at once")
    func uploadIsCachedByHashAndEndpoint() async throws {
        let dir = try Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("p.jpg")
        try Self.photo(at: photo)
        let copy = dir.appendingPathComponent("copy.jpg")
        try FileManager.default.copyItem(at: photo, to: copy)
        let store = AttachmentStore(cacheDirectory: dir.appendingPathComponent("cache"))
        let uploader = CountingUploader()
        async let a = store.upload(path: photo.path, endpointKey: "openai|-|x", using: uploader)
        async let b = store.upload(path: photo.path, endpointKey: "openai|-|x", using: uploader)
        let ids = try await [a.fileID, b.fileID]
        #expect(ids[0] == ids[1])
        let fromCopy = try await store.upload(path: copy.path, endpointKey: "openai|-|x", using: uploader)
        #expect(fromCopy.fileID == ids[0], "内容相同的文件按 SHA256 复用已上传的 file id")
        #expect(await uploader.count == 1)
        let other = try await store.upload(path: photo.path, endpointKey: "anthropic|-|y", using: uploader)
        #expect(other.fileID != ids[0], "file id 按 Provider 端点隔离")
        let resolved = try await store.resolve(path: photo.path)
        #expect(resolved.uploadStarted != nil && resolved.providerFileReady != nil)
    }

    @Test("A provider-held image is referenced where the adapter has a Files API, inline elsewhere")
    func fileReferenceEncoding() throws {
        let part = ModelContentPart.imageFile(mediaType: "image/jpeg", data: Data([1, 2]), fileID: "file-9")
        let request = ModelRequest(model: ModelID("m"), messages: [ModelMessage(role: .user, parts: [.text("看图"), part])])

        let responses = try #require(JSONSerialization.jsonObject(with: OpenAIResponsesProvider.makeRequestBody(request)) as? [String: Any])
        let content = try #require(((responses["input"] as? [[String: Any]])?.first?["content"]) as? [[String: String]])
        #expect(content.last == ["type": "input_image", "file_id": "file-9"])

        let anthropic = try #require(JSONSerialization.jsonObject(with: AnthropicMessagesProvider.makeRequestBody(request)) as? [String: Any])
        let block = try #require(((anthropic["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.last)
        #expect(block["source"] as? [String: String] == ["type": "file", "file_id": "file-9"])

        let chat = try #require(JSONSerialization.jsonObject(with: OpenAICompatibleProvider.makeRequestBody(request)) as? [String: Any])
        let chatPart = try #require(((chat["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])?.last)
        #expect(((chatPart["image_url"] as? [String: String])?["url"])?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    @Test("The latency report separates upload time from provider wait")
    func latencyVerdict() async throws {
        let recorder = TurnLatencyRecorder()
        let t0 = Date(timeIntervalSince1970: 1_000)
        await recorder.mark(.messageSendRequested, run: "r", at: t0)
        await recorder.mark(.inferenceRequestStarted, run: "r", at: t0.addingTimeInterval(0.1))
        await recorder.mark(.requestBodySent, run: "r", at: t0.addingTimeInterval(0.4))
        await recorder.mark(.responseStart, run: "r", at: t0.addingTimeInterval(4.4))
        await recorder.mark(.firstReasoningDelta, run: "r", at: t0.addingTimeInterval(5.0))
        await recorder.mark(.completed, run: "r", at: t0.addingTimeInterval(9.0))
        let report = try #require(await recorder.finish(run: "r"))
        #expect(report.inlineUploadMs == 300)
        #expect(report.providerWaitMs == 4_000)
        #expect(report.verdict.hasPrefix("B:"))
        #expect(report.rows.map(\.cumulativeMs) == [0, 100, 400, 4_400, 5_000, 9_000])
        #expect(report.traceMetadata.keys.allSatisfy { !$0.lowercased().contains("header") && !$0.lowercased().contains("token") })
        #expect(await recorder.finish(run: "r") == nil, "报告取走后记录应清空")
    }
}
#endif
