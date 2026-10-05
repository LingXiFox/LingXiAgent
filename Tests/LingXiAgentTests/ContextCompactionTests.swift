import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore
import LingXiClient

struct ContextCompactionTests {
    private let estimator = ConservativeTokenEstimator()

    private func entry(_ id: String, role: ContextRole, source: ContextSource, content: String) -> ContextEntry {
        ContextEntry(messageID: MessageID(id), role: role, source: source, part: .text(content))
    }

    private func compactableEntries(_ first: String = "alpha archived context", _ second: String = "beta archived context") -> [ContextEntry] {
        [
            entry("old-1", role: .assistant, source: .assistantMessage, content: String(repeating: first + " ", count: 24)),
            entry("old-2", role: .assistant, source: .assistantMessage, content: String(repeating: second + " ", count: 24)),
            entry("recent", role: .assistant, source: .assistantMessage, content: "recent answer"),
            entry("current", role: .user, source: .userMessage, content: "current question"),
        ]
    }

    private var compactionBudget: ContextBudget {
        ContextBudget(hardInputLimit: 300, preferredActiveTokens: 60, highWaterTokens: 60, lowWaterTokens: 30, reservedOutputTokens: 0, protocolOverheadTokens: 0, toolSchemaTokens: 0, safetyMarginTokens: 0)
    }

    private var indexBudget: ContextBudget {
        ContextBudget(hardInputLimit: 2000, preferredActiveTokens: 60, highWaterTokens: 60, lowWaterTokens: 30, reservedOutputTokens: 0, protocolOverheadTokens: 0, toolSchemaTokens: 0, safetyMarginTokens: 0)
    }

    @Test func budgetPlannerReservesTheLargestRequestedOutputAndToolSchema() {
        let planner = ContextBudgetPlanner(policy: ContextBudgetPolicy(preferredRatio: 0.5, defaultActiveCeiling: 1_000, safetyMarginTokens: 50, fixedOverheadTokens: 100))
        let profile = ModelContextProfile(contextWindowTokens: 1_000, maxOutputTokens: 200, recommendedOutputReserveTokens: 300)

        let recommended = planner.plan(profile: profile, toolSchemaTokens: 100)
        let requested = planner.plan(profile: profile, requestedMaxOutputTokens: 400, toolSchemaTokens: 100)

        #expect(recommended.reservedOutputTokens == 300)
        #expect(recommended.hardInputLimit == 450)
        #expect(recommended.preferredActiveTokens == 225)
        #expect(requested.reservedOutputTokens == 400)
        #expect(requested.hardInputLimit == 350)
        #expect(requested.highWaterTokens <= requested.hardInputLimit)
    }

    @Test func pageInNeverExceedsRemainingTokenBudget() async throws {
        let compactor = ContextCompactor()
        _ = try await compactor.compact(sessionID: SessionID("page-in"), entries: compactableEntries(), budget: compactionBudget)

        let all = await compactor.pageIn(sessionID: SessionID("page-in"), query: "archived context", remainingTokens: 10_000)
        let first = try #require(all.first)
        let firstCost = estimator.estimate(entries: [first])
        let limited = await compactor.pageIn(sessionID: SessionID("page-in"), query: "archived context", remainingTokens: firstCost)

        #expect(limited == [first])
        #expect(estimator.estimate(entries: limited) <= firstCost)
        #expect(await compactor.pageIn(sessionID: SessionID("page-in"), query: "archived context", remainingTokens: firstCost - 1).isEmpty)
    }

    @Test func derivedPagesAreSessionIsolated() async throws {
        let compactor = ContextCompactor()
        _ = try await compactor.compact(sessionID: SessionID("a"), entries: compactableEntries("alpha only", "alpha again"), budget: compactionBudget)
        _ = try await compactor.compact(sessionID: SessionID("b"), entries: compactableEntries("beta only", "beta again"), budget: compactionBudget)

        let a = await compactor.pageIn(sessionID: SessionID("a"), query: "alpha", remainingTokens: 10_000)
        let b = await compactor.pageIn(sessionID: SessionID("b"), query: "beta", remainingTokens: 10_000)

        #expect(a.allSatisfy { ContextCompactor.content(of: $0.part).contains("alpha") })
        #expect(b.allSatisfy { ContextCompactor.content(of: $0.part).contains("beta") })
        #expect(await compactor.pageIn(sessionID: SessionID("a"), query: "beta", remainingTokens: 10_000).isEmpty)
    }

    @Test func rehydrationFlowsThroughPCoreSnapshot() async throws {
        let sessionID = SessionID("rehydration")
        let compactor = ContextCompactor()
        let compacted = try await compactor.compact(sessionID: sessionID, entries: compactableEntries(), budget: indexBudget)
        let rehydrated = await compactor.pageIn(sessionID: sessionID, query: "alpha", remainingTokens: 10_000)
        let session = Session(id: sessionID, createdAt: Date())
        // 索引投影本身就是一条 derivedPage，因此驻留页数量 = 召回条目 + 1。
        let snapshot = await PCoreContextEngine().snapshot(for: session, activeEntries: compacted.entries + rehydrated, estimatedTokens: compacted.afterTokens + estimator.estimate(entries: rehydrated))

        #expect(compacted.pagedOut > 0)
        #expect(snapshot.metrics.derivedPageCount == rehydrated.count + 1)
        #expect(snapshot.modelMessages().contains { $0.content.contains("[E-Core index]") })
        #expect(snapshot.modelMessages().contains { $0.content.contains("[Restored session context]") })
    }

    @Test func historicalUserTurnsRemainEligibleAndRehydrateWithoutChangingCanonicalHistory() async throws {
        let sessionID = SessionID("historical-users")
        let compactor = ContextCompactor()
        let oldUser = entry("anchor-01", role: .user, source: .userMessage, content: String(repeating: "Anchor-01 archived session fact ", count: 20))
        let middleUser = entry("anchor-02", role: .user, source: .userMessage, content: String(repeating: "Anchor-02 archived session fact ", count: 20))
        let recentUser = entry("anchor-03", role: .user, source: .userMessage, content: String(repeating: "Anchor-03 recent session fact ", count: 20))
        let entries = [
            entry("constraint", role: .system, source: .system, content: "active operational constraint"),
            oldUser,
            middleUser,
            recentUser,
            entry("project", role: .system, source: .projectPage, content: String(repeating: "reconstructible project context ", count: 20)),
            entry("current", role: .user, source: .userMessage, content: "current question"),
        ]
        let budget = ContextBudget(hardInputLimit: 2_000, preferredActiveTokens: 300, highWaterTokens: 300, lowWaterTokens: 300, reservedOutputTokens: 0, protocolOverheadTokens: 0, toolSchemaTokens: 0, safetyMarginTokens: 0)

        let result = try await compactor.compact(sessionID: sessionID, entries: entries, budget: budget, trigger: .manual)
        let states = await compactor.unitStates(sessionID: sessionID)
        let oldState = try #require(states.first { $0.messageID == oldUser.messageID })

        #expect(entries.contains(oldUser))
        #expect(result.entries.contains { $0.messageID == recentUser.messageID })
        #expect(result.entries.contains { $0.messageID == MessageID("current") })
        #expect(result.entries.contains { $0.messageID == MessageID("constraint") })
        #expect(!result.entries.contains { $0.messageID == oldUser.messageID })
        #expect(!result.entries.contains { $0.messageID == MessageID("project") })
        #expect(oldState.residency == .derived)
        // 移出记录指向 E-Core 引用，不再是 DerivedContextStore 页面 id。
        let referenceID = try #require(oldState.derivedPageID)
        #expect(referenceID.hasPrefix("ref_"))

        let references = await compactor.ecoreStore.references(sessionID: sessionID)
        #expect(references.contains { $0.referenceID == referenceID && $0.summary.contains("Anchor-01") })

        let rehydrated = await compactor.pageIn(sessionID: sessionID, query: "Anchor-01", remainingTokens: 10_000)
        let snapshot = await PCoreContextEngine().snapshot(for: Session(id: sessionID, createdAt: .now), activeEntries: result.entries + rehydrated, estimatedTokens: result.afterTokens + estimator.estimate(entries: rehydrated))

        #expect(rehydrated.contains { ContextCompactor.content(of: $0.part).contains("Anchor-01") })
        #expect(snapshot.entries.contains { $0.source == .derivedPage && ContextCompactor.content(of: $0.part).contains("Anchor-01") })
        // Exact Restore：不经过检索，直接按 referenceID 取回同一份完整载荷。
        let exact = await compactor.pageIn(sessionID: sessionID, referenceID: referenceID, remainingTokens: 10_000)
        #expect(exact.count == 1)
        #expect(ContextCompactor.content(of: try #require(exact.first).part).contains(String(repeating: "Anchor-01 archived session fact ", count: 20)))
        // 新的 page-out 不写 DerivedContextStore（契约第八节：禁止两套 store 并行写入）。
        #expect(await compactor.derivedStore.pages(sessionID: sessionID).isEmpty)
    }

    /// P-Core 只留轻量索引：referenceID + summary，绝不内联已 page-out 的完整载荷（契约第一节）。
    @Test func eCoreIndexProjectionCarriesReferenceButNotPayload() async throws {
        let sessionID = SessionID("index-projection")
        let compactor = ContextCompactor()
        let payload = String(repeating: "delta archived payload ", count: 24)
        let entries = [
            entry("old", role: .assistant, source: .assistantMessage, content: payload),
            entry("current", role: .user, source: .userMessage, content: "current question"),
        ]

        let result = try await compactor.compact(sessionID: sessionID, entries: entries, budget: indexBudget, trigger: .manual)
        let projection = try #require(result.entries.first { $0.messageID == ContextCompactor.eCoreIndexMessageID })
        let text = ContextCompactor.content(of: projection.part)
        let reference = try #require(await compactor.ecoreStore.references(sessionID: sessionID).first)

        #expect(!result.entries.contains { $0.messageID == MessageID("old") })
        #expect(text.contains(reference.referenceID))
        #expect(text.contains("delta"))
        #expect(!text.contains(payload))

        // 连续两轮压缩不会让索引投影累积成两份：投影每轮整体重建。
        let second = try await compactor.compact(sessionID: sessionID, entries: result.entries, budget: indexBudget, trigger: .manual, evictionEpoch: 1)
        #expect(second.entries.count { $0.messageID == ContextCompactor.eCoreIndexMessageID } == 1)
    }

    /// Legacy Read Fallback：迁移前落在 DerivedContextStore 的旧页面仍可召回，只是不再承接新写入。
    @Test func legacyDerivedPagesStayReadableAfterConvergence() async throws {
        let sessionID = SessionID("legacy-fallback")
        let compactor = ContextCompactor()
        let legacyContent = "legacy migrated page about quasars"
        await seedLegacyPage(compactor.derivedStore, sessionID: sessionID, content: legacyContent)

        let rehydrated = await compactor.pageIn(sessionID: sessionID, query: "quasars", remainingTokens: 10_000)
        #expect(rehydrated.contains { ContextCompactor.content(of: $0.part).contains(legacyContent) })
    }

    private func seedLegacyPage(_ store: DerivedContextStore, sessionID: SessionID, content: String) async {
        try? await store.insertLegacyPage(DerivedContextPage(sessionID: sessionID, sourceKind: .user, content: content, messageID: nil, tokenEstimate: 10))
    }

    @Test func projectBackedToolResultDoesNotCreateDerivedCopy() async throws {
        let source = String(repeating: "project-backed result ", count: 24)
        var entries = compactableEntries(source, "other archived context")
        entries[0] = entry("old-1", role: .tool, source: .toolResult, content: source)
        let compactor = ContextCompactor()
        let result = try await compactor.compact(
            sessionID: SessionID("project-backed"),
            entries: entries,
            budget: compactionBudget,
            projectBackedContents: [source]
        )

        #expect(result.pagedOut > 0)
        #expect(result.derivedCreated == 1)
        #expect(await compactor.pageIn(sessionID: SessionID("project-backed"), query: "project-backed", remainingTokens: 10_000).isEmpty)
    }

    @Test func hardInputLimitFailsBeforeProviderIsCalled() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFakeProvider(script: [[.textDelta("unexpected"), .completed(.stop)]])
        let host = try CoreHost(
            providerAssembly: ModelRuntimeAssembly(
                provider: provider,
                modelID: ModelID("fake-model"),
                contextProfile: ModelContextProfile(contextWindowTokens: 4_500)
            ),
            workspaceRoot: try WorkspaceRoot(path: root.path)
        )
        await host.start()
        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()

        let stream = try await client.sendMessage(sessionID: sessionID, content: "must not reach provider")
        do {
            for try await _ in stream {}
            Issue.record("超预算请求必须终止数据流")
        } catch let error as CoreError {
            #expect(error.code == .contextBudgetExceeded)
        }

        #expect(provider.recorder.requests.isEmpty)
        #expect((try await client.session(sessionID)).messages.map(\.role) == [.user])
    }

    @Test func protocolValidatorRejectsOrphanToolResult() throws {
        let result = ToolResult(callID: ToolCallID("orphan"), success: true, content: "orphan")
        #expect(throws: CoreError.self) {
            try ModelRequestProtocolValidator.validate([ContextEntry(messageID: MessageID("tool"), role: .tool, source: .toolResult, part: .toolResult(result))])
        }
    }

    @Test func protocolValidatorRejectsEveryMalformedToolShapeAndAcceptsParallelBatch() throws {
        let assistantID = MessageID("assistant")
        let toolID = MessageID("tool")
        let first = ToolCall(callID: ToolCallID("first"), toolID: ToolID("read_file"), arguments: "{}")
        let second = ToolCall(callID: ToolCallID("second"), toolID: ToolID("read_file"), arguments: "{}")
        let result = ToolResult(callID: first.callID, success: true, content: "ok")
        let secondResult = ToolResult(callID: second.callID, success: true, content: "ok")
        let valid = [
            ContextEntry(messageID: assistantID, role: .assistant, source: .toolCall, part: .toolCall(first)),
            ContextEntry(messageID: assistantID, role: .assistant, source: .toolCall, part: .toolCall(second)),
            ContextEntry(messageID: toolID, role: .tool, source: .toolResult, part: .toolResult(result)),
            ContextEntry(messageID: toolID, role: .tool, source: .toolResult, part: .toolResult(secondResult)),
        ]
        try ModelRequestProtocolValidator.validate(valid)
        #expect(throws: CoreError.self) { try ModelRequestProtocolValidator.validate(Array(valid.dropLast())) }
        #expect(throws: CoreError.self) { try ModelRequestProtocolValidator.validate(valid + [valid[2]]) }
        #expect(throws: CoreError.self) { try ModelRequestProtocolValidator.validate([ContextEntry(messageID: toolID, role: .tool, source: .toolResult, part: .toolResult(ToolResult(callID: ToolCallID("unknown"), success: true, content: "x")))]) }
        #expect(throws: CoreError.self) { try ModelRequestProtocolValidator.validate([valid[0], valid[2], valid[1]]) }
    }

    @Test func manualCompactUsesClientKeepsCanonicalAndRehydratesSessionOnlyFact() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFakeProvider(script: [
            [.textDelta("ack"), .completed(.stop)],
            [.textDelta("ack"), .completed(.stop)],
            [.textDelta("ack"), .completed(.stop)],
            [.textDelta("ack"), .completed(.stop)],
            [.toolCallStarted(callID: ToolCallID("load-context-search"), toolID: ToolID("load_tool")), .toolCallDelta(callID: ToolCallID("load-context-search"), arguments: "{\"tool_id\":\"context_search\"}"), .toolCallCompleted(ToolCall(callID: ToolCallID("load-context-search"), toolID: ToolID("load_tool"), arguments: "{\"tool_id\":\"context_search\"}")), .completed(.toolCalls)],
            [.reasoningDelta("need context"), .toolCallStarted(callID: ToolCallID("call-1"), toolID: ToolID("context_search")), .toolCallDelta(callID: ToolCallID("call-1"), arguments: "{\"query\":\"FoxAnchor-A\"}"), .toolCallCompleted(ToolCall(callID: ToolCallID("call-1"), toolID: ToolID("context_search"), arguments: "{\"query\":\"FoxAnchor-A\"}")), .completed(.toolCalls)],
            [.textDelta("FoxAnchor-A"), .completed(.stop)]
        ])
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake"), contextProfile: ModelContextProfile(contextWindowTokens: 18_000)), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        for index in 0..<4 {
            let anchor = index == 0 ? " FoxAnchor-A" : ""
            let stream = try await client.sendMessage(sessionID: sessionID, content: String(repeating: "large session evidence\(anchor) ", count: 240))
            for try await _ in stream {}
        }
        let canonical = try await client.session(sessionID)
        let markerMessageID = try #require(canonical.messages.first?.id)
        let referencesBefore = await host.ecoreStoreRef.references(sessionID: sessionID)
        let result = try await client.compact(sessionID)
        #expect(result.triggerSource == "manual")
        #expect(result.noEligibleReduction)
        #expect(await host.ecoreStoreRef.references(sessionID: sessionID) == referencesBefore)
        #expect(try await client.session(sessionID) == canonical)
        let compactedContext = try #require(await client.context(sessionID))
        let marker = compactedContext.units.first { $0.messageID == markerMessageID }
        #expect(marker?.residency == .derived)
        // P → E 收敛后，移出记录指向 E-Core 引用而不是 DerivedContextStore 页面 id。
        #expect(marker?.derivedPageID?.hasPrefix("ref_") == true)
        let stream = try await client.sendMessage(sessionID: sessionID, content: "What is FoxAnchor-A?")
        for try await _ in stream {}
        let context = try #require(await client.context(sessionID))
        #expect(context.sourceCounts["derivedPage", default: 0] > 0)
        // 召回命中 E-Core page-out 引用并 Exact Restore 取回载荷，才会出现这一段；
        // 旧的 RecallCache/ProjectIndex 计数器不再承接新写入，因此不能用它们证明召回发生。
        let reloaded = try await client.session(sessionID)
        let recalled = reloaded.messages.flatMap { message in
            message.parts.compactMap { part in if case let .toolResult(result) = part { result.content } else { nil } }
        }.joined(separator: "\n")
        #expect(recalled.contains("E-Core Paged-Out Context"))
        #expect(recalled.contains("FoxAnchor-A"))
        await host.shutdown()
    }

    @Test func smallSessionCompactIsSafeNoOp() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFakeProvider(script: [[.textDelta("ok"), .completed(.stop)]])
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path))
        await host.start()
        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "small")
        for try await _ in stream {}
        let before = try await client.session(sessionID)
        let result = try await client.compact(sessionID)
        #expect(result.noEligibleReduction)
        #expect(try await client.session(sessionID) == before)
        await host.shutdown()
    }

    @Test func eightStepToolLoopPagesHistoricalBatchesWithoutBreakingLiveProtocol() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Paging only happens once the accumulated loop overflows the model input window, and that
        // window shrinks with however many tool schemas the host registered, so the per-batch payload
        // has to clear the limit by a wide margin for the premise to hold on any runner.
        //
        // Phase 8 sizing note (ContextCompactionTests baseline red until here): the window is 12K and
        // the default registry's schemas now cost ~2.9K of it, so hardInputLimit is 4532 while the
        // system prompt plus the live user turn cost ~1.5K. The 3-call step of this fixture is a
        // mandatory unit - a tool batch the model has not consumed yet cannot be evicted - and at
        // 3.6KB per result it alone came to 5074 tokens. Core was refusing a request that no eviction
        // could have satisfied, which is the correct answer to an impossible budget, not a P/E bug.
        // The fixture therefore keeps its shape (7 steps, several calls per step, 11 reads) and
        // shrinks each result to ~1KB: the accumulated loop still overflows the window and gets
        // paged, while no single live batch is larger than the window can hold.
        try String(repeating: "evidence ", count: 120).write(to: root.appending(path: "evidence.txt"), atomically: false, encoding: .utf8)
        let counts = [2, 1, 3, 1, 2, 1, 1]
        var sequence = 0
        let script = counts.map { count -> [ModelEvent] in
            let calls = (0..<count).map { _ -> ToolCall in
                sequence += 1
                return ToolCall(callID: ToolCallID("call-\(sequence)"), toolID: ToolID("read_file"), arguments: #"{"path":"evidence.txt"}"#)
            }
            return calls.map(ModelEvent.toolCallCompleted) + [.completed(.toolCalls)]
        } + [[.textDelta("finished"), .completed(.stop)]]
        let provider = ScriptedFakeProvider(script: script)
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake"), contextProfile: ModelContextProfile(contextWindowTokens: 12_000)), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "analyze tool evidence")
        for try await _ in stream {}
        #expect(provider.recorder.requests.count == 8)
        let lastRequest = try #require(provider.recorder.requests.last)
        let toolMessages = lastRequest.messages.filter { $0.role == .tool }
        let callMessages = lastRequest.messages.filter { $0.role == .assistant && $0.parts.contains { if case .toolCall = $0 { true } else { false } } }
        #expect(toolMessages.count < counts.count)
        #expect(toolMessages.count == callMessages.count)
        #expect((try await client.session(sessionID)).messages.count == 16)
        // 批次证据整体移出 P-Core：模型可见的只剩 E-Core 索引里的 reference，完整载荷不再内联。
        let prompt = lastRequest.messages.map(\.content).joined(separator: "\n")
        #expect(prompt.contains("[E-Core index]"))
        #expect(prompt.contains("origin=toolCall"))
        #expect(!prompt.contains("[Historical tool evidence]"))
        await host.shutdown()
    }
}
