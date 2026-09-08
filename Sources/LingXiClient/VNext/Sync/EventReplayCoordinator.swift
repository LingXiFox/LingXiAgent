import Foundation
import LingXiProtocol

public enum ReplayState: Sendable, Equatable {
    case live
    case replaying(from: EventCursor)
    case snapshotFallback(cursor: EventCursor)
}

/// EventReplayCoordinator：管理 Runtime 与 Session 事件流的订阅、Replay 断点续传、Stream delivery barrier 与 Snapshot fallback。
public actor EventReplayCoordinator {
    private let transport: any ClientTransport
    private let sync: WatermarkSynchronizer
    private let streamBuffer: StreamFrameReorderBuffer

    private var lastRuntimeCursor: EventCursor?
    private var lastSessionCursors: [SessionID: EventCursor] = [:]

    // 记录进行中的 stream 映射，用于 terminal delivery barrier 校验
    private var assistantStreams: [MessageID: StreamID] = [:]
    private var toolStreams: [ToolCallID: (stdout: StreamID?, stderr: StreamID?)] = [:]
    private var reasoningStreams: [ModelStepID: StreamID] = [:]

    public init(
        transport: any ClientTransport,
        sync: WatermarkSynchronizer,
        streamBuffer: StreamFrameReorderBuffer = StreamFrameReorderBuffer()
    ) {
        self.transport = transport
        self.sync = sync
        self.streamBuffer = streamBuffer
    }

    public func getLastRuntimeCursor() -> EventCursor? {
        lastRuntimeCursor
    }

    public func getLastSessionCursor(for sessionID: SessionID) -> EventCursor? {
        lastSessionCursors[sessionID]
    }

    /// 订阅 Runtime 事件并自动追踪游标与同步水位线
    public func subscribeRuntimeEvents(after: EventCursor? = nil) async -> AsyncStream<RuntimeEventEnvelope> {
        let startCursor = after ?? lastRuntimeCursor
        let rawStream = await transport.subscribeRuntimeEvents(after: startCursor)

        await sync.markScopeSubscribed(.runtime)

        let (stream, continuation) = AsyncStream.makeStream(of: RuntimeEventEnvelope.self)
        let sync = self.sync

        Task { [weak self] in
            for await envelope in rawStream {
                guard let self else { return }
                if let last = await self.getLastRuntimeCursor(), envelope.cursor <= last {
                    // 去重：忽略已递交过的旧游标事件
                    continue
                }
                await self.recordRuntimeEnvelope(envelope)
                continuation.yield(envelope)
            }
            await sync.markScopeUnsubscribed(.runtime)
            continuation.finish()
        }

        return stream
    }

    private func recordRuntimeEnvelope(_ envelope: RuntimeEventEnvelope) async {
        lastRuntimeCursor = envelope.cursor
        await sync.recordObserved(scope: .runtime, cursor: envelope.cursor)
    }

    /// 订阅 Session 事件，支持断线重放、去重、Stream finalIndex barrier 与 Snapshot fallback
    public func subscribeSessionEvents(
        sessionID: SessionID,
        after: EventCursor? = nil,
        enforceStreamBarrier: Bool = true
    ) async throws -> AsyncStream<SessionEventEnvelope> {
        let (stream, continuation) = AsyncStream.makeStream(of: SessionEventEnvelope.self)

        await sync.markScopeSubscribed(.session(sessionID))
        let sync = self.sync
        let transport = self.transport

        Task { [weak self] in
            var currentCursor = after
            if currentCursor == nil { currentCursor = await self?.getLastSessionCursor(for: sessionID) }

            var shouldRetry = true
            while shouldRetry && !Task.isCancelled {
                do {
                    let rawStream = try await transport.subscribeSessionEvents(sessionID: sessionID, after: currentCursor)
                    for await envelope in rawStream {
                        guard let self else { return }
                        if let last = await self.getLastSessionCursor(for: sessionID), envelope.cursor <= last {
                            // 不重：丢弃重放区间内已消费过的重复事件
                            continue
                        }

                        if enforceStreamBarrier {
                            await self.applyDeliveryBarrierIfNeeded(envelope: envelope)
                        }

                        await self.recordSessionEnvelope(sessionID: sessionID, envelope: envelope)
                        continuation.yield(envelope)
                    }
                    // 正常结束（非异常终止）
                    shouldRetry = false
                } catch {
                    // 当 Replay 失败（如 disconnect、generation mismatch、replayUnavailable 等），触发 Snapshot Fallback
                    do {
                        guard let self else { return }
                        let snapshot = try await self.fallbackToSnapshot(sessionID: sessionID)
                        currentCursor = snapshot.eventCursor
                        // 循环重新订阅
                    } catch {
                        shouldRetry = false
                    }
                }
            }

            await sync.markScopeUnsubscribed(.session(sessionID))
            continuation.finish()
        }

        return stream
    }

    /// 执行 Snapshot Fallback：拉取权威快照并重置游标基线
    @discardableResult
    public func fallbackToSnapshot(sessionID: SessionID) async throws -> SessionSnapshot {
        let snapResp = try await transport.getSessionSnapshot(envelope: QueryEnvelope(payload: GetSessionSnapshotRequest(sessionID: sessionID)))
        let snapshot = snapResp.payload
        lastSessionCursors[sessionID] = snapshot.eventCursor
        await sync.resetCursor(for: .session(sessionID), to: snapshot.eventCursor)
        return snapshot
    }

    private func recordSessionEnvelope(sessionID: SessionID, envelope: SessionEventEnvelope) async {
        lastSessionCursors[sessionID] = envelope.cursor
        await sync.recordObserved(scope: .session(sessionID), cursor: envelope.cursor)

        switch envelope.payload {
        case let .assistantMessageStarted(messageID, streamID):
            assistantStreams[messageID] = streamID
        case let .modelStepStarted(stepID, visibleReasoningStreamID, _):
            if let reasoningStreamID = visibleReasoningStreamID {
                reasoningStreams[stepID] = reasoningStreamID
            }
        case let .toolRunning(callID, stdoutStreamID, stderrStreamID):
            toolStreams[callID] = (stdoutStreamID, stderrStreamID)
        default:
            break
        }
    }

    private func applyDeliveryBarrierIfNeeded(envelope: SessionEventEnvelope) async {
        switch envelope.payload {
        case let .assistantMessageCommitted(messageID, content, assistantFinalIndex):
            if let streamID = assistantStreams[messageID] {
                do {
                    try await streamBuffer.awaitFinalIndex(streamID: streamID, finalIndex: assistantFinalIndex, timeout: 0.1)
                } catch {
                    // 缺帧或发生断线：首先尝试通过 transport.subscribeStreamFrames(afterIndex:) 补洞
                    var replayedSuccessfully = false
                    let highest = await streamBuffer.highestDeliveredIndex(for: streamID)
                    if let rawReplay = try? await transport.subscribeStreamFrames(streamID: streamID, afterIndex: highest) {
                        for await frame in rawReplay {
                            await streamBuffer.pushFrame(frame)
                            if frame.index >= assistantFinalIndex { break }
                        }
                        if (try? await streamBuffer.awaitFinalIndex(streamID: streamID, finalIndex: assistantFinalIndex, timeout: 0.1)) != nil {
                            replayedSuccessfully = true
                        }
                    }

                    // 如果 stream 不可 replay，必须 fallback 权威 committed content 恢复，绝不永久等待 barrier
                    if !replayedSuccessfully {
                        await streamBuffer.resyncWithCanonicalCommittedContent(
                            streamID: streamID,
                            canonicalContent: content,
                            finalIndex: assistantFinalIndex
                        )
                    }
                }
            }

        case let .modelStepCompleted(stepID, visibleReasoningFinalIndex, _):
            if let finalIndex = visibleReasoningFinalIndex, let streamID = reasoningStreams[stepID] {
                try? await streamBuffer.awaitFinalIndex(streamID: streamID, finalIndex: finalIndex, timeout: 0.1)
            }

        case let .toolCompleted(callID, result, stdoutFinalIndex, stderrFinalIndex):
            if let streams = toolStreams[callID] {
                if let stdoutIndex = stdoutFinalIndex, let stdoutStream = streams.stdout {
                    do {
                        try await streamBuffer.awaitFinalIndex(streamID: stdoutStream, finalIndex: stdoutIndex, timeout: 0.1)
                    } catch {
                        await streamBuffer.resyncWithCanonicalCommittedContent(
                            streamID: stdoutStream,
                            canonicalContent: result.summary,
                            finalIndex: stdoutIndex
                        )
                    }
                }
                if let stderrIndex = stderrFinalIndex, let stderrStream = streams.stderr {
                    try? await streamBuffer.awaitFinalIndex(streamID: stderrStream, finalIndex: stderrIndex, timeout: 0.1)
                }
            }

        default:
            break
        }
    }
}
