import Testing
import Foundation
@testable import LingXiProtocol
@testable import LingXiPlatform
@testable import LingXiCore

@Suite("ComputerBatchTool Tests")
struct ComputerBatchToolTests {

    @Test("ComputerBatchTool definition and invalid argument rejection")
    func testToolDefinitionAndValidation() async throws {
        let tool = ComputerBatchTool()
        #expect(tool.definition.id.rawValue == "computer_batch")
        #expect(tool.definition.inputSchema.required.contains("actions"))
        #expect(tool.definition.capability.kinds.contains(.userInteraction))

        // 缺少 actions
        await #expect(throws: CoreError.self) {
            _ = try await tool.execute(arguments: "{}", profile: .workspace)
        }

        // 空 actions
        await #expect(throws: CoreError.self) {
            _ = try await tool.execute(arguments: #"{"actions": []}"#, profile: .workspace)
        }
    }

    @Test("ComputerBatchTool executes multi-step sequential action pipeline")
    func testBatchActionExecution() async throws {
        let tool = ComputerBatchTool()

        let payload = """
        {
            "intent_hint": "Search query and submit in browser",
            "actions": [
                {
                    "type": "move",
                    "x": 400,
                    "y": 300
                },
                {
                    "type": "click",
                    "button": "left",
                    "count": 1,
                    "x": 400,
                    "y": 300
                },
                {
                    "type": "type",
                    "text": "Antigravity Computer Use"
                },
                {
                    "type": "key",
                    "key": "Return"
                },
                {
                    "type": "wait",
                    "duration_ms": 100
                }
            ]
        }
        """

        let result = try await tool.execute(arguments: payload, profile: .workspace)
        print("\n🦊 [ComputerBatchTool Result]:\n\(result)")

        #expect(result.contains("Action Batch Execution: SUCCESS"))
        #expect(result.contains("Completed Steps: 5 / 5"))
        #expect(result.contains("Step Timing Breakdown:"))
        #expect(result.contains("Total Elapsed:"))
    }

    @Test("ComputerBatchTool handles pure observation and inspection actions without error")
    func testObservationActionsExecution() async throws {
        let mockEnv = DesktopEnvironment(
            capture: MockTestCaptureBackend(),
            accessibility: MockTestAccessibilityBackend(),
            probe: MockTestProbe()
        )
        let tool = ComputerBatchTool(environment: mockEnv)

        let payload = """
        {
            "intent_hint": "Inspect UI and take screenshot",
            "actions": [
                {
                    "type": "find",
                    "query": "SubmitButton"
                },
                {
                    "type": "screenshot"
                }
            ]
        }
        """

        let result = try await tool.execute(arguments: payload, profile: .workspace)
        print("\n🦊 [Observation Actions Result]:\n\(result)")

        #expect(result.contains("Action Batch Execution: SUCCESS"))
        #expect(result.contains("Executed Steps: 2"))
        #expect(result.contains("Find / Inspect \"SubmitButton\""))
        #expect(result.contains("Screenshot"))
        #expect(result.contains("Step Timing Breakdown:"))
    }

    @Test("ComputerBatchTool strictly rejects coordinate actions in background mode with foregroundRequired")
    func testBackgroundCoordinateActionRejectionWithForegroundRequired() async throws {
        let mockEnv = DesktopEnvironment(
            accessibility: MockTestAccessibilityBackend(),
            windows: MockTestWindowBackend(),
            probe: MockTestProbe()
        )
        let tool = ComputerBatchTool(environment: mockEnv)

        let payload = """
        {
            "intent_hint": "Attempt dangerous background coordinate click into occluded app",
            "target_app": "Safari",
            "bring_to_front": false,
            "actions": [
                {
                    "type": "click",
                    "x": 250,
                    "y": 150
                }
            ]
        }
        """

        let result = try await tool.execute(arguments: payload, profile: .workspace)
        print("\n🦊 [Background Rejection Result]:\n\(result)")

        #expect(result.contains("Action Batch Execution: FAILED"))
        #expect(result.contains("foregroundRequired"))
        #expect(result.contains("Completed Steps: 0 / 2"))
    }

    @Test("ComputerBatchTool allows coordinate actions when bring_to_front is explicitly true")
    func testForegroundCoordinateActionAllowedWithRevalidation() async throws {
        let mockEnv = DesktopEnvironment(
            accessibility: MockTestAccessibilityBackend(),
            input: MockTestInputBackend(),
            windows: MockTestWindowBackend(),
            probe: MockTestProbe()
        )
        let tool = ComputerBatchTool(environment: mockEnv)

        let payload = """
        {
            "intent_hint": "Legitimate foreground coordinate click",
            "target_app": "Safari",
            "bring_to_front": true,
            "actions": [
                {
                    "type": "click",
                    "x": 250,
                    "y": 150
                }
            ]
        }
        """

        let result = try await tool.execute(arguments: payload, profile: .workspace)
        print("\n🦊 [Foreground Allowed Result]:\n\(result)")

        #expect(result.contains("Action Batch Execution: SUCCESS"))
        #expect(result.contains("Completed Steps: 2 / 2"))
    }

    @Test("ComputerBatchTool reports friendly error when all actions are unrecognized")
    func testUnknownActionFriendlyError() async throws {
        let tool = ComputerBatchTool()

        let payload = """
        {
            "actions": [
                {
                    "type": "nonexistent_quantum_teleport"
                }
            ]
        }
        """

        do {
            _ = try await tool.execute(arguments: payload, profile: .workspace)
            #expect(Bool(false), "Should have thrown CoreError")
        } catch let error as CoreError {
            #expect(error.code == .toolArgumentInvalid)
            #expect(error.message.contains("No recognized actions found"))
            #expect(error.message.contains("Supported action types"))
        }
    }

    @Test("ComputerBatchTool defaults to non-disruptive background mode preserving TUI visibility")
    func testBackgroundNonDisruptiveModePreservesTUI() async throws {
        let mockEnv = DesktopEnvironment(
            capture: MockTestCaptureBackend(),
            accessibility: MockTestAccessibilityBackend(),
            windows: MockTestWindowBackend(),
            probe: MockTestProbe()
        )
        let tool = ComputerBatchTool(environment: mockEnv)

        let payload = """
        {
            "target_app": "Safari",
            "intent_hint": "Type in background without stealing foreground focus",
            "actions": [
                {
                    "type": "find",
                    "query": "NonexistentElementForScopeTest"
                }
            ]
        }
        """

        let result = try await tool.execute(arguments: payload, profile: .workspace)
        print("\n🦊 [Background Non-Disruptive Mode Result]:\n\(result)")

        #expect(result.contains("Action Batch Execution: SUCCESS"))
        #expect(result.contains("Non-disruptive background mode (TUI visibility preserved)"))
        #expect(result.contains("💡 PERFORMANCE NOTICE"))
    }
}

// MARK: - Test Mocks

private final class MockTestAccessibilityBackend: AccessibilityBackend, @unchecked Sendable {
    func fetchTree(scope: AccessibilityScope) async throws -> [AccessibilityNodeSnapshot] {
        return [
            AccessibilityNodeSnapshot(
                id: "btn_submit",
                role: "AXButton",
                name: "SubmitButton",
                value: nil,
                isInteractable: true,
                bounds: CoordinateRect(
                    origin: TargetPosition(x: 200, y: 300, space: .logicalPoint(displayID: "main")),
                    width: 100,
                    height: 36
                )
            )
        ]
    }

    func findElement(matching query: String, role: String?, scope: AccessibilityScope) async throws -> AccessibilityNodeSnapshot? {
        if query.contains("SubmitButton") {
            return AccessibilityNodeSnapshot(
                id: "btn_submit",
                role: "AXButton",
                name: "SubmitButton",
                value: nil,
                isInteractable: true,
                bounds: CoordinateRect(
                    origin: TargetPosition(x: 200, y: 300, space: .logicalPoint(displayID: "main")),
                    width: 100,
                    height: 36
                )
            )
        }
        return nil
    }

    func performAction(nodeID: String, action: AccessibilityAction) async throws {}
}

private final class MockTestCaptureBackend: CaptureBackend, @unchecked Sendable {
    func availableSources() async throws -> [CaptureSource] {
        [CaptureSource(id: "display_main", name: "Main Display", isDisplay: true)]
    }

    func captureFrame(source: CaptureSource, cropRect: NormalizedRect?) async throws -> CapturedFrame {
        CapturedFrame(
            data: Data(count: 64),
            pixelWidth: 1920,
            pixelHeight: 1080,
            scaleFactor: 2.0
        )
    }
}

private final class MockTestWindowBackend: WindowBackend, @unchecked Sendable {
    func listWindows() async throws -> [WindowInfo] {
        [WindowInfo(id: "win_1", title: "Safari", bundleIdentifier: "com.apple.safari", bounds: CoordinateRect(origin: TargetPosition(x: 0, y: 0, space: .logicalPoint(displayID: "main")), width: 800, height: 600), isMinimized: false)]
    }
    func focusWindow(id: String) async throws {}
    func setWindowBounds(id: String, bounds: CoordinateRect) async throws {}
    func attachTarget(query: TargetAttachmentQuery) async throws -> WindowInfo? {
        WindowInfo(id: "win_1", title: query.appName ?? "Target", bundleIdentifier: "com.apple.safari", bounds: CoordinateRect(origin: TargetPosition(x: 0, y: 0, space: .logicalPoint(displayID: "main")), width: 800, height: 600), isMinimized: false)
    }
}

private struct MockTestProbe: CapabilityProbing {
    func probe() async -> HostCapabilitySnapshot {
        HostCapabilitySnapshot(
            capture: .available,
            accessibility: .available,
            input: .available,
            windowManagement: .available,
            applicationManagement: .available,
            clipboard: .available
        )
    }
}

private final class MockTestInputBackend: InputBackend, @unchecked Sendable {
    func injectPointer(event: PointerInputEvent) async throws {}
    func injectKeyboard(event: KeyboardInputEvent) async throws {}
    func neutralize() async {}
}
