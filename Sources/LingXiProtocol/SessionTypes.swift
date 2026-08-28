import Foundation

/// Session 跨端标识与会话查询 DTO（协议层）。
/// 注意：这里是 Client 可见的协议 DTO，不等于 Core 内部 Session 领域对象。

public struct SessionID: Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct MessageID: Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum SessionMessageRole: String, Sendable, Equatable, Codable {
    case user
    case assistant
}

/// 一条会话消息的客户端视图。
public struct SessionMessageSnapshot: Sendable, Equatable, Codable {
    public let id: MessageID
    public let role: SessionMessageRole
    public let content: String
    public let createdAt: Date

    public init(id: MessageID, role: SessionMessageRole, content: String, createdAt: Date) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

/// Session 列表摘要。
public struct SessionInfo: Sendable, Equatable, Codable {
    public let id: SessionID
    public let createdAt: Date
    public let updatedAt: Date
    public let messageCount: Int

    public init(id: SessionID, createdAt: Date, updatedAt: Date, messageCount: Int) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
    }
}

/// Session 完整查询结果。
public struct SessionSnapshot: Sendable, Equatable, Codable {
    public let id: SessionID
    public let createdAt: Date
    public let updatedAt: Date
    public let messages: [SessionMessageSnapshot]

    public init(id: SessionID, createdAt: Date, updatedAt: Date, messages: [SessionMessageSnapshot]) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }
}

/// 一轮对话的句柄。
public struct TurnHandle: Sendable, Equatable, Codable {
    public let sessionID: SessionID
    public let streamID: StreamID

    public init(sessionID: SessionID, streamID: StreamID) {
        self.sessionID = sessionID
        self.streamID = streamID
    }
}

/// turn 正常完成（控制面语义事件）。
public struct TurnResult: Sendable, Equatable, Codable {
    public let sessionID: SessionID
    public let streamID: StreamID
    public let assistantMessageID: MessageID
    public let finishReason: ModelFinishReason?
    public let usage: ModelUsage?

    public init(
        sessionID: SessionID,
        streamID: StreamID,
        assistantMessageID: MessageID,
        finishReason: ModelFinishReason?,
        usage: ModelUsage?
    ) {
        self.sessionID = sessionID
        self.streamID = streamID
        self.assistantMessageID = assistantMessageID
        self.finishReason = finishReason
        self.usage = usage
    }
}

/// turn 失败（控制面语义事件）。
public struct TurnFailure: Sendable, Equatable, Codable {
    public let sessionID: SessionID
    public let streamID: StreamID
    public let error: CoreError

    public init(sessionID: SessionID, streamID: StreamID, error: CoreError) {
        self.sessionID = sessionID
        self.streamID = streamID
        self.error = error
    }
}
