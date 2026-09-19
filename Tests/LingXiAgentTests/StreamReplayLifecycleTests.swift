import Foundation
import Testing
@testable import LingXiCore
@testable import LingXiClient
@testable import LingXiProtocol

@Suite("Stream Replay Lifecycle Tests (Round 2 Phase C)")
struct StreamReplayLifecycleTests {

    @Test("Core SessionTurnCoordinator: 100 consecutive turns enforce bounded resident frame payload")
    func testCoreSessionCoordinator100TurnsBoundedResidentFrames() async throws {
        let sessionID = SessionID("sess-lifecycle-core")
        let eventLog = SessionEventLog(sessionID: sessionID)
        let coordinator = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        let totalTurns = 100
        let framesPerTurn: UInt64 = 50

        var streamIDs: [StreamID] = []

        for turnIndex in 0..<totalTurns {
            let runID = RunID("run-\(turnIndex)")
            let stepID = ModelStepID("step-\(turnIndex)")

            let (messageID, streamID) = await coordinator.beginAssistantStream(stepID: stepID, runID: runID)
            streamIDs.append(streamID)

            let causal = CausalContext(sessionID: sessionID, runID: runID, modelStepID: stepID)

            // Emit frames 0 through 49
            for frameIdx in 0..<framesPerTurn {
                let frame = StreamFrame(
                    streamID: streamID,
                    owner: causal,
                    index: frameIdx,
                    kind: .assistantText,
                    text: "chunk_\(frameIdx) "
                )
                _ = try await coordinator.emitStreamFrame(frame: frame)
            }

            // Commit assistant message and close stream
            await coordinator.commitAssistantMessage(
                messageID: messageID,
                streamID: streamID,
                causal: causal,
                content: "Full content of turn \(turnIndex)",
                finalIndex: framesPerTurn - 1
            )
        }

        let state = await coordinator.currentStreamReplayState

        // 验证 1：100 轮长回答（共 5000 帧）后，resident raw frames 保持在上限（<= 8 个流 * 50 帧 = 400 帧）
        let retainedFrames = state.retainedFrameCount
        #expect(retainedFrames <= 8 * Int(framesPerTurn))
        #expect(retainedFrames > 0) // 最近几个仍保留供短期回放

        // 验证 2：已有至少 92 个流被驱逐了 raw delta payload
        #expect(state.evictedStreamsCount >= totalTurns - 8)

        // 验证 3：对已淘汰的早期流进行订阅，应立即 finish，绝不挂起或卡死
        if let firstStreamID = streamIDs.first {
            let replayStream = await coordinator.subscribeStream(streamID: firstStreamID, afterIndex: 0)
            var collected: [StreamFrame] = []
            for await frame in replayStream {
                collected.append(frame)
            }
            #expect(collected.isEmpty)
        }

        // 验证 4：对最新保留的流进行订阅，仍能正常回放
        if let lastStreamID = streamIDs.last {
            let replayStream = await coordinator.subscribeStream(streamID: lastStreamID, afterIndex: 40)
            var collected: [StreamFrame] = []
            for await frame in replayStream {
                collected.append(frame)
            }
            #expect(collected.count == 9) // 41...49
        }
    }

    @Test("Client StreamFrameReorderBuffer: 100 consecutive terminal streams evict older deliveredFrames")
    func testClientReorderBuffer100StreamsTerminalEviction() async throws {
        let buffer = StreamFrameReorderBuffer(
            maxRetainedTerminalStreamsWithFrames: 8,
            maxRetainedTerminalStreamMetadata: 64
        )

        let totalStreams = 100
        let framesPerStream: UInt64 = 40
        let causal = CausalContext(sessionID: SessionID("sess-client-buffer"))

        var createdStreams: [StreamID] = []

        for sIndex in 0..<totalStreams {
            let streamID = StreamID("stream-\(sIndex)")
            createdStreams.append(streamID)

            // Push frames 0...39
            for fIndex in 0..<framesPerStream {
                let frame = StreamFrame(
                    streamID: streamID,
                    owner: causal,
                    index: fIndex,
                    kind: .assistantText,
                    text: "delta_\(fIndex) "
                )
                await buffer.pushFrame(frame)
            }

            // Await terminal finalIndex to trigger terminal lifecycle
            try await buffer.awaitFinalIndex(streamID: streamID, finalIndex: framesPerStream - 1, timeout: 1.0)
        }

        // 验证 1：100 个流（共 4000 帧）后，客户端保留的 raw deliveredFrames 严格有界（<= 8 * 40 = 320 帧）
        let retainedCount = await buffer.retainedDeliveredFrameCount
        #expect(retainedCount <= 8 * Int(framesPerStream))

        // 验证 2：被淘汰 raw payload 的终态流数至少为 64 - 8 = 56 个（元数据保留 64 个）
        let evictedCount = await buffer.evictedStreamsCount
        #expect(evictedCount >= 56)

        // 验证 3：最老且未被彻底驱逐的流的 raw frames 已被释放为 []
        let earlyStreamID = createdStreams[createdStreams.count - 40]
        let earlyDelivered = await buffer.deliveredFrames(for: earlyStreamID)
        #expect(earlyDelivered.isEmpty)

        // 验证 4：最新的流其 deliveredFrames 仍然完整存在
        let latestStreamID = try #require(createdStreams.last)
        let latestDelivered = await buffer.deliveredFrames(for: latestStreamID)
        #expect(latestDelivered.count == Int(framesPerStream))
    }

    @Test("Core SessionTurnCoordinator: resetForRevert completely purges all stream lifecycle state")
    func testResetForRevertCompletePurge() async throws {
        let sessionID = SessionID("sess-revert-purge")
        let eventLog = SessionEventLog(sessionID: sessionID)
        let coordinator = SessionTurnCoordinator(sessionID: sessionID, eventLog: eventLog)

        let runID = RunID("run-active")
        let stepID = ModelStepID("step-active")
        let (_, streamID) = await coordinator.beginAssistantStream(stepID: stepID, runID: runID)

        let causal = CausalContext(sessionID: sessionID, runID: runID, modelStepID: stepID)
        let frame = StreamFrame(streamID: streamID, owner: causal, index: 0, kind: .assistantText, text: "A")
        _ = try await coordinator.emitStreamFrame(frame: frame)

        // Subscribe to stream
        let stream = await coordinator.subscribeStream(streamID: streamID, afterIndex: nil)
        let subscriberTask = Task {
            var count = 0
            for await _ in stream {
                count += 1
            }
            return count
        }

        // Verify active stream exists
        #expect(await coordinator.hasStream(streamID))

        // Execute resetForRevert
        try await coordinator.resetForRevert(remainingMessages: [])

        // The subscriber should have finished promptly
        let count = await subscriberTask.value
        #expect(count == 1) // read frame 0, then finished on reset

        // All stream lifecycle state is 100% reset
        let state = await coordinator.currentStreamReplayState
        #expect(state.retainedFrameCount == 0)
        #expect(state.activeStreamCount == 0)
        #expect(state.evictedStreamsCount == 0)
        #expect(await coordinator.hasStream(streamID) == false)
    }

    @Test("StreamReplayState: TTL and grace period automatically evicts closed stream payload")
    func testStreamReplayStateTTLGracePeriodEviction() async throws {
        var state = StreamReplayState(
            maxRetainedClosedStreamsWithFrames: 8,
            replayGracePeriod: 0.05 // 50ms grace period
        )

        let streamID = StreamID("stream-grace")
        let causal = CausalContext(sessionID: SessionID("sess-grace"))

        state.recordKnownStream(streamID)
        try state.emitFrame(StreamFrame(streamID: streamID, owner: causal, index: 0, kind: .assistantText, text: "hello"))
        #expect(state.retainedFrameCount == 1)

        state.closeStream(streamID: streamID, finalIndex: 0)
        #expect(state.retainedFrameCount == 1) // Initially retained

        // Sleep to exceed grace period
        try await Task.sleep(nanoseconds: 70_000_000) // 70ms

        state.pruneClosedStreams()
        // Payload should now be evicted
        #expect(state.retainedFrameCount == 0)
        #expect(state.evictedStreamsCount == 1)
        #expect(state.terminalIndex(for: streamID) == 0) // Final index metadata preserved
    }
}
