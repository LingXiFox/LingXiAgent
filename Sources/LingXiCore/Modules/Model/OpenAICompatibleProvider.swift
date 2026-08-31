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

    // MARK: - ModelProvider

    public func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let prior = try await provenance.resolveContinuation(for: request.continuationOf, wire: .chatCompletions)
        let urlRequest = try makeURLRequest(request, continuation: prior)
        Self.log("request step=\(request.debugStep ?? 0) bytes=\(urlRequest.httpBody?.count ?? 0)", enabled: config.diagnosticsEnabled)

        // 连接阶段：失败直接 throw（Provider Error），由调用方转换为控制面结果。
        let response = try await transport.send(urlRequest, context: ProviderHTTPRequestContext(wireProtocol: .chatCompletions, model: request.model.rawValue, requestID: request.requestID, executionID: request.executionID, step: request.debugStep ?? 0))
        let requestID = response.header("x-request-id")
            ?? response.header("openai-request-id")
            ?? response.header("cf-ray")
        Self.log("http step=\(request.debugStep ?? 0) status=\(response.statusCode)", enabled: config.diagnosticsEnabled)
        guard (200..<300).contains(response.statusCode) else {
            _ = try? await Self.collectText(response.body)
            throw Self.httpError(status: response.statusCode, requestID: requestID)
        }

        // 数据面 pump：连接已建立，事件从独立任务流出。
        let events = AsyncThrowingStream<ModelEvent, Error> { continuation in
            let pump = Task {
                await Pump(
                    source: response.body,
                    continuation: continuation,
                    request: request,
                    prior: prior,
                    provenance: provenance,
                    debugStep: request.debugStep,
                    diagnosticsEnabled: config.diagnosticsEnabled,
                    performanceDiagnosticsEnabled: config.performanceDiagnosticsEnabled
                ).run()
            }
            continuation.onTermination = { @Sendable _ in
                pump.cancel()
            }
        }
        return events
    }

    // MARK: - Request 转换（Domain → OpenAI-compatible JSON）

    public func makeURLRequest(_ request: ModelRequest) throws -> URLRequest {
        try makeURLRequest(request, continuation: nil)
    }

    private func makeURLRequest(_ request: ModelRequest, continuation: ProviderContinuation?) throws -> URLRequest {
        var urlRequest = URLRequest(url: config.chatCompletionsURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch config.authentication {
        case .none: break
        case let .bearer(secret): urlRequest.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        case let .header(name, value): urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        for (name, value) in config.requiredHeaders where urlRequest.value(forHTTPHeaderField: name) == nil {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = try Self.makeRequestBody(request, continuation: continuation)
        return urlRequest
    }

    /// 可测试：Domain 请求 → wire JSON。
    public static func makeRequestBody(_ request: ModelRequest) throws -> Data {
        try makeRequestBody(request, continuation: nil)
    }

    private static func makeRequestBody(_ request: ModelRequest, continuation: ProviderContinuation?) throws -> Data {
        var messages: [ChatRequestBody.Message] = []
        if let system = request.system, !system.isEmpty {
            messages.append(Message(role: "system", content: system))
        }
        messages.append(contentsOf: request.messages.flatMap { providerMessages($0, continuation: continuation) })
        let body = ChatRequestBody(
            model: request.model.rawValue,
            stream: true,
            messages: messages,
            tools: request.tools.isEmpty ? nil : request.tools.map(ProviderTool.init)
        )
        return try JSONEncoder().encode(body)
    }

    private static func providerMessages(_ message: ModelMessage, continuation: ProviderContinuation?) -> [ChatRequestBody.Message] {
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
                Message(role: "tool", content: resultContent(result), toolCallID: continuation?.externalCallID(for: result.callID) ?? result.callID.rawValue)
            }
        case .assistant:
            return [Message(
                role: "assistant",
                content: message.content.isEmpty && !calls.isEmpty ? nil : message.content,
                toolCalls: calls.isEmpty ? nil : calls.map { ProviderToolCall(id: continuation?.externalCallID(for: $0.callID) ?? $0.callID.rawValue, function: ProviderToolCall.Function(name: $0.toolID.rawValue, arguments: $0.arguments)) }
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

    public static func httpError(status: Int, requestID: String? = nil) -> CoreError {
        let safeRequestID = requestID.map { String($0.prefix(128)) }.flatMap { value in
            value.isEmpty || !value.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) ? nil : value
        }
        let suffix = safeRequestID.map { " requestID=\($0)" } ?? ""
        return CoreError(code: .provider, message: "Provider HTTP 请求失败: status=\(status)\(suffix)")
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
            throw CoreError(code: .modelStream, message: "SSE chunk JSON 解析失败")
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

    static func collectText(_ stream: AsyncThrowingStream<Data, Error>) async throws -> String {
        var data = Data()
        var count = 0
        for try await chunk in stream {
            let remaining = 64 * 1024 - count
            guard remaining > 0 else { break }
            data.append(chunk.prefix(remaining))
            count += min(chunk.count, remaining)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func log(_ message: String, enabled: Bool) {
        guard enabled else { return }
        FileHandle.standardError.write(Data(("[chat-diagnostic] \(message)\n").utf8))
    }

    // MARK: - Pump（数据面）

    /// 消费网络字节：bytes → SSE buffer → 行 → JSON → ModelEvent。
    private final class Pump: Sendable {
        private let source: AsyncThrowingStream<Data, Error>
        private let continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation
        private let request: ModelRequest
        private let prior: ProviderContinuation?
        private let provenance: ProviderProvenanceStore
        private let debugStep: Int?
        private let diagnosticsEnabled: Bool
        private let performanceDiagnosticsEnabled: Bool

        init(source: AsyncThrowingStream<Data, Error>, continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation, request: ModelRequest, prior: ProviderContinuation?, provenance: ProviderProvenanceStore, debugStep: Int?, diagnosticsEnabled: Bool, performanceDiagnosticsEnabled: Bool) {
            self.source = source
            self.continuation = continuation
            self.request = request
            self.prior = prior
            self.provenance = provenance
            self.debugStep = debugStep
            self.diagnosticsEnabled = diagnosticsEnabled
            self.performanceDiagnosticsEnabled = performanceDiagnosticsEnabled
        }

        func run() async {
            var decoder = SSEDecoder()
            var completed: ModelFinishReason?
            var toolCalls = ToolCallBuffer(requestID: request.requestID, debugStep: debugStep, diagnosticsEnabled: performanceDiagnosticsEnabled)
            var sawDone = false
            var textChunks = 0
            var reasoningChunks = 0
            var toolChunks = 0
            continuation.yield(.started)

            do {
                outer: for try await chunk in source {
                    for line in decoder.feed(chunk) {
                        if try handle(line: line, into: &completed, toolCalls: &toolCalls, textChunks: &textChunks, reasoningChunks: &reasoningChunks, toolChunks: &toolChunks) {
                            sawDone = true
                            break outer
                        }
                    }
                }
                if !sawDone {
                    for line in decoder.flushPending() {
                        _ = try handle(line: line, into: &completed, toolCalls: &toolCalls, textChunks: &textChunks, reasoningChunks: &reasoningChunks, toolChunks: &toolChunks)
                    }
                }
            } catch let error as CoreError {
                if Task.isCancelled { continuation.finish(); return }
                continuation.yield(.failed(error))
                continuation.finish()
                return
            } catch {
                if Task.isCancelled { continuation.finish(); return }
                continuation.yield(.failed(CoreError(code: .modelStream, message: "Provider 流连接中断")))
                continuation.finish()
                return
            }

            if Task.isCancelled { continuation.finish(); return }
            guard sawDone || completed != nil else {
                continuation.yield(.failed(CoreError(code: .modelStream, message: "Provider SSE 意外结束")))
                continuation.finish()
                return
            }

            do {
                for event in try toolCalls.complete() {
                    continuation.yield(event)
                }
                let combinedReferences = (prior?.references ?? []).filter { priorRef in !toolCalls.references.contains { $0.domainCallID == priorRef.domainCallID } } + toolCalls.references
                if !combinedReferences.isEmpty {
                    try await provenance.record(ProviderContinuation(requestID: request.requestID, executionID: request.executionID, wire: .chatCompletions, references: combinedReferences))
                }
            } catch let error as CoreError {
                continuation.yield(.failed(error))
                continuation.finish()
                return
            } catch {
                continuation.yield(.failed(CoreError(code: .modelStream, message: "Tool Call 聚合失败")))
                continuation.finish()
                return
            }
            // [DONE] 或 EOF：有 finish_reason 用之，否则宽容收尾。
            OpenAICompatibleProvider.log("stream step=\(debugStep ?? 0) textChunks=\(textChunks) reasoningChunks=\(reasoningChunks) toolChunks=\(toolChunks) finish=\(String(describing: completed))", enabled: diagnosticsEnabled)
            continuation.yield(.completed(completed ?? .unknown))
            continuation.finish()
        }

        /// 处理一行 SSE；返回 true 表示遇到 [DONE]，应停止读取。
        /// malformed JSON 抛错，由 run 统一转为 .failed 并终止。
        private func handle(
            line: String,
            into completed: inout ModelFinishReason?,
            toolCalls: inout ToolCallBuffer,
            textChunks: inout Int,
            reasoningChunks: inout Int,
            toolChunks: inout Int
        ) throws -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(":") { return false }
            guard trimmed.hasPrefix("data:") else { return false } // event:/retry:/id: 忽略
            let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)

            if payload == "[DONE]" { return true }

            let chunk = try OpenAICompatibleProvider.decodeSSEChunk(String(payload))
            if let delta = chunk.choices?.first?.delta {
                if !(delta.content ?? "").isEmpty { textChunks += 1 }
                if !(delta.reasoning ?? "").isEmpty { reasoningChunks += 1 }
                toolChunks += delta.toolCalls?.count ?? 0
            }
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
            let name: String
            let description: String
            let parameters: JSONValue
        }

        let type = "function"
        let function: Function

        init(_ definition: ToolDefinition) {
            function = Function(
                name: definition.name,
                description: definition.description,
                parameters: definition.rawInputSchema ?? .object([
                    "type": .string("object"),
                    "properties": .object(definition.inputSchema.properties.mapValues { property in
                        var value: [String: JSONValue] = ["type": .string(property.type.rawValue), "description": .string(property.description)]
                        if let enumValues = property.enumValues { value["enum"] = .array(enumValues.map(JSONValue.string)) }
                        if let minimum = property.minimum { value["minimum"] = .number(minimum) }
                        if let maximum = property.maximum { value["maximum"] = .number(maximum) }
                        return .object(value)
                    }),
                    "required": .array(definition.inputSchema.required.map(JSONValue.string)),
                    "additionalProperties": .bool(false),
                ])
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

        init(id: String, function: Function) {
            self.id = id
            self.function = function
        }

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
        private var domainIDs: [Int: ToolCallID] = [:]
        private let requestID: ModelRequestID
        private let debugStep: Int?
        private let diagnosticsEnabled: Bool
        private(set) var references: [ProviderToolCallReference] = []

        init(requestID: ModelRequestID, debugStep: Int?, diagnosticsEnabled: Bool) {
            self.requestID = requestID
            self.debugStep = debugStep
            self.diagnosticsEnabled = diagnosticsEnabled
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
                    let domainID = ToolCallID("lingxi:\(requestID.rawValue):\(delta.index)")
                    domainIDs[delta.index] = domainID
                    references.append(ProviderToolCallReference(wire: .chatCompletions, domainCallID: domainID, externalCallID: id))
                    partial.started = true
                    events.append(.toolCallStarted(callID: domainID, toolID: ToolID(name)))
                }
                if partial.started, let domainID = domainIDs[delta.index], partial.emittedArgumentCount < partial.arguments.count {
                    let arguments = String(partial.arguments.dropFirst(partial.emittedArgumentCount))
                    partial.emittedArgumentCount = partial.arguments.count
                    events.append(.toolCallDelta(callID: domainID, arguments: arguments))
                }
                calls[delta.index] = partial
            }
            return events
        }

        mutating func complete() throws -> [ModelEvent] {
            defer { calls.removeAll() }
            return try calls.keys.sorted().map { index in
                guard let call = calls[index], let domainID = domainIDs[index], let name = call.name, call.started else {
                    throw CoreError(code: .modelStream, message: "Tool Call 信息不完整")
                }
                guard let data = call.arguments.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
                else {
                    throw CoreError(code: .modelStream, message: "Tool Call 参数不是 JSON object")
                }
                if diagnosticsEnabled {
                    let hash = call.arguments.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
                    FileHandle.standardError.write(Data("[tool-debug] step=\(debugStep ?? 0) index=\(index) argsHash=\(String(hash, radix: 16))\n".utf8))
                }
                return .toolCallCompleted(ToolCall(callID: domainID, toolID: ToolID(name), arguments: call.arguments))
            }
        }
    }
}
