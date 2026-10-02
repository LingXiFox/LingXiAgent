import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingXiProtocol

// MARK: - Provider Files APIs
//
// Only the two official endpoints whose Files API and file-reference request shape are
// documented are enabled. A relay or an OpenAI-compatible endpoint may or may not implement
// `/files`; guessing would turn a picked image into a failed upload, so those stay inline.

extension ResolvedModelEndpoint {
    /// The cache key a provider file id is stored under: ids are account- and endpoint-scoped.
    public var fileReferenceKey: String {
        "\(providerID)|\(accountID ?? "-")|\(baseURL?.absoluteString ?? "-")"
    }
}

enum ProviderFileUpload {
    /// multipart/form-data with plain fields and one file part.
    static func multipartRequest(url: URL, fields: [(String, String)], filename: String,
                                 mediaType: String, data: Data) -> URLRequest {
        let boundary = "lingxi-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (name, value) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        let safeName = filename.replacingOccurrences(of: "\"", with: "")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n")
        append("Content-Type: \(mediaType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// Sends the upload and returns the `id` field of the JSON reply.
    static func send(_ request: URLRequest, transport: any ProviderHTTPTransport, wire: ModelWireProtocol) async throws -> String {
        let response = try await transport.send(request, context: ProviderHTTPRequestContext(
            wireProtocol: wire, model: "files", executionID: nil, step: 0))
        let text = (try? await OpenAICompatibleProvider.collectText(response.body)) ?? ""
        guard (200..<300).contains(response.statusCode) else {
            throw CoreError(code: .provider, message: "Provider 文件上传失败：HTTP \(response.statusCode) \(text.prefix(200))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let id = json["id"] as? String, !id.isEmpty else {
            throw CoreError(code: .provider, message: "Provider 文件上传没有返回 id")
        }
        return id
    }
}

extension ProviderConfig {
    /// The same credentials and fixed headers a model request carries.
    func authorize(_ request: inout URLRequest) async throws {
        switch authentication {
        case .none: break
        case let .bearer(secret): request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        case let .header(name, value): request.setValue(value, forHTTPHeaderField: name)
        case .oauth: break
        }
        for (name, value) in requiredHeaders { request.setValue(value, forHTTPHeaderField: name) }
        if let (name, value) = try await resolveAuthHeader() { request.setValue(value, forHTTPHeaderField: name) }
    }

    var apiRoot: String { baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
}
