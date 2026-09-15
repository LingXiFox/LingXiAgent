import Testing
import Foundation
@testable import LingXiProtocol
@testable import LingXiPlatform
@testable import LingXiCore

// MARK: - Fake Backends for Unit Testing

final class FakeAccessibilityBackend: AccessibilityBackend, @unchecked Sendable {
    var nodes: [AccessibilityNodeSnapshot] = []
    var performedActions: [(String, AccessibilityAction)] = []

    func fetchTree(scope: AccessibilityScope) async throws -> [AccessibilityNodeSnapshot] {
        nodes
    }

    func performAction(nodeID: String, action: AccessibilityAction) async throws {
        performedActions.append((nodeID, action))
    }
}

final class FakeInputBackend: InputBackend, @unchecked Sendable {
    var pointerEvents: [PointerInputEvent] = []
    var keyboardEvents: [KeyboardInputEvent] = []
    var neutralizeCount: Int = 0
    var shouldFailOnPointer: Bool = false

    func injectPointer(event: PointerInputEvent) async throws {
        if shouldFailOnPointer {
            throw ActionExecutionError.inputInjectionFailed(reason: "Mock injection failure")
        }
        pointerEvents.append(event)
    }

    func injectKeyboard(event: KeyboardInputEvent) async throws {
        keyboardEvents.append(event)
    }

    func neutralize() async {
        neutralizeCount += 1
    }
}

final class FakeCapabilityProbe: CapabilityProbing, @unchecked Sendable {
    var snapshotToReturn: HostCapabilitySnapshot

    init(snapshot: HostCapabilitySnapshot) {
        self.snapshotToReturn = snapshot
    }

    func probe() async -> HostCapabilitySnapshot {
        snapshotToReturn
    }
}

// MARK: - Test Suite

@Suite("InteractionBatchExecutor Tests")
struct InteractionBatchExecutorTests {

    private func makeTestObservation(version: Int64 = 1) -> Observation {
        let displayID = "display-1"
        let displayBounds = CoordinateRect(
            origin: TargetPosition(x: 0, y: 0, space: .logicalPoint(displayID: displayID)),
            width: 1920,
            height: 1080
        )
        let metrics = DisplayMetrics(
            displayID: displayID,
            scaleFactor: 2.0,
            bounds: displayBounds
        )
        let sessionID = EnvironmentSessionID(rawValue: "session-test")

        let refButton = ElementRef(sessionID: sessionID, scopeID: "session-test", version: version, index: 1)
        let refInput = ElementRef(sessionID: sessionID, scopeID: "session-test", version: version, index: 2)

        let nodeButton = AccessibilityNodeSnapshot(
            id: "btn-login",
            role: "button",
            name: "Login",
            bounds: CoordinateRect(
                origin: TargetPosition(x: 100, y: 200, space: .logicalPoint(displayID: displayID)),
                width: 80,
                height: 30
            )
        )
        let nodeInput = AccessibilityNodeSnapshot(
            id: "txt-username",
            role: "textField",
            name: "Username",
            bounds: CoordinateRect(
                origin: TargetPosition(x: 100, y: 150, space: .logicalPoint(displayID: displayID)),
                width: 200,
                height: 30
            )
        )

        return Observation(
            id: ObservationID(),
            sessionID: sessionID,
            version: version,
            observedAt: Date(),
            source: .desktop(displayID: displayID, activeWindowID: nil),
            elements: [
                refButton: nodeButton,
                refInput: nodeInput
            ],
            screenshotBlobRef: "blob-sha256-mock",
            viewportBounds: displayBounds,
            displayMetrics: metrics
        )
    }

    @Test("Sequential pipeline execution succeeds with all steps recorded")
    func testSequentialExecutionSuccess() async throws {
        let fakeInput = FakeInputBackend()
        let fakeAccess = FakeAccessibilityBackend()
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
            accessibility: fakeAccess,
            input: fakeInput,
            probe: probe,
            initialSnapshot: await probe.probe()
        )

        let obs = makeTestObservation(version: 1)
        let refBtn = obs.elements.keys.first(where: { $0.index == 1 })!

        let batch = ActionBatch(
            actions: [
                .desktop(.primitive(.hover(target: .element(refBtn)))),
                .desktop(.primitive(.click(target: .element(refBtn), button: .left, count: 1))),
                .desktop(.primitive(.type(text: "hello", target: nil)))
            ],
            stopOnFailure: true
        )

        let executor = ActionBatchExecutor()
        let result = try await executor.execute(
            batch: batch,
            environment: env,
            currentObservation: obs
        )

        #expect(result.succeeded == true)
        #expect(result.completedStepCount == 3)
        #expect(fakeInput.pointerEvents.count >= 2)
        #expect(fakeInput.keyboardEvents.count >= 1)
        #expect(fakeInput.neutralizeCount >= 1)
    }

    @Test("Stop-on-failure stops immediately and triggers input neutralization")
    func testStopOnFailureCircuitBreak() async throws {
        let fakeInput = FakeInputBackend()
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
            input: fakeInput,
            probe: probe,
            initialSnapshot: await probe.probe()
        )

        let obs = makeTestObservation(version: 1)
        let refBtn = obs.elements.keys.first(where: { $0.index == 1 })!

        fakeInput.shouldFailOnPointer = true

        let batch = ActionBatch(
            actions: [
                .desktop(.primitive(.click(target: .element(refBtn), button: .left, count: 1))),
                .desktop(.primitive(.type(text: "never reached", target: nil)))
            ],
            stopOnFailure: true
        )

        let executor = ActionBatchExecutor()
        let result = try await executor.execute(
            batch: batch,
            environment: env,
            currentObservation: obs
        )

        #expect(result.succeeded == false)
        #expect(result.completedStepCount == 0)
        #expect(fakeInput.keyboardEvents.isEmpty)
        #expect(fakeInput.neutralizeCount >= 1)
    }

    @Test("Stale reference preflight check intercepts mismatched version")
    func testStaleReferenceIntercepted() async throws {
        let fakeInput = FakeInputBackend()
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
            input: fakeInput,
            probe: probe,
            initialSnapshot: await probe.probe()
        )

        let obs = makeTestObservation(version: 10)
        let staleRef = ElementRef(
            sessionID: obs.sessionID,
            scopeID: obs.sessionID.rawValue,
            version: 9, // Version mismatch!
            index: 1
        )

        let batch = ActionBatch(
            actions: [
                .desktop(.primitive(.click(target: .element(staleRef), button: .left, count: 1)))
            ]
        )

        let executor = ActionBatchExecutor()
        do {
            _ = try await executor.execute(
                batch: batch,
                environment: env,
                currentObservation: obs
            )
            Issue.record("Expected stale reference error was not thrown")
        } catch let InteractionError.staleReference(staleErr) {
            if case let .versionMismatch(expected, current, _) = staleErr {
                #expect(expected == 9)
                #expect(current == 10)
            } else {
                Issue.record("Unexpected stale error: \(staleErr)")
            }
        }
    }

    @Test("Capability preflight rejects action when input capability is unsupported")
    func testCapabilityPreflightRejection() async throws {
        let probe = FakeCapabilityProbe(
            snapshot: HostCapabilitySnapshot(
                capture: .available,
                accessibility: .available,
                input: .unsupported(reason: "Wayland EIS not available"),
                windowManagement: .unsupported(reason: "No window manager"),
                applicationManagement: .available,
                clipboard: .available
            )
        )
        let env = DesktopEnvironment(
            probe: probe,
            initialSnapshot: await probe.probe()
        )

        let obs = makeTestObservation(version: 1)
        let refBtn = obs.elements.keys.first(where: { $0.index == 1 })!

        let batch = ActionBatch(
            actions: [
                .desktop(.primitive(.click(target: .element(refBtn), button: .left, count: 1)))
            ]
        )

        let executor = ActionBatchExecutor()
        do {
            _ = try await executor.execute(
                batch: batch,
                environment: env,
                currentObservation: obs
            )
            Issue.record("Expected capability error was not thrown")
        } catch let InteractionError.capability(capErr) {
            if case let .featureUnsupported(feature, reason) = capErr {
                #expect(feature == "InputInjection")
                #expect(reason == "Wayland EIS not available")
            } else {
                Issue.record("Unexpected capability error: \(capErr)")
            }
        }
    }

    @Test("CoordinateTransform handles physical, normalized, and window coordinates accurately")
    func testCoordinateTransformAccuracy() throws {
        let displayID = "disp-main"
        let displayBounds = CoordinateRect(
            origin: TargetPosition(x: 0, y: 0, space: .logicalPoint(displayID: displayID)),
            width: 1920,
            height: 1080
        )
        let metrics = DisplayMetrics(
            displayID: displayID,
            scaleFactor: 2.0, // Retina
            bounds: displayBounds
        )

        // 1. 物理像素到逻辑点转换: (800, 600) -> (400, 300)
        let physicalPos = TargetPosition(x: 800, y: 600, space: .physicalPixel(displayID: displayID))
        let logicalFromPhys = try CoordinateTransform.toLogicalPoint(from: physicalPos, displayMetrics: metrics)
        #expect(logicalFromPhys.x == 400.0)
        #expect(logicalFromPhys.y == 300.0)

        // 2. 归一化比例坐标转换: (0.5, 0.5) -> (960, 540)
        let normalizedPos = TargetPosition(x: 0.5, y: 0.5, space: .normalized(displayID: displayID))
        let logicalFromNorm = try CoordinateTransform.toLogicalPoint(from: normalizedPos, displayMetrics: metrics)
        #expect(logicalFromNorm.x == 960.0)
        #expect(logicalFromNorm.y == 540.0)

        // 3. 归一化越界检查抛错
        let outOfBoundsPos = TargetPosition(x: 1.2, y: 0.5, space: .normalized(displayID: displayID))
        #expect(throws: CoordinateTransformError.self) {
            _ = try CoordinateTransform.toLogicalPoint(from: outOfBoundsPos, displayMetrics: metrics)
        }

        // 4. 窗口局部坐标转换: Window origin at (100, 100), local (50, 50) -> Global (150, 150)
        let windowBounds = CoordinateRect(
            origin: TargetPosition(x: 100, y: 100, space: .logicalPoint(displayID: displayID)),
            width: 500,
            height: 400
        )
        let windowLocalPos = TargetPosition(x: 50, y: 50, space: .windowLocal(windowID: "win-1"))
        let logicalFromWin = try CoordinateTransform.toLogicalPoint(
            from: windowLocalPos,
            displayMetrics: metrics,
            windowBounds: windowBounds
        )
        #expect(logicalFromWin.x == 150.0)
        #expect(logicalFromWin.y == 150.0)

        // 5. 窗口上下文缺失时必须明确抛错
        #expect(throws: CoordinateTransformError.self) {
            _ = try CoordinateTransform.toLogicalPoint(from: windowLocalPos, displayMetrics: metrics, windowBounds: nil)
        }
    }

    @Test("Task cancellation immediately stops execution and ensures neutralization")
    func testTaskCancellationHandling() async throws {
        let fakeInput = FakeInputBackend()
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
            input: fakeInput,
            probe: probe,
            initialSnapshot: await probe.probe()
        )
        let obs = makeTestObservation(version: 1)

        let task = Task {
            let executor = ActionBatchExecutor()
            let batch = ActionBatch(
                actions: [
                    .desktop(.primitive(.wait(condition: .duration(milliseconds: 500)))),
                    .desktop(.primitive(.type(text: "never", target: nil)))
                ]
            )
            return try await executor.execute(batch: batch, environment: env, currentObservation: obs)
        }

        task.cancel()

        do {
            _ = try await task.value
        } catch let InteractionError.cancellation(cancelErr) {
            #expect(cancelErr == .userCancelled)
        } catch {
            // Task cancellation caught
        }

        #expect(fakeInput.neutralizeCount >= 1)
    }

    @Test("Critical risk evaluator blocks action execution before invocation")
    func testCriticalRiskEvaluationRejection() async throws {
        let fakeInput = FakeInputBackend()
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
            input: fakeInput,
            probe: probe,
            initialSnapshot: await probe.probe()
        )
        let obs = makeTestObservation(version: 1)
        let refBtn = obs.elements.keys.first(where: { $0.index == 1 })!

        final class FakeRiskEvaluator: InteractionRiskEvaluating, @unchecked Sendable {
            func evaluateRisk(actions: [InteractionAction], observation: Observation?, origin: String?, intentHint: String?) async -> InteractionRiskCategory {
                .critical(reason: "Payment transaction requires explicit physical confirmation")
            }
        }

        let executor = ActionBatchExecutor()
        let batch = ActionBatch(
            actions: [
                .desktop(.primitive(.click(target: .element(refBtn), button: .left, count: 1)))
            ],
            intentHint: "Click confirm payment"
        )

        do {
            _ = try await executor.execute(
                batch: batch,
                environment: env,
                currentObservation: obs,
                riskEvaluator: FakeRiskEvaluator()
            )
            Issue.record("Expected critical risk rejection was not thrown")
        } catch let InteractionError.permission(permErr) {
            if case let .highRiskActionForbidden(reason) = permErr {
                #expect(reason.contains("Payment transaction"))
            } else {
                Issue.record("Unexpected permission error: \(permErr)")
            }
        }
        #expect(fakeInput.pointerEvents.isEmpty)
        #expect(fakeInput.neutralizeCount >= 1)
    }
}
