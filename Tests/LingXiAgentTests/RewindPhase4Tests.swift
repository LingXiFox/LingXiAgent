import Testing
import Foundation
@testable import LingXiCore
@testable import LingXiProtocol

@Suite("RewindPhase4Tests")
struct RewindPhase4Tests {
    @Test
    func pendingPermissionContinuationCancelledOnRewind() async throws {
        let engine = PermissionEngine(defaultDecision: .ask)
        let sessionID = SessionID("sess-perm-test")
        let request = PermissionRequest(
            permissionID: PermissionID("perm-1"),
            sessionID: sessionID,
            toolCallID: ToolCallID("call-1"),
            toolID: ToolID("bash"),
            capabilities: [.processExecute],
            resource: "/tmp",
            description: "Execute script"
        )

        async let askTask: PermissionDecision = engine.request(request) {
            // Callback when asked
        }

        // Give continuation a tick to register
        try await Task.sleep(nanoseconds: 10_000_000)

        // Simulate rewind cancelling pending permissions for this session
        await engine.cancelPending(sessionID: sessionID, reason: .sessionReverted)

        let decision = await askTask
        #expect(decision == .deny)

        // Late reply from old UI should fail gracefully
        var didCatchExpired = false
        do {
            try await engine.reply(PermissionReply(permissionID: request.permissionID, decision: .allow))
        } catch {
            didCatchExpired = true
        }
        #expect(didCatchExpired)
    }

    @Test
    func pendingQuestionContinuationCancelledOnRewind() async throws {
        let runtime = QuestionRuntime(interactive: true)
        let sessionID = SessionID("sess-question-test")
        let request = QuestionRequest(
            questionID: QuestionID("q-1"),
            question: "Confirm action?",
            options: ["Yes", "No"],
            allowsMultiple: false,
            allowsFreeText: false,
            originSessionID: sessionID
        )

        async let askTask: QuestionReply = runtime.ask(request)

        try await Task.sleep(nanoseconds: 10_000_000)

        // Cancel pending questions for session
        await runtime.cancelPending(sessionID: sessionID, reason: .sessionReverted)

        var didThrowExpired = false
        do {
            _ = try await askTask
        } catch let err as CoreError {
            if err.code == .interactionExpired {
                didThrowExpired = true
            }
        } catch {
            // Other error
        }
        #expect(didThrowExpired)

        // Late UI reply to expired question fails
        var didCatchLateReply = false
        do {
            try await runtime.reply(QuestionReply(questionID: request.questionID, selectedOptionIndices: [0]))
        } catch {
            didCatchLateReply = true
        }
        #expect(didCatchLateReply)
    }
}
