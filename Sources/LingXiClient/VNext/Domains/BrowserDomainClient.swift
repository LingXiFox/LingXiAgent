import Foundation
import LingXiProtocol

/// Read-only view of the browser sessions the Agent is driving.
public struct BrowserDomainClient: Sendable {
    private let transport: any ClientTransport

    public init(transport: any ClientTransport) {
        self.transport = transport
    }

    public func sessions() async throws -> [BrowserSessionStatus] {
        let resp = try await transport.getBrowserSessions(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    public func capture(sessionID: String, savePath: String? = nil) async throws -> BrowserCapture {
        let req = GetBrowserCaptureRequest(sessionID: sessionID, savePath: savePath)
        let resp = try await transport.getBrowserCapture(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }
}
