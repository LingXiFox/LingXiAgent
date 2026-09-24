import Foundation

/// 任务内工具执行状态记录
public struct ToolExecutionState: Sendable, Codable, Equatable, Hashable {
    public let toolCallID: String
    public let state: String // 'pending' | 'executing' | 'completed' | 'failed'
    public let payload: [String: String]
    public let updatedAt: Date

    public init(
        toolCallID: String,
        state: String,
        payload: [String: String] = [:],
        updatedAt: Date = .now
    ) {
        self.toolCallID = toolCallID
        self.state = state
        self.payload = payload
        self.updatedAt = updatedAt
    }
}
