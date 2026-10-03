#if os(macOS)
import Foundation
import LingXiPlatform

/// Application-facing IPC adapter. The handler belongs to the GUI, never Core.
public final class GUIAutomationIPC: @unchecked Sendable {
    private let socket: GUIAutomationSocket
    public init(path: String = GUIAutomationSocket.socketPath,
                handler: @escaping @Sendable (GUIAutomationRequest) async -> GUIAutomationResponse) throws {
        socket = try GUIAutomationSocket(path: path) { data in
            let response: GUIAutomationResponse
            do { response = await handler(try JSONDecoder().decode(GUIAutomationRequest.self, from: data)) }
            catch { response = GUIAutomationResponse(accepted: false, reason: "invalidCommand") }
            return (try? JSONEncoder().encode(response)) ?? Data()
        }
    }
    public func close() { socket.close() }
}
#endif
