import Foundation

// What a front end can say about a tool without guessing. The settings window
// used to print a hardcoded verdict for the desktop and browser tools; these
// are the facts Core actually holds about them.

/// Whether the model sees a tool without loading it first.
public enum ToolExposure: String, Codable, Sendable, Equatable {
    /// Sent with every request.
    case core
    /// Registered, but the model has to load it by id first.
    case onDemand
    /// Not registered in this runtime.
    case unavailable
}

public struct GetToolStatusRequest: Codable, Sendable, Equatable {
    public let toolIDs: [String]
    public init(toolIDs: [String]) { self.toolIDs = toolIDs }
}

public struct ToolStatusEntry: Codable, Sendable, Equatable {
    public let toolID: String
    public let exposure: ToolExposure
    /// How the current permission policy treats this tool. Only known for
    /// registered tools, since the decision is made from their capabilities.
    public let permission: PermissionDecision?
    /// False when the tool exists but the thing it drives is not reachable
    /// here, which is a different failure than the tool being missing.
    public let backendReady: Bool
    /// Where the backend was found, or why it was not. Never a secret path
    /// fragment the user has to decode: it names the file that is missing.
    public let backendDetail: String?

    public init(toolID: String, exposure: ToolExposure, permission: PermissionDecision? = nil,
                backendReady: Bool = true, backendDetail: String? = nil) {
        self.toolID = toolID
        self.exposure = exposure
        self.permission = permission
        self.backendReady = backendReady
        self.backendDetail = backendDetail
    }
}
