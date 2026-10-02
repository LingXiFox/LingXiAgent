import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingXiProtocol

/// A real reachability round trip against a provider endpoint.
///
/// Core runs it on the front end's behalf: a settings view never talks to a
/// provider itself. The request is the provider's own model listing, because
/// that is the cheapest call that proves both the network path and the
/// credential. Failures come back as what upstream said; the credential never
/// appears in a result or a message.
enum ProviderConnectivityProbe {

    struct Outcome: Sendable, Equatable {
        let latencyMs: Double
        /// Models the endpoint listed; 0 when the reply carried no list.
        let models: Int
    }

    private static let anthropicVersion = "2023-06-01"

    /// The model-listing URL for a configured base URL, per adapter.
    static func modelsURL(baseURL: String, adapter: String) -> URL? {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        while value.hasSuffix("/") { value.removeLast() }
        for suffix in ["/chat/completions", "/responses", "/completions", "/models"] where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
        }
        return URL(string: value + "/models")
    }

    static func request(baseURL: String, adapter: String, apiKeyHeader: String?,
                        credential: String?, headers: [String: String]) -> URLRequest? {
        guard let url = modelsURL(baseURL: baseURL, adapter: adapter) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(ProductVersion.userAgent) (provider test)", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers where !name.isEmpty {
            request.setValue(value, forHTTPHeaderField: name)
        }
        applyCredential(to: &request, adapter: adapter, apiKeyHeader: apiKeyHeader, credential: credential)
        return request
    }

    /// Attaches a credential the way this adapter expects it. Shared with
    /// ``ProviderModelAvailabilityProbe`` so there is only ever one answer to "how does this vendor
    /// want its key spelled" — a second implementation is how a probe starts succeeding on a request
    /// the real call would have had rejected.
    static func applyCredential(to request: inout URLRequest, adapter: String,
                                apiKeyHeader: String?, credential: String?) {
        guard let credential, !credential.isEmpty else { return }
        let custom = apiKeyHeader?.trimmingCharacters(in: .whitespaces)
        let headerName = (custom?.isEmpty == false) ? custom : nil
        if adapter == "anthropic-messages" {
            request.setValue(credential, forHTTPHeaderField: headerName ?? "x-api-key")
            if request.value(forHTTPHeaderField: "anthropic-version") == nil {
                request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
            }
        } else if let headerName, headerName.lowercased() != "authorization" {
            request.setValue(credential, forHTTPHeaderField: headerName)
        } else {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
    }

    static func probe(
        baseURL: String,
        adapter: String,
        apiKeyHeader: String? = nil,
        credential: String?,
        headers: [String: String] = [:],
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async throws -> Outcome {
        let clock = ContinuousClock()
        guard let request = request(baseURL: baseURL, adapter: adapter, apiKeyHeader: apiKeyHeader,
                                    credential: credential, headers: headers) else {
            throw CoreError(code: .toolArgumentInvalid, message: "Base URL 无效，无法测试连接")
        }
        let started = clock.now
        let data: Data
        let response: URLResponse
        do {
            if let httpClient {
                (data, response) = try await httpClient(request)
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
        } catch {
            throw CoreError(code: .provider, message: "无法连接：\(error.localizedDescription)")
        }
        let parts = started.duration(to: clock.now).components
        let elapsed = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
        guard let http = response as? HTTPURLResponse else {
            throw CoreError(code: .provider, message: "非 HTTP 响应")
        }
        guard (200...299).contains(http.statusCode) else {
            throw CoreError(code: .provider, message: "HTTP \(http.statusCode)")
        }
        return Outcome(latencyMs: elapsed, models: Self.modelIDs(in: data).count)
    }

    /// Model ids a listing endpoint carried.
    ///
    /// "OpenAI-compatible" describes the request dialect; the reply envelope does not follow it.
    /// Relays disagree on the container key and on whether an entry is an object or a bare id, so
    /// one permissive reader backs both the connectivity count and the add-model picker. They used
    /// to disagree: a relay answering `{"models":["a"]}` reported "1 model" in the connection test
    /// while the picker called the same endpoint empty.
    static func modelIDs(in data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let entries: [Any]
        if let array = object as? [Any] {
            entries = array
        } else if let dictionary = object as? [String: Any] {
            entries = ["data", "models", "modelsList", "results", "items"]
                .lazy.compactMap { dictionary[$0] as? [Any] }.first ?? []
        } else {
            entries = []
        }
        var ids: Set<String> = []
        for entry in entries {
            let raw: String?
            if let string = entry as? String {
                raw = string
            } else if let dictionary = entry as? [String: Any] {
                raw = ["id", "model", "name", "slug"]
                    .lazy.compactMap { dictionary[$0] as? String }.first
            } else {
                raw = nil
            }
            if let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                ids.insert(id)
            }
        }
        return ids.sorted()
    }
}
