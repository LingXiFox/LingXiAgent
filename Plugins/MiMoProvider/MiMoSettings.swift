import Foundation
import LingXiPluginABI
import LingXiSettingsProtocol

/// MiMo's own settings page. The plugin owns every row, tab and key binding in this file; the host
/// only supplies the viewport, validation and the outer frame.
final class MiMoSettingsState: @unchecked Sendable {
    static let capability = "settings.view.v1"

    private let lock = NSLock()
    private var draft = MiMoConfig()
    private var applied = MiMoConfig()
    private var viewport = SettingsViewport(width: 60, height: 20)
    private var page = 0
    private var selection = 0
    private var credentials: [SettingsCredentialStatus] = []
    private var note: String?

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
            lock.lock(); draft = applied; note = nil; lock.unlock()
            return SettingsResponse(ok: true)
        }
    }

    func open(_ invocation: SettingsInvocation) -> SettingsResponse {
        lock.lock()
        defer { lock.unlock() }
        viewport = (invocation.viewport ?? viewport).clamped
        credentials = invocation.credentials ?? []
        note = nil
        selection = 0
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
            case "up": selection = max(0, selection - 1)
            case "down": selection = min(max(0, itemCount - 1), selection + 1)
            case "left": page = max(0, page - 1); selection = 0
            case "right": page = min(pages.count - 1, page + 1); selection = 0
            case "tab": page = (page + 1) % pages.count; selection = 0
            case "enter":
                activate()
            default:
                break
            }
        case .resize:
            if let width = input.width, let height = input.height {
                viewport = SettingsViewport(width: width, height: height).clamped
            }
        case .credential:
            note = "凭据状态已刷新"
        default:
            break
        }
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
                config: try JSONValue.encode(draft), preferredModel: draft.model, ok: true
            )
        } catch {
            return SettingsResponse(ok: false, error: "\(error)")
        }
    }

    func commit(_ invocation: SettingsInvocation) -> SettingsResponse {
        lock.lock()
        defer { lock.unlock() }
        if let config = invocation.config, let parsed = try? MiMoConfig(json: config) {
            applied = parsed
            draft = parsed
        }
        note = "已保存"
        return SettingsResponse(frame: response().frame, title: "MiMo Provider", ok: true)
    }

    func apply(_ invocation: SettingsInvocation) -> SettingsResponse {
        lock.lock()
        defer { lock.unlock() }
        guard let config = invocation.config, let parsed = try? MiMoConfig(json: config) else {
            return SettingsResponse(ok: false, error: "invalid MiMo configuration")
        }
        applied = parsed
        draft = parsed
        return SettingsResponse(ok: true)
    }

    // MARK: - state

    private var itemCount: Int {
        switch page {
        case 0: 3
        case 1: 2
        case 2: MiMoWire.models.count
        case 3: thinkingItemCount
        default: 1
        }
    }

    private var thinkingItemCount: Int {
        if draft.protocolKind != .responses || draft.thinkingMode != .enabled {
            return MiMoThinkingMode.allCases.count
        }
        return MiMoThinkingMode.allCases.count + MiMoReasoningEffort.allCases.count + 1
    }

    private func activate() {
        switch page {
        case 0:
            guard let provider = credentials.first else { return }
            switch selection {
            case 0: pendingCommand = SettingsCommand(type: "credential.update", providerID: provider.providerID)
            case 1: pendingCommand = SettingsCommand(type: "credential.remove", providerID: provider.providerID)
            default: note = "连接测试需要真实网络凭据，本页不发起付费请求。"
            }
        case 1:
            draft.protocolKind = selection == 0 ? .chatCompletions : .responses
            if draft.protocolKind == .chatCompletions { draft.reasoningEffort = nil }
            note = nil
        case 2:
            if MiMoWire.models.indices.contains(selection) {
                draft.model = MiMoWire.models[selection]
            }
        case 3:
            applyThinkingSelection()
        default:
            break
        }
    }

    private var pendingCommand: SettingsCommand?

    private func applyThinkingSelection() {
        let modes = MiMoThinkingMode.allCases
        if selection < modes.count {
            draft.thinkingMode = modes[selection]
            if draft.thinkingMode != .enabled { draft.reasoningEffort = nil }
            return
        }
        guard draft.protocolKind == .responses, draft.thinkingMode == .enabled else { return }
        let effortIndex = selection - modes.count
        let efforts = MiMoReasoningEffort.allCases
        if effortIndex < efforts.count {
            draft.reasoningEffort = efforts[effortIndex].rawValue
        } else {
            draft.reasoningEffort = nil
            note = "使用服务端默认 effort"
        }
    }

    // MARK: - rendering

    private func response() -> SettingsResponse {
        let rows = renderRows()
        let clipped = (try? SettingsFrameValidator.validate(SettingsFrame(rows: rows), viewport: viewport))
            ?? SettingsFrame(rows: [])
        let command = pendingCommand
        pendingCommand = nil
        return SettingsResponse(frame: clipped, title: "MiMo Provider", command: command)
    }

    private func renderRows() -> [SettingsRow] {
        var rows: [SettingsRow] = []
        rows.append(SettingsRow(tabs()))
        rows.append(SettingsRow([]))
        switch page {
        case 0: renderConnection(&rows)
        case 1: renderProtocol(&rows)
        case 2: renderModel(&rows)
        default: renderAdvanced(&rows)
        }
        rows.append(SettingsRow([]))
        if let note {
            rows.append(SettingsRow([SettingsSpan(note, fg: "dim")]))
        }
        rows.append(SettingsRow([
            SettingsSpan("←/→ 切页  ↑/↓ 选择  Enter 应用  Ctrl-S 保存  Esc 取消", fg: "muted"),
        ]))
        return rows
    }

    private func tabs() -> [SettingsSpan] {
        pages.enumerated().flatMap { index, title -> [SettingsSpan] in
            let active = index == page
            var spans = [SettingsSpan(active ? "▸ \(title)" : "  \(title)", fg: active ? "fox" : "dim", bold: active)]
            if index != pages.count - 1 { spans.append(SettingsSpan("   ", fg: "muted")) }
            return spans
        }
    }

    private func renderConnection(_ rows: inout [SettingsRow]) {
        let provider = credentials.first
        let status: String
        if let provider {
            status = provider.configured ? "已配置（\(provider.source)）" : "未配置"
        } else {
            status = "无凭据声明"
        }
        rows.append(SettingsRow([SettingsSpan("Connection", fg: "fox", bold: true)]))
        rows.append(SettingsRow([SettingsSpan("API Key  "), SettingsSpan(status, fg: provider?.configured == true ? "success" : "error")]))
        rows.append(SettingsRow([]))
        let items = ["更新凭据（宿主安全输入）", "删除凭据", "测试连接（不自动发请求）"]
        for (index, item) in items.enumerated() {
            rows.append(SettingsRow([
                SettingsSpan(index == selection ? "▸ " : "  ", fg: "fox"),
                SettingsSpan(item, fg: index == selection ? "cream" : "dim"),
            ]))
        }
    }

    private func renderProtocol(_ rows: inout [SettingsRow]) {
        rows.append(SettingsRow([SettingsSpan("API Protocol", fg: "fox", bold: true)]))
        let items = [
            ("Chat Completions", "已稳定 / 默认"),
            ("Responses", "支持 reasoning.effort 与工具续接"),
        ]
        for (index, item) in items.enumerated() {
            let selected = (draft.protocolKind == .chatCompletions ? 0 : 1) == index
            rows.append(SettingsRow([
                SettingsSpan(index == selection ? "▸ " : "  ", fg: "fox"),
                SettingsSpan(selected ? "[x] " : "[ ] ", fg: selected ? "success" : "muted"),
                SettingsSpan(item.0, fg: index == selection ? "cream" : "dim"),
                SettingsSpan("  " + item.1, fg: "muted"),
            ]))
        }
    }

    private func renderModel(_ rows: inout [SettingsRow]) {
        rows.append(SettingsRow([SettingsSpan("Model", fg: "fox", bold: true)]))
        for (index, model) in MiMoWire.models.enumerated() {
            let selected = draft.model == model
            rows.append(SettingsRow([
                SettingsSpan(index == selection ? "▸ " : "  ", fg: "fox"),
                SettingsSpan(selected ? "[x] " : "[ ] ", fg: selected ? "success" : "muted"),
                SettingsSpan(model, fg: index == selection ? "cream" : "dim"),
            ]))
        }
    }

    private func renderAdvanced(_ rows: inout [SettingsRow]) {
        rows.append(SettingsRow([SettingsSpan("Thinking", fg: "fox", bold: true)]))
        let modes = MiMoThinkingMode.allCases
        let labels = ["服务端默认", "开启思考", "关闭思考"]
        for (index, mode) in modes.enumerated() {
            let selected = draft.thinkingMode == mode
            rows.append(SettingsRow([
                SettingsSpan(index == selection ? "▸ " : "  ", fg: "fox"),
                SettingsSpan(selected ? "(•) " : "( ) "),
                SettingsSpan(labels[index], fg: index == selection ? "cream" : "dim"),
            ]))
        }
        guard draft.protocolKind == .responses, draft.thinkingMode == .enabled else { return }
        rows.append(SettingsRow([]))
        rows.append(SettingsRow([SettingsSpan("reasoning.effort", fg: "fox", bold: true)]))
        let efforts = MiMoReasoningEffort.allCases
        for (index, effort) in efforts.enumerated() {
            let selected = draft.reasoningEffort == effort.rawValue
            let item = modes.count + index
            rows.append(SettingsRow([
                SettingsSpan(item == selection ? "▸ " : "  ", fg: "fox"),
                SettingsSpan(selected ? "(•) " : "( ) "),
                SettingsSpan(effort.rawValue, fg: item == selection ? "cream" : "dim"),
                SettingsSpan("  → \(effort.wireValue)", fg: "muted"),
            ]))
        }
        let defaultIndex = modes.count + efforts.count
        rows.append(SettingsRow([
            SettingsSpan(defaultIndex == selection ? "▸ " : "  ", fg: "fox"),
            SettingsSpan(draft.reasoningEffort == nil ? "(•) " : "( ) "),
            SettingsSpan("服务端默认", fg: defaultIndex == selection ? "cream" : "dim"),
        ]))
        rows.append(SettingsRow([SettingsSpan("MiMo 目前实际只区分关闭与开启；其余档位尚未形成不同推理强度。", fg: "error")]))
    }
}
