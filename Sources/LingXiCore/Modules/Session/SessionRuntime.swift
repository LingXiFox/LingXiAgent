import Foundation
import LingXiProtocol

/// 一个 Session 的 Lane。
/// 所有该 Session 的状态变化（user append → inference → assistant append）
/// 都在本 actor 内发生：同一 Session 严格保序；
/// 单活动 turn 保护拒绝并发推理（TurnAlreadyRunning）。
/// 不同 Session 各自持有独立 runtime，天然并行。
public actor SessionRuntime {
    private let store: any SessionStore
    private let sessionID: SessionID
    private let modelBus: ModelBus
    private let dataPlane: DataPlane
    private let contextBuilder: SessionContextBuilder
    private let eventSink: @Sendable (CoreEvent) async -> Void

    private var turnRunning = false

    init(
        store: any SessionStore,
        sessionID: SessionID,
        modelBus: ModelBus,
        dataPlane: DataPlane,
        contextBuilder: SessionContextBuilder,
        eventSink: @escaping @Sendable (CoreEvent) async -> Void
    ) {
        self.store = store
        self.sessionID = sessionID
        self.modelBus = modelBus
        self.dataPlane = dataPlane
        self.contextBuilder = contextBuilder
        self.eventSink = eventSink
    }

    /// 启动一轮对话：立即返回 DMA 通道；结果经控制面 turn 事件交付。
    public func startTurn(_ content: String) async throws -> OpenedStream {
        guard !turnRunning else {
            throw CoreError(code: .turnAlreadyRunning, message: "该 Session 已有进行中的对话轮次")
        }
        // 首个 await 前占用 Session Lane，防止 actor 重入让两个 turn 同时穿过 guard。
        turnRunning = true
        do {
            // Session 存在性校验（SessionNotFound）。
            _ = try await store.session(sessionID)

            // 1. user message 先落 Session；后续 Provider / inference 失败时仍保留。
            try await store.appendMessage(sessionID, role: .user, content: content)

            guard let modelID = modelBus.gateway.modelID else {
                throw CoreError(
                    code: .provider,
                    message: "未配置模型 Provider，缺少环境变量: \(modelBus.gateway.missingRequirements.joined(separator: ", "))"
                )
            }

            // 2. Context L1：Session 历史 → 模型输入。
            let session = try await store.session(sessionID)
            let request = ModelRequest(
                model: modelID,
                messages: contextBuilder.buildModelMessages(from: session.messages)
            )

            // 3. 打开 DMA 通道并启动推理。
            let opened = await dataPlane.openAgentStream()
            let handle = TurnHandle(sessionID: sessionID, streamID: opened.stream.id)
            await eventSink(.turnStarted(handle))
            pumpInference(request, handle: handle, sink: opened.sink)
            return opened.stream
        } catch {
            turnRunning = false
            throw error
        }
    }

    // MARK: - Private

    private func pumpInference(
        _ request: ModelRequest,
        handle: TurnHandle,
        sink: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) {
        let modelBus = self.modelBus

        Task {
            var index = 0
            // 本轮内存聚合：实时展示走 DMA，Session 只在完成时写一次。
            var contentBuffer = ""
            var usage: ModelUsage?
            var finishReason: ModelFinishReason?

            func finishTurn(error: CoreError?) {
                // 捕获为 let 再跨 Task 发送，避免可变局部变量被并发捕获。
                let aggregatedContent = contentBuffer
                let aggregatedFinish = finishReason
                let aggregatedUsage = usage
                Task {
                    await self.endTurn(
                        handle: handle,
                        sink: sink,
                        contentBuffer: aggregatedContent,
                        finishReason: aggregatedFinish,
                        usage: aggregatedUsage,
                        error: error
                    )
                }
            }

            do {
                let events = try await modelBus.stream(request)
                for try await event in events {
                    switch event {
                    case .started:
                        break
                    case let .textDelta(text):
                        sink.yield(StreamChunk(streamID: handle.streamID, index: index, text: text, kind: .text))
                        index += 1
                        contentBuffer += text
                    case let .reasoningDelta(text):
                        sink.yield(StreamChunk(streamID: handle.streamID, index: index, text: text, kind: .reasoning))
                        index += 1
                    case let .usage(newUsage):
                        usage = newUsage
                    case let .completed(reason):
                        finishReason = reason
                    case let .failed(error):
                        finishTurn(error: error)
                        return
                    }
                }
                finishTurn(error: nil)
            } catch let error as CoreError {
                finishTurn(error: error)
            } catch {
                finishTurn(error: CoreError(code: .provider, message: String(describing: error)))
            }
        }
    }

    /// turn 收尾：正常完成写一次 assistant message；失败不写虚假完成消息。
    private func endTurn(
        handle: TurnHandle,
        sink: AsyncThrowingStream<StreamChunk, Error>.Continuation,
        contentBuffer: String,
        finishReason: ModelFinishReason?,
        usage: ModelUsage?,
        error: CoreError?
    ) async {
        defer { sink.finish() }
        if let error {
            turnRunning = false
            await eventSink(.turnFailed(TurnFailure(
                sessionID: handle.sessionID,
                streamID: handle.streamID,
                error: error
            )))
            return
        }

        do {
            let message = try await store.appendMessage(
                handle.sessionID, role: .assistant, content: contentBuffer
            )
            turnRunning = false
            await eventSink(.turnCompleted(TurnResult(
                sessionID: handle.sessionID,
                streamID: handle.streamID,
                assistantMessageID: message.id,
                finishReason: finishReason,
                usage: usage
            )))
        } catch let error as CoreError {
            turnRunning = false
            await eventSink(.turnFailed(TurnFailure(
                sessionID: handle.sessionID,
                streamID: handle.streamID,
                error: error
            )))
        } catch {
            turnRunning = false
            await eventSink(.turnFailed(TurnFailure(
                sessionID: handle.sessionID,
                streamID: handle.streamID,
                error: CoreError(code: .transport, message: String(describing: error))
            )))
        }
    }
}
