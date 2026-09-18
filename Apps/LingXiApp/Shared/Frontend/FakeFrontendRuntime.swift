import Foundation
import SwiftUI
import LingXiProtocol

/// Phase 0 预设场景类型
public enum GUIFixtureScenario: String, CaseIterable, Identifiable, Sendable {
    case empty = "Empty State"
    case conversation = "Normal Conversation"
    case streaming = "High-Speed Streaming"
    case toolHeavy = "Tool Invocations & Subagent"
    case permission = "HITL Permission Request"
    case contextPressure = "High Context Pressure"
    case mcpFailure = "MCP Server Failure"
    case backgroundTask = "Background Task Monitor"
    case providerReconnect = "Provider Reconnect"

    public var id: String { rawValue }
}

/// FakeFrontendRuntime: 纯内存隔离的前端模拟运行时
/// 严格遵守 Phase 0 Hard Gate：
/// - 0 CoreHost
/// - 0 Plugin process
/// - 0 Browser helper
/// - 0 user HOME writes
/// - 0 filesystem mutations
public final class FakeFrontendRuntime: @unchecked Sendable {
    public let sidebarModel: SidebarPresentationModel
    public let conversationModel: ConversationPresentationModel
    public let inspectorModel: RuntimeInspectorPresentationModel
    public let composerModel: ComposerModel

    public private(set) var currentScenario: GUIFixtureScenario = .conversation
    private var streamingTask: Task<Void, Never>?

    public init(scenario: GUIFixtureScenario = .conversation) {
        self.sidebarModel = SidebarPresentationModel()
        self.conversationModel = ConversationPresentationModel()
        self.inspectorModel = RuntimeInspectorPresentationModel()
        self.composerModel = ComposerModel()

        applyScenario(scenario)
    }

    public func switchScenario(_ scenario: GUIFixtureScenario) {
        streamingTask?.cancel()
        streamingTask = nil
        self.currentScenario = scenario
        applyScenario(scenario)
    }

    private func applyScenario(_ scenario: GUIFixtureScenario) {
        // 1. 初始化标准 Sidebar 数据
        sidebarModel.workspace = WorkspaceSummaryPresentation(
            name: "LingXiAgent",
            rootBadge: "local",
            isRemote: false,
            gitBranch: "main",
            indexingState: "ready"
        )
        sidebarModel.sessions = [
            SessionItemPresentation(id: "sess-1", title: "Refactor ToolRuntime", messageCount: 14, mode: "build", isActive: true),
            SessionItemPresentation(id: "sess-2", title: "Analyze Cache Hit Ratio", messageCount: 6, mode: "plan", isActive: false),
            SessionItemPresentation(id: "sess-3", title: "Review LingXi Glass UI", messageCount: 22, mode: "review", isActive: false)
        ]
        sidebarModel.selectedSessionID = "sess-1"

        // 2. 根据场景装配 Conversation 与 Inspector 数据
        switch scenario {
        case .empty:
            conversationModel.sessionID = "sess-empty"
            conversationModel.items = []
            conversationModel.isGenerating = false
            inspectorModel.telemetry = RuntimeInspectorPresentation(
                pcoreNodes: 0,
                pcoreEdges: 0,
                ecoreHeat: 0.0,
                cacheHitRatio: 1.0,
                tokensPerSecond: 0.0,
                retrievalWarmup: "idle",
                activeMCPCount: 0,
                activeBackgroundTasks: 0
            )

        case .conversation:
            conversationModel.sessionID = "sess-1"
            conversationModel.items = [
                TimelineItemPresentation(kind: .user(
                    content: "Please check the workspace revision barrier and verify if A->B->A transition invalidates stale context.",
                    attachments: [AttachmentPresentation(filename: "audit_r8.md", mediaType: "text/markdown", byteCount: 4500)]
                )),
                TimelineItemPresentation(kind: .thinking(
                    content: "Auditing CoreHost and ToolRuntime workspaceRevision checking logic...\nIdentified that stale context must be rejected via revision inequality.",
                    isExpanded: false
                )),
                TimelineItemPresentation(kind: .tool(
                    callID: "call-1",
                    toolName: "read_file",
                    summary: "read_file path: markerA.txt (workspaceRevision: 3)",
                    status: "success"
                )),
                TimelineItemPresentation(kind: .assistant(
                    content: "I have verified the workspace transition barrier. Even when the workspace path reverts from B back to A, the `workspaceRevision` advances from 1 to 3, ensuring any stale RunExecutionContext from revision 1 is rejected immediately.",
                    isStreaming: false
                ))
            ]
            conversationModel.isGenerating = false
            inspectorModel.telemetry = RuntimeInspectorPresentation(
                pcoreNodes: 1450,
                pcoreEdges: 3920,
                ecoreHeat: 0.35,
                cacheHitRatio: 0.88,
                tokensPerSecond: 64.0,
                retrievalWarmup: "ready",
                activeMCPCount: 4,
                activeBackgroundTasks: 0
            )

        case .streaming:
            conversationModel.sessionID = "sess-1"
            conversationModel.items = [
                TimelineItemPresentation(kind: .user(
                    content: "Generate a benchmark simulation for streaming tokens across macOS GUI.",
                    attachments: []
                )),
                TimelineItemPresentation(kind: .assistant(
                    content: "Simulating token generation... ",
                    isStreaming: true
                ))
            ]
            conversationModel.isGenerating = true
            inspectorModel.telemetry = RuntimeInspectorPresentation(
                pcoreNodes: 1450,
                pcoreEdges: 3920,
                ecoreHeat: 0.85,
                cacheHitRatio: 0.94,
                tokensPerSecond: 128.5,
                retrievalWarmup: "ready",
                activeMCPCount: 4,
                activeBackgroundTasks: 0
            )
            // 启动轻量定时模拟追加
            startMockStreaming()

        case .toolHeavy:
            conversationModel.sessionID = "sess-1"
            conversationModel.items = [
                TimelineItemPresentation(kind: .user(content: "Audit codebase graph and run computer use verification.", attachments: [])),
                TimelineItemPresentation(kind: .tool(callID: "t-1", toolName: "codebase_graph", summary: "Indexed 1250 files and 3480 AST symbols", status: "success")),
                TimelineItemPresentation(kind: .tool(callID: "t-2", toolName: "spawn_subagent", summary: "Child subagent 'GraphAuditor' spawned", status: "running")),
                TimelineItemPresentation(kind: .tool(callID: "t-3", toolName: "computer_batch", summary: "Executed 3 steps on macOS Screen [1920x1080]", status: "success")),
                TimelineItemPresentation(kind: .terminal(title: "Subagent Finished", isSuccess: true, message: "Child run completed with 0 errors."))
            ]
            conversationModel.isGenerating = false
            inspectorModel.telemetry.activeBackgroundTasks = 1

        case .permission:
            conversationModel.sessionID = "sess-1"
            conversationModel.items = [
                TimelineItemPresentation(kind: .user(content: "Execute sensitive terminal command: rm -rf .cache/temp", attachments: [])),
                TimelineItemPresentation(kind: .tool(callID: "p-1", toolName: "bash", summary: "Permission required: Execution of high-risk command", status: "waiting_permission"))
            ]
            conversationModel.isGenerating = false

        case .contextPressure:
            conversationModel.sessionID = "sess-1"
            conversationModel.items = [
                TimelineItemPresentation(kind: .user(content: "Analyze full repo codebase history and commit traces.", attachments: [])),
                TimelineItemPresentation(kind: .assistant(content: "Context window utilization is at 92%. Active compaction triggered.", isStreaming: false))
            ]
            conversationModel.isGenerating = false
            inspectorModel.telemetry.ecoreHeat = 0.96
            inspectorModel.telemetry.cacheHitRatio = 0.42

        case .mcpFailure:
            conversationModel.sessionID = "sess-1"
            conversationModel.items = [
                TimelineItemPresentation(kind: .user(content: "Query sqlite database via MCP", attachments: [])),
                TimelineItemPresentation(kind: .tool(callID: "m-1", toolName: "mcp_sqlite", summary: "Connection reset by peer (server crashed)", status: "failed")),
                TimelineItemPresentation(kind: .terminal(title: "MCP Fault Injected", isSuccess: false, message: "MCP Server 'sqlite' terminated unexpectedly. Core fail-closed safely."))
            ]
            conversationModel.isGenerating = false
            inspectorModel.telemetry.activeMCPCount = 3

        case .backgroundTask:
            conversationModel.sessionID = "sess-1"
            conversationModel.items = [
                TimelineItemPresentation(kind: .user(content: "Run test suite in background", attachments: [])),
                TimelineItemPresentation(kind: .tool(callID: "bg-1", toolName: "background_run", summary: "swift test --filter Round8SystemAuditTests (PID: 48920)", status: "running"))
            ]
            inspectorModel.telemetry.activeBackgroundTasks = 2

        case .providerReconnect:
            conversationModel.sessionID = "sess-1"
            conversationModel.items = [
                TimelineItemPresentation(kind: .user(content: "Send streaming query", attachments: [])),
                TimelineItemPresentation(kind: .assistant(content: "Provider connection dropped. Automatically reconnecting via ProviderConnectionFlow...", isStreaming: true))
            ]
            inspectorModel.telemetry.tokensPerSecond = 0.0
        }
    }

    private func startMockStreaming() {
        streamingTask = Task { @MainActor [weak self] in
            let mockTokens = ["LingXi", " Glass", " delivers", " zero-lag", " glassmorphism", " with", " completely", " isolated", " UI", " state."]
            for token in mockTokens {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, let self else { break }
                self.conversationModel.appendOrUpdateStreamingChunk(chunk: token)
            }
            guard !Task.isCancelled, let self else { return }
            self.conversationModel.finalizeStreaming()
        }
    }

    public func sendMessage(text: String, mode: String, attachments: [AttachmentPresentation]) {
        let userItem = TimelineItemPresentation(kind: .user(content: text, attachments: attachments))
        conversationModel.items.append(userItem)
        composerModel.clear()

        // 模拟 Assistant 回复
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self else { return }
            self.conversationModel.items.append(TimelineItemPresentation(
                kind: .assistant(content: "Echo [\(mode)]: \(text)", isStreaming: false)
            ))
        }
    }
}
