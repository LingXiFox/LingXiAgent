import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

@Suite("Subagent Permission Posture Tests")
struct SubagentPermissionPostureTests {

    @Test("A child inherits the parent posture when it asked for no profile of its own")
    func inheritsParentPosture() {
        #expect(AgentRuntime.childPermissionConfiguration(profile: nil, parent: .yoloFullAccess) == .yoloFullAccess)
        #expect(AgentRuntime.childPermissionConfiguration(
            profile: SubagentExecutionProfile(maxSteps: 8),
            parent: .askWorkspace
        ) == .askWorkspace)
    }

    @Test("An explicit child profile overrides the parent")
    func explicitProfileWins() {
        let fullAccess = SubagentExecutionProfile(permissionProfile: "fullAccess")
        let workspace = SubagentExecutionProfile(permissionProfile: "workspace")
        #expect(AgentRuntime.childPermissionConfiguration(profile: fullAccess, parent: .strict) == .yoloFullAccess)
        #expect(AgentRuntime.childPermissionConfiguration(profile: workspace, parent: .yoloFullAccess) == .askWorkspace)
    }

    @Test("With no parent context the child still lands on the strict posture, never a wider one")
    func absentParentContextStaysStrict() {
        #expect(AgentRuntime.childPermissionConfiguration(profile: nil, parent: nil) == .strict)
        #expect(AgentRuntime.childPermissionConfiguration(
            profile: SubagentExecutionProfile(permissionProfile: "  "),
            parent: nil
        ) == .strict)
    }
}
