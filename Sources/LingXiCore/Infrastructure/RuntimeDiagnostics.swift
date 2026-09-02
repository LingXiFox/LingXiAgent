import Foundation
import LingXiProtocol

public actor RuntimeDiagnosticsStore {
    private let limit: Int
    private var events: [RuntimeTraceEvent] = []

    public init(limit: Int = 4_000) {
        self.limit = max(100, limit)
    }

    public func record(
        kind: RuntimeTraceKind,
        event: String,
        sessionID: SessionID? = nil,
        runID: AgentRunID? = nil,
        rootRunID: AgentRunID? = nil,
        parentRunID: AgentRunID? = nil,
        workflowID: WorkflowID? = nil,
        taskID: WorkflowTaskID? = nil,
        executionID: String? = nil,
        providerRequestID: String? = nil,
        toolCallID: ToolCallID? = nil,
        metadata: [String: String] = [:],
        errorCode: String? = nil
    ) {
        let item = RuntimeTraceEvent(
            kind: kind,
            event: event,
            sessionID: sessionID,
            runID: runID,
            rootRunID: rootRunID,
            parentRunID: parentRunID,
            workflowID: workflowID,
            taskID: taskID,
            executionID: executionID,
            providerRequestID: providerRequestID,
            toolCallID: toolCallID,
            metadata: Self.sanitize(metadata),
            errorCode: errorCode
        )
        events.append(item)
        if events.count > limit { events.removeFirst(events.count - limit) }
    }

    public func snapshot() -> [RuntimeTraceEvent] { events }

    public func recentErrors(limit: Int = 100) -> [RuntimeTraceEvent] {
        Array(events.reversed().filter { $0.errorCode != nil || $0.kind == .error }.prefix(max(1, limit)))
    }

    private static func sanitize(_ values: [String: String]) -> [String: String] {
        values.reduce(into: [:]) { result, item in
            let key = item.key
            let lower = key.lowercased()
            if ["secret", "credential", "authorization", "api_key", "apikey", "token", "password", "cookie", "env", "header", "request_body", "response_body", "content", "arguments"].contains(where: lower.contains) {
                result[key] = "[redacted]"
            } else {
                result[key] = item.value.replacingOccurrences(of: "Bearer \\S+", with: "Bearer [redacted]", options: .regularExpression)
            }
        }
    }
}
