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
    #expect(try await registry.epoch == 2)
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
