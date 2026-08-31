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
        ContextBudget(hardInputLimit: 300, preferredActiveTokens: 60, highWaterTokens: 60, lowWaterTokens: 30, reservedOutputTokens: 0, fixedOverheadTokens: 0, safetyMarginTokens: 0)
    }

    @Test func budgetPlannerReservesTheLargestRequestedOutputAndToolSchema() {
        let planner = ContextBudgetPlanner(policy: ContextBudgetPolicy(preferredRatio: 0.5, defaultActiveCeiling: 1_000, safetyMarginTokens: 50, fixedOverheadTokens: 100))
        let profile = ModelContextProfile(contextWindowTokens: 1_000, maxOutputTokens: 200, recommendedOutputReserveTokens: 300)

        let recommended = planner.plan(profile: profile, toolTokens: 100)
        let requested = planner.plan(profile: profile, requestedMaxOutputTokens: 400, toolTokens: 100)

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

    @Test func rehydrationFlowsThroughL1Snapshot() async throws {
        let sessionID = SessionID("rehydration")
        let compactor = ContextCompactor()
        let compacted = try await compactor.compact(sessionID: sessionID, entries: compactableEntries(), budget: compactionBudget)
        let rehydrated = await compactor.pageIn(sessionID: sessionID, query: "alpha", remainingTokens: 10_000)
        let session = Session(id: sessionID, createdAt: Date())
        let snapshot = await L1ContextEngine().snapshot(for: session, activeEntries: compacted.entries + rehydrated, estimatedTokens: compacted.afterTokens + estimator.estimate(entries: rehydrated))

        #expect(compacted.pagedOut > 0)
        #expect(snapshot.metrics.derivedPageCount == rehydrated.count)
        #expect(snapshot.modelMessages().contains { $0.content.contains("[Session context]") })
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
        let budget = ContextBudget(hardInputLimit: 2_000, preferredActiveTokens: 300, highWaterTokens: 300, lowWaterTokens: 300, reservedOutputTokens: 0, fixedOverheadTokens: 0, safetyMarginTokens: 0)

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
        #expect(oldState.derivedPageID != nil)

        let exactPage = await compactor.derivedStore.search(sessionID: sessionID, query: "What is Anchor-01?", limit: 1)
        let rehydrated = await compactor.pageIn(sessionID: sessionID, query: "Anchor-01", remainingTokens: 10_000)
        let snapshot = await L1ContextEngine().snapshot(for: Session(id: sessionID, createdAt: .now), activeEntries: result.entries + rehydrated, estimatedTokens: result.afterTokens + estimator.estimate(entries: rehydrated))
        let metrics = await compactor.cacheMetrics(sessionID: sessionID)

        #expect(exactPage.first?.content.contains("Anchor-01") == true)
        #expect(rehydrated.contains { ContextCompactor.content(of: $0.part).contains("Anchor-01") })
        #expect(snapshot.entries.contains { $0.source == .derivedPage && ContextCompactor.content(of: $0.part).contains("Anchor-01") })
        #expect(metrics.l3Hits > 0)
        #expect(metrics.l2Promotions > 0)
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
        let provider = ScriptedFakeProvider(script: [[.textDelta("ack"), .completed(.stop)]])
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake"), contextProfile: ModelContextProfile(contextWindowTokens: 10_000)), workspaceRoot: try WorkspaceRoot(path: root.path))
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        for index in 0..<4 {
            let anchor = index == 0 ? " FoxAnchor-A" : ""
            let stream = try await client.sendMessage(sessionID: sessionID, content: String(repeating: "large session evidence\(anchor) ", count: 300))
            for try await _ in stream {}
        }
        let canonical = try await client.session(sessionID)
        let markerMessageID = try #require(canonical.messages.first?.id)
        let result = try await client.compact(sessionID)
        #expect(result.triggerSource == "manual")
        #expect(result.beforeEstimatedTokens > result.afterEstimatedTokens)
        #expect(result.derivedPagesCreated > 0)
        #expect(try await client.session(sessionID) == canonical)
        let compactedContext = try #require(await client.context(sessionID))
        let marker = compactedContext.units.first { $0.messageID == markerMessageID }
        #expect(marker?.residency == .derived)
        #expect(marker?.derivedPageID != nil)
        let cacheBefore = try await client.projectCache()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "What is FoxAnchor-A?")
        for try await _ in stream {}
        let context = try #require(await client.context(sessionID))
        #expect(context.sourceCounts["derivedPage", default: 0] > 0)
        let cache = try await client.projectCache()
        #expect(cache.derivedL3Pages > 0)
        #expect(cache.derivedL3Hits > cacheBefore.derivedL3Hits)
        #expect(cache.sessionL2DerivedPromotions > cacheBefore.sessionL2DerivedPromotions)
        #expect(cache.derivedPageInCount > cacheBefore.derivedPageInCount)
    }

    @Test func smallSessionCompactIsSafeNoOp() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFakeProvider(script: [[.textDelta("ok"), .completed(.stop)]])
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake")), workspaceRoot: try WorkspaceRoot(path: root.path))
        await host.start()
        defer { Task { await host.shutdown() } }
        let client = LingXiClient.inProcess(endpoint: host)
        let sessionID = try await client.createSession()
        let stream = try await client.sendMessage(sessionID: sessionID, content: "small")
        for try await _ in stream {}
        let before = try await client.session(sessionID)
        let result = try await client.compact(sessionID)
        #expect(result.noEligibleReduction)
        #expect(try await client.session(sessionID) == before)
    }

    @Test func eightStepToolLoopPagesHistoricalBatchesWithoutBreakingLiveProtocol() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try String(repeating: "evidence ", count: 200).write(to: root.appending(path: "evidence.txt"), atomically: true, encoding: .utf8)
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
        let host = try CoreHost(providerAssembly: ModelRuntimeAssembly(provider: provider, modelID: ModelID("fake"), contextProfile: ModelContextProfile(contextWindowTokens: 10_000)), workspaceRoot: try WorkspaceRoot(path: root.path), permissionDecision: .allow)
        await host.start()
        defer { Task { await host.shutdown() } }
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
        let cache = try await client.projectCache()
        #expect(cache.historicalToolEvidencePages > 0)
    }
}
