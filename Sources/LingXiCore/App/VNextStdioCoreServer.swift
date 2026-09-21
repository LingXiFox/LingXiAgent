import Foundation
import LingXiProtocol

private struct VNextWireRequest: Codable {
    let id: String
    let method: String
    let payload: Data?
    let commandID: CommandID?
    let expectedRevision: UInt64?
    let issuedAt: Date?
    let requestID: RequestID?

    init(
        id: String,
        method: String,
        payload: Data?,
        commandID: CommandID? = nil,
        expectedRevision: UInt64? = nil,
        issuedAt: Date? = nil,
        requestID: RequestID? = nil
    ) {
        self.id = id
        self.method = method
        self.payload = payload
        self.commandID = commandID
        self.expectedRevision = expectedRevision
        self.issuedAt = issuedAt
        self.requestID = requestID
    }
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

private struct SessionEventSubscription: Codable { let sessionID: SessionID; let after: EventCursor? }
private struct StreamSubscription: Codable { let streamID: StreamID; let afterIndex: UInt64? }

private final class ConnectionTaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var finishedIDs: Set<String> = []
    private var finishedIDOrder: [String] = []
    private let maxTombstones = 1024

    func register(id: String, task: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if finishedIDs.contains(id) {
            finishedIDs.remove(id)
        } else {
            tasks[id] = task
        }
    }

    func unregister(id: String) {
        lock.lock()
        defer { lock.unlock() }
        if tasks.removeValue(forKey: id) == nil {
            recordFinished(id)
        }
    }

    func cancel(id: String) {
        lock.lock()
        let task = tasks.removeValue(forKey: id)
        recordFinished(id)
        lock.unlock()
        task?.cancel()
    }

    private func recordFinished(_ id: String) {
        finishedIDs.insert(id)
        finishedIDOrder.append(id)
        if finishedIDOrder.count > maxTombstones {
            let oldest = finishedIDOrder.removeFirst()
            finishedIDs.remove(oldest)
        }
    }

    private func extractAndClearTasks() -> [Task<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        let all = Array(tasks.values)
        tasks.removeAll()
        finishedIDs.removeAll()
        finishedIDOrder.removeAll()
        return all
    }

    func drainAll() async {
        let all = extractAndClearTasks()
        for task in all {
            task.cancel()
        }
        for task in all {
            _ = await task.value
        }
    }
}

/// JSON-lines server for the VNext Application composition root.
public struct VNextStdioCoreServer: Sendable {
    private let service: any LingXiProtocolService
    private let input: FileHandle
    private let output: FileHandle
    private let connectionTasks = ConnectionTaskRegistry()

    public init(service: any LingXiProtocolService, input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        self.service = service
        self.input = input
        self.output = output
    }

    public func run() async throws {
        let writer = VNextWireWriter(output: output)
        try await withTaskCancellationHandler {
            var buffer = Data()
            let maxLineBytes = ProtocolConstants.maxFrameBytes
            do {
                for try await chunk in LingXiPlatform.lineReader.dataChunks(from: input) {
                    guard !Task.isCancelled else { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[..<newline]
                        buffer.removeSubrange(...newline)

                        // 关键防御：严格在 JSON decode 之前拦截超大单行，杜绝大内存分配 (Audit Round 10 Phase C)
                        if line.count > maxLineBytes {
                            await writer.reply(id: "system", payload: nil, error: CoreError(code: .transport, message: "Line size \(line.count) exceeds maximum frame limit of \(maxLineBytes)"))
                            continue
                        }

                        do {
                            let request = try JSONDecoder().decode(VNextWireRequest.self, from: line)
                            handle(request, writer: writer)
                        } catch {
                            // 关键修复：恶意或异常格式不静默丢弃，尝试定位 requestID 回复错误响应，杜绝客户端永久挂死 (Audit Round 10 Phase C)
                            if let jsonObject = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                               let reqID = jsonObject["id"] as? String {
                                await writer.reply(id: reqID, payload: nil, error: CoreError(code: .unsupportedCommand, message: "Malformed JSON request payload: \(error.localizedDescription)"))
                            } else {
                                await writer.reply(id: "system", payload: nil, error: CoreError(code: .unsupportedCommand, message: "Malformed JSON request frame"))
                            }
                        }
                    }
                    if buffer.count > maxLineBytes {
                        buffer.removeAll()
                        await writer.reply(id: "system", payload: nil, error: CoreError(code: .transport, message: "Accumulated frame size exceeds \(maxLineBytes) limit"))
                    }
                }
            }
        } onCancel: {
            try? input.close()
        }
        await connectionTasks.drainAll()
    }

    private func handle(_ request: VNextWireRequest, writer: VNextWireWriter) {
        let task = Task {
            defer {
                connectionTasks.unregister(id: request.id)
            }
            guard !Task.isCancelled else { return }
            do {
                switch request.method {
                case "runtime.info": try await reply(request, try await service.getRuntimeInfo(envelope: queryEnvelope(request, as: VoidResult.self)), writer)
                case "runtime.health": try await reply(request, try await service.getRuntimeHealth(envelope: queryEnvelope(request, as: VoidResult.self)), writer)
                case "runtime.capabilities": try await reply(request, try await service.getRuntimeCapabilities(envelope: queryEnvelope(request, as: VoidResult.self)), writer)
                case "runtime.config": try await reply(request, try await service.getEffectiveConfiguration(envelope: queryEnvelope(request, as: VoidResult.self)), writer)
                case "runtime.config.reload": try await reply(request, try await service.reloadConfiguration(envelope: commandEnvelope(request, as: VoidResult.self)), writer)
                case "runtime.setting.update": try await reply(request, try await service.updateTypedSetting(envelope: commandEnvelope(request, as: UpdateTypedSettingRequest.self)), writer)
                case "session.create": try await reply(request, try await service.createSession(envelope: commandEnvelope(request, as: CreateSessionRequest.self)), writer)
                case "session.rename": try await reply(request, try await service.renameSession(envelope: commandEnvelope(request, as: RenameSessionRequest.self)), writer)
                case "session.set_reasoning_effort": try await reply(request, try await service.setSessionReasoningEffort(envelope: commandEnvelope(request, as: SetSessionReasoningEffortRequest.self)), writer)
                case "session.delete": try await reply(request, try await service.deleteSession(envelope: commandEnvelope(request, as: DeleteSessionRequest.self)), writer)
                case "session.revert_last_turn": try await reply(request, try await service.revertLastTurn(envelope: commandEnvelope(request, as: RevertLastTurnRequest.self)), writer)
                case "session.get": try await reply(request, try await service.getSession(envelope: queryEnvelope(request, as: GetSessionRequest.self)), writer)
                case "session.list": try await reply(request, try await service.listSessions(envelope: queryEnvelope(request, as: PageRequest.self)), writer)
                case "session.snapshot": try await reply(request, try await service.getSessionSnapshot(envelope: queryEnvelope(request, as: GetSessionSnapshotRequest.self)), writer)
                case "turn.submit": try await reply(request, try await service.submitTurn(envelope: commandEnvelope(request, as: SubmitTurnRequest.self)), writer)
                case "turn.cancel": try await reply(request, try await service.cancelTurn(envelope: commandEnvelope(request, as: CancelTurnRequest.self)), writer)
                case "turn.get": try await reply(request, try await service.getTurn(envelope: queryEnvelope(request, as: GetTurnRequest.self)), writer)
                case "turn.list": try await reply(request, try await service.listTurns(envelope: queryEnvelope(request, as: ListTurnsRequest.self)), writer)
                case "run.cancel": try await reply(request, try await service.cancelRun(envelope: commandEnvelope(request, as: CancelRunRequest.self)), writer)
                case "run.resume": try await reply(request, try await service.resumeRun(envelope: commandEnvelope(request, as: ResumeRunRequest.self)), writer)
                case "run.get": try await reply(request, try await service.getRun(envelope: queryEnvelope(request, as: GetRunRequest.self)), writer)
                case "run.list": try await reply(request, try await service.listRuns(envelope: queryEnvelope(request, as: ListRunsRequest.self)), writer)
                case "agent.tree": try await reply(request, try await service.getAgentTree(envelope: queryEnvelope(request, as: GetAgentTreeRequest.self)), writer)
                case "interaction.list": try await reply(request, try await service.listPendingInteractions(envelope: queryEnvelope(request, as: ListInteractionsRequest.self)), writer)
                case "interaction.resolve": try await reply(request, try await service.resolveInteraction(envelope: commandEnvelope(request, as: ResolveInteractionRequest.self)), writer)
                case "provider.list": try await reply(request, try await service.listProviders(envelope: queryEnvelope(request, as: VoidResult.self)), writer)
                case "provider.status": try await reply(request, try await service.getProviderStatus(envelope: queryEnvelope(request, as: VoidResult.self)), writer)
                case "provider.get": try await reply(request, try await service.getProvider(envelope: queryEnvelope(request, as: GetProviderRequest.self)), writer)
                case "provider.test": try await reply(request, try await service.testProvider(envelope: commandEnvelope(request, as: TestProviderRequest.self)), writer)
                case "provider.configure": try await reply(request, try await service.configureProvider(envelope: commandEnvelope(request, as: ConfigureProviderRequest.self)), writer)
                case "provider.remove": try await reply(request, try await service.removeProvider(envelope: commandEnvelope(request, as: RemoveProviderRequest.self)), writer)
                case "provider.reload": try await reply(request, try await service.reloadProviders(envelope: commandEnvelope(request, as: VoidResult.self)), writer)
                case "model.list": try await reply(request, try await service.listModels(envelope: queryEnvelope(request, as: VoidResult.self)), writer)
                case "model.selection": try await reply(request, try await service.getModelSelection(envelope: queryEnvelope(request, as: VoidResult.self)), writer)
                case "model.select": try await reply(request, try await service.selectModel(envelope: commandEnvelope(request, as: SelectModelRequest.self)), writer)
                case "model.get": try await reply(request, try await service.getModel(envelope: queryEnvelope(request, as: GetModelRequest.self)), writer)
                case "model.capabilities": try await reply(request, try await service.getModelCapabilities(envelope: queryEnvelope(request, as: GetModelCapabilitiesRequest.self)), writer)
                case "context.state": try await reply(request, try await service.getContextState(envelope: queryEnvelope(request, as: GetContextStateRequest.self)), writer)
                case "context.policy": try await reply(request, try await service.getContextPolicy(envelope: queryEnvelope(request, as: VoidResult.self)), writer)
                case "context.policy.update": try await reply(request, try await service.updateContextPolicy(envelope: commandEnvelope(request, as: UpdateContextPolicyRequest.self)), writer)
                case "context.compact": try await reply(request, try await service.compactContext(envelope: commandEnvelope(request, as: CompactContextRequest.self)), writer)
                case "context.search": try await reply(request, try await service.searchContext(envelope: queryEnvelope(request, as: SearchContextRequest.self)), writer)
                case "context.entry": try await reply(request, try await service.getContextEntry(envelope: queryEnvelope(request, as: GetContextEntryRequest.self)), writer)
                case "extension.list": try await reply(request, try await service.listExtensions(envelope: queryEnvelope(request, as: ListExtensionsRequest.self)), writer)
                case "extension.status": try await reply(request, try await service.getExtensionStatus(envelope: queryEnvelope(request, as: GetExtensionStatusRequest.self)), writer)
                case "extension.get": try await reply(request, try await service.getExtension(envelope: queryEnvelope(request, as: GetExtensionRequest.self)), writer)
                case "extension.install": try await reply(request, try await service.installExtension(envelope: commandEnvelope(request, as: InstallExtensionRequest.self)), writer)
                case "extension.uninstall": try await reply(request, try await service.uninstallExtension(envelope: commandEnvelope(request, as: UninstallExtensionRequest.self)), writer)
                case "extension.enable": try await reply(request, try await service.enableExtension(envelope: commandEnvelope(request, as: EnableExtensionRequest.self)), writer)
                case "extension.disable": try await reply(request, try await service.disableExtension(envelope: commandEnvelope(request, as: DisableExtensionRequest.self)), writer)
                case "extension.reload": try await reply(request, try await service.reloadExtensions(envelope: commandEnvelope(request, as: VoidResult.self)), writer)
                case "extension.configure": try await reply(request, try await service.configureExtension(envelope: commandEnvelope(request, as: ConfigureExtensionRequest.self)), writer)
                case "extension.executeCommand": try await reply(request, try await service.executeExtensionCommand(envelope: commandEnvelope(request, as: ExecuteExtensionCommandRequest.self)), writer)
                case "workspace.get": try await reply(request, try await service.getWorkspace(envelope: queryEnvelope(request, as: VoidResult.self)), writer)
                case "workspace.set": try await reply(request, try await service.setWorkspace(envelope: commandEnvelope(request, as: SetWorkspaceRequest.self)), writer)
                case "workspace.diff": try await reply(request, try await service.getWorkspaceDiffSummary(envelope: queryEnvelope(request, as: VoidResult.self)), writer)
                case "content.beginUpload": try await reply(request, try await service.beginContentUpload(envelope: commandEnvelope(request, as: BeginContentUploadRequest.self)), writer)
                case "content.uploadChunk":
                    let req = try decode(UploadContentChunkRequest.self, request.payload)
                    try await service.uploadContentChunk(uploadID: req.uploadID, chunkIndex: req.chunkIndex, data: req.payload.data)
                    let receipt = CommandReceipt<VoidResult>(commandID: request.commandID ?? CommandID(request.id), applied: true, revision: 0, observedThrough: [], result: VoidResult())
                    try await reply(request, receipt, writer)
                case "content.commitUpload": try await reply(request, try await service.commitContentUpload(envelope: commandEnvelope(request, as: CommitContentUploadRequest.self)), writer)
                case "content.abortUpload": try await reply(request, try await service.abortContentUpload(envelope: commandEnvelope(request, as: AbortContentUploadRequest.self)), writer)
                case "content.getMetadata":
                    let req = try decode(GetContentMetadataRequest.self, request.payload)
                    let auth = sanitizeContentAuthorization(req.authorization)
                    let meta = try await service.getContentMetadata(ref: req.ref, authorization: auth)
                    guard !Task.isCancelled else { return }
                    await writer.reply(id: request.id, payload: try? JSONEncoder().encode(meta), error: nil)
                case "content.get":
                    let req = try decode(GetContentRequest.self, request.payload)
                    let auth = sanitizeContentAuthorization(req.authorization)
                    let data = try await service.getContent(ref: req.ref, authorization: auth)
                    let payload = ContentBinaryPayload(data: data)
                    guard !Task.isCancelled else { return }
                    await writer.reply(id: request.id, payload: try? JSONEncoder().encode(payload), error: nil)
                case "content.getRange":
                    let req = try decode(GetContentRangeRequest.self, request.payload)
                    let auth = sanitizeContentAuthorization(req.authorization)
                    let data = try await service.getContentRange(ref: req.ref, offset: req.offset, length: req.length, authorization: auth)
                    let payload = ContentBinaryPayload(data: data)
                    guard !Task.isCancelled else { return }
                    await writer.reply(id: request.id, payload: try? JSONEncoder().encode(payload), error: nil)
                case "diagnostics.get": try await reply(request, try await service.getDiagnostics(envelope: queryEnvelope(request, as: VoidResult.self)), writer)
                case "diagnostics.performance": try await reply(request, try await service.getPerformanceMetrics(envelope: queryEnvelope(request, as: GetPerformanceMetricsRequest.self)), writer)
                case "diagnostics.providerMetrics": try await reply(request, try await service.getProviderMetrics(envelope: queryEnvelope(request, as: VoidResult.self)), writer)
                case "diagnostics.runTrace": try await reply(request, try await service.getRunTrace(envelope: queryEnvelope(request, as: GetRunTraceRequest.self)), writer)
                case "credential.list": try await reply(request, try await service.listCredentials(envelope: queryEnvelope(request, as: VoidResult.self)), writer)
                case "credential.store": try await reply(request, try await service.storeCredential(envelope: commandEnvelope(request, as: StoreCredentialRequest.self)), writer)
                case "credential.delete": try await reply(request, try await service.deleteCredential(envelope: commandEnvelope(request, as: DeleteCredentialRequest.self)), writer)
                case "credential.status": try await reply(request, try await service.getCredentialStatus(envelope: queryEnvelope(request, as: GetCredentialStatusRequest.self)), writer)
                case "credential.test": try await reply(request, try await service.testCredential(envelope: commandEnvelope(request, as: TestCredentialRequest.self)), writer)
                case "events.runtime":
                    guard !Task.isCancelled else { return }
                    await writer.reply(id: request.id, payload: nil, error: nil)
                    let after = request.payload.flatMap { try? JSONDecoder().decode(EventCursor.self, from: $0) }
                    let stream = await service.subscribeRuntimeEvents(after: after)
                    let subKey = "sub:\(request.id)"
                    let subTask = Task {
                        defer { connectionTasks.unregister(id: subKey) }
                        for await event in stream {
                            guard !Task.isCancelled else { break }
                            await writer.push(kind: "runtime", subscriptionID: request.id, payload: event)
                        }
                    }
                    connectionTasks.register(id: subKey, task: subTask)
                case "events.session":
                    guard !Task.isCancelled else { return }
                    await writer.reply(id: request.id, payload: nil, error: nil)
                    let subscription = try decode(SessionEventSubscription.self, request.payload)
                    let stream = try await service.subscribeSessionEvents(sessionID: subscription.sessionID, after: subscription.after)
                    let subKey = "sub:\(request.id)"
                    let subTask = Task {
                        defer { connectionTasks.unregister(id: subKey) }
                        for await event in stream {
                            guard !Task.isCancelled else { break }
                            await writer.push(kind: "session", subscriptionID: request.id, payload: event)
                        }
                    }
                    connectionTasks.register(id: subKey, task: subTask)
                case "events.session.list": try await reply(request, try await service.listSessionEvents(request: decode(ListSessionEventsRequest.self, request.payload)), writer)
                case "events.stream":
                    guard !Task.isCancelled else { return }
                    await writer.reply(id: request.id, payload: nil, error: nil)
                    let subscription = try decode(StreamSubscription.self, request.payload)
                    let stream = try await service.subscribeStreamFrames(streamID: subscription.streamID, afterIndex: subscription.afterIndex)
                    let subKey = "sub:\(request.id)"
                    let subTask = Task {
                        defer { connectionTasks.unregister(id: subKey) }
                        for await frame in stream {
                            guard !Task.isCancelled else { break }
                            await writer.push(kind: "frame", subscriptionID: request.id, payload: frame)
                        }
                    }
                    connectionTasks.register(id: subKey, task: subTask)
                case "events.unsubscribe":
                    if let subID = try? decode(String.self, request.payload) {
                        connectionTasks.cancel(id: "sub:\(subID)")
                        connectionTasks.cancel(id: subID)
                    }
                    let receipt = CommandReceipt<VoidResult>(commandID: CommandID(request.id), applied: true, revision: 0, observedThrough: [], result: VoidResult())
                    try await reply(request, receipt, writer)
                default: throw CoreError(code: .unsupportedCommand, message: "未知 VNext 方法: \(request.method)")
                }
            } catch let error as CoreError {
                if !Task.isCancelled {
                    await writer.reply(id: request.id, payload: nil, error: error)
                }
            } catch {
                if !Task.isCancelled {
                    await writer.reply(id: request.id, payload: nil, error: CoreError(code: .transport, message: String(describing: error)))
                }
            }
        }
        connectionTasks.register(id: request.id, task: task)
    }

    private func reply<T: Encodable>(_ request: VNextWireRequest, _ value: T, _ writer: VNextWireWriter) async throws {
        guard !Task.isCancelled else { return }
        await writer.reply(id: request.id, payload: try JSONEncoder().encode(value), error: nil)
    }

    private func commandEnvelope<P: Codable & Sendable>(_ request: VNextWireRequest, as type: P.Type) throws -> CommandEnvelope<P> {
        let payload = try decode(type, request.payload)
        return CommandEnvelope(
            commandID: request.commandID ?? CommandID(request.id),
            issuedAt: request.issuedAt ?? Date(),
            expectedRevision: request.expectedRevision,
            payload: payload
        )
    }

    private func queryEnvelope<P: Codable & Sendable>(_ request: VNextWireRequest, as type: P.Type) throws -> QueryEnvelope<P> {
        let payload = try decode(type, request.payload)
        return QueryEnvelope(
            requestID: request.requestID ?? RequestID(request.id),
            issuedAt: request.issuedAt ?? Date(),
            payload: payload
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, _ payload: Data?) throws -> T {
        guard let payload else { return try JSONDecoder().decode(T.self, from: Data("{}".utf8)) }
        return try JSONDecoder().decode(T.self, from: payload)
    }

    private func sanitizeContentAuthorization(_ clientAuth: ContentAuthorizationContext?) -> ContentAuthorizationContext {
        guard let clientAuth else { return .anonymous }
        // 关键安全防御：绝不允许客户端自封 isSystemAdmin 或伪造系统权限 (Audit Round 7 Phase E)
        return ContentAuthorizationContext(
            sessionID: clientAuth.sessionID,
            principal: clientAuth.principal,
            workspaceID: clientAuth.workspaceID,
            isSystemAdmin: false
        )
    }
}

private actor VNextWireWriter {
    let output: FileHandle

    init(output: FileHandle) { self.output = output }

    func reply(id: String, payload: Data?, error: CoreError?) {
        write(VNextWireResponse(id: id, payload: payload, error: error))
    }

    func push<T: Encodable>(kind: String, subscriptionID: String, payload: T) async {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        write(VNextWirePush(kind: kind, subscriptionID: subscriptionID, payload: data))
    }

    private func write<T: Encodable>(_ message: T) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        try? output.write(contentsOf: data + Data("\n".utf8))
    }
}
