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
        let pump = Pump(source: bytes, continuation: continuation!)
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
        messages.append(contentsOf: request.messages.map {
            Message(role: $0.role.rawValue, content: $0.content)
        })
        let body = ChatRequestBody(model: model, stream: true, messages: messages)
        return try JSONEncoder().encode(body)
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
        guard let data = trimmed.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(SSEChunk.self, from: data)
        else {
            throw CoreError(
                code: .modelStream,
                message: "SSE chunk JSON 解析失败: \(trimmed.prefix(200))"
            )
        }

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

        init(source: URLSession.AsyncBytes, continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation) {
            self.source = source
            self.continuation = continuation
        }

        func run() async {
            var decoder = SSEDecoder()
            var completed: ModelFinishReason?
            var sawDone = false
            continuation.yield(.started)

            do {
                outer: for try await byte in source {
                    for line in decoder.feed(Data([byte])) {
                        if try handle(line: line, into: &completed) {
                            sawDone = true
                            break outer
                        }
                    }
                }
                if !sawDone {
                    for line in decoder.flushPending() {
                        _ = try handle(line: line, into: &completed)
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

            // [DONE] 或 EOF：有 finish_reason 用之，否则宽容收尾。
            continuation.yield(.completed(completed ?? .unknown))
            continuation.finish()
        }

        /// 处理一行 SSE；返回 true 表示遇到 [DONE]，应停止读取。
        /// malformed JSON 抛错，由 run 统一转为 .failed 并终止。
        private func handle(line: String, into completed: inout ModelFinishReason?) throws -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(":") { return false }
            guard trimmed.hasPrefix("data:") else { return false } // event:/retry:/id: 忽略
            let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)

            if payload == "[DONE]" { return true }

            for event in try OpenAICompatibleProvider.events(forSSEPayload: String(payload)) {
                if case let .completed(reason) = event {
                    completed = reason
                } else {
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
            let content: String
        }

        let model: String
        let stream: Bool
        let messages: [Message]
    }

    typealias Message = ChatRequestBody.Message

    struct SSEChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
                // reasoning_content（DeepSeek 风格）与 reasoning（OpenRouter 风格）取其一。
                let reasoning: String?

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    content = try container.decodeIfPresent(String.self, forKey: .content)
                    reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
                        ?? container.decodeIfPresent(String.self, forKey: .reasoningContent)
                }

                enum CodingKeys: String, CodingKey {
                    case content
                    case reasoning
                    case reasoningContent = "reasoning_content"
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
}
