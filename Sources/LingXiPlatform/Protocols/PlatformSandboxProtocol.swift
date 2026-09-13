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

    public init(
        workspace: URL,
        readOnlyPaths: [URL] = [],
        filesystem: SandboxFilesystemAccess = .workspaceReadWrite,
        network: SandboxNetworkAccess = .deny,
        allowSubprocesses: Bool = true
    ) {
        self.workspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
        self.readOnlyPaths = readOnlyPaths.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.filesystem = filesystem
        self.network = network
        self.allowSubprocesses = allowSubprocesses
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
