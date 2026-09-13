import Foundation
import Testing
@testable import LingXiCore
import LingXiProtocol

struct RewindPhase1Tests {
    @Test func sessionRevisionInitializesAndBumps() async throws {
        let store = InMemorySessionStore()
        let session = try await store.create()
        #expect(session.revision == 0)
        #expect(try await store.currentRevision(session.id) == 0)

        let rev1 = try await store.bumpRevision(session.id)
        #expect(rev1 == 1)
        #expect(try await store.currentRevision(session.id) == 1)

        let rev2 = try await store.bumpRevision(session.id)
        #expect(rev2 == 2)
        #expect(try await store.currentRevision(session.id) == 2)
    }

    @Test func runLeaseAndRevisionGuardValidation() async throws {
        let store = InMemorySessionStore()
        let session = try await store.create()
        let guardService = StoreSessionRevisionGuard(store: store)

        let lease0 = RunLease(sessionID: session.id, turnID: TurnID("turn-1"), revision: 0)
        try await guardService.validate(lease0)

        // Bump revision, lease0 should become stale
        _ = try await store.bumpRevision(session.id)
        #expect(try await store.currentRevision(session.id) == 1)

        do {
            try await guardService.validate(lease0)
            Issue.record("Expected StaleRunError when revision does not match")
        } catch let stale as StaleRunError {
            #expect(stale.sessionID == session.id)
            #expect(stale.expected == 1)
            #expect(stale.actual == 0)
        }

        let lease1 = RunLease(sessionID: session.id, turnID: TurnID("turn-2"), revision: 1)
        try await guardService.validate(lease1)
    }

    @Test func appendMessageWithExpectedRevisionRejectsStaleWrites() async throws {
        let store = InMemorySessionStore()
        let session = try await store.create()

        let msg1 = Message(id: MessageID("m1"), role: .user, content: "Hello", createdAt: Date())
        _ = try await store.appendMessage(session.id, message: msg1, expectedRevision: 0)

        _ = try await store.bumpRevision(session.id)

        let msg2 = Message(id: MessageID("m2"), role: .assistant, content: "Stale reply", createdAt: Date())
        do {
            _ = try await store.appendMessage(session.id, message: msg2, expectedRevision: 0)
            Issue.record("Expected StaleRunError on stale appendMessage")
        } catch let stale as StaleRunError {
            #expect(stale.expected == 1)
            #expect(stale.actual == 0)
        }

        let loaded = try await store.session(session.id)
        #expect(loaded.messages.count == 1)
        #expect(loaded.messages.first?.content == "Hello")
    }

    @Test func revertLastTurnBumpsRevision() async throws {
        let store = InMemorySessionStore()
        let session = try await store.create()
        _ = try await store.appendMessage(session.id, role: .user, content: "User prompt")
        _ = try await store.appendMessage(session.id, role: .assistant, content: "Assistant reply")

        let revBefore = try await store.currentRevision(session.id)
        #expect(revBefore == 0)

        let result = try await store.revertLastTurn(session.id)
        #expect(result.revertedPrompt == "User prompt")
        #expect(result.removedCount == 2)

        let revAfter = try await store.currentRevision(session.id)
        #expect(revAfter == 1)
    }
}
