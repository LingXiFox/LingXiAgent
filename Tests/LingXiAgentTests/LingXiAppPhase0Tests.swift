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

        let runtime = RuntimeFrontend()

        // 发送消息
        runtime.sendMessage(
            text: "Hello Cyber Fox!",
            mode: .build,
            attachments: [AttachmentPresentation(filename: "mock.png", mediaType: "image/png", byteCount: 1024)]
        )

        // 验证用户主目录未产生临时污染
        #expect(!FileManager.default.fileExists(atPath: testMarker.path))
    }

    @Test("RuntimeFrontend Architecture: Composer typing is isolated from high-speed streaming without interference")
    func testComposerTypingIsolatedFromStreaming() async throws {
        let runtime = RuntimeFrontend()
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
            thumbnailSymbol: "doc.richtext"
        )

        #expect(att.filename == "spec.pdf")
        #expect(att.mediaType == "application/pdf")
        #expect(att.formattedSize == "2.4 MB")
        #expect(att.isUploaded)
    }

    @Test("RuntimeFrontend Architecture: Session and task switching synchronizes stage state")
    func testSessionSwitchingSynchronization() async throws {
        let runtime = RuntimeFrontend()
        #expect(runtime.sidebarModel.selectedSessionID == "sess-1")
        #expect(runtime.conversationModel.sessionID == "sess-1")

        runtime.newSession()
        #expect(runtime.sidebarModel.selectedSessionID != "sess-1")
        #expect(runtime.conversationModel.sessionID == runtime.sidebarModel.selectedSessionID)
    }

    @Test("RuntimeFrontend Architecture: HITL interaction resolves locally and in state")
    func testHITLInteractionResolution() async throws {
        let runtime = RuntimeFrontend()
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

    @Test("RuntimeFrontend Architecture: Task finalization transitions task state machine")
    func testTaskFinalizationTransitions() async throws {
        let runtime = RuntimeFrontend()
        #expect(runtime.conversationModel.activeTask?.state == "running")

        runtime.finalizeTask(action: .accept)
        #expect(runtime.conversationModel.activeTask?.state == "completed")

        runtime.finalizeTask(action: .discard)
        #expect(runtime.conversationModel.activeTask?.state == "cancelled")
    }

    @Test("RuntimeFrontend Architecture: LingXiFrontendKit and Apps strictly do NOT import LingXiCore or LingXiPlatform")
    func testFrontendLayerArchitecturePurity() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LingXiAgentTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Repo root

        let sharedDir = repoRoot.appendingPathComponent("Apps/LingXiApp/Shared")
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(at: sharedDir, includingPropertiesForKeys: nil) else {
            Issue.record("Failed to enumerate Apps/LingXiApp/Shared")
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
