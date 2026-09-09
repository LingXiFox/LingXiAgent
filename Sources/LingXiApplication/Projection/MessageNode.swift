import Foundation
import LingXiProtocol

/// 问答会话性能与元数据指标。
public struct MessageMetrics: Sendable, Equatable, Codable {
    public var model: String?
    public var durationMs: Double?
    public var firstTokenMs: Double?
    public var tokenRate: Double?
    public var totalTokens: Int?
    public var completedAt: Date?

    public init(
        model: String? = nil,
        durationMs: Double? = nil,
        firstTokenMs: Double? = nil,
        tokenRate: Double? = nil,
        totalTokens: Int? = nil,
        completedAt: Date? = nil
    ) {
        self.model = model
        self.durationMs = durationMs
        self.firstTokenMs = firstTokenMs
        self.tokenRate = tokenRate
        self.totalTokens = totalTokens
        self.completedAt = completedAt
    }
}

/// 消息节点（用户输入或助手回答）。
/// 契约：同一个 MessageID 只能产生一个正文节点。
/// 流式过程中更新同一节点，提交后 finalize 同一节点，严禁拆分成 Assistant + Result 两份。
public struct MessageNode: Sendable, Equatable {
    public let messageID: MessageID
    public var role: ProtocolMessageRole
    public var content: String
    public var isStreaming: Bool
    public var isFinal: Bool
    public var citations: [ContentRef]
    public var metrics: MessageMetrics?

    public init(
        messageID: MessageID,
        role: ProtocolMessageRole,
        content: String = "",
        isStreaming: Bool = false,
        isFinal: Bool = false,
        citations: [ContentRef] = [],
        metrics: MessageMetrics? = nil
    ) {
        self.messageID = messageID
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.isFinal = isFinal
        self.citations = citations
        self.metrics = metrics
    }
}
