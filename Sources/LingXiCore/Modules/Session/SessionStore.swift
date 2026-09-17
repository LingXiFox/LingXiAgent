import Foundation
import LingXiProtocol

/// Session 存储契约。
/// 当前实现：InMemorySessionStore；未来 SQLite 到来时替换实现，
/// AgentRuntime / SessionRuntime / TUI 的领域逻辑不变。
public protocol SessionStore: Actor, Sendable {
    func create(kind: SessionKind, parentSessionID: SessionID?, rootSessionID: SessionID?, spawnedByRunID: AgentRunID?, spawnedByToolCallID: ToolCallID?, title: String?) async throws -> Session
    func session(_ id: SessionID) async throws -> Session
    func listSessions() async throws -> [Session]
    func updateTitle(_ id: SessionID, title: String?) async throws -> Session
    func updateReasoningEffort(_ id: SessionID, effort: ReasoningEffort) async throws -> Session
    @discardableResult
    func appendMessage(_ sessionID: SessionID, role: MessageRole, content: String) async throws -> Message
    @discardableResult
    func appendMessage(_ sessionID: SessionID, role: MessageRole, parts: [SessionMessagePart]) async throws -> Message
    @discardableResult
    func appendMessage(_ sessionID: SessionID, message: Message) async throws -> Message
    @discardableResult
    func appendMessage(_ sessionID: SessionID, message: Message, expectedRevision: UInt64?) async throws -> Message
    @discardableResult
    func bumpRevision(_ sessionID: SessionID) async throws -> UInt64
    func currentRevision(_ sessionID: SessionID) async throws -> UInt64
    func deleteSession(_ id: SessionID) async throws
    @discardableResult
    func revertLastTurn(_ sessionID: SessionID, bumpRevision: Bool) async throws -> (revertedPrompt: String?, removedCount: Int)
}

public extension SessionStore {
    @discardableResult
    func revertLastTurn(_ sessionID: SessionID) async throws -> (revertedPrompt: String?, removedCount: Int) {
        try await revertLastTurn(sessionID, bumpRevision: true)
    }

    func create() async throws -> Session {
        try await create(kind: .primary, parentSessionID: nil, rootSessionID: nil, spawnedByRunID: nil, spawnedByToolCallID: nil, title: nil)
    }

    @discardableResult
    func appendMessage(_ sessionID: SessionID, role: MessageRole, content: String) async throws -> Message {
        try await appendMessage(sessionID, role: role, content: content, expectedRevision: nil)
    }

    @discardableResult
    func appendMessage(_ sessionID: SessionID, role: MessageRole, content: String, expectedRevision: UInt64?) async throws -> Message {
        try await appendMessage(sessionID, role: role, parts: [.text(content)], expectedRevision: expectedRevision)
    }

    @discardableResult
    func appendMessage(_ sessionID: SessionID, role: MessageRole, parts: [SessionMessagePart]) async throws -> Message {
        try await appendMessage(sessionID, role: role, parts: parts, expectedRevision: nil)
    }

    @discardableResult
    func appendMessage(_ sessionID: SessionID, role: MessageRole, parts: [SessionMessagePart], expectedRevision: UInt64?) async throws -> Message {
        let message = Message(id: MessageID(UUID().uuidString), role: role, parts: parts, createdAt: Date())
        return try await appendMessage(sessionID, message: message, expectedRevision: expectedRevision)
    }
}

/// 内存实现：actor 保证并发安全。
public actor InMemorySessionStore: SessionStore {
    private var sessions: [SessionID: Session] = [:]
    private var order: [SessionID] = []

    public init() {}

    public func create(kind: SessionKind = .primary, parentSessionID: SessionID? = nil, rootSessionID: SessionID? = nil, spawnedByRunID: AgentRunID? = nil, spawnedByToolCallID: ToolCallID? = nil, title: String? = nil) async throws -> Session {
        guard parentSessionID == nil || sessions[parentSessionID!] != nil else { throw CoreError(code: .sessionNotFound, message: "Parent Session 不存在") }
        let id = SessionID(UUID().uuidString)
        let session = Session(id: id, createdAt: Date(), kind: kind, parentSessionID: parentSessionID, rootSessionID: rootSessionID ?? parentSessionID.flatMap { sessions[$0]?.rootSessionID } ?? id, spawnedByRunID: spawnedByRunID, spawnedByToolCallID: spawnedByToolCallID, title: title)
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

    public func updateTitle(_ id: SessionID, title: String?) async throws -> Session {
        guard let current = sessions[id] else { throw CoreError(code: .sessionNotFound, message: "Session 不存在: \(id.rawValue)") }
        let updated = Session(id: current.id, createdAt: current.createdAt, kind: current.kind, parentSessionID: current.parentSessionID, rootSessionID: current.rootSessionID, spawnedByRunID: current.spawnedByRunID, spawnedByToolCallID: current.spawnedByToolCallID, title: title, reasoningEffort: current.reasoningEffort, projectID: current.projectID, cwdRootBindingID: current.cwdRootBindingID, cwdRelativePath: current.cwdRelativePath, updatedAt: current.updatedAt, messages: current.messages)
        sessions[id] = updated
        return updated
    }

    public func updateReasoningEffort(_ id: SessionID, effort: ReasoningEffort) async throws -> Session {
        guard let current = sessions[id] else { throw CoreError(code: .sessionNotFound, message: "Session 不存在: \(id.rawValue)") }
        var updated = current
        updated.setReasoningEffort(effort)
        sessions[id] = updated
        return updated
    }

    @discardableResult
    public func appendMessage(_ sessionID: SessionID, message: Message) async throws -> Message {
        try await appendMessage(sessionID, message: message, expectedRevision: nil)
    }

    @discardableResult
    public func appendMessage(_ sessionID: SessionID, message: Message, expectedRevision: UInt64?) async throws -> Message {
        guard var session = sessions[sessionID] else {
            throw CoreError(code: .sessionNotFound, message: "Session 不存在: \(sessionID.rawValue)")
        }
        if let expected = expectedRevision {
            guard session.revision == expected else {
                throw StaleRunError(sessionID: sessionID, expected: session.revision, actual: expected)
            }
        }
        session.append(message)
        sessions[sessionID] = session
        return message
    }

    @discardableResult
    public func bumpRevision(_ sessionID: SessionID) async throws -> UInt64 {
        guard var session = sessions[sessionID] else {
            throw CoreError(code: .sessionNotFound, message: "Session 不存在: \(sessionID.rawValue)")
        }
        let rev = session.bumpRevision()
        sessions[sessionID] = session
        return rev
    }

    public func currentRevision(_ sessionID: SessionID) async throws -> UInt64 {
        guard let session = sessions[sessionID] else {
            throw CoreError(code: .sessionNotFound, message: "Session 不存在: \(sessionID.rawValue)")
        }
        return session.revision
    }

    public func deleteSession(_ id: SessionID) async throws {
        sessions.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    @discardableResult
    public func revertLastTurn(_ sessionID: SessionID, bumpRevision: Bool) async throws -> (revertedPrompt: String?, removedCount: Int) {
        guard var session = sessions[sessionID] else {
            throw CoreError(code: .sessionNotFound, message: "Session 不存在: \(sessionID.rawValue)")
        }
        let outcome = session.revertLastTurn(bumpRevision: bumpRevision)
        sessions[sessionID] = session
        return outcome
    }
}

/// 每 project 一个 state.sqlite 的 canonical Session repository。
public actor PersistentSessionStore: SessionStore {
    private let persistence: SQLitePersistenceStore
    private var reasoningEfforts: [SessionID: ReasoningEffort] = [:]

    public init(persistence: SQLitePersistenceStore) { self.persistence = persistence }

    public func create(kind: SessionKind = .primary, parentSessionID: SessionID? = nil, rootSessionID: SessionID? = nil, spawnedByRunID: AgentRunID? = nil, spawnedByToolCallID: ToolCallID? = nil, title: String? = nil) async throws -> Session {
        let main = try await persistence.mainRootBinding()
        let parentRoot: SessionID?
        if let parentSessionID {
            parentRoot = try await session(parentSessionID).rootSessionID
        } else {
            parentRoot = nil
        }
        let id = SessionID(UUID().uuidString)
        let session = Session(
            id: id,
            createdAt: .now,
            kind: kind,
            parentSessionID: parentSessionID,
            rootSessionID: rootSessionID ?? parentRoot ?? id,
            spawnedByRunID: spawnedByRunID,
            spawnedByToolCallID: spawnedByToolCallID,
            title: title,
            projectID: persistence.projectID,
            cwdRootBindingID: main.id
        )
        try await persistence.createSession(session)
        return session
    }

    public func session(_ id: SessionID) async throws -> Session {
        if var session = try await persistence.loadSession(id) {
            if let effort = reasoningEfforts[id] {
                session.setReasoningEffort(effort)
            }
            return session
        }
        if var global = try await persistence.loadGlobalSession(id) {
            if let effort = reasoningEfforts[id] {
                global.setReasoningEffort(effort)
            }
            return global
        }
        throw CoreError(code: .sessionNotFound, message: "Session 不存在: \(id.rawValue)")
    }

    public func listSessions() async throws -> [Session] {
        var list = try await persistence.loadSessions()
        for i in list.indices {
            if let effort = reasoningEfforts[list[i].id] {
                list[i].setReasoningEffort(effort)
            }
        }
        return list
    }

    public func updateTitle(_ id: SessionID, title: String?) async throws -> Session {
        let current = try await session(id)
        try await persistence.updateSessionTitle(id, title: title)
        return Session(id: current.id, createdAt: current.createdAt, kind: current.kind, parentSessionID: current.parentSessionID, rootSessionID: current.rootSessionID, spawnedByRunID: current.spawnedByRunID, spawnedByToolCallID: current.spawnedByToolCallID, title: title, reasoningEffort: current.reasoningEffort, projectID: current.projectID, cwdRootBindingID: current.cwdRootBindingID, cwdRelativePath: current.cwdRelativePath, updatedAt: .now, revision: current.revision, messages: current.messages)
    }

    public func updateReasoningEffort(_ id: SessionID, effort: ReasoningEffort) async throws -> Session {
        reasoningEfforts[id] = effort
        var current = try await session(id)
        current.setReasoningEffort(effort)
        return current
    }

    @discardableResult
    public func appendMessage(_ sessionID: SessionID, message: Message) async throws -> Message {
        try await appendMessage(sessionID, message: message, expectedRevision: nil)
    }

    @discardableResult
    public func appendMessage(_ sessionID: SessionID, message: Message, expectedRevision: UInt64?) async throws -> Message {
        _ = try await session(sessionID)
        try await persistence.appendMessage(sessionID: sessionID, message: message, expectedRevision: expectedRevision)
        return message
    }

    @discardableResult
    public func bumpRevision(_ sessionID: SessionID) async throws -> UInt64 {
        _ = try await session(sessionID)
        return try await persistence.bumpRevision(sessionID: sessionID)
    }

    public func currentRevision(_ sessionID: SessionID) async throws -> UInt64 {
        _ = try await session(sessionID)
        return try await persistence.currentRevision(sessionID: sessionID)
    }

    public func deleteSession(_ id: SessionID) async throws {
        try await persistence.deleteSession(id)
    }

    @discardableResult
    public func revertLastTurn(_ sessionID: SessionID, bumpRevision: Bool) async throws -> (revertedPrompt: String?, removedCount: Int) {
        _ = try await session(sessionID)
        return try await persistence.revertLastTurn(sessionID: sessionID, bumpRevision: bumpRevision)
    }
}
