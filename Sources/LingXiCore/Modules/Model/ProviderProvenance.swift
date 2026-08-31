import Foundation
import LingXiProtocol

/// Provider 原生调用身份只存在于 Model Adapter 边界，不能成为 LingXi ToolCallID。
public struct ProviderToolCallReference: Sendable, Equatable, Codable {
    public let wire: ModelWireProtocol
    public let domainCallID: ToolCallID
    public let externalCallID: String
    public let externalItemID: String?

    public init(wire: ModelWireProtocol, domainCallID: ToolCallID, externalCallID: String, externalItemID: String? = nil) {
        self.wire = wire
        self.domainCallID = domainCallID
        self.externalCallID = externalCallID
        self.externalItemID = externalItemID
    }
}

public enum ProviderContinuationItem: Sendable, Equatable, Codable {
    /// 原始 Provider item JSON；Core 不解释或改写其中的 opaque content。
    case opaque(Data)
    case toolCall(ToolCallID)
}

public struct ProviderContinuation: Sendable, Equatable, Codable {
    public let requestID: ModelRequestID
    public let executionID: AgentRunID?
    public let wire: ModelWireProtocol
    public let responseID: String?
    public let references: [ProviderToolCallReference]
    public let orderedItems: [ProviderContinuationItem]

    public init(requestID: ModelRequestID, executionID: AgentRunID?, wire: ModelWireProtocol, responseID: String? = nil, references: [ProviderToolCallReference], orderedItems: [ProviderContinuationItem] = []) {
        self.requestID = requestID
        self.executionID = executionID
        self.wire = wire
        self.responseID = responseID
        self.references = references
        self.orderedItems = orderedItems
    }

    public func externalCallID(for domainCallID: ToolCallID) -> String? {
        references.first { $0.domainCallID == domainCallID }?.externalCallID
    }
}

/// Entries are keyed by one model request, so concurrent Main/Child decoders cannot share correlation state.
public actor ProviderProvenanceStore {
    private var entries: [ModelRequestID: ProviderContinuation] = [:]
    private var referencesByDomainID: [ToolCallID: ProviderToolCallReference] = [:]
    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-provider-provenance-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
    }

    public func continuation(for requestID: ModelRequestID?, wire: ModelWireProtocol) throws -> ProviderContinuation? {
        guard let requestID else { return nil }
        let url = file(requestID)
        let value: ProviderContinuation?
        if let cached = entries[requestID] { value = cached }
        else if FileManager.default.fileExists(atPath: url.path) { value = try JSONDecoder().decode(ProviderContinuation.self, from: Data(contentsOf: url)) }
        else { value = nil }
        guard let value, value.wire == wire else { return nil }
        entries[requestID] = value
        for ref in value.references { referencesByDomainID[ref.domainCallID] = ref }
        return value
    }

    public func resolveContinuation(for requestID: ModelRequestID?, wire: ModelWireProtocol) throws -> ProviderContinuation? {
        let base = try continuation(for: requestID, wire: wire)
        var combined = base?.references ?? []
        for (domainID, ref) in referencesByDomainID where ref.wire == wire {
            if !combined.contains(where: { $0.domainCallID == domainID }) {
                combined.append(ref)
            }
        }
        if let base {
            return ProviderContinuation(requestID: base.requestID, executionID: base.executionID, wire: base.wire, responseID: base.responseID, references: combined, orderedItems: base.orderedItems)
        } else if !combined.isEmpty {
            return ProviderContinuation(requestID: requestID ?? ModelRequestID(), executionID: nil, wire: wire, responseID: nil, references: combined, orderedItems: [])
        }
        return nil
    }

    public func record(_ continuation: ProviderContinuation) throws {
        let url = file(continuation.requestID)
        try JSONEncoder().encode(continuation).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        entries[continuation.requestID] = continuation
        for ref in continuation.references {
            referencesByDomainID[ref.domainCallID] = ref
        }
    }

    public func remove(_ executionID: AgentRunID) {
        entries = entries.filter { $0.value.executionID != executionID }
        for url in files() {
            guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(ProviderContinuation.self, from: data), value.executionID == executionID else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func files() -> [URL] { (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] }
    private func file(_ requestID: ModelRequestID) -> URL { directory.appendingPathComponent(sha256Hex(requestID.rawValue) + ".json") }
}
