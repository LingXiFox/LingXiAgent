import Foundation
import LingXiPluginABI

/// Everything about MiMo's wire formats lives here. The plugin exposes one provider id, but settings
/// choose between the Chat Completions and Responses families; the two encoders and normalizers are
/// deliberately separate so a change in one cannot silently alter the other.
enum MiMoWire {
    static let chatEndpoint = URL(string: "https://api.xiaomimimo.com/v1/chat/completions")!
    static let responsesEndpoint = URL(string: "https://api.xiaomimimo.com/v1/responses")!
    /// Kept for older call sites; Chat Completions remains the historical default.
    static let endpoint = chatEndpoint
    static let providerID = "mimo"
    static let models = ["mimo-v2.6-flash", "mimo-v2.6-pro"]

    static func endpoint(for config: MiMoConfig) -> URL {
        switch config.protocolKind {
        case .chatCompletions: chatEndpoint
        case .responses: responsesEndpoint
        }
    }

    // MARK: - Chat Completions request

    struct Body: Encodable {
        let model: String
        let messages: [Message]
        let tools: [Tool]?
        let stream = true
        let stream_options = StreamOptions()
        let thinking: Thinking?
    }

    struct StreamOptions: Encodable { let include_usage = true }

    /// `{"thinking":{"type":"enabled"|"disabled"}}`; omitted in `default` mode.
    struct Thinking: Encodable { let type: String }

    /// Chat Completions messages: one shape for text turns, the assistant tool call and the tool
    /// result. `content` is null only for an assistant message that carries calls.
    struct Message: Encodable {
        let role: String
        var content: String?
        var tool_calls: [ToolCall]?
        var tool_call_id: String?
        /// MiMo's Chat Completions extension: reasoning of the assistant turn that issued the
        /// tool calls. Kept only for the live tool loop; never persisted by the Core.
        var reasoning_content: String?
    }

    struct ToolCall: Encodable {
        let id: String
        let type = "function"
        let function: Function
    }

    struct Function: Encodable {
        let name: String
        let arguments: String
    }

    struct Tool: Encodable {
        let type = "function"
        let function: FunctionDefinition
    }

    struct FunctionDefinition: Encodable {
        let name: String
        let description: String?
        let parameters: JSONValue
    }

    static func body(for request: ProviderWireRequest, config: MiMoConfig) throws -> [UInt8] {
        var messages: [Message] = []
        if let instructions = request.instructions, !instructions.isEmpty {
            messages.append(Message(role: "system", content: instructions))
        }
        // A function may emit calls and its results as separate items; merge them into the assistant
        // message shape Chat Completions expects.
        var pendingCalls: [ToolCall] = []
        func flushCalls() {
            guard !pendingCalls.isEmpty else { return }
            let callIDs = Set(pendingCalls.map(\.id))
            let structured = (request.previousReasoningTurns ?? [])
                .filter { !callIDs.isDisjoint(with: $0.callIDs) }
                .flatMap { $0.items.map(\.text) }
                .joined(separator: "\n\n")
            messages.append(Message(
                role: "assistant", content: nil, tool_calls: pendingCalls,
                reasoning_content: structured.isEmpty ? request.previousReasoning : structured
            ))
            pendingCalls.removeAll()
        }
        for item in request.input {
            switch item.kind {
            case .message:
                flushCalls()
                messages.append(Message(role: item.role ?? "user", content: item.text ?? ""))
            case .functionCall:
                pendingCalls.append(ToolCall(
                    id: item.callID ?? "",
                    function: Function(name: item.name ?? "", arguments: item.arguments ?? "{}")
                ))
            case .functionCallOutput:
                flushCalls()
                messages.append(Message(role: "tool", content: item.output ?? "", tool_call_id: item.callID))
            }
        }
        flushCalls()

        let tools = try request.tools.map { tool in
            Tool(function: FunctionDefinition(
                name: tool.name,
                description: tool.description,
                parameters: try JSONValue(data: Data(tool.parametersJSON.utf8))
            ))
        }
        let body = Body(
            // The routed model wins: a settings snapshot must not redirect a request that the Core
            // resolved to another declared MiMo model.
            model: request.model,
            messages: messages,
            tools: tools.isEmpty ? nil : tools,
            thinking: config.chatThinkingType.map(Thinking.init(type:))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Array(try encoder.encode(body))
    }

    // MARK: - Responses request

    struct ResponsesBody: Encodable {
        let model: String
        let instructions: String?
        let input: [ResponsesInputItem]
        let tools: [ResponsesTool]?
        let stream = true
        let max_output_tokens: Int?
        let reasoning: Reasoning?

        enum CodingKeys: String, CodingKey {
            case model, instructions, input, tools, stream, reasoning
            case max_output_tokens = "max_output_tokens"
        }
    }

    /// Only `effort` is sent. The Responses request must not carry previous_response_id,
    /// background, or context_management: the kernel owns history and the plugin is stateless.
    struct Reasoning: Encodable { let effort: String }

    struct ResponsesInputItem: Encodable {
        let type: String
        var role: String?
        var content: [ResponsesContent]?
        var id: String?
        var status: String?
        var call_id: String?
        var name: String?
        var arguments: String?
        var output: String?
    }

    struct ResponsesContent: Encodable {
        let type: String
        let text: String
    }

    struct ResponsesTool: Encodable {
        let type = "function"
        let name: String
        let description: String?
        let parameters: JSONValue
    }

    static func responsesBody(for request: ProviderWireRequest, config: MiMoConfig) throws -> [UInt8] {
        var items: [ResponsesInputItem] = []
        // A Reasoning item belongs immediately before the function_call it accompanied. The
        // official contract says to keep all historical thinking content in `input`; it forbids
        // previous_response_id, so the kernel-owned history is the only carrier.
        var turnForCall: [String: Int] = [:]
        for (index, turn) in (request.previousReasoningTurns ?? []).enumerated() {
            for callID in turn.callIDs { turnForCall[callID] = index }
        }
        var insertedTurns: Set<Int> = []
        for item in request.input {
            switch item.kind {
            case .message:
                let role = item.role ?? "user"
                items.append(ResponsesInputItem(
                    type: "message", role: role,
                    content: [ResponsesContent(
                        type: role == "assistant" ? "output_text" : "input_text",
                        text: item.text ?? ""
                    )]
                ))
            case .functionCall:
                if let callID = item.callID, let index = turnForCall[callID],
                   insertedTurns.insert(index).inserted {
                    for reasoning in (request.previousReasoningTurns ?? [])[index].items {
                        items.append(ResponsesInputItem(
                            type: "reasoning", content: [
                                ResponsesContent(type: "reasoning_text", text: reasoning.text)
                            ], id: reasoning.id, status: reasoning.status
                        ))
                    }
                }
                items.append(ResponsesInputItem(
                    type: "function_call", call_id: item.callID, name: item.name,
                    arguments: item.arguments
                ))
            case .functionCallOutput:
                items.append(ResponsesInputItem(
                    type: "function_call_output", call_id: item.callID, output: item.output
                ))
            }
        }
        let tools = try request.tools.map { tool in
            ResponsesTool(
                name: tool.name,
                description: tool.description,
                parameters: try JSONValue(data: Data(tool.parametersJSON.utf8))
            )
        }
        let body = ResponsesBody(
            // The routed model wins, matching the Chat encoder: config.model is the settings
            // default/validation value, not an override of the Core's model route.
            model: request.model,
            instructions: request.instructions,
            input: items,
            tools: tools.isEmpty ? nil : tools,
            max_output_tokens: request.maxOutputTokens,
            reasoning: config.responsesEffort.map(Reasoning.init(effort:))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Array(try encoder.encode(body))
    }

    // MARK: - cassette digest

    /// The digest covers the protocol, model, thinking mode and effort in addition to the neutral
    /// request. Different settings therefore cannot replay each other's cassette exchange, while
    /// the credential and execution id are never part of the key.
    static func digest(for request: ProviderWireRequest, config: MiMoConfig) -> String {
        let payload = DigestPayload(
            request: redactedRequest(request),
            settings: DigestSettings(
                protocolKind: config.protocolKind.rawValue,
                model: config.model,
                thinkingMode: config.thinkingMode.rawValue,
                reasoningEffort: config.reasoningEffort
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return MiMoDigest.hex((try? encoder.encode(payload)) ?? Data())
    }

    /// The pre-settings key. Kept only so cassettes recorded before this change (notably the real
    /// `mimo-chat-live.json`) continue to replay under the exact default Chat configuration.
    /// Any explicit protocol/thinking/effort choice uses the new key, so configs never alias.
    static func legacyDigestIfApplicable(for request: ProviderWireRequest, config: MiMoConfig) -> String? {
        guard config.protocolKind == .chatCompletions,
              config.thinkingMode == .default,
              config.reasoningEffort == nil,
              config.model == request.model else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return MiMoDigest.hex((try? encoder.encode(redactedRequest(request))) ?? Data())
    }

    private struct DigestPayload: Encodable {
        let request: ProviderWireRequest
        let settings: DigestSettings
    }

    private struct DigestSettings: Encodable {
        let protocolKind: String
        let model: String
        let thinkingMode: String
        let reasoningEffort: String?
    }

    private static func redactedRequest(_ request: ProviderWireRequest) -> ProviderWireRequest {
        ProviderWireRequest(
            model: request.model, instructions: request.instructions, input: request.input,
            tools: request.tools, maxOutputTokens: request.maxOutputTokens, credential: nil,
            executionID: nil
        )
    }

    // MARK: - Chat Completions SSE normalization

    /// Chat Completions chunks carry deltas per choice. Tool calls are indexed and their name/id
    /// arrive once, so the normalizer accumulates them and only completes a call at finish.
    struct Normalizer {
        private struct Call {
            var id: String
            var name: String
            var arguments: String
        }

        private var calls: [Int: Call] = [:]
        private var order: [Int] = []
        private var pendingFinish: String?
        private var terminalEmitted = false
        private var usageEmitted = false
        private var announced: Set<Int> = []

        var hasTerminal: Bool { terminalEmitted }

        /// Returns events for one chunk. The terminal is deliberately held until `finalize` so a
        /// trailing usage chunk is not dropped by the kernel's terminal guard.
        mutating func consume(data: String) -> [ProviderWireEvent] {
            guard data != "[DONE]" else { return [] }
            guard let object = try? JSONValue(data: Data(data.utf8)) else { return [] }

            if let error = object.object?["error"]?.object {
                pendingFinish = nil
                terminalEmitted = true
                return [.init(
                    type: "failed",
                    failureKind: mapFailure(error["code"]?.string ?? error["type"]?.string),
                    message: error["message"]?.string ?? "the provider sent an error object"
                )]
            }

            var produced: [ProviderWireEvent] = []
            if let usage = object.object?["usage"]?.object, !usage.isEmpty {
                usageEmitted = true
                produced.append(.init(type: "usage", usage: ProviderWireUsage(
                    inputTokens: usage["prompt_tokens"]?.numberValue.map(Int.init),
                    outputTokens: usage["completion_tokens"]?.numberValue.map(Int.init),
                    reasoningTokens: usage["completion_tokens_details"]?.object?["reasoning_tokens"]?.numberValue.map(Int.init),
                    cacheReadTokens: usage["prompt_tokens_details"]?.object?["cached_tokens"]?.numberValue.map(Int.init),
                    cacheWriteTokens: nil
                )))
            }

            guard let choice = object.object?["choices"]?.array?.first?.object else { return produced }
            let delta = choice["delta"]?.object

            if let reasoning = delta?["reasoning_content"]?.string, !reasoning.isEmpty {
                produced.append(.init(type: "reasoningDelta", text: reasoning))
            }
            if let text = delta?["content"]?.string, !text.isEmpty {
                produced.append(.init(type: "textDelta", text: text))
            }
            if let toolCalls = delta?["tool_calls"]?.array {
                produced.append(contentsOf: ingest(toolCalls))
            }
            if let finish = choice["finish_reason"]?.string {
                pendingFinish = finish
            }
            return produced
        }

        /// Emits any accumulated tool calls, then exactly one terminal event.
        mutating func finalize() -> [ProviderWireEvent] {
            guard !terminalEmitted, let finish = pendingFinish else { return [] }
            terminalEmitted = true
            var produced: [ProviderWireEvent] = []
            for index in order {
                guard let call = calls[index], !call.id.isEmpty else { continue }
                produced.append(.init(
                    type: "toolCallCompleted", callID: call.id,
                    name: call.name, arguments: call.arguments.isEmpty ? "{}" : call.arguments
                ))
            }
            switch finish {
            case "tool_calls": produced.append(.init(type: "completed", stopReason: "toolCalls"))
            case "length": produced.append(.init(type: "completed", stopReason: "maxTokens"))
            case "content_filter": produced.append(.init(type: "completed", stopReason: "contentFilter"))
            case "stop": produced.append(.init(type: "completed", stopReason: "stop"))
            default: produced.append(.init(type: "completed", stopReason: "unknown"))
            }
            return produced
        }

        private mutating func ingest(_ rawCalls: [JSONValue]) -> [ProviderWireEvent] {
            var produced: [ProviderWireEvent] = []
            for raw in rawCalls {
                guard let entry = raw.object, let index = entry["index"]?.numberValue.map(Int.init) else { continue }
                let function = entry["function"]?.object
                let isNew = calls[index] == nil
                var call = calls[index] ?? Call(id: "", name: "", arguments: "")
                if let id = entry["id"]?.string, !id.isEmpty { call.id = id }
                if let name = function?["name"]?.string, !name.isEmpty { call.name = name }
                if isNew { order.append(index) }

                // The id and name may land in different chunks; announce only once both exist, and
                // hold argument fragments until then so the kernel never sees a delta for an
                // unstarted call.
                if !announced.contains(index), !call.id.isEmpty, !call.name.isEmpty {
                    announced.insert(index)
                    produced.append(.init(type: "toolCallStarted", callID: call.id, name: call.name))
                }
                if let fragment = function?["arguments"]?.string, !fragment.isEmpty {
                    call.arguments += fragment
                    if announced.contains(index), !call.id.isEmpty {
                        produced.append(.init(type: "toolCallDelta", callID: call.id, arguments: fragment))
                    }
                }
                calls[index] = call
            }
            return produced
        }

        private func mapFailure(_ code: String?) -> String {
            switch code {
            case "rate_limit_exceeded", "rate_limit_error": return "rateLimited"
            case "context_length_exceeded": return "contextExceeded"
            case "invalid_api_key", "authentication_error": return "unauthorized"
            case "content_filter": return "contentFilter"
            case "invalid_request_error": return "invalidRequest"
            case "server_error", "overloaded_error": return "serverOverloaded"
            case "timeout": return "gatewayTimeout"
            default: return "transport"
            }
        }
    }

    // MARK: - Responses SSE normalization

    /// Stateful translator for one Responses stream. Events are keyed by `sequence_number` when
    /// present, which is the only reliable way to drop a retried delta without dropping legitimate
    /// repeated text. `done` events never re-emit a segment that already arrived as deltas, tool
    /// calls complete exactly once, and every terminal is emitted at most once.
    struct ResponsesNormalizer {
        private struct Call {
            var callID: String
            var itemID: String
            var name: String
            var arguments: String
            var started: Bool
            var completed: Bool
        }

        private var calls: [String: Call] = [:]
        private var callIDByItem: [String: String] = [:]
        private var seenSequences: Set<Int> = []
        private var textItemsWithDeltas: Set<String> = []
        private var reasoningItemsWithDeltas: Set<String> = []
        private var sawAnyTextDelta = false
        private var sawAnyReasoningDelta = false
        private var createdEmitted = false
        private var usageEmitted = false
        private var terminalEmitted = false
        private var cancelled = false
        private var sawToolCall = false

        var hasTerminal: Bool { terminalEmitted }

        /// Cancellation is local state, not just a Task flag: any event that was already queued for
        /// this stream is discarded instead of being delivered after the caller gave up.
        mutating func cancel() {
            cancelled = true
        }

        mutating func consume(event name: String?, data: String) -> [ProviderWireEvent] {
            guard !cancelled, !terminalEmitted, data != "[DONE]" else { return [] }
            guard let root = try? JSONValue(data: Data(data.utf8)).object else { return [] }

            if let sequence = root["sequence_number"]?.numberValue.map(Int.init) {
                guard seenSequences.insert(sequence).inserted else { return [] }
            }
            let type = (name?.isEmpty == false ? name! : root["type"]?.string) ?? ""

            var produced: [ProviderWireEvent] = []
            switch type {
            case "response.created":
                if !createdEmitted, let id = root["response"]?.object?["id"]?.string, !id.isEmpty {
                    createdEmitted = true
                    produced.append(.init(type: "providerRequestID", requestID: id))
                }

            case "response.output_text.delta":
                let itemID = itemID(root)
                if let delta = root["delta"]?.string ?? root["text"]?.string, !delta.isEmpty {
                    textItemsWithDeltas.insert(itemID)
                    sawAnyTextDelta = true
                    produced.append(.init(type: "textDelta", text: delta))
                }

            case "response.output_text.done":
                // Never duplicate the whole segment after a stream of deltas. If a non-conforming
                // provider sent no delta at all, the done event is the only copy of the text.
                // A missing item id is treated as the same stream, not as a new segment.
                let itemID = itemID(root)
                if !textItemsWithDeltas.contains(itemID),
                   !(itemID.isEmpty && sawAnyTextDelta),
                   let text = root["text"]?.string, !text.isEmpty {
                    textItemsWithDeltas.insert(itemID)
                    sawAnyTextDelta = true
                    produced.append(.init(type: "textDelta", text: text))
                }

            case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
                let itemID = itemID(root)
                if let delta = root["delta"]?.string ?? root["text"]?.string, !delta.isEmpty {
                    reasoningItemsWithDeltas.insert(itemID)
                    sawAnyReasoningDelta = true
                    produced.append(.init(
                        type: "reasoningDelta", text: delta,
                        itemID: itemID.isEmpty ? nil : itemID,
                        status: root["status"]?.string
                    ))
                }

            case "response.reasoning_text.done", "response.reasoning_summary_text.done":
                let itemID = itemID(root)
                if !reasoningItemsWithDeltas.contains(itemID),
                   !(itemID.isEmpty && sawAnyReasoningDelta),
                   let text = root["text"]?.string, !text.isEmpty {
                    reasoningItemsWithDeltas.insert(itemID)
                    sawAnyReasoningDelta = true
                    produced.append(.init(
                        type: "reasoningDelta", text: text,
                        itemID: itemID.isEmpty ? nil : itemID,
                        status: root["status"]?.string ?? "completed"
                    ))
                }

            case "response.output_item.added":
                if let item = root["item"]?.object, item["type"]?.string == "reasoning" {
                    if let event = reasoningItemEvent(from: item) { produced.append(event) }
                    break
                }
                guard let item = root["item"]?.object, item["type"]?.string == "function_call" else { break }
                let callID = item["call_id"]?.string ?? item["id"]?.string ?? ""
                let itemID = item["id"]?.string ?? callID
                guard !callID.isEmpty else { break }
                sawToolCall = true
                var call = ensureCall(callID: callID, itemID: itemID)
                if let name = item["name"]?.string, !name.isEmpty { call.name = name }
                if let arguments = item["arguments"]?.string, !arguments.isEmpty {
                    call.arguments += arguments
                }
                calls[callID] = call
                produced.append(contentsOf: startIfReady(callID: callID))

            case "response.function_call_arguments.delta":
                let itemID = root["item_id"]?.string ?? ""
                let callID = root["call_id"]?.string ?? callIDByItem[itemID] ?? itemID
                let delta = root["delta"]?.string ?? ""
                guard !callID.isEmpty, !delta.isEmpty else { break }
                sawToolCall = true
                produced.append(contentsOf: appendArgumentDelta(callID: callID, itemID: itemID, delta: delta))

            case "response.function_call_arguments.done":
                let itemID = root["item_id"]?.string ?? ""
                let callID = root["call_id"]?.string ?? callIDByItem[itemID] ?? itemID
                guard !callID.isEmpty else { break }
                sawToolCall = true
                var call = ensureCall(callID: callID, itemID: itemID)
                if let name = root["name"]?.string, !name.isEmpty { call.name = name }
                if let arguments = root["arguments"]?.string, !arguments.isEmpty { call.arguments = arguments }
                calls[callID] = call
                produced.append(contentsOf: startIfReady(callID: callID))
                produced.append(contentsOf: complete(callID: callID))

            case "response.output_item.done":
                if let item = root["item"]?.object, item["type"]?.string == "reasoning" {
                    if let event = reasoningItemEvent(from: item) { produced.append(event) }
                    break
                }
                guard let item = root["item"]?.object, item["type"]?.string == "function_call" else { break }
                let callID = item["call_id"]?.string ?? item["id"]?.string ?? ""
                let itemID = item["id"]?.string ?? callID
                guard !callID.isEmpty else { break }
                sawToolCall = true
                var call = ensureCall(callID: callID, itemID: itemID)
                if let name = item["name"]?.string, !name.isEmpty { call.name = name }
                if let arguments = item["arguments"]?.string, !arguments.isEmpty { call.arguments = arguments }
                calls[callID] = call
                produced.append(contentsOf: startIfReady(callID: callID))
                produced.append(contentsOf: complete(callID: callID))

            case "response.completed":
                if let usage = usageEvent(from: root) { produced.append(usage) }
                let response = root["response"]?.object
                if let output = response?["output"]?.array {
                    for item in output {
                        guard let object = item.object, object["type"]?.string == "reasoning",
                              let event = reasoningItemEvent(from: object) else { continue }
                        produced.append(event)
                    }
                }
                if response?["status"]?.string == "incomplete" {
                    produced.append(incompleteEvent(response: response))
                } else {
                    produced.append(.init(type: "completed", stopReason: sawToolCall ? "toolCalls" : "stop"))
                }

            case "response.incomplete":
                if let usage = usageEvent(from: root) { produced.append(usage) }
                produced.append(incompleteEvent(response: root["response"]?.object))

            case "response.failed":
                if let usage = usageEvent(from: root) { produced.append(usage) }
                let response = root["response"]?.object
                let error = response?["error"]?.object ?? root["error"]?.object
                produced.append(.init(
                    type: "failed",
                    failureKind: mapFailure(error?["code"]?.string ?? error?["type"]?.string),
                    message: error?["message"]?.string ?? "the provider reported a failed response"
                ))

            case "error":
                if let usage = usageEvent(from: root) { produced.append(usage) }
                let error = root["error"]?.object ?? root
                produced.append(.init(
                    type: "failed",
                    failureKind: mapFailure(error["code"]?.string ?? error["type"]?.string),
                    message: error["message"]?.string ?? "the provider sent an error event"
                ))

            case "response.usage", "usage":
                if let usage = usageEvent(from: root) { produced.append(usage) }

            default:
                break
            }

            if produced.contains(where: { $0.type == "completed" || $0.type == "failed" }) {
                terminalEmitted = true
            }
            return produced
        }

        mutating func finalize() -> [ProviderWireEvent] { [] }

        // MARK: helpers

        private func itemID(_ root: [String: JSONValue]) -> String {
            if let id = root["item_id"]?.string, !id.isEmpty { return id }
            if let index = root["output_index"]?.numberValue.map(Int.init) {
                return "output:\(index)"
            }
            return ""
        }

        private mutating func ensureCall(callID: String, itemID: String) -> Call {
            if let existing = calls[callID] { return existing }
            let call = Call(
                callID: callID, itemID: itemID, name: "", arguments: "",
                started: false, completed: false
            )
            calls[callID] = call
            if !itemID.isEmpty { callIDByItem[itemID] = callID }
            return call
        }

        private mutating func appendArgumentDelta(
            callID: String, itemID: String, delta: String
        ) -> [ProviderWireEvent] {
            var call = ensureCall(callID: callID, itemID: itemID)
            let wasStarted = call.started
            call.arguments += delta
            calls[callID] = call
            var produced = startIfReady(callID: callID)
            // If the call had not started yet, startIfReady released the buffered prefix (which now
            // includes this fragment). Emitting it again here would duplicate the delta.
            if wasStarted {
                produced.append(.init(type: "toolCallDelta", callID: callID, arguments: delta))
            }
            return produced
        }

        /// Emits `toolCallStarted` once the name is known, followed by any buffered argument prefix.
        private mutating func startIfReady(callID: String) -> [ProviderWireEvent] {
            guard var call = calls[callID], !call.started, !call.name.isEmpty else { return [] }
            call.started = true
            let buffered = call.arguments
            calls[callID] = call
            var produced: [ProviderWireEvent] = [
                .init(type: "toolCallStarted", callID: call.callID, name: call.name)
            ]
            if !buffered.isEmpty {
                produced.append(.init(type: "toolCallDelta", callID: call.callID, arguments: buffered))
            }
            return produced
        }

        /// One `toolCallCompleted` per call, no matter how many done markers arrive.
        private mutating func complete(callID: String) -> [ProviderWireEvent] {
            guard var call = calls[callID], !call.completed else { return [] }
            call.completed = true
            let arguments = call.arguments.isEmpty ? "{}" : call.arguments
            calls[callID] = call
            return [.init(
                type: "toolCallCompleted", callID: call.callID,
                name: call.name, arguments: arguments
            )]
        }

        /// Preserve the documented Reasoning item shape: id, content[type=reasoning_text], type and
        /// status. Never flatten it into assistant/user text.
        private func reasoningItemEvent(from item: [String: JSONValue]) -> ProviderWireEvent? {
            var text = ""
            if let content = item["content"]?.array {
                for part in content {
                    guard let object = part.object,
                          object["type"]?.string == "reasoning_text" || object["type"] == nil,
                          let value = object["text"]?.string else { continue }
                    text += value
                }
            }
            guard !text.isEmpty else { return nil }
            return ProviderWireEvent(
                type: "reasoningItem", text: text,
                itemID: item["id"]?.string,
                status: item["status"]?.string
            )
        }

        private mutating func usageEvent(from root: [String: JSONValue]) -> ProviderWireEvent? {
            guard !usageEmitted else { return nil }
            let response = root["response"]?.object
            guard let usage = root["usage"]?.object ?? response?["usage"]?.object, !usage.isEmpty else {
                return nil
            }
            usageEmitted = true
            let inputDetails = usage["input_tokens_details"]?.object
            let outputDetails = usage["output_tokens_details"]?.object
            return .init(type: "usage", usage: ProviderWireUsage(
                inputTokens: usage["input_tokens"]?.numberValue.map(Int.init)
                    ?? usage["prompt_tokens"]?.numberValue.map(Int.init),
                outputTokens: usage["output_tokens"]?.numberValue.map(Int.init)
                    ?? usage["completion_tokens"]?.numberValue.map(Int.init),
                reasoningTokens: outputDetails?["reasoning_tokens"]?.numberValue.map(Int.init)
                    ?? usage["reasoning_tokens"]?.numberValue.map(Int.init),
                cacheReadTokens: inputDetails?["cached_tokens"]?.numberValue.map(Int.init)
                    ?? usage["cache_read_input_tokens"]?.numberValue.map(Int.init)
                    ?? usage["cacheReadTokens"]?.numberValue.map(Int.init),
                cacheWriteTokens: inputDetails?["cache_write_tokens"]?.numberValue.map(Int.init)
                    ?? usage["cache_creation_input_tokens"]?.numberValue.map(Int.init)
                    ?? usage["cacheWriteTokens"]?.numberValue.map(Int.init)
            ))
        }

        private func incompleteEvent(response: [String: JSONValue]?) -> ProviderWireEvent {
            let reason = response?["incomplete_details"]?.object?["reason"]?.string ?? "unknown"
            let kind = reason == "content_filter" ? "contentFilter" : "streamProtocol"
            return .init(
                type: "failed", failureKind: kind,
                message: "the provider marked the response incomplete (\(reason))"
            )
        }

        private func mapFailure(_ code: String?) -> String {
            switch code {
            case "rate_limit_exceeded", "rate_limit", "insufficient_quota": return "rateLimited"
            case "context_length_exceeded", "context_length": return "contextExceeded"
            case "invalid_api_key", "authentication_error": return "unauthorized"
            case "content_filter": return "contentFilter"
            case "invalid_request_error": return "invalidRequest"
            case "server_error", "overloaded_error": return "serverOverloaded"
            case "timeout": return "gatewayTimeout"
            default: return "streamProtocol"
            }
        }
    }
}

enum MiMoDigest {
    /// FNV-1a 64-bit; a stable cassette key, not a cryptographic one. The credential is excluded
    /// before hashing, so no secret can leak into a recorded file.
    static func hex(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
