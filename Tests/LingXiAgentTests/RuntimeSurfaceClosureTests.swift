import Foundation
import Testing
@testable import LingXiCore
import LingXiProtocol

/// §6 and §7 of the closure contract: the Agent tree and the Task lifecycle are Core's, and the
/// GUI reads them rather than editing its own copy.
///
/// The defects being pinned out were specific. `finalizeTask` wrote `task.state = "completed"`
/// into the presentation model and then fired the RPC with `try?`, so a rejected finalize still
/// showed as done. `resumeRun` did the same thing inside Core: `try?` around the real resume,
/// then `applied: true` carrying the *pre-resume* snapshot — a failed resume was
/// indistinguishable from a successful one.
@Suite("Runtime surface closure", .serialized)
struct RuntimeSurfaceClosureTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The body of a declaration, as lines: from the line containing `marker` down to the first
    /// line that closes it at member indentation. Line arrays keep these checks readable when
    /// the thing being asserted is a statement order.
    private static func lines(_ relative: String, from marker: String) throws -> [String] {
        let text = try source(relative)
        guard let at = text.range(of: marker) else {
            Issue.record("\(relative) 里找不到 \(marker)")
            return []
        }
        let after = text[at.lowerBound...]
        return Array(after.components(separatedBy: "\n").prefix(while: { !$0.hasPrefix("    }") }))
    }

    // MARK: - §7.1 no optimistic local mutation

    @Test("finalizing a task cannot rewrite GUI state before Core answers")
    func finalizeIsNotStateOnly() throws {
        let gui = try Self.source("Apps/macOS/FrontendKit/Frontend/RuntimeFrontend.swift")
        let start = try #require(gui.range(of: "public func finalizeTask"))
        let body = gui[start.lowerBound...].components(separatedBy: "\n").prefix(while: { !$0.hasPrefix("    }") })
        let lines = Array(body)

        #expect(!lines.contains { $0.contains("conversationModel.activeTask = task") },
                "GUI 不允许先把自己的任务状态改掉再发请求")
        #expect(!lines.contains { $0.contains("task.state =") },
                "先改本地 state 就是 §7.1 禁止的 optimistic mutation")
        let calls = lines.enumerated().filter { $0.element.contains("client.task.finalize") }
        #expect(calls.count == 1, "收尾应当只发一次命令")
        let after = lines[calls[0].offset...]
        #expect(!after.contains(where: { $0.contains("try? await client.task.finalize") }),
                "收尾是用户显式动作，不允许 try? 吞错")
        #expect(after.contains(where: { $0.contains("actionError =") }),
                "失败必须有可见反馈")
        #expect(after.contains(where: { $0.contains("reloadTasks") || $0.contains("refreshTasks") }),
                "成功后必须回读 Core 权威快照，而不是本地推断")
    }

    @Test("the task surface exposes the RPCs that actually exist")
    func taskDomainIsFullyReached() throws {
        let gui = try Self.source("Apps/macOS/FrontendKit/Frontend/RuntimeFrontend.swift")
        let pane = try Self.source("Apps/macOS/FrontendKit/Components/WarmToolPane.swift")
        // §7 listed these as covered-but-stale. Each must be called somewhere in the GUI, not
        // merely declared by the client.
        // Some go through `taskAction { try await $0.finalize(...) }`, so the receiver is written
        // as `$0` rather than `client.task`. Matching the selector is what proves the call exists.
        for (method, surface) in [("finalize", pane), ("listArtifacts", pane), ("getReport", pane),
                                  ("updateCriteria", gui)] {
            #expect(surface.contains("client.task.\(method)") || surface.contains("$0.\(method)"),
                    "Task Domain 的 \(method) 在 GUI 里没有调用点")
        }
    }

    /// A button that claims more than Core can do is as bad as no button. Finalize collapses
    /// `accept` and `finish` onto the same transition, so offering both would be theatre.
    @Test("the finalize UI offers only the two transitions Core distinguishes")
    func finalizeActionsMatchCoreSemantics() throws {
        let core = try Self.source("Sources/LingXiCore/App/CoreHost+TaskService.swift")
        #expect(core.contains("envelope.payload.action == .discard ? .cancel : .complete"),
                "Core 的收尾语义变了，这个测试要跟着重新判断能露出几个动作")
        let pane = try Self.source("Apps/macOS/FrontendKit/Components/WarmToolPane.swift")
        #expect(!pane.contains("action: .accept"), "accept 与 finish 在 Core 是同一条转移，不该做成两个按钮")
        #expect(pane.contains("action: .finish") && pane.contains("action: .discard"))
    }

    // MARK: - §6 resume only when resumable

    @Test("resuming a terminal run fails instead of reporting a successful no-op")
    func resumeRunRejectsTerminal() async throws {
        let core = try Self.source("Sources/LingXiCore/App/CoreHost.swift")
        let start = try #require(core.range(of: "public func resumeRun(envelope:"))
        let body = Array(core[start.lowerBound...].components(separatedBy: "\n").prefix(while: { !$0.hasPrefix("    }") }))

        #expect(!body.contains(where: { $0.contains("_ = try? await agent?.resumeAgentRun") }),
                "resume 的错误被 try? 吞掉，就是伪成功")
        #expect(body.contains(where: { $0.contains("run.status.isTerminal") }),
                "终态 Run 必须明确不可恢复")
        #expect(body.contains(where: { $0.contains("await agent.resumeAgentRun") }),
                "恢复必须真的执行并把错误传出来")
        // The receipt must carry the post-resume snapshot, not the one read before the attempt.
        let resultLine = body.firstIndex { $0.contains("result: ") }
        let refreshed = body.firstIndex { $0.contains("let resumed") }
        #expect(resultLine != nil && refreshed != nil && refreshed! < resultLine!,
                "回执应携带恢复之后重新读取的快照")
    }

    @Test("the agent tree is read from Core and its actions re-read it")
    func agentTreeComesFromCore() throws {
        let lines = try Self.lines("Apps/macOS/FrontendKit/Frontend/RuntimeFrontend.swift",
                                   from: "public func refreshAgentTree")
        #expect(lines.contains { $0.contains("client.run.getAgentTree(sessionID:") },
                "Agent 树必须由 getAgentTree 取得，不能由时间线拼一个看起来像的")

        let all = try Self.source("Apps/macOS/FrontendKit/Frontend/RuntimeFrontend.swift")
        for method in ["cancelRun", "resumeRun"] {
            #expect(all.contains("client.run.\(method)"), "Run 的 \(method) 未接入")
        }

        let resume = try Self.lines("Apps/macOS/FrontendKit/Frontend/RuntimeFrontend.swift",
                                    from: "public func resumeAgentRun")
        #expect(resume.contains { $0.contains("await refreshAgentTree()") },
                "恢复之后必须回读权威树")
        #expect(resume.contains { $0.contains("actionError =") }, "恢复失败必须可见")
    }

    /// Resume must not be offered for a state that cannot take it (§6: 不支持恢复就不显示可点 Resume).
    @Test("Resume is offered only for states Core can resume")
    func resumeButtonIsGated() throws {
        let rows = try Self.lines("Apps/macOS/FrontendKit/Components/AgentTreeSheet.swift",
                                  from: "private var row: some View")
        let guardLine = rows.firstIndex { $0.contains("Button(\"恢复\")") }
        #expect(guardLine != nil, "Agent 树里没有恢复入口")
        let condition = rows[0..<guardLine!].reversed().first { $0.contains("if run.status") }
        let text = try #require(condition, "恢复按钮没有状态前置条件")
        for terminal in ["completed", "cancelled", "timedOut"] {
            #expect(!text.contains(".\(terminal)"),
                    "终态 \(terminal) 不该出现在恢复条件里：Core 现在会直接拒绝")
        }
        let cancel = rows.first { $0.contains("Button(\"取消\")") }
        #expect(cancel != nil, "Agent 树应能取消运行中的 Run")
    }

    // MARK: - §28 the invariant, checked mechanically

    /// The whole contract reduces to one sentence: runtime state lives on the right and comes
    /// from Core. Anything the left sidebar can click must be persistent knowledge, not this run.
    @Test("the sidebar's runtime sections read from the projected snapshot, not local guesses")
    func sidebarSectionsAreProjected() throws {
        let hud = try Self.source("Apps/macOS/FrontendKit/Components/AgentStatusHUD.swift")
        let sidebar = try Self.source("Apps/macOS/FrontendKit/Components/SidebarView.swift")
        #expect(hud.contains("live?.subagents"), "子代理状态必须来自 Core 投影")
        #expect(hud.contains("live?.todos"), "Task / To-do 必须来自 Core 投影")
        // §1.1: nothing that only exists during a run may appear in the left sidebar.
        for leak in ["subagent", "agentTree", "todo", "permission request", "browser session"] {
            #expect(!sidebar.lowercased().contains(leak),
                    "左侧出现了运行态概念「\(leak)」，§1.1 规定它属于右侧")
        }
    }
}
