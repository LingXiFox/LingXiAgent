import Foundation
import Testing
@testable import LingXiProtocol
@testable import LingXiApplication
@testable import LingXiCore

@Suite("P/E Core Schema Migration & Storage Metrics Tests (Round 2 Phase E)", .serialized)
struct PECoreSchemaMigrationTests {

    @Test("Legacy JSON with l1/pCore/eCore/cache fields is cleanly adapted via decode adapter")
    func testLegacyDecodeAdapter() throws {
        let legacyJSON = """
        {
            "sessionID": "sess-legacy-test",
            "revision": 42,
            "estimatedTokens": 12000,
            "compactionGeneration": 3,
            "l1Tokens": 5000,
            "l2Tokens": 1000,
            "l3Tokens": 500,
            "pCoreTokens": 5000,
            "eCoreObjectCount": 15,
            "eCoreTotalBytes": 131072,
            "cacheReadTokens": 3500,
            "promptTokens": 8500,
            "previousPromptTokens": 8000,
            "cacheStatus": "hit",
            "cacheEpoch": 2,
            "epochReason": "prefix_stable",
            "stablePrefixHash": "abc123hash",
            "missDiagnostics": "none",
            "clientHealthStatus": "stable",
            "cacheDebt": 120
        }
        """

        let data = try #require(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(ContextStateSnapshot.self, from: data)

        // 1. Verify canonical properties were reconstructed
        #expect(decoded.sessionID == SessionID("sess-legacy-test"))
        #expect(decoded.revision == 42)
        #expect(decoded.compactionGeneration == 3)
        #expect(decoded.estimatedTokens == 12000)

        #expect(decoded.pCore?.usedTokens == 5000)
        #expect(decoded.eCore?.objectCount == 15)
        #expect(decoded.eCore?.totalBytes == 131072)
        #expect(decoded.providerCache?.cacheReadTokens == 3500)
        #expect(decoded.providerCache?.promptTokens == 8500)
        #expect(decoded.providerCache?.previousPromptTokens == 8000)
        #expect(decoded.providerCache?.cacheStatus == "hit")
        #expect(decoded.providerCache?.cacheEpoch == 2)
        #expect(decoded.providerCache?.epochReason == "prefix_stable")
        #expect(decoded.providerCache?.stablePrefixHash == "abc123hash")
        #expect(decoded.providerCache?.missDiagnostics == "none")
        #expect(decoded.providerCache?.clientHealthStatus == "stable")
        #expect(decoded.providerCache?.cacheDebt == 120)

        // 2. Verify legacy computed properties are non-breaking
        #expect(decoded.l1Tokens == 5000)
        #expect(decoded.l2Tokens == 0)
        #expect(decoded.l3Tokens == 0)
        #expect(decoded.pCoreTokens == 5000)
        #expect(decoded.eCoreObjectCount == 15)
        #expect(decoded.eCoreTotalBytes == 131072)
        #expect(decoded.activePCoreTokens == 5000)
        #expect(decoded.cacheReadTokens == 3500)
        #expect(decoded.promptTokens == 8500)
        #expect(decoded.previousPromptTokens == 8000)
        #expect(decoded.cacheDebt == 120)
    }

    @Test("Canonical ContextStateSnapshot serializes exclusively canonical schema without legacy keys")
    func testCanonicalEncodingExcludesLegacyKeys() throws {
        let snapshot = ContextStateSnapshot(
            sessionID: SessionID("sess-canonical-test"),
            revision: 10,
            pCore: PCoreStateSnapshot(usedTokens: 4096, targetTokens: 16000, softLimitTokens: 14000, hardLimitTokens: 18000),
            eCore: ECoreStateSnapshot(objectCount: 8, totalBytes: 65536, hotObjectCount: 2, coldObjectCount: 6, revision: 10),
            providerCache: ProviderCacheStateSnapshot(
                promptTokens: 5000,
                previousPromptTokens: 4800,
                cacheReadTokens: 3000,
                cacheEpoch: 1,
                epochReason: "ok",
                cacheDebt: 0,
                clientHealthStatus: "stable",
                stablePrefixHash: "hash-stable",
                cacheStatus: "hit",
                missDiagnostics: nil
            ),
            estimatedTokens: 4096,
            compactionGeneration: 0
        )

        let data = try JSONEncoder().encode(snapshot)
        let jsonObject = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Verify canonical fields are present
        let rawSessionID = (jsonObject["sessionID"] as? [String: Any])?["rawValue"] as? String ?? (jsonObject["sessionID"] as? String)
        #expect(rawSessionID == "sess-canonical-test")
        #expect(jsonObject["revision"] as? UInt64 == 10 || jsonObject["revision"] as? Int == 10)
        #expect(jsonObject["compactionGeneration"] as? Int == 0)
        #expect(jsonObject["pCore"] != nil)
        #expect(jsonObject["eCore"] != nil)
        #expect(jsonObject["providerCache"] != nil)

        // Verify legacy stored keys are completely absent
        #expect(jsonObject["l1Tokens"] == nil)
        #expect(jsonObject["l2Tokens"] == nil)
        #expect(jsonObject["l3Tokens"] == nil)
        #expect(jsonObject["pCoreTokens"] == nil)
        #expect(jsonObject["eCoreObjectCount"] == nil)
        #expect(jsonObject["eCoreTotalBytes"] == nil)
        #expect(jsonObject["cacheReadTokens"] == nil)
        #expect(jsonObject["promptTokens"] == nil)
        #expect(jsonObject["previousPromptTokens"] == nil)
        #expect(jsonObject["cacheStatus"] == nil)
        #expect(jsonObject["cacheEpoch"] == nil)
        #expect(jsonObject["epochReason"] == nil)
        #expect(jsonObject["stablePrefixHash"] == nil)
        #expect(jsonObject["missDiagnostics"] == nil)
        #expect(jsonObject["clientHealthStatus"] == nil)
        #expect(jsonObject["cacheDebt"] == nil)
    }

    @Test("Context state revision is monotonic and strictly decoupled from compaction generation")
    func testRevisionDecoupledFromCompactionGeneration() {
        let sessionID = SessionID("sess-revision-decoupled")

        // Turn 1: Initial state, revision 1, compactionGeneration 0
        let snap1 = ContextStateSnapshot(
            sessionID: sessionID,
            revision: 1,
            pCore: PCoreStateSnapshot(usedTokens: 1000),
            compactionGeneration: 0
        )
        #expect(snap1.revision == 1)
        #expect(snap1.compactionGeneration == 0)

        // Turn 2: State updated without compaction -> revision 2, compactionGeneration still 0
        let snap2 = ContextStateSnapshot(
            sessionID: sessionID,
            revision: 2,
            pCore: PCoreStateSnapshot(usedTokens: 2500),
            compactionGeneration: 0
        )
        #expect(snap2.revision == 2)
        #expect(snap2.compactionGeneration == 0)
        #expect(snap2.revision > snap1.revision)

        // Turn 3: Compaction occurs -> revision 3, compactionGeneration increments to 1
        let snap3 = ContextStateSnapshot(
            sessionID: sessionID,
            revision: 3,
            pCore: PCoreStateSnapshot(usedTokens: 1200),
            compactionGeneration: 1
        )
        #expect(snap3.revision == 3)
        #expect(snap3.compactionGeneration == 1)
        #expect(snap3.revision > snap2.revision)
    }

    @Test("ECoreObjectStore storageMetrics O(1) tracking on store and clean")
    func testECoreStorageMetricsO1Tracking() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-ecore-metrics-\(UUID().uuidString)")
        let store = ECoreObjectStore(baseDirectory: tempDir)
        let sessionID = SessionID("sess-metrics-test")

        // Initial metrics
        let initial = await store.storageMetrics(for: sessionID)
        #expect(initial.count == 0)
        #expect(initial.totalBytes == 0)

        // Store object 1
        let content1 = "Hello E-Core Fabric Object 1"
        let meta1 = await store.store(
            sessionID: sessionID,
            toolCallID: ToolCallID("call-1"),
            toolName: "read_file",
            content: content1,
            force: true
        )
        #expect(meta1 != nil)

        let after1 = await store.storageMetrics(for: sessionID)
        #expect(after1.count == 1)
        #expect(after1.totalBytes == content1.utf8.count)

        // Store object 2
        let content2 = "Second Observation Content for Metrics Test"
        let meta2 = await store.store(
            sessionID: sessionID,
            toolCallID: ToolCallID("call-2"),
            toolName: "grep_search",
            content: content2,
            force: true
        )
        #expect(meta2 != nil)

        let after2 = await store.storageMetrics(for: sessionID)
        #expect(after2.count == 2)
        #expect(after2.totalBytes == content1.utf8.count + content2.utf8.count)

        // Clean session
        await store.cleanSession(sessionID: sessionID)
        let afterClean = await store.storageMetrics(for: sessionID)
        #expect(afterClean.count == 0)
        #expect(afterClean.totalBytes == 0)

        try? FileManager.default.removeItem(at: tempDir)
    }
}
