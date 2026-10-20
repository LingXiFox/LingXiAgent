import Foundation
import LingXiPluginABI

/// The official example plugin, and the proof that the closure is real: a dynamic library the Host
/// `dlopen`s, written against the published ABI, changing one actual context assembly. Nothing in the
/// Core knows its name.
///
/// Capability: one `contextPrepare` hook that appends a single text entry.

private let bundleIdentifier = "site.lingxi.plugin.contextprobe"
private let pluginVersion = "1.0.0"
private let hookIdentifier = "contextProbe"
private let injectedEntryID = "probe.marker"

private func json(_ value: some Encodable) -> [UInt8] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return Array((try? encoder.encode(value)) ?? Data())
}

private func emit(_ bytes: [UInt8], out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, length outLength: UnsafeMutablePointer<UInt32>?) -> Bool {
    guard let out, let outLength else { return false }
    let (buffer, count) = LingXiBuffer.duplicate(bytes)
    out.pointee = buffer
    outLength.pointee = count
    return buffer != nil
}

private let describeImpl: @convention(c) (
    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<UInt32>?
) -> Int32 = { out, outLength in
    let identity = PluginIdentity(
        bundleID: bundleIdentifier,
        version: pluginVersion,
        hooks: [PluginIdentity.DeclaredHook(id: hookIdentifier, node: "contextPrepare", priority: 50, canVeto: false)]
    )
    return emit(json(identity), out: out, length: outLength) ? 0 : -1
}

/// Test-only cancellation state: a request id is cancellable while its invocation is in flight.
private final class CancellationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled: Set<String> = []
    private var slow = false

    func markSlow(_ value: Bool) { lock.lock(); slow = value; lock.unlock() }
    var isSlow: Bool { lock.lock(); defer { lock.unlock() }; return slow }
    func cancel(_ id: String) { lock.lock(); cancelled.insert(id); lock.unlock() }
    func consume(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled.remove(id) != nil
    }
}

private let registry = CancellationRegistry()

private let startImpl: @convention(c) (
    UnsafePointer<UInt8>?, UInt32, UnsafeMutablePointer<LingXiStatus>?
) -> Int32 = { granted, length, outStatus in
    let grantedText = LingXiBuffer.copyString(granted, length: length)
    registry.markSlow(grantedText.contains("fault.slow"))
    outStatus?.pointee = .make()
    return 0
}

private let stopImpl: @convention(c) () -> Int32 = { 0 }
private let disposeImpl: @convention(c) () -> Int32 = { 0 }

private let invokeImpl: @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<UInt8>?, UInt32,
    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<UInt32>?,
    UnsafeMutablePointer<LingXiStatus>?
) -> Int32 = { requestID, capability, payload, payloadLength, out, outLength, outStatus in
    guard let capability, String(cString: capability) == "hook.\(hookIdentifier)" else {
        outStatus?.pointee = .make(.methodNotImplemented)
        return -1
    }
    let identifier = requestID.map { String(cString: $0) } ?? ""
    if registry.isSlow {
        // A deliberately slow call, cancellable in 20ms steps: the host must stay responsive and a
        // cancel must be observed promptly rather than waiting the call out.
        var waited = 0
        while waited < 2_000 {
            if registry.consume(identifier) {
                outStatus?.pointee = .make(.cancelled)
                return -1
            }
            usleep(20_000)
            waited += 20
        }
    }
    let bytes = LingXiBuffer.copyBytes(payload, length: payloadLength)
    guard let invocation = try? HookWire.decode(HookWireInvocation.self, from: bytes) else {
        outStatus?.pointee = .make(.protocolViolation)
        return -1
    }

    // The one visible effect: a text entry appended to the request about to be sent.
    let marker = HookWireVerdict.WireInjection(
        id: injectedEntryID,
        text: "[context-probe] entries=\(invocation.entries.count) model=\(invocation.model)",
        segment: "derivedPage"
    )
    guard emit(json(HookWireVerdict.rewrite([marker])), out: out, length: outLength) else {
        outStatus?.pointee = .make(.capabilityFailed)
        return -1
    }
    outStatus?.pointee = .make()
    return 0
}

private let cancelImpl: @convention(c) (UnsafePointer<CChar>?) -> Int32 = { identifier in
    guard let identifier else { return -1 }
    registry.cancel(String(cString: identifier))
    return 0
}

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

/// The table must outlive the call: the host keeps this pointer for the plugin's lifetime, so it is
/// allocated once and never copied off a stack frame.
private enum PluginTable {
    // Immutable after creation and intentionally outlives every call.
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
    // A major mismatch is a hard failure. There is no compatibility path to fall back onto.
    guard hostABIMajor == LingXiABI.major else {
        outStatus?.pointee = .make(.abiViolation)
        return -1
    }
    guard let outAPI, let outABIMajor else {
        outStatus?.pointee = .make(.abiViolation)
        return -1
    }
    outABIMajor.pointee = LingXiABI.major
    outAPI.pointee = PluginTable.pointer
    return 0
}
