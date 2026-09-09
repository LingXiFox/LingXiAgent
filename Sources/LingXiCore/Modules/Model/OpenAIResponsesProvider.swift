import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingXiProtocol

/// OpenAI Responses API adapter. Its DTOs never leave this file.
public struct OpenAIResponsesProvider: ModelProvider {
    private let config: ProviderConfig
    private let transport: any ProviderHTTPTransport
    private let provenance: ProviderProvenanceStore

    public init(config: ProviderConfig, session: URLSession = .shared, provenance: ProviderProvenanceStore = ProviderProvenanceStore()) {
        self.config = config
        transport = URLSessionProviderHTTPTransport(session: session)
        self.provenance = provenance
    }

    public init(config: ProviderConfig, transport: any ProviderHTTPTransport, provenance: ProviderProvenanceStore = ProviderProvenanceStore()) {
        self.config = config
        self.transport = transport
        self.provenance = provenance
    }

    public func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let prior = try await provenance.resolveContinuation(for: request.continuationOf, wire: .responses)
        let previousResponseID = config.remoteStateEnabled ? prior?.responseID : nil
        let urlRequest = try makeURLRequest(request, continuation: prior, previousResponseID: previousResponseID)
        let startedAt = Date()
        Self.logRequest(urlRequest, step: request.debugStep, localContinuation: prior != nil, enabled: config.diagnosticsEnabled)
        let response = try await transport.send(urlRequest, context: ProviderHTTPRequestContext(wireProtocol: .responses, model: request.model.rawValue, requestID: request.requestID, executionID: request.executionID, step: request.debugStep ?? 0))
        let requestID = response.header("x-request-id")
            ?? response.header("openai-request-id")
            ?? response.header("cf-ray")
        Self.log("http step=\(request.debugStep ?? 0) status=\(response.statusCode) requestID=\(requestID ?? "none") elapsedMs=\(Self.elapsed(since: startedAt))", enabled: config.diagnosticsEnabled)
        guard (200..<300).contains(response.statusCode) else {
            let body = (try? await OpenAICompatibleProvider.collectText(response.body)) ?? ""
            Self.logHTTPError(body, step: request.debugStep, status: response.statusCode, requestID: requestID, enabled: config.diagnosticsEnabled)
            let requestFields: [String]
            if let reqBody = urlRequest.httpBody, let json = (try? JSONSerialization.jsonObject(with: reqBody)) as? [String: Any] {
                requestFields = json.keys.sorted()
            } else {
                requestFields = []
            }
            let toolSchemas = request.tools.map { "\($0.name)(\($0.inputSchema.required.joined(separator: ", ")))" }
            let capabilityProjection = "toolsRequested=\(!request.tools.isEmpty) (count=\(request.tools.count)), reasoningRequested=\(request.reasoning != nil)"
            let diagnostics = OpenAICompatibleProvider.makeWireDiagnostics(
                provider: config.baseURL.host ?? "openai",
                model: request.model.rawValue,
                wireAdapter: config.wireProtocol.rawValue,
                url: urlRequest.url?.absoluteString ?? config.responsesURL.absoluteString,
                httpMethod: urlRequest.httpMethod ?? "POST",
                requestFields: requestFields,
                toolSchemas: toolSchemas,
                capabilityProjection: capabilityProjection,
                responseBody: body
            )
            let error = OpenAICompatibleProvider.httpError(status: response.statusCode, requestID: requestID, diagnostics: diagnostics)
            throw ProviderRateLimitError.from(statusCode: response.statusCode, headers: response.headers, body: body, underlying: error)
        }

        let events = AsyncThrowingStream<ModelEvent, Error> { continuation in
            if let requestID = ProviderTraceSanitizer.requestID(requestID) {
                continuation.yield(.providerRequestID(requestID))
            }
            let pump = Task {
                await Pump(source: response.body, continuation: continuation, request: request, prior: prior, step: request.debugStep, providerRequestID: requestID, startedAt: startedAt, provenance: provenance, sensitiveValues: Self.sensitiveValues(config.authentication), diagnosticsEnabled: config.diagnosticsEnabled).run()
            }
            continuation.onTermination = { @Sendable _ in
                pump.cancel()
            }
        }
        return events
    }

    public func endExecution(_ executionID: AgentRunID) async {
        await provenance.remove(executionID)
    }

    public func makeURLRequest(_ request: ModelRequest, previousResponseID: String? = nil) throws -> URLRequest {
        try makeURLRequest(request, continuation: nil, previousResponseID: previousResponseID)
    }

    private func makeURLRequest(_ request: ModelRequest, continuation: ProviderContinuation?, previousResponseID: String?) throws -> URLRequest {
        var urlRequest = URLRequest(url: config.responsesURL)
        urlRequest.httpMethod = "POST"
        if let timeout = request.overallTimeoutSeconds { urlRequest.timeoutInterval = timeout }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch config.authentication {
        case .none: break
        case let .bearer(secret): urlRequest.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        case let .header(name, value): urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        for (name, value) in config.requiredHeaders where urlRequest.value(forHTTPHeaderField: name) == nil {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = try Self.makeRequestBody(
            request,
            continuation: continuation,
            previousResponseID: config.remoteStateEnabled ? previousResponseID : nil,
            store: config.remoteStateEnabled
        )
        return urlRequest
    }

    /// Domain request -> Responses API JSON.
    public static func makeRequestBody(_ request: ModelRequest) throws -> Data {
        try makeRequestBody(request, continuation: nil, previousResponseID: nil, store: false)
    }

    private static func makeRequestBody(_ request: ModelRequest, continuation: ProviderContinuation?, previousResponseID: String?, store: Bool) throws -> Data {
        let messages = previousResponseID == nil ? request.messages : continuationMessages(request)
        let input = messages.flatMap { message -> [ResponseRequestBody.Input] in
            let calls = message.parts.compactMap { if case let .toolCall(call) = $0 { call } else { nil } }
            let results = message.parts.compactMap { if case let .toolResult(result) = $0 { result } else { nil } }
            switch message.role {
            case .tool:
                return results.map {
                    let projected = ModelToolResultProjection.project($0)
                    return .functionOutput(callID: continuation?.externalCallID(for: projected.callID) ?? projected.callID.rawValue, output: projected.content)
                }
            case .assistant:
                var items: [ResponseRequestBody.Input] = []
                if !message.content.isEmpty { items.append(.message(role: "assistant", content: message.content)) }
                let byID = Dictionary(uniqueKeysWithValues: calls.map { ($0.callID, $0) })
                let ordered = continuation?.orderedItems ?? []
                if request.reasoning != nil, !ordered.isEmpty, ordered.contains(where: { if case let .toolCall(id) = $0 { byID[id] != nil } else { false } }) {
                    for item in ordered {
                        switch item {
                        case let .opaque(data): items.append(.opaque(data))
                        case let .toolCall(id):
                            guard let call = byID[id] else { continue }
                            items.append(.functionCall(callID: continuation?.externalCallID(for: id) ?? id.rawValue, name: call.toolID.rawValue, arguments: call.arguments))
                        }
                    }
                } else {
                    items.append(contentsOf: calls.map { .functionCall(callID: continuation?.externalCallID(for: $0.callID) ?? $0.callID.rawValue, name: $0.toolID.rawValue, arguments: $0.arguments) })
                }
                return items
            case .system:
                return [.message(role: "developer", content: message.content)]
            case .user:
                return [.message(role: "user", content: message.content)]
            }
        }
        let orderedTools: [ToolDefinition]
        let instructions: String?
        if let plan = request.cachePlan {
            instructions = plan.immutableBase.systemPrompt ?? request.system
            orderedTools = plan.immutableBase.coreTools + plan.appendOnlyContext.dynamicTools
        } else {
            instructions = request.system
            let coreIDs = ToolRuntime.coreToolIDs
            let core = request.tools.filter { coreIDs.contains($0.id) }.sorted(by: { $0.id.rawValue < $1.id.rawValue })
            let dynamic = request.tools.filter { !coreIDs.contains($0.id) }.sorted(by: { $0.id.rawValue < $1.id.rawValue })
            orderedTools = core + dynamic
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ResponseRequestBody(
            model: request.model.rawValue,
            stream: true,
            store: store,
            instructions: instructions,
            input: input,
            tools: orderedTools.isEmpty ? nil : orderedTools.map(ResponseRequestBody.Tool.init),
            reasoning: request.reasoning.map { ResponseRequestBody.Reasoning(effort: $0) },
            include: !store && request.reasoning != nil ? ["reasoning.encrypted_content"] : nil,
            previousResponseID: previousResponseID
        ))
    }

    public static func events(forSSEPayload payload: String, decoder: inout ResponsesSSEDecoder) throws -> [ModelEvent] {
        try decoder.consume(payload)
    }

    private static func continuationMessages(_ request: ModelRequest) -> [ModelMessage] {
        if let callIndex = request.messages.lastIndex(where: { message in
            message.role == .assistant && message.parts.contains { if case .toolCall = $0 { true } else { false } }
        }) {
            return Array(request.messages.suffix(from: request.messages.index(after: callIndex)))
        }
        let lastUser = request.messages.lastIndex { $0.role == .user }
        guard let toolIndex = request.messages.lastIndex(where: { $0.role == .tool }), lastUser == nil || toolIndex > lastUser! else { return [] }
        return [request.messages[toolIndex]]
    }

    private static func logRequest(_ request: URLRequest, step: Int?, localContinuation: Bool, enabled: Bool) {
        guard enabled, let body = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return }
        let input = object["input"] as? [[String: Any]] ?? []
        let outputCount = input.filter { $0["type"] as? String == "function_call_output" }.count
        let callCount = input.filter { $0["type"] as? String == "function_call" }.count
        let toolCount = (object["tools"] as? [[String: Any]])?.count ?? 0
        let remoteContinuation = object["previous_response_id"] != nil
        log("request step=\(step ?? 0) wire=responses localContinuation=\(localContinuation) remoteContinuation=\(remoteContinuation) inputItems=\(input.count) functionCalls=\(callCount) functionOutputs=\(outputCount) tools=\(toolCount) bytes=\(body.count) timeoutSec=\(Int(request.timeoutInterval))", enabled: enabled)
    }

    private static func logHTTPError(_ body: String, step: Int?, status: Int, requestID: String?, enabled: Bool) {
        log("httpError step=\(step ?? 0) status=\(status) requestID=\(requestID ?? "none") body=\(sanitizedProviderToken(body, limit: 300) ?? "none")", enabled: enabled)
    }

    private static func elapsed(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    private static func sensitiveValues(_ authentication: ProviderAuthentication) -> [String] {
        switch authentication {
        case .none: []
        case let .bearer(value), let .header(_, value): [value]
        }
    }
    private static func log(_ message: String, enabled: Bool) {
        guard enabled else { return }
        FileHandle.standardError.write(Data(("[responses-diagnostic] \(message)\n").utf8))
    }

    private final class Pump: Sendable {
        private let source: AsyncThrowingStream<Data, Error>
        private let continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation
        private let request: ModelRequest
        private let prior: ProviderContinuation?
        private let step: Int?
        private let providerRequestID: String?
        private let startedAt: Date
        private let provenance: ProviderProvenanceStore
        private let sensitiveValues: [String]
        private let diagnosticsEnabled: Bool

        init(source: AsyncThrowingStream<Data, Error>, continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation, request: ModelRequest, prior: ProviderContinuation?, step: Int?, providerRequestID: String?, startedAt: Date, provenance: ProviderProvenanceStore, sensitiveValues: [String], diagnosticsEnabled: Bool) {
            self.source = source
            self.continuation = continuation
            self.request = request
            self.prior = prior
            self.step = step
            self.providerRequestID = providerRequestID
            self.startedAt = startedAt
            self.provenance = provenance
            self.sensitiveValues = sensitiveValues
            self.diagnosticsEnabled = diagnosticsEnabled
        }

        func run() async {
            var lines = SSEDecoder()
            var decoder = ResponsesSSEDecoder(requestID: request.requestID, sensitiveValues: sensitiveValues)
            var completed: ModelFinishReason?
            var lastEventType = "none"
            var terminalObserved = false
            var failureObserved = false
            var responseID: String?
            continuation.yield(.started)
            do {
                outer: for try await chunk in source {
                    for line in lines.feed(chunk) {
                        if try emit(line, decoder: &decoder, completed: &completed, lastEventType: &lastEventType, terminalObserved: &terminalObserved, failureObserved: &failureObserved, responseID: &responseID) { break outer }
                    }
                }
                if !terminalObserved {
                    for line in lines.flushPending() {
                        _ = try emit(line, decoder: &decoder, completed: &completed, lastEventType: &lastEventType, terminalObserved: &terminalObserved, failureObserved: &failureObserved, responseID: &responseID)
                    }
                }
                if Task.isCancelled { continuation.finish(); return }
                if failureObserved { continuation.finish(); return }
                guard terminalObserved else { throw CoreError(code: .modelStream, message: "Responses SSE 意外结束") }
                let combinedReferences = (prior?.references ?? []).filter { priorRef in !decoder.references.contains { $0.domainCallID == priorRef.domainCallID } } + decoder.references
                if responseID != nil || !combinedReferences.isEmpty || !decoder.orderedItems.isEmpty {
                    try await provenance.record(ProviderContinuation(requestID: request.requestID, executionID: request.executionID, wire: .responses, responseID: responseID, references: combinedReferences, orderedItems: decoder.orderedItems))
                }
                OpenAIResponsesProvider.log("eof step=\(step ?? 0) requestID=\(providerRequestID ?? "none") responseIDPresent=\(responseID != nil) lastEvent=\(lastEventType) terminal=\(terminalObserved) elapsedMs=\(OpenAIResponsesProvider.elapsed(since: startedAt))", enabled: diagnosticsEnabled)
                continuation.yield(.completed(completed ?? .unknown))
                continuation.finish()
            } catch let error as CoreError {
                if Task.isCancelled { continuation.finish(); return }
                OpenAIResponsesProvider.log("failed step=\(step ?? 0) requestID=\(providerRequestID ?? "none") responseIDPresent=\(responseID != nil) lastEvent=\(lastEventType) terminal=\(terminalObserved) elapsedMs=\(OpenAIResponsesProvider.elapsed(since: startedAt)) code=\(error.code.rawValue)", enabled: diagnosticsEnabled)
                continuation.yield(.failed(error))
                continuation.finish()
            } catch {
                if Task.isCancelled { continuation.finish(); return }
                OpenAIResponsesProvider.log("failed step=\(step ?? 0) requestID=\(providerRequestID ?? "none") responseIDPresent=\(responseID != nil) lastEvent=\(lastEventType) terminal=\(terminalObserved) elapsedMs=\(OpenAIResponsesProvider.elapsed(since: startedAt)) code=transport", enabled: diagnosticsEnabled)
                continuation.yield(.failed(CoreError(code: .modelStream, message: "Responses SSE 连接中断")))
                continuation.finish()
            }
        }

        private func emit(_ line: String, decoder: inout ResponsesSSEDecoder, completed: inout ModelFinishReason?, lastEventType: inout String, terminalObserved: inout Bool, failureObserved: inout Bool, responseID: inout String?) throws -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { return false }
            let payload = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]" else { return true }
            if let data = payload.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = object["type"] as? String {
                lastEventType = sanitizedProviderToken(type, limit: 120) ?? "unknown"
                terminalObserved = terminalObserved || ["response.completed", "response.incomplete", "response.failed", "error"].contains(type)
                if let response = object["response"] as? [String: Any], let id = response["id"] as? String { responseID = id }
                OpenAIResponsesProvider.log("event step=\(step ?? 0) requestID=\(providerRequestID ?? "none") responseIDPresent=\(responseID != nil) type=\(lastEventType) elapsedMs=\(OpenAIResponsesProvider.elapsed(since: startedAt))", enabled: diagnosticsEnabled)
                if let failure = ResponsesProviderFailure(eventType: type, object: object, sensitiveValues: sensitiveValues) {
                    OpenAIResponsesProvider.log("providerError step=\(step ?? 0) requestID=\(providerRequestID ?? "none") event=\(failure.eventType) code=\(failure.code ?? "none") param=\(failure.param ?? "none") message=\(failure.diagnosticMessage)", enabled: diagnosticsEnabled)
                }
            }
            for event in try decoder.consume(payload) {
                if case let .completed(reason) = event { completed = reason }
                else if case .failed = event { failureObserved = true; continuation.yield(event) }
                else { continuation.yield(event) }
            }
            return terminalObserved
        }

    }
}

/// Explicit stream state machine for OpenAI Responses protocol.
public enum ResponsesStreamState: Sendable, Equatable {
    case idle
    case inProgress(responseID: String?)
    case inOutputItem(outputIndex: Int, itemType: String, itemID: String?)
    case streamingText(outputIndex: Int, contentIndex: Int)
    case streamingToolArguments(outputIndex: Int, callID: String)
    case completed(status: String)
    case failed(error: String)
}

public struct ResponsesStreamStateMachine: Sendable {
    public private(set) var state: ResponsesStreamState = .idle
    public private(set) var responseID: String?
    public private(set) var completedCallIDs: [String] = []
    public private(set) var references: [ProviderToolCallReference] = []

    private struct PartialCall {
        var name: String?
        var arguments = ""
        var started = false
        var emitted = 0
        var completed = false
    }

    private var calls: [String: PartialCall] = [:]
    private var itemToCallID: [String: String] = [:]
    private var callToItemID: [String: String] = [:]
    private var orderedKeys: [String] = []
    private var opaqueItems: [String: Data] = [:]
    private var domainIDs: [String: ToolCallID] = [:]
    private let requestID: ModelRequestID
    private let sensitiveValues: [String]

    public var orderedItems: [ProviderContinuationItem] {
        orderedKeys.compactMap { key in
            if key.hasPrefix("opaque:"), let data = opaqueItems[key] { return .opaque(data) }
            if key.hasPrefix("call:"), let id = domainIDs[String(key.dropFirst("call:".count))] { return .toolCall(id) }
            return nil
        }
    }

    public init(requestID: ModelRequestID = ModelRequestID(), sensitiveValues: [String] = []) {
        self.requestID = requestID
        self.sensitiveValues = sensitiveValues
    }

    public mutating func feedEvent(type: String, object: [String: Any]) throws -> [ModelEvent] {
        switch (state, type) {
        // 1. response.created & response.in_progress
        case (_, "response.created"), (_, "response.in_progress"):
            if let response = object["response"] as? [String: Any], let id = response["id"] as? String {
                self.responseID = id
            }
            state = .inProgress(responseID: self.responseID)
            return []

        // 2. output_item.added
        case (_, "response.output_item.added"):
            let outputIndex = object["output_index"] as? Int ?? 0
            guard let item = object["item"] as? [String: Any], let itemType = item["type"] as? String else { return [] }
            let itemID = item["id"] as? String
            state = .inOutputItem(outputIndex: outputIndex, itemType: itemType, itemID: itemID)
            if itemType == "reasoning", let itemID {
                let key = "opaque:\(itemID)"
                if !orderedKeys.contains(key) { orderedKeys.append(key) }
                opaqueItems[key] = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])
                return []
            }
            if itemType == "function_call" {
                if let itemID, let callID = item["call_id"] as? String {
                    itemToCallID[itemID] = callID
                    callToItemID[callID] = itemID
                }
                return try updateCall(callID: extractCallID(in: item), name: item["name"] as? String, arguments: item["arguments"] as? String, finish: false)
            }
            return []

        // 3. content_part.added
        case (_, "response.content_part.added"):
            let outputIndex = object["output_index"] as? Int ?? 0
            let contentIndex = object["content_index"] as? Int ?? 0
            state = .streamingText(outputIndex: outputIndex, contentIndex: contentIndex)
            return []

        // 4. output_text.delta
        case (_, "response.output_text.delta"):
            let outputIndex = object["output_index"] as? Int ?? 0
            let contentIndex = object["content_index"] as? Int ?? 0
            state = .streamingText(outputIndex: outputIndex, contentIndex: contentIndex)
            if let delta = object["delta"] as? String {
                return [.textDelta(delta)]
            }
            return []

        // 5. output_text.done & content_part.done
        case (_, "response.output_text.done"), (_, "response.content_part.done"):
            state = .inProgress(responseID: self.responseID)
            return []

        // 6. reasoning / reasoning_summary delta
        case (_, "response.reasoning_summary_text.delta"), (_, "response.reasoning.delta"):
            if let delta = object["delta"] as? String {
                return [.reasoningDelta(delta)]
            }
            return []

        // 7. function_call_arguments.delta
        case (_, "response.function_call_arguments.delta"):
            let outputIndex = object["output_index"] as? Int ?? 0
            let callID = extractCallID(in: object)
            if let callID {
                state = .streamingToolArguments(outputIndex: outputIndex, callID: callID)
            }
            return try updateCall(callID: callID, name: object["name"] as? String, arguments: object["delta"] as? String, finish: false)

        // 8. function_call_arguments.done
        case (_, "response.function_call_arguments.done"):
            let callID = extractCallID(in: object)
            return try updateCall(callID: callID, name: object["name"] as? String, arguments: object["arguments"] as? String, finish: true)

        // 9. output_item.done
        case (_, "response.output_item.done"):
            state = .inProgress(responseID: self.responseID)
            guard let item = object["item"] as? [String: Any], let itemType = item["type"] as? String else { return [] }
            if itemType == "function_call" {
                if let itemID = item["id"] as? String, let callID = item["call_id"] as? String {
                    itemToCallID[itemID] = callID
                    callToItemID[callID] = itemID
                }
                return try updateCall(callID: extractCallID(in: item), name: item["name"] as? String, arguments: item["arguments"] as? String, finish: true)
            }
            if itemType == "reasoning", let itemID = item["id"] as? String {
                let key = "opaque:\(itemID)"
                if !orderedKeys.contains(key) { orderedKeys.append(key) }
                opaqueItems[key] = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])
                return []
            }
            return []

        // 10. response.completed
        case (_, "response.completed"):
            state = .completed(status: "completed")
            var events: [ModelEvent] = []
            if let response = object["response"] as? [String: Any] {
                if let usage = response["usage"] as? [String: Any] {
                    events.append(.usage(Self.parseUsage(usage)))
                }
                let finishReason: ModelFinishReason = completedCallIDs.isEmpty ? .stop : .toolCalls
                events.append(.completed(finishReason))
            } else {
                events.append(.completed(.unknown))
            }
            return events

        // 11. response.incomplete
        case (_, "response.incomplete"):
            state = .completed(status: "incomplete")
            var events: [ModelEvent] = []
            if let response = object["response"] as? [String: Any], let usage = response["usage"] as? [String: Any] {
                events.append(.usage(Self.parseUsage(usage)))
            }
            events.append(.completed(.maxTokens))
            return events

        // 12. response.failed / error
        case (_, "response.failed"), (_, "error"):
            let failure = ResponsesProviderFailure(eventType: type, object: object, sensitiveValues: sensitiveValues)
            let errorMsg = failure?.diagnosticMessage ?? "Responses error event=\(type)"
            state = .failed(error: errorMsg)
            return [.failed(failure?.coreError ?? CoreError(code: .modelStream, message: errorMsg))]

        default:
            return []
        }
    }

    private mutating func updateCall(callID: String?, name: String?, arguments: String?, finish: Bool) throws -> [ModelEvent] {
        guard let callID, !callID.isEmpty else { throw CoreError(code: .modelStream, message: "Responses function call 缺少 call_id") }
        let domainID = domainIDs[callID] ?? ToolCallID("lingxi:\(requestID.rawValue):\(domainIDs.count)")
        domainIDs[callID] = domainID
        let orderKey = "call:\(callID)"
        if !orderedKeys.contains(orderKey) { orderedKeys.append(orderKey) }
        var call = calls[callID] ?? PartialCall()
        call.name = name ?? call.name
        if let arguments, !arguments.isEmpty {
            if finish || arguments.hasPrefix(call.arguments) { call.arguments = arguments }
            else { call.arguments += arguments }
        }
        var events: [ModelEvent] = []
        if let name = call.name, !call.started {
            call.started = true
            events.append(.toolCallStarted(callID: domainID, toolID: ToolID(name)))
        }
        if call.started, call.emitted < call.arguments.count {
            events.append(.toolCallDelta(callID: domainID, arguments: String(call.arguments.dropFirst(call.emitted))))
            call.emitted = call.arguments.count
        }
        if finish, !call.completed {
            guard let name = call.name else { throw CoreError(code: .modelStream, message: "Responses function call 缺少 name") }
            call.completed = true
            completedCallIDs.append(callID)
            references.append(ProviderToolCallReference(wire: .responses, domainCallID: domainID, externalCallID: callID, externalItemID: callToItemID[callID]))
            events.append(.toolCallCompleted(ToolCall(callID: domainID, toolID: ToolID(name), arguments: call.arguments)))
        }
        calls[callID] = call
        return events
    }

    private func extractCallID(in object: [String: Any]) -> String? {
        (object["call_id"] as? String) ?? (object["item_id"] as? String).flatMap { itemToCallID[$0] }
    }

    private static func parseUsage(_ value: [String: Any]) -> ModelUsage {
        let outputDetails = value["output_tokens_details"] as? [String: Any]
        let inputDetails = value["input_tokens_details"] as? [String: Any]
        return ModelUsage(
            inputTokens: value["input_tokens"] as? Int,
            outputTokens: value["output_tokens"] as? Int,
            reasoningTokens: outputDetails?["reasoning_tokens"] as? Int,
            cacheReadTokens: inputDetails?["cached_tokens"] as? Int
        )
    }
}

/// Stateful Responses API decoder wrapper. Backed by ResponsesStreamStateMachine.
public struct ResponsesSSEDecoder {
    public var stateMachine: ResponsesStreamStateMachine

    public var completedCallIDs: [String] { stateMachine.completedCallIDs }
    public var references: [ProviderToolCallReference] { stateMachine.references }
    public var orderedItems: [ProviderContinuationItem] { stateMachine.orderedItems }
    public var responseID: String? { stateMachine.responseID }

    public init(requestID: ModelRequestID = ModelRequestID(), sensitiveValues: [String] = []) {
        stateMachine = ResponsesStreamStateMachine(requestID: requestID, sensitiveValues: sensitiveValues)
    }

    public mutating func consume(_ payload: String) throws -> [ModelEvent] {
        guard let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { throw CoreError(code: .modelStream, message: "Responses SSE JSON 解析失败") }
        return try stateMachine.feedEvent(type: type, object: object)
    }

    public mutating func feedSSEText(_ text: String) throws -> [ModelEvent] {
        var events: [ModelEvent] = []
        var lines = SSEDecoder()
        if let data = text.data(using: .utf8) {
            for line in lines.feed(data) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("data:") else { continue }
                let payload = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]" else { break }
                events.append(contentsOf: try consume(payload))
            }
            for line in lines.flushPending() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("data:") else { continue }
                let payload = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]" else { break }
                events.append(contentsOf: try consume(payload))
            }
        }
        return events
    }
}

private struct ResponsesProviderFailure {
    let eventType: String
    let code: String?
    let message: String
    let param: String?

    init?(eventType: String, object: [String: Any], sensitiveValues: [String]) {
        guard eventType == "response.failed" || eventType == "error" else { return nil }
        let details: [String: Any]
        if eventType == "response.failed" {
            details = ((object["response"] as? [String: Any])?["error"] as? [String: Any]) ?? (object["error"] as? [String: Any]) ?? [:]
        } else {
            details = (object["error"] as? [String: Any]) ?? object
        }
        self.eventType = sanitizedProviderToken(eventType, limit: 120) ?? "error"
        code = (details["code"] as? String).flatMap { sanitizedProviderToken($0, sensitiveValues: sensitiveValues, limit: 120) }
        param = (details["param"] as? String).flatMap { sanitizedProviderToken($0, sensitiveValues: sensitiveValues, limit: 160) }
        message = sanitizedProviderMessage(details["message"] as? String ?? "Provider returned an error without a message", sensitiveValues: sensitiveValues, limit: 1_024)
    }

    var coreError: CoreError {
        var fields = ["event=\(eventType)"]
        if let code { fields.append("code=\(code)") }
        if let param { fields.append("param=\(param)") }
        return CoreError(code: .modelStream, message: "Responses provider error \(fields.joined(separator: " ")): \(message)")
    }

    var diagnosticMessage: String { sanitizedProviderMessage(message, sensitiveValues: [], limit: 240) }
}

private func sanitizedProviderToken(_ value: String, sensitiveValues: [String] = [], limit: Int) -> String? {
    let sanitized = sanitizedProviderMessage(value, sensitiveValues: sensitiveValues, limit: limit)
        .map { $0.isLetter || $0.isNumber || "._:-/[]".contains($0) ? $0 : "_" }
    let result = String(sanitized)
    return result.isEmpty ? nil : result
}

private func sanitizedProviderMessage(_ value: String, sensitiveValues: [String], limit: Int) -> String {
    var result = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    for secret in sensitiveValues where !secret.isEmpty { result = result.replacingOccurrences(of: secret, with: "<redacted>") }
    let patterns = [
        #"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#,
        #"(?i)(\"(?:authorization|api[_-]?key|access[_-]?token|client[_-]?secret|encrypted_content|prompt|input)\"\s*:\s*)\"(?:\\.|[^\"])*\""#,
        #"(?i)\b[A-Za-z0-9._-]*(?:secret|api[_-]?key)[A-Za-z0-9._-]*\b"#,
        #"\bsk-[A-Za-z0-9_-]+\b"#,
    ]
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: pattern.contains("authorization") ? "$1\"<redacted>\"" : "<redacted>")
    }
    result = result.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    guard result.count > limit else { return result }
    return String(result.prefix(limit)) + "..."
}

private struct ResponseRequestBody: Encodable {
    struct Tool: Encodable {
        let type = "function"
        let name: String
        let description: String
        let parameters: JSONValue

        init(_ definition: ToolDefinition) {
            name = definition.name
            description = definition.description
            parameters = definition.rawInputSchema ?? .object([
                "type": .string("object"),
                "properties": .object(definition.inputSchema.properties.mapValues { property in
                    var value: [String: JSONValue] = ["type": .string(property.type.rawValue), "description": .string(property.description)]
                    if let values = property.enumValues { value["enum"] = .array(values.map(JSONValue.string)) }
                    if let minimum = property.minimum { value["minimum"] = .number(minimum) }
                    if let maximum = property.maximum { value["maximum"] = .number(maximum) }
                    return .object(value)
                }),
                "required": .array(definition.inputSchema.required.map(JSONValue.string)),
                "additionalProperties": .bool(false),
            ])
        }
    }

    struct Reasoning: Encodable {
        let effort: String?
        let summary: String?
        init(effort: String? = nil, summary: String? = nil) {
            self.effort = effort
            self.summary = summary
        }
    }

    enum Input: Encodable {
        case message(role: String, content: String)
        case functionCall(callID: String, name: String, arguments: String, itemID: String? = nil)
        case functionOutput(callID: String, output: String)
        case opaque(Data)

        enum Keys: String, CodingKey { case type, role, content, callID = "call_id", name, arguments, output, id, status }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: Keys.self)
            switch self {
            case let .message(role, content):
                try values.encode(role, forKey: .role); try values.encode(content, forKey: .content)
            case let .functionCall(callID, name, arguments, itemID):
                try values.encode("function_call", forKey: .type)
                try values.encode(callID, forKey: .callID)
                try values.encode(name, forKey: .name)
                try values.encode(arguments, forKey: .arguments)
                if let itemID { try values.encode(itemID, forKey: .id) }
            case let .functionOutput(callID, output):
                try values.encode("function_call_output", forKey: .type); try values.encode(callID, forKey: .callID); try values.encode(output, forKey: .output)
            case let .opaque(data):
                try JSONDecoder().decode(JSONValue.self, from: data).encode(to: encoder)
            }
        }
    }

    let model: String
    let stream: Bool
    let store: Bool
    let instructions: String?
    let input: [Input]
    let tools: [Tool]?
    let reasoning: Reasoning?
    let include: [String]?
    let previousResponseID: String?

    enum CodingKeys: String, CodingKey {
        case model, stream, store, instructions, input, tools, reasoning, include
        case previousResponseID = "previous_response_id"
    }
}
