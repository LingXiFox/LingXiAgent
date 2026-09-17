import Foundation
import Testing
@testable import LingXiProtocol
@testable import LingXiCore

@Suite("CodebaseGraph Identity & Incremental Correctness Tests (Round 2 Phase D)", .serialized)
struct CodebaseGraphIdentityIncrementalTests {

    @Test("Symbol Identity: Different containers with identical method names produce distinct method nodes")
    func testDistinctContainersWithSameMethodNamesProduceTwoNodes() async throws {
        let engine = CodebaseGraphEngine()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("Tools.swift")
        try """
        struct ReadTool {
            func execute() {}
        }

        struct WriteTool {
            func execute() {}
        }
        """.write(to: file, atomically: true, encoding: .utf8)

        _ = await engine.indexWorkspace(workspaceURL: tempDir, forceReindex: true)

        let executeNodes = await engine.search(query: "execute", kind: .method)
        #expect(executeNodes.count == 2, "Must produce exactly two distinct method nodes for ReadTool.execute and WriteTool.execute, got \(executeNodes.count)")

        let qualifiedNames = executeNodes.map(\.qualifiedName)
        #expect(qualifiedNames.contains(where: { $0.contains("ReadTool.execute") }))
        #expect(qualifiedNames.contains(where: { $0.contains("WriteTool.execute") }))

        // Ensure IDs are strictly distinct
        let ids = Set(executeNodes.map(\.id))
        #expect(ids.count == 2, "Node IDs must be strictly distinct!")
    }

    @Test("Incremental Correctness: Unchanged Caller retains call edge when Callee file is modified")
    func testUnchangedCallerRetainsCallEdgeOnCalleeModification() async throws {
        let engine = CodebaseGraphEngine()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileA = tempDir.appendingPathComponent("CallerA.swift")
        let fileB = tempDir.appendingPathComponent("CalleeB.swift")

        try """
        func callerA() {
            calleeB()
        }
        """.write(to: fileA, atomically: true, encoding: .utf8)

        try """
        func calleeB() {
        }
        """.write(to: fileB, atomically: true, encoding: .utf8)

        // 1. Initial full index
        _ = await engine.indexWorkspace(workspaceURL: tempDir, forceReindex: true)

        let trace1 = await engine.traceCallPath(symbolNameOrId: "callerA", direction: .outbound, maxDepth: 2)
        #expect(trace1?.steps.map(\.to.name).contains("calleeB") == true, "callerA must call calleeB initially")

        // Wait slightly to ensure mtime differences on filesystem
        try await Task.sleep(nanoseconds: 100_000_000)

        // 2. Modify CalleeB.swift only (CallerA is UNCHANGED)
        try """
        func calleeB() {
            // Updated implementation
            let x = 42
        }
        func newHelperB() {}
        """.write(to: fileB, atomically: true, encoding: .utf8)

        // 3. Incremental index (forceReindex: false)
        _ = await engine.indexWorkspace(workspaceURL: tempDir, forceReindex: false)

        // 4. Critical assertion: callerA -> calleeB edge MUST STILL EXIST!
        let trace2 = await engine.traceCallPath(symbolNameOrId: "callerA", direction: .outbound, maxDepth: 2)
        let calledAfter = trace2?.steps.map(\.to.name) ?? []
        #expect(calledAfter.contains("calleeB"), "callerA -> calleeB edge MUST NOT BE LOST during incremental reindex! Found: \(calledAfter)")
    }

    @Test("File Deletion Detection: Deleting source file removes its nodes and edges completely")
    func testFileDeletionRemovesEntitiesAndEdges() async throws {
        let engine = CodebaseGraphEngine()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file1 = tempDir.appendingPathComponent("App.swift")
        let file2 = tempDir.appendingPathComponent("DeprecatedHelper.swift")

        try """
        func appMain() {
            deprecatedAction()
        }
        """.write(to: file1, atomically: true, encoding: .utf8)

        try """
        func deprecatedAction() {
        }
        """.write(to: file2, atomically: true, encoding: .utf8)

        // Initial index: 2 files
        let initialOverview = await engine.indexWorkspace(workspaceURL: tempDir, forceReindex: true)
        #expect(initialOverview.totalFiles == 2)
        #expect(await engine.nodeCount >= 4) // 2 files + 2 functions

        // Delete DeprecatedHelper.swift from disk
        try FileManager.default.removeItem(at: file2)

        try await Task.sleep(nanoseconds: 100_000_000)

        // Incremental index: should detect file removal
        let afterOverview = await engine.indexWorkspace(workspaceURL: tempDir, forceReindex: false)
        #expect(afterOverview.totalFiles == 1)

        // Verify deprecatedAction node is completely purged
        let searchResults = await engine.search(query: "deprecatedAction")
        #expect(searchResults.isEmpty, "Deleted file's nodes must be completely purged from graph")

        // Trace appMain: call to deprecatedAction should no longer exist
        let trace = await engine.traceCallPath(symbolNameOrId: "appMain", direction: .outbound, maxDepth: 2)
        let targets = trace?.steps.map(\.to.name) ?? []
        #expect(!targets.contains("deprecatedAction"))
    }

    @Test("Parser Correctness: Nested scope calls belong only to innermost scope and single-line functions are captured")
    func testParserNestedScopeAndSingleLineFunctionCalls() async throws {
        let engine = CodebaseGraphEngine()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("Scopes.swift")
        try """
        func singleLineCaller() { targetOne() }

        func outerFunc() {
            func innerFunc() {
                targetTwo()
            }
        }

        func targetOne() {}
        func targetTwo() {}
        """.write(to: file, atomically: true, encoding: .utf8)

        _ = await engine.indexWorkspace(workspaceURL: tempDir, forceReindex: true)

        // 1. Single-line function: singleLineCaller must successfully call targetOne
        let traceSingle = await engine.traceCallPath(symbolNameOrId: "singleLineCaller", direction: .outbound, maxDepth: 2)
        let singleTargets = traceSingle?.steps.map(\.to.name) ?? []
        #expect(singleTargets.contains("targetOne"), "Single-line function body calls must be detected! Got: \(singleTargets)")

        // 2. Nested scope: targetTwo must belong to innerFunc, NOT outerFunc
        let traceInner = await engine.traceCallPath(symbolNameOrId: "innerFunc", direction: .outbound, maxDepth: 2)
        let innerTargets = traceInner?.steps.map(\.to.name) ?? []
        #expect(innerTargets.contains("targetTwo"), "innerFunc must call targetTwo")

        let traceOuter = await engine.traceCallPath(symbolNameOrId: "outerFunc", direction: .outbound, maxDepth: 2)
        let outerTargets = traceOuter?.steps.map(\.to.name) ?? []
        #expect(!outerTargets.contains("targetTwo"), "outerFunc must NOT be contaminated with innerFunc's call to targetTwo!")
    }

    @Test("Parser Correctness: Strings and comments containing braces do not corrupt scope depth")
    func testBracesInStringsAndCommentsDoNotCorruptScope() async throws {
        let engine = CodebaseGraphEngine()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("Braces.swift")
        try """
        func safeParserFunction() {
            let fakeBrace = "{ }"
            // { unbalanced comment brace
            validCall()
        }

        func validCall() {}
        """.write(to: file, atomically: true, encoding: .utf8)

        _ = await engine.indexWorkspace(workspaceURL: tempDir, forceReindex: true)

        let trace = await engine.traceCallPath(symbolNameOrId: "safeParserFunction", direction: .outbound, maxDepth: 2)
        let targets = trace?.steps.map(\.to.name) ?? []
        #expect(targets.contains("validCall"), "validCall must be attributed to safeParserFunction despite braces in string and comment")
    }
}
