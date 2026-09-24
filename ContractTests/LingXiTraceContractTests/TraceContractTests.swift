import Foundation
import Testing
import LingXiProtocol

/// 契约测试：RuntimeTrace 协议与黑盒序列化规范
/// 约束：禁 @testable、禁 import LingXiCore
struct TraceContractTests {

    @Test("RuntimeTraceEvent serialization round-trip retains all mandatory and optional fields")
    func traceEventFullSerialization() throws {
        let event = RuntimeTraceEvent(
            traceID: "trace-full-1",
            timestamp: Date(timeIntervalSince1970: 1700000000),
            kind: .task,
            event: "task.lifecycle.start",
            sessionID: SessionID("sess-1"),
            runID: AgentRunID("run-1"),
            rootRunID: AgentRunID("root-run-1"),
            parentRunID: AgentRunID("parent-run-1"),
            workflowID: WorkflowID("wf-1"),
            workflowTaskID: WorkflowTaskID("wf-task-1"),
            taskID: TaskID("task-1"),
            parentGoalID: "goal-1",
            traceSchemaVersion: 1,
            spanID: "span-1",
            parentSpanID: "span-parent",
            durationMicroseconds: 45000,
            tokens: TraceTokenUsage(inputTokens: 1200, outputTokens: 300, cacheReadTokens: 5000, reasoningTokens: 50),
            attributes: [
                "step": .int(3),
                "ratio": .double(0.85),
                "isTerminal": .bool(false),
                "tool": .string("readFile"),
                "tags": .stringArray(["eval", "p26"])
            ],
            executionID: "exec-1",
            providerRequestID: "req-1",
            toolCallID: ToolCallID("call-1"),
            metadata: ["source": "contract-test"],
            errorCode: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let decoded = try JSONDecoder().decode(RuntimeTraceEvent.self, from: data)

        #expect(decoded.traceID == "trace-full-1")
        #expect(decoded.kind == .task)
        #expect(decoded.event == "task.lifecycle.start")
        #expect(decoded.sessionID == SessionID("sess-1"))
        #expect(decoded.taskID == TaskID("task-1"))
        #expect(decoded.parentGoalID == "goal-1")
        #expect(decoded.traceSchemaVersion == 1)
        #expect(decoded.spanID == "span-1")
        #expect(decoded.parentSpanID == "span-parent")
        #expect(decoded.durationMicroseconds == 45000)
        #expect(decoded.tokens?.inputTokens == 1200)
        #expect(decoded.tokens?.outputTokens == 300)
        #expect(decoded.tokens?.cacheReadTokens == 5000)
        #expect(decoded.tokens?.reasoningTokens == 50)
        #expect(decoded.attributes?["step"] == .int(3))
        #expect(decoded.attributes?["ratio"] == .double(0.85))
        #expect(decoded.attributes?["isTerminal"] == .bool(false))
        #expect(decoded.attributes?["tool"] == .string("readFile"))
        #expect(decoded.attributes?["tags"] == .stringArray(["eval", "p26"]))
        #expect(decoded.toolCallID == ToolCallID("call-1"))
    }

    @Test("RuntimeTraceKind decodes unknown string values to .unknown without throwing")
    func traceKindFaultTolerantDecoding() throws {
        let json = #"{"traceID":"t1","kind":"futureSpecV2Kind","event":"unknown.event"}"#
        let decoded = try JSONDecoder().decode(RuntimeTraceEvent.self, from: json.data(using: .utf8)!)
        #expect(decoded.kind == .unknown)

        // All P26 declared kinds encode and decode accurately
        let p26Kinds: [RuntimeTraceKind] = [.task, .workspace, .capability, .eval, .toolPlan, .actionFlow]
        for k in p26Kinds {
            let data = try JSONEncoder().encode(k)
            let dec = try JSONDecoder().decode(RuntimeTraceKind.self, from: data)
            #expect(dec == k)
        }
    }

    @Test("TraceAttributeValue primitive variants round-trip through JSON")
    func traceAttributeValueCoding() throws {
        let values: [String: TraceAttributeValue] = [
            "text": .string("hello world"),
            "count": .int(42),
            "ratio": .double(3.14159),
            "flag": .bool(true),
            "list": .stringArray(["a", "b", "c"])
        ]

        let data = try JSONEncoder().encode(values)
        let decoded = try JSONDecoder().decode([String: TraceAttributeValue].self, from: data)

        #expect(decoded["text"] == .string("hello world"))
        #expect(decoded["count"] == .int(42))
        #expect(decoded["flag"] == .bool(true))
        #expect(decoded["list"] == .stringArray(["a", "b", "c"]))
    }

    @Test("TraceQueryRequest and Page round-trip serialization")
    func traceQueryRequestAndPage() throws {
        let req = TraceQueryRequest(
            taskID: TaskID("task-query-1"),
            sessionID: SessionID("sess-query-1"),
            kind: .eval,
            fromTimestamp: Date(timeIntervalSince1970: 1000),
            toTimestamp: Date(timeIntervalSince1970: 2000),
            limit: 50,
            cursor: "cur-1"
        )
        let reqData = try JSONEncoder().encode(req)
        let decReq = try JSONDecoder().decode(TraceQueryRequest.self, from: reqData)
        #expect(decReq == req)

        let page = Page(items: [
            RuntimeTraceEvent(kind: .eval, event: "eval.step", taskID: TaskID("task-query-1"))
        ], nextCursor: "next-cur", hasMore: true)
        let pageData = try JSONEncoder().encode(page)
        let decPage = try JSONDecoder().decode(Page<RuntimeTraceEvent>.self, from: pageData)
        #expect(decPage.items.count == 1)
        #expect(decPage.items.first?.taskID == TaskID("task-query-1"))
        #expect(decPage.nextCursor == "next-cur")
        #expect(decPage.hasMore == true)
    }
}
