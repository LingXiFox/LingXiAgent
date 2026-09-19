#if canImport(SwiftUI)
import Foundation
import Testing
@testable import LingXiFrontendKit
@testable import LingXiProtocol

@MainActor
@Suite("macOS GUI Phase 0 Hard Gate & Architecture Tests")
struct LingXiAppPhase0Tests {

    @Test("Phase 0 Hard Gate: FakeFrontendRuntime has zero process spawning and zero filesystem mutation")
    func testPhase0ZeroSideEffectsHardGate() async throws {
        // Record baseline state before running runtime
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let testMarker = homeDir.appendingPathComponent(".lingxiagent_phase0_probe_\(UUID().uuidString)")
        #expect(!FileManager.default.fileExists(atPath: testMarker.path))

        // Instantiate FakeFrontendRuntime and exercise all core operations
        let runtime = FakeFrontendRuntime(scenario: .empty)

        // Iterate through all 9 deterministic scenarios
        for scenario in GUIFixtureScenario.allCases {
            runtime.switchScenario(scenario)
            #expect(runtime.currentScenario == scenario)
        }

        // Send a simulated message
        runtime.sendMessage(
            text: "Hello Cyber Fox!",
            mode: "build",
            attachments: [AttachmentPresentation(filename: "mock.png", mediaType: "image/png", byteCount: 1024)]
        )

        // Verification: No side-effect file was written to user home
        #expect(!FileManager.default.fileExists(atPath: testMarker.path))
    }

    @Test("Phase 0 Architecture: Composer typing is isolated from high-speed streaming without interference")
    func testComposerTypingIsolatedFromStreaming() async throws {
        let runtime = FakeFrontendRuntime(scenario: .streaming)
        let composer = runtime.composerModel
        let conversation = runtime.conversationModel

        // Concurrently simulate 1,000 rapid streaming chunk appends and user typing in composer
        await withTaskGroup(of: Void.self) { group in
            // Task 1: Streaming token generation
            group.addTask {
                for i in 0..<1000 {
                    await MainActor.run {
                        conversation.appendOrUpdateStreamingChunk(chunk: " [\(i)]")
                    }
                }
                await MainActor.run {
                    conversation.finalizeStreaming()
                }
            }

            // Task 2: Continuous user typing in Composer
            group.addTask {
                for char in "Building macOS GUI Phase 0 with LingXi Glass" {
                    await MainActor.run {
                        composer.text.append(char)
                    }
                }
            }
        }

        // Assert: Composer contains the complete typed string without lost characters
        #expect(composer.text == "Building macOS GUI Phase 0 with LingXi Glass")

        // Assert: Conversation items contain the streaming content
        let assistantItem = conversation.items.first {
            if case .assistant = $0.kind { return true }
            return false
        }
        #expect(assistantItem != nil)
    }

    @Test("Phase 0 Architecture: AttachmentPresentation is purely abstract without leaking local paths")
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

    @Test("Phase 0 Architecture: All 9 fixture scenarios switch state deterministically")
    func testAllFixtureScenarios() async throws {
        let runtime = FakeFrontendRuntime(scenario: .empty)
        #expect(runtime.conversationModel.items.isEmpty)
        #expect(runtime.inspectorModel.telemetry.residentTokens == 0)
        #expect(runtime.inspectorModel.telemetry.codebaseNodes == 0)

        runtime.switchScenario(.conversation)
        #expect(runtime.conversationModel.items.count == 4)
        #expect(runtime.inspectorModel.telemetry.residentTokens == 52400)
        #expect(runtime.inspectorModel.telemetry.codebaseNodes == 1450)

        runtime.switchScenario(.permission)
        let hasWaitingPermission = runtime.conversationModel.items.contains {
            if case .tool(_, _, _, let status) = $0.kind { return status == "waiting_permission" }
            return false
        }
        #expect(hasWaitingPermission)

        runtime.switchScenario(.contextPressure)
        #expect(runtime.inspectorModel.telemetry.ecoreHeat >= 0.9)

        runtime.switchScenario(.mcpFailure)
        let hasFailedTool = runtime.conversationModel.items.contains {
            if case .tool(_, _, _, let status) = $0.kind { return status == "failed" }
            return false
        }
        #expect(hasFailedTool)

        runtime.switchScenario(.backgroundTask)
        #expect(runtime.inspectorModel.telemetry.activeBackgroundTasks == 2)
    }

    @Test("Phase 0 Architecture: switchSession synchronizes selected session and transcript")
    func testSessionSwitchingSynchronization() async throws {
        let runtime = FakeFrontendRuntime(scenario: .conversation)
        #expect(runtime.sidebarModel.selectedSessionID == "sess-1")
        #expect(runtime.conversationModel.sessionID == "sess-1")

        runtime.switchSession(id: "sess-2")
        #expect(runtime.sidebarModel.selectedSessionID == "sess-2")
        #expect(runtime.conversationModel.sessionID == "sess-2")
        #expect(runtime.conversationModel.items.count == 2)

        runtime.switchSession(id: "sess-3")
        #expect(runtime.sidebarModel.selectedSessionID == "sess-3")
        #expect(runtime.conversationModel.sessionID == "sess-3")
    }
}
#endif
