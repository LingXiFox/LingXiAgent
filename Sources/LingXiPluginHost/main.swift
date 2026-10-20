import Foundation
import LingXiPluginABI

/// The generic plugin host: one process, one plugin, `dlopen` plus the fixed C ABI on one side and
/// newline-delimited JSON with the Core on the other. It ships with no plugin code and no vendor
/// knowledge (Plugin-System-Design.md §一).
final class HostAgent {
    private var library: PluginLibrary?
    private let hostAPI: UnsafePointer<LingXiHostAPI>
    private let output = FileHandle.standardOutput
    private let outputLock = NSLock()

    init() {
        hostAPI = HostAgent.makeHostAPI()
    }

    func handle(_ request: HostRequest) -> HostReply {
        var reply = HostReply(id: request.id, ok: true)
        do {
            switch request.method {
            case .load: try load(request, into: &reply)
            case .start: try start(request, into: &reply)
            case .invoke: try invoke(request, into: &reply)
            case .cancel: try cancel(request, into: &reply)
            case .stop: try stop(into: &reply)
            case .ping: reply.payload = .object(["alive": .bool(library != nil)])
            }
        } catch let fault as HostFault {
            reply = HostReply(id: request.id, ok: false)
            reply.fault = fault
        } catch {
            reply = HostReply(id: request.id, ok: false)
            reply.fault = HostFault(code: "capabilityFailed", domain: "host", message: "\(error)")
        }
        return reply
    }

    /// The parent closed its write handle: this process ends the session and quits. Teardown happens
    /// here too, so an abrupt Core exit cannot leave the plugin loaded.
    func shutdownDueToEndOfInput() {
        library?.stop()
        library?.dispose()
        library?.close()
        library = nil
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
        // The manifest and the exported table must agree; a mismatch is a packaging error, and
        // guessing which one is authoritative is how silent downgrades start (PLG-011).
        guard manifest.abiMajor == opened.abiMajor else {
            opened.close()
            throw HostFault(
                code: "abiViolation", domain: "manifest",
                message: "manifest declares ABI major \(manifest.abiMajor) but the plugin table says \(opened.abiMajor)"
            )
        }
        // Declared capabilities in the manifest and in the table must agree; a plugin that describes
        // something it never declared is a protocol violation, not a surprise to tolerate.
        guard Set(manifest.capabilities) == Set(opened.identity.hooks.map { "hook.\($0.id)" }) else {
            opened.close()
            throw HostFault(code: "protocolViolation", domain: "host", message: "declared capabilities differ from the plugin identity")
        }
        library = opened

        reply.bundleID = opened.bundleID
        reply.abiMajor = opened.abiMajor
        reply.capabilities = opened.declaredHooks.map {
            DeclaredCapability(kind: "hook", id: $0.id, node: $0.node, priority: $0.priority, canVeto: $0.canVeto)
        }
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

    private func invoke(_ request: HostRequest, into reply: inout HostReply) throws {
        guard let library else {
            throw HostFault(code: "protocolViolation", domain: "host", message: "invocation before the handshake completed")
        }
        guard let capability = request.capability else {
            throw HostFault(code: "protocolViolation", domain: "host", message: "invoke needs a capability")
        }
        let payload = (try? JSONEncoder().encode(request.payload ?? .null)) ?? Data()
        let bytes = try library.invoke(capability: capability, payload: Array(payload))
        reply.payload = try JSONValue(data: Data(bytes))
    }

    private func cancel(_ request: HostRequest, into reply: inout HostReply) throws {
        guard let library, let requestID = request.requestID else {
            throw HostFault(code: "protocolViolation", domain: "host", message: "cancel needs requestID")
        }
        _ = library   // forwarding cancellation is the plugin table's business once invoke is async
        reply.payload = .object(["cancelled": .string(requestID)])
    }

    private func stop(into reply: inout HostReply) throws {
        guard let library else {
            reply.payload = .object(["stopped": .bool(false)])
            return
        }
        library.stop()
        library.dispose()
        library.close()
        self.library = nil
        reply.payload = .object(["stopped": .bool(true)])
    }

    func write(line: String) {
        outputLock.lock()
        defer { outputLock.unlock() }
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
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            }
        ))
        return UnsafePointer(allocated)
    }

    /// The host's own Team ID, used by the restricted tier. An unsigned local build reports no team,
    /// which is exactly why development mode exists.
    private static func ownTeamID() -> String? {
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
        FileHandle.standardError.write(Data("host: handling \(request.method.rawValue) id=\(request.id ?? -1)\n".utf8))
        let reply = agent.handle(request)
        let data = (try? JSONEncoder().encode(reply)) ?? Data()
        agent.write(line: String(decoding: data, as: UTF8.self))
    }
}

agent.shutdownDueToEndOfInput()
