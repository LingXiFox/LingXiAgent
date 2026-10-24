import Foundation
import LingXiPluginABI
import LingXiSettingsProtocol

/// The MiMo provider plugin. Everything vendor-specific is in this directory; the Core and the
/// ABI have no idea this exists.
final class MiMoCore: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var requestExecutions: [String: String] = [:]
    private var replay: MiMoCassetteStore?
    private var recorderStore: MiMoCassetteStore?
    private var replayMode = false
    private var recordPath: String?
    private var slowReplay = false
    private var hostAPI: UnsafePointer<LingXiHostAPI>?
    private var currentConfig = MiMoConfig()
    /// One snapshot per Run. Tool rounds reuse it; it is dropped at the terminal that ends the Run
    /// (or on cancellation), so a settings save mid-Run cannot change protocol or thinking.
    private var executionConfigs: [String: MiMoConfig] = [:]
    private var executionOrder: [String] = []
    private static let maxExecutionSnapshots = 64
    /// Offline test hook: a loopback endpoint supplied as a grant. Production grants never set it.
    private var endpointOverride: URL?

    func attach(hostAPI: UnsafePointer<LingXiHostAPI>?) {
        lock.lock(); self.hostAPI = hostAPI; lock.unlock()
    }

    func start(granted: String) throws {
        var replayPath: String?
        var recording: String?
        var slow = false
        var startupConfig: JSONValue?
        var endpoint: URL?
        for grant in granted.split(separator: ",") {
            let text = String(grant).trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("vcr=") {
                replayPath = String(text.dropFirst(4))
            } else if text.hasPrefix("record=") {
                recording = String(text.dropFirst(7))
            } else if text == "fault.slow" {
                slow = true
            } else if text.hasPrefix("config=") {
                let raw = String(text.dropFirst(7))
                guard let data = Data(base64Encoded: raw),
                      let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                    throw MiMoConfigError.notAnObject
                }
                startupConfig = decoded
            } else if text.hasPrefix("test.endpoint=") {
                let raw = String(text.dropFirst(14))
                guard let url = URL(string: raw), Self.isLoopback(url) else {
                    throw MiMoConfigError.invalidTestEndpoint(raw)
                }
                endpoint = url
            }
        }
        let applied = try startupConfig.map { try MiMoConfig(json: $0) } ?? MiMoConfig()

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
        currentConfig = applied
        executionConfigs.removeAll()
        executionOrder.removeAll()
        endpointOverride = endpoint
        lock.unlock()
    }

    /// Called by the settings capability once it lands. The JSON form validates first, so a bad
    /// candidate never replaces the last good configuration.
    @discardableResult
    func applySettings(_ config: JSONValue) throws -> MiMoConfig {
        let parsed = try MiMoConfig(json: config)
        applySettings(parsed)
        return parsed
    }

    func applySettings(_ config: MiMoConfig) {
        lock.lock()
        currentConfig = config
        lock.unlock()
    }

    func invoke(requestID: String, capability: String, request: ProviderWireRequest) -> ABIStatusCode {
        guard capability == "provider.\(MiMoWire.providerID)" else { return .methodNotImplemented }

        // Every phase is measured from this instant, so the report never goes backwards and the
        // caller can subtract phases without a second clock.
        let timing = MiMoTimingTracker(replay: isReplayMode())
        // Snapshot before digesting: the digest must describe the exact settings this invocation
        // will use, including the execution's first protocol/thinking choice and any temporary
        // frontend thinking selection, which wins over the saved config for this request only.
        let config = effectiveConfig(for: request)
        let digest = MiMoWire.digest(for: request, config: config)
        let legacyDigest = MiMoWire.legacyDigestIfApplicable(for: request, config: config)
        let executionID = request.executionID
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = StatusBox()
        let recorder = EventRecorder()
        let emit: @Sendable (ProviderWireEvent) -> Void = { [weak self] event in
            guard let self else { return }
            if event.type == "reasoningDelta" { timing.mark(.firstReasoning) }
            if event.type == "textDelta" { timing.mark(.firstText) }
            // Timing is observation-only, so it is never part of a cassette: a recorded exchange
            // stays byte-identical to one made before this capability existed.
            if event.type != "timing" { recorder.append(event) }
            let terminal = event.type == "completed" || event.type == "failed"
            if terminal {
                timing.mark(.terminal)
                // Exactly one report, immediately before the request's terminal event.
                if let report = timing.finish() {
                    self.emit(
                        requestID: requestID,
                        event: ProviderWireEvent(type: "timing", timing: report)
                    )
                }
                // Persist the cassette before the terminal reaches the kernel: the run returns as
                // soon as it sees `completed`, so writing afterwards races the caller (and its shutdown).
                if event.type == "completed", let path = self.recordingPath(),
                   let store = self.recordingCassette() {
                    store.append(digest: digest, events: recorder.events, to: path)
                }
                self.noteTerminal(executionID: executionID, event: event)
            }
            self.emit(requestID: requestID, event: event)
        }

        let task = Task { [weak self] in
            defer { semaphore.signal() }
            guard let self else { return }
            if self.isReplayMode(), let replay = self.cassetteStore() {
                if let exchange = replay.take(digest: digest, legacyDigest: legacyDigest) {
                    do {
                        try await MiMoTransport.replay(
                            exchange: exchange, config: config, slow: self.isSlow(), emit: emit
                        )
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
                    try await MiMoTransport.stream(
                        request: request, requestID: requestID, config: config,
                        endpoint: self.endpoint(), timing: timing, emit: emit
                    )
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
        if let executionID, !executionID.isEmpty {
            requestExecutions[requestID] = executionID
        }
        lock.unlock()
        semaphore.wait()
        lock.lock()
        tasks.removeValue(forKey: requestID)
        requestExecutions.removeValue(forKey: requestID)
        lock.unlock()
        return outcome.value
    }

    func cancel(requestID: String) {
        lock.lock()
        let task = tasks[requestID]
        if let executionID = requestExecutions.removeValue(forKey: requestID) {
            executionConfigs.removeValue(forKey: executionID)
            executionOrder.removeAll { $0 == executionID }
        }
        lock.unlock()
        task?.cancel()
    }

    private func config(for request: ProviderWireRequest) -> MiMoConfig {
        guard let executionID = request.executionID, !executionID.isEmpty else {
            // Older callers without an execution id cannot be snapshotted; current settings apply.
            lock.lock(); defer { lock.unlock() }; return currentConfig
        }
        lock.lock()
        defer { lock.unlock() }
        if let existing = executionConfigs[executionID] { return existing }
        let snapshot = currentConfig
        executionConfigs[executionID] = snapshot
        executionOrder.append(executionID)
        if executionOrder.count > Self.maxExecutionSnapshots {
            let evicted = executionOrder.removeFirst()
            executionConfigs.removeValue(forKey: evicted)
        }
        return snapshot
    }

    /// The saved settings snapshot plus the frontend's temporary thinking selection for this request
    /// only. An unknown level keeps the saved configuration: a stale or hostile id must never crash
    /// the plugin or silently change what the user configured.
    private func effectiveConfig(for request: ProviderWireRequest) -> MiMoConfig {
        let saved = config(for: request)
        guard let level = request.reasoningLevel,
              let mode = MiMoThinkingMode(rawValue: level) else { return saved }
        return saved.applyingThinking(mode)
    }

    /// What the plugin would send next. Display data only: protocol family, thinking level and a
    /// short source/detail hint. No credential, prompt, header or request content can enter here.
    func providerState() -> ProviderState {
        lock.lock()
        let config = currentConfig
        lock.unlock()
        let detail: String
        switch config.thinkingMode {
        case .default:
            detail = "服务端默认"
        case .disabled:
            detail = "思考已关闭"
        case .enabled:
            if config.protocolKind == .responses {
                let effort = config.reasoningEffort
                    .flatMap(MiMoReasoningEffort.init(rawValue:))?.wireValue
                detail = effort.map { "effort=\($0)" } ?? "服务端默认 effort"
            } else {
                detail = "thinking.type=enabled"
            }
        }
        return ProviderState(
            protocolKind: config.protocolKind.rawValue,
            protocolLabel: config.protocolKind == .chatCompletions ? "Chat Completions" : "Responses",
            thinkingLevel: config.thinkingMode.rawValue,
            thinkingLabel: config.thinkingMode.label,
            source: config.thinkingMode == .default ? "server-default" : "plugin-settings",
            detail: detail
        )
    }

    /// A `toolCalls` terminal is the round trip: the same Run will issue another request, so the
    /// snapshot must survive. Every other terminal (or cancel) ends the Run and releases it.
    private func noteTerminal(executionID: String?, event: ProviderWireEvent) {
        guard let executionID, !executionID.isEmpty else { return }
        if event.type == "completed", event.stopReason == "toolCalls" { return }
        lock.lock()
        executionConfigs.removeValue(forKey: executionID)
        executionOrder.removeAll { $0 == executionID }
        lock.unlock()
    }

    private func endpoint() -> URL? {
        lock.lock(); defer { lock.unlock() }; return endpointOverride
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme == "http", let host = url.host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
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
private let settingsState = MiMoSettingsState()
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
            )],
            modelDetails: MiMoWire.models.map { model in
                ProviderModel(
                    id: model,
                    thinkingLevels: MiMoWire.thinkingLevels,
                    defaultThinkingLevel: nil
                )
            },
            state: ProviderStateDeclaration(capability: MiMoWire.stateCapability)
        )],
        settings: SettingsDeclaration(capability: MiMoSettingsState.capability)
    )
    return emitJSON(identity, out: out, length: length)
}

private let startImpl: @convention(c) (
    UnsafePointer<UInt8>?, UInt32, UnsafeMutablePointer<LingXiStatus>?
) -> Int32 = { granted, length, status in
    do {
        try core.start(granted: LingXiBuffer.copyString(granted, length: length))
        status?.pointee = .make()
        return 0
    } catch {
        status?.pointee = .make(.protocolViolation)
        return -1
    }
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
    if String(cString: capability) == MiMoWire.stateCapability {
        // Read-only state capability: display data only, answered without touching any request.
        out?.pointee = nil
        outLength?.pointee = 0
        let result = emitJSON(core.providerState(), out: out, length: outLength)
        status?.pointee = .make(result == 0 ? .ok : .capabilityFailed)
        return result == 0 ? 0 : -1
    }
    if String(cString: capability) == MiMoSettingsState.capability {
        guard let invocation = try? JSONDecoder().decode(SettingsInvocation.self, from: Data(bytes)) else {
            status?.pointee = .make(.protocolViolation)
            return -1
        }
        out?.pointee = nil
        outLength?.pointee = 0
        var response = settingsState.handle(invocation)
        if invocation.op == .apply || invocation.op == .commit,
           let config = invocation.config {
            do {
                try core.applySettings(config)
            } catch {
                // An IPC-ok frame must not hide a semantic rejection of the candidate config.
                response = SettingsResponse(ok: false, error: "\(error)")
            }
        }
        let result = emitJSON(response, out: out, length: outLength)
        status?.pointee = .make(result == 0 ? .ok : .capabilityFailed)
        return result == 0 ? 0 : -1
    }
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
