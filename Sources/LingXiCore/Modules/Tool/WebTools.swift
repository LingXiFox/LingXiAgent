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
    let raw: Bool?
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
    var rawURL = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    // GitHub blob URL 智能转 raw 源代码地址，提升代码抓取体验
    if rawURL.contains("github.com/") && rawURL.contains("/blob/") {
        rawURL = rawURL
            .replacingOccurrences(of: "https://github.com/", with: "https://raw.githubusercontent.com/")
            .replacingOccurrences(of: "/blob/", with: "/")
    }

    guard let url = URL(string: rawURL), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
        throw CoreError(code: .toolArgumentInvalid, message: "Web URL 必须使用 HTTPS 或 HTTP")
    }
    if scheme == "http" && !(url.host == "127.0.0.1" || url.host == "localhost" || url.host == "::1") {
        throw CoreError(code: .toolArgumentInvalid, message: "非 loopback Web URL 必须使用 HTTPS")
    }
    return url
}

// MARK: - HTML to Markdown Cleaner
enum WebHTMLCleaner {
    static func clean(_ html: String) -> (title: String?, markdown: String) {
        var text = html

        // 1. 提取 Title
        var title: String? = nil
        if let titleRange = text.range(of: "(?i)<title[^>]*>([\\s\\S]*?)</title>", options: .regularExpression) {
            let rawTitle = String(text[titleRange])
            title = rawTitle.replacingOccurrences(of: "(?i)<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. 剥离无意义脚本、样式、导航、页脚等噪声
        let noisePatterns = [
            "(?i)<script[\\s\\S]*?</script>",
            "(?i)<style[\\s\\S]*?</style>",
            "(?i)<noscript[\\s\\S]*?</noscript>",
            "(?i)<svg[\\s\\S]*?</svg>",
            "(?i)<iframe[\\s\\S]*?</iframe>",
            "(?i)<header[\\s\\S]*?</header>",
            "(?i)<footer[\\s\\S]*?</footer>",
            "(?i)<nav[\\s\\S]*?</nav>"
        ]
        for p in noisePatterns {
            text = text.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }

        // 3. 结构标签转换为 Markdown 语义格式
        text = text.replacingOccurrences(of: "(?i)<h1[^>]*>([\\s\\S]*?)</h1>", with: "\n\n# $1\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<h2[^>]*>([\\s\\S]*?)</h2>", with: "\n\n## $1\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<h3[^>]*>([\\s\\S]*?)</h3>", with: "\n\n### $1\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<h4[^>]*>([\\s\\S]*?)</h4>", with: "\n\n#### $1\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<li[^>]*>([\\s\\S]*?)</li>", with: "\n- $1", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<pre[^>]*><code[^>]*>([\\s\\S]*?)</code></pre>", with: "\n```\n$1\n```\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<code[^>]*>([\\s\\S]*?)</code>", with: "`$1`", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<strong[^>]*>([\\s\\S]*?)</strong>", with: "**$1**", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<b[^>]*>([\\s\\S]*?)</b>", with: "**$1**", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<em[^>]*>([\\s\\S]*?)</em>", with: "*$1*", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<p[^>]*>([\\s\\S]*?)</p>", with: "\n\n$1\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)

        // 4. 移除剩余 HTML 标签
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        // 5. 解码常用 HTML 实体
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "\u{27}"), ("&apos;", "\u{27}"), ("&nbsp;", " "), ("&#x20;", " ")
        ]
        for (k, v) in entities {
            text = text.replacingOccurrences(of: k, with: v)
        }

        // 6. 整理空行与冗余空白
        let lines = text.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
        var cleanedLines: [String] = []
        var prevEmpty = false
        for line in lines {
            if line.isEmpty {
                if !prevEmpty { cleanedLines.append(""); prevEmpty = true }
            } else {
                cleanedLines.append(line)
                prevEmpty = false
            }
        }
        return (title, cleanedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public struct WebFetchTool: ToolExecutor {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public let definition = ToolDefinition(
        id: ToolID("web_fetch"),
        description: "Fetch and extract readable content from a web page or API URL (supports auto HTML-to-Markdown, JSON pretty-printing, and GitHub raw redirection).",
        inputSchema: ToolInputSchema(
            properties: [
                "url": ToolInputProperty(type: .string, description: "Target HTTPS/HTTP URL to fetch"),
                "max_bytes": ToolInputProperty(type: .integer, description: "Maximum content length limit (default: 65536)", minimum: 1, maximum: 262_144),
                "raw": ToolInputProperty(type: .boolean, description: "Whether to return unformatted raw content without HTML parsing")
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

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,application/json,text/plain;q=0.8,*/*;q=0.7", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CoreError(code: .toolExecutionFailed, message: "Web fetch 没有 HTTP 响应")
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let limit = min(max(1, input.maxBytes ?? 32_768), 262_144)

        let processedContent: String
        // 1. HTML 响应：自动清洗并转为极高可读性的 Markdown 正文 (除非显式要求 raw)
        let rawContent = String(decoding: data.prefix(limit), as: UTF8.self)
        if !(input.raw ?? false) && (contentType.contains("html") || rawContent.contains("<!DOCTYPE") || rawContent.contains("<html")) {
            let fullText = String(decoding: data, as: UTF8.self)
            let (_, markdown) = WebHTMLCleaner.clean(fullText)
            processedContent = String(markdown.prefix(limit))
        } else {
            processedContent = rawContent
        }

        var result: [String: Any] = [
            "url": url.absoluteString,
            "status": http.statusCode,
            "content": processedContent,
            "truncated": data.count > limit
        ]
        if !contentType.isEmpty {
            result["contentType"] = contentType
        }

        guard JSONSerialization.isValidJSONObject(result), let encoded = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else {
            throw CoreError(code: .toolExecutionFailed, message: "Web fetch 结果无法编码")
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}

public struct WebSearchTool: ToolExecutor {
    private let session: URLSession
    private let endpoint: URL?
    private let tavilyAPIKey: String?

    public init(session: URLSession = .shared, endpoint: URL? = nil, tavilyAPIKey: String? = nil) {
        self.session = session
        self.endpoint = endpoint
        self.tavilyAPIKey = tavilyAPIKey
    }

    public let definition = ToolDefinition(
        id: ToolID("web_search"),
        description: "Search the web and return structured snippets, titles, and URLs.",
        inputSchema: ToolInputSchema(
            properties: [
                "query": ToolInputProperty(type: .string, description: "Search query text"),
                "max_results": ToolInputProperty(type: .integer, description: "Maximum search results to return", minimum: 1, maximum: 10)
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

        // 1. 优先使用显式配置的 backend endpoint (如 SearXNG / 自建搜索端点)
        if let configured = endpoint {
            return try await executeConfiguredEndpoint(configured, query: query, maxResults: input.maxResults ?? 5)
        }

        // 2. 支持开箱即用的 Tavily 搜索服务 (若配置了 TAVILY_API_KEY)
        if let tavilyKey = tavilyAPIKey, !tavilyKey.isEmpty {
            return try await executeTavilySearch(apiKey: tavilyKey, query: query, maxResults: input.maxResults ?? 5)
        }

        // 3. 自动降级为零配置 DuckDuckGo 搜索，确保随时随地开箱即用
        if let ddgResult = try? await executeDuckDuckGoSearch(query: query, maxResults: input.maxResults ?? 5), !ddgResult.isEmpty {
            return ddgResult
        }

        // 4. 若无网络连接或无法访问公共搜索，输出友好提示
        return """
        [WebSearch Unavailable: No backend configured or offline]
        To configure a dedicated search provider, you can export either:
        1. LINGXI_WEB_SEARCH_ENDPOINT="https://your-search-api/search" (e.g. SearXNG)
        2. TAVILY_API_KEY="tvly-..." (for native AI-optimized web search)

        Tip: If you know the documentation or site URL, you can directly use `web_fetch` to fetch and read web pages!
        """
    }

    private func executeConfiguredEndpoint(_ base: URL, query: String, maxResults: Int) async throws -> String {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        let existingQueryItems = components?.queryItems ?? []
        components?.queryItems = existingQueryItems + [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(min(max(1, maxResults), 10)))
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
        let limit = min(max(1, maxResults), 10)
        let results: [[String: String]] = rawItems.prefix(limit).map { item in
            let title = String((item["title"] as? String ?? "").prefix(240))
            let snippet = String((item["snippet"] as? String ?? item["description"] as? String ?? "").prefix(600))
            let itemURL = item["url"] as? String ?? item["link"] as? String ?? ""
            return ["title": title, "snippet": snippet, "url": itemURL]
        }
        let output: [String: Any] = ["query": query, "total": results.count, "results": results]
        guard let encoded = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted]) else {
            throw CoreError(code: .toolExecutionFailed, message: "web_search 结果无法编码")
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private func executeTavilySearch(apiKey: String, query: String, maxResults: Int) async throws -> String {
        guard let url = URL(string: "https://api.tavily.com/search") else {
            throw CoreError(code: .toolExecutionFailed, message: "Tavily endpoint invalid")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "api_key": apiKey,
            "query": query,
            "max_results": min(max(1, maxResults), 10),
            "search_depth": "basic"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CoreError(code: .toolExecutionFailed, message: "Tavily search request failed")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            throw CoreError(code: .toolExecutionFailed, message: "Tavily response parsing failed")
        }
        var formatted = "Search Query: \(query)\n"
        formatted += "Results Found: \(results.count)\n\n"
        for (idx, item) in results.enumerated() {
            let title = item["title"] as? String ?? "No Title"
            let itemURL = item["url"] as? String ?? ""
            let content = item["content"] as? String ?? ""
            formatted += "\(idx + 1). [\(title)](\(itemURL))\n"
            formatted += "   \(content)\n\n"
        }
        return formatted
    }

    private func executeDuckDuckGoSearch(query: String, maxResults: Int) async throws -> String {
        guard let url = URL(string: "https://lite.duckduckgo.com/lite/") else { return "" }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)", forHTTPHeaderField: "User-Agent")

        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        request.httpBody = "q=\(encodedQuery)".data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            return ""
        }

        // Parse result-link and result-snippet from DuckDuckGo Lite HTML
        let linkPattern = try NSRegularExpression(pattern: #"href=['"]([^'"]+)['"][^>]*class=['"]result-link['"][^>]*>([^<]+)</a>"#, options: [.caseInsensitive])
        let snippetPattern = try NSRegularExpression(pattern: #"class=['"]result-snippet['"][^>]*>\s*([\s\S]*?)\s*</td>"#, options: [.caseInsensitive])

        let nsHTML = html as NSString
        let linkMatches = linkPattern.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length))
        let snippetMatches = snippetPattern.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length))

        let limit = min(max(1, maxResults), linkMatches.count)
        guard limit > 0 else { return "" }

        var formatted = "Search Query: \(query)\n"
        formatted += "Results Found: \(limit)\n\n"

        for i in 0..<limit {
            let linkMatch = linkMatches[i]
            let rawURL = nsHTML.substring(with: linkMatch.range(at: 1))
            let title = nsHTML.substring(with: linkMatch.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)

            var snippet = ""
            if i < snippetMatches.count {
                let rawSnippet = nsHTML.substring(with: snippetMatches[i].range(at: 1))
                // Strip simple HTML tags like <b> from snippet
                snippet = rawSnippet.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&#x27;", with: "'")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            formatted += "\(i + 1). [\(title)](\(rawURL))\n"
            if !snippet.isEmpty {
                formatted += "   \(snippet)\n\n"
            } else {
                formatted += "\n"
            }
        }

        return formatted
    }
}

