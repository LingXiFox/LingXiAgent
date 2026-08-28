import Foundation
import Testing
@testable import LingXiCore

struct ProjectContextTests {
    @Test func scannerSkipsSensitiveAndBinaryFilesAndSlicesStably() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(String(repeating: "let marker = 1\n", count: 2_000), to: root, path: "Sources/Alpha.swift")
        try write("ignored", to: root, path: ".env")
        try write("ignored", to: root, path: ".env.local")
        try write("ignored", to: root, path: "cert.pem")
        try write("ignored", to: root, path: "credential.json")
        try write("ignored", to: root, path: "private-secret/notes.txt")
        try write("ignored", to: root, path: ".git/config")
        try write("ignored", to: root, path: "node_modules/package/index.js")
        try Data([0x41, 0x00, 0x42]).write(to: root.appending(path: "Sources/blob.bin"))

        let scanner = ProjectScanner(root: root)
        let first = try scanner.scan()
        let second = try scanner.scan()

        #expect(first == second)
        #expect(Set(first.map(\.path)) == ["Sources/Alpha.swift"])
        #expect(first.count > 1)
        #expect(first.dropLast().allSatisfy { (8 * 1024 ... 16 * 1024).contains($0.byteCount) })
        #expect(Set(first.map(\.version)).count == 1)
        #expect(first.allSatisfy { !$0.hash.isEmpty })
    }

    @Test func storeIndexesInitiallyAndRebuildsOnlyChangedFiles() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("needle alpha\n", to: root, path: "A.swift")
        try write("needle beta\n", to: root, path: "B.swift")
        let scanner = ProjectScanner(root: root)
        let store = ProjectPageStore()

        let initial = try await store.rebuildStaleFiles(using: scanner)
        let before = await store.search(projectRoot: root, query: "needle")
        try write("needle alpha changed\n", to: root, path: "A.swift")
        let update = try await store.rebuildStaleFiles(using: scanner)
        let unchanged = try await store.rebuildStaleFiles(using: scanner)
        let after = await store.search(projectRoot: root, query: "needle")

        #expect(initial.initialIndexedPaths == ["A.swift", "B.swift"])
        #expect(initial.rebuiltPaths.isEmpty)
        #expect(initial.filesChecked == 2)
        #expect(initial.filesRebuilt == 0)
        #expect(initial.initialIndexedPages == 2)
        #expect(before.map(\.path) == ["A.swift", "B.swift"])
        guard before.count == 2 else { return }
        #expect(update.rebuiltPaths == ["A.swift"])
        #expect(update.filesChecked == 2)
        #expect(update.filesRebuilt == 1)
        #expect(update.initialIndexedPages == 0)
        #expect(update.removedPaths.isEmpty)
        #expect(update.invalidatedPageIDs == [before[0].id])
        #expect(unchanged.filesChecked == 2)
        #expect(unchanged.filesRebuilt == 0)
        #expect(unchanged.rebuiltPaths.isEmpty)
        #expect(after.map(\.path) == ["A.swift", "B.swift"])
        #expect(after[1] == before[1])
    }

    @Test func workingSetPromotesTouchesEvictsAndInvalidates() async {
        let root = "/project"
        let a = ContextPage(projectRoot: root, path: "A", startLine: 1, endLine: 1, content: "aaaa")
        let b = ContextPage(projectRoot: root, path: "B", startLine: 1, endLine: 1, content: "bbbb")
        let c = ContextPage(projectRoot: root, path: "C", startLine: 1, endLine: 1, content: "cccc")
        let workingSet = L2WorkingSet(characterBudget: 8)

        _ = await workingSet.promote([a, b, a])
        await workingSet.touch([a.id])
        let promotion = await workingSet.promote([c])
        await workingSet.invalidate([a.id])

        #expect(promotion.evicted == [b])
        #expect(await workingSet.page(id: b.id) == nil)
        #expect(await workingSet.metrics() == L2WorkingSetMetrics(pageCount: 1, characterCount: 4))
    }

    @Test func pagerDeduplicatesWithinProjectBudgetAndRecordsCacheFaults() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("needle A\n", to: root, path: "A.swift")
        try write("needle A\n", to: root, path: "B.swift")
        try write("needle C\n", to: root, path: "C.swift")
        let pager = ContextPager(
            store: ProjectPageStore(),
            workingSet: L2WorkingSet(characterBudget: 32),
            projectCharacterBudget: 10
        )

        _ = try await pager.rebuildStaleFiles(using: ProjectScanner(root: root))
        let initialMetrics = await pager.debugMetrics(projectRoot: root)
        let first = await pager.query(projectRoot: root, query: "needle", limit: 10)
        let second = await pager.query(projectRoot: root, query: "needle", limit: 10)

        #expect(first.pages.map(\.path) == ["A.swift"])
        #expect(initialMetrics.initialIndexedFiles == 3)
        #expect(initialMetrics.staleRebuilds == 0)
        #expect(first.characterCount <= 10)
        #expect(first.metrics == ContextPagerMetrics(hits: 0, misses: 1, pageFaults: 1))
        #expect(second.pages == first.pages)
        #expect(second.metrics == ContextPagerMetrics(hits: 1, misses: 1, pageFaults: 1))
    }

    @Test func lexicalSearchPrefersPathAndScannerClassifiesSource() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("# Project\n", to: root, path: "README.md")
        try write("struct PermissionEngine {}", to: root, path: "Sources/PermissionEngine.swift")
        let scanner = ProjectScanner(root: root)
        let store = ProjectPageStore()
        _ = try await store.rebuildStaleFiles(using: scanner)
        let pages = await store.search(projectRoot: root, query: "PermissionEngine")
        #expect(pages.first?.path == "Sources/PermissionEngine.swift")
        #expect((try scanner.scan().first { $0.path == "README.md" })?.sourceType == .projectMetadata)
    }

    @Test func pagerReportsCandidatesAndNeverExceedsProjectBudget() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("needle 1111111111", to: root, path: "A.swift")
        try write("needle 2222222222", to: root, path: "B.swift")
        let pager = ContextPager(store: ProjectPageStore(), workingSet: L2WorkingSet(characterBudget: 1_000), projectCharacterBudget: 18)
        _ = try await pager.rebuildStaleFiles(using: ProjectScanner(root: root))
        let result = await pager.query(projectRoot: root, query: "needle")
        #expect(result.candidatePageCount == 2)
        #expect(result.candidateCharacterCount > result.selectedCharacterCount)
        #expect(result.selectedCharacterCount <= 18)
        #expect(result.pages.count == result.selectedPageCount)
    }

    @Test func workingSetIsWarmAcrossQueriesAndIsolatedByProject() async throws {
        let firstRoot = try makeProject()
        let secondRoot = try makeProject()
        defer { try? FileManager.default.removeItem(at: firstRoot); try? FileManager.default.removeItem(at: secondRoot) }
        try write("Tool Runtime execution chain", to: firstRoot, path: "Sources/ToolRuntime.swift")
        try write("Provider configuration", to: firstRoot, path: "Sources/Provider.swift")
        try write("Tool Runtime execution chain", to: secondRoot, path: "Sources/ToolRuntime.swift")
        let pager = ContextPager(store: ProjectPageStore(), workingSet: L2WorkingSet(characterBudget: 1_000), projectCharacterBudget: 1_000)
        _ = try await pager.rebuildStaleFiles(using: ProjectScanner(root: firstRoot))
        _ = try await pager.rebuildStaleFiles(using: ProjectScanner(root: secondRoot))
        _ = await pager.query(projectRoot: firstRoot, query: "Tool Runtime")
        let warm = await pager.query(projectRoot: firstRoot, query: "Runtime execution")
        let beforeOtherProject = warm.metrics.hits
        let other = await pager.query(projectRoot: secondRoot, query: "Tool Runtime")
        #expect(warm.metrics.hits > 0)
        #expect(other.metrics.hits == beforeOtherProject)
    }

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ content: String, to root: URL, path: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
}
