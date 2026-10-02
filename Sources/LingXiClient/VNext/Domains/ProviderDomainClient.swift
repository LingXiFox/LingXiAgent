import Foundation
import LingXiProtocol

public struct ProviderDomainClient: Sendable {
    private let transport: any ClientTransport

    public init(transport: any ClientTransport) {
        self.transport = transport
    }

    public func list() async throws -> [ProviderAccountInfo] {
        let resp = try await transport.listProviders(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    public func status() async throws -> ProviderStatus {
        let resp = try await transport.getProviderStatus(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    public func get(providerID: String) async throws -> ProviderAccountInfo {
        let req = GetProviderRequest(providerID: providerID)
        let resp = try await transport.getProvider(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func test(providerID: String) async throws -> CommandReceipt<TestProviderResult> {
        let req = TestProviderRequest(providerID: providerID)
        return try await transport.testProvider(envelope: CommandEnvelope(payload: req))
    }

    public func configure(
        providerID: String,
        accountID: String,
        displayName: String? = nil,
        endpointURL: String? = nil,
        credentialReference: CredentialRef? = nil
    ) async throws -> CommandReceipt<ProviderAccountInfo> {
        let req = ConfigureProviderRequest(
            providerID: providerID,
            accountID: accountID,
            displayName: displayName,
            endpointURL: endpointURL,
            credentialReference: credentialReference
        )
        return try await transport.configureProvider(envelope: CommandEnvelope(payload: req))
    }

    public func remove(accountID: String) async throws -> CommandReceipt<VoidResult> {
        let req = RemoveProviderRequest(accountID: accountID)
        return try await transport.removeProvider(envelope: CommandEnvelope(payload: req))
    }

    public func reload() async throws -> CommandReceipt<VoidResult> {
        try await transport.reloadProviders(envelope: CommandEnvelope(payload: VoidResult()))
    }

    // MARK: providers.json editing

    public func configuration(providerID: String) async throws -> ProviderConfigurationDetail {
        let req = GetProviderConfigurationRequest(providerID: providerID)
        return try await transport.getProviderConfiguration(envelope: QueryEnvelope(payload: req)).payload
    }

    public func saveConfiguration(_ request: SaveProviderConfigurationRequest) async throws -> ProviderConfigurationDetail {
        let receipt = try await transport.saveProviderConfiguration(envelope: CommandEnvelope(payload: request))
        guard let detail = receipt.result else {
            throw RuntimeError(category: .runtime, code: "emptyResult", message: "保存 Provider 配置没有返回结果", retryability: .none, source: .client)
        }
        return detail
    }

    public func deleteConfiguration(providerID: String, deleteCredential: Bool = true) async throws {
        let req = DeleteProviderConfigurationRequest(providerID: providerID, deleteCredential: deleteCredential)
        _ = try await transport.deleteProviderConfiguration(envelope: CommandEnvelope(payload: req))
    }

    // MARK: sign-in and pre-save connection tests

    /// Products Core can actually sign a user in to.
    public func authProducts() async throws -> [ProviderAuthProduct] {
        try await transport.listProviderAuthProducts(envelope: QueryEnvelope(payload: VoidResult())).payload
    }

    /// Starts a sign-in flow; the caller opens `authorizeURL` in the system browser.
    /// Curated registry plus the published models.lingxifox.cn index.
    public func catalog(refresh: Bool = false) async throws -> [ProviderCatalogEntry] {
        try await transport.getProviderCatalog(
            envelope: QueryEnvelope(payload: GetProviderCatalogRequest(refresh: refresh))).payload
    }

    public func catalogModels(entryID: String) async throws -> ProviderModelRoster {
        try await transport.getProviderCatalogModels(
            envelope: QueryEnvelope(payload: GetProviderCatalogModelsRequest(entryID: entryID))).payload
    }

    /// Probes the models this provider already has configured. Costs one minimal turn each.
    public func probeModels(providerID: String) async throws -> [String: ModelAvailability] {
        try await transport.probeProviderModels(
            envelope: CommandEnvelope(payload: ProbeProviderModelsRequest(providerID: providerID))).result ?? [:]
    }

    /// What a previous probe settled, without spending another request.
    public func modelAvailability(providerID: String) async throws -> [String: ModelAvailability] {
        try await transport.getProviderModelAvailability(
            envelope: QueryEnvelope(payload: GetProviderModelAvailabilityRequest(providerID: providerID))).payload
    }

    /// Models an account reaches but that are not offered for selection, keyed by product.
    public func withheldModels() async throws -> [String: [String]] {
        try await transport.getWithheldModels(envelope: QueryEnvelope(payload: VoidResult())).payload
    }

    /// Connects a registry product with the credential or endpoint its contract requires.
    public func connect(_ request: ConnectProviderRequest) async throws -> ProviderAccountInfo {
        let receipt = try await transport.connectProvider(envelope: CommandEnvelope(payload: request))
        guard let account = receipt.result else {
            throw RuntimeError(category: .runtime, code: "emptyResult", message: "连接 Provider 没有返回结果",
                               retryability: .none, source: .client)
        }
        return account
    }

    public func beginAuth(productID: String) async throws -> ProviderAuthFlow {
        let receipt = try await transport.beginProviderAuth(
            envelope: CommandEnvelope(payload: BeginProviderAuthRequest(productID: productID)))
        return try Self.requireResult(receipt, message: "开始登录没有返回结果")
    }

    public func authStatus(flowID: String) async throws -> ProviderAuthFlow {
        let req = GetProviderAuthFlowRequest(flowID: flowID)
        return try await transport.getProviderAuthFlow(envelope: QueryEnvelope(payload: req)).payload
    }

    public func cancelAuth(flowID: String) async throws {
        let req = CancelProviderAuthRequest(flowID: flowID)
        _ = try await transport.cancelProviderAuth(envelope: CommandEnvelope(payload: req))
    }

    /// Tests a provider that is not saved yet, referencing a staged credential.
    public func testDraft(_ draft: TestProviderDraftRequest) async throws -> TestProviderResult {
        let receipt = try await transport.testProviderDraft(envelope: CommandEnvelope(payload: draft))
        return try Self.requireResult(receipt, message: "测试连接没有返回结果")
    }

    private static func requireResult(_ receipt: CommandReceipt<ProviderAuthFlow>, message: String) throws -> ProviderAuthFlow {
        guard let flow = receipt.result else {
            throw RuntimeError(category: .runtime, code: "emptyResult", message: message, retryability: .none, source: .client)
        }
        return flow
    }

    private static func requireResult(_ receipt: CommandReceipt<TestProviderResult>, message: String) throws -> TestProviderResult {
        guard let result = receipt.result else {
            throw RuntimeError(category: .runtime, code: "emptyResult", message: message, retryability: .none, source: .client)
        }
        return result
    }
}
