#if canImport(SwiftUI)
import Foundation
import SwiftUI
import Combine
import LingXiClient
import LingXiProtocol

/// 前端运行时契约
@MainActor
public protocol FrontendRuntime: AnyObject {
    var sidebarModel: SidebarPresentationModel { get }
    var conversationModel: ConversationPresentationModel { get }
    var inspectorModel: RuntimeInspectorPresentationModel { get }
    var composerModel: ComposerModel { get }

    func sendMessage(text: String, mode: AgentRunMode, attachments: [AttachmentPresentation])
    func stopGenerating()
    func resolveInteraction(interactionID: String, approved: Bool)
    func switchSession(id: String)
    func newSession()
    func switchStageTab(_ tab: TaskStageViewTab)
    func finalizeTask(action: TaskFinalizeAction)
    func submitSideQuestion(question: String) async -> String
}

/// RuntimeFrontend: 真实 macOS 原生前端运行时
/// 底层由 LingXiClientVNext 提供正式 RPC 支持，同时具备离线/预览纯内存回退能力
@MainActor
public final class RuntimeFrontend: FrontendRuntime, ObservableObject {
    public let sidebarModel: SidebarPresentationModel
    public let conversationModel: ConversationPresentationModel
    public let inspectorModel: RuntimeInspectorPresentationModel
    public let composerModel: ComposerModel

    public var client: LingXiClientVNext?
    private var activeStreamingTask: Task<Void, Never>?

    public init(client: LingXiClientVNext? = nil) {
        self.client = client
        self.sidebarModel = SidebarPresentationModel()
        self.conversationModel = ConversationPresentationModel()
        self.inspectorModel = RuntimeInspectorPresentationModel()
        self.composerModel = ComposerModel()

        setupInitialState()
    }

    private func setupInitialState() {
        let defaultTask = TaskPresentation(
            taskID: "task-init",
            objective: "macOS Sonoma 原生 SwiftUI 界面交付与契约对接",
            state: "running",
            criteria: [
                SuccessCriterion(criterionID: "c1", description: "两栏 NavigationSplitView + .inspector() 原生结构", isSatisfied: true),
                SuccessCriterion(criterionID: "c2", description: "暖墨底、单品牌强调色（狐橙）、原生 Gauge 上下文健康度", isSatisfied: true),
                SuccessCriterion(criterionID: "c3", description: "HITL 审批内联卡片与 AppKit NSTextView Composer 桥接", isSatisfied: false)
            ],

            artifacts: [
                TaskArtifact(ordinal: 1, kind: "spec", ref: "Docs/GUI-DESIGN-SPECIFICATION.md", version: 1),
                TaskArtifact(ordinal: 2, kind: "diff", ref: "git-diff-b4.patch", version: 2, parentVersion: 1)
            ],
            worktreeBranch: "feat/gui-v1-foundation"
        )

        let initialSession = SessionItemPresentation(
            id: "sess-1",
            title: "Phase 4: SwiftUI 原生前端与契约对接",
            lastUpdated: Date(),
            messageCount: 3,
            mode: "Build",
            isActive: true,
            tasks: [defaultTask]
        )

        let folder = SessionFolderPresentation(
            folderName: "LingXiAgent",
            sessions: [initialSession]
        )

        sidebarModel.folders = [folder]
        sidebarModel.selectedSessionID = initialSession.id
        sidebarModel.selectedTaskID = defaultTask.taskID

        conversationModel.sessionID = initialSession.id
        conversationModel.activeTask = defaultTask
        conversationModel.stageTab = .actionFlow
        conversationModel.items = [
            TimelineItemPresentation(
                timestamp: Date().addingTimeInterval(-120),
                kind: .user(content: "主人已下令：按照文档 /Users/lingxifox/Downloads/GUI-DESIGN-SPECIFICATION.md 开工！", attachments: [])
            ),
            TimelineItemPresentation(
                timestamp: Date().addingTimeInterval(-60),
                kind: .thinking(content: "本狐已解析 GUI 规范 v1.2.0。正在梳理双栏布局、任务三视图与原生控件...", isExpanded: true, durationSeconds: 2.4, tokenCount: 420)
            ),
            TimelineItemPresentation(
                timestamp: Date().addingTimeInterval(-10),
                kind: .assistant(content: "主人，本狐已就位！macOS 原生双栏结构、任务控制条、Context Health 优雅仪表已全部接入。", isStreaming: false)
            )
        ]

        inspectorModel.criteria = defaultTask.criteria
        inspectorModel.artifacts = defaultTask.artifacts
        inspectorModel.contextHealth = ContextHealthPresentation(usedTokens: 48_200, maxTokens: 128_000)
    }

    // MARK: - Frontend Actions

    public func sendMessage(
        text: String,
        mode: AgentRunMode = .build,
        attachments: [AttachmentPresentation] = []
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // 1. 追加用户消息
        conversationModel.items.append(
            TimelineItemPresentation(kind: .user(content: text, attachments: attachments))
        )
        composerModel.clear()
        conversationModel.isGenerating = true

        // 2. 如果存在真实 client，发起真实 Turn
        if let client = client, !conversationModel.sessionID.isEmpty {
            activeStreamingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let sessionID = SessionID(self.conversationModel.sessionID)
                    let input = UserInput(text: text)
                    _ = try await client.turn.submitTurn(sessionID: sessionID, input: input)

                } catch {
                    self.conversationModel.items.append(
                        TimelineItemPresentation(kind: .terminal(title: "RPC Error", isSuccess: false, message: error.localizedDescription))
                    )
                    self.conversationModel.isGenerating = false
                }
            }
        } else {
            // 离线/预览模式：模拟流式生成
            activeStreamingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
                let sampleChunks = ["🦊 ", "本狐收到主人的指令！", " 正在以 ", mode.rawValue, " 模式为您全力以赴构建。"]
                for chunk in sampleChunks {
                    if Task.isCancelled { break }
                    self.conversationModel.appendOrUpdateStreamingChunk(chunk: chunk)
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
                self.conversationModel.finalizeStreaming()
            }
        }
    }

    public func stopGenerating() {
        activeStreamingTask?.cancel()
        activeStreamingTask = nil
        conversationModel.finalizeStreaming()
    }

    public func resolveInteraction(interactionID: String, approved: Bool) {
        // 更新本地展示卡片
        if let idx = conversationModel.items.firstIndex(where: {
            if case .interaction(let card) = $0.kind, card.interactionID == interactionID { return true }
            return false
        }) {
            if case .interaction(var card) = conversationModel.items[idx].kind {
                card.status = approved ? .approved : .rejected
                conversationModel.items[idx].kind = .interaction(card: card)
            }
        }

        // 若有 Client，通知后端
        if let client = client, !conversationModel.sessionID.isEmpty {
            Task {
                let decision: PermissionDecision = approved ? .allow : .deny
                let resolution = InteractionResolution.permission(decision)
                _ = try? await client.interaction.resolve(
                    sessionID: SessionID(self.conversationModel.sessionID),
                    interactionID: InteractionID(interactionID),
                    resolution: resolution
                )
            }
        }
    }


    public func switchSession(id: String) {
        sidebarModel.selectedSessionID = id
        conversationModel.sessionID = id

        // 查找选中的 session 与 task
        for folder in sidebarModel.folders {
            if let sess = folder.sessions.first(where: { $0.id == id }) {
                conversationModel.activeTask = sess.tasks.first
                if let task = sess.tasks.first {
                    inspectorModel.criteria = task.criteria
                    inspectorModel.artifacts = task.artifacts
                }
                break
            }
        }
    }

    public func newSession() {
        let newID = "sess-\(UUID().uuidString.prefix(6))"
        let newTask = TaskPresentation(
            taskID: "task-\(UUID().uuidString.prefix(6))",
            objective: "新会话任务",
            state: "queued"
        )
        let newSession = SessionItemPresentation(
            id: newID,
            title: "新会话 \(Date().formatted(date: .omitted, time: .shortened))",
            tasks: [newTask]
        )

        if sidebarModel.folders.isEmpty {
            sidebarModel.folders = [SessionFolderPresentation(folderName: "Default", sessions: [newSession])]
        } else {
            sidebarModel.folders[0].sessions.insert(newSession, at: 0)
        }

        switchSession(id: newID)
    }

    public func switchStageTab(_ tab: TaskStageViewTab) {
        conversationModel.stageTab = tab
    }

    public func finalizeTask(action: TaskFinalizeAction) {
        guard var task = conversationModel.activeTask else { return }
        switch action {
        case .accept:
            task.state = "completed"
        case .discard:
            task.state = "cancelled"
        case .finish:
            task.state = "completed"
        }
        conversationModel.activeTask = task

        if let client = client {
            Task {
                _ = try? await client.task.finalize(taskID: TaskID(task.taskID), action: action)
            }
        }
    }

    public func submitSideQuestion(question: String) async -> String {
        guard let client = client else {
            return "（预览模式）侧问回答：\(question)"
        }
        do {
            let res = try await client.turn.submitSideQuestion(
                sessionID: SessionID(conversationModel.sessionID),
                question: question
            )
            return res.answer
        } catch {
            return "侧问失败: \(error.localizedDescription)"
        }
    }
}
#endif
