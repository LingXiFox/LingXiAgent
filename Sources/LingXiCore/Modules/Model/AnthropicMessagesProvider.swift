import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingXiProtocol

/// Anthropic Messages adapter. Native wire identities and DTOs remain local to this file.
public struct AnthropicMessagesProvider: ModelProvider {
    private let config: ProviderConfig
    private let session: URLSession

    public init(config: ProviderConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let urlRequest = try makeURLRequest(request)
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw CoreError(code: .provider, message: "Provider returned a non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAICompatibleProvider.httpError(status: http.statusCode, requestID: http.value(forHTTPHeaderField: "request-id"))
        }
        return AsyncThrowingStream { continuation in
            let pump = Task { await Pump(source: bytes, continuation: continuation).run() }
            continuation.onTermination = { @Sendable _ in
                pump.cancel()
                bytes.task.cancel()
            }
        }
    }

    public func makeURLRequest(_ request: ModelRequest) throws -> URLRequest {
        guard request.reasoning == nil else {
            throw CoreError(code: .provider, message: "Anthropic reasoning configuration is not implemented")
        }
        var result = URLRequest(url: config.anthropicMessagesURL)
        result.httpMethod = "POST"
        result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        result.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        switch config.authentication {
        case .none: break
        case let .bearer(secret): result.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        case let .header(name, value): result.setValue(value, forHTTPHeaderField: name)
        }
        result.httpBody = try Self.makeRequestBody(request, maxOutputTokens: config.maxOutputTokens ?? 4_096)
        return result
    }

    public static func makeRequestBody(_ request: ModelRequest, maxOutputTokens: Int = 4_096) throws -> Data {
        let messageSystem = request.messages.filter { $0.role == .system }.map(\.content).filter { !$0.isEmpty }
        let system = ([request.system].compactMap { $0 } + messageSystem).joined(separator: "\n\n")
        let messages = try request.messages.compactMap { message -> RequestBody.Message? in
            switch message.role {
            case .system:
                return nil
            case .user:
                return RequestBody.Message(role: "user", content: message.parts.compactMap { part in
                    if case let .text(text) = part { return .text(text) }
                    return nil
                })
            case .assistant:
                return RequestBody.Message(role: "assistant", content: try message.parts.map { part in
                    switch part {
                    case let .text(text): return .text(text)
                    case let .toolCall(call):
                        guard let data = call.arguments.data(using: .utf8),
                              let input = try? JSONDecoder().decode(JSONValue.self, from: data),
                              case .object = input
                        else { throw CoreError(code: .provider, message: "Anthropic tool input must be a JSON object") }
                        return .toolUse(id: call.callID.rawValue, name: call.toolID.rawValue, input: input)
                    case .toolResult:
                        throw CoreError(code: .provider, message: "Anthropic assistant message cannot contain tool results")
                    }
                })
            case .tool:
                return RequestBody.Message(role: "user", content: message.parts.compactMap { part in
                    guard case let .toolResult(result) = part else { return nil }
                    return .toolResult(id: result.callID.rawValue, content: result.content, isError: !result.success)
                })
            }
        }
        let tools = request.tools.isEmpty ? nil : request.tools.map(RequestBody.Tool.init)
        return try JSONEncoder().encode(RequestBody(
            model: request.model.rawValue,
            maxTokens: max(1, maxOutputTokens),
            stream: true,
            system: system.isEmpty ? nil : system,
            messages: messages,
            tools: tools
        ))
    }

    private final class Pump: Sendable {
        private let source: URLSession.AsyncBytes
        private let continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation

        init(source: URLSession.AsyncBytes, continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation) {
            self.source = source
            self.continuation = continuation
        }

        func run() async {
            var lines = SSEDecoder()
            var decoder = AnthropicSSEDecoder()
            var terminal = false
            var failed = false
            continuation.yield(.started)
            do {
                outer: for try await byte in source {
                    for line in lines.feed(Data([byte])) {
                        if try emit(line, decoder: &decoder, terminal: &terminal, failed: &failed) { break outer }
                    }
                }
                if !terminal {
                    for line in lines.flushPending() {
                        _ = try emit(line, decoder: &decoder, terminal: &terminal, failed: &failed)
                    }
                }
                if Task.isCancelled || failed { continuation.finish(); return }
                guard terminal else { throw CoreError(code: .modelStream, message: "Anthropic SSE ended unexpectedly") }
                continuation.finish()
            } catch let error as CoreError {
                if Task.isCancelled { continuation.finish(); return }
                continuation.yield(.failed(error))
                continuation.finish()
            } catch {
                if Task.isCancelled { continuation.finish(); return }
                continuation.yield(.failed(CoreError(code: .modelStream, message: "Anthropic SSE connection interrupted")))
                continuation.finish()
            }
        }

        private func emit(_ line: String, decoder: inout AnthropicSSEDecoder, terminal: inout Bool, failed: inout Bool) throws -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { return false }
            let payload = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { terminal = true; return true }
            if let data = payload.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let type = object["type"] as? String {
                terminal = terminal || type == "message_stop" || type == "error"
            }
            for event in try decoder.consume(payload) {
                if case .failed = event { failed = true }
                continuation.yield(event)
            }
            return terminal
        }
    }
}

public struct AnthropicSSEDecoder {
    private struct PartialTool {
        var id: String
        var name: String
        var arguments = ""
    }

    private var tools: [Int: PartialTool] = [:]

    public init() {}

    public mutating func consume(_ payload: String) throws -> [ModelEvent] {
        guard let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { throw CoreError(code: .modelStream, message: "Anthropic SSE JSON parsing failed") }

        switch type {
        case "message_start":
            let message = object["message"] as? [String: Any]
            return usage(message?["usage"] as? [String: Any]).map { [.usage($0)] } ?? []
        case "content_block_start":
            guard let index = object["index"] as? Int, let block = object["content_block"] as? [String: Any] else { return [] }
            switch block["type"] as? String {
            case "text": return (block["text"] as? String).flatMap { $0.isEmpty ? nil : [.textDelta($0)] } ?? []
            case "thinking": return (block["thinking"] as? String).flatMap { $0.isEmpty ? nil : [.reasoningDelta($0)] } ?? []
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else {
                    throw CoreError(code: .modelStream, message: "Anthropic tool use is missing identity")
                }
                tools[index] = PartialTool(id: id, name: name)
                return [.toolCallStarted(callID: ToolCallID(id), toolID: ToolID(name))]
            default: return []
            }
        case "content_block_delta":
            guard let index = object["index"] as? Int, let delta = object["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta": return (delta["text"] as? String).map { [.textDelta($0)] } ?? []
            case "thinking_delta": return (delta["thinking"] as? String).map { [.reasoningDelta($0)] } ?? []
            case "input_json_delta":
                guard var tool = tools[index], let fragment = delta["partial_json"] as? String else { return [] }
                tool.arguments += fragment
                tools[index] = tool
                return [.toolCallDelta(callID: ToolCallID(tool.id), arguments: fragment)]
            default: return []
            }
        case "content_block_stop":
            guard let index = object["index"] as? Int, let tool = tools.removeValue(forKey: index) else { return [] }
            guard let data = tool.arguments.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
            else { throw CoreError(code: .modelStream, message: "Anthropic tool input is not a JSON object") }
            return [.toolCallCompleted(ToolCall(callID: ToolCallID(tool.id), toolID: ToolID(tool.name), arguments: tool.arguments))]
        case "message_delta":
            var events: [ModelEvent] = []
            if let value = usage(object["usage"] as? [String: Any]) { events.append(.usage(value)) }
            let delta = object["delta"] as? [String: Any]
            if let reason = finishReason(delta?["stop_reason"] as? String) { events.append(.completed(reason)) }
            return events
        case "message_stop":
            return []
        case "error":
            return [.failed(CoreError(code: .modelStream, message: "Anthropic SSE returned an error"))]
        default:
            return []
        }
    }

    private func usage(_ raw: [String: Any]?) -> ModelUsage? {
        guard let raw else { return nil }
        return ModelUsage(
            inputTokens: raw["input_tokens"] as? Int,
            outputTokens: raw["output_tokens"] as? Int,
            reasoningTokens: nil,
            cacheReadTokens: raw["cache_read_input_tokens"] as? Int,
            cacheWriteTokens: raw["cache_creation_input_tokens"] as? Int
        )
    }

    private func finishReason(_ raw: String?) -> ModelFinishReason? {
        switch raw {
        case "end_turn", "stop_sequence": .stop
        case "max_tokens": .maxTokens
        case "tool_use": .toolCalls
        case "refusal": .contentFilter
        case nil, "": nil
        default: .unknown
        }
    }
}

private struct RequestBody: Encodable {
    struct Message: Encodable { let role: String; let content: [Content] }
    struct Tool: Encodable {
        let name: String
        let description: String
        let inputSchema: JSONValue

        init(_ definition: ToolDefinition) {
            name = definition.name
            description = definition.description
            inputSchema = definition.rawInputSchema ?? .object([
                "type": .string("object"),
                "properties": .object(definition.inputSchema.properties.mapValues { .object(["type": .string($0.type.rawValue), "description": .string($0.description)]) }),
                "required": .array(definition.inputSchema.required.map(JSONValue.string)),
                "additionalProperties": .bool(false),
            ])
        }

        enum CodingKeys: String, CodingKey { case name, description; case inputSchema = "input_schema" }
    }
    enum Content: Encodable {
        case text(String)
        case toolUse(id: String, name: String, input: JSONValue)
        case toolResult(id: String, content: String, isError: Bool)

        enum Keys: String, CodingKey { case type, text, id, name, input, toolUseID = "tool_use_id", content, isError = "is_error" }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: Keys.self)
            switch self {
            case let .text(text):
                try values.encode("text", forKey: .type); try values.encode(text, forKey: .text)
            case let .toolUse(id, name, input):
                try values.encode("tool_use", forKey: .type); try values.encode(id, forKey: .id); try values.encode(name, forKey: .name); try values.encode(input, forKey: .input)
            case let .toolResult(id, content, isError):
                try values.encode("tool_result", forKey: .type); try values.encode(id, forKey: .toolUseID); try values.encode(content, forKey: .content); try values.encode(isError, forKey: .isError)
            }
        }
    }

    let model: String
    let maxTokens: Int
    let stream: Bool
    let system: String?
    let messages: [Message]
    let tools: [Tool]?

    enum CodingKeys: String, CodingKey { case model, stream, system, messages, tools; case maxTokens = "max_tokens" }
}
