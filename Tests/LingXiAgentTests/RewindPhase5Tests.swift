import Testing
import Foundation
@testable import LingXiCore
@testable import LingXiProtocol

@Suite("RewindPhase5Tests")
struct RewindPhase5Tests {
    @Test
    func compactionAndDerivedContextDeletedOnRevert() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let persistence = try SQLitePersistenceStore(dataRoot: tmpDir, mainRoot: tmpDir)
        let store = PersistentSessionStore(persistence: persistence)
        let session = try await store.create()

        _ = try await store.appendMessage(session.id, role: .user, content: "Compaction input")
        _ = try await store.appendMessage(session.id, role: .assistant, content: "Compaction reply")

        // Save simulated compaction & derived context
        let snapshot = ContextUnitDebugSnapshot(messageID: MessageID("m1"), residency: .derived)
        let derivedPage = DerivedContextPage(
            id: "derived-1",
            sessionID: session.id,
            sourceKind: .historicalTool,
            content: "Derived summary of tool",
            messageID: MessageID("m1"),
            tokenEstimate: 50,
            createdAt: .now
        )
        try await persistence.saveCompaction(
            sessionID: session.id,
            generation: 1,
            residencies: [snapshot],
            derivedPages: [derivedPage]
        )

        // Verify compaction & derived exist
        let savedCompaction = try await persistence.compaction(sessionID: session.id)
        #expect(savedCompaction != nil)
        let derivedPages = try await persistence.loadDerived()
        #expect(!derivedPages.isEmpty)

        // Perform revert
        _ = try await store.revertLastTurn(session.id)

        // Verify both compaction_state and derived_context are wiped
        let afterCompaction = try await persistence.compaction(sessionID: session.id)
        #expect(afterCompaction == nil)
        let afterDerived = try await persistence.loadDerived()
        #expect(afterDerived.isEmpty)
    }

    @Test
    func compactorResetClearsResidenciesAndDerivedPages() async throws {
        let compactor = ContextCompactor()
        let sessionID = SessionID("sess-compactor-test")

        await compactor.restoreResidencies(
            sessionID: sessionID,
            values: [ContextUnitDebugSnapshot(messageID: MessageID("m1"), residency: .active)]
        )
        let page = DerivedContextPage(
            id: "p1",
            sessionID: sessionID,
            sourceKind: .user,
            content: "User test page",
            messageID: MessageID("m1"),
            tokenEstimate: 20,
            createdAt: .now
        )
        try await compactor.derivedStore.pageOut(page)

        let pagesBefore = await compactor.derivedStore.pages(sessionID: sessionID)
        #expect(pagesBefore.count == 1)

        await compactor.reset(sessionID: sessionID)

        let pagesAfter = await compactor.derivedStore.pages(sessionID: sessionID)
        #expect(pagesAfter.isEmpty)
    }
}
