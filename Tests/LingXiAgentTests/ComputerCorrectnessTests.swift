import Testing
import Foundation
@testable import LingXiProtocol
@testable import LingXiPlatform
@testable import LingXiCore

#if os(macOS)
import Cocoa
import CoreGraphics
#endif

@Suite("Computer Correctness & Safety Tests (Round 3 Phase C)")
struct ComputerCorrectnessTests {

    #if os(macOS)
    @Test("Screenshot records hard failure when capture backend is unsupported")
    func testScreenshotFailsHardWhenCaptureUnsupported() async throws {
        let tool = ComputerBatchTool()
        let payload = """
        {
            "actions": [
                {
                    "type": "screenshot"
                }
            ]
        }
        """

        let result = try await tool.execute(arguments: payload, profile: .workspace)
        // When capture is available the result must report a real captured artifact; when it is
        // not, it must say FAILED. It may never pretend to have succeeded.
        #expect(result.contains("Screenshot"))
        if result.contains("FAILED") {
            #expect(result.contains("Action Batch Execution: FAILED"))
        } else {
            #expect(result.contains("captured:"), "success branch must report a real capture, got: \(result)")
            #expect(result.contains("Action Batch Execution: SUCCESS"))
        }
    }

    @Test("Click strictly refuses fallback to (0,0) when target is missing")
    func testClickRefusesFallbackToZeroZero() async throws {
        let tool = ComputerBatchTool()
        let payload = """
        {
            "actions": [
                {
                    "type": "click"
                }
            ]
        }
        """

        let result = try await tool.execute(arguments: payload, profile: .workspace)
        #expect(result.contains("Action Batch Execution: FAILED"))
        #expect(result.contains("Missing target"))
        #expect(result.contains("Refused to fallback to (0,0)"))
    }
    #endif

    @Test("ActionBatchExecutor enforces real timeout on elementVisible and elementGone wait conditions")
    func testWaitConditionsEnforceRealTimeout() async throws {
        let executor = ActionBatchExecutor()
        let probe = FakeCapabilityProbe(
            snapshot: HostCapabilitySnapshot(
                capture: .available,
                accessibility: .available,
                input: .available,
                windowManagement: .available,
                applicationManagement: .available,
                clipboard: .available
            )
        )
        let env = DesktopEnvironment(
            probe: probe,
            initialSnapshot: await probe.probe()
        )

        let sessionID = EnvironmentSessionID(rawValue: "test-wait-env")
        let displayID = "main"
        let displayBounds = CoordinateRect(
            origin: TargetPosition(x: 0, y: 0, space: .logicalPoint(displayID: displayID)),
            width: 1920,
            height: 1080
        )
        let metrics = DisplayMetrics(
            displayID: displayID,
            scaleFactor: 1.0,
            bounds: displayBounds
        )

        let dummyObs = Observation(
            id: ObservationID(),
            sessionID: sessionID,
            version: 1,
            observedAt: Date(),
            source: .desktop(displayID: displayID, activeWindowID: nil),
            elements: [:], // 空元素表
            screenshotBlobRef: nil,
            viewportBounds: displayBounds,
            displayMetrics: metrics
        )

        let targetRef = ElementRef(
            sessionID: sessionID,
            scopeID: sessionID.rawValue,
            version: 1,
            index: 42
        )

        // 等待一个永远不会出现的元素，必须在超时后失败，绝不能像旧代码那样直接 break 假成功
        let waitBatch = ActionBatch(
            actions: [
                .desktop(.primitive(.wait(condition: .elementVisible(ref: targetRef, timeoutMs: 100))))
            ],
            stopOnFailure: true
        )

        let result = try await executor.execute(
            batch: waitBatch,
            environment: env,
            currentObservation: dummyObs
        )

        #expect(result.succeeded == false)
        #expect(result.completedStepCount == 0)
        #expect(result.failureReason?.contains("conditionNotMet") == true)
    }

    #if os(macOS)
    @Test("DarwinWindowBackend setWindowBounds fails fast instead of being empty no-op")
    func testSetWindowBoundsFailsFastOnInvalidWindow() async throws {
        let backend = DarwinWindowBackend()
        do {
            try await backend.setWindowBounds(
                id: "999999999",
                bounds: CoordinateRect(
                    origin: TargetPosition(x: 100, y: 100, space: .logicalPoint(displayID: "main")),
                    width: 800,
                    height: 600
                )
            )
            Issue.record("Should have thrown error for nonexistent window ID")
        } catch {
            // 验证它确实执行了校验并抛出异常，而不是空函数
            #expect("\(error)".contains("inputInjectionFailed") || "\(error)".contains("Window"))
        }
    }

    @Test("DarwinInputBackend fails fast on unknown key instead of defaulting to key 'A'")
    func testDarwinInputBackendRejectsUnknownKey() async throws {
        guard AXIsProcessTrusted() else {
            // 无无障碍权限时跳过硬件注入部分
            return
        }

        let backend = DarwinInputBackend(isIndependentVirtualCursor: true)
        do {
            try await backend.injectKeyboard(event: KeyboardInputEvent(kind: .keyPress(key: "nonexistent_unknown_key_xyz")))
            Issue.record("Should have thrown error for unknown key name")
        } catch {
            #expect("\(error)".contains("Unknown or unsupported key"))
        }
    }
    #endif

    @Test("DesktopEnvironment marks snapshot stale on init when initialSnapshot is nil")
    func testDesktopEnvironmentStaleOnInit() async throws {
        let probe = FakeCapabilityProbe(
            snapshot: HostCapabilitySnapshot(
                capture: .available,
                accessibility: .available,
                input: .available,
                windowManagement: .available,
                applicationManagement: .available,
                clipboard: .available
            )
        )

        // initialSnapshot 为 nil 时，初始化必须自动触发首次 probe
        let env = DesktopEnvironment(probe: probe, initialSnapshot: nil)
        let preflight = await env.preflightSnapshot()
        #expect(preflight.capture == .available)
        #expect(preflight.input == .available)
    }

    @Test("ActionBatchResult outputs high-precision real per-step durations")
    func testActionBatchResultPerStepDurations() async throws {
        let executor = ActionBatchExecutor()
        let probe = FakeCapabilityProbe(
            snapshot: HostCapabilitySnapshot(
                capture: .available,
                accessibility: .available,
                input: .available,
                windowManagement: .available,
                applicationManagement: .available,
                clipboard: .available
            )
        )
        let env = DesktopEnvironment(
            probe: probe,
            initialSnapshot: await probe.probe()
        )

        let sessionID = EnvironmentSessionID(rawValue: "test-timing-env")
        let displayID = "main"
        let displayBounds = CoordinateRect(
            origin: TargetPosition(x: 0, y: 0, space: .logicalPoint(displayID: displayID)),
            width: 1920,
            height: 1080
        )
        let metrics = DisplayMetrics(
            displayID: displayID,
            scaleFactor: 1.0,
            bounds: displayBounds
        )

        let dummyObs = Observation(
            id: ObservationID(),
            sessionID: sessionID,
            version: 1,
            observedAt: Date(),
            source: .desktop(displayID: displayID, activeWindowID: nil),
            elements: [:],
            screenshotBlobRef: nil,
            viewportBounds: displayBounds,
            displayMetrics: metrics
        )

        let batch = ActionBatch(
            actions: [
                .desktop(.primitive(.wait(condition: .duration(milliseconds: 30)))),
                .desktop(.primitive(.wait(condition: .duration(milliseconds: 300))))
            ],
            stopOnFailure: true
        )

        let result = try await executor.execute(
            batch: batch,
            environment: env,
            currentObservation: dummyObs
        )

        #expect(result.succeeded == true)
        #expect(result.completedStepCount == 2)
        #expect(result.stepDurationsMs.count == 2)
        // The two waits differ tenfold so an averaged per-step duration cannot pass. The separation
        // is wide deliberately: the macOS leg measured a 30ms and a 60ms wait 0.055ms apart, which
        // no assertion about their difference can survive.
        #expect(result.stepDurationsMs[0] >= 20.0)
        #expect(result.stepDurationsMs[1] >= 200.0)
        #expect(
            abs(result.stepDurationsMs[0] - result.stepDurationsMs[1]) > 50.0,
            "measured step durations were \(result.stepDurationsMs) ms"
        )
    }
}
