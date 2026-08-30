import Foundation
import LingXiProtocol

/// Phase 12 architectural invariant: MCP schemas are only held by active leases.
public let MCP_FULL_SCHEMA_PERMANENT_RESIDENCY = "FORBIDDEN"

public struct MCPServerID: RawRepresentable, Sendable, Hashable, Codable { public let rawValue: String; public init(_ rawValue: String) { self.rawValue = rawValue }; public init(rawValue: String) { self.init(rawValue) } }
public struct AuthContextID: RawRepresentable, Sendable, Hashable, Codable { public let rawValue: String; public init(_ rawValue: String) { self.rawValue = rawValue }; public init(rawValue: String) { self.init(rawValue) } }
public enum MCPProtocolEra: String, Sendable, Codable { case modern, legacy }
public enum MCPCacheScope: String, Sendable, Codable { case `public`, `private` }
public enum MCPLeaseState: String, Sendable, Codable { case armed, used, expired, revoked }

public struct MCPToolAnnotations: Sendable, Equatable, Codable {
    public let readOnlyHint: Bool?
    public let destructiveHint: Bool?
    public let idempotentHint: Bool?
    public let openWorldHint: Bool?
    public init(readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil, idempotentHint: Bool? = nil, openWorldHint: Bool? = nil) { self.readOnlyHint = readOnlyHint; self.destructiveHint = destructiveHint; self.idempotentHint = idempotentHint; self.openWorldHint = openWorldHint }
}

/// L3 entry: metadata only. The full JSON Schema lives exclusively in MCPToolSchemaStore.
public struct MCPToolCatalogEntry: Sendable, Equatable, Codable {
    public let toolID: ToolID
    public let serverID: MCPServerID
    public let serverAlias: String
    public let upstreamName: String
    public let title: String
    public let shortDescription: String
    public let tags: [String]
    public let annotations: MCPToolAnnotations
    public let schemaHash: String
    public let era: MCPProtocolEra
    public var available: Bool
    public var stale: Bool
    public let cacheScope: MCPCacheScope
    public let authContextID: AuthContextID?
    public var lastSeen: Date
}

public struct MCPDiscoveredTool: Sendable {
    public let entry: MCPToolCatalogEntry
    public let inputSchema: JSONValue
    public init(entry: MCPToolCatalogEntry, inputSchema: JSONValue) { self.entry = entry; self.inputSchema = inputSchema }
}

public struct MCPToolSearchCandidate: Sendable, Equatable, Codable {
    public let toolID: ToolID
    public let displayName: String
    public let serverAlias: String
    public let shortDescription: String
    public let riskHint: String
    public let availability: String
    public let temperature: String
}

public struct MCPToolSchemaLease: Sendable, Equatable, Codable {
    public let leaseID: String
    public let sessionID: SessionID
    public let toolID: ToolID
    public let schemaHash: String
    public let providerName: String
    public let createdAt: Date
    public let expiresAt: Date
    public var state: MCPLeaseState
}

public enum MCPToolPagerError: Error, Sendable, Equatable {
    case missingTool, unavailable, schemaMissing, schemaChanged, schemaTooLarge, schemaBudgetExceeded, leaseMissing, leaseExpired, taskUnsupported
}

public protocol MCPToolInvoker: Sendable {
    func call(serverID: MCPServerID, toolName: String, arguments: String) async throws -> String
}

public actor MCPToolSchemaStore {
    private var values: [String: JSONValue] = [:]
    public init() {}
    public func put(_ schema: JSONValue, toolID: ToolID, hash: String) { values[key(toolID, hash)] = schema }
    public func schema(toolID: ToolID, hash: String) -> JSONValue? { values[key(toolID, hash)] }
    public func count() -> Int { values.count }
    public func bytes() -> Int { values.values.reduce(0) { $0 + ((try? JSONEncoder().encode($1).count) ?? 0) } }
    public func remove(toolID: ToolID) { values = values.filter { !$0.key.hasPrefix("\(toolID.rawValue)@") } }
    private func key(_ id: ToolID, _ hash: String) -> String { "\(id.rawValue)@\(hash)" }
}

public struct ProviderToolNameCodec: Sendable {
    public init() {}
    public func encode(serverAlias: String, upstreamName: String, toolID: ToolID) -> String {
        let base = (serverAlias + "_" + upstreamName).lowercased().map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
        return String(base.prefix(48)) + "_" + String(sha256Hex(toolID.rawValue).prefix(10))
    }
}

public actor MCPToolPager {
    private struct SessionState { var l1: [ToolID: Int] = [:]; var leases: [String: MCPToolSchemaLease] = [:]; var presented: Set<String> = [] }
    private let schemas: MCPToolSchemaStore
    private let codec = ProviderToolNameCodec()
    private let maxSchemaBytes: Int
    private let maxSchemaDepth: Int
    private let invoker: (any MCPToolInvoker)?
    private var catalog: [ToolID: MCPToolCatalogEntry] = [:]
    private var sessions: [SessionID: SessionState] = [:]
    private var l2: [ProjectID: [ToolID: Int]] = [:]
    private var providerSchemaCounts: [SessionID: [Int]] = [:]
    public private(set) var pageFaults = 0

    public init(schemaStore: MCPToolSchemaStore = MCPToolSchemaStore(), invoker: (any MCPToolInvoker)? = nil, maxSchemaBytes: Int = 128 * 1024, maxSchemaDepth: Int = 64) {
        self.schemas = schemaStore; self.invoker = invoker; self.maxSchemaBytes = maxSchemaBytes; self.maxSchemaDepth = maxSchemaDepth
    }

    /// Catalog update is all-or-nothing at the caller boundary: callers pass only a completed tools/list generation.
    public func replaceCatalog(serverID: MCPServerID, tools: [MCPDiscoveredTool]) async throws {
        for tool in tools {
            let encoded = try JSONEncoder().encode(tool.inputSchema)
            guard encoded.count <= maxSchemaBytes, depth(tool.inputSchema) <= maxSchemaDepth else { throw MCPToolPagerError.schemaTooLarge }
        }
        let old = catalog.values.filter { $0.serverID == serverID }.map(\.toolID)
        for id in old { catalog[id]?.available = false; removeReferences(id); await schemas.remove(toolID: id) }
        for tool in tools {
            catalog[tool.entry.toolID] = tool.entry
            await schemas.put(tool.inputSchema, toolID: tool.entry.toolID, hash: tool.entry.schemaHash)
        }
    }

    public func search(sessionID: SessionID, projectID: ProjectID, query: String, server: String? = nil, capability: String? = nil, maxResults: Int = 6) -> [MCPToolSearchCandidate] {
        let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let session = sessions[sessionID] ?? SessionState()
        let project = l2[projectID] ?? [:]
        var matched: [(entry: MCPToolCatalogEntry, score: Int)] = []
        for entry in catalog.values where (server == nil || entry.serverAlias == server) && (capability == nil || entry.tags.contains(capability!)) {
            let text = "\(entry.upstreamName) \(entry.title) \(entry.shortDescription) \(entry.tags.joined(separator: " "))".lowercased()
            let lexical = terms.reduce(0) { $0 + (text.contains($1) ? 100 : 0) }
            let boost = (session.l1[entry.toolID] ?? 0) * 4 + (project[entry.toolID] ?? 0) * 2 + (entry.available ? 1 : -1000)
            if terms.isEmpty || lexical >= 100 { matched.append((entry, lexical + boost)) }
        }
        matched.sort { $0.score == $1.score ? $0.entry.toolID.rawValue < $1.entry.toolID.rawValue : $0.score > $1.score }
        return matched.prefix(max(1, min(maxResults, 8))).map { item in
            let entry = item.entry
            return MCPToolSearchCandidate(toolID: entry.toolID, displayName: "\(entry.serverAlias).\(entry.upstreamName)", serverAlias: entry.serverAlias, shortDescription: entry.shortDescription, riskHint: entry.annotations.readOnlyHint == true ? "external/read-only hint" : "external/untrusted", availability: entry.available ? (entry.stale ? "stale" : "available") : "unavailable", temperature: session.l1[entry.toolID] != nil ? "hot" : project[entry.toolID] != nil ? "warm" : "cold")
        }
    }

    public func load(sessionID: SessionID, toolID: ToolID, schemaTokenBudget: Int) async throws -> MCPToolSchemaLease {
        guard let entry = catalog[toolID], entry.available else { throw MCPToolPagerError.unavailable }
        guard let schema = await schemas.schema(toolID: toolID, hash: entry.schemaHash) else { throw MCPToolPagerError.schemaMissing }
        let bytes = try JSONEncoder().encode(schema).count
        guard bytes <= maxSchemaBytes, depth(schema) <= maxSchemaDepth else { throw MCPToolPagerError.schemaTooLarge }
        guard (bytes + 3) / 4 <= schemaTokenBudget else { throw MCPToolPagerError.schemaBudgetExceeded }
        pageFaults += 1
        let providerName = codec.encode(serverAlias: entry.serverAlias, upstreamName: entry.upstreamName, toolID: toolID)
        let lease = MCPToolSchemaLease(leaseID: UUID().uuidString, sessionID: sessionID, toolID: toolID, schemaHash: entry.schemaHash, providerName: providerName, createdAt: .now, expiresAt: .now.addingTimeInterval(300), state: .armed)
        var state = sessions[sessionID] ?? SessionState(); state.leases[lease.leaseID] = lease; sessions[sessionID] = state
        return lease
    }

    public func providerDefinitions(sessionID: SessionID) async -> [ToolDefinition] {
        let leases = sessions[sessionID]?.leases.values.filter { $0.state == .armed && $0.expiresAt > .now } ?? []
        providerSchemaCounts[sessionID, default: []].append(leases.count)
        if !leases.isEmpty { var state = sessions[sessionID] ?? SessionState(); state.presented.formUnion(leases.map(\.leaseID)); sessions[sessionID] = state }
        var result: [ToolDefinition] = []
        for lease in leases {
            guard let entry = catalog[lease.toolID], let schema = await schemas.schema(toolID: lease.toolID, hash: lease.schemaHash) else { continue }
            result.append(ToolDefinition(id: ToolID(lease.providerName), name: lease.providerName, description: entry.shortDescription, inputSchema: ToolInputSchema(properties: [:], required: []), capability: ToolCapability([.networkAccess, .destructive]), rawInputSchema: schema))
        }
        return result.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func resolve(sessionID: SessionID, providerToolID: ToolID, now: Date = .now) throws -> MCPToolSchemaLease {
        guard let lease = sessions[sessionID]?.leases.values.first(where: { $0.providerName == providerToolID.rawValue && $0.state == .armed }) else { throw MCPToolPagerError.leaseMissing }
        guard lease.expiresAt > now else {
            sessions[sessionID]?.leases.removeValue(forKey: lease.leaseID)
            throw MCPToolPagerError.leaseExpired
        }
        guard let entry = catalog[lease.toolID], entry.schemaHash == lease.schemaHash else { throw MCPToolPagerError.schemaChanged }
        return lease
    }

    public func markUsed(sessionID: SessionID, providerToolID: ToolID, projectID: ProjectID) throws -> MCPToolSchemaLease {
        let lease = try resolve(sessionID: sessionID, providerToolID: providerToolID)
        var state = sessions[sessionID] ?? SessionState(); state.l1[lease.toolID, default: 0] += 1
        if var stored = state.leases[lease.leaseID] { stored.state = .used; state.leases[lease.leaseID] = stored }; sessions[sessionID] = state
        l2[projectID, default: [:]][lease.toolID, default: 0] += 1
        return lease
    }

    public func execute(sessionID: SessionID, projectID: ProjectID, providerToolID: ToolID, arguments: String) async throws -> (lease: MCPToolSchemaLease, content: String) {
        let lease = try markUsed(sessionID: sessionID, providerToolID: providerToolID, projectID: projectID)
        guard let entry = catalog[lease.toolID], let invoker else { throw MCPToolPagerError.unavailable }
        return (lease, try await invoker.call(serverID: entry.serverID, toolName: entry.upstreamName, arguments: arguments))
    }

    public func searchToolResult(sessionID: SessionID, projectID: ProjectID, arguments: String) throws -> String {
        struct Input: Decodable { let query: String; let server: String?; let capability: String?; let maxResults: Int? }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let input = try decoder.decode(Input.self, from: Data(arguments.utf8))
        return String(decoding: try JSONEncoder().encode(search(sessionID: sessionID, projectID: projectID, query: input.query, server: input.server, capability: input.capability, maxResults: input.maxResults ?? 6)), as: UTF8.self)
    }

    public func loadToolResult(sessionID: SessionID, arguments: String, schemaTokenBudget: Int) async throws -> String {
        struct Input: Decodable { let toolId: String }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let input = try decoder.decode(Input.self, from: Data(arguments.utf8))
        let lease = try await load(sessionID: sessionID, toolID: ToolID(input.toolId), schemaTokenBudget: schemaTokenBudget)
        return String(decoding: try JSONEncoder().encode(["status": "leased", "tool": lease.toolID.rawValue, "provider_name": lease.providerName]), as: UTF8.self)
    }

    /// Called after every provider response; this is the sole schema page-out path.
    public func finishProviderStep(sessionID: SessionID) {
        guard var state = sessions[sessionID] else { return }
        for id in state.presented {
            guard var lease = state.leases[id] else { continue }
            lease.state = lease.expiresAt <= .now ? .expired : .revoked
            state.leases.removeValue(forKey: id)
        }
        state.presented.removeAll()
        sessions[sessionID] = state
    }

    public func leaseCount(sessionID: SessionID) -> Int { sessions[sessionID]?.leases.count ?? 0 }
    /// Request audit only: counts, never schema bodies.
    public func requestSchemaCounts(sessionID: SessionID) -> [Int] { providerSchemaCounts[sessionID] ?? [] }
    public func catalogCount() -> Int { catalog.count }
    public func schemaStoreMetrics() async -> (count: Int, bytes: Int) { (await schemas.count(), await schemas.bytes()) }
    public func fullSchemaResidencyCount() -> Int { sessions.values.reduce(0) { $0 + $1.presented.count } }

    private func removeReferences(_ toolID: ToolID) {
        for sessionID in sessions.keys { sessions[sessionID]?.l1.removeValue(forKey: toolID); sessions[sessionID]?.leases = sessions[sessionID]!.leases.filter { $0.value.toolID != toolID } }
        for projectID in l2.keys { l2[projectID]?.removeValue(forKey: toolID) }
    }
    private func depth(_ value: JSONValue) -> Int { switch value { case let .array(values): return 1 + (values.map(depth).max() ?? 0); case let .object(values): return 1 + (values.values.map(depth).max() ?? 0); default: return 1 } }
}

public enum MCPDiscoveryTools {
    public static let search = ToolDefinition(id: ToolID("search_tools"), description: "Search external MCP tool capabilities. Returns metadata only, never schemas.", inputSchema: ToolInputSchema(properties: ["query": ToolInputProperty(type: .string, description: "Capability query"), "server": ToolInputProperty(type: .string, description: "Optional server alias"), "capability": ToolInputProperty(type: .string, description: "Optional capability tag"), "max_results": ToolInputProperty(type: .integer, description: "Maximum candidates", minimum: 1, maximum: 8)], required: ["query"]), capability: ToolCapability(readOnly: true))
    public static let load = ToolDefinition(id: ToolID("load_tool"), description: "Lease one external MCP tool for the next inference only.", inputSchema: ToolInputSchema(properties: ["tool_id": ToolInputProperty(type: .string, description: "ToolID returned by search_tools")], required: ["tool_id"]), capability: ToolCapability(readOnly: true))
}
