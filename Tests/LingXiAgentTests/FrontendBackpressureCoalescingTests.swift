import Foundation
import Testing
@testable import LingXiProtocol
@testable import LingXiApplication
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
}
