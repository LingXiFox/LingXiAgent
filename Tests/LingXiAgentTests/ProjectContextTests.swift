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

    @Test func sensitivePolicyHidesSentinelsFromManifestAndContext() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataRoot = root.appending(path: "runtime-data", directoryHint: .isDirectory)
        let sensitivePaths = [
            ".ssh/config", ".aws/config", ".gnupg/private.key", ".netrc", ".npmrc",
            ".env", ".env.local", "develop.env", "db-credentials.json", "service-secret.txt", "api-token.txt",
            "runtime-data/blobs/page.txt",
        ]
        for path in sensitivePaths { try write("sensitive-sentinel", to: root, path: path) }
        try write("visible-sentinel", to: root, path: "scratch/untracked.txt")
        let policy = SensitivePathPolicy(root: root, excluding: [dataRoot])
        let scanner = ProjectScanner(root: root, sensitivePathPolicy: policy)

        let manifest = try scanner.scanManifest()
        let context = try scanner.scan()

        #expect(manifest.files.map(\.path) == ["scratch/untracked.txt"])
        #expect(context.map(\.path) == ["scratch/untracked.txt"])
        #expect(context.allSatisfy { !$0.content.contains("sensitive-sentinel") })
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

    @Test func symbolSearchRanksExactQualifiedNamesAcrossPages() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("struct Container {\n" + String(repeating: "    let value = 1\n", count: 20) + "    func target() {}\n}\n", to: root, path: "Sources/Container.swift")
        try write(String(repeating: "Container target documentation\n", count: 50), to: root, path: "Docs/Guide.md")
        let store = ProjectPageStore()

        _ = try await store.rebuildStaleFiles(using: ProjectScanner(root: root, minimumPageBytes: 32, maximumPageBytes: 64))
        let result = await store.searchResult(projectRoot: root, query: ContextQuery(currentTask: "Container.target()"))
        let stats = await store.statistics(projectRoot: root)

        #expect(result.pages.first?.path == "Sources/Container.swift")
        #expect(result.pages.first?.content.contains("func target") == true)
        #expect(result.symbolMetrics.hints == 3)
        #expect(result.symbolMetrics.exactMatches == 2)
        #expect(stats.symbols == 2)
        #expect(stats.symbolFiles == 1)
    }

    @Test func symbolIndexReplacesChangedFilesAndRemovesDeletedFiles() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "Sources/Feature.swift"
        try write("struct OldFeature {}", to: root, path: path)
        let store = ProjectPageStore()
        let scanner = ProjectScanner(root: root)

        _ = try await store.rebuildStaleFiles(using: scanner)
        try write("struct NewFeature {}", to: root, path: path)
        _ = try await store.rebuildStaleFiles(using: scanner)
        let old = await store.searchResult(projectRoot: root, query: ContextQuery(currentTask: "OldFeature"))
        let fresh = await store.searchResult(projectRoot: root, query: ContextQuery(currentTask: "NewFeature"))
        try FileManager.default.removeItem(at: root.appending(path: path))
        _ = try await store.rebuildStaleFiles(using: scanner)
        let removed = await store.statistics(projectRoot: root)

        #expect(old.symbolMetrics.exactMatches == 0)
        #expect(fresh.symbolMetrics.exactMatches == 1)
        #expect(removed.symbols == 0)
        #expect(removed.symbolFiles == 0)
    }

    @Test func currentSourceOutranksResearchWhileResearchRemainsRetrievable() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let referencePath = "Docs/opencode-extraction/permission.md"
        let referenceDocumentationPath = "References/upstream.md"
        try write("struct PermissionEngine {}", to: root, path: "Sources/PermissionEngine.swift")
        try write(String(repeating: "OpenCode PermissionEngine legacy reference\n", count: 250), to: root, path: referencePath)
        try write("Upstream reference", to: root, path: referenceDocumentationPath)
        let store = ProjectPageStore()
        let scanner = ProjectScanner(root: root)

        _ = try await store.rebuildStaleFiles(using: scanner)
        let exact = await store.searchResult(projectRoot: root, query: ContextQuery(currentTask: "PermissionEngine"))
        let explicitReference = await store.searchResult(projectRoot: root, query: ContextQuery(currentTask: "OpenCode PermissionEngine"))
        let pages = try scanner.scan()

        #expect(exact.pages.first?.path == "Sources/PermissionEngine.swift")
        #expect(exact.pages.contains { $0.path == referencePath })
        #expect(explicitReference.pages.contains { $0.path == referencePath })
        #expect(pages.first { $0.path == referencePath }?.sourceType == .researchArchive)
        #expect(pages.first { $0.path == referenceDocumentationPath }?.sourceType == .referenceDocumentation)
    }

    @Test func documentationStaysSearchableBelowCurrentSource() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("let guideMarker = \"GuideMarker\"", to: root, path: "Sources/Guide.swift")
        try write("GuideMarker documentation", to: root, path: "Docs/Guide.md")
        let store = ProjectPageStore()

        _ = try await store.rebuildStaleFiles(using: ProjectScanner(root: root))
        let result = await store.searchResult(projectRoot: root, query: ContextQuery(currentTask: "GuideMarker"))

        #expect(result.pages.first?.path == "Sources/Guide.swift")
        #expect(result.pages.contains { $0.path == "Docs/Guide.md" })
    }

    @Test func pagerReportsSplitSymbolTimingAndSourceCandidates() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("struct PermissionEngine {}", to: root, path: "Sources/PermissionEngine.swift")
        try write("PermissionEngine reference", to: root, path: "Docs/opencode-extraction/permission.md")
        let pager = ContextPager(store: ProjectPageStore(), workingSet: L2WorkingSet(), projectCharacterBudget: 1_000)

        _ = try await pager.rebuildStaleFiles(using: ProjectScanner(root: root))
        let result = await pager.query(projectRoot: root, query: ContextQuery(currentTask: "PermissionEngine"))

        #expect(result.turnMetrics.symbolHints == 1)
        #expect(result.turnMetrics.symbolExactMatches == 1)
        #expect(result.turnMetrics.symbolTotalMilliseconds >= result.turnMetrics.symbolHintExtractionMilliseconds)
        #expect(result.turnMetrics.symbolTotalMilliseconds >= result.turnMetrics.symbolExactLookupMilliseconds + result.turnMetrics.symbolPrefixLookupMilliseconds + result.turnMetrics.symbolCandidateMergeMilliseconds + result.turnMetrics.symbolRankingMilliseconds)
        #expect(result.turnMetrics.currentSourceCandidates == 1)
        #expect(result.turnMetrics.referenceCandidates == 1)
    }

    @Test func qualifiedSymbolMissFallsBackToParentAndLeaf() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("struct PermissionEngine {\n    func request() {}\n}\n", to: root, path: "Sources/PermissionEngine.swift")
        let pager = ContextPager(store: ProjectPageStore(), workingSet: L2WorkingSet(), projectCharacterBudget: 1_000)

        _ = try await pager.rebuildStaleFiles(using: ProjectScanner(root: root))
        let result = await pager.query(projectRoot: root, query: ContextQuery(currentTask: "PermissionEngine.evaluate"))

        #expect(result.pages.first?.path == "Sources/PermissionEngine.swift")
        #expect(result.turnMetrics.symbolQualifiedExactMatches == 0)
        #expect(result.turnMetrics.symbolFallbackExactMatches == 1)
    }

    @Test func l2LexicalHitStillUsesL3StructuralCoverage() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("PermissionEngine legacy note", to: root, path: "Docs/Legacy.md")
        try write("struct PermissionEngine {}", to: root, path: "Sources/PermissionEngine.swift")
        let pager = ContextPager(store: ProjectPageStore(), workingSet: L2WorkingSet(characterBudget: 64), projectCharacterBudget: 1_000)

        _ = try await pager.rebuildStaleFiles(using: ProjectScanner(root: root))
        _ = await pager.query(projectRoot: root, query: "legacy")
        let result = await pager.query(projectRoot: root, query: ContextQuery(currentTask: "PermissionEngine"))

        #expect(result.pages.first?.path == "Sources/PermissionEngine.swift")
        #expect(result.turnMetrics.symbolExactMatches == 1)
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
