import Foundation
import LingXiPluginABI

/// The generic plugin host: one process, one plugin, `dlopen` plus the fixed C ABI on one side and
/// newline-delimited JSON with the Core on the other. It ships with no plugin code and no vendor
/// knowledge (Plugin-System-Design.md §一).
///
/// Invocations run off the read loop, so a `cancel` frame is handled while a call is still in
/// flight. Without that, one slow provider request would make the host deaf to everything.
final class HostAgent: @unchecked Sendable {
    private var library: PluginLibrary?
    private let hostAPI: UnsafePointer<LingXiHostAPI>
    private let output = FileHandle.standardOutput
    private static let outputLock = NSLock()
    private let stateLock = NSLock()
    private var pending: Set<String> = []
    private var cancelled: Set<String> = []
    /// Plugin calls are serialized; the read loop stays free, which is what makes cancel work.
    private let invocationQueue = DispatchQueue(label: "site.lingxi.plugin-host.invoke")

    init() {
        hostAPI = HostAgent.makeHostAPI()
    }

    /// Returns a reply for immediate methods; `invoke` and `cancel` complete asynchronously.
    func handle(_ request: HostRequest) {
        pendingReply = HostReply(id: request.id, ok: true)
        do {
            switch request.method {
            case .invoke:
                try beginInvoke(request)
                return
            case .cancel:
                let identifier = request.requestID ?? ""
                stateLock.lock()
                cancelled.insert(identifier)
                stateLock.unlock()
                _ = library?.cancel(requestID: identifier)
                reply(HostReply(id: request.id, ok: true), payload: .object(["cancelled": .string(identifier)]))
                return
            case .load: try load(request, into: &pendingReply)
            case .start: try start(request, into: &pendingReply)
            case .stop: try stop(into: &pendingReply)
            case .diagnostics: try diagnostics(into: &pendingReply)
            case .ping: pendingReply.payload = .object(["alive": .bool(library != nil)])
            }
            reply(pendingReply)
        } catch let fault as HostFault {
            reply(HostReply(id: request.id, ok: false), fault: fault)
        } catch {
            reply(HostReply(id: request.id, ok: false), fault: HostFault(code: "capabilityFailed", domain: "host", message: "\(error)"))
        }
    }

    private var pendingReply = HostReply(id: nil, ok: true)

    func shutdownDueToEndOfInput() {
        cancelAllPending()
        library?.stop()
        library?.dispose()
        library?.close()
        library = nil
    }

    // MARK: - methods

    private func beginInvoke(_ request: HostRequest) throws {
        guard let library else {
            throw HostFault(code: "protocolViolation", domain: "host", message: "invocation before the handshake completed")
        }
        guard let capability = request.capability, let requestID = request.requestID else {
            throw HostFault(code: "protocolViolation", domain: "host", message: "invoke needs a capability and a requestID")
        }
        stateLock.lock()
        pending.insert(requestID)
        stateLock.unlock()

        let payload = (try? JSONEncoder().encode(request.payload ?? .null)) ?? Data()
        let replyID = request.id
        invocationQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<JSONValue, HostFault>
            do {
                let bytes = try library.invoke(capability: capability, requestID: requestID, payload: Array(payload))
                result = .success(try JSONValue(data: Data(bytes)))
            } catch let failure as LibraryFailure {
                let code = self.wasCancelled(requestID) ? "cancelled" : "capabilityFailed"
                result = .failure(HostFault(code: code, domain: "plugin", message: failure.description))
            } catch {
                result = .failure(HostFault(code: "capabilityFailed", domain: "plugin", message: "\(error)"))
            }
            self.finishInvoke(requestID: requestID, replyID: replyID, result: result)
        }
    }

    private func finishInvoke(requestID: String, replyID: Int?, result: Result<JSONValue, HostFault>) {
        stateLock.lock()
        pending.remove(requestID)
        cancelled.remove(requestID)
        stateLock.unlock()
        switch result {
        case .success(let payload):
            reply(HostReply(id: replyID, ok: true), payload: payload)
        case .failure(let fault):
            reply(HostReply(id: replyID, ok: false), fault: fault)
        }
    }

    private func wasCancelled(_ requestID: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled.contains(requestID)
    }

    private func cancelAllPending() {
        stateLock.lock()
        let ids = pending
        cancelled.formUnion(ids)
        stateLock.unlock()
        for id in ids { _ = library?.cancel(requestID: id) }
    }

    private func load(_ request: HostRequest, into reply: inout HostReply) throws {
        guard library == nil else {
            throw HostFault(code: "protocolViolation", domain: "host", message: "a plugin is already loaded in this host")
        }
        guard let path = request.bundlePath else {
            throw HostFault(code: "protocolViolation", domain: "host", message: "load needs bundlePath")
        }
        let policy = SignaturePolicy(rawValue: request.policy ?? "restricted") ?? .restricted
        let bundleURL = URL(fileURLWithPath: path)

        let manifest: BundleManifest
        do {
            manifest = try BundleValidator.validate(bundleURL: bundleURL, policy: policy, hostTeamID: HostAgent.ownTeamID())
        } catch let rejection as BundleRejection {
            throw HostFault(code: "abiViolation", domain: "bundle", message: rejection.description)
        }

        let opened: PluginLibrary
        do {
            opened = try PluginLibrary.open(url: manifest.executableURL, entryPoint: manifest.entryPoint, hostAPI: hostAPI)
        } catch let failure as LibraryFailure {
            throw HostFault(code: "abiViolation", domain: "abi", message: failure.description)
        }
        guard opened.abiMajor == LingXiABI.major else {
            opened.close()
            throw HostFault(code: "abiViolation", domain: "abi", message: "plugin ABI major \(opened.abiMajor) is not \(LingXiABI.major)")
        }
        // Identity cannot drift from the bundle that carries it: a plugin claiming another id would
        // receive the other plugin's grants.
        guard manifest.bundleID == opened.bundleID else {
            opened.close()
            throw HostFault(
                code: "protocolViolation", domain: "manifest",
                message: "manifest id \(manifest.bundleID) does not match the plugin identity \(opened.bundleID)"
            )
        }
        guard manifest.abiMajor == opened.abiMajor else {
            opened.close()
            throw HostFault(
                code: "abiViolation", domain: "manifest",
                message: "manifest declares ABI major \(manifest.abiMajor) but the plugin table says \(opened.abiMajor)"
            )
        }
        let declaredHooks = opened.identity.hooks.map { "hook.\($0.id)" }
        let declaredProviders = opened.identity.providers.map { "provider.\($0.id)" }
        guard Set(manifest.capabilities) == Set(declaredHooks + declaredProviders) else {
            opened.close()
            throw HostFault(code: "protocolViolation", domain: "host", message: "declared capabilities differ from the plugin identity")
        }
        library = opened

        reply.bundleID = opened.bundleID
        reply.abiMajor = opened.abiMajor
        reply.capabilities = opened.declaredHooks.map {
            DeclaredCapability(kind: "hook", id: $0.id, node: $0.node, priority: $0.priority, canVeto: $0.canVeto)
        }
        reply.providers = opened.identity.providers
        reply.permissions = manifest.permissions
        reply.payload = .object([
            "version": .string(manifest.version),
            "teamID": manifest.teamID.map { .string($0) } ?? .null,
            "signature": .string(manifest.signature.rawValue),
        ])
    }

    private func start(_ request: HostRequest, into reply: inout HostReply) throws {
        guard let library else {
            throw HostFault(code: "protocolViolation", domain: "host", message: "capability.activate before a load")
        }
        let granted = Array((request.grantedPermissions ?? []).joined(separator: ",").utf8)
        try library.start(granted: granted)
        reply.payload = .object(["started": .bool(true)])
    }

    /// Diagnostics never exposes values, only the names present in this process environment. The
    /// tripwire test uses it to prove a passphrase or API key never crossed the process boundary.
    private func diagnostics(into reply: inout HostReply) throws {
        let keys = ProcessInfo.processInfo.environment.keys.sorted()
        reply.payload = .object([
            "environment": .array(keys.map { .string($0) }),
            "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
        ])
    }

    private func stop(into reply: inout HostReply) throws {
        guard let library else {
            reply.payload = .object(["stopped": .bool(false)])
            return
        }
        cancelAllPending()
        library.stop()
        library.dispose()
        library.close()
        self.library = nil
        reply.payload = .object(["stopped": .bool(true)])
    }

    // MARK: - output

    private func reply(_ header: HostReply, payload: JSONValue) {
        var copy = header
        copy.payload = payload
        reply(copy)
    }

    private func reply(_ header: HostReply, fault: HostFault) {
        var copy = header
        copy.fault = fault
        reply(copy)
    }

    private func reply(_ reply: HostReply) {
        guard let data = try? JSONEncoder().encode(reply) else { return }
        write(line: String(decoding: data, as: UTF8.self))
    }

    func write(line: String) {
        HostAgent.outputLock.lock()
        defer { HostAgent.outputLock.unlock() }
        output.write(Data((line + "\n").utf8))
    }

    private static func makeHostAPI() -> UnsafePointer<LingXiHostAPI> {
        let allocated = UnsafeMutablePointer<LingXiHostAPI>.allocate(capacity: 1)
        allocated.initialize(to: LingXiHostAPI(
            structSize: UInt32(MemoryLayout<LingXiHostAPI>.size),
            abiMajor: LingXiABI.major,
            log: { level, text, length in
                let message = LingXiBuffer.copyString(text, length: length)
                FileHandle.standardError.write(Data("[plugin log \(level)] \(message)\n".utf8))
            },
            emit: { event, payload, length in
                let name = event.map { String(cString: $0) } ?? "event"
                let body = LingXiBuffer.copyString(payload, length: length)
                let line = "{\"event\":\"\(name)\",\"payload\":\(body.isEmpty ? "null" : body)}"
                HostAgent.outputLock.lock()
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
                HostAgent.outputLock.unlock()
            }
        ))
        return UnsafePointer(allocated)
    }

    /// The host's own Team ID, used by the restricted tier. An unsigned local build reports no team,
    /// which is exactly why development mode exists.
    private static let cachedTeamID: String? = computeOwnTeamID()

    /// The host's Team ID does not change during its lifetime; codesign is expensive under load, so
    /// it is resolved once per process instead of once per plugin load.
    private static func ownTeamID() -> String? { cachedTeamID }

    private static func computeOwnTeamID() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvvv", Bundle.main.executablePath ?? "/dev/null"]
        let pipe = Pipe()
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return value == "not set" ? nil : value
        }
        return nil
    }
}

let agent = HostAgent()
let input = FileHandle.standardInput
var pending = Data()

while true {
    // availableData hands back whatever arrived; readData(ofLength:) waits for the full count and a
    // live pipe never delivers it.
    let chunk = input.availableData
    guard !chunk.isEmpty else { break }
    pending.append(chunk)
    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
        let line = pending[pending.startIndex..<newline]
        pending.removeSubrange(pending.startIndex...newline)
        guard !line.isEmpty else { continue }
        if line.count > HostWire.maxFrameBytes {
            agent.write(line: "{\"fault\":{\"code\":\"protocolViolation\",\"domain\":\"frame\",\"message\":\"frame exceeds the cap\"}}")
            continue
        }
        guard let request = try? HostWire.decode(HostRequest.self, from: Data(line)) else {
            agent.write(line: "{\"ok\":false,\"fault\":{\"code\":\"protocolViolation\",\"domain\":\"frame\",\"message\":\"undecodable frame\"}}")
            continue
        }
        agent.handle(request)
    }
}

agent.shutdownDueToEndOfInput()
