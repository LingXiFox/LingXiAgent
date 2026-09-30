import Foundation
import Testing
@testable import LingXiCore
import LingXiProtocol

struct SideQuestionServiceTests {
    @Test("Side question uses the model without changing the session history")
    func sideQuestionIsReadOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("side_question_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = RequestRecorder()
        let provider = ScriptedFakeProvider(script: [[.started, .textDelta("side-answer"), .completed(.stop)]],
                                            recorder: recorder)
        let assembly = ModelRuntimeAssembly(provider: provider, modelID: ModelID("test-model"))
        let host = try CoreHost(providerAssembly: assembly, workspaceRoot: WorkspaceRoot(path: root.path))
        let session = try await host.sessionStore.create()
        _ = try await host.sessionStore.appendMessage(session.id, role: .user, content: "Earlier question")
        let before = try await host.sessionStore.session(session.id)

        let receipt = try await host.submitSideQuestion(envelope: CommandEnvelope(payload:
            SubmitSideQuestionRequest(sessionID: session.id, question: "Follow-up?")))

        #expect(receipt.result?.answer == "side-answer")
        #expect(recorder.requests.count == 1)
        #expect(recorder.requests[0].tools.isEmpty)
        #expect(recorder.requests[0].messages.last?.content == "Follow-up?")
        let after = try await host.sessionStore.session(session.id)
        #expect(after.messages == before.messages)
    }
}
