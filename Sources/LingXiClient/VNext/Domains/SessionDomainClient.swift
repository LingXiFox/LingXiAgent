import Foundation
import LingXiProtocol

public struct SessionDomainClient: Sendable {
    private let transport: any ClientTransport
    private let replayCoordinator: EventReplayCoordinator?

    public init(transport: any ClientTransport, replayCoordinator: EventReplayCoordinator? = nil) {
        self.transport = transport
        self.replayCoordinator = replayCoordinator
    }

    public func create(
        workspace: String? = nil,
        initialModel: String? = nil,
        defaultMode: AgentMode = .build,
        defaultPermissionConfiguration: PermissionConfiguration = .askWorkspace
    ) async throws -> CommandReceipt<SessionSummary> {
        let req = CreateSessionRequest(
            workspace: workspace,
            initialModel: initialModel,
            defaultMode: defaultMode,
            defaultPermissionConfiguration: defaultPermissionConfiguration
        )
        return try await transport.createSession(envelope: CommandEnvelope(payload: req))
    }

    public func rename(sessionID: SessionID, title: String?) async throws -> CommandReceipt<SessionSummary> {
        let req = RenameSessionRequest(sessionID: sessionID, title: title)
        return try await transport.renameSession(envelope: CommandEnvelope(payload: req))
    }

    public func setReasoningEffort(sessionID: SessionID, effort: ReasoningEffort) async throws -> CommandReceipt<SessionSummary> {
        let req = SetSessionReasoningEffortRequest(sessionID: sessionID, effort: effort)
        return try await transport.setSessionReasoningEffort(envelope: CommandEnvelope(payload: req))
    }

    public func delete(sessionID: SessionID) async throws -> CommandReceipt<VoidResult> {
        let req = DeleteSessionRequest(sessionID: sessionID)
        return try await transport.deleteSession(envelope: CommandEnvelope(payload: req))
    }

    public func get(sessionID: SessionID) async throws -> SessionSummary {
        let req = GetSessionRequest(sessionID: sessionID)
        let resp = try await transport.getSession(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func list(page: PageRequest = PageRequest()) async throws -> Page<SessionSummary> {
        let resp = try await transport.listSessions(envelope: QueryEnvelope(payload: page))
        return resp.payload
    }

    public func listAll() async throws -> [SessionSummary] {
        var sessions: [SessionSummary] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try await list(page: PageRequest(cursor: cursor, limit: 200))
            sessions.append(contentsOf: page.items)
            guard page.hasMore, let next = page.nextCursor, seen.insert(next).inserted else { break }
            cursor = next
        } while true
        return sessions
    }

    public func snapshot(sessionID: SessionID) async throws -> SessionSnapshot {
        let req = GetSessionSnapshotRequest(sessionID: sessionID)
        let resp = try await transport.getSessionSnapshot(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func events(sessionID: SessionID, after: EventCursor? = nil) async throws -> AsyncStream<SessionEventEnvelope> {
        if let replayCoordinator {
            return try await replayCoordinator.subscribeSessionEvents(sessionID: sessionID, after: after)
        }
        return try await transport.subscribeSessionEvents(sessionID: sessionID, after: after)
    }

    public func listEvents(request: ListSessionEventsRequest) async throws -> [SessionEventEnvelope] {
        try await transport.listSessionEvents(request: request)
    }
}
