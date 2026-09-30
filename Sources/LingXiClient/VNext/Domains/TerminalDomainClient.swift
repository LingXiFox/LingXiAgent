import Foundation
import LingXiProtocol

/// The terminal sessions that exist right now, as Core owns them.
public struct TerminalDomainClient: Sendable {
    private let transport: any ClientTransport

    public init(transport: any ClientTransport) {
        self.transport = transport
    }

    public func sessions() async throws -> [TerminalSessionInfo] {
        try await transport.listTerminalSessions(envelope: QueryEnvelope(payload: VoidResult())).payload
    }

    /// Starts the user's own interactive shell.
    public func spawnShell(cwd: String? = nil, columns: Int? = nil, rows: Int? = nil) async throws -> TerminalSessionInfo {
        let request = SpawnTerminalSessionRequest(cwd: cwd, columns: columns, rows: rows)
        let receipt = try await transport.spawnTerminalSession(envelope: CommandEnvelope(payload: request))
        guard let session = receipt.result else {
            throw RuntimeError(category: .runtime, code: "emptyResult", message: "创建终端会话没有返回结果",
                               retryability: .none, source: .client)
        }
        return session
    }

    /// Everything produced since the previous call.
    public func read(sessionID: String, columns: Int? = nil, rows: Int? = nil) async throws -> TerminalSessionOutput {
        let request = ReadTerminalSessionRequest(sessionID: sessionID, columns: columns, rows: rows)
        return try await transport.readTerminalSession(envelope: QueryEnvelope(payload: request)).payload
    }

    public func write(sessionID: String, text: String) async throws {
        let request = WriteTerminalSessionRequest(sessionID: sessionID, text: text)
        _ = try await transport.writeTerminalSession(envelope: CommandEnvelope(payload: request))
    }

    public func interrupt(sessionID: String) async throws {
        let request = InterruptTerminalSessionRequest(sessionID: sessionID)
        _ = try await transport.interruptTerminalSession(envelope: CommandEnvelope(payload: request))
    }

    public func close(sessionID: String) async throws {
        let request = CloseTerminalSessionRequest(sessionID: sessionID)
        _ = try await transport.closeTerminalSession(envelope: CommandEnvelope(payload: request))
    }
}
