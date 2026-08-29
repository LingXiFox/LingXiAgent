import Foundation
import LingXiProtocol

/// 一个 Session 的串行 Agent Lane。Tool 结果以结构化 parts 回写 Session，再进入下一步模型输入。
public actor SessionRuntime {
    private static let maximumAgentSteps = 8

    private let store: any SessionStore
    private let sessionID: SessionID
    private let modelBus: ModelBus
    private let dataPlane: DataPlane
    private let contextEngine: L1ContextEngine
    private let toolRuntime: ToolRuntime
    private let performanceStore: PerformanceStore
    private let contextPager: ContextPager
    private let projectScanner: ProjectScanner
    private let eventSink: @Sendable (CoreEvent) async -> Void
    private var turnRunning = false

    init(
        store: any SessionStore,
        sessionID: SessionID,
        modelBus: ModelBus,
        dataPlane: DataPlane,
        contextEngine: L1ContextEngine,
        toolRuntime: ToolRuntime,
        performanceStore: PerformanceStore,
        contextPager: ContextPager,
        projectScanner: ProjectScanner,
        eventSink: @escaping @Sendable (CoreEvent) async -> Void
    ) {
        self.store = store
        self.sessionID = sessionID
        self.modelBus = modelBus
        self.dataPlane = dataPlane
        self.contextEngine = contextEngine
        self.toolRuntime = toolRuntime
        self.performanceStore = performanceStore
        self.contextPager = contextPager
        self.projectScanner = projectScanner
        self.eventSink = eventSink
    }

    /// 启动一轮对话并立即返回 DMA 通道；同一 Session 只允许一个活动 turn。
    public func startTurn(_ content: String) async throws -> OpenedStream {
        guard !turnRunning else {
            throw CoreError(code: .turnAlreadyRunning, message: "该 Session 已有进行中的对话轮次")
        }
        turnRunning = true
        let profiler = TurnProfiler(sessionID: sessionID, enabled: performanceStore.enabled)
        do {
            _ = try await store.session(sessionID)
            try await store.appendMessage(sessionID, role: .user, content: content)
            guard modelBus.gateway.modelID != nil else {
                throw CoreError(
                    code: .provider,
                    message: "未配置模型 Provider，缺少环境变量: \(modelBus.gateway.missingRequirements.joined(separator: ", "))"
                )
            }
            let opened = await dataPlane.openAgentStream()
            let handle = TurnHandle(sessionID: sessionID, streamID: opened.stream.id)
            await eventSink(.turnStarted(handle))
            Task { await self.runTurn(handle: handle, sink: opened.sink, task: content, profiler: profiler) }
            return opened.stream
        } catch {
            turnRunning = false
            throw error
        }
    }

    private func runTurn(
        handle: TurnHandle,
        sink: AsyncThrowingStream<StreamChunk, Error>.Continuation,
        task: String,
        profiler: TurnProfiler
    ) async {
        var index = 0
        var finalUsage: ModelUsage?
        var finalReason: ModelFinishReason?
        var lastSuccessfulRead: (signature: ToolRuntime.ReadOnlySignature, content: String)?

        do {
            for step in 0..<Self.maximumAgentSteps {
                trace("agent.step.begin", step: step + 1)
                let session = try await store.session(sessionID)
                let clock = ContinuousClock()
                let contextStarted = clock.now
                trace("context.build.begin", step: step + 1)
                let scan = try await contextPager.rebuildStaleFiles(using: projectScanner)
                let userMessages = session.messages.compactMap { $0.role == .user ? $0.parts.compactMap { if case let .text(text) = $0 { text } else { nil } }.joined() : nil }
                let query = ContextQuery(currentTask: task, recentUserMessages: Array(userMessages.dropLast()))
                let pagerResult = await contextPager.query(projectRoot: projectScanner.root, query: query)
                let pages = pagerResult.pages.filter { page in
                    !session.messages.contains { message in
                        message.parts.contains { part in
                            if case let .toolResult(result) = part { return result.content == page.content }
                            return false
                        }
                    }
                }
                let context = await contextEngine.snapshot(for: session, projectPages: pages)
                await contextPager.recordInjection(pages)
                let paging = await contextPager.debugMetrics(projectRoot: projectScanner.root)
                profiler.recordPaging(paging, turn: pagerResult.turnMetrics, scan: scan)
                trace("context.build.end", step: step + 1)
                profiler.recordContext(context, build: contextStarted.duration(to: clock.now))
                let dispatchStarted = clock.now
                trace("model.next.begin", step: step + 1)
                let request = ModelRequest(
                    model: try modelID(),
                    messages: context.modelMessages(),
                    tools: toolRuntime.definitions,
                    debugStep: step + 1
                )
                trace("provider.stream.begin", step: step + 1)
                let events = try await modelBus.stream(request)
                let dispatch = dispatchStarted.duration(to: clock.now)
                let streamStarted = clock.now
                var text = ""
                var calls: [ToolCall] = []

                for try await event in events {
                    switch event {
                    case .started:
                        profiler.recordFirstEvent(streamElapsed: streamStarted.duration(to: clock.now))
                    case let .textDelta(delta):
                        sink.yield(StreamChunk(streamID: handle.streamID, index: index, text: delta, kind: .text))
                        profiler.recordText(delta, streamElapsed: streamStarted.duration(to: clock.now))
                        index += 1
                        text += delta
                    case let .reasoningDelta(delta):
                        sink.yield(StreamChunk(streamID: handle.streamID, index: index, text: delta, kind: .reasoning))
                        profiler.recordReasoning(delta, streamElapsed: streamStarted.duration(to: clock.now))
                        index += 1
                    case .toolCallStarted, .toolCallDelta:
                        break // Tool arguments 只在完整聚合后进入控制面。
                    case let .toolCallCompleted(call):
                        calls.append(call)
                    case let .usage(usage):
                        finalUsage = usage
                        profiler.recordUsage(usage)
                    case let .completed(reason):
                        finalReason = reason
                    case let .failed(error):
                        throw error
                    }
                }
                trace("provider.stream.end", step: step + 1)
                profiler.recordModel(dispatch: dispatch, stream: streamStarted.duration(to: clock.now))

                guard !calls.isEmpty else {
                    await completeTurn(
                        handle: handle,
                        sink: sink,
                        content: text,
                        finishReason: finalReason,
                        usage: finalUsage,
                        profiler: profiler
                    )
                    return
                }

                var assistantParts: [SessionMessagePart] = calls.map(SessionMessagePart.toolCall)
                if !text.isEmpty { assistantParts.insert(.text(text), at: 0) }
                trace("tool.batch.begin", step: step + 1, toolCount: calls.count)
                trace("tool.batch.count", step: step + 1, toolCount: calls.count)
                guard Set(calls.map(\.callID)).count == calls.count else {
                    throw CoreError(code: .modelStream, message: "Tool batch 含重复 toolCallID")
                }
                trace("session.parts.append.begin", step: step + 1, toolCount: calls.count)
                try await store.appendMessage(sessionID, role: .assistant, parts: assistantParts)
                trace("session.parts.append.end", step: step + 1, toolCount: calls.count)

                trace("tool.batch.settle.begin", step: step + 1, toolCount: calls.count)
                let signatures = calls.map { try? toolRuntime.readOnlySignature(for: $0) }
                var outcomes = Array<ToolRuntime.ExecutionOutcome?>(repeating: nil, count: calls.count)
                var primaryByIndex: [Int: Int] = [:]
                var primaryBySignature: [ToolRuntime.ReadOnlySignature: Int] = [:]

                for (offset, call) in calls.enumerated() {
                    await eventSink(.toolCallCompleted(call))
                    trace("tool.execute.begin", step: step + 1, toolCallID: call.callID)
                    if let signature = signatures[offset], let previous = lastSuccessfulRead, previous.signature == signature {
                        outcomes[offset] = duplicateOutcome(for: call, signature: signature, content: previous.content)
                    } else if let signature = signatures[offset], let primary = primaryBySignature[signature] {
                        primaryByIndex[offset] = primary
                    } else {
                        if let signature = signatures[offset] { primaryBySignature[signature] = offset }
                        primaryByIndex[offset] = offset
                    }
                }

                await withTaskGroup(of: (Int, ToolRuntime.ExecutionOutcome).self) { group in
                    for (offset, call) in calls.enumerated() where outcomes[offset] == nil && primaryByIndex[offset] == offset {
                        group.addTask { [toolRuntime, sessionID, eventSink] in
                            let outcome = await toolRuntime.executeWithMetrics(call, sessionID: sessionID) { request in
                                await eventSink(.permissionAsked(request))
                            }
                            return (offset, outcome)
                        }
                    }
                    for await (offset, outcome) in group { outcomes[offset] = outcome }
                }

                for (offset, call) in calls.enumerated() where outcomes[offset] == nil {
                    guard let primary = primaryByIndex[offset], let previous = outcomes[primary] else {
                        throw CoreError(code: .modelStream, message: "Tool batch settlement 缺少结果: \(call.callID.rawValue)")
                    }
                    outcomes[offset] = duplicateOutcome(for: call, signature: signatures[offset]!, content: previous.result.content)
                }

                let settled = outcomes.compactMap { $0 }
                guard settled.count == calls.count, zip(calls, settled).allSatisfy({ $0.0.callID == $0.1.result.callID }) else {
                    throw CoreError(code: .modelStream, message: "ToolCall 与 ToolResult ID 不匹配")
                }
                for (offset, outcome) in settled.enumerated() {
                    let call = calls[offset]
                    trace("tool.execute.end", step: step + 1, toolCallID: call.callID)
                    profiler.recordTool(outcome)
                    let result = outcome.result
                    if let signature = signatures[offset], result.success || result.error?.code == "duplicateToolCall" {
                        lastSuccessfulRead = (signature, result.content)
                    } else {
                        lastSuccessfulRead = nil
                    }
                    trace("session.parts.append.begin", step: step + 1, toolCallID: call.callID)
                    try await store.appendMessage(sessionID, role: .tool, parts: [.toolResult(result)])
                    trace("session.parts.append.end", step: step + 1, toolCallID: call.callID)
                    await eventSink(.toolResult(result))
                }
                trace("tool.batch.settle.end", step: step + 1, toolCount: calls.count)
            }
            throw CoreError(code: .agentStepLimitReached, message: "Agent Tool Loop 超过 \(Self.maximumAgentSteps) steps")
        } catch let error as CoreError {
            await failTurn(handle: handle, sink: sink, error: error, profiler: profiler)
        } catch {
            await failTurn(
                handle: handle,
                sink: sink,
                error: CoreError(code: .provider, message: String(describing: error)),
                profiler: profiler
            )
        }
    }

    private func modelID() throws -> ModelID {
        guard let modelID = modelBus.gateway.modelID else {
            throw CoreError(code: .provider, message: "未配置模型 Provider")
        }
        return modelID
    }

    private func trace(_ event: String, step: Int, toolCallID: ToolCallID? = nil, toolCount: Int? = nil) {
        guard ProcessInfo.processInfo.environment["LINGXI_PERF_DEBUG"] == "1" else { return }
        var fields = ["[agent-trace]", "event=\(event)", "sessionID=\(sessionID.rawValue)", "step=\(step)"]
        if let toolCallID { fields.append("toolCallID=\(toolCallID.rawValue)") }
        if let toolCount { fields.append("toolCount=\(toolCount)") }
        FileHandle.standardError.write(Data((fields.joined(separator: " ") + "\n").utf8))
    }

    private func duplicateOutcome(for call: ToolCall, signature: ToolRuntime.ReadOnlySignature, content: String) -> ToolRuntime.ExecutionOutcome {
        ToolRuntime.ExecutionOutcome(
            result: ToolResult(callID: call.callID, success: false, content: content, error: ToolError(code: "duplicateToolCall", message: "连续重复调用已复用前一成功结果")),
            permissionWait: .zero,
            permissionAsked: false,
            execution: .zero,
            toolName: signature.toolName,
            resource: signature.resource
        )
    }

    private func completeTurn(
        handle: TurnHandle,
        sink: AsyncThrowingStream<StreamChunk, Error>.Continuation,
        content: String,
        finishReason: ModelFinishReason?,
        usage: ModelUsage?,
        profiler: TurnProfiler
    ) async {
        defer { sink.finish() }
        do {
            let message = try await store.appendMessage(handle.sessionID, role: .assistant, content: content)
            turnRunning = false
            if let report = profiler.report() { await performanceStore.save(report) }
            await eventSink(.turnCompleted(TurnResult(
                sessionID: handle.sessionID,
                streamID: handle.streamID,
                assistantMessageID: message.id,
                finishReason: finishReason,
                usage: usage
            )))
        } catch let error as CoreError {
            await failTurn(handle: handle, sink: sink, error: error, profiler: profiler)
        } catch {
            await failTurn(handle: handle, sink: sink, error: CoreError(code: .transport, message: String(describing: error)), profiler: profiler)
        }
    }

    private func failTurn(
        handle: TurnHandle,
        sink: AsyncThrowingStream<StreamChunk, Error>.Continuation,
        error: CoreError,
        profiler: TurnProfiler
    ) async {
        sink.finish()
        turnRunning = false
        if let report = profiler.report() { await performanceStore.save(report) }
        await eventSink(.turnFailed(TurnFailure(sessionID: handle.sessionID, streamID: handle.streamID, error: error)))
    }
}
