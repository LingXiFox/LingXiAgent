import Foundation

// Read-only projection of the browser sessions the Agent actually drives.
//
// The fields are exactly what Core's browser host reports: the page it last
// navigated, the title it read, and the snapshot it took. There is no loading
// flag, no cookie jar and no control-party state in the runtime yet, so none
// is claimed here.

/// One live Agent browser session.
public struct BrowserSessionStatus: Codable, Sendable, Equatable, Identifiable {
    /// The session the Agent owns this browser under; equals the Agent session ID.
    public let sessionID: String
    public let url: String
    public let title: String
    /// Page identifier the host reports for this session's tab, when it reports one.
    public let tabID: String?
    /// Snapshot generation the last observation was taken at.
    public let observationVersion: Int64?
    public let observedAt: Date?
    /// Elements the last observation described.
    public let observedElementCount: Int

    public var id: String { sessionID }

    public init(sessionID: String, url: String, title: String, tabID: String? = nil,
                observationVersion: Int64? = nil, observedAt: Date? = nil,
                observedElementCount: Int = 0) {
        self.sessionID = sessionID
        self.url = url
        self.title = title
        self.tabID = tabID
        self.observationVersion = observationVersion
        self.observedAt = observedAt
        self.observedElementCount = observedElementCount
    }
}

public struct GetBrowserCaptureRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    /// Ask the host to write the image to a file instead of returning it inline.
    public let savePath: String?

    public init(sessionID: String, savePath: String? = nil) {
        self.sessionID = sessionID
        self.savePath = savePath
    }
}

/// A page image taken from the Agent's browser. Exactly one side is populated:
/// the host either returns the bytes or writes them to a path.
public struct BrowserCapture: Codable, Sendable, Equatable {
    public let sessionID: String
    public let base64PNG: String?
    public let savedPath: String?

    public init(sessionID: String, base64PNG: String? = nil, savedPath: String? = nil) {
        self.sessionID = sessionID
        self.base64PNG = base64PNG
        self.savedPath = savedPath
    }
}
