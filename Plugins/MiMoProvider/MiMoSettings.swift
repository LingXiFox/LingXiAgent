import Foundation
import LingXiPluginABI
import LingXiSettingsProtocol

/// MiMo's own settings page. The plugin owns every row, tab and key binding in this file; the host
/// only supplies the viewport, validation and the outer frame.
///
/// Layout contract, top to bottom: the tab row, one concise status line (dirty marker plus the
/// effective protocol/model/thinking summary), the page content, and the key hint. There are no
/// decorative blank rows: a settings frame is a control surface, not a document.
final class MiMoSettingsState: @unchecked Sendable {
    static let capability = "settings.view.v1"

    /// One clickable row action. The mouse path and the keyboard path share it, so a click can never
    /// reach a row the keyboard cannot select.
    private enum Action: Equatable {
        case tab(Int)
        /// Index among the current page's selectable items.
        case item(Int)
    }

    private struct Screen {
        var rows: [SettingsRow] = []
        /// One entry per row; `nil` marks a display-only row.
        var actions: [Action?] = []
        /// Title cell ranges on the tab row, so a click lands on the tab it points at.
        var tabColumns: [(range: Range<Int>, page: Int)] = []
    }

    private let lock = NSLock()
    private var draft = MiMoConfig()
    private var applied = MiMoConfig()
    private var viewport = SettingsViewport(width: 60, height: 20)
    private var page = 0
    private var selection = 0
    /// The advanced effort list starts collapsed: a single row expands it on demand.
    private var effortExpanded = false
    private var credentials: [SettingsCredentialStatus] = []
    private var note: String?
    private var pendingCommand: SettingsCommand?

    private let pages = ["Connection", "Protocol", "Model", "Advanced"]

    func handle(_ invocation: SettingsInvocation) -> SettingsResponse {
        switch invocation.op {
        case .open: return open(invocation)
        case .input:
            if let input = invocation.input { return handleInput(input) }
            return response()
        case .resize:
            if let viewport = invocation.viewport { return resize(viewport) }
            return response()
        case .prepareSave: return prepareSave()
        case .commit: return commit(invocation)
        case .apply: return apply(invocation)
        case .cancel:
            lock.lock()
            // Cancel always returns to what a save would have persisted, never to hard-coded
            // defaults: a reopened page must not silently forget the committed configuration.
            draft = applied
            note = nil
            lock.unlock()
            return SettingsResponse(dirty: false, ok: true)
        }
    }

    func open(_ invocation: SettingsInvocation) -> SettingsResponse {
        lock.lock()
        defer { lock.unlock() }
        viewport = (invocation.viewport ?? viewport).clamped
        credentials = invocation.credentials ?? []
        note = nil
        page = 0
        selection = 0
        effortExpanded = false
        if let config = invocation.config, let parsed = try? MiMoConfig(json: config) {
            draft = parsed
            applied = parsed
        } else {
            draft = applied
        }
        return response()
    }

    func handleInput(_ input: SettingsInput) -> SettingsResponse {
        lock.lock()
        defer { lock.unlock() }
        switch input.kind {
        case .key:
            switch input.key {
            case "up": select(selection - 1)
            case "down": select(selection + 1)
            case "left": setPage(page - 1)
            case "right": setPage(page + 1)
            case "tab": setPage((page + 1) % pages.count)
            case "enter": activate()
            default: break
            }
        case .mouse:
            handleMouse(input)
        case .resize:
            if let width = input.width, let height = input.height {
                viewport = SettingsViewport(width: width, height: height).clamped
            }
        case .credential:
            note = "凭据状态已刷新"
        default:
            break
        }
        clampSelection()
        return response()
    }

    func resize(_ viewport: SettingsViewport) -> SettingsResponse {
        lock.lock(); self.viewport = viewport.clamped; lock.unlock()
        return response()
    }

    func prepareSave() -> SettingsResponse {
        lock.lock()
        defer { lock.unlock() }
        do {
            _ = try draft.validated()
            return SettingsResponse(
                config: try JSONValue.encode(draft), preferredModel: draft.model,
                dirty: draft != applied, ok: true
            )
        } catch {
            return SettingsResponse(dirty: draft != applied, ok: false, error: "\(error)")
        }
    }

    func commit(_ invocation: SettingsInvocation) -> SettingsResponse {
        lock.lock()
        defer { lock.unlock() }
        if let config = invocation.config {
            guard let parsed = try? MiMoConfig(json: config) else {
                return SettingsResponse(dirty: draft != applied, ok: false, error: "invalid MiMo configuration")
            }
            applied = parsed
            draft = parsed
        } else {
            applied = draft
        }
        note = "已保存"
        return SettingsResponse(frame: response().frame, title: "MiMo Provider", dirty: false, ok: true)
    }

    func apply(_ invocation: SettingsInvocation) -> SettingsResponse {
        lock.lock()
        defer { lock.unlock() }
        guard let config = invocation.config, let parsed = try? MiMoConfig(json: config) else {
            return SettingsResponse(dirty: draft != applied, ok: false, error: "invalid MiMo configuration")
        }
        applied = parsed
        draft = parsed
        note = nil
        return SettingsResponse(frame: response().frame, title: "MiMo Provider", dirty: false, ok: true)
    }

    // MARK: - selection

    private var effortVisible: Bool {
        draft.protocolKind == .responses && draft.thinkingMode == .enabled
    }

    private var itemCount: Int {
        switch page {
        case 0: return 3
        case 1: return 2
        case 2: return MiMoWire.models.count
        case 3:
            let modes = MiMoThinkingMode.allCases.count
            guard effortVisible else { return modes }
            let expanded = effortExpanded ? 1 + MiMoReasoningEffort.allCases.count : 0
            return modes + 1 + expanded
        default: return 1
        }
    }

    private func select(_ target: Int) {
        selection = min(max(0, target), max(0, itemCount - 1))
    }

    private func clampSelection() {
        selection = min(max(0, selection), max(0, itemCount - 1))
    }

    private func setPage(_ target: Int) {
        page = min(max(0, target), pages.count - 1)
        selection = 0
    }

    private func activate() {
        switch page {
        case 0:
            guard let provider = credentials.first else {
                note = "插件没有声明凭据，无法配置连接。"
                return
            }
            switch selection {
            case 0:
                pendingCommand = SettingsCommand(type: "credential.update", providerID: provider.providerID)
                note = nil
            case 1:
                pendingCommand = SettingsCommand(type: "credential.remove", providerID: provider.providerID)
                note = nil
            default:
                note = "测试连接不发请求，只检查凭据是否已配置。"
            }
        case 1:
            draft.protocolKind = selection == 0 ? .chatCompletions : .responses
            if draft.protocolKind == .chatCompletions {
                // Chat Completions has no reasoning.effort; the effort list is Responses-only.
                draft.reasoningEffort = nil
                effortExpanded = false
            }
            note = nil
        case 2:
            if MiMoWire.models.indices.contains(selection) {
                draft.model = MiMoWire.models[selection]
            }
        case 3:
            activateAdvanced()
        default:
            break
        }
    }

    private func activateAdvanced() {
        let modes = MiMoThinkingMode.allCases
        if selection < modes.count {
            draft.thinkingMode = modes[selection]
            if draft.thinkingMode != .enabled {
                draft.reasoningEffort = nil
                effortExpanded = false
            }
            note = nil
            return
        }
        guard effortVisible else { return }
        if selection == modes.count {
            effortExpanded.toggle()
            return
        }
        let effortIndex = selection - modes.count - 1
        let efforts = MiMoReasoningEffort.allCases
        if effortIndex == 0 {
            draft.reasoningEffort = nil
            note = "使用服务端默认 effort"
        } else if efforts.indices.contains(effortIndex - 1) {
            draft.reasoningEffort = efforts[effortIndex - 1].rawValue
            note = nil
        }
    }

    /// Mouse coordinates are relative to the plugin frame origin. A click selects and activates in
    /// one step, exactly like moving the cursor and pressing Enter. A wheel notch also carries the
    /// cell it happened over, so the non-zero delta wins: wheeling must move the selection without
    /// applying whatever row happens to sit under the pointer.
    private func handleMouse(_ input: SettingsInput) {
        if let delta = input.delta, delta != 0 {
            // +1 is one wheel notch up, -1 is one notch down.
            select(selection - delta)
            return
        }
        guard let row = input.row else { return }
        let screen = buildScreen()
        guard row >= 0, row < screen.rows.count else { return }
        if row == 0 {
            guard let column = input.column,
                  let tab = screen.tabColumns.first(where: { $0.range.contains(column) })
            else { return }
            setPage(tab.page)
            return
        }
        guard let action = screen.actions[row] else { return }
        apply(action)
    }

    private func apply(_ action: Action) {
        switch action {
        case .tab(let index):
            setPage(index)
        case .item(let index):
            selection = index
            activate()
            clampSelection()
        }
    }

    // MARK: - rendering

    private func response() -> SettingsResponse {
        let screen = buildScreen()
        let clipped = (try? SettingsFrameValidator.validate(
            SettingsFrame(rows: screen.rows), viewport: viewport
        )) ?? SettingsFrame(rows: [])
        let command = pendingCommand
        pendingCommand = nil
        return SettingsResponse(
            frame: clipped, title: "MiMo Provider", command: command,
            dirty: draft != applied
        )
    }

    private func buildScreen() -> Screen {
        var screen = Screen()
        screen.rows.append(tabRow(&screen.tabColumns))
        screen.actions.append(nil)
        screen.rows.append(statusRow())
        screen.actions.append(nil)
        switch page {
        case 0: renderConnection(&screen)
        case 1: renderProtocol(&screen)
        case 2: renderModel(&screen)
        default: renderAdvanced(&screen)
        }
        if let note {
            screen.rows.append(SettingsRow([SettingsSpan(note, fg: "dim")]))
            screen.actions.append(nil)
        }
        screen.rows.append(SettingsRow([
            SettingsSpan("↑/↓ 选择  ←/→ 切页  Enter 应用  Ctrl-S 保存  Esc 取消", fg: "muted"),
        ]))
        screen.actions.append(nil)
        return screen
    }

    private func tabRow(_ columns: inout [(range: Range<Int>, page: Int)]) -> SettingsRow {
        var spans: [SettingsSpan] = []
        var column = 0
        for (index, title) in pages.enumerated() {
            let active = index == page
            let text = (active ? "▸ " : "  ") + title
            let width = SettingsFrameValidator.displayWidth(text)
            columns.append((column..<(column + width), index))
            spans.append(SettingsSpan(text, fg: active ? "fox" : "dim", bold: active))
            column += width
            if index != pages.count - 1 {
                spans.append(SettingsSpan("   ", fg: "muted"))
                column += 3
            }
        }
        return SettingsRow(spans)
    }

    private func statusRow() -> SettingsRow {
        let dirty = draft != applied
        var spans: [SettingsSpan] = []
        spans.append(SettingsSpan(dirty ? "● 未保存" : "已保存", fg: dirty ? "error" : "dim", bold: dirty))
        spans.append(SettingsSpan("  " + summary, fg: "muted"))
        return SettingsRow(spans)
    }

    /// One line, three facts: the protocol in use, the routed model and the thinking selection. The
    /// effort only appears where it is actually sent (Responses with thinking enabled).
    private var summary: String {
        var parts = [
            draft.protocolKind == .chatCompletions ? "Chat" : "Responses",
            draft.model,
            "思考:\(draft.thinkingMode.shortLabel)",
        ]
        if effortVisible {
            let effort = draft.reasoningEffort
                .flatMap(MiMoReasoningEffort.init(rawValue:))?.wireValue ?? "服务端默认"
            parts.append("effort=\(effort)")
        }
        return parts.joined(separator: " · ")
    }

    private func heading(_ text: String) -> SettingsRow {
        SettingsRow([SettingsSpan(text, fg: "fox", bold: true)])
    }

    private func selectableRow(
        index: Int, marker: String?, checked: Bool, label: String, detail: String? = nil
    ) -> SettingsRow {
        let active = index == selection
        var spans: [SettingsSpan] = [SettingsSpan(active ? "▸ " : "  ", fg: "fox")]
        if let marker {
            spans.append(SettingsSpan(marker + " ", fg: checked ? "success" : "muted"))
        }
        spans.append(SettingsSpan(label, fg: active ? "cream" : "dim"))
        if let detail { spans.append(SettingsSpan("  " + detail, fg: "muted")) }
        return SettingsRow(spans)
    }

    private func radioRow(index: Int, checked: Bool, label: String, detail: String? = nil) -> SettingsRow {
        selectableRow(
            index: index, marker: checked ? "(•)" : "( )", checked: checked, label: label, detail: detail
        )
    }

    private func checkRow(index: Int, checked: Bool, label: String, detail: String? = nil) -> SettingsRow {
        selectableRow(
            index: index, marker: checked ? "[x]" : "[ ]", checked: checked, label: label, detail: detail
        )
    }

    private func renderConnection(_ screen: inout Screen) {
        let provider = credentials.first
        let status: String
        if let provider {
            status = provider.configured ? "已配置（\(provider.source)）" : "未配置"
        } else {
            status = "无凭据声明"
        }
        screen.rows.append(heading("Connection"))
        screen.actions.append(nil)
        screen.rows.append(SettingsRow([
            SettingsSpan("API Key  "),
            SettingsSpan(status, fg: provider?.configured == true ? "success" : "error"),
        ]))
        screen.actions.append(nil)
        let items = ["更新凭据（宿主安全输入）", "删除凭据", "测试连接（只检查配置，不发起请求）"]
        for (index, item) in items.enumerated() {
            screen.rows.append(selectableRow(
                index: index, marker: nil, checked: false, label: item
            ))
            screen.actions.append(.item(index))
        }
    }

    private func renderProtocol(_ screen: inout Screen) {
        screen.rows.append(heading("API Protocol"))
        screen.actions.append(nil)
        let items = [
            ("Chat Completions", "thinking.type"),
            ("Responses", "reasoning.effort / 工具续接"),
        ]
        for (index, item) in items.enumerated() {
            let checked = (draft.protocolKind == .chatCompletions) == (index == 0)
            screen.rows.append(checkRow(index: index, checked: checked, label: item.0, detail: item.1))
            screen.actions.append(.item(index))
        }
    }

    private func renderModel(_ screen: inout Screen) {
        screen.rows.append(heading("Model"))
        screen.actions.append(nil)
        for (index, model) in MiMoWire.models.enumerated() {
            screen.rows.append(checkRow(index: index, checked: draft.model == model, label: model))
            screen.actions.append(.item(index))
        }
    }

    private func renderAdvanced(_ screen: inout Screen) {
        screen.rows.append(heading("Thinking"))
        screen.actions.append(nil)
        let modes = MiMoThinkingMode.allCases
        for (index, mode) in modes.enumerated() {
            screen.rows.append(radioRow(
                index: index, checked: draft.thinkingMode == mode, label: mode.label
            ))
            screen.actions.append(.item(index))
        }
        guard effortVisible else { return }
        let effort = draft.reasoningEffort
            .flatMap(MiMoReasoningEffort.init(rawValue:))?.wireValue ?? "服务端默认"
        screen.rows.append(selectableRow(
            index: modes.count, marker: effortExpanded ? "▾" : "▸", checked: false,
            label: "高级 effort",
            detail: "当前 \(effort) · \(effortExpanded ? "收起" : "展开")"
        ))
        screen.actions.append(.item(modes.count))
        guard effortExpanded else { return }
        let serverDefault = modes.count + 1
        screen.rows.append(radioRow(
            index: serverDefault, checked: draft.reasoningEffort == nil, label: "服务端默认"
        ))
        screen.actions.append(.item(serverDefault))
        for (offset, effortLevel) in MiMoReasoningEffort.allCases.enumerated() {
            let item = serverDefault + 1 + offset
            screen.rows.append(radioRow(
                index: item, checked: draft.reasoningEffort == effortLevel.rawValue,
                label: effortLevel.rawValue, detail: "→ \(effortLevel.wireValue)"
            ))
            screen.actions.append(.item(item))
        }
    }
}
