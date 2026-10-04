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

    }

    @Test func policyResolverResolvesHierarchyAndValidates() throws {
        // Default global resolution
        let defaultPolicy = try ContextPolicyResolver.resolve(
            global: ContextCacheConfiguration(),
            modelWindow: 1_048_576
        )
        #expect(defaultPolicy.addressableBudget == 1_048_576)
        #expect(defaultPolicy.modelWindow == 1_048_576)
        #expect(defaultPolicy.pCoreTarget == 220_000)
        #expect(defaultPolicy.pCoreSoftLimit == 235_000)
        #expect(defaultPolicy.pCoreHardLimit == 250_000)
        #expect(defaultPolicy.eCoreRecallBudget == 350_000)
        #expect(defaultPolicy.eCoreStorageBudget == 1_048_576 - 220_000 - 350_000)
        #expect(defaultPolicy.eCoreEnabled == true)

        // Invalid config target > softLimit
        let invalidPCore = ContextCacheConfiguration(
            pCore: ContextCachePCoreConfiguration(target: 250_000, softLimit: 220_000, hardLimit: 260_000)
        )
        #expect(throws: ConfigurationValidationError.self) {
            try ContextPolicyResolver.resolve(global: invalidPCore, modelWindow: 1_048_576)
        }

        // Invalid config addressableBudget too small
        let smallBudget = ContextCacheConfiguration(
            addressableBudget: 100_000,
            pCore: ContextCachePCoreConfiguration(target: 80_000, softLimit: 90_000, hardLimit: 100_000),
            eCore: ContextCacheECoreConfiguration(recallBudget: 50_000)
        )
        #expect(throws: ConfigurationValidationError.self) {
            try ContextPolicyResolver.resolve(global: smallBudget, modelWindow: 1_048_576)
        }

        // Model override takes precedence
        let modelOverride = ContextCacheConfiguration(
            addressableBudget: 2_000_000,
            pCore: ContextCachePCoreConfiguration(target: 300_000, softLimit: 320_000, hardLimit: 350_000),
            eCore: ContextCacheECoreConfiguration(recallBudget: 500_000)
        )
        let resolvedOverride = try ContextPolicyResolver.resolve(
            global: ContextCacheConfiguration(),
            modelWindow: 2_000_000,
            modelOverride: modelOverride
        )
        #expect(resolvedOverride.pCoreTarget == 300_000)
        #expect(resolvedOverride.eCoreRecallBudget == 500_000)
        #expect(resolvedOverride.addressableBudget == 2_000_000)
    }

    @Test func cacheControllerPagesOutToECoreAndRestoresByReference() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Create test files
        let file1 = root.appending(path: "FileA.swift")
        try "func alpha() { print(\"alpha\") }".write(to: file1, atomically: false, encoding: .utf8)
        let file2 = root.appending(path: "FileB.swift")
        try "func beta() { print(\"beta\") }".write(to: file2, atomically: false, encoding: .utf8)

        let pager = ContextPager(store: ProjectPageStore(), workingSet: RecallWorkingSet())
        let scanner = ProjectScanner(root: root)
        let policy = EffectiveContextPolicy(
            addressableBudget: 100_000,
            modelWindow: 100_000,
            economicThreshold: nil,
            reserve: 100,
            pCoreTarget: 10,
            pCoreSoftLimit: 15,
            pCoreHardLimit: 20,
            eCoreStorageBudget: 50_000,
            eCoreRecallBudget: 1_000
        )
        let controller = ContextCacheController(
            contextPager: pager,
            scanner: scanner,
            policy: policy,
            ecoreStore: ECoreObjectStore(baseDirectory: root.appendingPathComponent("ecore"))
        )

        let sessionID = SessionID("test-eviction")
        _ = try await controller.handleSearch(sessionID: sessionID, query: "alpha")
        let pCoreAfterAlpha = await controller.pCoreResidentTokens(for: sessionID)
        #expect(pCoreAfterAlpha > 0)
        #expect(await controller.eCoreObjectCount(for: sessionID) == 0)

        // Adding beta will push PCore over softLimit (15 tokens), causing alpha to be demoted to RecallCache
        _ = try await controller.handleSearch(sessionID: sessionID, query: "beta")
        let eCoreAfterBeta = await controller.eCoreObjectCount(for: sessionID)
        #expect(eCoreAfterBeta > 0)
        let references = await controller.ecoreStore.references(sessionID: sessionID)
        let alphaReference = try #require(references.first { $0.origin == .page && $0.summary.contains("FileA.swift") })
        #expect(try await controller.ecoreStore.restore(sessionID: sessionID, referenceID: alphaReference.referenceID) == "func alpha() { print(\"alpha\") }")
        let residency = await controller.residencyTelemetry(sessionID: sessionID)
        #expect(residency.duplicateResidencyBytes == 0)

        let stats = await controller.pagingStats(for: sessionID)
        #expect(stats.demotions > 0)
        #expect(stats.pageOuts > 0)

        // Searching alpha again promotes it from RecallCache warm cache back to PCore
        _ = try await controller.handleSearch(sessionID: sessionID, query: "alpha")
        let statsAfterPromote = await controller.pagingStats(for: sessionID)
        #expect(statsAfterPromote.promotions > 0)
    }

    @Test func sessionResetEnsuresCompleteCacheIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appending(path: "Isolated.swift")
        try "struct SecretFact { let x = 42 }".write(to: file, atomically: false, encoding: .utf8)

        let pager = ContextPager(store: ProjectPageStore(), workingSet: RecallWorkingSet())
        let scanner = ProjectScanner(root: root)
        let controller = ContextCacheController(
            contextPager: pager,
            scanner: scanner
        )

        let sessionA = SessionID("session-A")
        let sessionB = SessionID("session-B")

        _ = try await controller.handleSearch(sessionID: sessionA, query: "SecretFact")
        #expect(await controller.pCoreResidentTokens(for: sessionA) > 0)
        #expect(await controller.residentPages(for: sessionA).count > 0)

        // Session B is completely isolated
        #expect(await controller.pCoreResidentTokens(for: sessionB) == 0)
        #expect(await controller.residentPages(for: sessionB).isEmpty)

        // Resetting Session A clears all its cached state
        await controller.resetSession(sessionA)
        #expect(await controller.pCoreResidentTokens(for: sessionA) == 0)
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
        try? await store.insertLegacyPage(page)

        // Query with Chinese greeting that doesn't match any tokens
        let results = await store.search(sessionID: sessionID, query: "你好呀", limit: 3)
        #expect(results.isEmpty)

        let englishNoMatch = await store.search(sessionID: sessionID, query: "hello there", limit: 3)
        #expect(englishNoMatch.isEmpty)
    }

    @Test func livePCoreAccountingReflectsTurnCompletionAndDistinguishesProviderInput() async throws {
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

        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()

    // Before any turn: the runtime system context is already resident in PCore.
    let initialProjection = try #require(await client.contextProjection(sessionID))
    #expect(initialProjection.pCore.usedTokens > 0)
        #expect(initialProjection.lastProviderInputTokens == nil)

        // Turn 1: "你好"
        let stream1 = try await client.sendMessage(sessionID: sessionID, content: "你好")
        for try await _ in stream1 {}

        // After Turn 1: PCore resident usage must reflect both user prompt AND assistant response
        let projection1 = try #require(await client.contextProjection(sessionID))
        let turn1Usage = projection1.pCore.usedTokens
        let turn1Input = try #require(projection1.lastProviderInputTokens)

        // PCore resident usage must be strictly greater than the input token count sent before inference
        #expect(turn1Usage > turn1Input)
        #expect(turn1Usage > 0)
        #expect(turn1Input > 0)
        #expect(projection1.eCore.objectCount == 0)
        #expect(projection1.eCore.totalBytes == 0)

        // Turn 2: Multi-turn prompt
        let stream2 = try await client.sendMessage(sessionID: sessionID, content: "请介绍一下 Swift Concurrency 的核心概念。")
        for try await _ in stream2 {}

        // After Turn 2: PCore usage and provider input must steadily grow
        let projection2 = try #require(await client.contextProjection(sessionID))
        let turn2Usage = projection2.pCore.usedTokens
        let turn2Input = try #require(projection2.lastProviderInputTokens)

        #expect(turn2Usage > turn1Usage)
        #expect(turn2Input > turn1Input)
        #expect(turn2Usage > turn2Input)
        await host.shutdown()
    }

    @Test("Strict Append-Only telemetry accurately detects mutations without false positives (Issue #44)")
    func strictAppendOnlyTelemetryDetectsMutationsAccurately() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = ContextCacheController(
            contextPager: ContextPager(store: ProjectPageStore(), workingSet: RecallWorkingSet()),
            scanner: ProjectScanner(root: root),
            policy: EffectiveContextPolicy(
                addressableBudget: 100_000,
                modelWindow: 100_000,
                economicThreshold: nil,
                reserve: 100,
                pCoreTarget: 10,
                pCoreSoftLimit: 15,
                pCoreHardLimit: 20,
                eCoreStorageBudget: 50_000,
                eCoreRecallBudget: 1_000
            )
        )

        let sessionID = SessionID("test-append-only-session")

        // Turn 1: Initial conversation
        let fp1 = PrefixFingerprint(
            systemHash: "sys_1",
            coreToolsHash: "tools_1",
            historyStableHash: "hist_1",
            requestProfileHash: "prof_1",
            stablePrefixHash: "prefix_1"
        )
        let hist1 = ["user:Hello", "assistant:Hi there!"]
        await controller.recordFingerprint(sessionID: sessionID, fingerprint: fp1, historySignatures: hist1)
        let health1 = try #require(await controller.lastClientHealth(for: sessionID))
        #expect(health1.appendOnlyHistory == true)
        #expect(health1.appendOnlyViolations == 0)

        // Turn 2: Legitimate append-only continuation
        let fp2 = PrefixFingerprint(
            systemHash: "sys_1",
            coreToolsHash: "tools_1",
            historyStableHash: "hist_2",
            requestProfileHash: "prof_1",
            stablePrefixHash: "prefix_1"
        )
        let hist2 = ["user:Hello", "assistant:Hi there!", "user:What is Swift?", "assistant:A language."]
        await controller.recordFingerprint(sessionID: sessionID, fingerprint: fp2, historySignatures: hist2)
        let health2 = try #require(await controller.lastClientHealth(for: sessionID))
        #expect(health2.appendOnlyHistory == true)
        #expect(health2.appendOnlyViolations == 0)

        // Turn 3: History mutation / truncation / edit (non-empty hash, but prefix broken!)
        let fp3 = PrefixFingerprint(
            systemHash: "sys_1",
            coreToolsHash: "tools_1",
            historyStableHash: "hist_3_mutated",
            requestProfileHash: "prof_1",
            stablePrefixHash: "prefix_1"
        )
        // Previous Turn 1 user message was edited: "user:Hello" -> "user:Edited Prompt"
        let hist3Mutated = ["user:Edited Prompt", "assistant:Hi there!", "user:What is Swift?"]
        await controller.recordFingerprint(sessionID: sessionID, fingerprint: fp3, historySignatures: hist3Mutated)
        let health3 = try #require(await controller.lastClientHealth(for: sessionID))
        // Must strictly detect violation!
        #expect(health3.appendOnlyHistory == false)
        #expect(health3.appendOnlyViolations == 1)
    }

    @Test("Context search recalls E-Core object fabric content accurately (Issues #40, #41, #42)")
    func ecoreFabricSearchRecallsObjectAccurately() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = ContextCacheController(
            contextPager: ContextPager(store: ProjectPageStore(), workingSet: RecallWorkingSet()),
            scanner: ProjectScanner(root: root),
            policy: EffectiveContextPolicy(
                addressableBudget: 100_000,
                modelWindow: 100_000,
                economicThreshold: nil,
                reserve: 100,
                pCoreTarget: 10,
                pCoreSoftLimit: 15,
                pCoreHardLimit: 20,
                eCoreStorageBudget: 50_000,
                eCoreRecallBudget: 1_000
            )
        )

        let sessionID = SessionID("test-ecore-search-session")

        // Store a large observation into E-Core
        let toolCallID = ToolCallID("call_find_symbols_123")
        let observationText = "FOUND SYMBOL: QuantumTelemetryProcessor in package Core/Telemetry.swift at line 42"
        let meta = await controller.ecoreStore.store(
            sessionID: sessionID,
            toolCallID: toolCallID,
            toolName: "find_symbols",
            content: observationText,
            force: true
        )
        #expect(meta != nil)

        // Perform context search query
        let searchResult = try await controller.handleSearch(
            sessionID: sessionID,
            query: "QuantumTelemetryProcessor"
        )

        #expect(searchResult.contains("## E-Core Fabric Objects"))
        #expect(searchResult.contains("find_symbols"))
        #expect(searchResult.contains("QuantumTelemetryProcessor"))
    }
}
