import Foundation
import LingXiProtocol

private actor StateManager {
    var state: ConnectionState = .disconnected
    var continuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    func getState() -> ConnectionState {
        state
    }

    func registerContinuation(_ continuation: AsyncStream<ConnectionState>.Continuation, id: UUID) {
        continuations[id] = continuation
        continuation.yield(state)
    }

    func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    func transition(to newState: ConnectionState) {
        state = newState
        for continuation in continuations.values {
            continuation.yield(newState)
        }
    }
}

/// InProcessTransport：基于内存进程内直接调用 LingXiProtocolService（如 CoreHost）的 Transport 实现。
public final class InProcessTransport: ClientTransport, Sendable {
    private let service: any LingXiProtocolService
    public let authorizationContext: ContentAuthorizationContext
    private let handshake: ProtocolHandshake
    private let stateManager = StateManager()

    public init(
        service: any LingXiProtocolService,
        authorizationContext: ContentAuthorizationContext = .system,
        handshake: ProtocolHandshake = ProtocolHandshake()
    ) {
        self.service = service
        self.authorizationContext = authorizationContext
        self.handshake = handshake
    }

    public var connectionState: ConnectionState {
        get async {
            await stateManager.getState()
        }
    }

    public var stateStream: AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            let id = UUID()
            Task {
                await self.stateManager.registerContinuation(continuation, id: id)
            }

            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.stateManager.removeContinuation(id: id)
                }
            }
        }
    }

    public func connect() async throws {
        await stateManager.transition(to: .connecting)
        await stateManager.transition(to: .handshaking)

        do {
            let result = try await handshake.perform(service: service)
            await stateManager.transition(to: .connected(version: result.serverVersion, capabilities: result.capabilities))
        } catch {
            await stateManager.transition(to: .failed(detail: "\(error)"))
            throw error
        }
    }

    public func disconnect() async {
        await stateManager.transition(to: .disconnected)
    }

    // MARK: - LingXiProtocolService: 1. Runtime
    public func getRuntimeInfo(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeInfo> {
        try await service.getRuntimeInfo(envelope: envelope)
    }

    public func getRuntimeHealth(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeHealth> {
        try await service.getRuntimeHealth(envelope: envelope)
    }

    public func getRuntimeCapabilities(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeCapabilities> {
        try await service.getRuntimeCapabilities(envelope: envelope)
    }

    public func getEffectiveConfiguration(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<EffectiveConfigurationSnapshot> {
        try await service.getEffectiveConfiguration(envelope: envelope)
    }

    public func reloadConfiguration(envelope: CommandEnvelope<VoidResult>) async throws -> CommandReceipt<VoidResult> {
        try await service.reloadConfiguration(envelope: envelope)
    }

    public func updateTypedSetting(envelope: CommandEnvelope<UpdateTypedSettingRequest>) async throws -> CommandReceipt<VoidResult> {
        try await service.updateTypedSetting(envelope: envelope)
    }

    // MARK: - LingXiProtocolService: 2. Session
    public func createSession(envelope: CommandEnvelope<CreateSessionRequest>) async throws -> CommandReceipt<SessionSummary> {
        try await service.createSession(envelope: envelope)
    }

    public func renameSession(envelope: CommandEnvelope<RenameSessionRequest>) async throws -> CommandReceipt<SessionSummary> {
        try await service.renameSession(envelope: envelope)
    }

    public func setSessionReasoningEffort(envelope: CommandEnvelope<SetSessionReasoningEffortRequest>) async throws -> CommandReceipt<SessionSummary> {
        try await service.setSessionReasoningEffort(envelope: envelope)
    }

    public func deleteSession(envelope: CommandEnvelope<DeleteSessionRequest>) async throws -> CommandReceipt<VoidResult> {
        try await service.deleteSession(envelope: envelope)
    }

    public func getSession(envelope: QueryEnvelope<GetSessionRequest>) async throws -> ResponseEnvelope<SessionSummary> {
        try await service.getSession(envelope: envelope)
    }

    public func listSessions(envelope: QueryEnvelope<PageRequest>) async throws -> ResponseEnvelope<Page<SessionSummary>> {
        try await service.listSessions(envelope: envelope)
    }

    public func getSessionSnapshot(envelope: QueryEnvelope<GetSessionSnapshotRequest>) async throws -> ResponseEnvelope<SessionSnapshot> {
        try await service.getSessionSnapshot(envelope: envelope)
    }

    // MARK: - LingXiProtocolService: 3. Turn
    public func submitTurn(envelope: CommandEnvelope<SubmitTurnRequest>) async throws -> CommandReceipt<SubmitTurnResult> {
        try await service.submitTurn(envelope: envelope)
    }

    public func cancelTurn(envelope: CommandEnvelope<CancelTurnRequest>) async throws -> CommandReceipt<VoidResult> {
        try await service.cancelTurn(envelope: envelope)
    }

    public func getTurn(envelope: QueryEnvelope<GetTurnRequest>) async throws -> ResponseEnvelope<TurnSnapshot> {
        try await service.getTurn(envelope: envelope)
    }

    public func listTurns(envelope: QueryEnvelope<ListTurnsRequest>) async throws -> ResponseEnvelope<Page<TurnSnapshot>> {
        try await service.listTurns(envelope: envelope)
    }

    // MARK: - LingXiProtocolService: 4. Run
    public func cancelRun(envelope: CommandEnvelope<CancelRunRequest>) async throws -> CommandReceipt<VoidResult> {
        try await service.cancelRun(envelope: envelope)
    }

    public func resumeRun(envelope: CommandEnvelope<ResumeRunRequest>) async throws -> CommandReceipt<RunSnapshot> {
        try await service.resumeRun(envelope: envelope)
    }

    public func getRun(envelope: QueryEnvelope<GetRunRequest>) async throws -> ResponseEnvelope<RunSnapshot> {
        try await service.getRun(envelope: envelope)
    }

    public func listRuns(envelope: QueryEnvelope<ListRunsRequest>) async throws -> ResponseEnvelope<Page<RunSnapshot>> {
        try await service.listRuns(envelope: envelope)
    }

    public func getAgentTree(envelope: QueryEnvelope<GetAgentTreeRequest>) async throws -> ResponseEnvelope<AgentTreeNode> {
        try await service.getAgentTree(envelope: envelope)
    }

    // MARK: - LingXiProtocolService: 5. Interaction
    public func listPendingInteractions(envelope: QueryEnvelope<ListInteractionsRequest>) async throws -> ResponseEnvelope<[InteractionSnapshot]> {
        try await service.listPendingInteractions(envelope: envelope)
    }

    public func resolveInteraction(envelope: CommandEnvelope<ResolveInteractionRequest>) async throws -> CommandReceipt<VoidResult> {
        try await service.resolveInteraction(envelope: envelope)
    }

    // MARK: - LingXiProtocolService: 6. Provider
    public func listProviders(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[ProviderAccountInfo]> {
        try await service.listProviders(envelope: envelope)
    }

    public func getProviderStatus(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ProviderStatus> {
        try await service.getProviderStatus(envelope: envelope)
    }

    public func getProvider(envelope: QueryEnvelope<GetProviderRequest>) async throws -> ResponseEnvelope<ProviderAccountInfo> {
        try await service.getProvider(envelope: envelope)
    }

    public func testProvider(envelope: CommandEnvelope<TestProviderRequest>) async throws -> CommandReceipt<TestProviderResult> {
        try await service.testProvider(envelope: envelope)
    }

    public func configureProvider(envelope: CommandEnvelope<ConfigureProviderRequest>) async throws -> CommandReceipt<ProviderAccountInfo> {
        try await service.configureProvider(envelope: envelope)
    }

    public func removeProvider(envelope: CommandEnvelope<RemoveProviderRequest>) async throws -> CommandReceipt<VoidResult> {
        try await service.removeProvider(envelope: envelope)
    }

    public func reloadProviders(envelope: CommandEnvelope<VoidResult>) async throws -> CommandReceipt<VoidResult> {
        try await service.reloadProviders(envelope: envelope)
    }

    // MARK: - LingXiProtocolService: 7. Model
    public func listModels(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[ProviderModelInfo]> {
        try await service.listModels(envelope: envelope)
    }

    public func getModelSelection(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ModelSelectionInfo> {
        try await service.getModelSelection(envelope: envelope)
    }

    public func selectModel(envelope: CommandEnvelope<SelectModelRequest>) async throws -> CommandReceipt<ModelSelectionInfo> {
        try await service.selectModel(envelope: envelope)
    }

    public func getModel(envelope: QueryEnvelope<GetModelRequest>) async throws -> ResponseEnvelope<ProviderModelInfo> {
        try await service.getModel(envelope: envelope)
    }

    public func getModelCapabilities(envelope: QueryEnvelope<GetModelCapabilitiesRequest>) async throws -> ResponseEnvelope<ModelCapabilitiesInfo> {
        try await service.getModelCapabilities(envelope: envelope)
    }

    public func setModelSelection(envelope: CommandEnvelope<SetModelSelectionRequest>) async throws -> CommandReceipt<ModelSelectionInfo> {
        try await service.setModelSelection(envelope: envelope)
    }

    // MARK: - LingXiProtocolService: 8. Context
    public func getContextState(envelope: QueryEnvelope<GetContextStateRequest>) async throws -> ResponseEnvelope<ContextStateSnapshot> {
        try await service.getContextState(envelope: envelope)
    }

    public func getContextPolicy(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ContextCachePolicySnapshot> {
        try await service.getContextPolicy(envelope: envelope)
    }

    public func compactContext(envelope: CommandEnvelope<CompactContextRequest>) async throws -> CommandReceipt<VoidResult> {
        try await service.compactContext(envelope: envelope)
    }

    public func searchContext(envelope: QueryEnvelope<SearchContextRequest>) async throws -> ResponseEnvelope<[ContextSearchResultItem]> {
        try await service.searchContext(envelope: envelope)
    }

    public func getContextEntry(envelope: QueryEnvelope<GetContextEntryRequest>) async throws -> ResponseEnvelope<ContextEntryItem> {
        try await service.getContextEntry(envelope: envelope)
    }

    public func updateContextPolicy(envelope: CommandEnvelope<UpdateContextPolicyRequest>) async throws -> CommandReceipt<ContextCachePolicySnapshot> {
        try await service.updateContextPolicy(envelope: envelope)
    }

    // MARK: - LingXiProtocolService: 9. Extension
    public func listExtensions(envelope: QueryEnvelope<ListExtensionsRequest>) async throws -> ResponseEnvelope<[ExtensionInfo]> {
        try await service.listExtensions(envelope: envelope)
    }

    public func getExtensionStatus(envelope: QueryEnvelope<GetExtensionStatusRequest>) async throws -> ResponseEnvelope<ExtensionInfo> {
        try await service.getExtensionStatus(envelope: envelope)
    }

    public func getExtension(envelope: QueryEnvelope<GetExtensionRequest>) async throws -> ResponseEnvelope<ExtensionInfo> {
        try await service.getExtension(envelope: envelope)
    }

    public func installExtension(envelope: CommandEnvelope<InstallExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo> {
        try await service.installExtension(envelope: envelope)
    }

    public func uninstallExtension(envelope: CommandEnvelope<UninstallExtensionRequest>) async throws -> CommandReceipt<VoidResult> {
        try await service.uninstallExtension(envelope: envelope)
    }

    public func enableExtension(envelope: CommandEnvelope<EnableExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo> {
        try await service.enableExtension(envelope: envelope)
    }

    public func disableExtension(envelope: CommandEnvelope<DisableExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo> {
        try await service.disableExtension(envelope: envelope)
    }

    public func reloadExtensions(envelope: CommandEnvelope<VoidResult>) async throws -> CommandReceipt<VoidResult> {
        try await service.reloadExtensions(envelope: envelope)
    }

    public func configureExtension(envelope: CommandEnvelope<ConfigureExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo> {
        try await service.configureExtension(envelope: envelope)
    }

    // MARK: - LingXiProtocolService: 10. Workspace
    public func getWorkspace(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<WorkspaceSummary> {
        try await service.getWorkspace(envelope: envelope)
    }

    public func setWorkspace(envelope: CommandEnvelope<SetWorkspaceRequest>) async throws -> CommandReceipt<WorkspaceSummary> {
        try await service.setWorkspace(envelope: envelope)
    }

    public func getWorkspaceSummary(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<WorkspaceSummary> {
        try await service.getWorkspaceSummary(envelope: envelope)
    }

    public func getWorkspaceDiffSummary(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<WorkspaceDiffSummary> {
        try await service.getWorkspaceDiffSummary(envelope: envelope)
    }

    // MARK: - LingXiProtocolService: 11. Resource & Content Data Plane
    public func beginContentUpload(envelope: CommandEnvelope<BeginContentUploadRequest>) async throws -> CommandReceipt<BeginContentUploadResponse> {
        try await service.beginContentUpload(envelope: envelope)
    }

    public func uploadContentChunk(uploadID: String, chunkIndex: UInt64, data: Data) async throws {
        try await service.uploadContentChunk(uploadID: uploadID, chunkIndex: chunkIndex, data: data)
    }

    public func commitContentUpload(envelope: CommandEnvelope<CommitContentUploadRequest>) async throws -> CommandReceipt<ContentRef> {
        try await service.commitContentUpload(envelope: envelope)
    }

    public func abortContentUpload(envelope: CommandEnvelope<AbortContentUploadRequest>) async throws -> CommandReceipt<VoidResult> {
        try await service.abortContentUpload(envelope: envelope)
    }

    public func getContentMetadata(ref: ContentRef, authorization: ContentAuthorizationContext) async throws -> ContentMetadata {
        // Enforce the connection's injected authorization context
        let effectiveAuth = self.authorizationContext
        return try await service.getContentMetadata(ref: ref, authorization: effectiveAuth)
    }

    public func getContent(ref: ContentRef, authorization: ContentAuthorizationContext) async throws -> Data {
        let effectiveAuth = self.authorizationContext
        return try await service.getContent(ref: ref, authorization: effectiveAuth)
    }

    public func getContentRange(ref: ContentRef, offset: Int, length: Int, authorization: ContentAuthorizationContext) async throws -> Data {
        let effectiveAuth = self.authorizationContext
        return try await service.getContentRange(ref: ref, offset: offset, length: length, authorization: effectiveAuth)
    }

    // MARK: - LingXiProtocolService: 12. Diagnostics
    public func getDiagnostics(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeDiagnosticsBundle> {
        try await service.getDiagnostics(envelope: envelope)
    }

    public func getPerformanceMetrics(envelope: QueryEnvelope<GetPerformanceMetricsRequest>) async throws -> ResponseEnvelope<TurnPerformanceReport?> {
        try await service.getPerformanceMetrics(envelope: envelope)
    }

    public func getProviderMetrics(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ProviderMetricsInfo> {
        try await service.getProviderMetrics(envelope: envelope)
    }

    public func getRunTrace(envelope: QueryEnvelope<GetRunTraceRequest>) async throws -> ResponseEnvelope<RunTraceInfo> {
        try await service.getRunTrace(envelope: envelope)
    }

    // MARK: - LingXiProtocolService: 13. Credential
    public func listCredentials(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[CredentialRef]> {
        try await service.listCredentials(envelope: envelope)
    }

    public func storeCredential(envelope: CommandEnvelope<StoreCredentialRequest>) async throws -> CommandReceipt<CredentialResult> {
        try await service.storeCredential(envelope: envelope)
    }

    public func deleteCredential(envelope: CommandEnvelope<DeleteCredentialRequest>) async throws -> CommandReceipt<VoidResult> {
        try await service.deleteCredential(envelope: envelope)
    }

    public func getCredentialStatus(envelope: QueryEnvelope<GetCredentialStatusRequest>) async throws -> ResponseEnvelope<CredentialStatusInfo> {
        try await service.getCredentialStatus(envelope: envelope)
    }

    public func testCredential(envelope: CommandEnvelope<TestCredentialRequest>) async throws -> CommandReceipt<TestCredentialResult> {
        try await service.testCredential(envelope: envelope)
    }

    // MARK: - Event Streams
    public func subscribeRuntimeEvents(after: EventCursor?) async -> AsyncStream<RuntimeEventEnvelope> {
        await service.subscribeRuntimeEvents(after: after)
    }

    public func subscribeSessionEvents(sessionID: SessionID, after: EventCursor?) async throws -> AsyncStream<SessionEventEnvelope> {
        try await service.subscribeSessionEvents(sessionID: sessionID, after: after)
    }

    public func listSessionEvents(request: ListSessionEventsRequest) async throws -> [SessionEventEnvelope] {
        try await service.listSessionEvents(request: request)
    }

    // MARK: - High-Frequency StreamFrames
    public func subscribeStreamFrames(streamID: StreamID, afterIndex: UInt64?) async throws -> AsyncStream<StreamFrame> {
        try await service.subscribeStreamFrames(streamID: streamID, afterIndex: afterIndex)
    }
}
