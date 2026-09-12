import Testing
import Foundation
@testable import LingXiProtocol
@testable import LingXiCore
@testable import LingXiClient

@Suite struct ContextCachePolicyTests {
    @Test func tokenFormatterFormatsCompactUnitsCorrectly() {
        #expect(TokenFormatter.format(532) == "532")
        #expect(TokenFormatter.format(1_320) == "1.3K")
        #expect(TokenFormatter.format(18_400) == "18.4K")
        #expect(TokenFormatter.format(220_000) == "220K")
        #expect(TokenFormatter.format(1_048_576) == "1.05M")
        #expect(TokenFormatter.format(0) == "0")

        #expect(TokenFormatter.formatLayer(layer: "L1", usage: 1_320, capacity: 220_000, state: .available) == "L1 1.3K/220K")
        #expect(TokenFormatter.formatLayer(layer: "L2", usage: 0, capacity: 350_000, state: .empty) == "L2 0/350K")
        #expect(TokenFormatter.formatLayer(layer: "L3", usage: 0, capacity: 454_000, state: .empty) == "L3 0/454K")
        #expect(TokenFormatter.formatLayer(layer: "L3", usage: 0, capacity: 454_000, state: .unavailable) == "L3 off")
    }

    @Test func policyResolverResolvesHierarchyAndValidates() throws {
        // Default global resolution
        let defaultPolicy = try ContextPolicyResolver.resolve(
            global: ContextCacheConfiguration(),
            modelWindow: 1_048_576
        )
        #expect(defaultPolicy.addressableBudget == 1_048_576)
        #expect(defaultPolicy.modelWindow == 1_048_576)
        #expect(defaultPolicy.l1Target == 220_000)
        #expect(defaultPolicy.l1SoftLimit == 235_000)
        #expect(defaultPolicy.l1HardLimit == 250_000)
        #expect(defaultPolicy.l2Max == 350_000)
        #expect(defaultPolicy.l3Capacity == 1_048_576 - 220_000 - 350_000)
        #expect(defaultPolicy.l3Enabled == true)

        // Invalid config target > softLimit
        let invalidL1 = ContextCacheConfiguration(
            l1: ContextCacheL1Configuration(target: 250_000, softLimit: 220_000, hardLimit: 260_000)
        )
        #expect(throws: ConfigurationValidationError.self) {
            try ContextPolicyResolver.resolve(global: invalidL1, modelWindow: 1_048_576)
        }

        // Invalid config addressableBudget too small
        let smallBudget = ContextCacheConfiguration(
            addressableBudget: 100_000,
            l1: ContextCacheL1Configuration(target: 80_000, softLimit: 90_000, hardLimit: 100_000),
            l2: ContextCacheL2Configuration(max: 50_000)
        )
        #expect(throws: ConfigurationValidationError.self) {
            try ContextPolicyResolver.resolve(global: smallBudget, modelWindow: 1_048_576)
        }

        // Model override takes precedence
        let modelOverride = ContextCacheConfiguration(
            addressableBudget: 2_000_000,
            l1: ContextCacheL1Configuration(target: 300_000, softLimit: 320_000, hardLimit: 350_000),
            l2: ContextCacheL2Configuration(max: 500_000)
        )
        let resolvedOverride = try ContextPolicyResolver.resolve(
            global: ContextCacheConfiguration(),
            modelWindow: 2_000_000,
            modelOverride: modelOverride
        )
        #expect(resolvedOverride.l1Target == 300_000)
        #expect(resolvedOverride.l2Max == 500_000)
        #expect(resolvedOverride.addressableBudget == 2_000_000)
    }

    @Test func cacheControllerEvictsToL2OnSoftLimitAndPromotesBack() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Create test files
        let file1 = root.appending(path: "FileA.swift")
        try "func alpha() { print(\"alpha\") }".write(to: file1, atomically: true, encoding: .utf8)
        let file2 = root.appending(path: "FileB.swift")
        try "func beta() { print(\"beta\") }".write(to: file2, atomically: true, encoding: .utf8)

        let pager = ContextPager(store: ProjectPageStore(), workingSet: L2WorkingSet())
        let scanner = ProjectScanner(root: root)
        let policy = EffectiveContextPolicy(
            addressableBudget: 100_000,
            modelWindow: 100_000,
            economicThreshold: nil,
            reserve: 100,
            l1Target: 10,
            l1SoftLimit: 15,
            l1HardLimit: 20,
            l2Max: 1_000,
            l3Capacity: 50_000
        )
        let controller = ContextCacheController(
            contextPager: pager,
            scanner: scanner,
            policy: policy
        )

        let sessionID = SessionID("test-eviction")
        _ = try await controller.handleSearch(sessionID: sessionID, query: "alpha")
        let l1AfterAlpha = await controller.l1UsageTokens(for: sessionID)
        #expect(l1AfterAlpha > 0)
        #expect(await controller.l2UsageTokens(for: sessionID) == 0)

        // Adding beta will push L1 over softLimit (15 tokens), causing alpha to be demoted to L2
        _ = try await controller.handleSearch(sessionID: sessionID, query: "beta")
        let l2AfterBeta = await controller.l2UsageTokens(for: sessionID)
        #expect(l2AfterBeta > 0)
        let stats = await controller.pagingStats(for: sessionID)
        #expect(stats.demotions > 0)
        #expect(stats.pageOuts > 0)

        // Searching alpha again promotes it from L2 warm cache back to L1
        _ = try await controller.handleSearch(sessionID: sessionID, query: "alpha")
        let statsAfterPromote = await controller.pagingStats(for: sessionID)
        #expect(statsAfterPromote.promotions > 0)
    }

    @Test func sessionResetEnsuresCompleteCacheIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appending(path: "Isolated.swift")
        try "struct SecretFact { let x = 42 }".write(to: file, atomically: true, encoding: .utf8)

        let pager = ContextPager(store: ProjectPageStore(), workingSet: L2WorkingSet())
        let scanner = ProjectScanner(root: root)
        let controller = ContextCacheController(
            contextPager: pager,
            scanner: scanner
        )

        let sessionA = SessionID("session-A")
        let sessionB = SessionID("session-B")

        _ = try await controller.handleSearch(sessionID: sessionA, query: "SecretFact")
        #expect(await controller.l1UsageTokens(for: sessionA) > 0)
        #expect(await controller.residentPages(for: sessionA).count > 0)

        // Session B is completely isolated
        #expect(await controller.l1UsageTokens(for: sessionB) == 0)
        #expect(await controller.residentPages(for: sessionB).isEmpty)

        // Resetting Session A clears all its cached state
        await controller.resetSession(sessionA)
        #expect(await controller.l1UsageTokens(for: sessionA) == 0)
        #expect(await controller.residentPages(for: sessionA).isEmpty)
    }

    @Test func chineseNoMatchQueryReturnsZeroMatchesWithoutHistoricalFallback() async {
        let store = DerivedContextStore()
        let sessionID = SessionID("chinese-isolation")
        let page = DerivedContextPage(
            sessionID: sessionID,
            sourceKind: .historicalTool,
            content: "AgentSessionTests AgentToolLoopTests WireCodableTests",
            messageID: nil,
            tokenEstimate: 50,
            provenanceIDs: []
        )
        try? await store.pageOut(page)

        // Query with Chinese greeting that doesn't match any tokens
        let results = await store.search(sessionID: sessionID, query: "你好呀", limit: 3)
        #expect(results.isEmpty)

        let englishNoMatch = await store.search(sessionID: sessionID, query: "hello there", limit: 3)
        #expect(englishNoMatch.isEmpty)
    }

    @Test func liveL1AccountingReflectsTurnCompletionAndDistinguishesProviderInput() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = ScriptedFakeProvider(script: [
            // Turn 1:
            [.textDelta("你好呀！我是 LingXi，很高兴为你提供帮助。有什么我可以协助你的吗？"), .completed(.stop)],
            // Turn 2:
            [.textDelta("Swift Concurrency 引入了基于协程的结构化并发模型，核心概念包括 async/await 语法糖、Actor 状态隔离与 Task 生命周期管理。"), .completed(.stop)]
        ])

        let host = try CoreHost(
            providerAssembly: ModelRuntimeAssembly(
                provider: provider,
                modelID: ModelID("test-model"),
                contextProfile: ModelContextProfile(contextWindowTokens: 128_000)
            ),
            workspaceRoot: try WorkspaceRoot(path: root.path),
            permissionDecision: .allow
        )
        await host.start()
        defer { Task { await host.shutdown() } }

        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()

    // Before any turn: the runtime system context is already resident in L1.
    let initialProjection = try #require(await client.contextProjection(sessionID))
    #expect(initialProjection.l1.usageTokens > 0)
        #expect(initialProjection.lastProviderInputTokens == nil)

        // Turn 1: "你好"
        let stream1 = try await client.sendMessage(sessionID: sessionID, content: "你好")
        for try await _ in stream1 {}

        // After Turn 1: L1 resident usage must reflect both user prompt AND assistant response
        let projection1 = try #require(await client.contextProjection(sessionID))
        let turn1Usage = projection1.l1.usageTokens
        let turn1Input = try #require(projection1.lastProviderInputTokens)

        // L1 resident usage must be strictly greater than the input token count sent before inference
        #expect(turn1Usage > turn1Input)
        #expect(turn1Usage > 0)
        #expect(turn1Input > 0)
        #expect(projection1.l2.usageTokens == 0)
        #expect(projection1.l3.usageTokens == 0)

        // Turn 2: Multi-turn prompt
        let stream2 = try await client.sendMessage(sessionID: sessionID, content: "请介绍一下 Swift Concurrency 的核心概念。")
        for try await _ in stream2 {}

        // After Turn 2: L1 usage and provider input must steadily grow
        let projection2 = try #require(await client.contextProjection(sessionID))
        let turn2Usage = projection2.l1.usageTokens
        let turn2Input = try #require(projection2.lastProviderInputTokens)

        #expect(turn2Usage > turn1Usage)
        #expect(turn2Input > turn1Input)
        #expect(turn2Usage > turn2Input)
    }
}
