import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingXiProtocol

private struct WebSearchInput: Decodable {
    let query: String
    let maxResults: Int?
}

private struct WebFetchInput: Decodable {
    let url: String
    let maxBytes: Int?
}

private func webArguments<T: Decodable>(_ arguments: String, as type: T.Type) throws -> T {
    guard let data = arguments.data(using: .utf8) else {
        throw CoreError(code: .toolArgumentInvalid, message: "Web Tool 参数不是 UTF-8")
    }
    do {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    } catch {
        throw CoreError(code: .toolArgumentInvalid, message: "Web Tool 参数无效: \(error.localizedDescription)")
    }
}

private func webURL(_ raw: String) throws -> URL {
    guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
        throw CoreError(code: .toolArgumentInvalid, message: "Web URL 必须使用 HTTPS 或 HTTP")
    }
    if scheme == "http" && !(url.host == "127.0.0.1" || url.host == "localhost" || url.host == "::1") {
        throw CoreError(code: .toolArgumentInvalid, message: "非 loopback Web URL 必须使用 HTTPS")
    }
    return url
}

public struct WebFetchTool: ToolExecutor {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public let definition = ToolDefinition(
        id: ToolID("web_fetch"),
        description: "Fetch a bounded web page projection from an HTTPS URL.",
        inputSchema: ToolInputSchema(
            properties: [
                "url": ToolInputProperty(type: .string, description: "HTTPS URL"),
                "max_bytes": ToolInputProperty(type: .integer, description: "Maximum response bytes", minimum: 1, maximum: 32_768)
            ],
            required: ["url"]
        ),
        capability: ToolCapability(readOnly: true)
    )

    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        try webURL(webArguments(arguments, as: WebFetchInput.self).url).absoluteString
    }

    public func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind> {
        [.networkAccess]
    }

    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input = try webArguments(arguments, as: WebFetchInput.self)
        let url = try webURL(input.url)
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CoreError(code: .toolExecutionFailed, message: "Web fetch 没有 HTTP 响应")
        }
        let limit = min(max(1, input.maxBytes ?? 32_768), 32_768)
        let bounded = data.prefix(limit)
        let content = String(decoding: bounded, as: UTF8.self)
        let result: [String: Any] = [
            "url": url.absoluteString,
            "status": http.statusCode,
            "content": content,
            "truncated": data.count > limit
        ]
        guard JSONSerialization.isValidJSONObject(result), let encoded = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else {
            throw CoreError(code: .toolExecutionFailed, message: "Web fetch 结果无法编码")
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}

public struct WebSearchTool: ToolExecutor {
    private let session: URLSession
    private let endpoint: URL?

    public init(session: URLSession = .shared, endpoint: URL? = nil) {
        self.session = session
        self.endpoint = endpoint
    }

    public let definition = ToolDefinition(
        id: ToolID("web_search"),
        description: "Search the configured web backend and return bounded structured snippets.",
        inputSchema: ToolInputSchema(
            properties: [
                "query": ToolInputProperty(type: .string, description: "Search query"),
                "max_results": ToolInputProperty(type: .integer, description: "Maximum snippets", minimum: 1, maximum: 10)
            ],
            required: ["query"]
        ),
        capability: ToolCapability(readOnly: true)
    )

    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        let input = try webArguments(arguments, as: WebSearchInput.self)
        return "web_search:\(input.query)"
    }

    public func capabilities(for arguments: String, profile: ExecutionProfile) throws -> Set<ToolCapabilityKind> {
        [.networkAccess]
    }

    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let input = try webArguments(arguments, as: WebSearchInput.self)
        let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw CoreError(code: .toolArgumentInvalid, message: "web_search query 不能为空") }
        guard let configured = endpoint else {
            throw CoreError(code: .toolExecutionFailed, message: "web_search 未配置 backend")
        }
        let base = try webURL(configured.absoluteString)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        let existingQueryItems = components?.queryItems ?? []
        components?.queryItems = existingQueryItems + [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(min(max(1, input.maxResults ?? 5), 10)))
        ]
        guard let url = components?.url else { throw CoreError(code: .toolExecutionFailed, message: "web_search backend URL 无效") }
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 20))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CoreError(code: .toolExecutionFailed, message: "web_search backend 请求失败")
        }
        let object = try JSONSerialization.jsonObject(with: data)
        let rawItems: [[String: Any]]
        if let items = object as? [[String: Any]] { rawItems = items }
        else if let dict = object as? [String: Any], let items = (dict["results"] ?? dict["items"]) as? [[String: Any]] { rawItems = items }
        else { throw CoreError(code: .toolExecutionFailed, message: "web_search backend 返回格式无效") }
        let limit = min(max(1, input.maxResults ?? 5), 10)
        let results: [[String: String]] = rawItems.prefix(limit).map { item in
            let title = String((item["title"] as? String ?? "").prefix(240))
            let snippet = String((item["snippet"] as? String ?? item["description"] as? String ?? "").prefix(600))
            let url = item["url"] as? String ?? item["link"] as? String ?? ""
            return ["title": title, "snippet": snippet, "url": url]
        }
        let output: [String: Any] = ["query": query, "total": results.count, "results": results]
        guard let encoded = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) else {
            throw CoreError(code: .toolExecutionFailed, message: "web_search 结果无法编码")
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}
