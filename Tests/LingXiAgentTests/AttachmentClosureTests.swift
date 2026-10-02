import Foundation
import Testing
@testable import LingXiCore
import LingXiProtocol

/// §3 of the GUI↔Core closure contract: an attachment is not an attachment until Core holds
/// the bytes and the turn carries them.
///
/// The defect this replaces was cosmetic — the composer's "文件或图片…" spliced `@/abs/path`
/// into the text field, the strip rendered nothing, and `UserInput.attachments` stayed empty on
/// every path. Two things had to be true for that to stop being possible: the upload has to be
/// the real content plane, and a file Core cannot put in front of a model has to fail out loud.
@Suite("Attachment closure", .serialized)
struct AttachmentClosureTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - The content plane is real

    @Test("an uploaded file comes back as a ContentRef Core can read again")
    func uploadRoundTrip() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment_closure_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let host = try CoreHost(workspaceRoot: try WorkspaceRoot(path: temp.path), dataRoot: temp)
        let payload = "func hello() { print(\"closure\") }\n"
        let begin = try await host.beginContentUpload(envelope: CommandEnvelope(payload:
            BeginContentUploadRequest(filename: "hello.swift",
                                      proposedMediaType: "text/x-swift",
                                      expectedByteCount: payload.utf8.count,
                                      scope: .global)))
        let uploadID = try #require(begin.result?.uploadID)
        try await host.uploadContentChunk(uploadID: uploadID, chunkIndex: 0,
                                          data: Data(payload.utf8))
        let commit = try await host.commitContentUpload(envelope: CommandEnvelope(payload:
            CommitContentUploadRequest(uploadID: uploadID, expectedDigest: nil)))
        let ref = try #require(commit.result)

        #expect(ref.byteCount == payload.utf8.count, "引用必须带上真实字节数，上限判断靠它")
        #expect(ref.mediaType == "text/x-swift")
        let readBack = try await host.getContent(ref: ref, authorization: .system)
        #expect(String(data: readBack, encoding: .utf8) == payload,
                "上传的字节和取回的字节不一致，附件就不算进入 Core")
    }

    @Test("an aborted upload leaves nothing addressable")
    func abortDoesNotFakeSuccess() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment_abort_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let host = try CoreHost(workspaceRoot: try WorkspaceRoot(path: temp.path), dataRoot: temp)

        let begin = try await host.beginContentUpload(envelope: CommandEnvelope(payload:
            BeginContentUploadRequest(filename: "gone.txt", proposedMediaType: "text/plain",
                                      expectedByteCount: 4, scope: .global)))
        let uploadID = try #require(begin.result?.uploadID)
        _ = try await host.abortContentUpload(envelope: CommandEnvelope(payload:
            AbortContentUploadRequest(uploadID: uploadID)))
        // The GUI aborts on a failed chunk; a committed ref afterwards would be a phantom file.
        await #expect(throws: (any Error).self) {
            _ = try await host.commitContentUpload(envelope: CommandEnvelope(payload:
                CommitContentUploadRequest(uploadID: uploadID, expectedDigest: nil)))
        }
    }

    // MARK: - The chain exists end to end

    /// Each hop below is a line that has to name the attached files or the feature is
    /// decoration again. Core runs beside the files, so they travel by path, not by upload.
    @Test("every hop from the composer to the model request carries the files")
    func chainIsWiredEndToEnd() throws {
        let hops: [(file: String, needle: String, why: String)] = [
            ("Apps/macOS/FrontendKit/Components/ComposerDock.swift", "model.attachments.append",
             "选择文件必须进入附件列表，而不是拼成一段 @路径 文本"),
            ("Apps/macOS/FrontendKit/Components/ComposerDock.swift", "runtime.prepareAttachment(id: item.id, url: url)",
             "选中附件就要开始准备，而不是等到发送"),
            ("Apps/macOS/FrontendKit/Frontend/RuntimeFrontend.swift",
             ".submitPrompt(text: text, fileReferences: paths)",
             "附件路径必须进入提交动作"),
            ("Sources/LingXiApplication/ApplicationStore.swift", "contextReferences: fileReferences",
             "路径必须进入本轮的执行意图"),
            ("Sources/LingXiCore/App/CoreHost.swift", "resolveFileReferences(executionIntent.contextReferences, run:",
             "Core 必须把路径解析为附件交给 Agent Loop"),
            ("Sources/LingXiCore/Modules/Session/SessionRuntime.swift", "source: .attachment",
             "附件要成为自己的上下文条目，模型才看得见"),
        ]
        for hop in hops {
            let text = try Self.source(hop.file)
            #expect(text.contains(hop.needle), "\(hop.file)：\(hop.why)")
        }
    }

    @Test("a file that went away fails the send instead of being dropped")
    func missingFileAbortsSubmission() throws {
        let text = try Self.source("Apps/macOS/FrontendKit/Frontend/RuntimeFrontend.swift")
        let start = try #require(text.range(of: "private func submitWithFiles"))
        let lines = Array(text[start.lowerBound...].components(separatedBy: "\n").prefix(while: { !$0.hasPrefix("    }") }))
        let failures = lines.enumerated().filter { $0.element.contains("actionError =") }
        #expect(failures.count >= 3, "未连接/不在本机/已移动三条失败路径都要可见报错")
        for (offset, _) in failures {
            let following = lines[(offset + 1)..<min(offset + 4, lines.count)]
            #expect(following.contains { $0.contains("return") }, "报错后必须中止提交，第 \(offset) 行之后没有 return")
        }
        #expect(!lines.contains { $0.contains("continue") }, "不允许跳过某个附件继续发送")
    }

    /// Whether a model can read a file is the provider's and the model's call, not the
    /// composer's: the GUI attaches any file, Core passes images through as image parts, and
    /// only bytes that are neither image nor text fail — out loud, never by being dropped.
    @Test("the composer refuses no file type, and Core refuses only what no model could read")
    func onlyUnreadableBytesAreRefused() throws {
        let gui = try Self.source("Apps/macOS/FrontendKit/Components/ComposerDock.swift")
        #expect(!gui.contains("unsupportedReason"), "前端不应再按扩展名拦截附件")
        let core = try Self.source("Sources/LingXiCore/App/CoreHost.swift")
        #expect(core.contains("hasPrefix(\"image/\")") && core.contains("imageData: payload.data"),
                "图片必须以图片内容交给 Provider，而不是在 Core 里被当作“非文本”拒掉")
        #expect(core.contains("binaryFileUnsupported"),
                "既不是图片也不是文本的字节仍要明确失败，不能静默丢掉")
    }
}
