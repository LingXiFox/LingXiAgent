import Foundation

public enum BackgroundTaskStatus: String, Codable, Sendable, Equatable {
    case running
    case exited
    case timedOut = "timed_out"
    case terminated
}

public struct BackgroundTaskSnapshot: Codable, Sendable, Equatable {
    public let id: String
    public let command: String
    public let cwd: String
    public let timeoutSeconds: Int
    public let startedAt: Date
    public let completedAt: Date?
    public let status: BackgroundTaskStatus
    public let pid: Int32?
    public let exitCode: Int32?
    public let description: String?
    public let stdout: String
    public let stderr: String
    public let stdoutCursor: Int
    public let stderrCursor: Int
    public let elapsedSeconds: Double
    public let remainingTimeoutSeconds: Double

    public init(
        id: String,
        command: String,
        cwd: String,
        timeoutSeconds: Int,
        startedAt: Date,
        completedAt: Date?,
        status: BackgroundTaskStatus,
        pid: Int32?,
        exitCode: Int32?,
        description: String?,
        stdout: String,
        stderr: String,
        stdoutCursor: Int,
        stderrCursor: Int,
        elapsedSeconds: Double,
        remainingTimeoutSeconds: Double
    ) {
        self.id = id
        self.command = command
        self.cwd = cwd
        self.timeoutSeconds = timeoutSeconds
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.status = status
        self.pid = pid
        self.exitCode = exitCode
        self.description = description
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutCursor = stdoutCursor
        self.stderrCursor = stderrCursor
        self.elapsedSeconds = elapsedSeconds
        self.remainingTimeoutSeconds = remainingTimeoutSeconds
    }
}
