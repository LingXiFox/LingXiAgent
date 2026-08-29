import Foundation
import LingXiProtocol

/// Session 存储契约。
/// 当前实现：InMemorySessionStore；未来 SQLite 到来时替换实现，
/// AgentRuntime / SessionRuntime / TUI 的领域逻辑不变。
public protocol SessionStore: Actor, Sendable {
    func create() async throws -> Session
    func session(_ id: SessionID) async throws -> Session
    func listSessions() async throws -> [Session]
    @discardableResult
    func appendMessage(_ sessionID: SessionID, role: MessageRole, content: String) async throws -> Message
    @discardableResult
    func appendMessage(_ sessionID: SessionID, role: MessageRole, parts: [SessionMessagePart]) async throws -> Message
}

/// 内存实现：actor 保证并发安全。
public actor InMemorySessionStore: SessionStore {
    private var sessions: [SessionID: Session] = [:]
    private var order: [SessionID] = []

    public init() {}

    public func create() async throws -> Session {
        let session = Session(id: SessionID(UUID().uuidString), createdAt: Date())
        sessions[session.id] = session
        order.append(session.id)
        return session
    }

    public func session(_ id: SessionID) async throws -> Session {
        guard let session = sessions[id] else {
            throw CoreError(code: .sessionNotFound, message: "Session 不存在: \(id.rawValue)")
        }
        return session
    }

    public func listSessions() async throws -> [Session] {
        order.compactMap { sessions[$0] }
    }

    @discardableResult
    public func appendMessage(_ sessionID: SessionID, role: MessageRole, content: String) async throws -> Message {
        try await appendMessage(sessionID, role: role, parts: [.text(content)])
    }

    @discardableResult
    public func appendMessage(_ sessionID: SessionID, role: MessageRole, parts: [SessionMessagePart]) async throws -> Message {
        guard sessions[sessionID] != nil else {
            throw CoreError(code: .sessionNotFound, message: "Session 不存在: \(sessionID.rawValue)")
        }
        let message = Message(
            id: MessageID(UUID().uuidString),
            role: role,
            parts: parts,
            createdAt: Date()
        )
        sessions[sessionID]?.append(message)
        return message
    }
}

/// 每 project 一个 state.sqlite 的 canonical Session repository。
public actor PersistentSessionStore: SessionStore {
    private let persistence: SQLitePersistenceStore

    public init(persistence: SQLitePersistenceStore) { self.persistence = persistence }

    public func create() async throws -> Session {
        let main = try await persistence.mainRootBinding()
        let session = Session(
            id: SessionID(UUID().uuidString),
            createdAt: .now,
            projectID: persistence.projectID,
            cwdRootBindingID: main.id
        )
        try await persistence.createSession(id: session.id, cwdRootBindingID: main.id, cwdRelativePath: .root, createdAt: session.createdAt)
        return session
    }

    public func session(_ id: SessionID) async throws -> Session {
        guard let session = try await persistence.loadSessions().first(where: { $0.id == id }) else {
            throw CoreError(code: .sessionNotFound, message: "Session 不存在: \(id.rawValue)")
        }
        return session
    }

    public func listSessions() async throws -> [Session] { try await persistence.loadSessions() }

    @discardableResult
    public func appendMessage(_ sessionID: SessionID, role: MessageRole, content: String) async throws -> Message {
        try await appendMessage(sessionID, role: role, parts: [.text(content)])
    }

    @discardableResult
    public func appendMessage(_ sessionID: SessionID, role: MessageRole, parts: [SessionMessagePart]) async throws -> Message {
        _ = try await session(sessionID)
        let message = Message(id: MessageID(UUID().uuidString), role: role, parts: parts, createdAt: .now)
        try await persistence.appendMessage(sessionID: sessionID, message: message)
        return message
    }
}
