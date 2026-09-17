import Foundation
import Testing
@testable import LingXiProtocol
@testable import LingXiApplication
@testable import LingXiCore
@testable import LingXiTUI
@testable import LingXiTUIComponents

@Suite("P/E Core Snapshot & Convergence Tests (Phase 5)", .serialized)
struct PECoreSnapshotSemanticsTests {

    @Test("activePCoreTokens strictly respects P-Core usedTokens and never falls back to promptTokens or l1Tokens")
    func testPCoreStrictDecoupling() {
        let sessionID = SessionID("pcore-strict-decoupling")

        // Case 1: pCore snapshot explicitly provided
        let snap1 = ContextStateSnapshot(
            sessionID: sessionID,
            revision: 1,
            pCore: PCoreStateSnapshot(usedTokens: 4200, targetTokens: 16000, softLimitTokens: 14000, hardLimitTokens: 18000),
            l1Tokens: 9999,
            promptTokens: 8888
        )
        #expect(snap1.activePCoreTokens == 4200)
        #expect(snap1.pCore?.usedTokens == 4200)
        #expect(snap1.pCore?.targetTokens == 16000)

        // Case 2: pCore snapshot has 0 usedTokens - must remain 0, NEVER fallback to promptTokens/l1Tokens
        let snap2 = ContextStateSnapshot(
            sessionID: sessionID,
            revision: 2,
            pCore: PCoreStateSnapshot(usedTokens: 0, targetTokens: 16000, softLimitTokens: 14000, hardLimitTokens: 18000),
            l1Tokens: 6000,
            promptTokens: 5000
        )
        #expect(snap2.activePCoreTokens == 0)

        // Case 3: legacy backward compatibility: no pCore provided, pCoreTokens nil, promptTokens exists
        // Must NOT fallback to promptTokens or l1Tokens!
        let snap3 = ContextStateSnapshot(
            sessionID: sessionID,
            revision: 3,
            pCore: nil,
            l1Tokens: 6000,
            promptTokens: 5000,
            pCoreTokens: nil
        )
        #expect(snap3.activePCoreTokens == 0)
    }

    @Test("ECore clear correctly reduces objectCount and totalBytes to 0 without high-water heuristic block")
    func testECoreClearWithoutHeuristicBlock() {
        let sessionID = SessionID("ecore-clear-test")

        let initialSnapshot = ContextStateSnapshot(
            sessionID: sessionID,
            revision: 1,
            eCore: ECoreStateSnapshot(objectCount: 42, totalBytes: 1048576, revision: 1)
        )
        #expect(initialSnapshot.eCore?.objectCount == 42)
        #expect(initialSnapshot.eCore?.totalBytes == 1048576)

        // Incoming snapshot where ECore is cleared to 0
        let clearedSnapshot = ContextStateSnapshot(
            sessionID: sessionID,
            revision: 2,
            eCore: ECoreStateSnapshot(objectCount: 0, totalBytes: 0, revision: 2)
        )

        let merged = SessionReducer.mergeContextState(existing: initialSnapshot, incoming: clearedSnapshot, hasMessages: true)
        #expect(merged.eCore?.objectCount == 0)
        #expect(merged.eCore?.totalBytes == 0)
        #expect(merged.eCoreObjectCount == 0)
        #expect(merged.eCoreTotalBytes == 0)
    }

    @Test("P-Core compaction drop (< 1/4) is authentically applied and not suppressed by legacy high-water heuristics")
    func testPCoreCompactionDropWithoutHeuristicSuppression() {
        let sessionID = SessionID("pcore-compaction-test")

        let beforeCompaction = ContextStateSnapshot(
            sessionID: sessionID,
            revision: 10,
            pCore: PCoreStateSnapshot(usedTokens: 80000, targetTokens: 100000, softLimitTokens: 90000, hardLimitTokens: 110000),
            compactionGeneration: 1
        )
        #expect(beforeCompaction.activePCoreTokens == 80000)

        // After compaction: drops from 80,000 to 5,000 (well below 1/4)
        // With legacy heuristic, this would be mistakenly rejected and kept at 80,000!
        let afterCompaction = ContextStateSnapshot(
            sessionID: sessionID,
            revision: 11,
            pCore: PCoreStateSnapshot(usedTokens: 5000, targetTokens: 100000, softLimitTokens: 90000, hardLimitTokens: 110000),
            compactionGeneration: 1 // Same generation test case
        )

        let merged = SessionReducer.mergeContextState(existing: beforeCompaction, incoming: afterCompaction, hasMessages: true)
        #expect(merged.activePCoreTokens == 5000)
        #expect(merged.pCore?.usedTokens == 5000)
    }

    @Test("ContextStateUpdate semantics: full, reset, and patch")
    func testContextStateUpdateSemantics() {
        let sessionID = SessionID("context-update-semantics")

        let base = ContextStateSnapshot(
            sessionID: sessionID,
            revision: 5,
            pCore: PCoreStateSnapshot(usedTokens: 20000, targetTokens: 32000),
            eCore: ECoreStateSnapshot(objectCount: 10, totalBytes: 5000),
            providerCache: ProviderCacheStateSnapshot(cacheReadTokens: 15000)
        )

        // 1. Reset command
        let resetResult = SessionReducer.applyContextUpdate(.reset(sessionID: sessionID, revision: 6), existing: base)
        #expect(resetResult?.revision == 6)
        #expect(resetResult?.activePCoreTokens == 0)
        #expect(resetResult?.eCore?.objectCount == 0)
        #expect(resetResult?.eCore?.totalBytes == 0)

        // 2. Out-of-order stale update dropped
        let staleFull = ContextStateSnapshot(
            sessionID: sessionID,
            revision: 3, // older than 6
            pCore: PCoreStateSnapshot(usedTokens: 99999)
        )
        let staleResult = SessionReducer.applyContextUpdate(.full(staleFull), existing: resetResult)
        #expect(staleResult?.revision == 6) // Preserved revision 6
        #expect(staleResult?.activePCoreTokens == 0)

        // 3. Patch only modifies specified fields
        let patch = ContextStatePatch(
            sessionID: sessionID,
            revision: 7,
            eCore: ECoreStateSnapshot(objectCount: 5, totalBytes: 2048, revision: 7)
        )
        let patchResult = SessionReducer.applyContextUpdate(.patch(patch), existing: resetResult)
        #expect(patchResult?.revision == 7)
        #expect(patchResult?.eCore?.objectCount == 5)
        #expect(patchResult?.eCore?.totalBytes == 2048)
        #expect(patchResult?.activePCoreTokens == 0) // P-Core unchanged
    }

    @Test("TUI Sidebar reflects authoritative P/E Core capacities without magic numbers")
    @MainActor
    func testTUISidebarReflectsAuthoritativeCapacities() {
        let sessionID = SessionID("tui-sidebar-authoritative-test")
        let tui = ApplicationTUI()

        var session = SessionViewState(sessionID: sessionID, title: "Test")
        session.appendNode(TimelineNode(
            id: TimelineNodeID("user-msg-1"),
            kind: .message(MessageNode(messageID: MessageID("user-msg-1"), role: .user, content: "Hello!"))
        ))
        session.contextState = ContextStateSnapshot(
            sessionID: sessionID,
            revision: 1,
            pCore: PCoreStateSnapshot(usedTokens: 12500, targetTokens: 64000, softLimitTokens: 58000, hardLimitTokens: 70000),
            eCore: ECoreStateSnapshot(objectCount: 8, totalBytes: 32768, revision: 1)
        )

        var state = ApplicationState()
        state.activeSessionID = sessionID
        state.activeSessionState = session

        tui.refreshViewForTesting(state)

        let sidebar = tui.sidebarModelForTesting
        #expect(sidebar != nil)

        let pCoreLayer = sidebar?.cacheLayers.first(where: { $0.name == "P-Core" })
        #expect(pCoreLayer != nil)
        #expect(pCoreLayer?.usedTokens == 12500)
        #expect(pCoreLayer?.capacityTokens == 64000) // Follows targetTokens, not 128_000!
        #expect(pCoreLayer?.detailText?.contains("12.5K/64K") == true || pCoreLayer?.detailText?.contains("64K") == true)

        let eCoreLayer = sidebar?.cacheLayers.first(where: { $0.name == "E-Core" })
        #expect(eCoreLayer != nil)
        #expect(eCoreLayer?.detailText?.contains("8 objs") == true)
        #expect(eCoreLayer?.detailText?.contains("32") == true) // 32 KB
    }
}
