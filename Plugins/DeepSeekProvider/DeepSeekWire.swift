import Foundation
import LingXiPluginABI

/// Everything about DeepSeek's wire format lives here: request encoding, SSE event names, and the
/// translation into the provider-neutral `ProviderWireEvent`. No other file may know these names.
enum DeepSeekWire {
    static let endpoint = URL(string: "https://api.deepseek.com/responses")!
    static let providerID = "deepseek"

    // MARK: - request

    struct Body: Encodable {
        let model: String
        let instructions: String?
        let input: [InputItem]
        let tools: [Tool]?
        let stream = true
        let max_output_tokens: Int?

        enum CodingKeys: String, CodingKey {
            case model, instructions, input, tools, stream
            case max_output_tokens = "max_output_tokens"
        }
    }

    struct InputItem: Encodable {
        let type: String
        var role: String?
        var content: [Content]?
        var call_id: String?
        var name: String?
        var arguments: String?
        var output: String?
    }

    struct Content: Encodable {
        let type: String
        let text: String
    }

    struct Tool: Encodable {
        let type = "function"
        let name: String
        let description: String?
        let parameters: JSONValue
    }

    static func body(for request: ProviderWireRequest) throws -> [UInt8] {
        var items: [InputItem] = []
        for item in request.input {
            switch item.kind {
            case .message:
                let role = item.role ?? "user"
                items.append(InputItem(
                    type: "message", role: role,
                    content: [Content(
                        type: role == "assistant" ? "output_text" : "input_text",
                        text: item.text ?? ""
                    )]
                ))
            case .functionCall:
                items.append(InputItem(
                    type: "function_call", call_id: item.callID, name: item.name, arguments: item.arguments
                ))
            case .functionCallOutput:
                items.append(InputItem(
                    type: "function_call_output", call_id: item.callID, output: item.output
                ))
            }
        }
        let tools = try request.tools.map { tool in
            Tool(
                name: tool.name,
                description: tool.description,
                parameters: try JSONValue(data: Data(tool.parametersJSON.utf8))
            )
        }
        let body = Body(
            model: request.model,
            instructions: request.instructions,
            input: items,
            tools: tools.isEmpty ? nil : tools,
            max_output_tokens: request.maxOutputTokens
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Array(try encoder.encode(body))
    }

    /// A request digest without the credential, used to match cassette exchanges. Never includes the
    /// authorization value, so a recorded cassette cannot leak it.
    static func digest(for request: ProviderWireRequest) -> String {
        let redacted = ProviderWireRequest(
            model: request.model, instructions: request.instructions, input: request.input,
            tools: request.tools, maxOutputTokens: request.maxOutputTokens, credential: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(redacted)) ?? Data()
        return StableDigest.hex(data)
    }

    // MARK: - SSE normalization

    /// Stateful translator for one response stream.
    struct Normalizer {
        private var callByItem: [String: String] = [:]
        private var callNames: [String: String] = [:]
        private var sawToolCall = false
        private var emittedTerminal = false
        private var completedCalls: Set<String> = []
        private(set) var emitted: [ProviderWireEvent] = []

        mutating func consume(event name: String?, data: String) -> [ProviderWireEvent] {
            guard data != "[DONE]" else { return [] }
            guard let object = try? JSONValue(data: Data(data.utf8)) else { return [] }
            let type = name ?? object.object?["type"]?.string ?? ""
            var produced: [ProviderWireEvent] = []

            switch type {
            case "response.created":
                if let id = object.object?["response"]?.object?["id"]?.string {
                    produced.append(.init(type: "providerRequestID", requestID: id))
                }
            case "response.output_text.delta":
                if let delta = object.object?["delta"]?.string, !delta.isEmpty {
                    produced.append(.init(type: "textDelta", text: delta))
                }
            case "response.reasoning_text.delta":
                if let delta = object.object?["delta"]?.string, !delta.isEmpty {
                    produced.append(.init(type: "reasoningDelta", text: delta))
                }
            case "response.output_item.added":
                guard let item = object.object?["item"]?.object, item["type"]?.string == "function_call" else { break }
                let callID = item["call_id"]?.string ?? item["id"]?.string ?? ""
                let itemID = item["id"]?.string ?? callID
                let callName = item["name"]?.string ?? ""
                callByItem[itemID] = callID
                callNames[callID] = callName
                sawToolCall = true
                produced.append(.init(type: "toolCallStarted", callID: callID, name: callName))
            case "response.function_call_arguments.delta":
                let itemID = object.object?["item_id"]?.string ?? ""
                let callID = object.object?["call_id"]?.string ?? callByItem[itemID] ?? itemID
                let delta = object.object?["delta"]?.string ?? ""
                produced.append(.init(type: "toolCallDelta", callID: callID, arguments: delta))
            case "response.function_call_arguments.done":
                let itemID = object.object?["item_id"]?.string ?? ""
                let callID = object.object?["call_id"]?.string ?? callByItem[itemID] ?? itemID
                let arguments = object.object?["arguments"]?.string ?? "{}"
                if completedCalls.insert(callID).inserted {
                    produced.append(.init(
                        type: "toolCallCompleted", callID: callID,
                        name: callNames[callID] ?? "", arguments: arguments
                    ))
                }
            case "response.output_item.done":
                guard let item = object.object?["item"]?.object, item["type"]?.string == "function_call" else { break }
                let callID = item["call_id"]?.string ?? ""
                // Fallback for a provider that only marks the item done. One completed event per call.
                if completedCalls.insert(callID).inserted {
                    produced.append(.init(
                        type: "toolCallCompleted", callID: callID,
                        name: callNames[callID] ?? item["name"]?.string ?? "",
                        arguments: item["arguments"]?.string ?? "{}"
                    ))
                }
            case "response.completed":
                let response = object.object?["response"]?.object
                if let usage = response?["usage"]?.object {
                    produced.append(.init(type: "usage", usage: ProviderWireUsage(
                        inputTokens: usage["input_tokens"]?.numberValue.map(Int.init),
                        outputTokens: usage["output_tokens"]?.numberValue.map(Int.init),
                        reasoningTokens: usage["output_tokens_details"]?.object?["reasoning_tokens"]?.numberValue.map(Int.init),
                        cacheReadTokens: usage["input_tokens_details"]?.object?["cached_tokens"]?.numberValue.map(Int.init),
                        cacheWriteTokens: nil
                    )))
                }
                produced.append(.init(type: "completed", stopReason: stopReason(response)))
            case "response.failed":
                let error = object.object?["response"]?.object?["error"]?.object
                produced.append(.init(
                    type: "failed",
                    failureKind: mapFailure(error?["code"]?.string ?? error?["type"]?.string),
                    message: error?["message"]?.string ?? "the provider reported a failed response"
                ))
            case "error":
                produced.append(.init(
                    type: "failed", failureKind: "streamProtocol",
                    message: object.object?["message"]?.string ?? "the provider sent an error event"
                ))
            default:
                break
            }

            if produced.contains(where: { $0.type == "completed" || $0.type == "failed" }) {
                emittedTerminal = true
            }
            emitted.append(contentsOf: produced)
            return produced
        }

        private func stopReason(_ response: [String: JSONValue]?) -> String {
            if response?["status"]?.string == "incomplete" {
                switch response?["incomplete_details"]?.object?["reason"]?.string {
                case "max_output_tokens": return "maxTokens"
                case "content_filter": return "contentFilter"
                default: return "unknown"
                }
            }
            if sawToolCall { return "toolCalls" }
            return "stop"
        }

        private func mapFailure(_ code: String?) -> String {
            switch code {
            case "rate_limit_exceeded", "rate_limit": return "rateLimited"
            case "context_length_exceeded", "context_length": return "contextExceeded"
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

enum StableDigest {
    /// FNV-1a 64-bit. Cassette matching needs a stable key, not a cryptographic one, and this keeps
    /// the plugin to Foundation only. It never runs over a secret: the credential is excluded first.
    static func hex(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
