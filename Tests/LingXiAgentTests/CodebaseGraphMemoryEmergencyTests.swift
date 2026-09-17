import Foundation
import Testing
@testable import LingXiProtocol
@testable import LingXiCore

@Suite("CodebaseGraph Memory Emergency Tests (Phase 7)", .serialized)
struct CodebaseGraphMemoryEmergencyTests {

    @Test("addEdge deduplicates and prevents exponential adjacency growth")
    func testAddEdgeDeduplication() async {
        let engine = CodebaseGraphEngine()

        let edge = GraphEdge(
            sourceId: "func:foo",
            targetId: "func:bar",
            kind: .calls,
            line: 42
        )

        // Add the same edge 10 times
        for _ in 0..<10 {
            await engine.addEdgeForTesting(edge)
        }

        let diag = await engine.memoryDiagnostics()
        #expect(diag.edgeCount == 1, "Canonical edges count must remain 1 after 10 duplicate insertions")
        #expect(diag.outgoingEdgeReferenceCount == 1, "Outgoing adjacency references must remain 1")
        #expect(diag.incomingEdgeReferenceCount == 1, "Incoming adjacency references must remain 1")
    }

    @Test("removeFileEntities cleans up edges from both ends without leaving stale references")
    func testRemoveFileEntitiesCleansBothEnds() async {
        let engine = CodebaseGraphEngine()
        let root = URL(fileURLWithPath: "/tmp/mock-workspace")
        let fileB = root.appendingPathComponent("FileB.swift")

        let nodeA = GraphNode(
            id: "func:FileA.swift:funcA",
            kind: .function,
            name: "funcA",
            qualifiedName: "FileA.swift.funcA",
            path: "FileA.swift"
        )
        let nodeB = GraphNode(
            id: "func:FileB.swift:funcB",
            kind: .function,
            name: "funcB",
            qualifiedName: "FileB.swift.funcB",
            path: "FileB.swift"
        )

        await engine.addNodeForTesting(nodeA)
        await engine.addNodeForTesting(nodeB)

        let edge = GraphEdge(
            sourceId: nodeA.id,
            targetId: nodeB.id,
            kind: .calls,
            line: 10
        )
        await engine.addEdgeForTesting(edge)

        let diagBefore = await engine.memoryDiagnostics()
        #expect(diagBefore.edgeCount == 1)
        #expect(diagBefore.outgoingEdgeReferenceCount == 1)
        #expect(diagBefore.incomingEdgeReferenceCount == 1)

        // Remove FileB (target)
        await engine.removeFileEntitiesForTesting(for: fileB, root: root)

        let diagAfter = await engine.memoryDiagnostics()
        #expect(diagAfter.nodeCount == 1) // Only nodeA remains
        #expect(diagAfter.edgeCount == 0, "Canonical edge must be deleted")
        #expect(diagAfter.outgoingEdgeReferenceCount == 0, "NodeA's outgoing reference must be cleaned up")
        #expect(diagAfter.incomingEdgeReferenceCount == 0, "NodeB's incoming reference must be cleaned up")
    }

    @Test("cacheFileURL uses deterministic SHA256 rather than unstable hashValue")
    func testCacheFileURLDeterministicSHA256() async {
        let engine = CodebaseGraphEngine()
        let workspace = URL(fileURLWithPath: "/Volumes/Development/Projects/LingXiAgent")

        let url1 = await engine.cacheFileURLForTesting(workspaceURL: workspace)
        let url2 = await engine.cacheFileURLForTesting(workspaceURL: workspace)

        #expect(url1 == url2)
        let filename = url1.lastPathComponent
        #expect(filename.hasPrefix("graph_"))
        #expect(filename.hasSuffix(".json"))
        // SHA256 is 64 hex characters + "graph_" (6) + ".json" (5) = 75 chars
        #expect(filename.count == 75, "Expected graph_<64-char-sha256>.json, got \(filename)")
    }

    @Test("Workspace switch clears previous graph nodes and edges")
    func testWorkspaceSwitchClearsGraph() async {
        let engine = CodebaseGraphEngine()

        let tempDirA = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tempDirB = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirA, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: tempDirB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirA)
            try? FileManager.default.removeItem(at: tempDirB)
        }

        let fileA = tempDirA.appendingPathComponent("SampleA.swift")
        try? "func sampleA() {}\n".write(to: fileA, atomically: true, encoding: .utf8)

        let fileB = tempDirB.appendingPathComponent("SampleB.swift")
        try? "func sampleB() {}\n".write(to: fileB, atomically: true, encoding: .utf8)

        // Index Workspace A
        _ = await engine.indexWorkspace(workspaceURL: tempDirA)
        let resultsA = await engine.search(query: "sampleA")
        #expect(!resultsA.isEmpty)

        // Switch to Workspace B
        _ = await engine.indexWorkspace(workspaceURL: tempDirB)
        let resultsAInB = await engine.search(query: "sampleA")
        #expect(resultsAInB.isEmpty, "Workspace A nodes must be cleared when switching to Workspace B")
        let resultsB = await engine.search(query: "sampleB")
        #expect(!resultsB.isEmpty, "Workspace B nodes must be indexed")
    }

    @Test("Reindex plateau: multiple reindexes of same workspace produce identical edge and adjacency counts")
    func testReindexPlateau() async {
        let engine = CodebaseGraphEngine()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file1 = tempDir.appendingPathComponent("Alpha.swift")
        try? """
        func alpha() {
            beta()
        }
        """.write(to: file1, atomically: true, encoding: .utf8)

        let file2 = tempDir.appendingPathComponent("Beta.swift")
        try? """
        func beta() {
        }
        """.write(to: file2, atomically: true, encoding: .utf8)

        // Pass 1
        _ = await engine.indexWorkspace(workspaceURL: tempDir, forceReindex: true)
        let diag1 = await engine.memoryDiagnostics()

        // Pass 2
        _ = await engine.indexWorkspace(workspaceURL: tempDir, forceReindex: true)
        let diag2 = await engine.memoryDiagnostics()

        // Pass 3
        _ = await engine.indexWorkspace(workspaceURL: tempDir, forceReindex: true)
        let diag3 = await engine.memoryDiagnostics()

        #expect(diag1.nodeCount == diag2.nodeCount)
        #expect(diag2.nodeCount == diag3.nodeCount)

        #expect(diag1.edgeCount == diag2.edgeCount)
        #expect(diag2.edgeCount == diag3.edgeCount)

        #expect(diag1.outgoingEdgeReferenceCount == diag2.outgoingEdgeReferenceCount)
        #expect(diag2.outgoingEdgeReferenceCount == diag3.outgoingEdgeReferenceCount)

        #expect(diag1.incomingEdgeReferenceCount == diag2.incomingEdgeReferenceCount)
        #expect(diag2.incomingEdgeReferenceCount == diag3.incomingEdgeReferenceCount)
    }
}
