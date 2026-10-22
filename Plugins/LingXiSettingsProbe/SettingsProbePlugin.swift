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
    private var viewport = SettingsViewport(width: 40, height: 12)
    private var sessionID: String?
    private var badFrame = false
    private var crashOnOpen = false

    func open(_ invocation: SettingsInvocation) {
        lock.lock()
        let shouldCrash = crashOnOpen
        lock.unlock()
        if shouldCrash { exit(1) }
        lock.lock()
        defer { lock.unlock() }
        sessionID = invocation.sessionID
        viewport = (invocation.viewport ?? viewport).clamped
        if let config = invocation.config?.object {
            if let value = config["name"]?.string { name = value }
            if case .bool(let value)? = config["enabled"] { enabled = value }
        }
    }

    func apply(_ invocation: SettingsInvocation) {
        lock.lock()
        defer { lock.unlock() }
        if let config = invocation.config?.object {
            if let value = config["name"]?.string { name = value }
            if case .bool(let value)? = config["enabled"] { enabled = value }
        }
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
            case "enter":
                enabled.toggle()
            default:
                break
            }
        case .paste:
            if let text = input.text, name.count < 30 {
                name += text.replacingOccurrences(of: "\n", with: " ")
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
        lock.unlock()
    }

    func reset() {
        lock.lock(); name = "probe"; enabled = true; sessionID = nil; lock.unlock()
    }

    func response(frame: Bool = true) -> SettingsResponse {
        lock.lock()
        defer { lock.unlock() }
        if badFrame {
            return SettingsResponse(
                frame: SettingsFrame(rows: [SettingsRow([SettingsSpan("\u{1B}[31mforged")])]),
                title: "Settings Probe"
            )
        }
        let rows = [
            SettingsRow([SettingsSpan("Settings Probe", fg: "fox", bold: true)]),
            SettingsRow([SettingsSpan("这个页面由插件自己绘制，宿主只提供边框。", fg: "dim")]),
            SettingsRow([]),
            SettingsRow([SettingsSpan("名称  "), SettingsSpan(name, fg: "string"), SettingsSpan("_", fg: "fox")]),
            SettingsRow([SettingsSpan(enabled ? "[x]" : "[ ]", fg: "fox"), SettingsSpan(" 启用示例选项")]),
            SettingsRow([]),
            SettingsRow([SettingsSpan("输入字符改名；Enter 切换；Ctrl-S 保存；Esc 取消。", fg: "muted")]),
        ]
        let clipped = (try? SettingsFrameValidator.validate(SettingsFrame(rows: rows), viewport: viewport))
            ?? SettingsFrame(rows: [])
        return SettingsResponse(frame: frame ? clipped : nil, title: "Settings Probe")
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
        guard let candidate = state.candidate() else {
            response = SettingsResponse(ok: false, error: "名称不能为空")
            break
        }
        response = SettingsResponse(config: candidate, ok: true)
    case .apply:
        state.apply(invocation)
        response = SettingsResponse(ok: true)
    case .commit:
        response = SettingsResponse(ok: true)
    case .cancel:
        state.reset()
        response = SettingsResponse(ok: true)
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
