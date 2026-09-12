import Foundation
import LingXiProtocol

/// Runtime driver for Anthropic Messages protocol (`/v1/messages`).
public struct AnthropicMessagesDriver: InferenceProtocolDriver {
    public let protocolIdentifier: String = "anthropicMessages"

    public init() {}

    public func stream(
        _ request: ModelRequest,
        context: ProtocolDriverContext
    ) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let auth: ProviderAuthentication = {
            guard let cred = context.credential, !cred.isEmpty else { return .none }
            // Anthropic API uses x-api-key header; DeepSeek/Bailian compatible may use Bearer
            if context.product.authStrategy == "bearer" {
                return .bearer(cred)
            }
            return .header(name: "x-api-key", value: cred)
        }()

        let endpointURL: URL = {
            var urlString = context.binding.baseURL
            if !urlString.hasSuffix("/") && !context.binding.path.hasPrefix("/") {
                urlString += "/"
            }
            if !context.binding.path.isEmpty && !urlString.hasSuffix(context.binding.path) {
                urlString += context.binding.path
            }
            return URL(string: urlString) ?? URL(string: context.binding.baseURL) ?? URL(fileURLWithPath: "/")
        }()

        var headers = context.binding.defaultHeaders ?? [:]
        if headers["anthropic-version"] == nil {
            headers["anthropic-version"] = "2023-06-01"
        }

        let config = ProviderConfig(
            baseURL: endpointURL,
            authentication: auth,
            model: request.model.rawValue,
            wireProtocol: .anthropicMessages,
            diagnosticsEnabled: context.diagnosticsEnabled,
            performanceDiagnosticsEnabled: context.performanceDiagnosticsEnabled,
            maxOutputTokens: nil,
            requiredHeaders: headers
        )

        let provider: AnthropicMessagesProvider
        if let transport = context.transport {
            provider = AnthropicMessagesProvider(config: config, transport: transport)
        } else {
            provider = AnthropicMessagesProvider(config: config)
        }

        return try await provider.stream(request)
    }
}
