import Foundation
import LingXiProtocol

/// Runtime driver for Ollama native/local runtime protocol.
public struct OllamaNativeDriver: InferenceProtocolDriver {
    public let protocolIdentifier: String = "ollamaNative"

    public init() {}

    public func stream(
        _ request: ModelRequest,
        context: ProtocolDriverContext
    ) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let chatDriver = OpenAIChatDriver()
        return try await chatDriver.stream(request, context: context)
    }
}
