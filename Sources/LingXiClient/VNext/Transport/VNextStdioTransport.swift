import Foundation
import LingXiProtocol

private struct VNextWireRequest: Codable {
    let id: String
    let method: String
    let payload: Data?
}

private struct VNextWireResponse: Codable {
    let id: String
    let payload: Data?
    let error: CoreError?
}

private struct VNextWirePush: Codable {
    let kind: String
    let subscriptionID: String
    let payload: Data
}

private enum VNextWireError: Error {
    case disconnected
    case invalidResponse
}

/// VNext JSON-lines transport. The wire adapter stays in Client; Application never sees it.
public final class VNextStdioTransport: ClientTransport, @unchecked Sendable {
    private let process: Process?
    private let input: FileHandle
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var runtimeContinuations: [String: AsyncStream<RuntimeEventEnvelope>.Continuation] = [:]
    private var sessionContinuations: [String: AsyncStream<SessionEventEnvelope>.Continuation] = [:]
    private var frameContinuations: [String: AsyncStream<StreamFrame>.Continuation] = [:]
    private var stateContinuation: AsyncStream<ConnectionState>.Continuation?
    private var terminalError: CoreError?
    private var currentState = ConnectionState.disconnected
    private let stateStorage: AsyncStream<ConnectionState>
    public let authorizationContext: ContentAuthorizationContext = .anonymous

    public init(corePath: String? = nil, interactive: Bool = true) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.resolveCorePath(corePath))
        process.arguments = ["--vnext"]
        if interactive {
            process.environment = ProcessInfo.processInfo.environment.merging(["LINGXI_INTERACTIVE": "1"]) { _, new in new }
        }
        Self.trace("process.run.begin path=\(process.executableURL?.path ?? "")")
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        self.process = process
        self.input = inputPipe.fileHandleForWriting
        var continuation: AsyncStream<ConnectionState>.Continuation!
        self.stateStorage = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation
        try process.run()
        Self.trace("process.run.end")
        Task { [weak self] in await self?.readLoop(pipe: outputPipe) }
    }

    public init(inputHandle: FileHandle, outputPipe: Pipe, process: Process? = nil) {
        self.process = process
        self.input = inputHandle
        var continuation: AsyncStream<ConnectionState>.Continuation!
        self.stateStorage = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation
        Task { [weak self] in await self?.readLoop(pipe: outputPipe) }
    }

    public var connectionState: ConnectionState {
        get async {
            withLock { currentState }
        }
    }

    public var stateStream: AsyncStream<ConnectionState> { stateStorage }

    public func connect() async throws {
        debug("connect.begin")
        updateState(.connecting)
        updateState(.handshaking)
        _ = try decoder.decode(ResponseEnvelope<RuntimeInfo>.self, from: try await send(method: "runtime.info", payload: try encoder.encode(VoidResult())))
        updateState(.connected(version: .current, capabilities: RuntimeCapabilities()))
        debug("connect.end")
    }

    public func disconnect() async {
        let (error, continuations) = withLock { () -> (CoreError, [CheckedContinuation<Data, Error>]) in
            terminalError = CoreError(code: .transport, message: "Core 连接已关闭")
            let error = terminalError!
            let continuations = Array(pending.values)
            pending.removeAll()
            return (error, continuations)
        }
        for continuation in continuations { continuation.resume(throwing: error) }
        try? input.close()
        if let process, process.isRunning { process.terminate() }
        updateState(.disconnected)
    }

    public func getRuntimeInfo(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeInfo> { try await response("runtime.info", envelope.payload) }
    public func getRuntimeHealth(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeHealth> { try await response("runtime.health", envelope.payload) }
    public func getRuntimeCapabilities(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeCapabilities> { try await response("runtime.capabilities", envelope.payload) }
    public func getEffectiveConfiguration(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<EffectiveConfigurationSnapshot> { try await response("runtime.config", envelope.payload) }
    public func reloadConfiguration(envelope: CommandEnvelope<VoidResult>) async throws -> CommandReceipt<VoidResult> { try await command("runtime.config.reload", envelope.payload) }
    public func updateTypedSetting(envelope: CommandEnvelope<UpdateTypedSettingRequest>) async throws -> CommandReceipt<VoidResult> { try await command("runtime.setting.update", envelope.payload) }

    public func createSession(envelope: CommandEnvelope<CreateSessionRequest>) async throws -> CommandReceipt<SessionSummary> { try await command("session.create", envelope.payload) }
    public func renameSession(envelope: CommandEnvelope<RenameSessionRequest>) async throws -> CommandReceipt<SessionSummary> { try await command("session.rename", envelope.payload) }
    public func setSessionReasoningEffort(envelope: CommandEnvelope<SetSessionReasoningEffortRequest>) async throws -> CommandReceipt<SessionSummary> { try await command("session.set_reasoning_effort", envelope.payload) }
    public func deleteSession(envelope: CommandEnvelope<DeleteSessionRequest>) async throws -> CommandReceipt<VoidResult> { try await command("session.delete", envelope.payload) }
    public func getSession(envelope: QueryEnvelope<GetSessionRequest>) async throws -> ResponseEnvelope<SessionSummary> { try await response("session.get", envelope.payload) }
    public func listSessions(envelope: QueryEnvelope<PageRequest>) async throws -> ResponseEnvelope<Page<SessionSummary>> { try await response("session.list", envelope.payload) }
    public func getSessionSnapshot(envelope: QueryEnvelope<GetSessionSnapshotRequest>) async throws -> ResponseEnvelope<SessionSnapshot> { try await response("session.snapshot", envelope.payload) }

    public func submitTurn(envelope: CommandEnvelope<SubmitTurnRequest>) async throws -> CommandReceipt<SubmitTurnResult> { try await command("turn.submit", envelope.payload) }
    public func cancelTurn(envelope: CommandEnvelope<CancelTurnRequest>) async throws -> CommandReceipt<VoidResult> { try await command("turn.cancel", envelope.payload) }
    public func getTurn(envelope: QueryEnvelope<GetTurnRequest>) async throws -> ResponseEnvelope<TurnSnapshot> { try await response("turn.get", envelope.payload) }
    public func listTurns(envelope: QueryEnvelope<ListTurnsRequest>) async throws -> ResponseEnvelope<Page<TurnSnapshot>> { try await response("turn.list", envelope.payload) }

    public func cancelRun(envelope: CommandEnvelope<CancelRunRequest>) async throws -> CommandReceipt<VoidResult> { try await command("run.cancel", envelope.payload) }
    public func resumeRun(envelope: CommandEnvelope<ResumeRunRequest>) async throws -> CommandReceipt<RunSnapshot> { try await command("run.resume", envelope.payload) }
    public func getRun(envelope: QueryEnvelope<GetRunRequest>) async throws -> ResponseEnvelope<RunSnapshot> { try await response("run.get", envelope.payload) }
    public func listRuns(envelope: QueryEnvelope<ListRunsRequest>) async throws -> ResponseEnvelope<Page<RunSnapshot>> { try await response("run.list", envelope.payload) }
    public func getAgentTree(envelope: QueryEnvelope<GetAgentTreeRequest>) async throws -> ResponseEnvelope<AgentTreeNode> { try await response("agent.tree", envelope.payload) }

    public func listPendingInteractions(envelope: QueryEnvelope<ListInteractionsRequest>) async throws -> ResponseEnvelope<[InteractionSnapshot]> { try await response("interaction.list", envelope.payload) }
    public func resolveInteraction(envelope: CommandEnvelope<ResolveInteractionRequest>) async throws -> CommandReceipt<VoidResult> { try await command("interaction.resolve", envelope.payload) }

    public func listProviders(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[ProviderAccountInfo]> { try await response("provider.list", envelope.payload) }
    public func getProviderStatus(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ProviderStatus> { try await response("provider.status", envelope.payload) }
    public func getProvider(envelope: QueryEnvelope<GetProviderRequest>) async throws -> ResponseEnvelope<ProviderAccountInfo> { try await response("provider.get", envelope.payload) }
    public func testProvider(envelope: CommandEnvelope<TestProviderRequest>) async throws -> CommandReceipt<TestProviderResult> { try await command("provider.test", envelope.payload) }
    public func configureProvider(envelope: CommandEnvelope<ConfigureProviderRequest>) async throws -> CommandReceipt<ProviderAccountInfo> { try await command("provider.configure", envelope.payload) }
    public func removeProvider(envelope: CommandEnvelope<RemoveProviderRequest>) async throws -> CommandReceipt<VoidResult> { try await command("provider.remove", envelope.payload) }
    public func reloadProviders(envelope: CommandEnvelope<VoidResult>) async throws -> CommandReceipt<VoidResult> { try await command("provider.reload", envelope.payload) }

    public func listModels(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[ProviderModelInfo]> { try await response("model.list", envelope.payload) }
    public func getModelSelection(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ModelSelectionInfo> { try await response("model.selection", envelope.payload) }
    public func selectModel(envelope: CommandEnvelope<SelectModelRequest>) async throws -> CommandReceipt<ModelSelectionInfo> { try await command("model.select", envelope.payload) }
    public func getModel(envelope: QueryEnvelope<GetModelRequest>) async throws -> ResponseEnvelope<ProviderModelInfo> { try await response("model.get", envelope.payload) }
    public func getModelCapabilities(envelope: QueryEnvelope<GetModelCapabilitiesRequest>) async throws -> ResponseEnvelope<ModelCapabilitiesInfo> { try await response("model.capabilities", envelope.payload) }
    public func setModelSelection(envelope: CommandEnvelope<SetModelSelectionRequest>) async throws -> CommandReceipt<ModelSelectionInfo> { try await command("model.select", envelope.payload) }

    public func getContextState(envelope: QueryEnvelope<GetContextStateRequest>) async throws -> ResponseEnvelope<ContextStateSnapshot> { try await response("context.state", envelope.payload) }
    public func getContextPolicy(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ContextCachePolicySnapshot> { try await response("context.policy", envelope.payload) }
    public func compactContext(envelope: CommandEnvelope<CompactContextRequest>) async throws -> CommandReceipt<VoidResult> { try await command("context.compact", envelope.payload) }
    public func searchContext(envelope: QueryEnvelope<SearchContextRequest>) async throws -> ResponseEnvelope<[ContextSearchResultItem]> { try await response("context.search", envelope.payload) }
    public func getContextEntry(envelope: QueryEnvelope<GetContextEntryRequest>) async throws -> ResponseEnvelope<ContextEntryItem> { try await response("context.entry", envelope.payload) }
    public func updateContextPolicy(envelope: CommandEnvelope<UpdateContextPolicyRequest>) async throws -> CommandReceipt<ContextCachePolicySnapshot> { try await command("context.policy.update", envelope.payload) }

    public func listExtensions(envelope: QueryEnvelope<ListExtensionsRequest>) async throws -> ResponseEnvelope<[ExtensionInfo]> { try await response("extension.list", envelope.payload) }
    public func getExtensionStatus(envelope: QueryEnvelope<GetExtensionStatusRequest>) async throws -> ResponseEnvelope<ExtensionInfo> { try await response("extension.status", envelope.payload) }
    public func getExtension(envelope: QueryEnvelope<GetExtensionRequest>) async throws -> ResponseEnvelope<ExtensionInfo> { try await response("extension.get", envelope.payload) }
    public func installExtension(envelope: CommandEnvelope<InstallExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo> { try await command("extension.install", envelope.payload) }
    public func uninstallExtension(envelope: CommandEnvelope<UninstallExtensionRequest>) async throws -> CommandReceipt<VoidResult> { try await command("extension.uninstall", envelope.payload) }
    public func enableExtension(envelope: CommandEnvelope<EnableExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo> { try await command("extension.enable", envelope.payload) }
    public func disableExtension(envelope: CommandEnvelope<DisableExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo> { try await command("extension.disable", envelope.payload) }
    public func reloadExtensions(envelope: CommandEnvelope<VoidResult>) async throws -> CommandReceipt<VoidResult> { try await command("extension.reload", envelope.payload) }
    public func configureExtension(envelope: CommandEnvelope<ConfigureExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo> { try await command("extension.configure", envelope.payload) }

    public func getWorkspace(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<WorkspaceSummary> { try await response("workspace.get", envelope.payload) }
    public func setWorkspace(envelope: CommandEnvelope<SetWorkspaceRequest>) async throws -> CommandReceipt<WorkspaceSummary> { try await command("workspace.set", envelope.payload) }
    public func getWorkspaceSummary(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<WorkspaceSummary> { try await response("workspace.get", envelope.payload) }
    public func getWorkspaceDiffSummary(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<WorkspaceDiffSummary> { try await response("workspace.diff", envelope.payload) }

    public func beginContentUpload(envelope: CommandEnvelope<BeginContentUploadRequest>) async throws -> CommandReceipt<BeginContentUploadResponse> { try await unsupported() }
    public func uploadContentChunk(uploadID: String, chunkIndex: UInt64, data: Data) async throws { try await unsupportedVoid() }
    public func commitContentUpload(envelope: CommandEnvelope<CommitContentUploadRequest>) async throws -> CommandReceipt<ContentRef> { try await unsupported() }
    public func abortContentUpload(envelope: CommandEnvelope<AbortContentUploadRequest>) async throws -> CommandReceipt<VoidResult> { try await unsupported() }
    public func getContentMetadata(ref: ContentRef, authorization: ContentAuthorizationContext) async throws -> ContentMetadata { try await unsupported() }
    public func getContent(ref: ContentRef, authorization: ContentAuthorizationContext) async throws -> Data { try await unsupported() }
    public func getContentRange(ref: ContentRef, offset: Int, length: Int, authorization: ContentAuthorizationContext) async throws -> Data { try await unsupported() }

    public func getDiagnostics(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeDiagnosticsBundle> { try await response("diagnostics.get", envelope.payload) }
    public func getPerformanceMetrics(envelope: QueryEnvelope<GetPerformanceMetricsRequest>) async throws -> ResponseEnvelope<TurnPerformanceReport?> { try await response("diagnostics.performance", envelope.payload) }
    public func getProviderMetrics(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ProviderMetricsInfo> { try await response("diagnostics.providerMetrics", envelope.payload) }
    public func getRunTrace(envelope: QueryEnvelope<GetRunTraceRequest>) async throws -> ResponseEnvelope<RunTraceInfo> { try await response("diagnostics.runTrace", envelope.payload) }
    public func listCredentials(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[CredentialRef]> { try await response("credential.list", envelope.payload) }
    public func storeCredential(envelope: CommandEnvelope<StoreCredentialRequest>) async throws -> CommandReceipt<CredentialResult> { try await command("credential.store", envelope.payload) }
    public func deleteCredential(envelope: CommandEnvelope<DeleteCredentialRequest>) async throws -> CommandReceipt<VoidResult> { try await command("credential.delete", envelope.payload) }
    public func getCredentialStatus(envelope: QueryEnvelope<GetCredentialStatusRequest>) async throws -> ResponseEnvelope<CredentialStatusInfo> { try await response("credential.status", envelope.payload) }
    public func testCredential(envelope: CommandEnvelope<TestCredentialRequest>) async throws -> CommandReceipt<TestCredentialResult> { try await command("credential.test", envelope.payload) }

    public func subscribeRuntimeEvents(after: EventCursor?) async -> AsyncStream<RuntimeEventEnvelope> {
        let id = makeID()
        let (stream, continuation) = AsyncStream<RuntimeEventEnvelope>.makeStream()
        withLock { runtimeContinuations[id] = continuation }
        Task { try? await self.send(method: "events.runtime", payload: after.map { try? self.encoder.encode($0) } ?? nil, id: id) }
        continuation.onTermination = { [weak self] _ in self?.removeRuntime(id) }
        return stream
    }

    public func subscribeSessionEvents(sessionID: SessionID, after: EventCursor?) async throws -> AsyncStream<SessionEventEnvelope> {
        let id = makeID()
        let (stream, continuation) = AsyncStream<SessionEventEnvelope>.makeStream()
        withLock { sessionContinuations[id] = continuation }
        let payload = try encoder.encode(SessionEventSubscription(sessionID: sessionID, after: after))
        do { _ = try await send(method: "events.session", payload: payload, id: id) }
        catch { removeSession(id); throw error }
        continuation.onTermination = { [weak self] _ in self?.removeSession(id) }
        return stream
    }

    public func listSessionEvents(request: ListSessionEventsRequest) async throws -> [SessionEventEnvelope] {
        try decoder.decode([SessionEventEnvelope].self, from: try await send(method: "events.session.list", payload: encoder.encode(request)))
    }

    public func subscribeStreamFrames(streamID: StreamID, afterIndex: UInt64?) async throws -> AsyncStream<StreamFrame> {
        let id = makeID()
        let (stream, continuation) = AsyncStream<StreamFrame>.makeStream()
        withLock { frameContinuations[id] = continuation }
        let payload = try encoder.encode(StreamSubscription(streamID: streamID, afterIndex: afterIndex))
        do { _ = try await send(method: "events.stream", payload: payload, id: id) }
        catch { removeFrame(id); throw error }
        continuation.onTermination = { [weak self] _ in self?.removeFrame(id) }
        return stream
    }

    private func response<Request: Encodable, Response: Codable & Sendable>(_ method: String, _ payload: Request) async throws -> ResponseEnvelope<Response> {
        try decoder.decode(ResponseEnvelope<Response>.self, from: await send(method: method, payload: encoder.encode(payload)))
    }

    private func command<Request: Encodable, Result: Codable & Sendable>(_ method: String, _ payload: Request) async throws -> CommandReceipt<Result> {
        try decoder.decode(CommandReceipt<Result>.self, from: await send(method: method, payload: encoder.encode(payload)))
    }

    private func unsupported<Response: Decodable>() async throws -> Response { throw CoreError(code: .unsupportedCommand, message: "VNext stdio operation is not exposed") }
    private func unsupportedVoid() async throws { throw CoreError(code: .unsupportedCommand, message: "VNext stdio operation is not exposed") }

    private func send(method: String, payload: Data?, id: String? = nil) async throws -> Data {
        let requestID = id ?? makeID()
        debug("send.begin id=\(requestID) method=\(method)")
        let data = try encoder.encode(VNextWireRequest(id: requestID, method: method, payload: payload)) + Data("\n".utf8)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let terminalError { lock.unlock(); continuation.resume(throwing: terminalError); return }
            pending[requestID] = continuation
            do { try input.write(contentsOf: data); lock.unlock() }
            catch { pending.removeValue(forKey: requestID); lock.unlock(); continuation.resume(throwing: error) }
        }
    }

    private func makeID() -> String {
        lock.lock(); defer { lock.unlock() }; nextID += 1; return String(nextID)
    }

    private func readLoop(pipe: Pipe) async {
        debug("readLoop.begin")
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                if let data = line.data(using: .utf8) { handle(data) }
            }
        } catch { fail(CoreError(code: .transport, message: String(describing: error))) }
        debug("readLoop.end")
        fail(CoreError(code: .transport, message: "Core 连接已关闭"))
    }

    private func handle(_ data: Data) {
        if let response = try? decoder.decode(VNextWireResponse.self, from: data) {
            debug("response id=\(response.id)")
            lock.lock(); let continuation = pending.removeValue(forKey: response.id); lock.unlock()
            if let error = response.error { continuation?.resume(throwing: error) }
            else { continuation?.resume(returning: response.payload ?? Data()) }
            return
        }
        guard let push = try? decoder.decode(VNextWirePush.self, from: data) else { return }
        switch push.kind {
        case "runtime": if let value = try? decoder.decode(RuntimeEventEnvelope.self, from: push.payload) { lock.lock(); runtimeContinuations[push.subscriptionID]?.yield(value); lock.unlock() }
        case "session": if let value = try? decoder.decode(SessionEventEnvelope.self, from: push.payload) { lock.lock(); sessionContinuations[push.subscriptionID]?.yield(value); lock.unlock() }
        case "frame": if let value = try? decoder.decode(StreamFrame.self, from: push.payload) { lock.lock(); frameContinuations[push.subscriptionID]?.yield(value); lock.unlock() }
        default: break
        }
    }

    private func fail(_ error: CoreError) {
        lock.lock(); guard terminalError == nil else { lock.unlock(); return }; terminalError = error; let values = pending.values; pending.removeAll(); lock.unlock()
        for continuation in values { continuation.resume(throwing: error) }
        updateState(.failed(detail: error.message))
    }

    private func updateState(_ value: ConnectionState) { withLock { currentState = value }; stateContinuation?.yield(value) }
    private func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    private func removeRuntime(_ id: String) { lock.lock(); runtimeContinuations.removeValue(forKey: id)?.finish(); lock.unlock() }
    private func removeSession(_ id: String) { lock.lock(); sessionContinuations.removeValue(forKey: id)?.finish(); lock.unlock() }
    private func removeFrame(_ id: String) { lock.lock(); frameContinuations.removeValue(forKey: id)?.finish(); lock.unlock() }

    private func debug(_ message: String) {
        Self.trace(message)
    }

    private static func trace(_ message: String) {
        guard ProcessInfo.processInfo.environment["LINGXI_TUI_DEBUG"] == "1" else { return }
        let timestamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        FileHandle.standardError.write(Data("[\(timestamp)] [VNextStdioTransport] \(message)\n".utf8))
    }

    private static func resolveCorePath(_ value: String?) -> String {
        if let value { return value }
        if let env = ProcessInfo.processInfo.environment["LINGXI_CORE_PATH"] { return env }
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("LingXiCoreHost").path
    }
}

private struct SessionEventSubscription: Codable { let sessionID: SessionID; let after: EventCursor? }
private struct StreamSubscription: Codable { let streamID: StreamID; let afterIndex: UInt64? }
