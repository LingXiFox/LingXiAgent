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
        let tool = ComputerBatchTool()

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
        let tool = ComputerBatchTool()

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
