import Foundation

/// A process attached to a pseudo-terminal, owned by the platform layer.
///
/// The GUI must not hold shell lifecycles; it renders what Core reports. This is
/// the seam Core drives a real interactive terminal through.
public protocol PlatformPtyProtocol: Sendable {
    /// Starts `command` in a new session with `cwd` as its working directory.
    ///
    /// - Throws: `PtyError.unsupported` where the platform has no PTY backend.
    func spawn(command: [String], cwd: URL, environment: [String: String],
               columns: Int, rows: Int) throws -> any PtyHandle
}

/// One live PTY session.
public protocol PtyHandle: Sendable {
    var pid: Int32 { get }

    /// Bytes the child produced since the last call, or nil once it exited.
    /// Never blocks.
    func drain() -> Data?

    func write(_ data: Data)
    func resize(columns: Int, rows: Int)

    /// SIGINT to the child's process group — what Ctrl-C does.
    func interrupt()

    /// SIGTERM, then SIGKILL if it is still there.
    func terminate()

    /// True when the child has exited and the output is fully drained.
    func isClosed() -> Bool

    /// Exit status once the child has been reaped; nil while it still runs.
    /// A child killed by a signal reports 128 + signal, like a shell would.
    func exitCode() -> Int32?

    /// Releases the master descriptor.
    func close()
}

public enum PtyError: Error, Sendable {
    case unsupported(String)
    case allocationFailed(String)
    case spawnFailed(String)
}
