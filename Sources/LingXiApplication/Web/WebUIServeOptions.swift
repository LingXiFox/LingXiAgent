import Foundation

/// Launch options for the WebUI front end (`lingxiagent serve`).
/// Lives in the application layer so the CLI parser and the WebUI target
/// share one description of how a serve session is configured.
public struct WebUIServeOptions: Sendable, Equatable {
    /// Bind address. Loopback by default; anything else is a remote exposure.
    public var host: String
    /// 0 lets the OS assign an ephemeral port.
    public var port: UInt16
    /// Open the system default browser once the server is listening.
    public var openBrowser: Bool
    /// Explicit Core path, mirroring `--core-path` on other entry points.
    public var corePath: String?
    /// Workspace the session starts in.
    public var workingDirectory: String?
    /// Resume this session on startup.
    public var resumeSessionID: String?
    /// Start the session in YOLO full-access mode.
    public var isYoloMode: Bool
    /// Required for non-loopback binds; also accepted on loopback.
    public var accessToken: String?
    /// Allow binding outside loopback. Refused when absent.
    public var allowRemote: Bool
    /// Skip the Origin / custom-header browser checks. Diagnostics only.
    public var disableBrowserGuard: Bool
    /// Serve assets straight from a checkout directory instead of the bundle.
    public var assetDirectory: String?
    /// Seconds without any connected client before the server exits. 0 disables.
    public var idleShutdownSeconds: Double

    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 0,
        openBrowser: Bool = true,
        corePath: String? = nil,
        workingDirectory: String? = nil,
        resumeSessionID: String? = nil,
        isYoloMode: Bool = false,
        accessToken: String? = nil,
        allowRemote: Bool = false,
        disableBrowserGuard: Bool = false,
        assetDirectory: String? = nil,
        idleShutdownSeconds: Double = 0
    ) {
        self.host = host
        self.port = port
        self.openBrowser = openBrowser
        self.corePath = corePath
        self.workingDirectory = workingDirectory
        self.resumeSessionID = resumeSessionID
        self.isYoloMode = isYoloMode
        self.accessToken = accessToken
        self.allowRemote = allowRemote
        self.disableBrowserGuard = disableBrowserGuard
        self.assetDirectory = assetDirectory
        self.idleShutdownSeconds = idleShutdownSeconds
    }

    public var isLoopbackHost: Bool {
        Self.loopbackHosts.contains(host.lowercased())
    }

    public var displayHost: String {
        // What the user is pointed at has to be where the socket actually is. Reporting the
        // spelling they typed advertised an `http://[::1]:port` URL that nothing answered on.
        bindHost.contains(":") ? "[\(bindHost)]" : bindHost
    }

    /// The bind address used for the actual socket. The listener speaks IPv4, so the loopback
    /// spellings that mean "this machine" all resolve to it, and anything else must already be
    /// a literal v4 address.
    public var bindHost: String {
        switch host.lowercased() {
        case "::1", "[::1]", "localhost", "0": return "127.0.0.1"
        default: return host
        }
    }

    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]", "0"]

    /// The application-layer launch configuration this maps onto.
    public func applicationConfiguration() -> ApplicationLaunchConfiguration {
        ApplicationLaunchConfiguration(
            corePath: corePath,
            initialWorkingDir: workingDirectory,
            isYoloMode: isYoloMode,
            resumeSessionID: resumeSessionID
        )
    }
}
