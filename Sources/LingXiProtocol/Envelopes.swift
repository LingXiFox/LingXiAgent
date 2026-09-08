import Foundation

/// CommandEnvelope：状态修改意图包裹器，要求具备幂等性 commandID。
public struct CommandEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let commandID: CommandID
    public let issuedAt: Date
    public let expectedRevision: UInt64?
    public let payload: Payload

    public init(
        commandID: CommandID = CommandID(),
        issuedAt: Date = Date(),
        expectedRevision: UInt64? = nil,
        payload: Payload
    ) {
        self.commandID = commandID
        self.issuedAt = issuedAt
        self.expectedRevision = expectedRevision
        self.payload = payload
    }
}

/// QueryEnvelope：只读查询请求包裹器。
public struct QueryEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let requestID: RequestID
    public let issuedAt: Date
    public let payload: Payload

    public init(
        requestID: RequestID = RequestID(),
        issuedAt: Date = Date(),
        payload: Payload
    ) {
        self.requestID = requestID
        self.issuedAt = issuedAt
        self.payload = payload
    }
}

/// ResponseEnvelope：查询或请求的响应包裹器，携带 revision 与 eventCursor 供数据新鲜度判断。
public struct ResponseEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let requestID: RequestID
    public let serverTime: Date
    public let revision: UInt64?
    public let eventCursor: EventCursor?
    public let payload: Payload

    public init(
        requestID: RequestID,
        serverTime: Date = Date(),
        revision: UInt64? = nil,
        eventCursor: EventCursor? = nil,
        payload: Payload
    ) {
        self.requestID = requestID
        self.serverTime = serverTime
        self.revision = revision
        self.eventCursor = eventCursor
        self.payload = payload
    }
}

/// CommandReceipt：状态修改命令的持久化回执（ACK 与观察水位线）。
public struct CommandReceipt<Result: Codable & Sendable>: Codable, Sendable {
    public let commandID: CommandID
    public let applied: Bool
    public let revision: UInt64
    /// 此 Command 对哪些 Event Stream 产生了可观察事实，以及这些事实至少已经提交到哪里。
    public let observedThrough: [EventWatermark]
    public let result: Result?

    public init(
        commandID: CommandID,
        applied: Bool,
        revision: UInt64,
        observedThrough: [EventWatermark],
        result: Result? = nil
    ) {
        self.commandID = commandID
        self.applied = applied
        self.revision = revision
        self.observedThrough = observedThrough
        self.result = result
    }
}

/// 分页请求。
public struct PageRequest: Codable, Sendable, Equatable {
    public let cursor: String?
    public let limit: Int

    public init(cursor: String? = nil, limit: Int = 50) {
        self.cursor = cursor
        self.limit = limit
    }
}

/// 分页响应。
public struct Page<T: Codable & Sendable>: Codable, Sendable {
    public let items: [T]
    public let nextCursor: String?
    public let hasMore: Bool

    public init(items: [T], nextCursor: String? = nil, hasMore: Bool = false) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

/// 空载荷/空结果。
public struct VoidResult: Codable, Sendable, Equatable {
    public init() {}
}
