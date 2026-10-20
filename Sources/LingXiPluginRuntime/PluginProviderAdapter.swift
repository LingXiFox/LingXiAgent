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
        let wire = Self.wireRequest(from: request, credential: granted)
        let payload = try JSONValue.encode(wire)
        let events = await session.invokeStreaming(
            capability: capabilityID, payload: payload, requestID: requestID, timeout: .seconds(300)
        )
        let active = self.active
        let session = self.session
        let executionID = request.executionID
        return AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    for try await value in events {
                        let envelope = try value.decode(ProviderWireEnvelope.self)
                        for mapped in Self.map(envelope.event) { continuation.yield(mapped) }
                    }
                    continuation.finish()
                } catch {
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

    public func endExecution(_ executionID: ExecutionID) async {
        for requestID in active.take(executionID) {
            await session.cancel(requestID: requestID)
        }
    }

    /// Disable/revocation path: every in-flight stream this adapter owns is cancelled.
    public func cancelAll() async {
        for requestID in active.takeAll() {
            await session.cancel(requestID: requestID)
        }
    }

    public var inFlightRequestCount: Int { active.count }

    // MARK: - mapping

    static func wireRequest(from request: ModelRequest, credential: String?) -> ProviderWireRequest {
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
            credential: credential
        )
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
