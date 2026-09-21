import Foundation
import Testing
@testable import LingXiProtocol
@testable import LingXiCore

@Suite("CodebaseGraph Compact Index & Caller-Local Invocation Tests (Phase 8)", .serialized)
struct CodebaseGraphCompactIndexTests {

    @Test("Caller-local invocation eliminates Cartesian product edges")
    func testCallerLocalInvocationEliminatesCartesianEdges() async {
        let engine = CodebaseGraphEngine()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // File 1 has callerA calling targetFoo, and callerB calling targetBar
        let file1 = tempDir.appendingPathComponent("Callers.swift")
        try? """
        func callerA() {
            targetFoo()
        }

        func callerB() {
            targetBar()
        }
        """.write(to: file1, atomically: false, encoding: .utf8)

        // File 2 defines targetFoo
        let file2 = tempDir.appendingPathComponent("Foo.swift")
        try? """
        func targetFoo() {
        }
        """.write(to: file2, atomically: false, encoding: .utf8)

        // File 3 defines targetBar
        let file3 = tempDir.appendingPathComponent("Bar.swift")
        try? """
        func targetBar() {
        }
        """.write(to: file3, atomically: false, encoding: .utf8)

        let overview = await engine.indexWorkspace(workspaceURL: tempDir, forceReindex: true)
        #expect(overview.totalFiles == 3)

        // Trace callerA outbound: must only call targetFoo, NOT targetBar
        if let traceA = await engine.traceCallPath(symbolNameOrId: "callerA", direction: .outbound, maxDepth: 2) {
            let calledSymbols = traceA.steps.map(\.to.name)
            #expect(calledSymbols.contains("targetFoo"), "callerA must call targetFoo")
            #expect(!calledSymbols.contains("targetBar"), "callerA must NOT call targetBar (no Cartesian product edge!)")
        } else {
            Issue.record("Expected trace for callerA not to be nil")
        }

        // Trace callerB outbound: must only call targetBar, NOT targetFoo
        if let traceB = await engine.traceCallPath(symbolNameOrId: "callerB", direction: .outbound, maxDepth: 2) {
            let calledSymbols = traceB.steps.map(\.to.name)
            #expect(calledSymbols.contains("targetBar"), "callerB must call targetBar")
            #expect(!calledSymbols.contains("targetFoo"), "callerB must NOT call targetFoo (no Cartesian product edge!)")
        } else {
            Issue.record("Expected trace for callerB not to be nil")
        }

        // Inbound trace on targetFoo: only callerA
        if let traceFoo = await engine.traceCallPath(symbolNameOrId: "targetFoo", direction: .inbound, maxDepth: 2) {
            let callers = traceFoo.steps.map(\.from.name)
            #expect(callers.contains("callerA"))
            #expect(!callers.contains("callerB"))
        }

        // Inbound trace on targetBar: only callerB
        if let traceBar = await engine.traceCallPath(symbolNameOrId: "targetBar", direction: .inbound, maxDepth: 2) {
            let callers = traceBar.steps.map(\.from.name)
            #expect(callers.contains("callerB"))
            #expect(!callers.contains("callerA"))
        }
    }

    @Test("Compact index memory diagnostics reflect compact pools")
    func testCompactIndexMemoryDiagnostics() async {
        let engine = CodebaseGraphEngine()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("Math.swift")
        try? """
        func add() {
            calc()
        }
        func calc() {}
        """.write(to: file, atomically: false, encoding: .utf8)

        _ = await engine.indexWorkspace(workspaceURL: tempDir, forceReindex: true)

        let diag = await engine.memoryDiagnostics()
        #expect(diag.nodeCount >= 3) // 1 file + 2 functions
        #expect(diag.edgeCount >= 2) // defines + calls
        #expect(diag.approximateHeapBytes > 0)
        #expect(diag.approximateHeapBytes < 100_000, "Compact graph heap should be very small for minimal workspace")
    }

    @Test("Disk cache V2 format roundtrip and legacy cache auto-invalidation")
    func testDiskCacheV2RoundtripAndInvalidation() async {
        let engine = CodebaseGraphEngine()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("Hello.swift")
        try? "func hello() {}".write(to: file, atomically: false, encoding: .utf8)

        // Index will persist V2 cache
        _ = await engine.indexWorkspace(workspaceURL: tempDir, forceReindex: true)
        let cacheFile = await engine.cacheFileURLForTesting(workspaceURL: tempDir)
        #expect(FileManager.default.fileExists(atPath: cacheFile.path))

        // Create a new engine instance to test loading from V2 cache
        let engine2 = CodebaseGraphEngine()
        _ = await engine2.indexWorkspace(workspaceURL: tempDir, forceReindex: false)
        #expect(await engine2.isIndexed)
        let results = await engine2.search(query: "hello")
        #expect(!results.isEmpty)

        // Write legacy V1 cache (without version field) to cacheFile and test auto-invalidation
        let legacyData = "{\"nodes\":[],\"edges\":[]}".data(using: .utf8)!
        try? legacyData.write(to: cacheFile)

        let engine3 = CodebaseGraphEngine()
        // Should ignore corrupt/legacy cache and reindex freshly
        _ = await engine3.indexWorkspace(workspaceURL: tempDir, forceReindex: false)
        #expect(await engine3.isIndexed)
        let freshResults = await engine3.search(query: "hello")
        #expect(!freshResults.isEmpty, "Engine must successfully re-index after encountering legacy cache")
    }
}
