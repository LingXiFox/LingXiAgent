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

    // MARK: - The policy the composer and Core share

    @Test("text attachments are accepted by extension and everything else is refused")
    func mediaTypePolicy() {
        #expect(AttachmentSupport.mediaType(for: URL(fileURLWithPath: "/tmp/a.swift")) == "text/x-swift")
        #expect(AttachmentSupport.mediaType(for: URL(fileURLWithPath: "/tmp/a.MD")) == "text/markdown")
        #expect(AttachmentSupport.mediaType(for: URL(fileURLWithPath: "/tmp/a.png")) == nil)
        #expect(AttachmentSupport.mediaType(for: URL(fileURLWithPath: "/tmp/noextension")) == nil)
    }

    @Test("the media type Core stores is a type the policy will carry")
    func policyAndStorageAgree() {
        // A file the composer accepts must still be text once it comes back as a ContentRef,
        // otherwise the GUI waves it through and resolveAttachments fails the turn it was told
        // to expect. One list, checked against itself.
        for (ext, mediaType) in AttachmentSupport.textMediaTypes {
            #expect(AttachmentSupport.isText(mediaType: mediaType),
                    "扩展名 .\(ext) 映射到 \(mediaType)，但 isText 不认——上传后会被自己拒掉")
        }
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
                                      proposedMediaType: AttachmentSupport.textMediaTypes["swift"],
                                      expectedByteCount: payload.utf8.count,
                                      scope: .global)))
        let uploadID = try #require(begin.result?.uploadID)
        try await host.uploadContentChunk(uploadID: uploadID, chunkIndex: 0,
                                          data: Data(payload.utf8))
        let commit = try await host.commitContentUpload(envelope: CommandEnvelope(payload:
            CommitContentUploadRequest(uploadID: uploadID, expectedDigest: nil)))
        let ref = try #require(commit.result)

        #expect(ref.byteCount == payload.utf8.count, "引用必须带上真实字节数，上限判断靠它")
        #expect(AttachmentSupport.isText(mediaType: ref.mediaType))
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

    /// The composer used to be the only place attachments existed. Each hop below is a line
    /// that has to name attachments or the feature is decoration again.
    @Test("every hop from the composer to the model request carries the refs")
    func chainIsWiredEndToEnd() throws {
        let hops: [(file: String, needle: String, why: String)] = [
            ("Apps/macOS/FrontendKit/Components/ComposerDock.swift", "model.attachments.append",
             "选择文件必须进入附件列表，而不是拼成一段 @路径 文本"),
            ("Apps/macOS/FrontendKit/Frontend/RuntimeFrontend.swift", "client.resource.upload",
             "提交前必须真的走内容面上传统"),
            ("Apps/macOS/FrontendKit/Frontend/RuntimeFrontend.swift",
             ".submitPrompt(text: text, attachments: refs)",
             "上传结果必须进入提交动作，否则 Core 收不到 ContentRef"),
            ("Sources/LingXiApplication/Actions/ApplicationAction.swift",
             "case submitPrompt(text: String, attachments: [ContentRef]",
             "Application 层要有附件位"),
            ("Sources/LingXiApplication/ApplicationStore.swift",
             "UserInput(text: prompt, attachments: attachments)",
             "必须进入 UserInput.attachments"),
            ("Sources/LingXiCore/App/CoreHost.swift", "attachments: resolvedAttachments",
             "Core 必须把附件交给 Agent Loop，而不是收下就丢"),
            ("Sources/LingXiCore/Modules/Session/SessionRuntime.swift", "source: .attachment",
             "附件要成为自己的上下文条目，模型才看得见"),
        ]
        for hop in hops {
            let text = try Self.source(hop.file)
            #expect(text.contains(hop.needle), "\(hop.file)：\(hop.why)")
        }
    }

    @Test("a failed upload cannot send a shorter turn than the user asked for")
    func uploadFailureAbortsSubmission() throws {
        let text = try Self.source("Apps/macOS/FrontendKit/Frontend/RuntimeFrontend.swift")
        let start = try #require(text.range(of: "private func submitWithAttachments"))
        let body = text[start.lowerBound...].components(separatedBy: "\n").prefix(while: { !$0.hasPrefix("    }") })
        let lines = Array(body)

        // Every failure path must report and return. A `continue` here would send a turn with
        // one file short, which is exactly the silent degradation §3.2 rules out.
        let failures = lines.enumerated().filter { $0.element.contains("actionError =") }
        #expect(failures.count >= 4, "读取/超限/类型/未连接四条失败路径都要可见报错，实际 \(failures.count) 条")
        for (offset, _) in failures {
            let following = lines[(offset + 1)..<min(offset + 4, lines.count)]
            #expect(following.contains { $0.contains("return") && !$0.contains("return .") },
                    "报错后必须中止提交，第 \(offset) 行之后没有 return")
        }
        #expect(!lines.contains { $0.contains("continue") }, "上传失败不允许跳过该附件继续发送")
        // The draft goes only after the last upload succeeded.
        let clear = lines.firstIndex { $0.contains("composerModel.clear()") }
        let dispatch = lines.firstIndex { $0.contains("submitPrompt(text:") }
        #expect(clear != nil && dispatch != nil && clear! < dispatch!,
                "必须先清草稿再提交；失败时根本不该走到这一行")
    }

    /// §3.2 forbids a turn that looks like it carried a file. Refuse before upload, in words.
    @Test("an unsupported attachment is refused with a reason, not by being dropped")
    func unsupportedIsExplained() throws {
        let reason = AttachmentSupport.unsupportedReason(for: URL(fileURLWithPath: "/tmp/shot.png"))
        #expect(reason.contains("shot.png") && reason.contains("文本"),
                "拒绝理由必须说清是哪个文件、为什么：\(reason)")
        let gui = try Self.source("Apps/macOS/FrontendKit/Components/ComposerDock.swift")
        #expect(gui.contains("AttachmentSupport.unsupportedReason"),
                "拾取环节就要拒绝，而不是上传完再失败")
        let core = try Self.source("Sources/LingXiCore/App/CoreHost.swift")
        #expect(core.contains("binaryFileUnsupported"),
                "Core 侧同样要拒，GUI 的判断不是可信边界")
    }
}
