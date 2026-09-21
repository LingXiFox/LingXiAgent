import Foundation

public enum SandboxFilesystemAccess: Sendable, Equatable {
    case workspaceReadWrite
    case workspaceReadOnly
}

public enum SandboxNetworkAccess: Sendable, Equatable {
    case deny
    case allowHosts([String])
}

public struct SandboxPolicy: Sendable, Equatable {
    public let workspace: URL
    public let readOnlyPaths: [URL]
    public let filesystem: SandboxFilesystemAccess
    public let network: SandboxNetworkAccess
    public let allowSubprocesses: Bool
    /// Where the child should actually run. A sandbox that replaces the working directory has to
    /// be told, or the command ends up at the workspace root and reports paths relative to there.
    public let workingDirectory: URL?

    public init(
        workspace: URL,
        readOnlyPaths: [URL] = [],
        filesystem: SandboxFilesystemAccess = .workspaceReadWrite,
        network: SandboxNetworkAccess = .deny,
        allowSubprocesses: Bool = true,
        workingDirectory: URL? = nil
    ) {
        self.workspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
        self.readOnlyPaths = readOnlyPaths.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.filesystem = filesystem
        self.network = network
        self.allowSubprocesses = allowSubprocesses
        self.workingDirectory = workingDirectory.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }
}

public struct SandboxCapabilities: Sendable, Equatable {
    public let filesystemEnforced: Bool
    public let networkEnforced: Bool
    public let processIsolationEnforced: Bool

    public init(filesystemEnforced: Bool, networkEnforced: Bool, processIsolationEnforced: Bool) {
        self.filesystemEnforced = filesystemEnforced
        self.networkEnforced = networkEnforced
        self.processIsolationEnforced = processIsolationEnforced
    }
}

public struct ToolProcessInvocation: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public protocol PlatformSandboxProtocol: Sendable {
    var capabilities: SandboxCapabilities { get }
    func invocation(executable: String, arguments: [String], policy: SandboxPolicy) throws -> ToolProcessInvocation
}
