import Testing
import Foundation
@testable import LingXiCore
@testable import LingXiProtocol

@Suite("RewindPhase2Tests")
struct RewindPhase2Tests {
    @Test
    func assistantMessageRejectedWhenRevisionStale() async throws {
        let store = InMemorySessionStore()
        let session = try await store.create()
        let initialRev = session.revision

        // Simulate turn starts with lease at initialRev
        let lease = RunLease(sessionID: session.id, turnID: TurnID("turn-1"), revision: initialRev)

        // Session gets bumped (e.g. via rewind / undo)
        let bumpedRev = try await store.bumpRevision(session.id)
        #expect(bumpedRev > initialRev)

        // Attempt to append assistant message with old lease revision
        var didCatchStale = false
        do {
            _ = try await store.appendMessage(
                session.id,
                role: .assistant,
                content: "Late completion message",
                expectedRevision: lease.revision
            )
        } catch is StaleRunError {
            didCatchStale = true
        }

        #expect(didCatchStale)

        // Verify session messages remain clean
        let refreshed = try await store.session(session.id)
        #expect(refreshed.messages.isEmpty)
    }

    @Test
    func toolResultPersistenceRejectedWhenRevisionStale() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let persistence = try SQLitePersistenceStore(dataRoot: tmpDir, mainRoot: tmpDir)
        let store = PersistentSessionStore(persistence: persistence)

        let session = try await store.create()
        let initialRev = session.revision

        // Start turn, lease at initialRev
        let userMsg = try await store.appendMessage(session.id, role: .user, content: "run tool", expectedRevision: initialRev)
        let lease = RunLease(sessionID: session.id, turnID: TurnID(userMsg.id.rawValue), revision: initialRev)

        // Assistant creates tool call
        let toolCall = ToolCall(callID: ToolCallID("call-1"), toolID: ToolID("test_tool"), arguments: "{}")
        let assistantMsg = Message(id: MessageID(UUID().uuidString), role: .assistant, parts: [.toolCall(toolCall)], createdAt: .now)
        let batch = ToolExchangeBatch(
            batchID: "batch-1",
            sessionID: session.id,
            assistantMessageID: assistantMsg.id,
            toolCalls: [toolCall],
            providerStep: 1,
            state: .pending,
            estimatedTokens: 10,
            revision: lease.revision,
            turnID: lease.turnID
        )

        try await persistence.appendAssistantMessageAndBatch(
            sessionID: session.id,
            message: assistantMsg,
            batch: batch,
            expectedRevision: lease.revision
        )

        // Now simulate /undo: revision bumped and messages deleted
        _ = try await store.bumpRevision(session.id)
        _ = try await store.revertLastTurn(session.id)

        // Stale tool result arrives late
        let lateResult = ToolResult(callID: toolCall.callID, success: true, content: "Late tool output")
        let toolResultMsg = Message(id: MessageID(UUID().uuidString), role: .tool, parts: [.toolResult(lateResult)], createdAt: .now)
        let settledBatch = batch.with(state: .settledAwaitingConsumption, resultMessageID: toolResultMsg.id, toolResults: [lateResult])

        var didCatchStale = false
        do {
            try await persistence.appendToolResultMessageAndSettle(
                sessionID: session.id,
                message: toolResultMsg,
                batch: settledBatch,
                expectedRevision: lease.revision
            )
        } catch is StaleRunError {
            didCatchStale = true
        }

        #expect(didCatchStale)

        // Verify DB does not have orphan tool result
        let refreshed = try await store.session(session.id)
        #expect(!refreshed.messages.contains(where: { $0.role == .tool }))
    }
}
