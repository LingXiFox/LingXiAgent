import Foundation
import LingXiKernel
import Testing

private func entry(_ id: String, _ segment: ContextSegment, _ text: String, unit: String? = nil) -> ContextEntry {
    ContextEntry(id: EntryID(id), segment: segment, role: segment.isPrivileged ? .system : .user, payload: .text(text), unit: unit)
}

private let filler = String(repeating: "x", count: 160)

@Test("CTX-001 only immutable instructions may hold the instruction channel")
func CTX_001_privilegedChannelIsUnique() throws {
    let instructions = entry("i", .immutableInstructions, "system")
    try ContextRequestValidator.validate([instructions, entry("h", .history, "data")], placement: .anywhereInHistory)

    #expect(throws: ContextValidationError.privilegedEntryNotFirst(index: 1)) {
        try ContextRequestValidator.validate([entry("h", .history, "data"), instructions], placement: .anywhereInHistory)
    }
    #expect(ContextSegment.history.isPrivileged == false)
    #expect(ContextSegment.derivedPage.isPrivileged == false)
    #expect(ContextSegment.currentUser.isPrivileged == false)
}

@Test("CTX-014 orphan, unconsumed and duplicate tool entries never reach a provider")
func CTX_014_requestProtocolValidation() {
    let instructions = entry("i", .immutableInstructions, "system")
    let call = makeCall("c1")
    let outcome = ToolOutcome(callID: ToolCallID("c1"), content: "ok", isError: false, effect: .readOnly)

    let orphan = ContextEntry(id: "r", segment: .history, role: .tool, payload: .toolResult(outcomes: [outcome]))
    #expect(throws: ContextValidationError.orphanToolResult(ToolCallID("c1"))) {
        try ContextRequestValidator.validate([instructions, orphan], placement: .anywhereInHistory)
    }

    let dangling = ContextEntry(id: "c", segment: .history, role: .assistant, payload: .toolCall(requests: [call]))
    #expect(throws: ContextValidationError.unconsumedToolCall(ToolCallID("c1"))) {
        try ContextRequestValidator.validate([instructions, dangling], placement: .anywhereInHistory)
    }

    let duplicated = ContextEntry(
        id: "c",
        segment: .history,
        role: .assistant,
        payload: .toolCall(requests: [call, makeCall("c1")])
    )
    #expect(throws: ContextValidationError.duplicateToolCallID(ToolCallID("c1"))) {
        try ContextRequestValidator.validate([instructions, duplicated], placement: .anywhereInHistory)
    }
}

@Test("CTX-006 a provider that needs results right after the call rejects a gap")
func CTX_006_adjacencyRequirement() {
    let call = makeCall("c1")
    let outcome = ToolOutcome(callID: ToolCallID("c1"), content: "ok", isError: false, effect: .readOnly)
    let callEntry = ContextEntry(id: "c", segment: .history, role: .assistant, payload: .toolCall(requests: [call]), unit: "b1")
    let resultEntry = ContextEntry(id: "r", segment: .history, role: .tool, payload: .toolResult(outcomes: [outcome]), unit: "b1")
    let between = entry("x", .history, "inserted")

    try! ContextRequestValidator.validate(
        [entry("i", .immutableInstructions, "sys"), callEntry, resultEntry],
        placement: .immediatelyAfterCall
    )
    #expect(throws: ContextValidationError.toolResultNotAdjacent(ToolCallID("c1"))) {
        try ContextRequestValidator.validate(
            [entry("i", .immutableInstructions, "sys"), callEntry, between, resultEntry],
            placement: .immediatelyAfterCall
        )
    }
}

@Test("CTX-008 eviction stops at the low water mark instead of compressing further")
func CTX_008_waterMarks() throws {
    var entries = [entry("i", .immutableInstructions, "sys"), entry("u", .currentUser, "now")]
    entries.append(contentsOf: (0..<5).map { entry("h\($0)", .history, filler) })

    let plan = try ContextBudgetPlanner().plan(entries, limits: BudgetLimits(preferredTokens: 100, hardTokens: 400))

    #expect(plan.evicted.count == 4)
    #expect(plan.evicted.map(\.id.rawValue) == ["h0", "h1", "h2", "h3"])
    #expect(plan.selected.contains { $0.id.rawValue == "h4" })
    #expect(plan.selected.contains { $0.segment == .derivedPage })
    #expect(plan.lowWaterTokens == 80)
    #expect(plan.highWaterTokens == 115)
}

@Test("CTX-008 a mandatory floor above the hard limit is an error, not silent truncation")
func CTX_008_mandatoryFloor() {
    let huge = entry("i", .immutableInstructions, String(repeating: "y", count: 4_000))
    #expect(throws: BudgetError.mandatoryFloorExceedsHardLimit(pinnedTokens: 1_004, hardTokens: 200)) {
        _ = try ContextBudgetPlanner().plan([huge], limits: BudgetLimits(preferredTokens: 100, hardTokens: 200))
    }
}

@Test("CTX-009 a causal batch leaves the context whole or not at all")
func CTX_009_batchesLeaveTogether() throws {
    let entries = [
        entry("i", .immutableInstructions, "sys"),
        entry("u", .currentUser, "now"),
        ContextEntry(id: "call", segment: .history, role: .assistant, payload: .toolCall(requests: [makeCall("c1")]), unit: "b1"),
        ContextEntry(id: "result", segment: .history, role: .tool, payload: .toolResult(outcomes: [
            ToolOutcome(callID: ToolCallID("c1"), content: String(repeating: filler, count: 8), isError: false, effect: .readOnly),
        ]), unit: "b1"),
    ]

    let plan = try ContextBudgetPlanner().plan(entries, limits: BudgetLimits(preferredTokens: 100, hardTokens: 400))

    #expect(plan.evicted.count == 2)
    try ContextRequestValidator.validate(plan.selected, placement: .immediatelyAfterCall)
}

@Test("CTX-002 the tool manifest is append-only inside an epoch")
func CTX_002_appendOnlyManifest() async throws {
    let registry = ToolRegistry()
    try await registry.register(ToolDescriptor(id: "test/a", name: "a", schemaJSON: "{}", effect: .readOnly))
    try await registry.register(ToolDescriptor(id: "test/b", name: "b", schemaJSON: "{}", effect: .readOnly))

    await #expect(throws: ToolRegistryError.self) {
        try await registry.register(ToolDescriptor(id: "test/a", name: "a", schemaJSON: "{\"v\":2}", effect: .readOnly))
    }

    await registry.advanceEpoch()
    try await registry.register(ToolDescriptor(id: "test/a", name: "a", schemaJSON: "{\"v\":2}", effect: .readOnly))

    let manifest = await registry.manifest()
    #expect(manifest.map(\.name) == ["a", "b"])
    #expect(await registry.epoch == 2)
}

@Test("the kernel keeps the instruction entry at the head of every request")
func assemblyKeepsPrefixStable() async throws {
    let provider = ScriptedProvider(scripts: [completed("done")])
    let loop = await makeLoop(provider: provider, executor: RecordingExecutor(), log: try DurableEventLog(sink: MemorySink()))

    let result = await loop.run(runRequest("prefix"), policy: LoopPolicy())
    let first = try #require(provider.request(at: 0))

    #expect(result.status == .completed)
    #expect(first.entries.first?.segment == .immutableInstructions)
    #expect(first.entries.filter { $0.segment.isPrivileged }.count == 1)
    #expect(first.entries.contains { $0.segment == .currentUser })
}

@Test("CTX-018 non-privileged content must never reach the instruction channel through role system")
func CTX_018_nonPrivilegedSystemRoleRejected() throws {
    let instructions = entry("i", .immutableInstructions, "system")
    let derivedSystem = ContextEntry(id: "d", segment: .derivedPage, role: .system, payload: .text("retrieved"))

    #expect(throws: ContextValidationError.nonPrivilegedSystemRole(index: 1)) {
        try ContextRequestValidator.validate([instructions, derivedSystem], placement: .anywhereInHistory)
    }
}

@Test("CTX-018 the eviction reference is data, fits the hard limit, and is counted in the plan")
func CTX_018_referenceIsCountedAndNonPrivileged() throws {
    let instructions = entry("i", .immutableInstructions, String(repeating: "s", count: 336))
    let currentUser = entry("u", .currentUser, "now")
    let history = entry("h", .history, filler)
    let plan = try ContextBudgetPlanner().plan(
        [instructions, currentUser, history],
        limits: BudgetLimits(preferredTokens: 100, hardTokens: 400)
    )

    let reference = try #require(plan.selected.first { $0.segment == .derivedPage })
    #expect(reference.role == .user)
    #expect(plan.evicted.map(\.id.rawValue) == ["h"])
    let recomputed = plan.selected.reduce(0) { $0 + TokenEstimator().estimate($1) }
    #expect(plan.estimatedTokens == recomputed)
    #expect(plan.estimatedTokens <= 400)
    try ContextRequestValidator.validate(plan.selected, placement: .immediatelyAfterCall)
}

@Test("CTX-018 a reference line that cannot fit under the hard limit fails closed")
func CTX_018_referenceOverHardLimit() {
    let instructions = entry("i", .immutableInstructions, String(repeating: "s", count: 336))
    let currentUser = entry("u", .currentUser, "now")
    let history = entry("h", .history, filler)

    #expect(throws: BudgetError.referenceExceedsHardLimit(estimatedTokens: 108, hardTokens: 100)) {
        _ = try ContextBudgetPlanner().plan(
            [instructions, currentUser, history],
            limits: BudgetLimits(preferredTokens: 100, hardTokens: 100)
        )
    }
}

@Test("CTX-017 only the newest user turn is mandatory; older user turns become history")
func CTX_017_previousUserTurnsAreDemoted() async {
    let store = SessionStore()
    let turn1 = ContextEntry(id: "turn-1", segment: .currentUser, role: .user, payload: .text("first"))
    let assistant1 = ContextEntry(id: "assistant-1", segment: .history, role: .assistant, payload: .text("reply"))
    let turn2 = ContextEntry(id: "turn-2", segment: .currentUser, role: .user, payload: .text("second"))

    await store.append(turn1, to: "s")
    await store.append(assistant1, to: "s")
    await store.append(turn2, to: "s")

    let entries = await store.entries(for: "s")
    #expect(entries.map(\.id.rawValue) == ["turn-1", "assistant-1", "turn-2"])
    #expect(entries.map(\.segment) == [.history, .history, .currentUser])
    #expect(entries.filter { $0.segment.isMandatory }.map(\.id.rawValue) == ["turn-2"])
}

@Test("CTX-018 further evictions forced by the reference line still list every evicted id")
func CTX_018_referenceListsAllEvictedIDs() throws {
    let instructions = entry("i", .immutableInstructions, String(repeating: "i", count: 200))
    let currentUser = entry("u", .currentUser, "now")
    let h0 = entry("h0", .history, String(repeating: "x", count: 208))
    let h1 = entry("h1", .history, "xxxx")
    let h2 = entry("h2", .history, "yyyy")

    let plan = try ContextBudgetPlanner().plan(
        [instructions, currentUser, h0, h1, h2],
        limits: BudgetLimits(preferredTokens: 100, hardTokens: 82)
    )

    let reference = try #require(plan.selected.first { $0.segment == .derivedPage })
    let text = reference.renderedText
    for evicted in plan.evicted {
        #expect(text.contains(evicted.id.rawValue), "reference line must let the model locate \(evicted.id.rawValue)")
    }
    #expect(plan.estimatedTokens == plan.selected.reduce(0) { $0 + TokenEstimator().estimate($1) })
    #expect(plan.estimatedTokens <= 82)
}
