import Foundation
import LingXiProtocol

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

    public init(
        messageID: MessageID,
        role: ProtocolMessageRole,
        content: String = "",
        isStreaming: Bool = false,
        isFinal: Bool = false,
        citations: [ContentRef] = []
    ) {
        self.messageID = messageID
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.isFinal = isFinal
        self.citations = citations
    }
}
