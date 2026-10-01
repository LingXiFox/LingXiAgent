import Foundation
import Testing
@testable import LingXiCore
import LingXiProtocol

/// §8, §9, §10 and the §30 layout freeze, checked together.
///
/// The three sections each asked for a Core capability to become reachable; §30 asked that the
/// existing 运行上下文 card not be touched while doing it. Those pull in opposite directions —
/// an inspector is most conveniently built by expanding the card — so the freeze is asserted
/// mechanically rather than promised.
@Suite("Runtime detail closure", .serialized)
struct ContextInspectorClosureTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - §8 context search and exact entry

    @Test("search and exact-entry reads are reachable from a surface")
    func contextInspectorIsWired() throws {
        let view = try source("Apps/macOS/FrontendKit/Components/ContextInspectorView.swift")
        let runtime = try source("Apps/macOS/FrontendKit/Frontend/RuntimeFrontend.swift")
        #expect(view.contains("client.context.search(sessionID:") || runtime.contains("client.context.search(sessionID:"),
                "§8 要求的 searchContext 没有界面调用")
        #expect(view.contains("client.context.getEntry(sessionID:") || runtime.contains("client.context.getEntry(sessionID:"),
                "§8 要求的 getContextEntry 没有界面调用")
        // Session-scoped: the inspector must query the session Core is showing, not a fixed one.
        let method = runtime[runtime.range(of: "func searchCurrentContext")!.lowerBound...]
            .components(separatedBy: "\n").prefix(6).joined(separator: "\n")
        #expect(method.contains("lastState.activeSessionID") || method.contains("activeSessionID"),
                "上下文搜索不能写死一个会话 id")
    }

    @Test("compact goes through the RPC and re-reads")
    func compactIsNotLocal() throws {
        let runtime = try source("Apps/macOS/FrontendKit/Frontend/RuntimeFrontend.swift")
        let body = runtime[runtime.range(of: "func compactCurrentContext")!.lowerBound...]
            .components(separatedBy: "\n").prefix(while: { !$0.hasPrefix("    }") })
        #expect(body.contains { $0.contains("client.context.compact(sessionID:") }, "压缩要走 RPC")
        #expect(!body.contains { $0.contains("try? await client.context.compact") },
                "压缩是用户动作，不允许 try? 吞错")
        #expect(body.contains { $0.contains("refreshContextInspector()") },
                "压缩后要回读权威状态")
    }

    // MARK: - §9 extension detail

    @Test("an extension row can ask Core for its own status")
    func extensionStatusIsReadable() throws {
        let store = try source("Apps/macOS/FrontendKit/Settings/SettingsStore.swift")
        let page = try source("Apps/macOS/FrontendKit/Settings/SettingsSystemPages.swift")
        #expect(store.contains("client.extensionDomain.getStatus(id:"),
                "§9 的 getStatus 没有 GUI 调用点")
        #expect(page.contains("ExtensionDetailRow"), "扩展详情面板不存在")
        // A read that failed must not silently keep showing the last known state as current.
        #expect(page.contains("Core 没有回答这个扩展的当前状态"),
                "读不到状态时必须说清楚，而不是继续显示列表里的旧值")
    }

    /// §9: unsupported capabilities must not be presented as buttons. `ExtensionInfo` carries no
    /// uninstallable / configurable / commands flag, so offering those actions would guess.
    @Test("extension actions are limited to what the runtime can answer")
    func noSpeculativeExtensionButtons() throws {
        let page = try source("Apps/macOS/FrontendKit/Settings/SettingsSystemPages.swift")
        #expect(!page.contains("client.extensionDomain.uninstall("),
                "没有 uninstallable 标志就提供卸载按钮，是在猜")
        #expect(!page.contains("client.extensionDomain.install("),
                "安装需要调用方指名对象，属于 ops 而不是列表开关")
    }

    // MARK: - §10 diagnostics

    @Test("performance metrics reach a surface and the fabricated global metrics are gone")
    func diagnosticsAreReal() throws {
        let gui = try source("Apps/macOS/FrontendKit/Components/ContextInspectorView.swift")
        let runtime = try source("Apps/macOS/FrontendKit/Frontend/RuntimeFrontend.swift")
        #expect(gui.contains("runtime.inspectorModel.performance"), "性能报告没有渲染点")
        #expect(runtime.contains("client.diagnostics.getPerformanceMetrics(sessionID:"),
                "§10.1 要求真实指标可达")
        let core = try source("Sources/LingXiCore/App/CoreHost.swift")
        #expect(!core.contains("payload: ProviderMetricsInfo(requestCount: 0"),
                "伪造的全局指标又回来了")
        #expect(!core.contains("spans: [\"run.start\", \"run.finish\"]"),
                "§10.2 禁止的固定两 span 假 trace 又回来了")
    }

    // MARK: - §30 the frozen card

    /// The card 运行上下文 keeps its rings, bars, metric grouping and text order. Everything the
    /// new sections needed went into a separate window; this asserts the card was not "improved".
    @Test("the persistent context card was not redesigned")
    func contextCardIsUntouched() throws {
        let lines = try source("Apps/macOS/FrontendKit/Components/AgentStatusHUD.swift")
            .components(separatedBy: "\n")
        func indexOf(_ marker: String) -> Int? {
            lines.firstIndex { $0.contains(marker) }
        }
        // The card's own body: from its declaration to the next property declaration. Searching
        // there rather than across the file matters — `Spacer(minLength: 0)` also appears in the
        // collapsed HUD, and `contextChart` is *used* inside the card but declared after it.
        let cardStart = try #require(indexOf("private var contextCard: some View"))
        var cardEnd = lines.count - 1
        for index in (cardStart + 1)..<lines.count {
            if lines[index].hasPrefix("    private var ") { cardEnd = index; break }
        }
        // In the order the card actually lays them out: ring+bar chart, then cache hit, P-Core,
        // E-Core. `Spacer(minLength: 0)` is deliberately not a marker — the card uses one in its
        // header row as well, so it does not pin any position.
        let markers = ["Text(\"运行上下文\")", "contextChart", "metric(\"缓存命中\"",
                       "metric(\"P-Core\"", "Text(eCoreBytes)"]
        let positions = markers.map { marker -> (String, Int?) in
            for index in cardStart..<cardEnd where lines[index].contains(marker) { return (marker, index) }
            return (marker, nil)
        }
        for (marker, at) in positions {
            #expect(at != nil, "运行上下文卡片少了「\(marker)」——§30 要求它原样保留")
        }
        let ordered = positions.compactMap { $0.1 }
        #expect(ordered == ordered.sorted(),
                "运行上下文内部的指标顺序被改动了：\(positions.map { "\"\($0.0)\"@\($0.1 ?? -1)" })")

        // Layout order, not declaration order: within the pane, the two new sections come after
        // the card.
        let paneStart = try #require(indexOf("private var contextPane: some View"))
        let layout = ["contextCard", "subagentSection", "taskSection"].map { name in
            lines[(paneStart + 1)..<min(paneStart + 30, lines.count)]
                .firstIndex { $0.contains(name) }
                .map { $0 + paneStart + 1 }
        }
        for (name, at) in zip(["contextCard", "subagentSection", "taskSection"], layout) {
            #expect(at != nil, "contextPane 里没有渲染 \(name)")
        }
        let compact = layout.compactMap { $0 }
        #expect(compact == compact.sorted(),
                "右侧栏的堆叠顺序变了：\(zip(["contextCard", "subagentSection", "taskSection"], layout))")
    }

    /// §30 also forbids squeezing the card to make room.
    @Test("the sidebar scrolls instead of compressing the context card")
    func sidebarScrolls() throws {
        let hud = try source("Apps/macOS/FrontendKit/Components/AgentStatusHUD.swift")
        let pane = hud[hud.range(of: "private var contextPane: some View")!.lowerBound...]
            .components(separatedBy: "\n").prefix(while: { !$0.hasPrefix("    }") })
            .joined(separator: "\n")
        #expect(pane.contains("ScrollView"), "整列必须可纵向滚动")
        #expect(pane.contains("contextCard"), "运行上下文应作为整体放进滚动列，而不是被拆散")
        #expect(!pane.contains(".frame(height:") && !pane.contains("GeometryReader"),
                "滚动列不该给运行上下文加固定高度——§30 第 5 条禁止为下面的模块腾空间而压缩它")
    }
}
