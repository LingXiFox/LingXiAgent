import Foundation
import LingXiProtocol

public struct ExtensionDomainClient: Sendable {
    private let transport: any ClientTransport

    public init(transport: any ClientTransport) {
        self.transport = transport
    }

    public func list(kind: ExtensionKind? = nil) async throws -> [ExtensionInfo] {
        let req = ListExtensionsRequest(kind: kind)
        let resp = try await transport.listExtensions(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func getStatus(id: String) async throws -> ExtensionInfo {
        let req = GetExtensionStatusRequest(id: id)
        let resp = try await transport.getExtensionStatus(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func get(id: String) async throws -> ExtensionInfo {
        let req = GetExtensionRequest(id: id)
        let resp = try await transport.getExtension(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func install(name: String, location: String) async throws -> CommandReceipt<ExtensionInfo> {
        let req = InstallExtensionRequest(name: name, location: location)
        return try await transport.installExtension(envelope: CommandEnvelope(payload: req))
    }

    public func uninstall(id: String) async throws -> CommandReceipt<VoidResult> {
        let req = UninstallExtensionRequest(id: id)
        return try await transport.uninstallExtension(envelope: CommandEnvelope(payload: req))
    }

    public func enable(id: String) async throws -> CommandReceipt<ExtensionInfo> {
        let req = EnableExtensionRequest(id: id)
        return try await transport.enableExtension(envelope: CommandEnvelope(payload: req))
    }

    public func disable(id: String) async throws -> CommandReceipt<ExtensionInfo> {
        let req = DisableExtensionRequest(id: id)
        return try await transport.disableExtension(envelope: CommandEnvelope(payload: req))
    }

    public func reload() async throws -> CommandReceipt<VoidResult> {
        try await transport.reloadExtensions(envelope: CommandEnvelope(payload: VoidResult()))
    }

    public func configure(id: String, configuration: [String: String]) async throws -> CommandReceipt<ExtensionInfo> {
        let req = ConfigureExtensionRequest(id: id, configuration: configuration)
        return try await transport.configureExtension(envelope: CommandEnvelope(payload: req))
    }
}
