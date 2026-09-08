import Foundation
import os
import LingXiProtocol
@testable import LingXiClient

/// FaultInjectingTransport：用于验收测试的可控故障注入传输层。
/// 支持网络强制断开、StreamFrame 丢帧、StreamFrame 重放失效、EventLog ReplayUnavailable 以及 Generation Mismatch 故障注入。
public final class FaultInjectingTransport: ClientTransport, @unchecked Sendable {
    private struct State {
        var status: ConnectionStatus = .disconnected
        var stateHistory: [ConnectionStatus] = []
        var stateContinuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
        var activeSessionStreamContinuations: [UUID: AsyncStream<SessionEventEnvelope>.Continuation] = [:]
        var replayUnavailable: Bool = false
        var generationMismatch: Bool = false
        var streamReplayAvailable: Bool = true
        var droppedFrameIndices: Set<UInt64> = []
    }

    private let underlying: any LingXiProtocolService
    public let authorizationContext: ContentAuthorizationContext
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(
        service: any LingXiProtocolService,
        authorizationContext: ContentAuthorizationContext = .system
    ) {
        self.underlying = service
        self.authorizationContext = authorizationContext
    }

    public var recordedStatuses: [ConnectionStatus] {
        state.withLock { $0.stateHistory }
    }

    public var replayUnavailable: Bool {
        get { state.withLock { $0.replayUnavailable } }
        set { state.withLock { $0.replayUnavailable = newValue } }
    }

    public var generationMismatch: Bool {
        get { state.withLock { $0.generationMismatch } }
        set { state.withLock { $0.generationMismatch = newValue } }
    }

    public var streamReplayAvailable: Bool {
        get { state.withLock { $0.streamReplayAvailable } }
        set { state.withLock { $0.streamReplayAvailable = newValue } }
    }

    public var droppedFrameIndices: Set<UInt64> {
        get { state.withLock { $0.droppedFrameIndices } }
        set { state.withLock { $0.droppedFrameIndices = newValue } }
    }

    public var connectionState: ConnectionState {
        get async {
            let status = state.withLock { $0.status }
            return ConnectionState(status: status)
        }
    }

    public var stateStream: AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            let id = UUID()
            let current = state.withLock { s -> ConnectionState in
                s.stateContinuations[id] = continuation
                return ConnectionState(status: s.status)
            }
            continuation.yield(current)

            continuation.onTermination = { [weak self] _ in
                _ = self?.state.withLock {
                    $0.stateContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    private func transition(to newStatus: ConnectionStatus) {
        let continuations: [AsyncStream<ConnectionState>.Continuation] = state.withLock { s in
            s.status = newStatus
            s.stateHistory.append(newStatus)
            return Array(s.stateContinuations.values)
        }

        let newState = ConnectionState(status: newStatus)
        for c in continuations {
            c.yield(newState)
        }
    }

    public func connect() async throws {
        transition(to: .connecting)
        transition(to: .handshaking)
        _ = try await underlying.getRuntimeInfo(envelope: QueryEnvelope(payload: VoidResult()))
        _ = try await underlying.getRuntimeCapabilities(envelope: QueryEnvelope(payload: VoidResult()))
        transition(to: .connected)
    }

    public func disconnect() async {
        transition(to: .disconnected)
        closeActiveStreams()
    }

    /// 模拟网络突发断开并进入 reconnecting 状态
    public func forceDisconnect() {
        transition(to: .reconnecting)
        closeActiveStreams()
    }

    private func closeActiveStreams() {
        let continuations: [AsyncStream<SessionEventEnvelope>.Continuation] = state.withLock { s in
            let list = Array(s.activeSessionStreamContinuations.values)
            s.activeSessionStreamContinuations.removeAll()
            return list
        }
        for c in continuations {
            c.finish()
        }
    }

    // MARK: - Stream & Event Injections

    public func subscribeStreamFrames(streamID: StreamID, afterIndex: UInt64?) async throws -> AsyncStream<StreamFrame> {
        let replayOk = state.withLock { $0.streamReplayAvailable }
        if afterIndex != nil && !replayOk {
            throw RuntimeError(
                category: .runtime,
                code: "streamReplayPruned",
                message: "Stream frames for \(streamID) have been pruned and cannot be replayed"
            )
        }

        let raw = try await underlying.subscribeStreamFrames(streamID: streamID, afterIndex: afterIndex)
        let (stream, continuation) = AsyncStream.makeStream(of: StreamFrame.self)

        Task {
            for await frame in raw {
                let drop = self.state.withLock { $0.droppedFrameIndices.contains(frame.index) }
                if !drop {
                    continuation.yield(frame)
                }
            }
            continuation.finish()
        }

        return stream
    }

    public func subscribeSessionEvents(sessionID: SessionID, after: EventCursor?) async throws -> AsyncStream<SessionEventEnvelope> {
        let (isReplayUnavailable, isGenMismatch) = state.withLock { s -> (Bool, Bool) in
            let res = (s.replayUnavailable, s.generationMismatch)
            if s.replayUnavailable { s.replayUnavailable = false }
            if s.generationMismatch { s.generationMismatch = false }
            return res
        }
        if after != nil && isReplayUnavailable {
            throw RuntimeError(
                category: .runtime,
                code: "replayUnavailable",
                message: "Event log sequence pruned"
            )
        }
        if after != nil && isGenMismatch {
            throw RuntimeError(
                category: .runtime,
                code: "generationMismatch",
                message: "Event log generation mismatch"
            )
        }

        let raw = try await underlying.subscribeSessionEvents(sessionID: sessionID, after: after)
        let (stream, continuation) = AsyncStream.makeStream(of: SessionEventEnvelope.self)

        let id = UUID()
        state.withLock {
            $0.activeSessionStreamContinuations[id] = continuation
        }

        Task {
            for await envelope in raw {
                continuation.yield(envelope)
            }
            _ = self.state.withLock {
                $0.activeSessionStreamContinuations.removeValue(forKey: id)
            }
            continuation.finish()
        }

        return stream
    }

    public func subscribeRuntimeEvents(after: EventCursor?) async -> AsyncStream<RuntimeEventEnvelope> {
        await underlying.subscribeRuntimeEvents(after: after)
    }

    public func listSessionEvents(request: ListSessionEventsRequest) async throws -> [SessionEventEnvelope] {
        try await underlying.listSessionEvents(request: request)
    }

    // MARK: - LingXiProtocolService Forwarding

    public func getRuntimeInfo(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeInfo> {
        try await underlying.getRuntimeInfo(envelope: envelope)
    }
    public func getRuntimeHealth(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeHealth> {
        try await underlying.getRuntimeHealth(envelope: envelope)
    }
    public func getRuntimeCapabilities(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeCapabilities> {
        try await underlying.getRuntimeCapabilities(envelope: envelope)
    }
    public func getEffectiveConfiguration(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<EffectiveConfigurationSnapshot> {
        try await underlying.getEffectiveConfiguration(envelope: envelope)
    }
    public func reloadConfiguration(envelope: CommandEnvelope<VoidResult>) async throws -> CommandReceipt<VoidResult> {
        try await underlying.reloadConfiguration(envelope: envelope)
    }
    public func updateTypedSetting(envelope: CommandEnvelope<UpdateTypedSettingRequest>) async throws -> CommandReceipt<VoidResult> {
        try await underlying.updateTypedSetting(envelope: envelope)
    }
    public func createSession(envelope: CommandEnvelope<CreateSessionRequest>) async throws -> CommandReceipt<SessionSummary> {
        try await underlying.createSession(envelope: envelope)
    }
    public func renameSession(envelope: CommandEnvelope<RenameSessionRequest>) async throws -> CommandReceipt<SessionSummary> {
        try await underlying.renameSession(envelope: envelope)
    }
    public func deleteSession(envelope: CommandEnvelope<DeleteSessionRequest>) async throws -> CommandReceipt<VoidResult> {
        try await underlying.deleteSession(envelope: envelope)
    }
    public func setSessionReasoningEffort(envelope: CommandEnvelope<SetSessionReasoningEffortRequest>) async throws -> CommandReceipt<SessionSummary> {
        try await underlying.setSessionReasoningEffort(envelope: envelope)
    }
    public func getSession(envelope: QueryEnvelope<GetSessionRequest>) async throws -> ResponseEnvelope<SessionSummary> {
        try await underlying.getSession(envelope: envelope)
    }
    public func listSessions(envelope: QueryEnvelope<PageRequest>) async throws -> ResponseEnvelope<Page<SessionSummary>> {
        try await underlying.listSessions(envelope: envelope)
    }
    public func getSessionSnapshot(envelope: QueryEnvelope<GetSessionSnapshotRequest>) async throws -> ResponseEnvelope<SessionSnapshot> {
        try await underlying.getSessionSnapshot(envelope: envelope)
    }
    public func submitTurn(envelope: CommandEnvelope<SubmitTurnRequest>) async throws -> CommandReceipt<SubmitTurnResult> {
        try await underlying.submitTurn(envelope: envelope)
    }
    public func cancelTurn(envelope: CommandEnvelope<CancelTurnRequest>) async throws -> CommandReceipt<VoidResult> {
        try await underlying.cancelTurn(envelope: envelope)
    }
    public func getTurn(envelope: QueryEnvelope<GetTurnRequest>) async throws -> ResponseEnvelope<TurnSnapshot> {
        try await underlying.getTurn(envelope: envelope)
    }
    public func listTurns(envelope: QueryEnvelope<ListTurnsRequest>) async throws -> ResponseEnvelope<Page<TurnSnapshot>> {
        try await underlying.listTurns(envelope: envelope)
    }
    public func cancelRun(envelope: CommandEnvelope<CancelRunRequest>) async throws -> CommandReceipt<VoidResult> {
        try await underlying.cancelRun(envelope: envelope)
    }
    public func resumeRun(envelope: CommandEnvelope<ResumeRunRequest>) async throws -> CommandReceipt<RunSnapshot> {
        try await underlying.resumeRun(envelope: envelope)
    }
    public func getRun(envelope: QueryEnvelope<GetRunRequest>) async throws -> ResponseEnvelope<RunSnapshot> {
        try await underlying.getRun(envelope: envelope)
    }
    public func listRuns(envelope: QueryEnvelope<ListRunsRequest>) async throws -> ResponseEnvelope<Page<RunSnapshot>> {
        try await underlying.listRuns(envelope: envelope)
    }
    public func getAgentTree(envelope: QueryEnvelope<GetAgentTreeRequest>) async throws -> ResponseEnvelope<AgentTreeNode> {
        try await underlying.getAgentTree(envelope: envelope)
    }
    public func listPendingInteractions(envelope: QueryEnvelope<ListInteractionsRequest>) async throws -> ResponseEnvelope<[InteractionSnapshot]> {
        try await underlying.listPendingInteractions(envelope: envelope)
    }
    public func resolveInteraction(envelope: CommandEnvelope<ResolveInteractionRequest>) async throws -> CommandReceipt<VoidResult> {
        try await underlying.resolveInteraction(envelope: envelope)
    }
    public func listProviders(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[ProviderAccountInfo]> {
        try await underlying.listProviders(envelope: envelope)
    }
    public func getProviderStatus(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ProviderStatus> {
        try await underlying.getProviderStatus(envelope: envelope)
    }
    public func getProvider(envelope: QueryEnvelope<GetProviderRequest>) async throws -> ResponseEnvelope<ProviderAccountInfo> {
        try await underlying.getProvider(envelope: envelope)
    }
    public func testProvider(envelope: CommandEnvelope<TestProviderRequest>) async throws -> CommandReceipt<TestProviderResult> {
        try await underlying.testProvider(envelope: envelope)
    }
    public func configureProvider(envelope: CommandEnvelope<ConfigureProviderRequest>) async throws -> CommandReceipt<ProviderAccountInfo> {
        try await underlying.configureProvider(envelope: envelope)
    }
    public func removeProvider(envelope: CommandEnvelope<RemoveProviderRequest>) async throws -> CommandReceipt<VoidResult> {
        try await underlying.removeProvider(envelope: envelope)
    }
    public func reloadProviders(envelope: CommandEnvelope<VoidResult>) async throws -> CommandReceipt<VoidResult> {
        try await underlying.reloadProviders(envelope: envelope)
    }
    public func listModels(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[ProviderModelInfo]> {
        try await underlying.listModels(envelope: envelope)
    }
    public func getModelSelection(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ModelSelectionInfo> {
        try await underlying.getModelSelection(envelope: envelope)
    }
    public func selectModel(envelope: CommandEnvelope<SelectModelRequest>) async throws -> CommandReceipt<ModelSelectionInfo> {
        try await underlying.selectModel(envelope: envelope)
    }
    public func getModel(envelope: QueryEnvelope<GetModelRequest>) async throws -> ResponseEnvelope<ProviderModelInfo> {
        try await underlying.getModel(envelope: envelope)
    }
    public func getModelCapabilities(envelope: QueryEnvelope<GetModelCapabilitiesRequest>) async throws -> ResponseEnvelope<ModelCapabilitiesInfo> {
        try await underlying.getModelCapabilities(envelope: envelope)
    }
    public func setModelSelection(envelope: CommandEnvelope<SetModelSelectionRequest>) async throws -> CommandReceipt<ModelSelectionInfo> {
        try await underlying.setModelSelection(envelope: envelope)
    }
    public func getContextState(envelope: QueryEnvelope<GetContextStateRequest>) async throws -> ResponseEnvelope<ContextStateSnapshot> {
        try await underlying.getContextState(envelope: envelope)
    }
    public func getContextPolicy(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ContextCachePolicySnapshot> {
        try await underlying.getContextPolicy(envelope: envelope)
    }
    public func compactContext(envelope: CommandEnvelope<CompactContextRequest>) async throws -> CommandReceipt<VoidResult> {
        try await underlying.compactContext(envelope: envelope)
    }
    public func searchContext(envelope: QueryEnvelope<SearchContextRequest>) async throws -> ResponseEnvelope<[ContextSearchResultItem]> {
        try await underlying.searchContext(envelope: envelope)
    }
    public func getContextEntry(envelope: QueryEnvelope<GetContextEntryRequest>) async throws -> ResponseEnvelope<ContextEntryItem> {
        try await underlying.getContextEntry(envelope: envelope)
    }
    public func updateContextPolicy(envelope: CommandEnvelope<UpdateContextPolicyRequest>) async throws -> CommandReceipt<ContextCachePolicySnapshot> {
        try await underlying.updateContextPolicy(envelope: envelope)
    }
    public func listExtensions(envelope: QueryEnvelope<ListExtensionsRequest>) async throws -> ResponseEnvelope<[ExtensionInfo]> {
        try await underlying.listExtensions(envelope: envelope)
    }
    public func getExtensionStatus(envelope: QueryEnvelope<GetExtensionStatusRequest>) async throws -> ResponseEnvelope<ExtensionInfo> {
        try await underlying.getExtensionStatus(envelope: envelope)
    }
    public func getExtension(envelope: QueryEnvelope<GetExtensionRequest>) async throws -> ResponseEnvelope<ExtensionInfo> {
        try await underlying.getExtension(envelope: envelope)
    }
    public func installExtension(envelope: CommandEnvelope<InstallExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo> {
        try await underlying.installExtension(envelope: envelope)
    }
    public func uninstallExtension(envelope: CommandEnvelope<UninstallExtensionRequest>) async throws -> CommandReceipt<VoidResult> {
        try await underlying.uninstallExtension(envelope: envelope)
    }
    public func enableExtension(envelope: CommandEnvelope<EnableExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo> {
        try await underlying.enableExtension(envelope: envelope)
    }
    public func disableExtension(envelope: CommandEnvelope<DisableExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo> {
        try await underlying.disableExtension(envelope: envelope)
    }
    public func reloadExtensions(envelope: CommandEnvelope<VoidResult>) async throws -> CommandReceipt<VoidResult> {
        try await underlying.reloadExtensions(envelope: envelope)
    }
    public func configureExtension(envelope: CommandEnvelope<ConfigureExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo> {
        try await underlying.configureExtension(envelope: envelope)
    }
    public func getWorkspace(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<WorkspaceSummary> {
        try await underlying.getWorkspace(envelope: envelope)
    }
    public func setWorkspace(envelope: CommandEnvelope<SetWorkspaceRequest>) async throws -> CommandReceipt<WorkspaceSummary> {
        try await underlying.setWorkspace(envelope: envelope)
    }
    public func getWorkspaceSummary(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<WorkspaceSummary> {
        try await underlying.getWorkspaceSummary(envelope: envelope)
    }
    public func getWorkspaceDiffSummary(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<WorkspaceDiffSummary> {
        try await underlying.getWorkspaceDiffSummary(envelope: envelope)
    }
    public func beginContentUpload(envelope: CommandEnvelope<BeginContentUploadRequest>) async throws -> CommandReceipt<BeginContentUploadResponse> {
        try await underlying.beginContentUpload(envelope: envelope)
    }
    public func uploadContentChunk(uploadID: String, chunkIndex: UInt64, data: Data) async throws {
        try await underlying.uploadContentChunk(uploadID: uploadID, chunkIndex: chunkIndex, data: data)
    }
    public func commitContentUpload(envelope: CommandEnvelope<CommitContentUploadRequest>) async throws -> CommandReceipt<ContentRef> {
        try await underlying.commitContentUpload(envelope: envelope)
    }
    public func abortContentUpload(envelope: CommandEnvelope<AbortContentUploadRequest>) async throws -> CommandReceipt<VoidResult> {
        try await underlying.abortContentUpload(envelope: envelope)
    }
    public func getContentMetadata(ref: ContentRef, authorization: ContentAuthorizationContext) async throws -> ContentMetadata {
        try await underlying.getContentMetadata(ref: ref, authorization: self.authorizationContext)
    }
    public func getContent(ref: ContentRef, authorization: ContentAuthorizationContext) async throws -> Data {
        try await underlying.getContent(ref: ref, authorization: self.authorizationContext)
    }
    public func getContentRange(ref: ContentRef, offset: Int, length: Int, authorization: ContentAuthorizationContext) async throws -> Data {
        try await underlying.getContentRange(ref: ref, offset: offset, length: length, authorization: self.authorizationContext)
    }
    public func getDiagnostics(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeDiagnosticsBundle> {
        try await underlying.getDiagnostics(envelope: envelope)
    }
    public func getPerformanceMetrics(envelope: QueryEnvelope<GetPerformanceMetricsRequest>) async throws -> ResponseEnvelope<TurnPerformanceReport?> {
        try await underlying.getPerformanceMetrics(envelope: envelope)
    }
    public func getProviderMetrics(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ProviderMetricsInfo> {
        try await underlying.getProviderMetrics(envelope: envelope)
    }
    public func getRunTrace(envelope: QueryEnvelope<GetRunTraceRequest>) async throws -> ResponseEnvelope<RunTraceInfo> {
        try await underlying.getRunTrace(envelope: envelope)
    }
    public func listCredentials(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[CredentialRef]> {
        try await underlying.listCredentials(envelope: envelope)
    }
    public func storeCredential(envelope: CommandEnvelope<StoreCredentialRequest>) async throws -> CommandReceipt<CredentialResult> {
        try await underlying.storeCredential(envelope: envelope)
    }
    public func deleteCredential(envelope: CommandEnvelope<DeleteCredentialRequest>) async throws -> CommandReceipt<VoidResult> {
        try await underlying.deleteCredential(envelope: envelope)
    }
    public func getCredentialStatus(envelope: QueryEnvelope<GetCredentialStatusRequest>) async throws -> ResponseEnvelope<CredentialStatusInfo> {
        try await underlying.getCredentialStatus(envelope: envelope)
    }
    public func testCredential(envelope: CommandEnvelope<TestCredentialRequest>) async throws -> CommandReceipt<TestCredentialResult> {
        try await underlying.testCredential(envelope: envelope)
    }
}
