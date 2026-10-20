import Foundation
import LingXiPluginABI

/// MiMo speaks the OpenAI Chat Completions family, not DeepSeek's Responses family. The two plugins
/// stay independent on purpose: no cross-vendor compatibility layer, just each vendor's wire format
/// translated into the same neutral events.
enum MiMoWire {
    static let endpoint = URL(string: "https://api.xiaomimimo.com/v1/chat/completions")!
    static let providerID = "mimo"
    static let models = ["mimo-v2.6-flash", "mimo-v2.6-pro"]

    // MARK: - request

    struct Body: Encodable {
        let model: String
        let messages: [Message]
        let tools: [Tool]?
        let stream = true
        let stream_options = StreamOptions()
    }

    struct StreamOptions: Encodable { let include_usage = true }

    /// Chat Completions messages: one shape for text turns, the assistant tool call and the tool
    /// result. `content` is null only for an assistant message that carries calls.
    struct Message: Encodable {
        let role: String
        var content: String?
        var tool_calls: [ToolCall]?
        var tool_call_id: String?
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

    static func body(for request: ProviderWireRequest) throws -> [UInt8] {
        var messages: [Message] = []
        if let instructions = request.instructions, !instructions.isEmpty {
            messages.append(Message(role: "system", content: instructions))
        }
        // A function may emit calls and its results as separate items; merge them into the assistant
        // message shape Chat Completions expects.
        var pendingCalls: [ToolCall] = []
        func flushCalls() {
            guard !pendingCalls.isEmpty else { return }
            messages.append(Message(role: "assistant", content: nil, tool_calls: pendingCalls))
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
            model: request.model,
            messages: messages,
            tools: tools.isEmpty ? nil : tools
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Array(try encoder.encode(body))
    }

    static func digest(for request: ProviderWireRequest) -> String {
        let redacted = ProviderWireRequest(
            model: request.model, instructions: request.instructions, input: request.input,
            tools: request.tools, maxOutputTokens: request.maxOutputTokens, credential: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return MiMoDigest.hex((try? encoder.encode(redacted)) ?? Data())
    }

    // MARK: - SSE normalization

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
