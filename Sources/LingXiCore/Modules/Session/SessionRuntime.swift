import Foundation
import LingXiProtocol

/// 一个 Session 的串行 Agent Lane。Tool 结果以结构化 parts 回写 Session，再进入下一步模型输入。
public actor SessionRuntime {
    private static let maximumAgentSteps = 8

    private let store: any SessionStore
    private let sessionID: SessionID
    private let modelBus: ModelBus
    private let dataPlane: DataPlane
    private let contextBuilder: SessionContextBuilder
    private let toolRuntime: ToolRuntime
    private let eventSink: @Sendable (CoreEvent) async -> Void
    private var turnRunning = false

    init(
        store: any SessionStore,
        sessionID: SessionID,
        modelBus: ModelBus,
        dataPlane: DataPlane,
        contextBuilder: SessionContextBuilder,
        toolRuntime: ToolRuntime,
        eventSink: @escaping @Sendable (CoreEvent) async -> Void
    ) {
        self.store = store
        self.sessionID = sessionID
        self.modelBus = modelBus
        self.dataPlane = dataPlane
        self.contextBuilder = contextBuilder
        self.toolRuntime = toolRuntime
        self.eventSink = eventSink
    }

    /// 启动一轮对话并立即返回 DMA 通道；同一 Session 只允许一个活动 turn。
    public func startTurn(_ content: String) async throws -> OpenedStream {
        guard !turnRunning else {
            throw CoreError(code: .turnAlreadyRunning, message: "该 Session 已有进行中的对话轮次")
        }
        turnRunning = true
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
            Task { await self.runTurn(handle: handle, sink: opened.sink) }
            return opened.stream
        } catch {
            turnRunning = false
            throw error
        }
    }

    private func runTurn(
        handle: TurnHandle,
        sink: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) async {
        var index = 0
        var finalUsage: ModelUsage?
        var finalReason: ModelFinishReason?

        do {
            for _ in 0..<Self.maximumAgentSteps {
                let session = try await store.session(sessionID)
                let request = ModelRequest(
                    model: try modelID(),
                    messages: contextBuilder.buildModelMessages(from: session.messages),
                    tools: toolRuntime.definitions
                )
                let events = try await modelBus.stream(request)
                var text = ""
                var calls: [ToolCall] = []

                for try await event in events {
                    switch event {
                    case .started:
                        break
                    case let .textDelta(delta):
                        sink.yield(StreamChunk(streamID: handle.streamID, index: index, text: delta, kind: .text))
                        index += 1
                        text += delta
                    case let .reasoningDelta(delta):
                        sink.yield(StreamChunk(streamID: handle.streamID, index: index, text: delta, kind: .reasoning))
                        index += 1
                    case .toolCallStarted, .toolCallDelta:
                        break // Tool arguments 只在完整聚合后进入控制面。
                    case let .toolCallCompleted(call):
                        calls.append(call)
                    case let .usage(usage):
                        finalUsage = usage
                    case let .completed(reason):
                        finalReason = reason
                    case let .failed(error):
                        throw error
                    }
                }

                guard !calls.isEmpty else {
                    await completeTurn(
                        handle: handle,
                        sink: sink,
                        content: text,
                        finishReason: finalReason,
                        usage: finalUsage
                    )
                    return
                }

                var assistantParts: [SessionMessagePart] = calls.map(SessionMessagePart.toolCall)
                if !text.isEmpty { assistantParts.insert(.text(text), at: 0) }
                try await store.appendMessage(sessionID, role: .assistant, parts: assistantParts)

                for call in calls {
                    await eventSink(.toolCallCompleted(call))
                    let result = await toolRuntime.execute(call, sessionID: sessionID) { [eventSink] request in
                        await eventSink(.permissionAsked(request))
                    }
                    try await store.appendMessage(sessionID, role: .tool, parts: [.toolResult(result)])
                    await eventSink(.toolResult(result))
                }
            }
            throw CoreError(code: .agentStepLimitReached, message: "Agent Tool Loop 超过 \(Self.maximumAgentSteps) steps")
        } catch let error as CoreError {
            await failTurn(handle: handle, sink: sink, error: error)
        } catch {
            await failTurn(
                handle: handle,
                sink: sink,
                error: CoreError(code: .provider, message: String(describing: error))
            )
        }
    }

    private func modelID() throws -> ModelID {
        guard let modelID = modelBus.gateway.modelID else {
            throw CoreError(code: .provider, message: "未配置模型 Provider")
        }
        return modelID
    }

    private func completeTurn(
        handle: TurnHandle,
        sink: AsyncThrowingStream<StreamChunk, Error>.Continuation,
        content: String,
        finishReason: ModelFinishReason?,
        usage: ModelUsage?
    ) async {
        defer { sink.finish() }
        do {
            let message = try await store.appendMessage(handle.sessionID, role: .assistant, content: content)
            turnRunning = false
            await eventSink(.turnCompleted(TurnResult(
                sessionID: handle.sessionID,
                streamID: handle.streamID,
                assistantMessageID: message.id,
                finishReason: finishReason,
                usage: usage
            )))
        } catch let error as CoreError {
            await failTurn(handle: handle, sink: sink, error: error)
        } catch {
            await failTurn(handle: handle, sink: sink, error: CoreError(code: .transport, message: String(describing: error)))
        }
    }

    private func failTurn(
        handle: TurnHandle,
        sink: AsyncThrowingStream<StreamChunk, Error>.Continuation,
        error: CoreError
    ) async {
        sink.finish()
        turnRunning = false
        await eventSink(.turnFailed(TurnFailure(sessionID: handle.sessionID, streamID: handle.streamID, error: error)))
    }
}
