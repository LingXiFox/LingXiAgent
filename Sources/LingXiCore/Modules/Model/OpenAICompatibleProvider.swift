import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingXiProtocol

/// OpenAI-compatible Provider Adapter。
/// 本类型是 Core 中唯一允许出现 OpenAI Chat Completions JSON 结构的地方：
/// choices / delta / finish_reason / prompt_tokens 等只存在于下方私有 DTO，
/// 出口一律转换为 LingXi ModelEvent。
public struct OpenAICompatibleProvider: ModelProvider {
    private let config: ProviderConfig
    private let session: URLSession

    public init(config: ProviderConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - ModelProvider

    public func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let urlRequest = try makeURLRequest(request)

        // 连接阶段：失败直接 throw（Provider Error），由调用方转换为控制面结果。
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw CoreError(code: .provider, message: "Provider 返回非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            // 读错误 body（截断），转换为 LingXi ProviderError；不输出任何凭据。
            let body = (try? await Self.collectText(bytes)) ?? ""
            throw Self.httpError(status: http.statusCode, body: body)
        }

        // 数据面 pump：连接已建立，事件从独立任务流出。
        var continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation!
        let events = AsyncThrowingStream { continuation = $0 }
        let pump = Pump(source: bytes, continuation: continuation!, debugStep: request.debugStep)
        Task { await pump.run() }
        return events
    }

    // MARK: - Request 转换（Domain → OpenAI-compatible JSON）

    public func makeURLRequest(_ request: ModelRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: config.chatCompletionsURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = config.apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try Self.makeRequestBody(request, model: config.model)
        return urlRequest
    }

    /// 可测试：Domain 请求 → wire JSON。
    public static func makeRequestBody(_ request: ModelRequest, model: String) throws -> Data {
        var messages: [ChatRequestBody.Message] = []
        if let system = request.system, !system.isEmpty {
            messages.append(Message(role: "system", content: system))
        }
        messages.append(contentsOf: request.messages.flatMap(providerMessages))
        let body = ChatRequestBody(
            model: model,
            stream: true,
            messages: messages,
            tools: request.tools.isEmpty ? nil : request.tools.map(ProviderTool.init)
        )
        return try JSONEncoder().encode(body)
    }

    private static func providerMessages(_ message: ModelMessage) -> [ChatRequestBody.Message] {
        let calls = message.parts.compactMap { part -> ToolCall? in
            guard case let .toolCall(call) = part else { return nil }
            return call
        }
        let results = message.parts.compactMap { part -> ToolResult? in
            guard case let .toolResult(result) = part else { return nil }
            return result
        }
        switch message.role {
        case .tool:
            return results.map { result in
                Message(role: "tool", content: resultContent(result), toolCallID: result.callID.rawValue)
            }
        case .assistant:
            return [Message(
                role: "assistant",
                content: message.content.isEmpty && !calls.isEmpty ? nil : message.content,
                toolCalls: calls.isEmpty ? nil : calls.map(ProviderToolCall.init)
            )]
        case .system, .user:
            return [Message(role: message.role.rawValue, content: message.content)]
        }
    }

    private static func resultContent(_ result: ToolResult) -> String {
        guard !result.success else { return result.content }
        let error = result.error ?? ToolError(code: "toolExecutionFailed", message: "Tool 执行失败")
        let data = try? JSONEncoder().encode(error)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? error.message
    }

    // MARK: - 错误转换

    public static func httpError(status: Int, body: String) -> CoreError {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = trimmed.isEmpty ? "<无响应体>" : String(trimmed.prefix(2000))
        return CoreError(
            code: .provider,
            message: "Provider HTTP \(status): \(preview)"
        )
    }

    /// 可测试：SSE data 行 payload → 0..n 个 ModelEvent。
    /// malformed JSON 抛出明确错误，绝不 crash Core。
    public static func events(forSSEPayload payload: String) throws -> [ModelEvent] {
        let trimmed = payload.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return events(from: try decodeSSEChunk(trimmed))
    }

    private static func decodeSSEChunk(_ payload: String) throws -> SSEChunk {
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(SSEChunk.self, from: data)
        else {
            throw CoreError(code: .modelStream, message: "SSE chunk JSON 解析失败: \(payload.prefix(200))")
        }
        return chunk
    }

    private static func events(from chunk: SSEChunk) -> [ModelEvent] {
        var events: [ModelEvent] = []
        if let usage = chunk.usage.map(Self.usage(from:)) {
            events.append(.usage(usage))
        }
        if let choice = chunk.choices?.first {
            if let text = choice.delta?.content, !text.isEmpty {
                events.append(.textDelta(text))
            }
            if let reasoning = choice.delta?.reasoning, !reasoning.isEmpty {
                events.append(.reasoningDelta(reasoning))
            }
            if let reason = choice.finishReason {
                events.append(.completed(reason))
            }
        }
        return events
    }

    public static func finishReason(fromOpenAI raw: String?) -> ModelFinishReason? {
        switch raw {
        case "stop": .stop
        case "length": .maxTokens
        case "content_filter": .contentFilter
        case "tool_calls": .toolCalls
        case nil, .some(""): nil
        default: .unknown
        }
    }

    private static func usage(from raw: SSEUsage) -> ModelUsage {
        ModelUsage(
            inputTokens: raw.promptTokens,
            outputTokens: raw.completionTokens,
            reasoningTokens: raw.completionTokensDetails?.reasoningTokens,
            cacheReadTokens: raw.promptTokensDetails?.cachedTokens,
            cacheWriteTokens: nil
        )
    }

    static func collectText(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        var count = 0
        for try await byte in bytes {
            data.append(byte)
            count += 1
            if count > 64 * 1024 { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Pump（数据面）

    /// 消费网络字节：bytes → SSE buffer → 行 → JSON → ModelEvent。
    private final class Pump: Sendable {
        private let source: URLSession.AsyncBytes
        private let continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation
        private let debugStep: Int?

        init(source: URLSession.AsyncBytes, continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation, debugStep: Int?) {
            self.source = source
            self.continuation = continuation
            self.debugStep = debugStep
        }

        func run() async {
            var decoder = SSEDecoder()
            var completed: ModelFinishReason?
            var toolCalls = ToolCallBuffer(debugStep: debugStep)
            var sawDone = false
            continuation.yield(.started)

            do {
                outer: for try await byte in source {
                    for line in decoder.feed(Data([byte])) {
                        if try handle(line: line, into: &completed, toolCalls: &toolCalls) {
                            sawDone = true
                            break outer
                        }
                    }
                }
                if !sawDone {
                    for line in decoder.flushPending() {
                        _ = try handle(line: line, into: &completed, toolCalls: &toolCalls)
                    }
                }
            } catch let error as CoreError {
                continuation.yield(.failed(error))
                continuation.finish()
                return
            } catch {
                continuation.yield(.failed(CoreError(code: .modelStream, message: "Provider 连接中断: \(error)")))
                continuation.finish()
                return
            }

            do {
                for event in try toolCalls.complete() {
                    continuation.yield(event)
                }
            } catch let error as CoreError {
                continuation.yield(.failed(error))
                continuation.finish()
                return
            } catch {
                continuation.yield(.failed(CoreError(code: .modelStream, message: String(describing: error))))
                continuation.finish()
                return
            }
            // [DONE] 或 EOF：有 finish_reason 用之，否则宽容收尾。
            continuation.yield(.completed(completed ?? .unknown))
            continuation.finish()
        }

        /// 处理一行 SSE；返回 true 表示遇到 [DONE]，应停止读取。
        /// malformed JSON 抛错，由 run 统一转为 .failed 并终止。
        private func handle(
            line: String,
            into completed: inout ModelFinishReason?,
            toolCalls: inout ToolCallBuffer
        ) throws -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(":") { return false }
            guard trimmed.hasPrefix("data:") else { return false } // event:/retry:/id: 忽略
            let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)

            if payload == "[DONE]" { return true }

            let chunk = try OpenAICompatibleProvider.decodeSSEChunk(String(payload))
            for event in OpenAICompatibleProvider.events(from: chunk) {
                if case let .completed(reason) = event {
                    completed = reason
                } else {
                    continuation.yield(event)
                }
            }
            if let calls = chunk.choices?.first?.delta?.toolCalls {
                for event in try toolCalls.consume(calls) {
                    continuation.yield(event)
                }
            }
            return false
        }
    }
}

private extension OpenAICompatibleProvider {
    struct ChatRequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String?
            let toolCalls: [ProviderToolCall]?
            let toolCallID: String?

            init(role: String, content: String?, toolCalls: [ProviderToolCall]? = nil, toolCallID: String? = nil) {
                self.role = role
                self.content = content
                self.toolCalls = toolCalls
                self.toolCallID = toolCallID
            }

            enum CodingKeys: String, CodingKey {
                case role, content
                case toolCalls = "tool_calls"
                case toolCallID = "tool_call_id"
            }
        }

        let model: String
        let stream: Bool
        let messages: [Message]
        let tools: [ProviderTool]?
    }

    typealias Message = ChatRequestBody.Message

    struct ProviderTool: Encodable {
        struct Function: Encodable {
            struct Parameters: Encodable {
                struct Property: Encodable {
                    let type: String
                    let description: String
                }

                let type = "object"
                let properties: [String: Property]
                let required: [String]
                let additionalProperties = false
            }

            let name: String
            let description: String
            let parameters: Parameters
        }

        let type = "function"
        let function: Function

        init(_ definition: ToolDefinition) {
            function = Function(
                name: definition.name,
                description: definition.description,
                parameters: Function.Parameters(
                    properties: definition.inputSchema.properties.mapValues {
                        Function.Parameters.Property(type: $0.type.rawValue, description: $0.description)
                    },
                    required: definition.inputSchema.required
                )
            )
        }
    }

    struct ProviderToolCall: Encodable {
        struct Function: Encodable {
            let name: String
            let arguments: String
        }

        let id: String
        let type = "function"
        let function: Function

        init(_ call: ToolCall) {
            id = call.callID.rawValue
            function = Function(name: call.toolID.rawValue, arguments: call.arguments)
        }
    }

    struct SSEChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
                // reasoning_content（DeepSeek 风格）与 reasoning（OpenRouter 风格）取其一。
                let reasoning: String?
                let toolCalls: [SSEToolCall]?

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    content = try container.decodeIfPresent(String.self, forKey: .content)
                    reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
                        ?? container.decodeIfPresent(String.self, forKey: .reasoningContent)
                    toolCalls = try container.decodeIfPresent([SSEToolCall].self, forKey: .toolCalls)
                }

                enum CodingKeys: String, CodingKey {
                    case content
                    case reasoning
                    case reasoningContent = "reasoning_content"
                    case toolCalls = "tool_calls"
                }
            }

            let delta: Delta?
            let finishReason: ModelFinishReason?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                delta = try container.decodeIfPresent(Delta.self, forKey: .delta)
                finishReason = try OpenAICompatibleProvider.finishReason(
                    fromOpenAI: container.decodeIfPresent(String.self, forKey: .finishReason)
                )
            }

            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }
        }

        let choices: [Choice]?
        let usage: SSEUsage?
    }

    struct SSEUsage: Decodable {
        struct CompletionDetails: Decodable {
            let reasoningTokens: Int?
            enum CodingKeys: String, CodingKey {
                case reasoningTokens = "reasoning_tokens"
            }
        }

        struct PromptDetails: Decodable {
            let cachedTokens: Int?
            enum CodingKeys: String, CodingKey {
                case cachedTokens = "cached_tokens"
            }
        }

        let promptTokens: Int?
        let completionTokens: Int?
        let completionTokensDetails: CompletionDetails?
        let promptTokensDetails: PromptDetails?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case completionTokensDetails = "completion_tokens_details"
            case promptTokensDetails = "prompt_tokens_details"
        }
    }

    struct SSEToolCall: Decodable {
        struct Function: Decodable {
            let name: String?
            let arguments: String?
        }

        let index: Int
        let id: String?
        let function: Function?
    }

    struct ToolCallBuffer {
        private struct Partial {
            var id: String?
            var name: String?
            var arguments = ""
            var started = false
            var emittedArgumentCount = 0
        }

        private var calls: [Int: Partial] = [:]
        private let debugStep: Int?

        init(debugStep: Int?) {
            self.debugStep = debugStep
        }

        mutating func consume(_ deltas: [SSEToolCall]) throws -> [ModelEvent] {
            var events: [ModelEvent] = []
            for delta in deltas {
                var partial = calls[delta.index] ?? Partial()
                partial.id = delta.id ?? partial.id
                partial.name = delta.function?.name ?? partial.name
                if let arguments = delta.function?.arguments, !arguments.isEmpty {
                    partial.arguments += arguments
                }
                if let id = partial.id, let name = partial.name, !partial.started {
                    partial.started = true
                    events.append(.toolCallStarted(callID: ToolCallID(id), toolID: ToolID(name)))
                }
                if partial.started, let id = partial.id, partial.emittedArgumentCount < partial.arguments.count {
                    let arguments = String(partial.arguments.dropFirst(partial.emittedArgumentCount))
                    partial.emittedArgumentCount = partial.arguments.count
                    events.append(.toolCallDelta(callID: ToolCallID(id), arguments: arguments))
                }
                calls[delta.index] = partial
            }
            return events
        }

        mutating func complete() throws -> [ModelEvent] {
            defer { calls.removeAll() }
            return try calls.keys.sorted().map { index in
                guard let call = calls[index], let id = call.id, let name = call.name, call.started else {
                    throw CoreError(code: .modelStream, message: "Tool Call 信息不完整")
                }
                guard let data = call.arguments.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
                else {
                    throw CoreError(code: .modelStream, message: "Tool Call 参数不是 JSON object: \(name)")
                }
                if ProcessInfo.processInfo.environment["LINGXI_PERF_DEBUG"] == "1" {
                    let hash = call.arguments.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
                    FileHandle.standardError.write(Data("[tool-debug] step=\(debugStep ?? 0) index=\(index) id=\(id) name=\(name) argsHash=\(String(hash, radix: 16))\n".utf8))
                }
                return .toolCallCompleted(ToolCall(callID: ToolCallID(id), toolID: ToolID(name), arguments: call.arguments))
            }
        }
    }
}
