import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingXiProtocol

/// The cheapest real turn that can tell a plan-ineligible model from a working one.
///
/// `/v1/models` cannot: an endpoint happily lists models the account's plan excludes, so a picker
/// built from it offers entries that fail the first time they are used — and the failure arrives as
/// an opaque 403 mid-conversation. A streaming one-token request is the smallest call that reaches
/// model routing, and its status answers the only question a settings screen needs to ask.
public enum ProviderModelAvailabilityProbe {

    /// The verdict rule. Only "this model is not yours" counts as a failure.
    ///
    /// A rate limit is the strongest evidence a model *is* reachable: throttling is applied after the
    /// request has been routed to it, so a name that does not resolve never reaches a 429. Reading 429
    /// as a failure would mark every working model on a busy account broken, which is worse than the
    /// bug this probe exists to catch. A 401, a dead gateway or a timeout says nothing about the
    /// model and must not be recorded as one.
    public static func verdict(statusCode: Int, body: String) -> ModelAvailability {
        if (200..<300).contains(statusCode) { return .available }
        if statusCode == 429 { return .available }
        switch ProviderErrorClassifier.classify(statusCode: statusCode, body: body).category {
        case .accessForbidden, .modelNotFound: return .unavailable
        default: return .unknown
        }
    }

    static func wireProtocol(forAdapter adapter: String) -> ModelWireProtocol {
        switch adapter {
        case "anthropic-messages": return .anthropicMessages
        case "openai-responses": return .responses
        default: return .chatCompletions
        }
    }

    /// A one-token streaming turn. `ProviderConfig` supplies the endpoint so the "do not append
    /// /chat/completions twice" rule stays in one place.
    static func body(modelID: String, wireProtocol: ModelWireProtocol) -> Data? {
        let message: [String: Any] = ["role": "user", "content": "Hi"]
        var payload: [String: Any] = ["model": modelID, "stream": true]
        switch wireProtocol {
        case .chatCompletions:
            payload["messages"] = [message]; payload["max_tokens"] = 1
        case .anthropicMessages:
            payload["messages"] = [message]; payload["max_tokens"] = 1
        case .responses:
            payload["input"] = [message]; payload["max_output_tokens"] = 1
        }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    public static func request(baseURL: String, adapter: String, modelID: String,
                               apiKeyHeader: String?, credential: String?,
                               headers: [String: String]) -> URLRequest? {
        let wire = wireProtocol(forAdapter: adapter)
        guard let root = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let config = ProviderConfig(baseURL: root, authentication: .none, model: modelID,
                                    wireProtocol: wire, parallelToolCalling: nil)
        let url: URL
        switch wire {
        case .chatCompletions: url = config.chatCompletionsURL
        case .responses: url = config.responsesURL
        case .anthropicMessages: url = config.anthropicMessagesURL
        }
        guard let payload = body(modelID: modelID, wireProtocol: wire) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(ProductVersion.userAgent) (model probe)", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers where !name.isEmpty {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // The same credential attachment the connection test uses, so a probe that passes cannot be
        // passing on an auth shape the real request would have had rejected.
        ProviderConnectivityProbe.applyCredential(to: &request, adapter: adapter,
                                                 apiKeyHeader: apiKeyHeader, credential: credential)
        return request
    }

    public static func probe(baseURL: String, adapter: String, modelID: String,
                             apiKeyHeader: String?, credential: String?,
                             headers: [String: String] = [:],
                             httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil) async
    -> ModelAvailability {
        guard let request = request(baseURL: baseURL, adapter: adapter, modelID: modelID,
                                    apiKeyHeader: apiKeyHeader, credential: credential, headers: headers)
        else { return .unknown }
        do {
            let (data, response): (Data, URLResponse)
            if let httpClient {
                (data, response) = try await httpClient(request)
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return .unknown }
            return verdict(statusCode: status, body: String(decoding: data, as: UTF8.self))
        } catch {
            // A transport failure is not a statement about the model.
            return .unknown
        }
    }
}
