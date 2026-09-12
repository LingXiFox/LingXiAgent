import Foundation
import LingXiProtocol

/// Runtime driver for Gemini API.
public struct GeminiNativeDriver: InferenceProtocolDriver {
    public let protocolIdentifier: String = "geminiNative"

    public init() {}

    public func stream(
        _ request: ModelRequest,
        context: ProtocolDriverContext
    ) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        // Fall back to OpenAIChatDriver for Gemini's OpenAI-compatible /v1beta/openai endpoints
        let chatDriver = OpenAIChatDriver()
        return try await chatDriver.stream(request, context: context)
    }
}
