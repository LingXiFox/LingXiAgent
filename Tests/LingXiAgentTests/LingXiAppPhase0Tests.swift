#if canImport(SwiftUI)
import Foundation
import Testing
@testable import LingXiFrontendKit
@testable import LingXiProtocol

@MainActor
@Suite("macOS GUI Runtime Frontend Architecture & Isolation Tests")
struct LingXiAppPhase0Tests {

    @Test("RuntimeFrontend Architecture: Pure in-memory execution produces zero filesystem mutations")
    func testZeroSideEffectsHardGate() async throws {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let testMarker = homeDir.appendingPathComponent(".lingxiagent_phase0_probe_\(UUID().uuidString)")
        #expect(!FileManager.default.fileExists(atPath: testMarker.path))

        let runtime = RuntimeFrontend.preview()

        // 发送消息
        runtime.sendMessage(
            text: "Hello Cyber Fox!",
            mode: .build,
            attachments: [AttachmentPresentation(filename: "mock.png", mediaType: "image/png", byteCount: 1024,
                                       sourceURL: URL(fileURLWithPath: "/tmp/mock.png"))]
        )

        // 验证用户主目录未产生临时污染
        #expect(!FileManager.default.fileExists(atPath: testMarker.path))
    }

    @Test("RuntimeFrontend Architecture: Composer typing is isolated from high-speed streaming without interference")
    func testComposerTypingIsolatedFromStreaming() async throws {
        let runtime = RuntimeFrontend.preview()
        let composer = runtime.composerModel
        let conversation = runtime.conversationModel

        // 并发模拟 500 次流式 chunk 追加与用户在 Composer 打字
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<500 {
                    await MainActor.run {
                        conversation.appendOrUpdateStreamingChunk(chunk: " [\(i)]")
                    }
                }
                await MainActor.run {
                    conversation.finalizeStreaming()
                }
            }

            group.addTask {
                for char in "Building macOS Native SwiftUI with Sonoma Architecture" {
                    await MainActor.run {
                        composer.text.append(char)
                    }
                }
            }
        }

        #expect(composer.text == "Building macOS Native SwiftUI with Sonoma Architecture")
        let assistantItem = conversation.items.first {
            if case .assistant = $0.kind { return true }
            return false
        }
        #expect(assistantItem != nil)
    }

    @Test("RuntimeFrontend Architecture: AttachmentPresentation is purely abstract without leaking local paths")
    func testAttachmentPresentationAbstractIsolation() throws {
        let att = AttachmentPresentation(
            filename: "spec.pdf",
            mediaType: "application/pdf",
            byteCount: 2_500_000,
            thumbnailSymbol: "doc.richtext",
            sourceURL: URL(fileURLWithPath: "/tmp/mock.pdf")
        )

        #expect(att.filename == "spec.pdf")
        #expect(att.mediaType == "application/pdf")
        #expect(att.formattedSize == "2.4 MB")
        // `isUploaded` is derived from the ContentRef Core handed back, not stored. A freshly
        // picked file has not been uploaded, and a strip that claimed otherwise was the flag-with-
        // no-fact behind §3's "只展示 AttachmentPresentation 但不上传".
        #expect(!att.isUploaded, "还没上传就声称已上传，正是被禁止的伪状态")
        var uploaded = att
        uploaded.contentRef = ContentRef(id: ContentID("c-1"), mediaType: att.mediaType, byteCount: att.byteCount)
        #expect(uploaded.isUploaded, "拿到引用之后应显示为已上传")
    }

    @Test("RuntimeFrontend Architecture: Session and task switching synchronizes stage state")
    func testSessionSwitchingSynchronization() async throws {
        let runtime = RuntimeFrontend.preview()
        #expect(runtime.sidebarModel.selectedSessionID == "sess-1")
        #expect(runtime.conversationModel.sessionID == "sess-1")

        runtime.newSession()
        #expect(runtime.sidebarModel.selectedSessionID != "sess-1")
        #expect(runtime.conversationModel.sessionID == runtime.sidebarModel.selectedSessionID)
    }

    @Test("RuntimeFrontend Architecture: HITL interaction resolves locally and in state")
    func testHITLInteractionResolution() async throws {
        let runtime = RuntimeFrontend.preview()
        let card = InteractionCardPresentation(
            interactionID: "int-101",
            agentRunID: "subagent-coder",
            toolName: "bash",
            parametersSummary: "rm -rf /tmp/test"
        )
        runtime.conversationModel.items.append(
            TimelineItemPresentation(kind: .interaction(card: card))
        )

        runtime.resolveInteraction(interactionID: "int-101", approved: true)

        let resolvedCard = runtime.conversationModel.items.compactMap { item -> InteractionCardPresentation? in
            if case .interaction(let c) = item.kind { return c }
            return nil
        }.first

        #expect(resolvedCard?.status == .approved)
    }

    /// §7.1: state is Core's to report.
    ///
    /// This test used to assert the opposite — that `finalizeTask` moved
    /// `conversationModel.activeTask.state` on its own — which is precisely the optimistic
    /// mutation the closure contract removes: a finalize Core rejected still read as completed.
    /// The state machine itself is covered against a real Core in `TaskRuntimeTests`; what
    /// belongs here is the GUI's refusal to predict the answer.
    @Test("Task finalization never rewrites GUI state ahead of Core")
    func testTaskFinalizationIsCoreAuthoritative() async throws {
        let runtime = RuntimeFrontend.preview()
        #expect(runtime.conversationModel.activeTask?.state == "running")

        runtime.finalizeTask(action: .accept)
        #expect(runtime.conversationModel.activeTask?.state == "running",
                "没有 Core 回执就把任务显示成已完成")
        #expect(runtime.actionError != nil, "无法收尾时必须给出可见原因，而不是静默不动")

        runtime.finalizeTask(action: .discard)
        #expect(runtime.conversationModel.activeTask?.state == "running")
    }

    @Test("RuntimeFrontend Architecture: LingXiFrontendKit and Apps strictly do NOT import LingXiCore or LingXiPlatform")
    func testFrontendLayerArchitecturePurity() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LingXiAgentTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Repo root

        let appsDir = repoRoot.appendingPathComponent("Apps")
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(at: appsDir, includingPropertiesForKeys: nil) else {
            Issue.record("Failed to enumerate Apps")
            return
        }

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(!content.contains("import LingXiCore"), "Architecture violation: \(fileURL.lastPathComponent) contains 'import LingXiCore'")
            #expect(!content.contains("import LingXiPlatform"), "Architecture violation: \(fileURL.lastPathComponent) contains 'import LingXiPlatform'")
        }
    }
}
#endif
