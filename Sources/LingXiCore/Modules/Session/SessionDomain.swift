import Foundation
import LingXiProtocol

// LingXi Session Domain：产品/会话领域的消息。
// 刻意不与 Model.ModelMessage 复用——Session Message 表达会话语义，
// ModelMessage 表达一次模型 inference 的输入，二者未来必然分化。
// 转换边界：SessionContextBuilder。

public enum MessageRole: String, Sendable {
    case user
    case assistant
}

public struct Message: Sendable, Equatable {
    public let id: MessageID
    public let role: MessageRole
    public let content: String
    public let createdAt: Date

    public init(id: MessageID, role: MessageRole, content: String, createdAt: Date) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

public struct Session: Sendable, Equatable {
    public let id: SessionID
    public let createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var messages: [Message]

    public init(id: SessionID, createdAt: Date) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.messages = []
    }

    public mutating func append(_ message: Message) {
        messages.append(message)
        updatedAt = message.createdAt
    }
}

// MARK: - 协议层 DTO 转换（Session Domain → Protocol DTO）

extension Session {
    public func toInfo() -> SessionInfo {
        SessionInfo(id: id, createdAt: createdAt, updatedAt: updatedAt, messageCount: messages.count)
    }

    public func toSnapshot() -> SessionSnapshot {
        SessionSnapshot(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messages: messages.map(\.toSnapshot)
        )
    }
}

extension Message {
    public var toSnapshot: SessionMessageSnapshot {
        SessionMessageSnapshot(
            id: id,
            role: SessionMessageRole(rawValue: role.rawValue) ?? .user,
            content: content,
            createdAt: createdAt
        )
    }
}
