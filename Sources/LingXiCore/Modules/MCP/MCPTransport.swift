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
    public static let modern = "2026-07-28"
    public static let legacy = "2025-11-25"
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
    public func list() -> [MCPServerConfiguration] { servers.values.sorted { $0.alias < $1.alias } }
    public func server(_ id: MCPServerID) -> MCPServerConfiguration? { servers[id] }
    public func setEnabled(_ id: MCPServerID, enabled: Bool) { guard let value = servers[id] else { return }; servers[id] = MCPServerConfiguration(serverID: value.serverID, alias: value.alias, transport: value.transport, command: value.command, arguments: value.arguments, endpoint: value.endpoint, protocolPreference: value.protocolPreference, enabled: enabled, auth: value.auth, environment: value.environment, timeoutSeconds: value.timeoutSeconds) }
}

public actor MCPConnectionManager: MCPToolInvoker {
    private var invokers: [MCPServerID: any MCPToolInvoker] = [:]
    public init() {}
    public func register(_ invoker: any MCPToolInvoker, for serverID: MCPServerID) { invokers[serverID] = invoker }
    public func call(serverID: MCPServerID, toolName: String, arguments: String) async throws -> String {
        guard let invoker = invokers[serverID] else { throw CoreError(code: .mcpServerUnavailable, message: "MCP server unavailable: \(serverID.rawValue)") }
        return try await invoker.call(serverID: serverID, toolName: toolName, arguments: arguments)
    }
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
        var cursor: String?
        var seen = Set<String>()
        var result: [MCPDiscoveredTool] = []
        for _ in 0..<100 {
            var parameters: [String: Any] = [:]
            if let cursor { parameters["cursor"] = cursor }
            let response = try await post(method: "tools/list", parameters: parameters)
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

    private func post(method: String, name: String? = nil, parameters: [String: Any]) async throws -> (data: Data, contentType: String) {
        guard configuration.enabled else { throw CoreError(code: .mcpServerUnavailable, message: "MCP server disabled") }
        guard let endpoint = configuration.endpoint else { throw CoreError(code: .mcpServerUnavailable, message: "MCP HTTP endpoint missing") }
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.timeoutInterval = configuration.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue(method, forHTTPHeaderField: "Mcp-Method")
        if let name { request.setValue(name, forHTTPHeaderField: "Mcp-Name") }
        try applyAuth(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": UUID().uuidString, "method": method, "params": parameters], options: [.sortedKeys])
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError where error.code == .timedOut { throw CoreError(code: .commandTimedOut, message: "MCP HTTP \(method) timed out") }
        catch { throw CoreError(code: .mcpServerUnavailable, message: "MCP HTTP \(method) transport failed") }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw CoreError(code: .mcpServerUnavailable, message: "MCP HTTP \(method) failed") }
        return (data, http.value(forHTTPHeaderField: "Content-Type") ?? "application/json")
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
        guard configuration.enabled else { throw CoreError(code: .mcpServerUnavailable, message: "MCP server disabled") }
        guard let command = configuration.command, command.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: command) else { throw CoreError(code: .mcpServerUnavailable, message: "MCP stdio executable unavailable") }
        let payload = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": UUID().uuidString, "method": method, "params": parameters], options: [.sortedKeys])
        var environment = EnvironmentSanitizer.sanitized()
        for (name, ref) in configuration.environment { if let value = try resolver.resolve(ref) { environment[name] = value } }
        let result = try await runToolProcess(
            invocation: ToolProcessInvocation(executable: command, arguments: configuration.arguments),
            cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            environment: environment,
            timeoutMilliseconds: Int(configuration.timeoutSeconds * 1_000),
            standardInput: String(decoding: payload, as: UTF8.self) + "\n"
        )
        guard result.exitCode == 0 else { throw CoreError(code: .mcpServerUnavailable, message: "MCP stdio exited \(result.exitCode)") }
        return Data(result.stdout.utf8)
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
        let decoded = try JSONDecoder().decode(Response.self, from: try MCPWire.jsonData(data, contentType: contentType))
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
