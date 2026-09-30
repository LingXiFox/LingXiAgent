import Foundation

// Contract for live terminal sessions.
//
// A timeline ToolCall records what the Agent ran; a terminal session is a
// process that exists right now. Both are reported here so a front end can show
// real sessions without dressing up history as one, and so the user's own shell
// is a session Core owns rather than one a view created.

/// Who a session belongs to.
public enum TerminalSessionKind: String, Codable, Sendable, Equatable {
    /// Started by an Agent run; output and lifetime come from Core's process layer.
    case agent
    /// Started by the user as an interactive shell.
    case user
}

/// Process state, as the runtime reports it.
public enum TerminalSessionState: String, Codable, Sendable, Equatable {
    case running
    case exited
    case timedOut
    case terminated
}

/// One terminal session as the front end sees it.
public struct TerminalSessionInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: TerminalSessionKind
    /// Command line for an Agent session; the shell's program for a user one.
    public let title: String
    public let cwd: String?
    public let state: TerminalSessionState
    public let pid: Int?
    public let exitCode: Int?
    /// The Agent session and run that started this process, when it is an Agent one.
    public let ownerSessionID: String?
    public let ownerRunID: String?
    public let startedAt: Date?
    /// Whether input can reach the process at all.
    public let supportsInput: Bool
    /// Whether an interrupt (Ctrl-C semantics) exists for this kind of session.
    /// A piped process has no terminal signal to raise, so this is false and the
    /// runtime refuses rather than pretending.
    public let supportsInterrupt: Bool

    public init(id: String, kind: TerminalSessionKind, title: String, cwd: String? = nil,
                state: TerminalSessionState, pid: Int? = nil, exitCode: Int? = nil,
                ownerSessionID: String? = nil, ownerRunID: String? = nil, startedAt: Date? = nil,
                supportsInput: Bool, supportsInterrupt: Bool) {
        self.id = id
        self.kind = kind
        self.title = title
        self.cwd = cwd
        self.state = state
        self.pid = pid
        self.exitCode = exitCode
        self.ownerSessionID = ownerSessionID
        self.ownerRunID = ownerRunID
        self.startedAt = startedAt
        self.supportsInput = supportsInput
        self.supportsInterrupt = supportsInterrupt
    }
}

/// Starts the user's interactive shell.
public struct SpawnTerminalSessionRequest: Codable, Sendable, Equatable {
    public var cwd: String?
    public var columns: Int?
    public var rows: Int?

    public init(cwd: String? = nil, columns: Int? = nil, rows: Int? = nil) {
        self.cwd = cwd
        self.columns = columns
        self.rows = rows
    }
}

public struct ReadTerminalSessionRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public var columns: Int?
    public var rows: Int?

    public init(sessionID: String, columns: Int? = nil, rows: Int? = nil) {
        self.sessionID = sessionID
        self.columns = columns
        self.rows = rows
    }
}

/// Everything produced since the previous read; the cursor is held by Core.
public struct TerminalSessionOutput: Codable, Sendable, Equatable {
    public let sessionID: String
    public let text: String
    public let state: TerminalSessionState
    public let exitCode: Int?

    public init(sessionID: String, text: String, state: TerminalSessionState, exitCode: Int? = nil) {
        self.sessionID = sessionID
        self.text = text
        self.state = state
        self.exitCode = exitCode
    }
}

public struct WriteTerminalSessionRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public let text: String

    public init(sessionID: String, text: String) {
        self.sessionID = sessionID
        self.text = text
    }
}

public struct InterruptTerminalSessionRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public init(sessionID: String) { self.sessionID = sessionID }
}

/// Ends a session for good. Collapsing a panel is not a close.
public struct CloseTerminalSessionRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public init(sessionID: String) { self.sessionID = sessionID }
}
