import Foundation
import LingXiPluginABI

/// The DeepSeek provider plugin. Everything vendor-specific is in this directory; the Core and the
/// ABI have no idea this exists.
final class MiMoCore: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var replay: MiMoCassetteStore?
    private var recorderStore: MiMoCassetteStore?
    private var replayMode = false
    private var recordPath: String?
    private var slowReplay = false
    private var hostAPI: UnsafePointer<LingXiHostAPI>?

    func attach(hostAPI: UnsafePointer<LingXiHostAPI>?) {
        lock.lock(); self.hostAPI = hostAPI; lock.unlock()
    }

    func start(granted: String) {
        var replayPath: String?
        var recording: String?
        var slow = false
        for grant in granted.split(separator: ",") {
            let text = String(grant).trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("vcr=") {
                replayPath = String(text.dropFirst(4))
            } else if text.hasPrefix("record=") {
                recording = String(text.dropFirst(7))
            } else if text == "fault.slow" {
                slow = true
            }
        }
        lock.lock()
        // A recorder is a cassette store too: without this, record-only mode had nothing to append
        // to and silently produced no file.
        replay = replayPath.map { MiMoCassetteStore(replayPath: $0) }
        // Recording output starts empty: loading the replay fixture into it would copy the
        // fixture's unconsumed exchanges into the recorded file.
        recorderStore = recording != nil ? MiMoCassetteStore(replayPath: nil) : nil
        replayMode = replayPath != nil
        recordPath = recording
        slowReplay = slow
        lock.unlock()
    }

    func invoke(requestID: String, capability: String, request: ProviderWireRequest) -> ABIStatusCode {
        guard capability == "provider.\(MiMoWire.providerID)" else { return .methodNotImplemented }

        let semaphore = DispatchSemaphore(value: 0)
        let outcome = StatusBox()
        let recorder = EventRecorder()
        let digest = MiMoWire.digest(for: request)
        let emit: @Sendable (ProviderWireEvent) -> Void = { [weak self] event in
            recorder.append(event)
            // Persist the cassette before the terminal reaches the kernel: the run returns as soon
            // as it sees `completed`, so writing afterwards races the caller (and its shutdown).
            if event.type == "completed", let self,
               let path = self.recordingPath(), let store = self.recordingCassette() {
                store.append(digest: digest, events: recorder.events, to: path)
            }
            self?.emit(requestID: requestID, event: event)
        }

        let task = Task { [weak self] in
            defer { semaphore.signal() }
            guard let self else { return }
            if self.isReplayMode(), let replay = self.cassetteStore() {
                if let events = replay.take(digest: digest) {
                    do {
                        try await MiMoTransport.replay(events: events, slow: self.isSlow(), emit: emit)
                    } catch is CancellationError {
                        outcome.set(.cancelled)
                    } catch {
                        emit(.init(type: "failed", failureKind: "transport", message: "\(error)"))
                        outcome.set(.capabilityFailed)
                    }
                } else {
                    emit(.init(
                        type: "failed", failureKind: "streamProtocol",
                        message: "cassette has no exchange for this request"
                    ))
                    outcome.set(.protocolViolation)
                }
            } else {
                do {
                    try await MiMoTransport.stream(request: request, requestID: requestID, emit: emit)
                } catch let error as MiMoTransport.TransportError {
                    let kind: String
                    switch error {
                    case .missingCredential: kind = "unauthorized"
                    case .streamEndedWithoutTerminal: kind = "streamProtocol"
                    case .httpStatus(let code): kind = Self.failureKind(forHTTP: code)
                    }
                    emit(.init(type: "failed", failureKind: kind, message: "\(error)"))
                    outcome.set(.capabilityFailed)
                } catch is CancellationError {
                    outcome.set(.cancelled)
                } catch {
                    emit(.init(type: "failed", failureKind: "transport", message: "\(error)"))
                    outcome.set(.capabilityFailed)
                }
            }
        }

        lock.lock()
        tasks[requestID] = task
        lock.unlock()
        semaphore.wait()
        lock.lock()
        tasks.removeValue(forKey: requestID)
        lock.unlock()
        return outcome.value
    }

    func cancel(requestID: String) {
        lock.lock()
        let task = tasks[requestID]
        lock.unlock()
        task?.cancel()
    }

    private func isReplayMode() -> Bool {
        lock.lock(); defer { lock.unlock() }; return replayMode
    }

    private func cassetteStore() -> MiMoCassetteStore? {
        lock.lock(); defer { lock.unlock() }; return replay
    }

    private func recordingCassette() -> MiMoCassetteStore? {
        lock.lock(); defer { lock.unlock() }; return recorderStore
    }

    private func isSlow() -> Bool {
        lock.lock(); defer { lock.unlock() }; return slowReplay
    }

    private func recordingPath() -> String? {
        lock.lock(); defer { lock.unlock() }; return recordPath
    }

    private func emit(requestID: String, event: ProviderWireEvent) {
        lock.lock()
        let api = hostAPI
        lock.unlock()
        guard let api, let emit = api.pointee.emit,
              let data = try? JSONEncoder().encode(ProviderWireEnvelope(requestID: requestID, event: event)) else {
            return
        }
        data.withUnsafeBytes { raw in
            "model.event".withCString { name in
                emit(name, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(data.count))
            }
        }
    }

    private static func failureKind(forHTTP code: Int) -> String {
        switch code {
        case 401, 403: "unauthorized"
        case 429: "rateLimited"
        case 400: "invalidRequest"
        case 500...599: "serverOverloaded"
        default: "transport"
        }
    }
}

private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ABIStatusCode = .ok
    func set(_ value: ABIStatusCode) { lock.lock(); stored = value; lock.unlock() }
    var value: ABIStatusCode { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ProviderWireEvent] = []
    func append(_ event: ProviderWireEvent) { lock.lock(); stored.append(event); lock.unlock() }
    var events: [ProviderWireEvent] { lock.lock(); defer { lock.unlock() }; return stored }
}

private let core = MiMoCore()
private let bundleID = "site.lingxi.provider.mimo"

private func emitJSON(_ value: some Encodable, out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, length: UnsafeMutablePointer<UInt32>?) -> Int32 {
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
        bundleID: bundleID,
        version: "1.0.0",
        hooks: [],
        providers: [ProviderIdentity(
            id: MiMoWire.providerID,
            models: MiMoWire.models,
            supportsParallelToolCalls: false,
            toolResultPlacement: "anywhereInHistory",
            credentials: [CredentialRequirement(
                id: "apiKey",
                label: "MiMo API Key",
                envVariable: "MIMO_API_KEY",
                helpURL: nil
            )]
        )]
    )
    return emitJSON(identity, out: out, length: length)
}

private let startImpl: @convention(c) (
    UnsafePointer<UInt8>?, UInt32, UnsafeMutablePointer<LingXiStatus>?
) -> Int32 = { granted, length, status in
    core.start(granted: LingXiBuffer.copyString(granted, length: length))
    status?.pointee = .make()
    return 0
}

private let stopImpl: @convention(c) () -> Int32 = { 0 }
private let disposeImpl: @convention(c) () -> Int32 = { 0 }

private let invokeImpl: @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<UInt8>?, UInt32,
    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<UInt32>?,
    UnsafeMutablePointer<LingXiStatus>?
) -> Int32 = { requestID, capability, payload, payloadLength, out, outLength, status in
    guard let requestID, let capability else {
        status?.pointee = .make(.protocolViolation)
        return -1
    }
    let bytes = LingXiBuffer.copyBytes(payload, length: payloadLength)
    guard let request = try? JSONDecoder().decode(ProviderWireRequest.self, from: Data(bytes)) else {
        status?.pointee = .make(.protocolViolation)
        return -1
    }
    out?.pointee = nil
    outLength?.pointee = 0
    let outcome = core.invoke(
        requestID: String(cString: requestID),
        capability: String(cString: capability),
        request: request
    )
    status?.pointee = .make(outcome)
    return outcome == .ok ? 0 : -1
}

private let cancelImpl: @convention(c) (UnsafePointer<CChar>?) -> Int32 = { identifier in
    guard let identifier else { return -1 }
    core.cancel(requestID: String(cString: identifier))
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
    guard hostABIMajor == LingXiABI.major else {
        outStatus?.pointee = .make(.abiViolation)
        return -1
    }
    guard let outAPI, let outABIMajor else {
        outStatus?.pointee = .make(.abiViolation)
        return -1
    }
    core.attach(hostAPI: hostAPI)
    outABIMajor.pointee = LingXiABI.major
    outAPI.pointee = PluginTable.pointer
    return 0
}
