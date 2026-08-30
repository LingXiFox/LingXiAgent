import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingXiProtocol

/// OpenAI Responses API adapter. Its DTOs never leave this file.
public struct OpenAIResponsesProvider: ModelProvider {
    private let config: ProviderConfig
    private let session: URLSession
    private let provenance: ResponsesProvenanceStore

    public init(config: ProviderConfig, session: URLSession = .shared, provenance: ResponsesProvenanceStore = ResponsesProvenanceStore()) {
        self.config = config
        self.session = session
        self.provenance = provenance
    }

    public func stream(_ request: ModelRequest) async throws -> AsyncThrowingStream<ModelEvent, Error> {
        let toolResultIDs = Self.trailingToolResultIDs(request)
        let previousResponseID = await provenance.responseID(for: toolResultIDs)
        let urlRequest = try makeURLRequest(request, previousResponseID: previousResponseID)
        let startedAt = Date()
        Self.logRequest(urlRequest, step: request.debugStep)
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw CoreError(code: .provider, message: "Provider 返回非 HTTP 响应")
        }
        let requestID = http.value(forHTTPHeaderField: "x-request-id")
            ?? http.value(forHTTPHeaderField: "openai-request-id")
            ?? http.value(forHTTPHeaderField: "cf-ray")
        Self.log("http step=\(request.debugStep ?? 0) status=\(http.statusCode) requestID=\(requestID ?? "none") elapsedMs=\(Self.elapsed(since: startedAt))")
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? await OpenAICompatibleProvider.collectText(bytes)) ?? ""
            Self.logHTTPError(body, step: request.debugStep, status: http.statusCode, requestID: requestID)
            throw OpenAICompatibleProvider.httpError(status: http.statusCode, body: body)
        }

        var continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation!
        let events = AsyncThrowingStream { continuation = $0 }
        Task { await Pump(source: bytes, continuation: continuation!, step: request.debugStep, requestID: requestID, startedAt: startedAt, provenance: provenance).run() }
        return events
    }

    public func makeURLRequest(_ request: ModelRequest, previousResponseID: String? = nil) throws -> URLRequest {
        var urlRequest = URLRequest(url: config.responsesURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = config.apiKey, !apiKey.isEmpty { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        urlRequest.httpBody = try Self.makeRequestBody(request, model: config.model, previousResponseID: previousResponseID)
        return urlRequest
    }

    /// Domain request -> Responses API JSON.
    public static func makeRequestBody(_ request: ModelRequest, model: String) throws -> Data {
        try makeRequestBody(request, model: model, previousResponseID: nil)
    }

    private static func makeRequestBody(_ request: ModelRequest, model: String, previousResponseID: String?) throws -> Data {
        let messages = previousResponseID == nil ? request.messages : continuationMessages(request)
        let input = messages.flatMap { message -> [ResponseRequestBody.Input] in
            let calls = message.parts.compactMap { if case let .toolCall(call) = $0 { call } else { nil } }
            let results = message.parts.compactMap { if case let .toolResult(result) = $0 { result } else { nil } }
            switch message.role {
            case .tool:
                return results.map { .functionOutput(callID: $0.callID.rawValue, output: resultContent($0)) }
            case .assistant:
                var items: [ResponseRequestBody.Input] = []
                if !message.content.isEmpty { items.append(.message(role: "assistant", content: message.content)) }
                items.append(contentsOf: calls.map { .functionCall(callID: $0.callID.rawValue, name: $0.toolID.rawValue, arguments: $0.arguments) })
                return items
            case .system:
                return [.message(role: "developer", content: message.content)]
            case .user:
                return [.message(role: "user", content: message.content)]
            }
        }
        return try JSONEncoder().encode(ResponseRequestBody(
            model: model,
            stream: true,
            store: true,
            instructions: request.system,
            input: input,
            tools: request.tools.isEmpty ? nil : request.tools.map(ResponseRequestBody.Tool.init),
            reasoning: request.reasoning.map(ResponseRequestBody.Reasoning.init),
            previousResponseID: previousResponseID
        ))
    }

    public static func events(forSSEPayload payload: String, decoder: inout ResponsesSSEDecoder) throws -> [ModelEvent] {
        try decoder.consume(payload)
    }

    private static func resultContent(_ result: ToolResult) -> String {
        guard !result.success else { return result.content }
        let error = result.error ?? ToolError(code: "toolExecutionFailed", message: "Tool 执行失败")
        return (try? String(decoding: JSONEncoder().encode(error), as: UTF8.self)) ?? error.message
    }

    private static func trailingToolResultIDs(_ request: ModelRequest) -> [String] {
        continuationMessages(request).flatMap { message in
            message.parts.compactMap { part in
                if case let .toolResult(result) = part { return result.callID.rawValue }
                return nil
            }
        }
    }

    private static func continuationMessages(_ request: ModelRequest) -> [ModelMessage] {
        let lastUser = request.messages.lastIndex { $0.role == .user }
        guard let toolIndex = request.messages.lastIndex(where: { $0.role == .tool }),
              lastUser == nil || toolIndex > lastUser!
        else { return [] }
        return [request.messages[toolIndex]]
    }

    private static func logRequest(_ request: URLRequest, step: Int?) {
        guard diagnosticsEnabled, let body = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return }
        let input = object["input"] as? [[String: Any]] ?? []
        let outputCount = input.filter { $0["type"] as? String == "function_call_output" }.count
        let callCount = input.filter { $0["type"] as? String == "function_call" }.count
        let toolCount = (object["tools"] as? [[String: Any]])?.count ?? 0
        let continued = object["previous_response_id"] != nil
        log("request step=\(step ?? 0) wire=responses continued=\(continued) inputItems=\(input.count) functionCalls=\(callCount) functionOutputs=\(outputCount) tools=\(toolCount) bytes=\(body.count) timeoutSec=\(Int(request.timeoutInterval))")
    }

    private static func logHTTPError(_ body: String, step: Int?, status: Int, requestID: String?) {
        let value = body.lowercased()
        log("httpError step=\(step ?? 0) status=\(status) requestID=\(requestID ?? "none") mentionsPreviousResponseID=\(value.contains("previous_response_id")) mentionsStore=\(value.contains("store")) unsupported=\(value.contains("unsupported") || value.contains("not supported")) notFound=\(value.contains("not found") || value.contains("unknown response")) malformed=\(value.contains("deserialize") || value.contains("invalid json") || value.contains("malformed"))")
    }

    private static var diagnosticsEnabled: Bool { ProcessInfo.processInfo.environment["LINGXI_PROVIDER_DIAGNOSTICS"] == "1" }
    private static func elapsed(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1_000) }
    private static func log(_ message: String) {
        guard diagnosticsEnabled else { return }
        FileHandle.standardError.write(Data(("[responses-diagnostic] \(message)\n").utf8))
    }

    private final class Pump: Sendable {
        private let source: URLSession.AsyncBytes
        private let continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation
        private let step: Int?
        private let requestID: String?
        private let startedAt: Date
        private let provenance: ResponsesProvenanceStore

        init(source: URLSession.AsyncBytes, continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation, step: Int?, requestID: String?, startedAt: Date, provenance: ResponsesProvenanceStore) {
            self.source = source
            self.continuation = continuation
            self.step = step
            self.requestID = requestID
            self.startedAt = startedAt
            self.provenance = provenance
        }

        func run() async {
            var lines = SSEDecoder()
            var decoder = ResponsesSSEDecoder()
            var completed: ModelFinishReason?
            var lastEventType = "none"
            var terminalObserved = false
            var responseID: String?
            continuation.yield(.started)
            do {
                outer: for try await byte in source {
                    for line in lines.feed(Data([byte])) {
                        if try emit(line, decoder: &decoder, completed: &completed, lastEventType: &lastEventType, terminalObserved: &terminalObserved, responseID: &responseID) { break outer }
                    }
                }
                if !terminalObserved {
                    for line in lines.flushPending() {
                        _ = try emit(line, decoder: &decoder, completed: &completed, lastEventType: &lastEventType, terminalObserved: &terminalObserved, responseID: &responseID)
                    }
                }
                if let responseID { await provenance.record(responseID: responseID, callIDs: decoder.completedCallIDs) }
                OpenAIResponsesProvider.log("eof step=\(step ?? 0) requestID=\(requestID ?? "none") responseID=\(responseID ?? "none") lastEvent=\(lastEventType) terminal=\(terminalObserved) elapsedMs=\(OpenAIResponsesProvider.elapsed(since: startedAt))")
                continuation.yield(.completed(completed ?? .unknown))
                continuation.finish()
            } catch let error as CoreError {
                OpenAIResponsesProvider.log("failed step=\(step ?? 0) requestID=\(requestID ?? "none") responseID=\(responseID ?? "none") lastEvent=\(lastEventType) terminal=\(terminalObserved) elapsedMs=\(OpenAIResponsesProvider.elapsed(since: startedAt)) code=\(error.code.rawValue)")
                continuation.yield(.failed(error))
                continuation.finish()
            } catch {
                OpenAIResponsesProvider.log("failed step=\(step ?? 0) requestID=\(requestID ?? "none") responseID=\(responseID ?? "none") lastEvent=\(lastEventType) terminal=\(terminalObserved) elapsedMs=\(OpenAIResponsesProvider.elapsed(since: startedAt)) code=transport")
                continuation.yield(.failed(CoreError(code: .modelStream, message: "Responses SSE 中断: \(error)")))
                continuation.finish()
            }
        }

        private func emit(_ line: String, decoder: inout ResponsesSSEDecoder, completed: inout ModelFinishReason?, lastEventType: inout String, terminalObserved: inout Bool, responseID: inout String?) throws -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { return false }
            let payload = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]" else { return true }
            if let data = payload.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = object["type"] as? String {
                lastEventType = type
                terminalObserved = terminalObserved || ["response.completed", "response.incomplete", "response.failed", "error"].contains(type)
                if let response = object["response"] as? [String: Any], let id = response["id"] as? String { responseID = id }
                OpenAIResponsesProvider.log("event step=\(step ?? 0) requestID=\(requestID ?? "none") responseID=\(responseID ?? "none") type=\(type) elapsedMs=\(OpenAIResponsesProvider.elapsed(since: startedAt))")
            }
            for event in try decoder.consume(payload) {
                if case let .completed(reason) = event { completed = reason }
                else { continuation.yield(event) }
            }
            return terminalObserved
        }
    }
}

/// Stateful Responses API event decoder. `item_id` remains adapter-local provenance;
/// only `call_id` becomes the domain ToolCall identity.
public struct ResponsesSSEDecoder {
    private struct Partial {
        var name: String?
        var arguments = ""
        var started = false
        var emitted = 0
        var completed = false
    }

    private var calls: [String: Partial] = [:]
    private var itemToCallID: [String: String] = [:]
    public private(set) var completedCallIDs: [String] = []

    public init() {}

    public mutating func consume(_ payload: String) throws -> [ModelEvent] {
        guard let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { throw CoreError(code: .modelStream, message: "Responses SSE JSON 解析失败: \(payload.prefix(200))") }
        switch type {
        case "response.output_text.delta":
            return (object["delta"] as? String).map { [.textDelta($0)] } ?? []
        case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
            return (object["delta"] as? String).map { [.reasoningDelta($0)] } ?? []
        case "response.function_call_arguments.delta":
            return try updateCall(callID: callID(in: object), name: string(object, "name"), arguments: object["delta"] as? String, finish: false)
        case "response.function_call_arguments.done":
            return try updateCall(callID: callID(in: object), name: string(object, "name"), arguments: object["arguments"] as? String, finish: true)
        case "response.output_item.added", "response.output_item.done":
            guard let item = object["item"] as? [String: Any], item["type"] as? String == "function_call" else { return [] }
            if let itemID = string(item, "id"), let callID = string(item, "call_id") { itemToCallID[itemID] = callID }
            return try updateCall(callID: callID(in: item), name: string(item, "name"), arguments: item["arguments"] as? String, finish: type.hasSuffix("done"))
        case "response.completed":
            var events: [ModelEvent] = []
            if let response = object["response"] as? [String: Any] {
                if let usage = response["usage"] as? [String: Any] { events.append(.usage(Self.usage(usage))) }
                events.append(.completed(Self.finish(response["status"] as? String)))
            } else { events.append(.completed(.unknown)) }
            return events
        case "response.incomplete":
            if let response = object["response"] as? [String: Any], let usage = response["usage"] as? [String: Any] {
                return [.usage(Self.usage(usage)), .completed(.maxTokens)]
            }
            return [.completed(.maxTokens)]
        case "response.failed", "error":
            let message = (object["error"] as? [String: Any])?["message"] as? String ?? object["message"] as? String ?? "Responses API 返回错误事件"
            return [.failed(CoreError(code: .modelStream, message: message))]
        default:
            return []
        }
    }

    private mutating func updateCall(callID: String?, name: String?, arguments: String?, finish: Bool) throws -> [ModelEvent] {
        guard let callID, !callID.isEmpty else { throw CoreError(code: .modelStream, message: "Responses function call 缺少 call_id") }
        var call = calls[callID] ?? Partial()
        call.name = name ?? call.name
        if let arguments, !arguments.isEmpty {
            if arguments.hasPrefix(call.arguments) { call.arguments = arguments }
            else { call.arguments += arguments }
        }
        var events: [ModelEvent] = []
        if let name = call.name, !call.started {
            call.started = true
            events.append(.toolCallStarted(callID: ToolCallID(callID), toolID: ToolID(name)))
        }
        if call.started, call.emitted < call.arguments.count {
            events.append(.toolCallDelta(callID: ToolCallID(callID), arguments: String(call.arguments.dropFirst(call.emitted))))
            call.emitted = call.arguments.count
        }
        if finish, !call.completed {
            guard let name = call.name else { throw CoreError(code: .modelStream, message: "Responses function call 缺少 name") }
            call.completed = true
            completedCallIDs.append(callID)
            events.append(.toolCallCompleted(ToolCall(callID: ToolCallID(callID), toolID: ToolID(name), arguments: call.arguments)))
        }
        calls[callID] = call
        return events
    }

    private func string(_ object: [String: Any], _ key: String) -> String? { object[key] as? String }

    private func callID(in object: [String: Any]) -> String? {
        string(object, "call_id") ?? string(object, "item_id").flatMap { itemToCallID[$0] }
    }

    private static func finish(_ status: String?) -> ModelFinishReason {
        switch status {
        case "completed": .stop
        case "incomplete": .maxTokens
        default: .unknown
        }
    }

    private static func usage(_ value: [String: Any]) -> ModelUsage {
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

    struct Reasoning: Encodable { let effort: String; init(_ effort: String) { self.effort = effort } }

    enum Input: Encodable {
        case message(role: String, content: String)
        case functionCall(callID: String, name: String, arguments: String)
        case functionOutput(callID: String, output: String)

        enum Keys: String, CodingKey { case type, role, content, callID = "call_id", name, arguments, output }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: Keys.self)
            switch self {
            case let .message(role, content):
                try values.encode(role, forKey: .role); try values.encode(content, forKey: .content)
            case let .functionCall(callID, name, arguments):
                try values.encode("function_call", forKey: .type); try values.encode(callID, forKey: .callID); try values.encode(name, forKey: .name); try values.encode(arguments, forKey: .arguments)
            case let .functionOutput(callID, output):
                try values.encode("function_call_output", forKey: .type); try values.encode(callID, forKey: .callID); try values.encode(output, forKey: .output)
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
    let previousResponseID: String?

    enum CodingKeys: String, CodingKey {
        case model, stream, store, instructions, input, tools, reasoning
        case previousResponseID = "previous_response_id"
    }
}

public actor ResponsesProvenanceStore {
    private var responseByCallID: [String: String] = [:]

    public init() {}

    func responseID(for callIDs: [String]) -> String? {
        guard !callIDs.isEmpty else { return nil }
        let values = Set(callIDs.compactMap { responseByCallID[$0] })
        return values.count == 1 && callIDs.allSatisfy { responseByCallID[$0] != nil } ? values.first : nil
    }

    func record(responseID: String, callIDs: [String]) {
        for callID in callIDs { responseByCallID[callID] = responseID }
    }
}
