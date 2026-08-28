import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

/// Adapter 边界测试：
/// LingXi Domain → OpenAI-compatible JSON，以及 SSE payload → LingXi ModelEvent。
struct OpenAIAdapterTests {
    // MARK: - Request 转换

    @Test func requestConversionWithSystem() throws {
        let request = ModelRequest(
            model: ModelID("m-1"),
            system: "be nice",
            messages: [ModelMessage(role: .user, content: "hello")]
        )
        let data = try OpenAICompatibleProvider.makeRequestBody(request, model: "m-1")
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["model"] as? String == "m-1")
        #expect(json["stream"] as? Bool == true)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "be nice")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "hello")
    }

    @Test func requestConversionWithoutSystem() throws {
        let request = ModelRequest(
            model: ModelID("m-1"),
            messages: [ModelMessage(role: .user, content: "hello")]
        )
        let data = try OpenAICompatibleProvider.makeRequestBody(request, model: "m-1")
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
    }

    // MARK: - URL 拼接

    @Test func chatCompletionsURL() throws {
        func url(_ base: String) throws -> URL {
            let config = ProviderConfig(
                baseURL: try #require(URL(string: base)),
                apiKey: nil,
                model: "m"
            )
            return config.chatCompletionsURL
        }
        #expect(try url("https://api.example.com/v1").absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(try url("https://api.example.com/v1/").absoluteString == "https://api.example.com/v1/chat/completions")
        // 已包含最终兼容层级时不再追加，避免 /v1/v1。
        #expect(try url("https://api.example.com/v1/chat/completions").absoluteString == "https://api.example.com/v1/chat/completions")
    }

    // MARK: - SSE payload → ModelEvent

    @Test func textDeltaOrder() throws {
        let payload = #"{"choices":[{"delta":{"content":"你好"}}]}"#
        let events = try OpenAICompatibleProvider.events(forSSEPayload: payload)
        #expect(events == [.textDelta("你好")])
    }

    @Test func reasoningDelta() throws {
        let deepseek = #"{"choices":[{"delta":{"reasoning_content":"think"}}]}"#
        #expect(try OpenAICompatibleProvider.events(forSSEPayload: deepseek) == [.reasoningDelta("think")])

        let openrouter = #"{"choices":[{"delta":{"reasoning":"think"}}]}"#
        #expect(try OpenAICompatibleProvider.events(forSSEPayload: openrouter) == [.reasoningDelta("think")])
    }

    @Test func usageParsing() throws {
        let payload = #"{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":34,"completion_tokens_details":{"reasoning_tokens":7},"prompt_tokens_details":{"cached_tokens":3}}}"#
        let events = try OpenAICompatibleProvider.events(forSSEPayload: payload)
        #expect(events == [.usage(ModelUsage(
            inputTokens: 12,
            outputTokens: 34,
            reasoningTokens: 7,
            cacheReadTokens: 3,
            cacheWriteTokens: nil
        ))])
    }

    @Test func finishReasonMapping() throws {
        #expect(OpenAICompatibleProvider.finishReason(fromOpenAI: "stop") == .stop)
        #expect(OpenAICompatibleProvider.finishReason(fromOpenAI: "length") == .maxTokens)
        #expect(OpenAICompatibleProvider.finishReason(fromOpenAI: "content_filter") == .contentFilter)
        #expect(OpenAICompatibleProvider.finishReason(fromOpenAI: nil) == nil)
        #expect(OpenAICompatibleProvider.finishReason(fromOpenAI: "weird") == .unknown)

        let payload = #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
        let events = try OpenAICompatibleProvider.events(forSSEPayload: payload)
        #expect(events == [.completed(.stop)])
    }

    @Test func emptyAndNonDataLines() throws {
        #expect(try OpenAICompatibleProvider.events(forSSEPayload: "") == [])
        // 非法结构但能定位的错误应抛错而不是 crash。
        #expect(throws: CoreError.self) {
            try OpenAICompatibleProvider.events(forSSEPayload: "{broken json")
        }
    }

    @Test func malformedSSEIsModelStreamError() {
        do {
            _ = try OpenAICompatibleProvider.events(forSSEPayload: "not-json-at-all")
            Issue.record("malformed SSE 应抛错")
        } catch let error as CoreError {
            #expect(error.code == .modelStream)
        } catch {
            Issue.record("错误类型应为 CoreError: \(error)")
        }
    }
}
