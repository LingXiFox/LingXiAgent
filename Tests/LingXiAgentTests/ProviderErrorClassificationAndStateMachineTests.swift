import Foundation
import Testing
@testable import LingXiProtocol
@testable import LingXiCore
@testable import LingXiApplication
@testable import LingXiClient

@Suite("Provider Error Classification & State Machine Tests")
struct ProviderErrorClassificationAndStateMachineTests {

    // MARK: - 1. HTTP 状态码与分类映射测试

    @Test("HTTP 400 context_length_exceeded classifies as contextExceeded and non-retryable")
    func testContextLengthExceeded() {
        let body = "{\"error\":{\"message\":\"This model's maximum context length is 128000 tokens. However, your messages resulted in 130000 tokens.\",\"type\":\"context_length_exceeded\",\"code\":\"context_length_exceeded\"}}"
        let error = ProviderErrorClassifier.classify(statusCode: 400, body: body)
        #expect(error.category == .contextExceeded)
        #expect(error.category.isRetryable == false)
        #expect(error.statusCode == 400)
        #expect(error.userFacingSummary.contains("模型上下文长度超限"))
        #expect(error.userFacingSummary.contains("/compact"))
    }

    @Test("HTTP 401 classifies as authFailure and non-retryable")
    func testAuthFailure() {
        let body = "{\"error\":{\"message\":\"Incorrect API key provided\",\"type\":\"invalid_request_error\",\"code\":\"invalid_api_key\"}}"
        let error = ProviderErrorClassifier.classify(statusCode: 401, body: body)
        #expect(error.category == .authFailure)
        #expect(error.category.isRetryable == false)
        #expect(error.statusCode == 401)
        #expect(error.userFacingSummary.contains("API Key / Access Token 无效或已过期"))
        #expect(error.userFacingSummary.contains("检查提供商配置"))
    }

    @Test("HTTP 402 classifies as quotaExhausted and non-retryable")
    func testQuotaExhausted() {
        let body = "{\"error\":{\"message\":\"You exceeded your current quota, please check your plan and billing details.\",\"type\":\"insufficient_quota\",\"code\":\"insufficient_quota\"}}"
        let error = ProviderErrorClassifier.classify(statusCode: 402, body: body)
        #expect(error.category == .quotaExhausted)
        #expect(error.category.isRetryable == false)
        #expect(error.statusCode == 402)
        #expect(error.userFacingSummary.contains("余额不足或额度耗尽"))
    }

    @Test("HTTP 403 classifies as accessForbidden and non-retryable")
    func testAccessForbidden() {
        let error = ProviderErrorClassifier.classify(statusCode: 403, body: "{\"error\":{\"message\":\"Country, region, or territory not supported\"}}")
        #expect(error.category == .accessForbidden)
        #expect(error.category.isRetryable == false)
        #expect(error.userFacingSummary.contains("访问被拒绝 (403)"))
    }

    @Test("HTTP 404 classifies as modelNotFound and non-retryable")
    func testModelNotFound() {
        let body = "{\"error\":{\"message\":\"The model `gpt-fake` does not exist\",\"type\":\"invalid_request_error\",\"code\":\"model_not_found\"}}"
        let error = ProviderErrorClassifier.classify(statusCode: 404, body: body)
        #expect(error.category == .modelNotFound)
        #expect(error.category.isRetryable == false)
        #expect(error.userFacingSummary.contains("模型或接口资源不存在 (404)"))
    }

    @Test("HTTP 405 classifies as methodNotAllowed")
    func testMethodNotAllowed() {
        let error = ProviderErrorClassifier.classify(statusCode: 405)
        #expect(error.category == .methodNotAllowed)
        #expect(error.category.isRetryable == false)
    }

    @Test("HTTP 408 classifies as gatewayTimeout and retryable")
    func testHTTP408Timeout() {
        let error = ProviderErrorClassifier.classify(statusCode: 408)
        #expect(error.category == .gatewayTimeout)
        #expect(error.category.isRetryable == true)
    }

    @Test("HTTP 409 classifies as conflict and non-retryable")
    func testConflict() {
        let error = ProviderErrorClassifier.classify(statusCode: 409)
        #expect(error.category == .conflict)
        #expect(error.category.isRetryable == false)
    }

    @Test("HTTP 413 classifies as payloadTooLarge and non-retryable")
    func testPayloadTooLarge() {
        let error = ProviderErrorClassifier.classify(statusCode: 413)
        #expect(error.category == .payloadTooLarge)
        #expect(error.category.isRetryable == false)
        #expect(error.userFacingSummary.contains("单次限制 (413)"))
    }

    @Test("HTTP 415 classifies as unsupportedMediaType and non-retryable")
    func testUnsupportedMediaType() {
        let error = ProviderErrorClassifier.classify(statusCode: 415)
        #expect(error.category == .unsupportedMediaType)
        #expect(error.category.isRetryable == false)
    }

    @Test("HTTP 422 classifies as invalidRequest and non-retryable")
    func testUnprocessableEntity() {
        let error = ProviderErrorClassifier.classify(statusCode: 422, body: "{\"error\":{\"message\":\"schema violation\"}}")
        #expect(error.category == .invalidRequest)
        #expect(error.category.isRetryable == false)
    }

    @Test("HTTP 423 classifies as locked and non-retryable")
    func testLocked() {
        let error = ProviderErrorClassifier.classify(statusCode: 423)
        #expect(error.category == .locked)
        #expect(error.category.isRetryable == false)
    }

    @Test("HTTP 429 with rpm exhausted classifies as rateLimited and retryable")
    func testRateLimitedWithRPMExhausted() {
        let body = "{\"error\":{\"message\":\"rpm exhausted\",\"type\":\"quota_exceeded_error\",\"code\":\"8\"}}"
        let error = ProviderErrorClassifier.classify(statusCode: 429, headers: ["Retry-After": "2"], body: body)
        #expect(error.category == .rateLimited)
        #expect(error.category.isRetryable == true)
        #expect(error.statusCode == 429)
        #expect(error.retryAfter == .milliseconds(2000))
    }

    @Test("HTTP 500 classifies as internalServerError and retryable")
    func testInternalServerError() {
        let error = ProviderErrorClassifier.classify(statusCode: 500)
        #expect(error.category == .internalServerError)
        #expect(error.category.isRetryable == true)
    }

    @Test("HTTP 501 classifies as notImplemented and non-retryable")
    func testNotImplemented() {
        let error = ProviderErrorClassifier.classify(statusCode: 501)
        #expect(error.category == .notImplemented)
        #expect(error.category.isRetryable == false)
    }

    @Test("HTTP 502 and Cloudflare 520/521/523 classify as badGateway and retryable")
    func testBadGateway() {
        let error502 = ProviderErrorClassifier.classify(statusCode: 502)
        #expect(error502.category == .badGateway)
        #expect(error502.category.isRetryable == true)

        let error521 = ProviderErrorClassifier.classify(statusCode: 521)
        #expect(error521.category == .badGateway)
        #expect(error521.category.isRetryable == true)
    }

    @Test("HTTP 503 and 529 classify as serverOverloaded and retryable")
    func testServerOverloaded() {
        let error503 = ProviderErrorClassifier.classify(statusCode: 503)
        #expect(error503.category == .serverOverloaded)
        #expect(error503.category.isRetryable == true)

        let error529 = ProviderErrorClassifier.classify(statusCode: 529)
        #expect(error529.category == .serverOverloaded)
        #expect(error529.category.isRetryable == true)
    }

    @Test("HTTP 504 and Cloudflare 522/524 classify as gatewayTimeout and retryable")
    func testGatewayTimeout() {
        let error504 = ProviderErrorClassifier.classify(statusCode: 504)
        #expect(error504.category == .gatewayTimeout)
        #expect(error504.category.isRetryable == true)

        let error524 = ProviderErrorClassifier.classify(statusCode: 524)
        #expect(error524.category == .gatewayTimeout)
        #expect(error524.category.isRetryable == true)
    }

    @Test("Content filter trigger classifies as contentFiltered and non-retryable")
    func testContentFilter() {
        let body = "{\"error\":{\"message\":\"The response was filtered due to the prompt triggering Azure OpenAI's content management policy.\",\"type\":\"content_filter\"}}"
        let error = ProviderErrorClassifier.classify(statusCode: 400, body: body)
        #expect(error.category == .contentFiltered)
        #expect(error.category.isRetryable == false)
        #expect(error.userFacingSummary.contains("安全审查"))
    }

    @Test("Transport errors classify accurately")
    func testTransportErrors() {
        let timeoutError = CoreError(code: .commandTimedOut, message: "request timed out")
        let errorTimeout = ProviderErrorClassifier.classify(statusCode: nil, underlying: timeoutError)
        #expect(errorTimeout.category == .gatewayTimeout)
        #expect(errorTimeout.category.isRetryable == true)

        let lostError = CoreError(code: .transportLost, message: "connection dropped")
        let errorLost = ProviderErrorClassifier.classify(statusCode: nil, underlying: lostError)
        #expect(errorLost.category == .networkFailure)
        #expect(errorLost.category.isRetryable == true)
    }

    // MARK: - 2. ProviderRateLimitError 桥接验证

    @Test("ProviderRateLimitError separates retryable from non-retryable")
    func testProviderRateLimitErrorBridge() {
        let baseErr = CoreError(code: .provider, message: "raw error")
        // 504 Gateway Timeout -> 可重试，返回 ProviderRateLimitError
        let retryable = ProviderRateLimitError.from(statusCode: 504, headers: [:], body: "gateway timeout", underlying: baseErr)
        #expect(retryable is ProviderRateLimitError)
        let rateErr = retryable as! ProviderRateLimitError
        #expect(rateErr.classified.category == .gatewayTimeout)
        #expect(rateErr.classified.category.isRetryable == true)

        // 401 Unauthorized -> 永久错误，包装为带结构化诊断的 CoreError，不重试
        let permanent = ProviderRateLimitError.from(statusCode: 401, headers: [:], body: "{\"error\":{\"message\":\"invalid key\"}}", underlying: baseErr)
        #expect(permanent is CoreError)
        let core = permanent as! CoreError
        #expect(core.code == .provider)
        #expect(core.message.contains("API Key"))
    }

    // MARK: - 3. 事件与 SessionViewState 状态机透传测试

    @Test("providerRequestStateChanged event preserves detail and statusCode across JSON serialization")
    func testEventSerialization() throws {
        let payload = SessionEventPayload.providerRequestStateChanged(
            requestID: ProviderRequestID("req-123"),
            state: .retryScheduled,
            detail: "上游网关超时 (504)，正在第 1/3 次重试 (2.0s)...",
            statusCode: 504
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SessionEventPayload.self, from: data)

        guard case let .providerRequestStateChanged(reqID, state, detail, code) = decoded else {
            Issue.record("Expected providerRequestStateChanged event")
            return
        }
        #expect(reqID.rawValue == "req-123")
        #expect(state == .retryScheduled)
        #expect(detail == "上游网关超时 (504)，正在第 1/3 次重试 (2.0s)...")
        #expect(code == 504)
    }

    @Test("SessionReducer correctly projects detail and statusCode into SessionViewState")
    func testSessionReducerProjectsDetail() {
        var state = SessionViewState(sessionID: SessionID("s-1"))
        let envelope = SessionEventEnvelope(
            cursor: EventCursor(generationID: EventLogGenerationID("gen-1"), sequence: 1),
            timestamp: Date(),
            causal: CausalContext(sessionID: SessionID("s-1")),
            payload: .providerRequestStateChanged(
                requestID: ProviderRequestID("req-1"),
                state: .retryScheduled,
                detail: "上游服务过载 (529)，退避重试 (1/3)...",
                statusCode: 529
            )
        )
        let connState = ConnectionState(status: .connected)
        SessionReducer.reduce(state: &state, event: envelope, connectionState: connState)

        #expect(state.activeProviderRequestState == .retryScheduled)
        #expect(state.activeProviderRequestDetail == "上游服务过载 (529)，退避重试 (1/3)...")
        #expect(state.activeProviderStatusCode == 529)
        #expect(state.status == .waitingForProvider)
    }
}
