import Foundation

// MARK: - ToolFamily
//
// Shared classification of a tool invocation into the product family the
// front-end should present it under. This used to be GUI-only string sniffing
// (Apps/LingXiApp/Shared/Components/TimelineViews.swift, DesignSystem/Components.swift).
// It is promoted here so every frontend (GUI, TUI, Web) groups tools identically.

public enum ToolFamily: String, Codable, CaseIterable, Sendable {
    case mcp
    case skill
    case browser
    case computer
    case fileEdit
    case fileRead
    case search
    case shell
    case git
    case subagent
    case network
    case other
}

public extension ToolFamily {
    /// Deterministic, pure classification.
    ///
    /// Order matters and mirrors the historical GUI rules: the *name* carries the
    /// most specific signal (`mcp__github__list_issues` is an MCP tool even though
    /// it also contains "list"), so name rules run first and `capabilityKind` is
    /// consulted only when the name is uninformative.
    static func classify(toolName: String, capabilityKind: ToolCapabilityKind? = nil) -> ToolFamily {
        let name = toolName.lowercased()

        // 1. MCP: prefix only, matching the GUI badge rule.
        if name.hasPrefix("mcp_") || name.hasPrefix("mcp.") || name.hasPrefix("mcp:") {
            return .mcp
        }
        // 2. Skills.
        if name.hasPrefix("skill") || name.contains("load_skill") {
            return .skill
        }
        // 3. Browser automation.
        if name.contains("browser") || name.contains("chrome") {
            return .browser
        }
        // 4. Desktop / OS-level control.
        if name.contains("computer") || name.contains("cursorarrow") || name.contains("desktop")
            || name.contains("screenshot") || name.contains("accessibilit") {
            return .computer
        }
        // 5. File mutation.
        if name.contains("edit") || name.contains("write") || name.contains("patch")
            || name.contains("multi_edit") || name.contains("notebook_edit") {
            return .fileEdit
        }
        // 6. File read.
        if name.contains("read") {
            return .fileRead
        }
        // 7. Outbound web verbs are checked before the generic discovery rule: `websearch`
        // contains "search" but is a network tool (same ordering the GUI glyph rule uses).
        if name.contains("webfetch") || name.contains("websearch") || name.contains("web_search") {
            return .network
        }
        // 8. Discovery.
        if name.contains("grep") || name.contains("glob") || name.contains("search") || name.contains("find") {
            return .search
        }
        // 9. Process execution.
        if name.contains("bash") || name.contains("shell") || name.contains("exec")
            || name.contains("run_command") || name.contains("terminal") || name.contains("process") {
            return .shell
        }
        // 10. Version control.
        if name.contains("git") || name.contains("worktree") || name.contains("commit") || name.contains("diff") {
            return .git
        }
        // 11. Delegation.
        if name.contains("subagent") || name.contains("agent") || name.contains("task") || name.contains("spawn") {
            return .subagent
        }
        // 12. Remaining fetch/http names.
        if name.contains("fetch") || name.contains("http") {
            return .network
        }
        // 13. Fall back on the declared capability when the name says nothing.
        if let capabilityKind, let family = family(for: capabilityKind) {
            return family
        }
        return .other
    }

    /// Capability-driven family, used only when the tool name is not decisive.
    static func family(for capabilityKind: ToolCapabilityKind) -> ToolFamily? {
        switch capabilityKind {
        case .projectRead: return .fileRead
        case .projectWrite: return .fileEdit
        case .externalFilesystem: return .fileEdit
        case .processExecute: return .shell
        case .repositoryRead, .repositoryWrite: return .git
        case .networkAccess: return .network
        case .destructive, .userInteraction, .externalService: return nil
        }
    }
}

// MARK: - FrontendCommand
//
// The CLOSED, browser-safe set of user intents a remote frontend may express.
// This is the serializable mirror of the user-facing `ApplicationAction` cases;
// store-internal actions (`_connectionStateChanged`, `_streamFrameReceived`, ...)
// and host lifecycle actions (`connect`, `disconnect`) are deliberately absent:
// they are not user intents and must never be reachable from a remote client.

public enum FrontendCommand: Codable, Sendable, Equatable {
    // Session management
    case createSession(title: String?, mode: AgentMode)
    case switchSession(sessionID: SessionID)
    case renameSession(sessionID: SessionID, newTitle: String)
    case deleteSession(sessionID: SessionID)
    case listSessions

    // Prompt & execution
    case submitPrompt(text: String)
    case stopCurrentRun
    case cancelRun(runID: RunID, reason: String?)
    case setMode(mode: AgentMode)
    case setPermissionConfiguration(PermissionConfiguration)
    case setReasoningEffort(ReasoningEffort)

    // HITL
    case respondInteraction(interactionID: InteractionID, resolution: InteractionResolution)
    case grantPermission(interactionID: InteractionID, decision: PermissionDecision)
    case replyQuestion(interactionID: InteractionID, reply: QuestionReply)
    case submitDecision(interactionID: InteractionID, decision: String)

    // Provider & model
    case selectModel(modelID: String)
    case listProviders
    case listModels

    // Context & extensions
    case compactContext(sessionID: SessionID?)
    case refreshExtensions
    case refreshDiagnostics

    // Command bus & connection refresh
    case executeCommand(rawInput: String)
    case reconnect
}
