import Foundation
import LingXiProtocol

/// 工具执行阶段。
public enum ToolExecutionPhase: String, Sendable, Equatable {
    case requested
    case waitingPermission
    case scheduled
    case running
    case completed
    case failed
    case cancelled
}

/// 工具执行节点。
/// 契约：同一个 ToolCallID 聚合成一个单一 ToolNode。
/// ToolCall 与 ToolResult 绝不拆分为两个独立产品节点。
public struct ToolNode: Sendable, Equatable {
    public let callID: ToolCallID
    public var toolName: String
    public var argumentsJSON: String
    public var phase: ToolExecutionPhase
    public var permissionID: PermissionID?
    public var stdout: String
    public var stderr: String
    public var result: ToolResultSnapshot?
    public var error: RuntimeError?
    public var modelStepID: ModelStepID?
    public var requestedAt: Date?
    public var admittedAt: Date?
    public var executorStartedAt: Date?
    public var executorFinishedAt: Date?
    public var resultCommittedAt: Date?
    public var projectionReceivedAt: Date?

    public var executionDuration: Duration? {
        if let execMs = result?.timing.executionMilliseconds, execMs >= 0 {
            return .milliseconds(execMs)
        }
        if let start = executorStartedAt, let finish = executorFinishedAt {
            let seconds = finish.timeIntervalSince(start)
            return .milliseconds(max(0, seconds * 1000.0))
        }
        return nil
    }

    public init(
        callID: ToolCallID,
        toolName: String,
        argumentsJSON: String = "{}",
        phase: ToolExecutionPhase = .requested,
        permissionID: PermissionID? = nil,
        stdout: String = "",
        stderr: String = "",
        result: ToolResultSnapshot? = nil,
        error: RuntimeError? = nil,
        modelStepID: ModelStepID? = nil,
        requestedAt: Date? = nil,
        admittedAt: Date? = nil,
        executorStartedAt: Date? = nil,
        executorFinishedAt: Date? = nil,
        resultCommittedAt: Date? = nil,
        projectionReceivedAt: Date? = nil
    ) {
        self.callID = callID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.phase = phase
        self.permissionID = permissionID
        self.stdout = stdout
        self.stderr = stderr
        self.result = result
        self.error = error
        self.modelStepID = modelStepID
        self.requestedAt = requestedAt
        self.admittedAt = admittedAt
        self.executorStartedAt = executorStartedAt
        self.executorFinishedAt = executorFinishedAt
        self.resultCommittedAt = resultCommittedAt
        self.projectionReceivedAt = projectionReceivedAt
    }

    public var argumentSummary: String {
        Self.summarizeArguments(argumentsJSON, toolName: toolName)
    }

    public static func summarizeArguments(_ argumentsJSON: String, toolName: String? = nil) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "unavailable"
        }
        let lowerName = toolName?.lowercased() ?? ""
        if lowerName.contains("write") || lowerName.contains("create") || lowerName.contains("edit") {
            var parts: [String] = []
            if let path = object["path"] as? String {
                parts.append("path=\(path)")
            }
            if let content = object["content"] as? String {
                parts.append("bytes=\(content.utf8.count)")
            }
            if !parts.isEmpty {
                return parts.joined(separator: " ")
            }
        }
        let preferredKeys = ["command", "cmd", "path", "pattern", "query", "url"]
        let keys = preferredKeys.filter { object[$0] != nil } + object.keys.filter { !preferredKeys.contains($0) && $0 != "content" }.sorted()
        let summary = keys.compactMap { key -> String? in
            guard let value = object[key] else { return nil }
            if let string = value as? String { return "\(key)=\(string)" }
            if let number = value as? NSNumber { return "\(key)=\(number)" }
            return "\(key)=…"
        }.joined(separator: " ")
        return String((summary.isEmpty ? "{}" : summary).prefix(120))
    }

    public static func formatDuration(_ duration: Duration) -> String {
        let components = duration.components
        let totalSeconds = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        if totalSeconds < 1.0 {
            let ms = max(0, Int(round(totalSeconds * 1000)))
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", totalSeconds)
        }
    }
}
