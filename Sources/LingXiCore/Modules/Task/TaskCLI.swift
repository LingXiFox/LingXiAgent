import Foundation
import LingXiProtocol
import LingXiPlatform

/// 任务与工作区生命周期运维 CLI (TaskCLI)
/// 对应 lingxiagent --task list|show|pause|resume|cancel|fork
public enum TaskCLI {

    public static func run(arguments: [String], dataRoot: URL) async throws -> String {
        guard let sub = arguments.first else {
            return helpText()
        }

        let mainRoot = URL(fileURLWithPath: LingXiPlatform.process.currentWorkingDirectory())
        let store = try SQLitePersistenceStore(dataRoot: dataRoot, mainRoot: mainRoot)
        let runtime = TaskRuntime(persistence: store)

        // Load existing capsules into runtime cache
        let existingCapsules = try await store.listCapsules(sessionID: nil)
        for capsule in existingCapsules {
            try await runtime.register(capsule: capsule)
        }

        switch sub {
        case "list":
            let capsules = await runtime.listCapsules()
            if capsules.isEmpty {
                return "No tasks found in the current workspace."
            }
            var output = "TASK ID                              STATE        REVISION  OBJECTIVE\n"
            output += "--------------------------------------------------------------------------------\n"
            for c in capsules.sorted(by: { $0.createdAt < $1.createdAt }) {
                let idStr = c.taskID.rawValue.padding(toLength: 36, withPad: " ", startingAt: 0)
                let stateStr = c.state.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
                let revStr = String(c.revision).padding(toLength: 8, withPad: " ", startingAt: 0)
                let objStr = c.objective.replacingOccurrences(of: "\n", with: " ")
                output += "\(idStr) \(stateStr) \(revStr)  \(objStr)\n"
            }
            return output

        case "show":
            guard arguments.count > 1 else {
                return "Error: Missing task-id. Usage: lingxiagent --task show <task-id>"
            }
            let taskID = TaskID(arguments[1])
            guard let capsule = await runtime.getCapsule(taskID) else {
                return "Error: Task not found: \(taskID.rawValue)"
            }
            var output = "Task Details:\n"
            output += "  ID:               \(capsule.taskID.rawValue)\n"
            output += "  State:            \(capsule.state.rawValue)\n"
            if let reason = capsule.waitingReason {
                output += "  Waiting Reason:   \(reason.rawValue)\n"
            }
            output += "  Workspace ID:     \(capsule.workspaceID.rawValue)\n"
            output += "  Session ID:       \(capsule.sessionID.rawValue)\n"
            output += "  Revision:         \(capsule.revision)\n"
            output += "  Objective:        \(capsule.objective)\n"
            output += "  Created:          \(capsule.createdAt)\n"
            output += "  Updated:          \(capsule.updatedAt)\n"

            if let resume = capsule.resumePoint {
                output += "  Resume Point:\n"
                output += "    Step Index:     \(resume.stepIndex)\n"
                output += "    Generation:     \(resume.generation)\n"
                output += "    Interrupted At: \(resume.interruptedAt)\n"
                if !resume.statePayload.isEmpty {
                    output += "    State Payload:  \(resume.statePayload)\n"
                }
            } else {
                output += "  Resume Point:     None\n"
            }

            output += "  Artifacts (\(capsule.artifacts.count)):\n"
            for art in capsule.artifacts {
                output += "    [\(art.ordinal)] (\(art.kind)) \(art.ref)\n"
            }

            output += "  Tool States (\(capsule.toolStates.count)):\n"
            for ts in capsule.toolStates {
                output += "    \(ts.toolCallID): \(ts.state)\n"
            }

            return output

        case "pause":
            guard arguments.count > 1 else {
                return "Error: Missing task-id. Usage: lingxiagent --task pause <task-id> [reason]"
            }
            let taskID = TaskID(arguments[1])
            let reason = arguments.count > 2 ? arguments.dropFirst(2).joined(separator: " ") : nil
            let req = TaskLifecycleRequest(taskID: taskID, command: .pause, reason: reason)
            let updated = try await runtime.transition(request: req)
            return "✓ Task \(taskID.rawValue) paused (revision \(updated.revision), generation \(updated.resumePoint?.generation ?? 0))."

        case "resume":
            guard arguments.count > 1 else {
                return "Error: Missing task-id. Usage: lingxiagent --task resume <task-id>"
            }
            let taskID = TaskID(arguments[1])
            let req = TaskLifecycleRequest(taskID: taskID, command: .resume)
            let updated = try await runtime.transition(request: req)
            return "✓ Task \(taskID.rawValue) resumed (state: \(updated.state.rawValue), revision \(updated.revision))."

        case "cancel":
            guard arguments.count > 1 else {
                return "Error: Missing task-id. Usage: lingxiagent --task cancel <task-id> [reason]"
            }
            let taskID = TaskID(arguments[1])
            let reason = arguments.count > 2 ? arguments.dropFirst(2).joined(separator: " ") : nil
            let req = TaskLifecycleRequest(taskID: taskID, command: .cancel, reason: reason)
            let updated = try await runtime.transition(request: req)
            return "✓ Task \(taskID.rawValue) cancelled (state: \(updated.state.rawValue))."

        case "fork":
            guard arguments.count > 1 else {
                return "Error: Missing workspace-id. Usage: lingxiagent --task fork <workspace-id> [copy-on-write|shared|git-worktree]"
            }
            let originID = WorkspaceID(arguments[1])
            let isoState: WorkspaceIsolationState
            if arguments.count > 2 {
                isoState = WorkspaceIsolationState(rawValue: arguments[2]) ?? .copyOnWrite
            } else {
                isoState = .copyOnWrite
            }

            let wsRuntime = WorkspaceRuntime()
            if let existing = try await store.workspace(workspaceID: originID) {
                await wsRuntime.register(WorkspaceEntity(
                    workspaceID: existing.workspaceID,
                    projectID: existing.projectID,
                    kind: WorkspaceKind(rawValue: existing.kind) ?? .main,
                    originWorkspaceID: existing.originWorkspaceID,
                    rootBindingID: existing.rootBindingID,
                    baseRevision: String(existing.baseRevision),
                    isolationState: WorkspaceIsolationState(rawValue: existing.isolationState) ?? .shared,
                    state: existing.state
                ))
            } else {
                return "Error: Origin workspace not found: \(originID.rawValue)"
            }

            let forked = try await wsRuntime.fork(from: originID, isolationState: isoState)
            try await store.saveWorkspace(
                workspaceID: forked.workspaceID,
                projectID: forked.projectID,
                kind: forked.kind.rawValue,
                originWorkspaceID: forked.originWorkspaceID,
                rootBindingID: forked.rootBindingID,
                baseRevision: Int(forked.baseRevision ?? "0") ?? 0,
                isolationState: forked.isolationState.rawValue,
                state: forked.state
            )

            return "✓ Forked workspace \(forked.workspaceID.rawValue) (origin: \(originID.rawValue), isolation: \(forked.isolationState.rawValue))."

        case "-h", "--help", "help":
            return helpText()

        default:
            return "Unknown task subcommand: '\(sub)'.\n\n\(helpText())"
        }
    }

    private static func helpText() -> String {
        """
        Usage: lingxiagent --task <subcommand> [options]

        Task & Workspace Lifecycle Management Commands:
          list                         List tasks for current project
          show <task-id>               Show detailed task capsule & resume point
          pause <task-id> [reason]     Pause task and record resume point
          resume <task-id>             Resume task from resume point
          cancel <task-id> [reason]    Cancel task execution
          fork <workspace-id> [mode]   Fork a workspace with isolation (default: copy-on-write)
        """
    }
}
