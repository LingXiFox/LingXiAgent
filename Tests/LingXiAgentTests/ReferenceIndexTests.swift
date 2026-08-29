import Foundation
import Testing
@testable import LingXiCore

struct ReferenceIndexTests {
    @Test func extractorFindsImportsTypesConformanceExtensionAndCalls() {
        let references = extract("""
        import Foundation
        @testable import Foo
        final class Worker: BaseWorker, Sendable {}
        struct Box: Sendable {}
        extension ToolRuntime {}
        func f(_ engine: PermissionEngine) -> ContextPager { permissionEngine.request() }
        // ContextPager fakeEngine.request()
        let text = "PermissionEngine fake.request()"
        """)
        #expect(references.contains { $0.kind == .import && $0.targetName == "Foundation" })
        #expect(references.contains { $0.kind == .import && $0.targetName == "Foo" })
        #expect(references.contains { $0.kind == .inheritance && $0.targetName == "BaseWorker" })
        #expect(references.contains { $0.kind == .protocolConformance && $0.targetName == "Sendable" })
        #expect(references.contains { $0.kind == .extensionTarget && $0.targetName == "ToolRuntime" })
        #expect(references.contains { $0.kind == .typeReference && $0.targetName == "PermissionEngine" })
        #expect(references.contains { $0.kind == .typeReference && $0.targetName == "ContextPager" })
        #expect(references.contains { $0.kind == .functionReference && $0.targetName == "request" })
        #expect(!references.contains { $0.targetName == "fake" })
    }

    @Test func indexResolvesAndKeepsAmbiguity() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("struct Exact {}\n", root, "Sources/Exact.swift")
        try write("struct Shared {}\n", root, "Sources/A.swift")
        try write("struct Shared {}\n", root, "Sources/B.swift")
        try write("func f(_ exact: Exact, _ shared: Shared) {}\n", root, "Sources/Use.swift")
        let store = ProjectPageStore()
        _ = try await store.rebuildStaleFiles(using: ProjectScanner(root: root))
        let stats = await store.statistics(projectRoot: root).references
        #expect(stats.resolvedCount >= 1)
        #expect(stats.ambiguousCount >= 1)
        #expect(stats.unresolvedCount == 0)
    }

    @Test func indexSupportsDirectionalLookupsAndProjectsStayIsolated() async {
        let index = ProjectReferenceIndex()
        let page = ContextPage(projectRoot: "/one", path: "A.swift", startLine: 1, endLine: 1, content: "")
        let source = Symbol(projectRoot: "/one", name: "A", qualifiedName: "A", kind: .struct, path: "A.swift", pageID: page.id, line: 1)
        let target = Symbol(projectRoot: "/one", name: "B", qualifiedName: "B", kind: .struct, path: "B.swift", pageID: "b", line: 1)
        let reference = ProjectReference(projectRoot: "/one", sourceSymbolID: source.id, sourcePageID: page.id, sourcePath: "A.swift", sourceLine: 2, targetName: "B", kind: .typeReference).resolving(to: [target], quality: .symbolNameResolved)
        await index.replaceReferences(projectRoot: "/one", forPath: "A.swift", references: [reference])
        #expect(await index.referencesFrom(projectRoot: "/one", symbol: source.id).count == 1)
        #expect(await index.referencesTo(projectRoot: "/one", symbol: target.id).count == 1)
        #expect(await index.dependenciesFrom(projectRoot: "/one", path: "A.swift").count == 1)
        #expect(await index.dependenciesTo(projectRoot: "/one", path: "B.swift").count == 1)
        #expect(await index.references(projectRoot: "/two").isEmpty)
    }

    @Test func staleTargetRemovalClearsResolutionAndOutgoingReferences() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("struct Target {}\n", root, "Sources/Target.swift")
        try write("func use(_ value: Target) {}\n", root, "Sources/Use.swift")
        let store = ProjectPageStore()
        let scanner = ProjectScanner(root: root)
        _ = try await store.rebuildStaleFiles(using: scanner)
        try FileManager.default.removeItem(at: root.appending(path: "Sources/Target.swift"))
        _ = try await store.rebuildStaleFiles(using: scanner)
        let stats = await store.statistics(projectRoot: root).references
        #expect(stats.resolvedCount == 0)
        #expect(stats.unresolvedCount >= 1)
        #expect(stats.indexedFileCount == 1)
    }

    @Test func relationQueryRanksDirectRelatedPagesWithinBudget() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("struct PermissionEngine {}\n", root, "Sources/PermissionEngine.swift")
        try write("struct ToolRuntime { func execute(_ engine: PermissionEngine) {} }\n", root, "Sources/ToolRuntime.swift")
        try write("ToolRuntime PermissionEngine unrelated lexical note\n", root, "Docs/Note.md")
        let pager = ContextPager(store: ProjectPageStore(), workingSet: L2WorkingSet(), projectCharacterBudget: 2_000)
        _ = try await pager.rebuildStaleFiles(using: ProjectScanner(root: root))
        let result = await pager.query(projectRoot: root, query: ContextQuery(currentTask: "ToolRuntime 和 PermissionEngine 如何关联？"))
        #expect(result.turnMetrics.directReferenceHits >= 1)
        #expect(result.turnMetrics.relatedPages <= 8)
        #expect(result.pages.map(\.path).contains("Sources/ToolRuntime.swift"))
        #expect(result.selectedCharacterCount <= 2_000)
    }

    private func extract(_ source: String) -> [ProjectReference] {
        let page = ContextPage(projectRoot: "/project", path: "Sources/Test.swift", startLine: 1, endLine: source.split(separator: "\n").count, content: source)
        return SwiftReferenceExtractor().extract(projectRoot: "/project", path: page.path, pages: [page], symbols: [])
    }
    private func project() throws -> URL { let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root }
    private func write(_ content: String, _ root: URL, _ path: String) throws { let url = root.appending(path: path); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try Data(content.utf8).write(to: url) }
}
