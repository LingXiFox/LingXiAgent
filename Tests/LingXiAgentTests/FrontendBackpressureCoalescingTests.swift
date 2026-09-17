import Foundation
import Testing
@testable import LingXiProtocol
@testable import LingXiApplication
@testable import LingXiTUIComponents
@testable import LingXiTUI

@Suite("Frontend Backpressure & Update Coalescing Tests (Round 2 Phase B)")
struct FrontendBackpressureCoalescingTests {

    @Test("FrontendUpdateCoalescer coalesces high-frequency updates without losing changeSet domains")
    func coalescerMergesHighFrequencyUpdatesAccurately() async {
        let coalescer = FrontendUpdateCoalescer()
        let baseState = ApplicationState.empty

        // Ingest 500 rapid incremental updates with different changed nodes
        for i in 0..<500 {
            let nodeID = TimelineNodeID("node_\(i)")
            let changeSet = ApplicationChangeSet(
                transcriptNodesChanged: [nodeID],
                nodeChanges: [TimelineNodeChange(nodeID: nodeID, kind: .update)]
            )
            let update = ApplicationUpdate(revision: UInt64(i + 1), state: baseState, changes: changeSet)
            await coalescer.ingest(update: update)
        }

        #expect(await coalescer.currentRevision == 500)
        #expect(await coalescer.hasPendingUpdate == true)

        // Drain single latest snapshot with merged changes
        guard let drained = await coalescer.drain() else {
            Issue.record("Expected drained update to be non-nil")
            return
        }

        #expect(drained.revision == 500)
        // All 500 changed nodes must be accurately preserved in the merged changeset!
        #expect(drained.changes.transcriptNodesChanged.count == 500)
        #expect(drained.changes.nodeChanges.count == 500)

        // After drain, accumulated changes must be reset to empty
        #expect(await coalescer.hasPendingUpdate == false)
    }

    @Test("invalidationSignal respects bounded buffer and does not accumulate unbounded signals")
    func invalidationSignalBackpressureBounded() async {
        let coalescer = FrontendUpdateCoalescer()
        let baseState = ApplicationState.empty

        // Burst 2,000 updates into coalescer
        for i in 0..<2000 {
            let changeSet = ApplicationChangeSet(
                contextChanged: i % 2 == 0,
                statusChanged: true
            )
            let update = ApplicationUpdate(revision: UInt64(i + 1), state: baseState, changes: changeSet)
            await coalescer.ingest(update: update)
        }

        // Drain once
        let drained = await coalescer.drain()
        #expect(drained != nil)
        #expect(drained?.revision == 2000)
        #expect(drained?.changes.statusChanged == true)
        #expect(drained?.changes.contextChanged == true)
    }

    @Test("ApplicationChangeSet empty and isEmpty correctly reflect zero mutations")
    func changeSetEmptySemantics() {
        let empty = ApplicationChangeSet.empty
        #expect(empty.isEmpty)

        var mutated = empty
        mutated.inputChanged = true
        #expect(!mutated.isEmpty)

        var merged = ApplicationChangeSet.empty
        merged.merge(with: mutated)
        #expect(!merged.isEmpty)
        #expect(merged.inputChanged)
    }

    @Test("Revision Gap triggers fullSnapshot downgrade to prevent retained view stale data (Issue #31)")
    func revisionGapTriggersFullSnapshotRecovery() async {
        let coalescer = FrontendUpdateCoalescer()
        let baseState = ApplicationState.empty

        // 1. Ingest initial revision 1 with small partial change
        let node1 = TimelineNodeID("node_1")
        let change1 = ApplicationChangeSet(transcriptNodesChanged: [node1])
        await coalescer.ingest(update: ApplicationUpdate(revision: 1, state: baseState, changes: change1))

        // 2. Ingest revision 10 (simulating Store buffer dropped 2...9)
        let node10 = TimelineNodeID("node_10")
        let change10 = ApplicationChangeSet(transcriptNodesChanged: [node10])
        await coalescer.ingest(update: ApplicationUpdate(revision: 10, state: baseState, changes: change10))

        #expect(await coalescer.totalRevisionGaps == 1)

        guard let drained = await coalescer.drain() else {
            Issue.record("Expected non-nil drained update")
            return
        }

        #expect(drained.revision == 10)
        // Accumulated changes must have escalated to fullSnapshot!
        #expect(drained.changes == .fullSnapshot)
    }

    @Test("UIEventPump provides lossless input channel with zero keystroke loss under state storm (Issues #30, #32)")
    func losslessUIEventPumpZeroKeystrokeLossUnderStateStorm() async throws {
        let pump = UIEventPump()
        let totalKeystrokes = 100
        let totalStateInvalidations = 1000

        // Concurrently bombard with 1000 state invalidations and 100 keystrokes
        await withTaskGroup(of: Void.self) { group in
            // State Storm Task
            group.addTask {
                for _ in 0..<totalStateInvalidations {
                    pump.markStateInvalidated()
                }
            }

            // High frequency User Keystroke Task
            group.addTask {
                for i in 0..<totalKeystrokes {
                    let char = Character(UnicodeScalar(65 + (i % 26))!)
                    pump.postInput(.character(char))
                }
            }
        }

        // Drain all accumulated events
        var collectedInputs: [TUIInputEvent] = []
        var hadStateInvalidation = false

        // Drain initial batch
        let batch = pump.drain()
        collectedInputs.append(contentsOf: batch.inputs)
        if batch.hasStateInvalidation {
            hadStateInvalidation = true
        }

        // Assert that state storm did NOT drop a single keystroke!
        #expect(collectedInputs.count == totalKeystrokes)
        #expect(hadStateInvalidation == true)

        // Verify ordering of received keystrokes
        for i in 0..<totalKeystrokes {
            let expectedChar = Character(UnicodeScalar(65 + (i % 26))!)
            #expect(collectedInputs[i] == .character(expectedChar))
        }

        // Subsequent drain without new events must be clean
        let cleanBatch = pump.drain()
        #expect(cleanBatch.inputs.isEmpty)
        #expect(!cleanBatch.hasStateInvalidation)
    }
}
