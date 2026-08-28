import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

struct ContextProfilerTests {
    private func message(_ id: String, _ role: MessageRole, _ parts: [SessionMessagePart]) -> Message {
        Message(id: MessageID(id), role: role, parts: parts, createdAt: Date())
    }

    @Test func l1SnapshotKeepsSystemOrderStructureAndRevision() async {
        var session = Session(id: SessionID("a"), createdAt: Date())
        let call = ToolCall(callID: ToolCallID("c"), toolID: ToolID("read_file"), arguments: #"{"path":"README.md"}"#)
        session.append(message("u", .user, [.text("hello")]))
        session.append(message("a", .assistant, [.toolCall(call)]))
        session.append(message("t", .tool, [.toolResult(ToolResult(callID: call.callID, success: true, content: "LingXiAgent"))]))
        let engine = L1ContextEngine(policy: L1ContextPolicy(systemContext: "system"))
        let first = await engine.snapshot(for: session)
        session.append(message("final", .assistant, [.text("answer")]))
        let second = await engine.snapshot(for: session)

        #expect(first.revision == 1)
        #expect(second.revision == 2)
        #expect(first.metrics.messageCount == 4)
        #expect(first.metrics.sourceCounts[.toolCall] == 1)
        #expect(first.metrics.sourceCounts[.toolResult] == 1)
        #expect(first.modelMessages().map(\.role) == [.system, .user, .assistant, .tool])
        #expect(first.modelMessages()[2].parts == [.toolCall(call)])
        #expect(first.modelMessages()[3].parts == [.toolResult(ToolResult(callID: call.callID, success: true, content: "LingXiAgent"))])
        #expect(second.modelMessages().last?.content == "answer")
    }

    @Test func l1RevisionsAreSessionIsolated() async {
        let engine = L1ContextEngine()
        let a = Session(id: SessionID("a"), createdAt: Date())
        let b = Session(id: SessionID("b"), createdAt: Date())
        #expect(await engine.snapshot(for: a).revision == 1)
        #expect(await engine.snapshot(for: b).revision == 1)
        #expect(await engine.snapshot(for: a).revision == 2)
    }

    @Test func contextQueryKeepsOnlyCurrentAndTwoRecentUserMessages() {
        let query = ContextQuery(currentTask: "current", recentUserMessages: ["old-1", "old-2", "recent-1", "recent-2"])
        #expect(query.text == "current\nrecent-1\nrecent-2")
        #expect(query.terms.contains("current"))
        #expect(!query.text.contains("old-1"))
    }

    @Test func l1AddsProjectPagesAsSystemContextWithoutToolDuplicate() async {
        var session = Session(id: SessionID("a"), createdAt: Date())
        session.append(message("u", .user, [.text("explain")]))
        session.append(message("t", .tool, [.toolResult(ToolResult(callID: ToolCallID("c"), success: true, content: "already read"))]))
        let page = ContextPage(projectRoot: "/project", path: "Sources/Tool.swift", startLine: 1, endLine: 1, content: "project context")
        let duplicate = ContextPage(projectRoot: "/project", path: "README.md", startLine: 1, endLine: 1, content: "already read")
        let snapshot = await L1ContextEngine().snapshot(for: session, projectPages: [page, page, duplicate])
        #expect(snapshot.metrics.projectPageCount == 1)
        #expect(snapshot.metrics.projectCharacterCount == page.characterCount)
        #expect(snapshot.entries.last?.source == .projectPage)
        #expect(snapshot.modelMessages().last?.role == .system)
    }

    @Test func profilerDisabledIsNoOpAndEnabledRecordsDMA() {
        let disabled = TurnProfiler(sessionID: SessionID("s"), enabled: false)
        disabled.recordText("ignored", streamElapsed: .zero)
        #expect(disabled.report() == nil)

        let enabled = TurnProfiler(sessionID: SessionID("s"), enabled: true)
        enabled.recordText("abc", streamElapsed: .zero)
        enabled.recordReasoning("think", streamElapsed: .zero)
        enabled.recordUsage(ModelUsage(outputTokens: 2))
        let outcome = ToolRuntime.ExecutionOutcome(
            result: ToolResult(callID: ToolCallID("c"), success: true, content: "file"),
            permissionWait: .zero,
            execution: .zero,
            toolName: "read_file",
            resource: nil
        )
        enabled.recordTool(outcome)
        let report = enabled.report()
        #expect(report?.textChunks == 1)
        #expect(report?.reasoningChunks == 1)
        #expect(report?.textCharacters == 3)
        #expect(report?.tools.first?.permissionWaitMilliseconds == 0)
        #expect(report?.tools.first?.executionMilliseconds == 0)
        #expect(report?.usage?.outputTokens == 2)
        #expect(report?.outputTokensPerSecond == nil, "没有可靠 stream duration 时不伪造 token/s")
    }
}
