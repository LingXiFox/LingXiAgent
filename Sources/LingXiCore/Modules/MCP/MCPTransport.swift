import Foundation
import LingXiProtocol
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MCPTransportKind: String, Sendable, Codable { case stdio, streamableHTTP }
public enum MCPProtocolPreference: String, Sendable, Codable { case auto, modern, legacy }

public struct SecretRef: Sendable, Equatable, Codable { public let identifier: String; public init(_ identifier: String) { self.identifier = identifier } }
public protocol SecretResolver: Sendable { func resolve(_ ref: SecretRef) throws -> String? }
public struct EnvironmentSecretResolver: SecretResolver {
    private let values: [String: String]
    public init(_ values: [String: String]) { self.values = values }
    public func resolve(_ ref: SecretRef) throws -> String? { values[ref.identifier] }
}
public struct InMemorySecretResolver: SecretResolver {
    private let values: [String: String]
    public init(_ values: [String: String] = [:]) { self.values = values }
    public func resolve(_ ref: SecretRef) throws -> String? { values[ref.identifier] }
}

public enum MCPAuthentication: Sendable, Equatable, Codable {
    case none
    case bearer(SecretRef)
    case header(name: String, value: SecretRef)
}
public struct MCPServerConfiguration: Sendable, Equatable, Codable {
    public let serverID: MCPServerID
    public let alias: String
    public let transport: MCPTransportKind
    public let command: String?
    public let arguments: [String]
    public let endpoint: URL?
    public let protocolPreference: MCPProtocolPreference
    public let enabled: Bool
    public let auth: MCPAuthentication
    /// Target names only. Values must originate from SecretResolver, never persistence.
    public let environment: [String: SecretRef]
    public let timeoutSeconds: Double
    public init(serverID: MCPServerID, alias: String, transport: MCPTransportKind, command: String? = nil, arguments: [String] = [], endpoint: URL? = nil, protocolPreference: MCPProtocolPreference = .auto, enabled: Bool = true, auth: MCPAuthentication = .none, environment: [String: SecretRef] = [:], timeoutSeconds: Double = 60) { self.serverID = serverID; self.alias = alias; self.transport = transport; self.command = command; self.arguments = arguments; self.endpoint = endpoint; self.protocolPreference = protocolPreference; self.enabled = enabled; self.auth = auth; self.environment = environment; self.timeoutSeconds = timeoutSeconds }
}

public enum MCPProtocolVersionNegotiator {
    public static let modern = "2024-11-05"
    public static let legacy = "2024-10-07"
    public static func select(preference: MCPProtocolPreference, supportsModern: Bool, supportsLegacy: Bool) throws -> MCPProtocolEra {
        switch preference {
        case .modern where supportsModern: return .modern
        case .legacy where supportsLegacy: return .legacy
        case .auto where supportsModern: return .modern
        case .auto where supportsLegacy: return .legacy
        default: throw CoreError(code: .mcpProtocolUnsupported, message: "MCP protocol version unsupported")
        }
    }
}

public actor MCPServerRegistry {
    private var servers: [MCPServerID: MCPServerConfiguration] = [:]
    public init(_ configurations: [MCPServerConfiguration] = []) { servers = Dictionary(uniqueKeysWithValues: configurations.map { ($0.serverID, $0) }) }
    public func register(_ configuration: MCPServerConfiguration) { servers[configuration.serverID] = configuration }
    public func list() -> [MCPServerConfiguration] { servers.values.sorted { $0.alias < $1.alias } }
    public func server(_ id: MCPServerID) -> MCPServerConfiguration? { servers[id] }
    public func setEnabled(_ id: MCPServerID, enabled: Bool) { guard let value = servers[id] else { return }; servers[id] = MCPServerConfiguration(serverID: value.serverID, alias: value.alias, transport: value.transport, command: value.command, arguments: value.arguments, endpoint: value.endpoint, protocolPreference: value.protocolPreference, enabled: enabled, auth: value.auth, environment: value.environment, timeoutSeconds: value.timeoutSeconds) }
    public func replace(_ configurations: [MCPServerConfiguration]) { servers = Dictionary(uniqueKeysWithValues: configurations.map { ($0.serverID, $0) }) }
}

public actor MCPConnectionManager: MCPToolInvoker {
    public enum Health: String, Sendable, Codable { case healthy, degraded, unavailable }
    private var invokers: [MCPServerID: any MCPToolInvoker] = [:]
    private var health: [MCPServerID: Health] = [:]
    public init() {}
    public func register(_ invoker: any MCPToolInvoker, for serverID: MCPServerID) { invokers[serverID] = invoker; health[serverID] = .healthy }
    public func unregister(_ serverID: MCPServerID) { invokers.removeValue(forKey: serverID); health.removeValue(forKey: serverID) }
    public func health(for serverID: MCPServerID) -> Health { health[serverID] ?? .unavailable }
    public func call(serverID: MCPServerID, toolName: String, arguments: String) async throws -> String {
        guard let invoker = invokers[serverID] else { throw CoreError(code: .mcpServerUnavailable, message: "MCP server unavailable: \(serverID.rawValue)") }
        do {
            let result = try await invoker.call(serverID: serverID, toolName: toolName, arguments: arguments)
            health[serverID] = .healthy
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            health[serverID] = .degraded
            throw error
        }
    }
    public func shutdown() { invokers.removeAll(); health.removeAll() }
}

/// Minimal Streamable HTTP JSON-RPC transport. It deliberately does not implement deprecated HTTP+SSE.
public struct MCPStreamableHTTPTransport: MCPToolInvoker {
    public let configuration: MCPServerConfiguration
    private let resolver: any SecretResolver
    private let session: URLSession
    public init(configuration: MCPServerConfiguration, resolver: any SecretResolver = InMemorySecretResolver(), session: URLSession = .shared) { self.configuration = configuration; self.resolver = resolver; self.session = session }
    public func call(serverID: MCPServerID, toolName: String, arguments: String) async throws -> String {
        let parameters = try JSONSerialization.jsonObject(with: Data(arguments.utf8))
        let response = try await post(method: "tools/call", name: toolName, parameters: ["name": toolName, "arguments": parameters])
        return try MCPWire.resultText(response.data, contentType: response.contentType)
    }

    /// tools/list stays outside the provider tool set; callers atomically install this completed generation into L3.
    public func listTools() async throws -> [MCPDiscoveredTool] {
        var sessionID: String?
        let initParams: [String: Any] = [
            "protocolVersion": protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "lingxiagent", "version": "0.1.0"]
        ]
        if let initResp = try? await post(method: "initialize", parameters: initParams) {
            sessionID = initResp.sessionID
            _ = try? await post(method: "notifications/initialized", parameters: [:], sessionID: sessionID)
        }

        var cursor: String?
        var seen = Set<String>()
        var result: [MCPDiscoveredTool] = []
        for _ in 0..<100 {
            var parameters: [String: Any] = [:]
            if let cursor { parameters["cursor"] = cursor }
            let response = try await post(method: "tools/list", parameters: parameters, sessionID: sessionID)
            let page = try MCPToolDiscovery.decode(response.data, contentType: response.contentType, configuration: configuration)
            for tool in page.tools {
                guard seen.insert(tool.entry.upstreamName).inserted else { throw CoreError(code: .mcpDiscoveryLimitExceeded, message: "Duplicate MCP tool name: \(tool.entry.upstreamName)") }
                result.append(tool)
            }
            guard let next = page.nextCursor, !next.isEmpty else { return result }
            guard next != cursor else { throw CoreError(code: .mcpDiscoveryLimitExceeded, message: "MCP tools/list cursor loop") }
            cursor = next
        }
        throw CoreError(code: .mcpDiscoveryLimitExceeded, message: "MCP tools/list exceeded page limit")
    }

    public func get() async throws -> Int {
        guard configuration.enabled else { throw CoreError(code: .mcpServerUnavailable, message: "MCP server disabled") }
        guard let endpoint = configuration.endpoint else { throw CoreError(code: .mcpServerUnavailable, message: "MCP HTTP endpoint missing") }
        var request = URLRequest(url: endpoint); request.httpMethod = "GET"; request.timeoutInterval = configuration.timeoutSeconds
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        try applyAuth(to: &request)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CoreError(code: .mcpServerUnavailable, message: "MCP GET failed") }
        return http.statusCode
    }

    private func post(method: String, name: String? = nil, parameters: [String: Any], sessionID: String? = nil) async throws -> (data: Data, contentType: String, sessionID: String?) {
        guard configuration.enabled else { throw CoreError(code: .mcpServerUnavailable, message: "MCP server disabled") }
        guard let endpoint = configuration.endpoint else { throw CoreError(code: .mcpServerUnavailable, message: "MCP HTTP endpoint missing") }
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.timeoutInterval = configuration.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue(method, forHTTPHeaderField: "Mcp-Method")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let name { request.setValue(name, forHTTPHeaderField: "Mcp-Name") }
        try applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": UUID().uuidString, "method": method, "params": parameters], options: [.sortedKeys])
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
         catch is CancellationError { throw CancellationError() }
         catch let error as URLError where error.code == .timedOut { throw CoreError(code: .commandTimedOut, message: "MCP HTTP \(method) timed out") }
        catch { throw CoreError(code: .mcpServerUnavailable, message: "MCP HTTP \(method) transport failed") }
        guard let http = response as? HTTPURLResponse else {
            throw CoreError(code: .mcpServerUnavailable, message: "MCP HTTP \(method) failed")
        }
        if !(200..<300).contains(http.statusCode) {
            // debug
            // print("MCP HTTP \(method) debug: status=\(http.statusCode), body=\(String(decoding: data, as: UTF8.self))")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            let auth = http.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
            if auth.lowercased().contains("oauth") || auth.lowercased().contains("bearer") {
                throw CoreError(code: .permissionDenied, message: "OAuth authorization required (HTTP \(http.statusCode))")
            }
            throw CoreError(code: .permissionDenied, message: "Authentication required (HTTP \(http.statusCode))")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(decoding: data, as: UTF8.self)
            throw CoreError(code: .mcpServerUnavailable, message: "MCP HTTP \(method) failed (HTTP \(http.statusCode)): \(bodyStr.prefix(200))")
        }
        let respSessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") ?? sessionID
        return (data, http.value(forHTTPHeaderField: "Content-Type") ?? "application/json", respSessionID)
    }
    private func applyAuth(to request: inout URLRequest) throws {
        switch configuration.auth {
        case .none: break
        case let .bearer(ref): if let secret = try resolver.resolve(ref) { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        case let .header(name, ref): if let secret = try resolver.resolve(ref) { request.setValue(secret, forHTTPHeaderField: name) }
        }
    }
    private var protocolVersion: String { configuration.protocolPreference == .legacy ? MCPProtocolVersionNegotiator.legacy : MCPProtocolVersionNegotiator.modern }

}

/// stdio is command + argv only and receives a sanitized explicit environment.
public struct MCPStdioTransport: MCPToolInvoker {
    public let configuration: MCPServerConfiguration
    private let resolver: any SecretResolver
    public init(configuration: MCPServerConfiguration, resolver: any SecretResolver = InMemorySecretResolver()) { self.configuration = configuration; self.resolver = resolver }
    public func call(serverID: MCPServerID, toolName: String, arguments: String) async throws -> String {
        let parameters = try JSONSerialization.jsonObject(with: Data(arguments.utf8))
        return try MCPWire.resultText(await request(method: "tools/call", parameters: ["name": toolName, "arguments": parameters]))
    }
    public func listTools() async throws -> [MCPDiscoveredTool] {
        var cursor: String?
        var seen = Set<String>()
        var result: [MCPDiscoveredTool] = []
        for _ in 0..<100 {
            var parameters: [String: Any] = [:]
            if let cursor { parameters["cursor"] = cursor }
            let page = try MCPToolDiscovery.decode(await request(method: "tools/list", parameters: parameters), configuration: configuration)
            for tool in page.tools {
                guard seen.insert(tool.entry.upstreamName).inserted else { throw CoreError(code: .mcpDiscoveryLimitExceeded, message: "Duplicate MCP tool name: \(tool.entry.upstreamName)") }
                result.append(tool)
            }
            guard let next = page.nextCursor, !next.isEmpty else { return result }
            guard next != cursor else { throw CoreError(code: .mcpDiscoveryLimitExceeded, message: "MCP tools/list cursor loop") }
            cursor = next
        }
        throw CoreError(code: .mcpDiscoveryLimitExceeded, message: "MCP tools/list exceeded page limit")
    }
    private func request(method: String, parameters: [String: Any]) async throws -> Data {
        try Task.checkCancellation()
        guard configuration.enabled else { throw CoreError(code: .mcpServerUnavailable, message: "MCP server disabled") }
        guard let command = configuration.command, command.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: command) else { throw CoreError(code: .mcpServerUnavailable, message: "MCP stdio executable unavailable") }
        var environment = EnvironmentSanitizer.sanitized()
        for (name, ref) in configuration.environment { if let value = try resolver.resolve(ref) { environment[name] = value } }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = configuration.arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // Server diagnostics must never fill an unread pipe or enter the JSON-RPC stream.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CoreError(code: .mcpServerUnavailable, message: "Failed to launch MCP stdio process: \(error.localizedDescription)")
        }

        let stdinHandle = stdinPipe.fileHandleForWriting
        let stdoutHandle = stdoutPipe.fileHandleForReading
        try stdoutPipe.fileHandleForWriting.close()
        let timeoutSeconds = configuration.timeoutSeconds > 0 ? configuration.timeoutSeconds : 30.0
        let reqId = UUID().uuidString

        let initReq: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "init-1",
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "lingxiagent", "version": "0.1.0"]
            ]
        ]
        let initData = try JSONSerialization.data(withJSONObject: initReq)
        let notifyReq: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": [String: Any]()
        ]
        let notifyData = try JSONSerialization.data(withJSONObject: notifyReq)
        let targetReq: [String: Any] = [
            "jsonrpc": "2.0",
            "id": reqId,
            "method": method,
            "params": parameters
        ]
        let targetReqData = try JSONSerialization.data(withJSONObject: targetReq)

        let startTime = ContinuousClock().now
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }

        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(timeoutSeconds)) }
            catch { return }
            continuation.finish()
        }
        defer {
            watchdog.cancel()
            stdoutHandle.readabilityHandler = nil
            continuation.finish()
            try? stdinHandle.close()
            if process.isRunning {
                process.terminate()
            }
        }

        try stdinHandle.write(contentsOf: initData)
        try stdinHandle.write(contentsOf: Data("\n".utf8))

        var buffer = Data()
        var initCompleted = false
        var targetResultData: Data?

        for await chunk in chunks {
            try Task.checkCancellation()
            buffer.append(chunk)
            guard buffer.count <= 8 * 1_024 * 1_024 else {
                throw CoreError(code: .mcpDiscoveryLimitExceeded, message: "MCP stdio response exceeded 8 MiB")
            }

            while let newlineRange = buffer.range(of: Data("\n".utf8)) {
                let lineData = buffer.subdata(in: 0..<newlineRange.lowerBound)
                buffer.removeSubrange(0..<newlineRange.upperBound)

                guard !lineData.isEmpty else { continue }
                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }

                let msgId = json["id"] as? String
                let numId = json["id"] as? Int

                if !initCompleted && (msgId == "init-1" || numId == 1) {
                    initCompleted = true
                    try stdinHandle.write(contentsOf: notifyData)
                    try stdinHandle.write(contentsOf: Data("\n".utf8))

                    try stdinHandle.write(contentsOf: targetReqData)
                    try stdinHandle.write(contentsOf: Data("\n".utf8))
                } else if msgId == reqId {
                    if let err = json["error"] as? [String: Any], let errMsg = err["message"] as? String {
                        if errMsg.lowercased().contains("credential") || errMsg.lowercased().contains("accesskey") || errMsg.lowercased().contains("unauthorized") || errMsg.lowercased().contains("auth") {
                            throw CoreError(code: .permissionDenied, message: "Authentication required: \(errMsg)")
                        } else {
                            throw CoreError(code: .toolExecutionFailed, message: "MCP error: \(errMsg)")
                        }
                    }
                    targetResultData = lineData
                    break
                }
            }
            if targetResultData != nil { break }
        }

        try Task.checkCancellation()

        guard let finalData = targetResultData else {
            let elapsed = ContinuousClock().now - startTime
            if elapsed >= .seconds(timeoutSeconds) {
                throw CoreError(code: .commandTimedOut, message: "MCP stdio \(method) timed out")
            }
            throw CoreError(code: .mcpServerUnavailable, message: "MCP stdio did not return a response for \(method)")
        }
        return finalData
    }
}

private enum MCPToolDiscovery {
    struct Page { let tools: [MCPDiscoveredTool]; let nextCursor: String? }
    private struct Response: Decodable {
        struct Result: Decodable { let tools: [Tool]; let nextCursor: String? }
        struct Tool: Decodable { let name: String; let title: String?; let description: String?; let inputSchema: JSONValue; let annotations: MCPToolAnnotations? }
        let result: Result
    }

    static func decode(_ data: Data, contentType: String = "application/json", configuration: MCPServerConfiguration) throws -> Page {
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: try MCPWire.jsonData(data, contentType: contentType))
        } catch {
            let sample = String(decoding: data.prefix(500), as: UTF8.self)
            throw CoreError(code: .mcpServerUnavailable, message: "MCP decode error: \(error), sample: \(sample)")
        }
        return try Page(tools: decoded.result.tools.map { tool in
            let encoded = try JSONEncoder().encode(tool.inputSchema)
            let toolID = ToolID("\(configuration.serverID.rawValue)::\(tool.name)")
            return MCPDiscoveredTool(
                entry: MCPToolCatalogEntry(
                    toolID: toolID,
                    serverID: configuration.serverID,
                    serverAlias: configuration.alias,
                    upstreamName: tool.name,
                    title: tool.title ?? tool.name,
                    shortDescription: String((tool.description ?? tool.name).prefix(512)),
                    tags: [],
                    annotations: tool.annotations ?? MCPToolAnnotations(),
                    schemaHash: sha256Hex(String(decoding: encoded, as: UTF8.self)),
                    era: .modern,
                    available: true,
                    stale: false,
                    cacheScope: .public,
                    authContextID: nil,
                    lastSeen: .now
                ),
                inputSchema: tool.inputSchema
            )
        }, nextCursor: decoded.result.nextCursor)
    }
}

private enum MCPWire {
    static func resultText(_ data: Data, contentType: String = "application/json") throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: jsonData(data, contentType: contentType)) as? [String: Any] else { throw CoreError(code: .mcpServerUnavailable, message: "Malformed MCP response") }
        if object["error"] != nil { throw CoreError(code: .toolExecutionFailed, message: "MCP tool returned an error") }
        let result = object["result"] as? [String: Any] ?? [:]
        if let structured = result["structuredContent"] { return String(decoding: try JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]), as: UTF8.self) }
        if let content = result["content"] as? [[String: Any]] { return content.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
    }

    static func jsonData(_ data: Data, contentType: String) throws -> Data {
        guard contentType.lowercased().contains("text/event-stream") else { return data }
        let events = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespaces)
            return text.hasPrefix("data:") ? String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces) : nil
        }
        guard let final = events.last(where: { $0 != "[DONE]" }) else { throw CoreError(code: .mcpServerUnavailable, message: "Malformed MCP SSE response") }
        return Data(final.utf8)
    }
}
