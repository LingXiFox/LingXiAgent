import Foundation
import LingXiProtocol

/// Runtime driver for OpenAI Responses API protocol (`/responses`).
public struct OpenAIResponsesDriver: InferenceProtocolDriver {
    public let protocolIdentifier: String = "openaiResponses"

    public init() {}

    public func stream(
        _ request: ModelRequest,
        context: ProtocolDriverContext
    ) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let auth: ProviderAuthentication = {
            guard let cred = context.credential, !cred.isEmpty else { return .none }
            switch context.product.authStrategy {
            case "header_api_key":
                return .header(name: "api-key", value: cred)
            case "apiKeyHeader":
                return .header(name: "x-api-key", value: cred)
            case "none":
                return .none
            default:
                return .bearer(cred)
            }
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

        let headers = context.binding.defaultHeaders ?? [:]

        let config = ProviderConfig(
            baseURL: endpointURL,
            authentication: auth,
            model: request.model.rawValue,
            wireProtocol: .responses,
            diagnosticsEnabled: context.diagnosticsEnabled,
            performanceDiagnosticsEnabled: context.performanceDiagnosticsEnabled,
            maxOutputTokens: nil,
            requiredHeaders: headers
        )

        let provider: OpenAIResponsesProvider
        if let transport = context.transport {
            provider = OpenAIResponsesProvider(config: config, transport: transport)
        } else {
            provider = OpenAIResponsesProvider(config: config)
        }

        return try await provider.stream(request)
    }
}
