import Foundation
import LingXiPlatform
import LingXiProtocol

// Terminal sessions for the right-hand panel.
//
// Two kinds of real session are reported through one contract: the processes an
// Agent run started (owned by Core's process layer) and the user's own shell
// (a PTY Core holds). A view never spawns a process and never decides when a
// session dies.

extension CoreHost {

    public func listTerminalSessions(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[TerminalSessionInfo]> {
        let sessions = await requireTerminalSessions().sessions()
        return ResponseEnvelope(requestID: envelope.requestID, revision: currentRevision, payload: sessions)
    }

    public func spawnTerminalSession(envelope: CommandEnvelope<SpawnTerminalSessionRequest>) async throws -> CommandReceipt<TerminalSessionInfo> {
        let request = envelope.payload
        let cwd = request.cwd.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let session = try await requireTerminalSessions().spawnShell(cwd: cwd, columns: request.columns,
                                                                    rows: request.rows)
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: nextRevision(),
                              observedThrough: [], result: session)
    }

    public func readTerminalSession(envelope: QueryEnvelope<ReadTerminalSessionRequest>) async throws -> ResponseEnvelope<TerminalSessionOutput> {
        let request = envelope.payload
        let output = try await requireTerminalSessions().read(sessionID: request.sessionID,
                                                             columns: request.columns, rows: request.rows)
        return ResponseEnvelope(requestID: envelope.requestID, revision: currentRevision, payload: output)
    }

    public func writeTerminalSession(envelope: CommandEnvelope<WriteTerminalSessionRequest>) async throws -> CommandReceipt<VoidResult> {
        let request = envelope.payload
        try await requireTerminalSessions().write(sessionID: request.sessionID, text: request.text)
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: nextRevision(),
                              observedThrough: [], result: VoidResult())
    }

    public func interruptTerminalSession(envelope: CommandEnvelope<InterruptTerminalSessionRequest>) async throws -> CommandReceipt<VoidResult> {
        try await requireTerminalSessions().interrupt(sessionID: envelope.payload.sessionID)
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: nextRevision(),
                              observedThrough: [], result: VoidResult())
    }

    public func closeTerminalSession(envelope: CommandEnvelope<CloseTerminalSessionRequest>) async throws -> CommandReceipt<VoidResult> {
        try await requireTerminalSessions().close(sessionID: envelope.payload.sessionID)
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: nextRevision(),
                              observedThrough: [], result: VoidResult())
    }
}
