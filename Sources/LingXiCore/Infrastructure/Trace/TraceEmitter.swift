import Foundation
import LingXiProtocol

/// 统一运行轨迹漏斗 (TraceEmitter)
/// 负责收敛全系统所有 Trace 生产者，将其标准化为 RuntimeTraceEvent，并经由有界非阻塞队列写入：
/// 1. 独立数据库 traces.sqlite (TraceStore)
/// 2. 内存环形缓冲 RuntimeDiagnosticsStore
/// 3. 按小时轮转归档 traces/trace-YYYY-MM-DD-HH.jsonl
public actor TraceEmitter {
    public static let shared = TraceEmitter()

    private var store: TraceStore?
    private let diagnosticsStore: RuntimeDiagnosticsStore
    private let exportRoot: URL?
    private let queueCapacity: Int
    private var pendingQueue: [RuntimeTraceEvent] = []
    private var isFlushing: Bool = false
    public private(set) var overflowDropCount: Int = 0

    public init(
        store: TraceStore? = nil,
        diagnosticsStore: RuntimeDiagnosticsStore = RuntimeDiagnosticsStore(limit: 4_000),
        exportRoot: URL? = nil,
        queueCapacity: Int = 5_000
    ) {
        self.store = store
        self.diagnosticsStore = diagnosticsStore
        self.exportRoot = exportRoot
        self.queueCapacity = max(100, queueCapacity)
    }

    public func configure(store: TraceStore, exportRoot: URL) {
        self.store = store
    }

    /// 向漏斗发射事件，保证绝对非阻塞、永不向调用方抛错。
    public func emit(_ event: RuntimeTraceEvent) {
        let sanitized = Self.redact(event)

        // 1. 实时内存诊断池消费
        Task { [diagnosticsStore] in
            await diagnosticsStore.record(
                kind: sanitized.kind,
                event: sanitized.event,
                sessionID: sanitized.sessionID,
                runID: sanitized.runID,
                rootRunID: sanitized.rootRunID,
                parentRunID: sanitized.parentRunID,
                workflowID: sanitized.workflowID,
                workflowTaskID: sanitized.workflowTaskID,
                taskID: sanitized.taskID,
                executionID: sanitized.executionID,
                providerRequestID: sanitized.providerRequestID,
                toolCallID: sanitized.toolCallID,
                metadata: sanitized.metadata,
                errorCode: sanitized.errorCode
            )
        }

        // 2. 有界异步缓冲
        if pendingQueue.count >= queueCapacity {
            pendingQueue.removeFirst()
            overflowDropCount += 1
        }
        pendingQueue.append(sanitized)

        triggerFlushIfNeeded()
    }

    private func triggerFlushIfNeeded() {
        guard !isFlushing, !pendingQueue.isEmpty else { return }
        isFlushing = true

        let batch = pendingQueue
        pendingQueue.removeAll(keepingCapacity: true)

        Task { [weak self] in
            await self?.processBatch(batch)
        }
    }

    private func processBatch(_ batch: [RuntimeTraceEvent]) async {
        defer {
            isFlushing = false
            triggerFlushIfNeeded()
        }

        guard let store = self.store else { return }

        for event in batch {
            do {
                try await store.insert(event: event)
                try exportJSONL(event: event)
            } catch {
                // 写路径绝不抛错阻断业务，记录控制台错误日志
                #if DEBUG
                print("[TraceEmitter] Persistence failed: \(error)")
                #endif
            }
        }
    }

    private func exportJSONL(event: RuntimeTraceEvent) throws {
        guard let exportRoot = self.exportRoot else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH"
        let hourString = formatter.string(from: event.timestamp)
        let fileURL = exportRoot.appendingPathComponent("trace-\(hourString).jsonl")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event)
        data.append(contentsOf: [0x0A]) // \n newline

        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    public func enforceRetention(days: Int = 7, maxRows: Int = 200_000) async throws -> Int {
        guard let store = self.store else { return 0 }
        return try await store.prune(retentionDays: days, maxRows: maxRows)
    }

    // MARK: - Redaction Invariants

    public static func redact(_ event: RuntimeTraceEvent) -> RuntimeTraceEvent {
        let cleanMetadata = redactMetadata(event.metadata)
        let cleanAttributes = redactAttributes(event.attributes)

        return RuntimeTraceEvent(
            traceID: event.traceID,
            timestamp: event.timestamp,
            kind: event.kind,
            event: event.event,
            sessionID: event.sessionID,
            runID: event.runID,
            rootRunID: event.rootRunID,
            parentRunID: event.parentRunID,
            workflowID: event.workflowID,
            workflowTaskID: event.workflowTaskID,
            taskID: event.taskID,
            parentGoalID: event.parentGoalID,
            traceSchemaVersion: event.traceSchemaVersion,
            spanID: event.spanID,
            parentSpanID: event.parentSpanID,
            durationMicroseconds: event.durationMicroseconds,
            tokens: event.tokens,
            attributes: cleanAttributes,
            executionID: event.executionID,
            providerRequestID: event.providerRequestID,
            toolCallID: event.toolCallID,
            metadata: cleanMetadata,
            errorCode: event.errorCode
        )
    }

    private static func redactMetadata(_ values: [String: String]) -> [String: String] {
        values.reduce(into: [:]) { result, item in
            let lower = item.key.lowercased()
            if isSensitiveKey(lower) {
                result[item.key] = "[redacted]"
            } else {
                result[item.key] = redactBearer(item.value)
            }
        }
    }

    private static func redactAttributes(_ attrs: [String: TraceAttributeValue]?) -> [String: TraceAttributeValue]? {
        guard let attrs = attrs else { return nil }
        return attrs.reduce(into: [:]) { result, item in
            let lower = item.key.lowercased()
            if isSensitiveKey(lower) {
                result[item.key] = .string("[redacted]")
            } else {
                switch item.value {
                case .string(let s):
                    result[item.key] = .string(redactBearer(s))
                default:
                    result[item.key] = item.value
                }
            }
        }
    }

    private static func isSensitiveKey(_ lower: String) -> Bool {
        let sensitiveKeys = [
            "secret", "credential", "authorization", "api_key", "apikey",
            "token", "password", "passphrase", "cookie", "lingxi_",
            "request_body", "response_body", "private_key"
        ]
        return sensitiveKeys.contains { lower.contains($0) }
    }

    private static func redactBearer(_ value: String) -> String {
        value.replacingOccurrences(of: "Bearer \\S+", with: "Bearer [redacted]", options: .regularExpression)
    }

    // MARK: - Adapters

    public static func adapt(
        terminalTrace: AgentTerminalTrace,
        sessionID: SessionID,
        runID: AgentRunID,
        taskID: TaskID? = nil
    ) -> RuntimeTraceEvent {
        var attrs: [String: TraceAttributeValue] = [:]
        attrs["terminalReason"] = .string(terminalTrace.terminalReason.rawValue)
        attrs["terminalTransition"] = .string(terminalTrace.terminalTransition)
        attrs["transitionSource"] = .string(terminalTrace.transitionSource)
        attrs["explanation"] = .string(terminalTrace.explanation)
        if let lastReq = terminalTrace.lastProviderRequestID {
            attrs["lastProviderRequestID"] = .string(lastReq)
        }
        if let finish = terminalTrace.finishReason {
            attrs["finishReason"] = .string(finish)
        }

        return RuntimeTraceEvent(
            timestamp: terminalTrace.timestamp,
            kind: .agentRun,
            event: "terminal.state",
            sessionID: sessionID,
            runID: runID,
            taskID: taskID,
            attributes: attrs,
            providerRequestID: terminalTrace.lastProviderRequestID,
            toolCallID: terminalTrace.lastToolCallID
        )
    }

    public static func adapt(
        profilerStep: StepPerformance,
        sessionID: SessionID,
        runID: AgentRunID? = nil,
        taskID: TaskID? = nil
    ) -> RuntimeTraceEvent {
        var attrs: [String: TraceAttributeValue] = [:]
        attrs["step"] = .int(profilerStep.step)
        attrs["contextBuildMs"] = .double(profilerStep.contextBuildMilliseconds)
        attrs["modelDispatchMs"] = .double(profilerStep.modelDispatchMilliseconds)
        attrs["streamMs"] = .double(profilerStep.streamMilliseconds)
        attrs["toolCallCount"] = .int(profilerStep.toolCallCount)

        let totalMs = profilerStep.contextBuildMilliseconds + profilerStep.modelDispatchMilliseconds + profilerStep.streamMilliseconds

        return RuntimeTraceEvent(
            kind: .core,
            event: "step.performance",
            sessionID: sessionID,
            runID: runID,
            taskID: taskID,
            durationMicroseconds: Int64(totalMs * 1_000),
            attributes: attrs
        )
    }

    public static func adapt(
        ecoreEvent: ECoreAccessEvent,
        taskID: TaskID? = nil
    ) -> RuntimeTraceEvent {
        var attrs: [String: TraceAttributeValue] = [:]
        attrs["objectID"] = .string(ecoreEvent.objectID.rawValue)
        attrs["eventType"] = .string(ecoreEvent.eventType.rawValue)

        return RuntimeTraceEvent(
            timestamp: ecoreEvent.timestamp,
            kind: .core,
            event: "ecore.access",
            sessionID: ecoreEvent.sessionID,
            taskID: taskID,
            attributes: attrs
        )
    }

    public static func adapt(
        retrievalQuery: String,
        resultsCount: Int,
        durationMs: Double,
        sessionID: SessionID? = nil,
        taskID: TaskID? = nil
    ) -> RuntimeTraceEvent {
        var attrs: [String: TraceAttributeValue] = [:]
        attrs["query"] = .string(retrievalQuery)
        attrs["resultsCount"] = .int(resultsCount)
        attrs["durationMs"] = .double(durationMs)

        return RuntimeTraceEvent(
            kind: .core,
            event: "retrieval.query",
            sessionID: sessionID,
            taskID: taskID,
            durationMicroseconds: Int64(durationMs * 1_000),
            attributes: attrs
        )
    }

    public static func adapt(
        providerCall: ProviderCallTrace,
        taskID: TaskID? = nil
    ) -> RuntimeTraceEvent {
        var attrs: [String: TraceAttributeValue] = [:]
        attrs["model"] = .string(providerCall.model)
        attrs["reason"] = .string(providerCall.reason)
        attrs["sequence"] = .int(providerCall.sequence)
        attrs["retryCount"] = .int(providerCall.retryCount)
        attrs["rateWaitMs"] = .int(providerCall.rateWaitMilliseconds)
        attrs["rateLimit429Count"] = .int(providerCall.rateLimit429Count)

        let tokens: TraceTokenUsage?
        if let usage = providerCall.actualUsage {
            tokens = TraceTokenUsage(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheReadTokens: usage.cacheReadTokens,
                reasoningTokens: usage.reasoningTokens
            )
        } else {
            tokens = TraceTokenUsage(inputTokens: providerCall.estimatedPromptTokens)
        }

        return RuntimeTraceEvent(
            timestamp: providerCall.timestamp,
            kind: .provider,
            event: "provider.call",
            sessionID: providerCall.sessionID,
            runID: providerCall.runID,
            parentRunID: providerCall.parentRunID,
            taskID: taskID,
            tokens: tokens,
            attributes: attrs,
            providerRequestID: providerCall.providerRequestID
        )
    }
}
