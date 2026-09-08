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

private struct SessionEventSubscription: Codable { let sessionID: SessionID; let after: EventCursor? }
private struct StreamSubscription: Codable { let streamID: StreamID; let afterIndex: UInt64? }

/// JSON-lines server for the VNext Application composition root.
public struct VNextStdioCoreServer: Sendable {
    private let service: any LingXiProtocolService
    private let input: FileHandle
    private let output: FileHandle

    public init(service: any LingXiProtocolService, input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        self.service = service
        self.input = input
        self.output = output
    }

    public func run() async throws {
        let writer = VNextWireWriter(output: output)
        let chunks = AsyncStream<Data> { continuation in
            continuation.onTermination = { _ in
                input.readabilityHandler = nil
                try? input.close()
            }
            input.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    input.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }
        await withTaskCancellationHandler {
            var buffer = Data()
            do {
                for await chunk in chunks {
                    guard !Task.isCancelled else { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[..<newline]
                        buffer.removeSubrange(...newline)
                        guard let request = try? JSONDecoder().decode(VNextWireRequest.self, from: line) else { continue }
                        handle(request, writer: writer)
                    }
                }
            }
        } onCancel: {
            input.readabilityHandler = nil
            try? input.close()
        }
    }

    private func handle(_ request: VNextWireRequest, writer: VNextWireWriter) {
        Task {
            do {
                switch request.method {
                case "runtime.info": try await reply(request, try await service.getRuntimeInfo(envelope: QueryEnvelope(payload: decode(VoidResult.self, request.payload))), writer)
                case "runtime.health": try await reply(request, try await service.getRuntimeHealth(envelope: QueryEnvelope(payload: decode(VoidResult.self, request.payload))), writer)
                case "runtime.capabilities": try await reply(request, try await service.getRuntimeCapabilities(envelope: QueryEnvelope(payload: decode(VoidResult.self, request.payload))), writer)
                case "runtime.config": try await reply(request, try await service.getEffectiveConfiguration(envelope: QueryEnvelope(payload: decode(VoidResult.self, request.payload))), writer)
                case "runtime.config.reload": try await reply(request, try await service.reloadConfiguration(envelope: CommandEnvelope(payload: decode(VoidResult.self, request.payload))), writer)
                case "runtime.setting.update": try await reply(request, try await service.updateTypedSetting(envelope: CommandEnvelope(payload: decode(UpdateTypedSettingRequest.self, request.payload))), writer)
                case "session.create": try await reply(request, try await service.createSession(envelope: CommandEnvelope(payload: decode(CreateSessionRequest.self, request.payload))), writer)
                case "session.rename": try await reply(request, try await service.renameSession(envelope: CommandEnvelope(payload: decode(RenameSessionRequest.self, request.payload))), writer)
                case "session.set_reasoning_effort": try await reply(request, try await service.setSessionReasoningEffort(envelope: CommandEnvelope(payload: decode(SetSessionReasoningEffortRequest.self, request.payload))), writer)
                case "session.delete": try await reply(request, try await service.deleteSession(envelope: CommandEnvelope(payload: decode(DeleteSessionRequest.self, request.payload))), writer)
                case "session.get": try await reply(request, try await service.getSession(envelope: QueryEnvelope(payload: decode(GetSessionRequest.self, request.payload))), writer)
                case "session.list": try await reply(request, try await service.listSessions(envelope: QueryEnvelope(payload: decode(PageRequest.self, request.payload))), writer)
                case "session.snapshot": try await reply(request, try await service.getSessionSnapshot(envelope: QueryEnvelope(payload: decode(GetSessionSnapshotRequest.self, request.payload))), writer)
                case "turn.submit": try await reply(request, try await service.submitTurn(envelope: CommandEnvelope(payload: decode(SubmitTurnRequest.self, request.payload))), writer)
                case "turn.cancel": try await reply(request, try await service.cancelTurn(envelope: CommandEnvelope(payload: decode(CancelTurnRequest.self, request.payload))), writer)
                case "turn.get": try await reply(request, try await service.getTurn(envelope: QueryEnvelope(payload: decode(GetTurnRequest.self, request.payload))), writer)
                case "turn.list": try await reply(request, try await service.listTurns(envelope: QueryEnvelope(payload: decode(ListTurnsRequest.self, request.payload))), writer)
                case "run.cancel": try await reply(request, try await service.cancelRun(envelope: CommandEnvelope(payload: decode(CancelRunRequest.self, request.payload))), writer)
                case "run.resume": try await reply(request, try await service.resumeRun(envelope: CommandEnvelope(payload: decode(ResumeRunRequest.self, request.payload))), writer)
                case "run.get": try await reply(request, try await service.getRun(envelope: QueryEnvelope(payload: decode(GetRunRequest.self, request.payload))), writer)
                case "run.list": try await reply(request, try await service.listRuns(envelope: QueryEnvelope(payload: decode(ListRunsRequest.self, request.payload))), writer)
                case "agent.tree": try await reply(request, try await service.getAgentTree(envelope: QueryEnvelope(payload: decode(GetAgentTreeRequest.self, request.payload))), writer)
                case "interaction.list": try await reply(request, try await service.listPendingInteractions(envelope: QueryEnvelope(payload: decode(ListInteractionsRequest.self, request.payload))), writer)
                case "interaction.resolve": try await reply(request, try await service.resolveInteraction(envelope: CommandEnvelope(payload: decode(ResolveInteractionRequest.self, request.payload))), writer)
                case "provider.list": try await reply(request, try await service.listProviders(envelope: QueryEnvelope(payload: decode(VoidResult.self, request.payload))), writer)
                case "provider.status": try await reply(request, try await service.getProviderStatus(envelope: QueryEnvelope(payload: decode(VoidResult.self, request.payload))), writer)
                case "provider.get": try await reply(request, try await service.getProvider(envelope: QueryEnvelope(payload: decode(GetProviderRequest.self, request.payload))), writer)
                case "provider.test": try await reply(request, try await service.testProvider(envelope: CommandEnvelope(payload: decode(TestProviderRequest.self, request.payload))), writer)
                case "provider.configure": try await reply(request, try await service.configureProvider(envelope: CommandEnvelope(payload: decode(ConfigureProviderRequest.self, request.payload))), writer)
                case "provider.remove": try await reply(request, try await service.removeProvider(envelope: CommandEnvelope(payload: decode(RemoveProviderRequest.self, request.payload))), writer)
                case "provider.reload": try await reply(request, try await service.reloadProviders(envelope: CommandEnvelope(payload: decode(VoidResult.self, request.payload))), writer)
                case "model.list": try await reply(request, try await service.listModels(envelope: QueryEnvelope(payload: decode(VoidResult.self, request.payload))), writer)
                case "model.selection": try await reply(request, try await service.getModelSelection(envelope: QueryEnvelope(payload: decode(VoidResult.self, request.payload))), writer)
                case "model.select": try await reply(request, try await service.selectModel(envelope: CommandEnvelope(payload: decode(SelectModelRequest.self, request.payload))), writer)
                case "model.get": try await reply(request, try await service.getModel(envelope: QueryEnvelope(payload: decode(GetModelRequest.self, request.payload))), writer)
                case "model.capabilities": try await reply(request, try await service.getModelCapabilities(envelope: QueryEnvelope(payload: decode(GetModelCapabilitiesRequest.self, request.payload))), writer)
                case "context.state": try await reply(request, try await service.getContextState(envelope: QueryEnvelope(payload: decode(GetContextStateRequest.self, request.payload))), writer)
                case "context.policy": try await reply(request, try await service.getContextPolicy(envelope: QueryEnvelope(payload: decode(VoidResult.self, request.payload))), writer)
                case "context.policy.update": try await reply(request, try await service.updateContextPolicy(envelope: CommandEnvelope(payload: decode(UpdateContextPolicyRequest.self, request.payload))), writer)
                case "context.compact": try await reply(request, try await service.compactContext(envelope: CommandEnvelope(payload: decode(CompactContextRequest.self, request.payload))), writer)
                case "context.search": try await reply(request, try await service.searchContext(envelope: QueryEnvelope(payload: decode(SearchContextRequest.self, request.payload))), writer)
                case "context.entry": try await reply(request, try await service.getContextEntry(envelope: QueryEnvelope(payload: decode(GetContextEntryRequest.self, request.payload))), writer)
                case "extension.list": try await reply(request, try await service.listExtensions(envelope: QueryEnvelope(payload: decode(ListExtensionsRequest.self, request.payload))), writer)
                case "extension.status": try await reply(request, try await service.getExtensionStatus(envelope: QueryEnvelope(payload: decode(GetExtensionStatusRequest.self, request.payload))), writer)
                case "extension.get": try await reply(request, try await service.getExtension(envelope: QueryEnvelope(payload: decode(GetExtensionRequest.self, request.payload))), writer)
                case "extension.install": try await reply(request, try await service.installExtension(envelope: CommandEnvelope(payload: decode(InstallExtensionRequest.self, request.payload))), writer)
                case "extension.uninstall": try await reply(request, try await service.uninstallExtension(envelope: CommandEnvelope(payload: decode(UninstallExtensionRequest.self, request.payload))), writer)
                case "extension.enable": try await reply(request, try await service.enableExtension(envelope: CommandEnvelope(payload: decode(EnableExtensionRequest.self, request.payload))), writer)
                case "extension.disable": try await reply(request, try await service.disableExtension(envelope: CommandEnvelope(payload: decode(DisableExtensionRequest.self, request.payload))), writer)
                case "extension.reload": try await reply(request, try await service.reloadExtensions(envelope: CommandEnvelope(payload: decode(VoidResult.self, request.payload))), writer)
                case "extension.configure": try await reply(request, try await service.configureExtension(envelope: CommandEnvelope(payload: decode(ConfigureExtensionRequest.self, request.payload))), writer)
                case "workspace.get": try await reply(request, try await service.getWorkspace(envelope: QueryEnvelope(payload: decode(VoidResult.self, request.payload))), writer)
                case "workspace.set": try await reply(request, try await service.setWorkspace(envelope: CommandEnvelope(payload: decode(SetWorkspaceRequest.self, request.payload))), writer)
                case "workspace.diff": try await reply(request, try await service.getWorkspaceDiffSummary(envelope: QueryEnvelope(payload: decode(VoidResult.self, request.payload))), writer)
                case "diagnostics.get": try await reply(request, try await service.getDiagnostics(envelope: QueryEnvelope(payload: decode(VoidResult.self, request.payload))), writer)
                case "diagnostics.performance": try await reply(request, try await service.getPerformanceMetrics(envelope: QueryEnvelope(payload: decode(GetPerformanceMetricsRequest.self, request.payload))), writer)
                case "diagnostics.providerMetrics": try await reply(request, try await service.getProviderMetrics(envelope: QueryEnvelope(payload: decode(VoidResult.self, request.payload))), writer)
                case "diagnostics.runTrace": try await reply(request, try await service.getRunTrace(envelope: QueryEnvelope(payload: decode(GetRunTraceRequest.self, request.payload))), writer)
                case "credential.list": try await reply(request, try await service.listCredentials(envelope: QueryEnvelope(payload: decode(VoidResult.self, request.payload))), writer)
                case "credential.store": try await reply(request, try await service.storeCredential(envelope: CommandEnvelope(payload: decode(StoreCredentialRequest.self, request.payload))), writer)
                case "credential.delete": try await reply(request, try await service.deleteCredential(envelope: CommandEnvelope(payload: decode(DeleteCredentialRequest.self, request.payload))), writer)
                case "credential.status": try await reply(request, try await service.getCredentialStatus(envelope: QueryEnvelope(payload: decode(GetCredentialStatusRequest.self, request.payload))), writer)
                case "credential.test": try await reply(request, try await service.testCredential(envelope: CommandEnvelope(payload: decode(TestCredentialRequest.self, request.payload))), writer)
                case "events.runtime":
                    await writer.reply(id: request.id, payload: nil, error: nil)
                    let after = request.payload.flatMap { try? JSONDecoder().decode(EventCursor.self, from: $0) }
                    let stream = await service.subscribeRuntimeEvents(after: after)
                    for await event in stream { await writer.push(kind: "runtime", subscriptionID: request.id, payload: event) }
                case "events.session":
                    await writer.reply(id: request.id, payload: nil, error: nil)
                    let subscription = try decode(SessionEventSubscription.self, request.payload)
                    let stream = try await service.subscribeSessionEvents(sessionID: subscription.sessionID, after: subscription.after)
                    for await event in stream { await writer.push(kind: "session", subscriptionID: request.id, payload: event) }
                case "events.session.list": try await reply(request, try await service.listSessionEvents(request: decode(ListSessionEventsRequest.self, request.payload)), writer)
                case "events.stream":
                    await writer.reply(id: request.id, payload: nil, error: nil)
                    let subscription = try decode(StreamSubscription.self, request.payload)
                    let stream = try await service.subscribeStreamFrames(streamID: subscription.streamID, afterIndex: subscription.afterIndex)
                    for await frame in stream { await writer.push(kind: "frame", subscriptionID: request.id, payload: frame) }
                default: throw CoreError(code: .unsupportedCommand, message: "未知 VNext 方法: \(request.method)")
                }
            } catch let error as CoreError {
                await writer.reply(id: request.id, payload: nil, error: error)
            } catch {
                await writer.reply(id: request.id, payload: nil, error: CoreError(code: .transport, message: String(describing: error)))
            }
        }
    }

    private func reply<T: Encodable>(_ request: VNextWireRequest, _ value: T, _ writer: VNextWireWriter) async throws {
        await writer.reply(id: request.id, payload: try JSONEncoder().encode(value), error: nil)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ payload: Data?) throws -> T {
        guard let payload else { return try JSONDecoder().decode(T.self, from: Data("{}".utf8)) }
        return try JSONDecoder().decode(T.self, from: payload)
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
        output.write(data + Data("\n".utf8))
    }
}
