import Testing
import Foundation
@testable import LingXiCore
@testable import LingXiProtocol

@Suite("RewindPhase3Tests")
struct RewindPhase3Tests {
    actor LogTracker {
        var order: [String] = []
        var aActive = false
        var bOverlapped = false

        func record(_ entry: String) { order.append(entry) }
        func setAActive(_ active: Bool) { aActive = active }
        func checkAActive() -> Bool { aActive }
        func markOverlapped() { bOverlapped = true }
    }

    @Test
    func sessionMutationLockEnforcesMutualExclusionOnSameSession() async throws {
        let lock = SessionMutationLock()
        let sessionID = SessionID("sess-lock-test")
        let tracker = LogTracker()

        async let op1: Void = lock.withExclusiveMutation(sessionID) {
            await tracker.record("op1-begin")
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            await tracker.record("op1-end")
        }

        async let op2: Void = lock.withExclusiveMutation(sessionID) {
            await tracker.record("op2-begin")
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            await tracker.record("op2-end")
        }

        _ = try await (op1, op2)
        let order = await tracker.order
        #expect(order == ["op1-begin", "op1-end", "op2-begin", "op2-end"] ||
                order == ["op2-begin", "op2-end", "op1-begin", "op1-end"])
    }

    @Test
    func sessionMutationLockAllowsDifferentSessionsConcurrently() async throws {
        let lock = SessionMutationLock()
        let sessA = SessionID("sess-A")
        let sessB = SessionID("sess-B")
        let tracker = LogTracker()

        async let opA: Void = lock.withExclusiveMutation(sessA) {
            await tracker.setAActive(true)
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            await tracker.setAActive(false)
        }

        async let opB: Void = lock.withExclusiveMutation(sessB) {
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            if await tracker.checkAActive() {
                await tracker.markOverlapped()
            }
        }

        _ = try await (opA, opB)
        let overlapped = await tracker.bOverlapped
        #expect(overlapped)
    }

    @Test
    func revertOrderEnsuresRevisionBumpsFirst() async throws {
        let store = InMemorySessionStore()
        let session = try await store.create()

        _ = try await store.appendMessage(session.id, role: .user, content: "First question")
        _ = try await store.appendMessage(session.id, role: .assistant, content: "First answer")

        let rev0 = try await store.currentRevision(session.id)
        #expect(rev0 == 0)

        // Simulate CoreHost.revertLastTurn steps:
        // 1. bumpRevision
        let rev1 = try await store.bumpRevision(session.id)
        #expect(rev1 == 1)

        // Any async worker holding rev0 is now stale immediately before DB deletion
        let guardService = StoreSessionRevisionGuard(store: store)
        let lease0 = RunLease(sessionID: session.id, turnID: TurnID("turn-0"), revision: rev0)
        do {
            try await guardService.validate(lease0)
            Issue.record("Should have failed validation")
        } catch is StaleRunError {
            // expected
        }

        // 2. Perform DB revert without double-bumping
        let result = try await store.revertLastTurn(session.id, bumpRevision: false)
        #expect(result.revertedPrompt == "First question")
        #expect(result.removedCount == 2)

        // Revision should remain at 1
        let currentRev = try await store.currentRevision(session.id)
        #expect(currentRev == 1)
    }
}
