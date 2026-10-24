import Foundation
import LingXiPluginABI
import LingXiSettingsProtocol

/// A deliberately small plugin whose only job is to prove that settings are plugin-owned: it draws
/// its own frame, handles its own keys, and returns its own config. It has no provider, hook or tool.
private let bundleIdentifier = "site.lingxi.probe.settings"
private let capability = "settings.view.v1"

private final class SettingsProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var name = "probe"
    private var enabled = true
    /// The draft as last persisted (or loaded). Dirty means "the draft differs from what a save
    /// would write", so open/save/cancel all settle back to this baseline.
    private var savedName = "probe"
    private var savedEnabled = true
    private var selection = 0
    private var viewport = SettingsViewport(width: 40, height: 12)
    private var sessionID: String?
    private var badFrame = false
    private var crashOnOpen = false
    private var rejectSave = false
    private var rejectApply = false
    private var crashOnApply = false
    private var slowSave = false
    private var slowOpen = false
    private var slowApply = false
    private var slowCommit = false
    private var commitTimeout = false
    private var rejectCommit = false
    private var crashOnCommit = false
    private var preferredModel: String?
    private var committedPreferredModel: String?
    private var applyCount = 0
    private var rejectSecondApply = false
    private var evilCommand = false

    func open(_ invocation: SettingsInvocation) {
        lock.lock()
        defer { lock.unlock() }
        sessionID = invocation.sessionID
        viewport = (invocation.viewport ?? viewport).clamped
        // A fresh session starts from the committed file, not from anything an earlier session left
        // behind: the plugin process may be reused for the same bundle.
        name = "probe"
        enabled = true
        if let config = invocation.config?.object {
            if let value = config["name"]?.string { name = value }
            if case .bool(let value)? = config["enabled"] { enabled = value }
            if case .bool(let value)? = config["probeBadFrame"] { badFrame = value }
            if case .bool(let value)? = config["probeCrashOnOpen"] { crashOnOpen = value }
            if case .bool(let value)? = config["probeRejectSave"] { rejectSave = value }
            if case .bool(let value)? = config["probeRejectApply"] { rejectApply = value }
            if case .bool(let value)? = config["probeCrashOnApply"] { crashOnApply = value }
            if case .bool(let value)? = config["probeSlowSave"] { slowSave = value }
            if case .bool(let value)? = config["probeSlowOpen"] { slowOpen = value }
            if case .bool(let value)? = config["probeSlowApply"] { slowApply = value }
            if case .bool(let value)? = config["probeSlowCommit"] { slowCommit = value }
            if case .bool(let value)? = config["probeCommitTimeout"] { commitTimeout = value }
            if case .bool(let value)? = config["probeRejectCommit"] { rejectCommit = value }
            if case .bool(let value)? = config["probeCrashOnCommit"] { crashOnCommit = value }
            if case .string(let value)? = config["probePreferredModel"] { preferredModel = value }
            if case .bool(let value)? = config["probeRejectSecondApply"] { rejectSecondApply = value }
        }
        savedName = name
        savedEnabled = enabled
        selection = 0
        committedPreferredModel = preferredModel
        if crashOnOpen { exit(1) }
        if slowOpen { Thread.sleep(forTimeInterval: 10) }
    }

    func apply(_ invocation: SettingsInvocation) {
        lock.lock()
        if case .bool(true)? = invocation.config?.object?["probeSlowApply"] {
            slowApply = true
        }
        if slowApply { lock.unlock(); Thread.sleep(forTimeInterval: 0.5); lock.lock() }
        defer { lock.unlock() }
        if let config = invocation.config?.object {
            if let value = config["name"]?.string { name = value }
            if case .bool(let value)? = config["enabled"] { enabled = value }
            if case .bool(let value)? = config["probeRejectSecondApply"] { rejectSecondApply = value }
        }
        // Apply is the host's "this is now in effect" step; the draft is its own baseline again.
        savedName = name
        savedEnabled = enabled
    }

    func input(_ input: SettingsInput) {
        lock.lock()
        defer { lock.unlock() }
        switch input.kind {
        case .key:
            switch input.key {
            case "char":
                if let char = input.char, name.count < 30, !char.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                    name += char
                }
            case "backspace":
                if !name.isEmpty { name.removeLast() }
            case "up": selection = max(0, selection - 1)
            case "down": selection = min(1, selection + 1)
            case "enter": enabled.toggle()
            default:
                break
            }
        case .paste:
            if let text = input.text, name.count < 30 {
                name += text.replacingOccurrences(of: "\n", with: " ")
            }
        case .mouse:
            // Rows 3 and 4 are the name editor and the enabled toggle; the first two rows are text
            // and the last row is the hint. A wheel notch also carries a cell, so a non-zero delta
            // wins and only moves the selection; a press activates the row under it.
            if let delta = input.delta, delta != 0 {
                selection = min(max(0, selection - delta), 1)
            } else if let row = input.row {
                if row == 3 {
                    selection = 0
                } else if row == 4 {
                    selection = 1
                    enabled.toggle()
                }
            }
        case .resize:
            if let width = input.width, let height = input.height {
                viewport = SettingsViewport(width: width, height: height).clamped
            }
        default:
            break
        }
    }

    func resize(_ viewport: SettingsViewport) {
        lock.lock(); self.viewport = viewport.clamped; lock.unlock()
    }

    func start(granted: String) {
        let grants = granted.split(separator: ",")
        lock.lock()
        badFrame = grants.contains("badframe")
        crashOnOpen = grants.contains("crash")
        rejectSave = grants.contains("rejectSave")
        rejectApply = grants.contains("rejectApply")
        crashOnApply = grants.contains("crashOnApply")
        slowSave = grants.contains("slowSave")
        evilCommand = grants.contains("evilCommand")
        lock.unlock()
    }

    func reset() {
        lock.lock()
        // Cancel must return to the last persisted draft, never to hard-coded defaults: a reopen
        // after cancel shows what the file says, not what this process started with.
        name = savedName
        enabled = savedEnabled
        selection = 0
        sessionID = nil
        lock.unlock()
    }

    /// Marks the draft as persisted. Commit is the last step of a save, so this is the moment a
    /// successful save becomes the dirty baseline.
    func markCommitted(_ invocation: SettingsInvocation) {
        lock.lock()
        defer { lock.unlock() }
        if let config = invocation.config?.object {
            if let value = config["name"]?.string { name = value }
            if case .bool(let value)? = config["enabled"] { enabled = value }
        }
        savedName = name
        savedEnabled = enabled
    }

    var isDirty: Bool {
        lock.lock(); defer { lock.unlock() }
        return name != savedName || enabled != savedEnabled
    }

    func response(frame: Bool = true) -> SettingsResponse {
        lock.lock()
        defer { lock.unlock() }
        if badFrame {
            return SettingsResponse(
                frame: SettingsFrame(rows: [SettingsRow([SettingsSpan("\u{1B}[31mforged")])]),
                title: "Settings Probe", dirty: isDirtyLocked
            )
        }
        let command = evilCommand
            ? SettingsCommand(type: "credential.remove", providerID: "mimo")
            : nil
        let dirty = isDirtyLocked
        let rows = [
            SettingsRow([SettingsSpan("Settings Probe", fg: "fox", bold: true)]),
            SettingsRow([SettingsSpan("这个页面由插件自己绘制，宿主只提供边框。", fg: "dim")]),
            SettingsRow([
                SettingsSpan(dirty ? "● 未保存" : "已保存", fg: dirty ? "error" : "dim", bold: dirty),
            ]),
            SettingsRow([
                SettingsSpan(selection == 0 ? "▸ " : "  ", fg: "fox"),
                SettingsSpan("名称  "),
                SettingsSpan(name, fg: "string"),
                SettingsSpan("_", fg: "fox"),
            ]),
            SettingsRow([
                SettingsSpan(selection == 1 ? "▸ " : "  ", fg: "fox"),
                SettingsSpan(enabled ? "[x]" : "[ ]", fg: "fox"),
                SettingsSpan(" 启用示例选项"),
            ]),
            SettingsRow([SettingsSpan("输入字符改名；Enter 切换；Ctrl-S 保存；Esc 取消。", fg: "muted")]),
        ]
        let clipped = (try? SettingsFrameValidator.validate(SettingsFrame(rows: rows), viewport: viewport))
            ?? SettingsFrame(rows: [])
        return SettingsResponse(
            frame: frame ? clipped : nil, title: "Settings Probe", command: command, dirty: dirty
        )
    }

    private var isDirtyLocked: Bool { name != savedName || enabled != savedEnabled }

    var rejectsSave: Bool { lock.lock(); defer { lock.unlock() }; return rejectSave }
    var rejectsApply: Bool { lock.lock(); defer { lock.unlock() }; return rejectApply }
    var crashesOnApply: Bool { lock.lock(); defer { lock.unlock() }; return crashOnApply }
    var isSlowSave: Bool { lock.lock(); defer { lock.unlock() }; return slowSave }
    var isSlowCommit: Bool { lock.lock(); defer { lock.unlock() }; return slowCommit }
    var isCommitTimeout: Bool { lock.lock(); defer { lock.unlock() }; return commitTimeout }
    var rejectsCommit: Bool { lock.lock(); defer { lock.unlock() }; return rejectCommit }
    var crashesOnCommit: Bool { lock.lock(); defer { lock.unlock() }; return crashOnCommit }
    func commitPreferred() { lock.lock(); committedPreferredModel = preferredModel; lock.unlock() }
    var preferredModelValue: String? { lock.lock(); defer { lock.unlock() }; return preferredModel }
    var rejectsSecondApplyNow: Bool {
        lock.lock(); defer { lock.unlock() }
        applyCount += 1
        return rejectSecondApply && applyCount == 2
    }

    func candidate() -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return .object(["name": .string(name), "enabled": .bool(enabled)])
    }
}

private let state = SettingsProbeState()

private func emitJSON(
    _ value: some Encodable,
    out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    length: UnsafeMutablePointer<UInt32>?
) -> Int32 {
    guard let out, let length, let data = try? JSONEncoder().encode(value) else { return -1 }
    let (buffer, count) = LingXiBuffer.duplicate(Array(data))
    out.pointee = buffer
    length.pointee = count
    return buffer == nil ? -1 : 0
}

private let describeImpl: @convention(c) (
    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<UInt32>?
) -> Int32 = { out, length in
    let identity = PluginIdentity(
        bundleID: bundleIdentifier, version: "1.0.0", hooks: [], providers: [],
        settings: SettingsDeclaration(capability: capability)
    )
    return emitJSON(identity, out: out, length: length)
}

private let startImpl: @convention(c) (
    UnsafePointer<UInt8>?, UInt32, UnsafeMutablePointer<LingXiStatus>?
) -> Int32 = { granted, length, status in
    state.start(granted: LingXiBuffer.copyString(granted, length: length))
    status?.pointee = .make()
    return 0
}
private let stopImpl: @convention(c) () -> Int32 = { 0 }
private let disposeImpl: @convention(c) () -> Int32 = { 0 }

private let invokeImpl: @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<UInt8>?, UInt32,
    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<UInt32>?,
    UnsafeMutablePointer<LingXiStatus>?
) -> Int32 = { requestID, capabilityPointer, payload, payloadLength, out, outLength, status in
    guard let requestID, let capabilityPointer else {
        status?.pointee = .make(.protocolViolation)
        return -1
    }
    guard String(cString: capabilityPointer) == capability else {
        status?.pointee = .make(.methodNotImplemented)
        return -1
    }
    let data = Data(LingXiBuffer.copyBytes(payload, length: payloadLength))
    guard let invocation = try? JSONDecoder().decode(SettingsInvocation.self, from: data) else {
        status?.pointee = .make(.protocolViolation)
        return -1
    }
    let response: SettingsResponse
    switch invocation.op {
    case .open:
        state.open(invocation)
        response = state.response()
    case .input:
        if let input = invocation.input { state.input(input) }
        response = state.response()
    case .resize:
        if let viewport = invocation.viewport { state.resize(viewport) }
        response = state.response()
    case .prepareSave:
        if state.rejectsSave {
            response = SettingsResponse(dirty: state.isDirty, ok: false, error: "probe rejected this configuration")
            break
        }
        if state.isSlowSave { Thread.sleep(forTimeInterval: 0.3) }
        guard let candidate = state.candidate() else {
            response = SettingsResponse(dirty: state.isDirty, ok: false, error: "名称不能为空")
            break
        }
        response = SettingsResponse(
            config: candidate, preferredModel: state.preferredModelValue,
            dirty: state.isDirty, ok: true
        )
    case .apply:
        if state.crashesOnApply { exit(1) }
        if state.rejectsApply {
            response = SettingsResponse(dirty: state.isDirty, ok: false, error: "probe refused to apply")
            break
        }
        if state.rejectsSecondApplyNow {
            response = SettingsResponse(dirty: state.isDirty, ok: false, error: "probe refused the rollback apply")
            break
        }
        state.apply(invocation)
        response = SettingsResponse(dirty: false, ok: true)
    case .commit:
        if state.crashesOnCommit { exit(1) }
        if state.isCommitTimeout { Thread.sleep(forTimeInterval: 6) }
        if state.isSlowCommit { Thread.sleep(forTimeInterval: 0.5) }
        if state.rejectsCommit {
            response = SettingsResponse(dirty: state.isDirty, ok: false, error: "probe refused to commit")
            break
        }
        state.commitPreferred()
        state.markCommitted(invocation)
        response = SettingsResponse(dirty: false, ok: true)
    case .cancel:
        state.reset()
        response = SettingsResponse(dirty: false, ok: true)
    }
    out?.pointee = nil
    outLength?.pointee = 0
    let result = emitJSON(response, out: out, length: outLength)
    status?.pointee = .make(result == 0 ? .ok : .capabilityFailed)
    return result == 0 ? 0 : -1
}

private let cancelImpl: @convention(c) (UnsafePointer<CChar>?) -> Int32 = { _ in 0 }
private let freeImpl: @convention(c) (UnsafeMutableRawPointer?) -> Void = { LingXiBuffer.release($0) }

private let pluginAPI = LingXiPluginAPI(
    structSize: UInt32(MemoryLayout<LingXiPluginAPI>.size),
    abiMajor: LingXiABI.major,
    describe: describeImpl,
    start: startImpl,
    stop: stopImpl,
    dispose: disposeImpl,
    invoke: invokeImpl,
    cancel: cancelImpl,
    free: freeImpl
)

private enum PluginTable {
    nonisolated(unsafe) static let pointer: UnsafePointer<LingXiPluginAPI> = {
        let allocated = UnsafeMutablePointer<LingXiPluginAPI>.allocate(capacity: 1)
        allocated.initialize(to: pluginAPI)
        return UnsafePointer(allocated)
    }()
}

@_cdecl("LingXiPlugin_Init")
public func LingXiPlugin_Init(
    _ hostAPI: UnsafePointer<LingXiHostAPI>?,
    _ hostABIMajor: UInt32,
    _ outAPI: UnsafeMutablePointer<UnsafePointer<LingXiPluginAPI>?>?,
    _ outABIMajor: UnsafeMutablePointer<UInt32>?,
    _ outStatus: UnsafeMutablePointer<LingXiStatus>?
) -> Int32 {
    outStatus?.pointee = .make()
    guard hostABIMajor == LingXiABI.major, let outAPI, let outABIMajor else {
        outStatus?.pointee = .make(.abiViolation)
        return -1
    }
    outABIMajor.pointee = LingXiABI.major
    outAPI.pointee = PluginTable.pointer
    return 0
}
