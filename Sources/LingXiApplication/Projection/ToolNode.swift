import Foundation
import LingXiProtocol

/// 工具执行阶段。
public enum ToolExecutionPhase: String, Sendable, Equatable, Codable {
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
public struct ToolNode: Sendable, Equatable, Codable {
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

    /// Shared front-end classification (see `ToolFamily` in LingXiProtocol).
    /// Derived from `toolName`, so it can never go stale; `toolFamily` is additionally
    /// written into the encoded representation for remote frontends.
    public var toolFamily: ToolFamily {
        // ToolNode carries no capability declaration; classification is name-driven.
        ToolFamily.classify(toolName: toolName, capabilityKind: nil)
    }

    /// `executionDuration` / `toolFamily` are derived; `toolFamily` is still put on the
    /// wire (explicit `encode(to:)` below) while `executionDuration` is not.
    private enum CodingKeys: String, CodingKey {
        case callID, toolName, argumentsJSON, phase, permissionID, stdout, stderr
        case result, error, modelStepID, requestedAt, admittedAt, executorStartedAt
        case executorFinishedAt, resultCommittedAt, projectionReceivedAt, toolFamily
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.callID = try container.decode(ToolCallID.self, forKey: .callID)
        self.toolName = try container.decode(String.self, forKey: .toolName)
        self.argumentsJSON = try container.decode(String.self, forKey: .argumentsJSON)
        self.phase = try container.decode(ToolExecutionPhase.self, forKey: .phase)
        self.permissionID = try container.decodeIfPresent(PermissionID.self, forKey: .permissionID)
        self.stdout = try container.decode(String.self, forKey: .stdout)
        self.stderr = try container.decode(String.self, forKey: .stderr)
        self.result = try container.decodeIfPresent(ToolResultSnapshot.self, forKey: .result)
        self.error = try container.decodeIfPresent(RuntimeError.self, forKey: .error)
        self.modelStepID = try container.decodeIfPresent(ModelStepID.self, forKey: .modelStepID)
        self.requestedAt = try container.decodeIfPresent(Date.self, forKey: .requestedAt)
        self.admittedAt = try container.decodeIfPresent(Date.self, forKey: .admittedAt)
        self.executorStartedAt = try container.decodeIfPresent(Date.self, forKey: .executorStartedAt)
        self.executorFinishedAt = try container.decodeIfPresent(Date.self, forKey: .executorFinishedAt)
        self.resultCommittedAt = try container.decodeIfPresent(Date.self, forKey: .resultCommittedAt)
        self.projectionReceivedAt = try container.decodeIfPresent(Date.self, forKey: .projectionReceivedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(callID, forKey: .callID)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(argumentsJSON, forKey: .argumentsJSON)
        try container.encode(phase, forKey: .phase)
        try container.encodeIfPresent(permissionID, forKey: .permissionID)
        try container.encode(stdout, forKey: .stdout)
        try container.encode(stderr, forKey: .stderr)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(modelStepID, forKey: .modelStepID)
        try container.encodeIfPresent(requestedAt, forKey: .requestedAt)
        try container.encodeIfPresent(admittedAt, forKey: .admittedAt)
        try container.encodeIfPresent(executorStartedAt, forKey: .executorStartedAt)
        try container.encodeIfPresent(executorFinishedAt, forKey: .executorFinishedAt)
        try container.encodeIfPresent(resultCommittedAt, forKey: .resultCommittedAt)
        try container.encodeIfPresent(projectionReceivedAt, forKey: .projectionReceivedAt)
        try container.encode(toolFamily, forKey: .toolFamily)
    }

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

    private static func compactPathString(_ path: String, maxLength: Int = 45) -> String {
        guard path.count > maxLength else { return path }
        let parts = path.split(separator: "/")
        if parts.count >= 2 {
            let suffix = parts.suffix(2).joined(separator: "/")
            let candidate = ".../" + suffix
            if candidate.count <= maxLength {
                return candidate
            }
        }
        if let last = parts.last {
            let suffix = String(last)
            if (".../" + suffix).count <= maxLength {
                return ".../" + suffix
            }
            return "..." + String(suffix.suffix(max(10, maxLength - 3)))
        }
        return "..." + String(path.suffix(max(10, maxLength - 3)))
    }

    public static func summarizeArguments(_ argumentsJSON: String, toolName: String? = nil) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "unavailable"
        }
        let lowerName = toolName?.lowercased() ?? ""
        if lowerName.contains("write") || lowerName.contains("create") || lowerName.contains("edit") {
            var parts: [String] = []
            if let path = (object["TargetFile"] as? String) ?? (object["path"] as? String) {
                parts.append("path=\(compactPathString(path))")
            }
            if let content = (object["CodeContent"] as? String) ?? (object["content"] as? String) ?? (object["ReplacementContent"] as? String) {
                parts.append("bytes=\(content.utf8.count)")
            }
            if !parts.isEmpty {
                return parts.joined(separator: " ")
            }
        }
        let preferredKeys = ["command", "CommandLine", "cmd", "pattern", "query", "path", "TargetFile", "AbsolutePath", "SearchPath", "SearchDirectory", "url"]
        let pathKeys: Set<String> = ["path", "TargetFile", "AbsolutePath", "SearchPath", "SearchDirectory", "url"]
        let keys = preferredKeys.filter { object[$0] != nil } + object.keys.filter { !preferredKeys.contains($0) && $0 != "content" && $0 != "CodeContent" && $0 != "ReplacementContent" && $0 != "TargetContent" }.sorted()
        let summary = keys.compactMap { key -> String? in
            guard let value = object[key] else { return nil }
            if let string = value as? String {
                let formatted = pathKeys.contains(key) ? compactPathString(string) : (string.count > 60 ? String(string.prefix(57)) + "..." : string)
                return "\(key)=\(formatted)"
            }
            if let number = value as? NSNumber { return "\(key)=\(number)" }
            return "\(key)=…"
        }.joined(separator: " ")
        if summary.isEmpty { return "{}" }
        if summary.count > 100 {
            return String(summary.prefix(97)) + "..."
        }
        return summary
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
