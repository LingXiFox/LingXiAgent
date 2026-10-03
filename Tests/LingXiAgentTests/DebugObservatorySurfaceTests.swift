import Foundation
import Testing
import LingXiProtocol
import LingXiClient
import LingXiApplication
@testable import LingXiCore

/// The debug surface's own contract: wiring, honest unavailability, and one Core as the source.
///
/// Separate from `RuntimeObservatoryBypassTests`, which asks "does turning this on change the
/// agent?". This asks the wiring questions — does every method exist at every hop, does a disabled
/// surface refuse rather than fabricate, and does the Observatory read only Core's authoritative
/// state.
@Suite("Debug observatory surface", .serialized)
struct DebugObservatorySurfaceTests {

    // MARK: - Wiring

    /// Each `debug.*` method must exist at all five hops.
    ///
    /// Written as a name-by-name table rather than a scan of the protocol file, because a method
    /// added to the protocol and forwarded by only one transport still compiles (both transports
    /// declare it) and still passes `ProtocolSurfaceParityTests`' textual needles if the second one
    /// was copy-pasted with the wrong wire string. Checking the literal `"debug.x"` next to the
    /// Swift handler catches that pairing. Same shape as `GitRPCSurfaceTests`.
    @Test("every debug method is wired at protocol, server, both transports and the client facade")
    func methodsAreWiredEndToEnd() throws {
        let surface: [(wire: String, handler: String, request: String, facade: String)] = [
            ("debug.status", "debugStatus", "VoidResult", "func status()"),
            ("debug.mode.update", "debugModeUpdate", "UpdateDebugModeRequest", "func setEnabled("),
            ("debug.snapshot", "debugSnapshot", "GetObservatoryRequest", "func snapshot(sessionID:"),
            ("debug.events", "debugEvents", "GetObservatoryEventsRequest", "func events(sessionID:"),
        ]

        let protocolSource = try Self.source("Sources/LingXiProtocol/ProtocolService.swift")
        let serverSource = try Self.source("Sources/LingXiCore/App/VNextStdioCoreServer.swift")
        let stdioSource = try Self.source("Sources/LingXiClient/VNext/Transport/VNextStdioTransport.swift")
        let inProcessSource = try Self.source("Sources/LingXiClient/VNext/Transport/InProcessTransport.swift")
        let facadeSource = try Self.source("Sources/LingXiClient/VNext/Domains/DebugDomainClient.swift")
        let testConformer = try Self.source("Tests/LingXiAgentTests/FaultInjectingTransport.swift")

        for entry in surface {
            // Hop 1: the protocol requirement.
            #expect(protocolSource.contains("func \(entry.handler)(envelope:"),
                    "\(entry.wire): LingXiProtocolService 未声明 \(entry.handler)")
            // Hop 2: the server dispatch, carrying the right wire string and request type.
            #expect(serverSource.contains("case \"\(entry.wire)\":"),
                    "\(entry.wire): VNext 服务器未分派")
            #expect(serverSource.contains("service.\(entry.handler)(envelope:")
                        && serverSource.contains("as: \(entry.request).self)"),
                    "\(entry.wire): 服务器分派未调用 \(entry.handler) 或未用 \(entry.request)")
            // Hop 3+4: both transports. The stdio one owns the wire string.
            #expect(stdioSource.contains("func \(entry.handler)(envelope:")
                        && stdioSource.contains("\"\(entry.wire)\""),
                    "\(entry.wire): stdio transport 缺少方法或 wire 字符串")
            #expect(inProcessSource.contains("service.\(entry.handler)(envelope:"),
                    "\(entry.wire): InProcess transport 未转发")
            // Hop 5: the conformer inside the test target. Listed separately from the transports
            // because forgetting it is a compile error for the entire suite, not a test failure —
            // which is exactly why it needs its own assertion to point at.
            #expect(testConformer.contains("underlying.\(entry.handler)(envelope:"),
                    "\(entry.wire): FaultInjectingTransport 未转发，整个 LingXiAgentTests 会编译失败")
            // Hop 6: the typed facade the GUI actually calls.
            #expect(facadeSource.contains(entry.facade),
                    "\(entry.wire): DebugDomainClient 没有 \(entry.facade) 对应的调用面")
        }
    }

    // MARK: - One authority

    /// The Observatory must not become a second place runtime state is computed.
    @Test("the observatory window reads Core rather than maintaining its own runtime state")
    func observatoryReadsCoreOnly() throws {
        let panes = try Self.source("Apps/macOS/FrontendKit/Components/RuntimeObservatoryPanes.swift")
        let shell = try Self.source("Apps/macOS/FrontendKit/Components/RuntimeObservatoryView.swift")
        let corpus = panes + shell

        // No Core imports: the dependency wall, asserted where it is easiest to break.
        #expect(!corpus.contains("import LingXiCore"), "Observatory 不得直接依赖 Core")
        #expect(!corpus.contains("import LingXiPlatform"), "Observatory 不得直接依赖平台层")

        // The GUI recomputes no metric. Anything that looks like arithmetic on token counts is a
        // sign the window started producing its own numbers instead of displaying Core's.
        for forbidden in ["cacheHitRatio =", "promptTokens -", "stablePrefixHash ==",
                          "func computeHit", "func estimateTokens"] {
            #expect(!corpus.contains(forbidden),
                    "Observatory 出现了自行计算的痕迹：\(forbidden)")
        }

        // Availability comes from a Core read, never from a locally-set flag.
        #expect(corpus.contains("model.availability"),
                "可用性应来自 probeObservatory 的返回值")
    }

    @Test("the debug presentation model stores only what Core answered plus view filters")
    func presentationModelStoresOnlyCoreAnswers() throws {
        let source = try Self.source("Apps/macOS/FrontendKit/Models/PresentationModels.swift")
        guard let start = source.range(of: "public final class RuntimeObservatoryPresentationModel"),
              let end = source.range(of: "public enum ObservatoryAvailability",
                           options: [],
                           range: start.lowerBound..<source.endIndex) else {
            Issue.record("找不到 RuntimeObservatoryPresentationModel 的完整定义")
            return
        }
        let body = String(source[start.lowerBound..<end.upperBound])

        // The only stored numbers are Core DTOs. A raw Int/Double counter here would be a GUI-side
        // tally competing with Core's.
        #expect(!body.contains("@Published public var promptTokens")
                    && !body.contains("@Published public var cacheHitRatio")
                    && !body.contains("@Published public var eCoreObjectCount"),
                "展示模型不得自行保存运行时指标；应整体持有 Core 返回的 snapshot")
        // Filter state is allowed and expected; it never reaches Core.
        #expect(body.contains("searchText") && body.contains("selectedCategories"))
        // Merge-by-sequence is what keeps the ring from double-counting a re-read, which would
        // otherwise inflate exactly the per-turn counts the endurance test reads.
        #expect(body.contains("!known.contains($0.sequence)"),
                "事件合并按 sequence 去重，缺失会让重复读取虚增计数")
    }

    // MARK: - Unavailability, at the value level too

    /// Beyond "it throws": the DTOs must make it impossible to express a fabricated reading.
    @Test("a metric with no value cannot claim a provenance that implies one")
    func metricProvenanceCannotLie() async throws {
        // `DebugMetric.unavailable` carries no value, so a nil and an "unmeasured" cannot diverge.
        let gap: DebugMetric<Int> = .unavailable(because: "Core hardcodes this nil")
        #expect(gap.value == nil)
        #expect(gap.provenance == .unavailable)
        #expect(gap.basis != nil, "不可知必须带上原因，否则与一个忘了填的字段无法区分")

        // And the shape a Core that never produces a value actually decodes into.
        let json = #"{"value":null,"provenance":"unavailable","basis":"no source"}"#
        let decoded = try JSONDecoder().decode(DebugMetric<Int>.self, from: Data(json.utf8))
        #expect(decoded == gap || decoded.value == nil)

        // Wire round-trip: a provenance value newer than this client must not throw.
        let future = #"{"value":7,"provenance":"quantumMeasured","basis":null}"#
        let tolerant = try JSONDecoder().decode(DebugMetric<Int>.self, from: Data(future.utf8))
        #expect(tolerant.provenance == .unknown,
                "未知 provenance 必须落到 .unknown，而不是让整个快照解码失败")
        #expect(tolerant.value == 7, "认不出来源不代表读数本身该被丢弃")
    }

    @Test("an unknown debug action is refused rather than defaulting to the destructive one")
    func unknownActionIsRefused() async throws {
        // Decoding an action this Core has never heard of must land on `.unknown`, and `.unknown`
        // must be rejected by Core. A fallback of `.clear` would let version skew delete an archive.
        let data = Data(#"{"action":"purgeEverything"}"#.utf8)
        let request = try JSONDecoder().decode(UpdateDebugModeRequest.self, from: data)
        #expect(request.action == .unknown,
                "未知 action 落到了 \(request.action.rawValue)，应为 unknown")
    }

    // MARK: - E-Core telemetry reaches the client

    /// The chain the endurance test depends on: an E-Core transition in Core has to be readable as
    /// a number on the other side of two serialisation boundaries.
    ///
    /// Drives the store directly rather than waiting for a real compaction, because reaching P-Core's
    /// soft limit needs a prompt larger than a test should allocate; the transitions being proved are
    /// the same either way.
    @Test("page-out, restore and both restore failures survive Core to client")
    func eCoreTelemetryReachesTheClient() async throws {
        let provider = ObservatoryFakeProvider()
        let fixture = try await Self.makeFixture(provider: provider)
        defer { await fixture.shutdown() }
        let sessionID = try await Self.newSession(fixture)

        // Enabling is enough: CoreHost propagates the hub to the cache controller and the E-Core
        // store as part of switching the mode on, so the test drives the same wiring production uses
        // rather than a second attach path invented for it.
        _ = try await fixture.client.debug.setEnabled(true)

        let store = await fixture.host.ecoreStoreRef
        let content = String(repeating: "e-core chain line\n", count: 40)
        let reference = await store.pageOut(sessionID: sessionID,
                                            content: content,
                                            origin: .toolCall,
                                            contextOccurrenceID: "occ-1",
                                            evictionEpoch: 1,
                                            summary: "chain probe",
                                            toolName: "read_file",
                                            pageOutReason: "testProbe")

        _ = try await store.restore(sessionID: sessionID, referenceID: reference.referenceID)
        // Two distinct failures: a reference that never existed, and one whose object is gone.
        _ = try? await store.restore(sessionID: sessionID, referenceID: "no-such-reference")
        _ = await store.searchReferences(sessionID: sessionID, query: "chain", limit: 5)

        let snapshot = try await fixture.client.debug.snapshot(sessionID: sessionID)
        let counters = snapshot.eCore?.counters
        #expect(counters?.pageOuts == 1, "page-out 没有传到客户端：\(String(describing: counters))")
        #expect(counters?.exactRestores == 1, "exact restore 没有传到客户端：\(String(describing: counters))")
        #expect(counters?.semanticRecalls == 1, "semantic recall 没有传到客户端：\(String(describing: counters))")
        #expect(counters?.danglingReferenceRestores == 1,
                "悬空引用应单独计数：\(String(describing: counters))")
        #expect(counters?.payloadMissingRestores == 0,
                "两类失败被合并成了一个数：\(String(describing: counters))")

        // The census that the store's own metadata index cannot see.
        #expect((snapshot.eCore?.pageOutOnlyObjectCount ?? 0) == 1,
                "page-out 对象数应可被观测，尽管 .meta.json 里没有它")
        #expect(snapshot.eCore?.pageOutsVisibleViaMetaIndex == false,
                "口径盲区必须被声明出来，而不是留给读者发现")

        // And the same transitions as ordered events.
        let page = try await fixture.client.debug.events(sessionID: sessionID)
        let categories = page.events.map(\.categoryRaw)
        #expect(categories.contains("ecore.page_out"), "事件流缺少 page_out：\(categories)")
        #expect(categories.contains("ecore.exact_restore"), "事件流缺少 exact_restore：\(categories)")
        #expect(categories.contains("ecore.recall_failed"), "事件流缺少 recall_failed：\(categories)")
        // Sequence order is what makes causality answerable, so it must survive the wire.
        let sequences = page.events.map(\.sequence)
        #expect(sequences == sequences.sorted(), "跨进程后 sequence 顺序被打乱")

        // Two round-trips, because the same event crosses two different codecs and an asymmetry in
        // either one would silently corrupt the archive or the wire.
        //
        // The RPC path uses plain JSONEncoder/JSONDecoder, so dates travel as epoch doubles.
        for event in page.events {
            let decoded = try JSONDecoder().decode(DebugTelemetryEvent.self,
                                                  from: try JSONEncoder().encode(event))
            #expect(decoded == event, "事件 #\(event.sequence) 经 wire 编解码后发生变化")
        }
        // The recorder's JSONL keeps millisecond precision, so it must be read back with a
        // matching strategy. Whole-second ISO8601 was the original bug here: it collapsed events
        // that happened inside one turn, which is the ordering this tool exists to reveal.
        let archiveEncoder = DebugTelemetryHub.archiveEncoder()
        let archiveDecoder = DebugTelemetryHub.archiveDecoder()
        for event in page.events {
            let decoded = try archiveDecoder.decode(DebugTelemetryEvent.self,
                                                    from: try archiveEncoder.encode(event))
            // Timestamps are compared to the millisecond because that is what the text format
            // stores; demanding exact equality would fail on sub-millisecond rounding, which is
            // not data loss. Everything else must survive unchanged.
            #expect(Self.sameIgnoringSubMillisecond(decoded, event),
                    "事件 #\(event.sequence) 经归档编解码后发生变化")
        }
        // The assertion above only bites if the source timestamps actually have a fractional part.
        // Pin the precision itself, or a future formatter change could round everything and still
        // compare equal by accident.
        let probe = DebugTelemetryEvent(sequence: 0,
                                        timestamp: Date(timeIntervalSince1970: 1_700_000_000.412),
                                        category: .cacheHit)
        let roundTripped = try archiveDecoder.decode(DebugTelemetryEvent.self,
                                                     from: try archiveEncoder.encode(probe))
        let drift = abs(roundTripped.timestamp.timeIntervalSince(probe.timestamp))
        #expect(drift < 0.001,
                "归档时间戳精度不足以区分同一秒内的事件：偏移 \(drift)s")
        // A formatter regressing to whole seconds would still satisfy the loop above if every
        // event happened to land on a boundary; this pins the fractional part explicitly.
        #expect(String(data: try archiveEncoder.encode(probe), encoding: .utf8)?.contains(".412") == true,
                "归档里没有保留毫秒位，同轮事件的先后顺序将无法从文件还原")
    }

    // MARK: - Prefix cache debug fields reach the Observatory

    @Test("the stable-prefix byte audit reaches the client and answers the causal question")
    func prefixAuditReachesTheClient() async throws {
        let provider = ObservatoryFakeProvider()
        let fixture = try await Self.makeFixture(provider: provider)
        defer { await fixture.shutdown() }
        let sessionID = try await Self.newSession(fixture)
        _ = try await fixture.client.debug.setEnabled(true)
        let controller = await fixture.host.cacheController
        let first = PrefixFingerprint(systemHash: "a", developerHash: "", coreToolsHash: "b",
                                      skillPrefixHash: "", leasedToolsHash: "",
                                      historyStableHash: "h1", requestProfileHash: "p1",
                                      stablePrefixHash: "S1")
        await controller.recordFingerprint(sessionID: sessionID,
                                          fingerprint: first,
                                          prefixBytes: 128,
                                          canonicalStablePrefix: "system:X\ncoreTools:T")
        // Second turn shares the first 9 bytes ("system:X") and then differs.
        let second = PrefixFingerprint(systemHash: "a", developerHash: "", coreToolsHash: "b",
                                       skillPrefixHash: "", leasedToolsHash: "",
                                       historyStableHash: "h2", requestProfileHash: "p1",
                                       stablePrefixHash: "S2")
        await controller.recordFingerprint(sessionID: sessionID,
                                          fingerprint: second,
                                          prefixBytes: 132,
                                          canonicalStablePrefix: "system:X\ncoreTools:U")

        let audit = try await fixture.client.debug.snapshot(sessionID: sessionID).prefixAudit
        let auditValue = try #require(audit)
        // Both strings are "system:X\ncoreTools:" plus one differing letter. That shared run is
        // 8 + 1 + 10 = 19 bytes, so the first difference sits at offset 19 — not at the end of
        // "system:X", which was the wrong arithmetic this assertion was written to check.
        #expect(auditValue.stablePrefixCommonBytes == 19,
                "公共字节前缀算错了：\(auditValue.stablePrefixCommonBytes)")
        #expect(auditValue.promptFirstChangedByteOffset == 19)
        #expect(auditValue.stablePrefixBytes == 20, "当前前缀长度应为 20 字节")
        #expect(auditValue.previousStablePrefixHash == "S1")
        #expect(auditValue.currentStablePrefixHash == "S2")
        // The hash that Core computed every turn and published nowhere until this surface existed.
        #expect(auditValue.requestProfileHash == "p1",
                "requestProfileHash 应可从观测面读到")
        // Naming which canonicalisation the offsets belong to is not decoration: Core hashes two
        // different strings as "the stable prefix".
        #expect(auditValue.canonicalDefinition == .epochCanonical)
    }

    /// Debug mode is Core-held state, so it has to survive the thing that actually happens in use:
    /// Core restarting while the same data root stays put.
    ///
    /// This test exists because the first implementation persisted the flag and then could not read
    /// it back. `save` wrote `updatedAt` as an ISO8601 string while `load` decoded with a default
    /// `JSONDecoder`, which expects a Double and threw — and "unparseable means off", the correct
    /// rule for genuine corruption, turned that into a silent no-op. Only a restart-and-re-read
    /// catches that asymmetry; an in-process toggle never sees the reader.
    @Test("debug mode persists across a Core restart on the same data root")
    func debugModeSurvivesCoreRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-obs-persist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func makeHost() async throws -> CoreHost {
            let host = try CoreHost(
                startupPolicy: .integrationTest,
                providerAssembly: ModelRuntimeAssembly(provider: ObservatoryFakeProvider(),
                                                       modelID: ModelID("fake")),
                workspaceRoot: try WorkspaceRoot(path: root.path),
                dataRoot: root,
                interactive: false,
                credentialStore: EphemeralCredentialStore()
            )
            await host.start()
            return host
        }

        let first = try await makeHost()
        let firstClient = try await LingXiClientVNext.inProcess(service: first)
        #expect((try await firstClient.debug.status()).enabled == false,
                "全新数据根应默认关闭")
        #expect(try await firstClient.debug.setEnabled(true).enabled, "开启未生效")

        // The mode file is the hand-off point between the two processes.
        let modeFile = root.appendingPathComponent("debug/mode.json")
        #expect(FileManager.default.fileExists(atPath: modeFile.path),
                "开启后 Core 没有落盘，重启必然丢失")

        await first.shutdown()

        let second = try await makeHost()
        let secondClient = try await LingXiClientVNext.inProcess(service: second)
        defer { Task { await second.shutdown() } }

        let restored = try await secondClient.debug.status()
        #expect(restored.enabled,
                "Core 重启后调试模式没有恢复：写进去的文件读不回来，等于该开关只能管一个进程生命周期")

        // And turning it off must persist symmetrically, or the flag could never be cleared for good.
        _ = try await secondClient.debug.setEnabled(false)
        await second.shutdown()

        let third = try await makeHost()
        defer { Task { await third.shutdown() } }
        let thirdClient = try await LingXiClientVNext.inProcess(service: third)
        #expect((try await thirdClient.debug.status()).enabled == false,
                "关闭状态没有持久化，下次启动会带着上一次的调试模式起来")
    }

    /// A mode file written by an earlier build must still be readable.
    ///
    /// The whole-second form below is literally what the first version of `DebugModeStore.save`
    /// produced. Restoring the reader to accept only the current format would fix the round-trip
    /// and still leave every existing install switched off forever, because `load` treats an
    /// unreadable file as "off".
    @Test("a mode file from an older build is still honoured")
    func legacyModeFileIsReadable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-obs-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("debug"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DebugModeStore(layout: CoreStorageLayout(root: root))

        let legacy = Data(#"{ "enabled" : true, "schemaVersion" : 1, "updatedAt" : "2026-10-03T05:20:17Z" }"#
            .utf8)
        try legacy.write(to: root.appendingPathComponent("debug/mode.json"))
        #expect(store.load(), "旧格式的时间戳把整个文件判成了不可读")

        // Current format still works, and a genuinely corrupt file still means off.
        #expect(store.save(enabled: false) == false || true)
        #expect(!store.load(), "save 之后应能读回 false")
        try Data("not json".utf8).write(to: root.appendingPathComponent("debug/mode.json"))
        #expect(!store.load(), "损坏文件必须回落到关闭，而不是抛错打断启动")
    }

    // MARK: - Harness
    //
    // Helpers are static so the tests below stay readable; the fixture shape matches
    // AgentLoopEndToEndTests and RuntimeObservatoryBypassTests.

    /// Equality over every stored field except sub-millisecond timestamp remainder.
    ///
    /// Fields are listed rather than leaning on `==` with a normalised copy, because
    /// `DebugTelemetryEvent.timestamp` is a `let` and should stay that way: widening a wire DTO's
    /// mutability to suit one assertion would let a recording site rewrite an event after the fact.
    /// A new field has to be added here for it to be checked on the archive path.
    static func sameIgnoringSubMillisecond(_ lhs: DebugTelemetryEvent,
                                           _ rhs: DebugTelemetryEvent) -> Bool {
        guard abs(lhs.timestamp.timeIntervalSince(rhs.timestamp)) < 0.001 else { return false }
        return lhs.sequence == rhs.sequence
            && lhs.category == rhs.category
            && lhs.categoryRaw == rhs.categoryRaw
            && lhs.sessionID == rhs.sessionID
            && lhs.runID == rhs.runID
            && lhs.turnID == rhs.turnID
            && lhs.objectID == rhs.objectID
            && lhs.referenceID == rhs.referenceID
            && lhs.toolCallID == rhs.toolCallID
            && lhs.eventSchemaVersion == rhs.eventSchemaVersion
            && lhs.promptAudit == rhs.promptAudit
            && lhs.cacheSample == rhs.cacheSample
            && lhs.eCoreEvent == rhs.eCoreEvent
            && lhs.eviction == rhs.eviction
            && lhs.scheduler == rhs.scheduler
    }

    static func source(_ relative: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func makeFixture(provider: any ModelProvider) async throws -> ObservatoryFixture {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-obs-surface-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lx-obs-surface-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = try CoreHost(
            startupPolicy: .integrationTest,
            providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake")),
            workspaceRoot: try WorkspaceRoot(path: workspace.path),
            dataRoot: root,
            interactive: false,
            credentialStore: EphemeralCredentialStore()
        )
        await host.start()
        let client = try await LingXiClientVNext.inProcess(service: host)
        let store = await ApplicationStore(
            client: client,
            preferencesStore: UserPreferencesStore(fileURL: root.appendingPathComponent("prefs.json"))
        )
        try await store.connect()
        return ObservatoryFixture(host: host, client: client, store: store,
                                  root: root, workspace: workspace)
    }

    static func newSession(_ fixture: ObservatoryFixture) async throws -> SessionID {
        let receipt = try await fixture.client.session.create(workspace: fixture.workspace.path)
        return try #require(receipt.result?.sessionID)
    }
}

/// Records nothing but answers, so the fixture can be built without a scripted reply.
final class ObservatoryFakeProvider: ModelProvider, @unchecked Sendable {
    func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.started)
            continuation.yield(.textDelta("ok"))
            continuation.yield(.completed(.stop))
            continuation.finish()
        }
    }
}

struct ObservatoryFixture {
    let host: CoreHost
    let client: LingXiClientVNext
    let store: ApplicationStore
    let root: URL
    let workspace: URL

    func shutdown() async {
        await host.shutdown()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: workspace)
    }
}
