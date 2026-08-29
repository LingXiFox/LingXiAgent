import Foundation
import LingXiProtocol

// LingXi Session Domain：产品/会话领域的消息。
// 刻意不与 Model.ModelMessage 复用——Session Message 表达会话语义，
// ModelMessage 表达一次模型 inference 的输入，二者未来必然分化。
// 转换边界：SessionContextBuilder。

public enum MessageRole: String, Sendable {
    case user
    case assistant
    case tool
}

public struct Message: Sendable, Equatable {
    public let id: MessageID
    public let role: MessageRole
    public let parts: [SessionMessagePart]
    public let createdAt: Date

    public var content: String {
        parts.compactMap { if case let .text(text) = $0 { text } else { nil } }.joined()
    }

    public init(id: MessageID, role: MessageRole, content: String, createdAt: Date) {
        self.init(id: id, role: role, parts: [.text(content)], createdAt: createdAt)
    }

    public init(id: MessageID, role: MessageRole, parts: [SessionMessagePart], createdAt: Date) {
        self.id = id
        self.role = role
        self.parts = parts
        self.createdAt = createdAt
    }
}

public struct Session: Sendable, Equatable {
    public let id: SessionID
    /// Durable cwd 只保存 binding 和相对路径，绝不复制 absolute path。
    public let projectID: ProjectID?
    public let cwdRootBindingID: RootBindingID?
    public let cwdRelativePath: ProjectRelativePath
    public let createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var messages: [Message]

    public init(
        id: SessionID,
        createdAt: Date,
        projectID: ProjectID? = nil,
        cwdRootBindingID: RootBindingID? = nil,
        cwdRelativePath: ProjectRelativePath = .root,
        updatedAt: Date? = nil,
        messages: [Message] = []
    ) {
        self.id = id
        self.projectID = projectID
        self.cwdRootBindingID = cwdRootBindingID
        self.cwdRelativePath = cwdRelativePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.messages = messages
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
            parts: parts,
            createdAt: createdAt
        )
    }
}
