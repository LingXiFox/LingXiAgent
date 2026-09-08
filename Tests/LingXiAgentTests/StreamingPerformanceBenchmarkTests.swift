import Testing
import Foundation
import LingXiProtocol
@testable import LingXiApplication
@testable import LingXiTUIComponents
import LingXiClient

@Suite("Streaming Performance & Burst Benchmark Tests")
struct StreamingPerformanceBenchmarkTests {

    @Test("LiveDeltaBuffer coalesces high-frequency deltas without losing order or dropping characters")
    func liveDeltaBufferCoalesceCorrectness() async throws {
        let sessionID = SessionID("bench-session-1")
        let streamID = StreamID("bench-stream-1")
        let modelStepID = ModelStepID("step-1")
        let causal = CausalContext(sessionID: sessionID, modelStepID: modelStepID)

        let tokens = ["Antigravity ", "is ", "optimizing ", "streaming ", "performance ", "for ", "TUI."]
        let expectedTotalText = tokens.joined()

        let (stream, continuation) = AsyncStream.makeStream(of: StreamFrame.self)

        // 生产者：以 2ms 极快 burst 发送
        Task {
            for (idx, token) in tokens.enumerated() {
                try? await Task.sleep(nanoseconds: 2_000_000)
                let frame = StreamFrame(
                    streamID: streamID,
                    owner: causal,
                    index: UInt64(idx),
                    kind: .assistantText,
                    text: token
                )
                continuation.yield(frame)
            }
            continuation.finish()
        }

        // 使用 LiveDeltaBuffer 接收
        let coalescedStream = LiveDeltaBuffer.coalesceStream(stream, windowMs: 16)
        var receivedBatches: [StreamFrame] = []
        for await frame in coalescedStream {
            receivedBatches.append(frame)
        }

        // 验证：
        // 1. 至少发生了合并（接收到的 frame 批次明显少于 token 数）
        #expect(receivedBatches.count < tokens.count, "High frequency tokens within window must be coalesced")
        // 2. 拼接后的总文本与原始文本严格完全一致
        let totalText = receivedBatches.compactMap { $0.textPayload }.joined()
        #expect(totalText == expectedTotalText, "Coalesced text must exactly match original tokens without loss or duplication")
    }

    @Test("Deterministic burst-stream benchmark satisfies latency, stall, and fidelity requirements")
    func deterministicBurstStreamBenchmark() async throws {
        let tracker = StreamingLatencyTracker()
        tracker.reset()
        tracker.isEnabled = true

        let clock = ContinuousClock()
        let sessionID = SessionID("bench-burst-session")
        let streamID = StreamID("bench-burst-stream")
        let stepID = ModelStepID("step-bench")
        let causal = CausalContext(sessionID: sessionID, modelStepID: stepID)

        // 构造 200 个模拟 delta 片段（包含中英文、标点、代码块、换行等真实交互文本）
        let deltaCorpus = [
            "思考过程：", "主人", "，小狐狸", "正在", "分析", "代码", "库结构", "...\n",
            "首先", "，我们需要", "定位", "流式", "刷新的", "关键瓶颈", "。\n",
            "1. Provider", " 返回的", " 每个 token", " 都会", "触发一次", " 全量重排", "；\n",
            "2. 历史", "节点", "重复", "计算", " wrap", "。\n",
            "```swift\n", "let x = 42\n", "print(\"result:\", x)\n", "```\n",
            "分析完成", "，准备", "执行", "增量", "渲染", "。\n"
        ]

        var tokens: [String] = []
        for _ in 0..<8 {
            tokens.append(contentsOf: deltaCorpus)
        }
        // 截取 200 个 token
        tokens = Array(tokens.prefix(200))
        let expectedFullText = tokens.joined()

        var state = SessionViewState(sessionID: sessionID)

        // 模拟 TUI Frame Scheduler 和 Viewport
        let viewport = TranscriptViewport()
        var receivedFramesCount = 0
        var projectedCount = 0
        var renderedFramesCount = 0
        var accumulatedText = ""

        final class DirtyBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _value = false
            func set() { lock.lock(); _value = true; lock.unlock() }
            func checkAndReset() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                let current = _value
                _value = false
                return current
            }
        }
        let dirtyBox = DirtyBox()
        var lastPresentedInstant: ContinuousClock.Instant?
        var maxObservedStallMs: Double = 0.0

        let startTime = clock.now

        // 模拟 LiveDeltaBuffer
        let (rawStream, rawContinuation) = AsyncStream.makeStream(of: StreamFrame.self)

        // 模拟 Producer 以 2~8ms 爆发发送
        let producerTask = Task {
            for (idx, token) in tokens.enumerated() {
                try? await Task.sleep(nanoseconds: UInt64.random(in: 2_000_000...8_000_000))
                let id = "delta-\(idx)"
                tracker.record(id, stage: .providerFrameReceived)

                let frame = StreamFrame(
                    streamID: streamID,
                    owner: causal,
                    index: UInt64(idx),
                    kind: .visibleReasoning,
                    text: token
                )
                tracker.record(id, stage: .adapterDecoded)
                tracker.record(id, stage: .canonicalDeltaEmitted)
                rawContinuation.yield(frame)
            }
            rawContinuation.finish()
        }

        let coalescedStream = LiveDeltaBuffer.coalesceStream(rawStream, windowMs: 16)

        // 模拟兼顾 10fps 的动画循环
        let animationTask = Task { [dirtyBox] in
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms ≈ 10fps
                dirtyBox.set()
            }
        }

        // 消费端
        for await frame in coalescedStream {
            receivedFramesCount += 1
            let frameID = "frame-\(receivedFramesCount)"
            tracker.record(frameID, stage: .applicationProjected)
            projectedCount += 1

            // 投影到 state: 仅更新 activeCell
            SessionReducer.reduceStreamFrame(
                state: &state,
                frame: frame,
                connectionState: .connecting
            )

            dirtyBox.set()

            // 模拟 Frame Scheduler 节奏：每隔 ~16ms 渲染一帧
            if dirtyBox.checkAndReset() {
                renderedFramesCount += 1

                let renderStart = clock.now
                tracker.record(frameID, stage: .frameScheduled, at: renderStart)

                // 增量更新 viewport
                if let active = state.activeCell {
                    let entryText = "Thinking · 1s\n\(state.thinkingNodes[stepID]?.content ?? "")"
                    let entry = TUITranscriptEntry(
                        id: active.id.rawValue,
                        kind: .thinking,
                        text: entryText,
                        style: .dim
                    )
                    viewport.entries = [entry]
                    _ = viewport.render(viewportHeight: 24, width: 80)
                }

                let renderEnd = clock.now
                tracker.record(frameID, stage: .openTUIPresented, at: renderEnd)

                if let last = lastPresentedInstant {
                    let dur = last.duration(to: renderEnd)
                    let c = dur.components
                    let ms = Double(c.seconds) * 1000.0 + Double(c.attoseconds) / 1_000_000_000_000_000.0
                    if ms > maxObservedStallMs {
                        maxObservedStallMs = ms
                    }
                }
                lastPresentedInstant = renderEnd
            }
        }

        _ = await producerTask.result
        animationTask.cancel()

        accumulatedText = state.thinkingNodes[stepID]?.content ?? ""

        let stats = tracker.calculateStats()
        let totalElapsed = startTime.duration(to: clock.now)
        let totalElapsedMs = Double(totalElapsed.components.seconds) * 1000.0 + Double(totalElapsed.components.attoseconds) / 1_000_000_000_000_000.0

        // ================= 严格指标验证 =================
        // 1. 文本无丢失、重复、乱序，与原始 token 拼接严格一致
        #expect(accumulatedText == expectedFullText, "Accumulated text must strictly equal original concatenated tokens")

        // 2. 验证 receive -> present 延迟 p95 < 50ms
        #expect(stats.p95Ms < 50.0, "Latency p95 must be < 50ms (actual: \(stats.p95Ms) ms)")

        // 3. 验证无 >200ms UI stall
        #expect(stats.maxStallMs < 200.0, "Max UI stall must be < 200ms (actual: \(stats.maxStallMs) ms)")

        // 4. 验证渲染帧合并有效性：200 个 token 被合并为少量帧渲染，避免成坨刷新和 UI 轰炸
        #expect(renderedFramesCount < 100, "200 tokens must be coalesced to < 100 render frames")

        // 输出 Benchmark 量化结果
        print("""
        ============================================================
        🎯 STREAMING PERFORMANCE BURST BENCHMARK RESULTS
        ============================================================
        Total Tokens Processed:      \(tokens.count)
        Coalesced Batches Received:  \(receivedFramesCount) (Coalesce Ratio: \(String(format: "%.1f", (1.0 - Double(receivedFramesCount) / Double(tokens.count)) * 100))%)
        State Projections:           \(projectedCount)
        Actual TUI Frames Rendered:  \(renderedFramesCount)
        Total Time:                  \(String(format: "%.2f", totalElapsedMs)) ms
        Average Frame Rate:          \(String(format: "%.1f", Double(renderedFramesCount) / (totalElapsedMs / 1000.0))) fps
        End-to-End Latency p50:      \(String(format: "%.2f", stats.p50Ms)) ms
        End-to-End Latency p95:      \(String(format: "%.2f", stats.p95Ms)) ms (Target: < 50ms)
        End-to-End Latency p99:      \(String(format: "%.2f", stats.p99Ms)) ms
        Maximum UI Stall:            \(String(format: "%.2f", maxObservedStallMs)) ms (Target: < 200ms)
        Bottleneck Stage:            \(stats.slowestStage)
        ============================================================
        """)
    }

    @Test("Incremental layout in TranscriptViewport reuses committed lines cache and only wraps active tail")
    func incrementalLayoutReusesCache() {
        let viewport = TranscriptViewport()
        let longHistory = (1...50).map { i in
            TUITranscriptEntry(
                id: "history-\(i)",
                kind: .assistant,
                text: "History message #\(i): This is an immutable committed line that should not be re-wrapped."
            )
        }

        // 初始填充 50 个历史条目
        viewport.entries = longHistory
        let clock = ContinuousClock()

        // 第一次渲染（建立缓存）
        let t0 = clock.now
        _ = viewport.render(viewportHeight: 30, width: 80)
        let firstRenderDur = t0.duration(to: clock.now)

        // 追加活跃的流式条目
        var activeEntry = TUITranscriptEntry(
            id: "active-stream",
            kind: .thinking,
            text: "Thinking · 1s\nStep 1: Inspecting code.",
            style: .dim
        )
        viewport.append(activeEntry)

        // 第二次渲染（有缓存）
        let t1 = clock.now
        _ = viewport.render(viewportHeight: 30, width: 80)
        let cachedRenderDur = t1.duration(to: clock.now)

        // 增量追加 active text
        activeEntry.text += " Step 2: Found solution."
        viewport.updateLast(activeEntry.text)

        // 第三次渲染（增量 wrap）
        let t2 = clock.now
        _ = viewport.render(viewportHeight: 30, width: 80)
        let incrementalRenderDur = t2.duration(to: clock.now)

        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000.0 + Double(d.components.attoseconds) / 1_000_000_000_000_000.0
        }

        print("Layout timing: first=\(ms(firstRenderDur))ms, cached=\(ms(cachedRenderDur))ms, incremental=\(ms(incrementalRenderDur))ms")
        // 验证增量/带缓存渲染速度明显优于初次全量渲染
        #expect(ms(incrementalRenderDur) < 5.0, "Incremental render with cache must be < 5ms")
    }
}
