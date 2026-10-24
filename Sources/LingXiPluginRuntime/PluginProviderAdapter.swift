import Foundation
import LingXiKernel
import LingXiPluginABI

/// Presents a plugin-provided model as the kernel's `ModelProvider`. The kernel never learns which
/// vendor is behind it: it sees a model id and normalized `ModelEvent`s.
public struct PluginProviderAdapter: ModelProvider {
    public let capabilities: ModelCapabilities

    private let session: PluginSession
    private let capabilityID: String
    private let credential: @Sendable () throws -> String?
    private let active = ActiveRequests()
    private let reasoning = ReasoningStore()

    private final class ActiveRequests: @unchecked Sendable {
        private let lock = NSLock()
        private var byExecution: [ExecutionID: Set<String>] = [:]

        func add(_ execution: ExecutionID, _ requestID: String) {
            lock.lock(); byExecution[execution, default: []].insert(requestID); lock.unlock()
        }

        func remove(_ execution: ExecutionID, _ requestID: String) {
            lock.lock(); byExecution[execution]?.remove(requestID); lock.unlock()
        }

        func take(_ execution: ExecutionID) -> [String] {
            lock.lock(); defer { lock.unlock() }
            return Array(byExecution.removeValue(forKey: execution) ?? [])
        }

        func takeAll() -> [String] {
            lock.lock(); defer { lock.unlock() }
            let all = byExecution.values.flatMap { $0 }
            byExecution.removeAll()
            return all
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return byExecution.values.reduce(0) { $0 + $1.count }
        }
    }

    public init(
        session: PluginSession,
        providerID: String,
        declaration: ProviderIdentity,
        credential: @escaping @Sendable () throws -> String?
    ) {
        self.session = session
        self.capabilityID = "provider.\(providerID)"
        self.credential = credential
        self.capabilities = ModelCapabilities(
            supportsReasoning: true,
            supportsParallelToolCalls: declaration.supportsParallelToolCalls,
            toolResultPlacement: ToolResultPlacement(rawValue: declaration.toolResultPlacement) ?? .anywhereInHistory
        )
    }

    public func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let granted: String?
        do { granted = try credential() } catch {
            throw ModelFailure(kind: .unauthorized, message: "credential store access failed; use /auth <provider> status")
        }
        let requestID = UUID().uuidString
        active.add(request.executionID, requestID)
        let previousReasoningTurns = reasoning.turns(for: request.executionID)
        let wire = Self.wireRequest(
            from: request, credential: granted,
            previousReasoning: previousReasoningTurns
                .flatMap { $0.items.map(\.text) }.joined(separator: "\n\n").nilIfEmpty,
            previousReasoningTurns: previousReasoningTurns.isEmpty ? nil : previousReasoningTurns
        )
        let payload = try JSONValue.encode(wire)
        let events = await session.invokeStreaming(
            capability: capabilityID, payload: payload, requestID: requestID, timeout: .seconds(300)
        )
        let active = self.active
        let session = self.session
        let executionID = request.executionID
        return AsyncThrowingStream { continuation in
            let pump = Task {
                var sawTerminal = false
                var currentItems: [ProviderReasoningItem] = []
                var itemIndexByKey: [String: Int] = [:]
                var currentCallIDs: [String] = []
                do {
                    for try await value in events {
                        let envelope = try value.decode(ProviderWireEnvelope.self)
                        let event = envelope.event
                        switch event.type {
                        case "reasoningDelta":
                            guard let delta = event.text, !delta.isEmpty else { break }
                            let key = event.itemID ?? "default"
                            if let index = itemIndexByKey[key] {
                                let old = currentItems[index]
                                currentItems[index] = ProviderReasoningItem(
                                    id: old.id, text: old.text + delta, status: old.status
                                )
                            } else {
                                currentItems.append(ProviderReasoningItem(
                                    id: event.itemID, text: delta, status: event.status
                                ))
                                itemIndexByKey[key] = currentItems.count - 1
                            }
                        case "reasoningItem":
                            guard let text = event.text, !text.isEmpty else { break }
                            let key = event.itemID ?? "default"
                            if let index = itemIndexByKey[key] {
                                let old = currentItems[index]
                                currentItems[index] = ProviderReasoningItem(
                                    id: event.itemID ?? old.id, text: text,
                                    status: event.status ?? old.status
                                )
                            } else {
                                currentItems.append(ProviderReasoningItem(
                                    id: event.itemID, text: text, status: event.status
                                ))
                                itemIndexByKey[key] = currentItems.count - 1
                            }
                        case "toolCallStarted", "toolCallCompleted":
                            if let callID = event.callID, !currentCallIDs.contains(callID) {
                                currentCallIDs.append(callID)
                            }
                        default:
                            break
                        }
                        for mapped in Self.map(event) {
                            switch mapped {
                            case .completed(let reason):
                                sawTerminal = true
                                if reason == .toolCalls {
                                    reasoning.appendTurn(
                                        ProviderReasoningTurn(callIDs: currentCallIDs, items: currentItems),
                                        for: executionID
                                    )
                                } else {
                                    reasoning.finalize(executionID)
                                }
                            case .failed:
                                sawTerminal = true
                                reasoning.finalize(executionID)
                            default:
                                break
                            }
                            continuation.yield(mapped)
                        }
                    }
                    if !sawTerminal { reasoning.finalize(executionID) }
                    continuation.finish()
                } catch {
                    // Cancellation after a terminal is the normal stream consumer shutdown; it
                    // must not erase a tool-round snapshot retained for the next step.
                    if !sawTerminal { reasoning.finalize(executionID) }
                    continuation.finish(throwing: error)
                }
                active.remove(executionID, requestID)
            }
            continuation.onTermination = { _ in
                pump.cancel()
                active.remove(executionID, requestID)
                Task { await session.cancel(requestID: requestID) }
            }
        }
    }

    /// Test/diagnostic visibility for the bounded per-execution reasoning cache.
    public var cachedReasoningExecutionCount: Int { reasoning.cachedExecutionCount }

    public func finishExecution(_ executionID: ExecutionID) async {
        reasoning.clearExecution(executionID)
        await endExecution(executionID)
    }

    public func endExecution(_ executionID: ExecutionID) async {
        reasoning.endExecution(executionID)
        for requestID in active.take(executionID) {
            await session.cancel(requestID: requestID)
        }
    }

    /// Disable/revocation path: every in-flight stream this adapter owns is cancelled.
    public func cancelAll() async {
        reasoning.clearAll()
        for requestID in active.takeAll() {
            await session.cancel(requestID: requestID)
        }
    }

    public var inFlightRequestCount: Int { active.count }

    // MARK: - mapping

    static func wireRequest(
        from request: ModelRequest, credential: String?,
        previousReasoning: String? = nil,
        previousReasoningTurns: [ProviderReasoningTurn]? = nil
    ) -> ProviderWireRequest {
        var instructions: [String] = []
        var items: [ProviderWireItem] = []
        for entry in request.entries {
            if entry.segment == .immutableInstructions {
                if case .text(let text) = entry.payload { instructions.append(text) }
                continue
            }
            switch entry.payload {
            case .text(let text):
                items.append(.init(kind: .message, role: entry.role.rawValue, text: text))
            case .assistantMessage(let text, let calls):
                if !text.isEmpty {
                    items.append(.init(kind: .message, role: MessageRole.assistant.rawValue, text: text))
                }
                for call in calls {
                    items.append(.init(
                        kind: .functionCall, callID: call.callID.rawValue,
                        name: call.toolName, arguments: call.argumentsJSON
                    ))
                }
            case .toolCall(let calls):
                for call in calls {
                    items.append(.init(
                        kind: .functionCall, callID: call.callID.rawValue,
                        name: call.toolName, arguments: call.argumentsJSON
                    ))
                }
            case .toolResult(let outcomes):
                for outcome in outcomes {
                    items.append(.init(
                        kind: .functionCallOutput, callID: outcome.callID.rawValue, output: outcome.content
                    ))
                }
            }
        }
        return ProviderWireRequest(
            model: request.model.rawValue,
            instructions: instructions.isEmpty ? nil : instructions.joined(separator: "\n\n"),
            input: items,
            tools: request.tools.map {
                ProviderWireTool(name: $0.name, description: nil, parametersJSON: $0.schemaJSON)
            },
            maxOutputTokens: nil,
            credential: credential,
            executionID: request.executionID.rawValue,
            previousReasoning: previousReasoning,
            previousReasoningTurns: previousReasoningTurns
        )
    }

    final class ReasoningStore: @unchecked Sendable {
        private let lock = NSLock()
        private var turns: [ExecutionID: [ProviderReasoningTurn]] = [:]
        private var order: [ExecutionID] = []
        /// A toolCalls terminal does not end the Run; the next request consumes this marker. A final
        /// terminal or endExecution without it clears the execution so a finished Run cannot leak.
        private var keepForNextStep: Set<ExecutionID> = []
        private static let maxExecutions = 64
        private static let maxTurnsPerExecution = 16
        private static let maxItemsPerExecution = 64
        private static let maxBytesPerExecution = 64 * 1024

        func turns(for executionID: ExecutionID) -> [ProviderReasoningTurn] {
            lock.lock(); defer { lock.unlock() }
            keepForNextStep.remove(executionID)
            return turns[executionID] ?? []
        }

        func appendTurn(_ turn: ProviderReasoningTurn, for executionID: ExecutionID) {
            guard !turn.callIDs.isEmpty, !turn.items.isEmpty else { return }
            lock.lock()
            if turns[executionID] == nil { order.append(executionID) }
            var existing = turns[executionID] ?? []
            existing.append(turn)
            while existing.count > Self.maxTurnsPerExecution { existing.removeFirst() }
            var itemCount = 0
            var byteCount = 0
            var kept: [ProviderReasoningTurn] = []
            for turn in existing.reversed() {
                if itemCount + turn.items.count > Self.maxItemsPerExecution { break }
                let bytes = turn.items.reduce(0) { $0 + $1.text.utf8.count }
                if byteCount + bytes > Self.maxBytesPerExecution { break }
                itemCount += turn.items.count
                byteCount += bytes
                kept.append(turn)
            }
            turns[executionID] = kept.reversed()
            keepForNextStep.insert(executionID)
            while order.count > Self.maxExecutions {
                let evicted = order.removeFirst()
                turns.removeValue(forKey: evicted)
                keepForNextStep.remove(evicted)
            }
            lock.unlock()
        }

        func clearExecution(_ executionID: ExecutionID) {
            lock.lock()
            turns.removeValue(forKey: executionID)
            keepForNextStep.remove(executionID)
            order.removeAll { $0 == executionID }
            lock.unlock()
        }

        func finalize(_ executionID: ExecutionID) {
            lock.lock()
            turns.removeValue(forKey: executionID)
            keepForNextStep.remove(executionID)
            order.removeAll { $0 == executionID }
            lock.unlock()
        }

        func endExecution(_ executionID: ExecutionID) {
            lock.lock()
            // Keep only a turn that is explicitly waiting for the next request of a live Run.
            // Every other path (final completion, cancellation, failure, or a tool turn whose Run
            // never continues) is reclaimed here.
            if !keepForNextStep.contains(executionID) {
                turns.removeValue(forKey: executionID)
                order.removeAll { $0 == executionID }
            }
            keepForNextStep.remove(executionID)
            lock.unlock()
        }

        func clearAll() {
            lock.lock(); turns.removeAll(); keepForNextStep.removeAll(); order.removeAll(); lock.unlock()
        }

        var cachedExecutionCount: Int {
            lock.lock(); defer { lock.unlock() }; return turns.count
        }
    }

    static func map(_ event: ProviderWireEvent) -> [ModelEvent] {
        switch event.type {
        case "textDelta":
            return event.text.map { [.textDelta($0)] } ?? []
        case "reasoningDelta":
            return event.text.map { [.reasoningDelta($0)] } ?? []
        case "toolCallStarted":
            guard let callID = event.callID, let name = event.name else { return [] }
            return [.toolCallStarted(ToolCallStart(callID: ToolCallID(callID), toolName: name))]
        case "toolCallDelta":
            guard let callID = event.callID else { return [] }
            return [.toolCallDelta(ToolCallDelta(callID: ToolCallID(callID), argumentFragment: event.arguments ?? ""))]
        case "toolCallCompleted":
            guard let callID = event.callID, let name = event.name else { return [] }
            return [.toolCallCompleted(ToolCall(
                callID: ToolCallID(callID), toolName: name, argumentsJSON: event.arguments ?? "{}"
            ))]
        case "usage":
            guard let usage = event.usage else { return [] }
            return [.usage(ModelUsage(
                inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                reasoningTokens: usage.reasoningTokens, cacheReadTokens: usage.cacheReadTokens,
                cacheWriteTokens: usage.cacheWriteTokens
            ))]
        case "completed":
            let reason = ModelStopReason(rawValue: event.stopReason ?? "") ?? .unknown
            return [.completed(reason)]
        case "failed":
            let kind = ModelFailure.Kind(rawValue: event.failureKind ?? "") ?? .unknown
            return [.failed(ModelFailure(kind: kind, message: event.message ?? "the provider reported a failure"))]
        case "providerRequestID":
            return event.requestID.map { [.providerRequestID($0)] } ?? []
        default:
            // Forward compatibility: an unknown event type is not a reason to kill the stream.
            return []
        }
    }
}


private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
