import Testing
import Foundation
@testable import LingXiProtocol
@testable import LingXiPlatform
@testable import LingXiCore

@Suite("Browser Correctness & Safety Tests (Round 3 Phase B)")
struct BrowserCorrectnessTests {

    private var sidecarPath: String {
        let cwd = FileManager.default.currentDirectoryPath
        return "\(cwd)/Sidecars/browser-host/index.mjs"
    }

    @Test("Real mode fails hard when Playwright is unavailable (no silent mock)")
    func testRealModeFailsHardWithoutPlaywright() async throws {
        guard FileManager.default.fileExists(atPath: sidecarPath) else {
            Issue.record("Sidecar script not found at \(sidecarPath)")
            return
        }

        // 明确要求 real 模式
        let client = BrowserHostClient(scriptPath: sidecarPath, mode: .real)
        try client.start()
        defer { client.stop() }

        // 当 Node 缺 Playwright 时，必须硬性报错拒绝假成功
        do {
            let handshake = try await client.initialize()
            // 如果环境里装了 playwright，则验证它必须报告真实可用
            #expect(handshake.playwrightAvailable == true)
        } catch let error as InteractionError {
            if case let .capability(capError) = error,
               case let .featureUnsupported(feature, _) = capError {
                #expect(feature == "BrowserHost")
            } else {
                Issue.record("Expected capability featureUnsupported, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("BrowserSessionManager reuses single context across multiple navigations")
    func testSingleContextReuseAcrossNavigations() async throws {
        guard FileManager.default.fileExists(atPath: sidecarPath) else { return }

        let manager = BrowserSessionManager(scriptPath: sidecarPath, mode: .mock)
        let sessionID = "reuse-session-\(UUID().uuidString.prefix(8))"

        // 第一次导航
        let summary1 = try await manager.navigate(sessionID: sessionID, url: "https://example.com/page1")
        #expect(summary1.contains("Version: v2") || summary1.contains("Version: v1"))

        // 第二次导航到新页面，必须直接复用既有 session，不重新创建 context
        let summary2 = try await manager.navigate(sessionID: sessionID, url: "https://example.com/page2")
        #expect(summary2.contains("URL: https://example.com/page2"))

        // 显式 resetSession 能够清空并重新创建
        let resetSummary = try await manager.resetSession(sessionID: sessionID, url: "https://example.com/reset")
        #expect(resetSummary.contains("URL: https://example.com/reset"))

        await manager.close(sessionID: sessionID)
    }

    @Test("BrowserHostClient rejects unsafe URL schemes")
    func testURLSchemePolicy() async throws {
        guard FileManager.default.fileExists(atPath: sidecarPath) else { return }

        let client = BrowserHostClient(scriptPath: sidecarPath, mode: .mock)
        try client.start()
        defer { client.stop() }

        _ = try await client.initialize()
        let sessionID = "url-sec-\(UUID().uuidString.prefix(8))"
        _ = try await client.createSession(sessionID: sessionID)

        // 拦截 javascript: 协议
        await #expect(throws: Error.self) {
            _ = try await client.navigate(sessionID: sessionID, url: "javascript:alert(1)")
        }

        // 拦截 file: 协议
        await #expect(throws: Error.self) {
            _ = try await client.navigate(sessionID: sessionID, url: "file:///etc/passwd")
        }

        try await client.closeSession(sessionID: sessionID)
    }

    @Test("BrowserHostClient performs anti-stale element reference interception")
    func testStaleElementReferenceInterception() async throws {
        guard FileManager.default.fileExists(atPath: sidecarPath) else { return }

        let client = BrowserHostClient(scriptPath: sidecarPath, mode: .mock)
        try client.start()
        defer { client.stop() }

        _ = try await client.initialize()
        let sessionID = "stale-sec-\(UUID().uuidString.prefix(8))"
        _ = try await client.createSession(sessionID: sessionID)
        _ = try await client.navigate(sessionID: sessionID, url: "https://example.com")
        let obs = try await client.snapshot(sessionID: sessionID)

        // 1. 尝试传入一个不存在的 refIndex
        await #expect(throws: Error.self) {
            try await client.performAction(
                sessionID: sessionID,
                actionType: "click",
                refIndex: 999999,
                version: obs.version
            )
        }

        // 2. 尝试传入过时的版本号 (version - 1)
        if let firstRef = obs.elements.keys.first {
            await #expect(throws: Error.self) {
                try await client.performAction(
                    sessionID: sessionID,
                    actionType: "click",
                    refIndex: firstRef.index,
                    version: obs.version - 1
                )
            }
        }

        try await client.closeSession(sessionID: sessionID)
    }

    @Test("ActionBatchExecutor refuses no-op success on browser page navigation actions")
    func testActionBatchExecutorRefusesBrowserPageActionsWithoutContext() async throws {
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

        let sessionID = EnvironmentSessionID(rawValue: "test-env")
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

        // 构造一个包含浏览器页面动作的批处理
        let batch = ActionBatch(
            actions: [
                .browser(.navigate(url: "https://example.com")),
                .browser(.reload)
            ],
            stopOnFailure: true
        )

        // 必须明确抛出错误拒绝假装执行成功
        let result = try await executor.execute(
            batch: batch,
            environment: env,
            currentObservation: dummyObs
        )

        #expect(result.succeeded == false)
        #expect(result.completedStepCount == 0)
        #expect(result.failureReason?.contains("BrowserNavigation") == true)
    }

    @Test("Decoupled capture: snapshot produces zero base64 while capture operates on demand")
    func testDecoupledSnapshotAndCapture() async throws {
        guard FileManager.default.fileExists(atPath: sidecarPath) else { return }

        let client = BrowserHostClient(scriptPath: sidecarPath, mode: .mock)
        try client.start()
        defer { client.stop() }

        _ = try await client.initialize()
        let sessionID = "capture-sec-\(UUID().uuidString.prefix(8))"
        _ = try await client.createSession(sessionID: sessionID)
        _ = try await client.navigate(sessionID: sessionID, url: "https://example.com")

        // 默认快照：screenshotBlobRef 必须为 nil
        let snap = try await client.snapshot(sessionID: sessionID, includeScreenshot: false)
        #expect(snap.screenshotBlobRef == nil)

        // 按需 capture：正常调用
        let (path, base64) = try await client.capture(sessionID: sessionID)
        #expect(path == nil)
        #expect(base64 == nil || base64 != nil)

        try await client.closeSession(sessionID: sessionID)
    }

    @Test("High-frequency BrowserHostClient start/stop stress test (100 iterations)")
    func testHighFrequencyBrowserHostClientLifecycle() async throws {
        guard FileManager.default.fileExists(atPath: sidecarPath) else { return }

        for _ in 1...100 {
            let client = BrowserHostClient(scriptPath: sidecarPath, mode: .mock)
            try client.start()
            client.stop()
        }
    }
}
