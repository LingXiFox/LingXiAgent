import Foundation
import LingXiKernel
import LingXiPluginABI

/// One plugin, one Host process. Owns the handshake, the invocation path, and the teardown that must
/// leave no process and no route behind.
public actor PluginSession {
    public enum SessionState: String, Sendable {
        case installed
        case running
        case failed
        case disabled
    }

    public enum SessionError: Error, Equatable {
        case notRunning
        case handshake(String)
        case hostFailed(String)
    }

    public let bundlePath: String
    public let hostExecutableURL: URL
    public private(set) var state: SessionState = .installed
    public private(set) var capabilities: [DeclaredCapability] = []
    public private(set) var providers: [ProviderIdentity] = []
    public private(set) var processIdentifier: Int32?

    private var process: PluginProcess?
    private let clock: any MonotonicClock
    private let timeout: Duration
    private let handshakeTimeout: Duration

    public init(
        bundlePath: String,
        hostExecutableURL: URL,
        clock: any MonotonicClock = SystemMonotonicClock(),
        timeout: Duration = .seconds(5),
        handshakeTimeout: Duration = .seconds(5)
    ) {
        self.bundlePath = bundlePath
        self.hostExecutableURL = hostExecutableURL
        self.clock = clock
        self.timeout = timeout
        self.handshakeTimeout = handshakeTimeout
    }

    public var isRunning: Bool { state == .running && (process?.isRunning ?? false) }

    public func enable(policy: SignaturePolicy, grantedPermissions: [String]) async throws {
        guard state != .running else { return }
        let process = PluginProcess(executableURL: hostExecutableURL, clock: clock)
        do {
            try process.start()
        } catch {
            state = .failed
            throw SessionError.handshake("the host process could not start: \(error)")
        }
        self.process = process
        processIdentifier = process.processIdentifier

        var load = HostRequest(id: nil, method: .load)
        load.bundlePath = bundlePath
        load.policy = policy.rawValue
        let loaded = try await send(load, process: process, timeout: handshakeTimeout)

        guard loaded.ok, let declared = loaded.capabilities else {
            let reason = loaded.fault.map { "\($0.code): \($0.message)" } ?? "load refused without a fault"
            process.terminate()
            self.process = nil
            state = .failed
            throw SessionError.handshake(reason)
        }
        capabilities = declared
        providers = loaded.providers ?? []

        var start = HostRequest(id: nil, method: .start)
        start.grantedPermissions = grantedPermissions
        let started = try await send(start, process: process, timeout: handshakeTimeout)
        guard started.ok else {
            let reason = started.fault.map { "\($0.code): \($0.message)" } ?? "start refused without a fault"
            process.terminate()
            self.process = nil
            state = .failed
            throw SessionError.handshake(reason)
        }
        state = .running
    }

    public func invoke(capability: String, payload: JSONValue, requestID: String) async throws -> JSONValue {
        guard let process, state == .running else { throw SessionError.notRunning }
        var request = HostRequest(id: nil, method: .invoke)
        request.capability = capability
        request.payload = payload
        request.requestID = requestID
        let reply = try await send(request, process: process)
        guard reply.ok, let body = reply.payload else {
            let reason = reply.fault.map { "\($0.code): \($0.message)" } ?? "invoke failed without a fault"
            throw SessionError.hostFailed(reason)
        }
        return body
    }

    /// Runs an invoke whose events arrive while it is still in flight. The returned stream ends when
    /// the invoke reply arrives; buffered events are drained before the end.
    public func invokeStreaming(
        capability: String, payload: JSONValue, requestID: String, timeout: Duration? = nil
    ) -> AsyncThrowingStream<JSONValue, Error> {
        guard let process, state == .running else {
            return AsyncThrowingStream { $0.finish(throwing: SessionError.notRunning) }
        }
        let subscription = process.subscribe(requestID: requestID)
        let session = self
        Task {
            do {
                var request = HostRequest(id: nil, method: .invoke)
                request.capability = capability
                request.payload = payload
                request.requestID = requestID
                let reply = try await session.send(request, process: process, timeout: timeout)
                if reply.ok {
                    subscription.finish()
                } else {
                    let reason = reply.fault.map { "\($0.code): \($0.message)" } ?? "invoke failed without a fault"
                    subscription.finish(throwing: SessionError.hostFailed(reason))
                }
            } catch {
                subscription.finish(throwing: error)
            }
            process.unsubscribe(requestID: requestID)
        }
        return AsyncThrowingStream { outer in
            let pump = Task {
                do {
                    for try await value in subscription.stream { outer.yield(value) }
                    outer.finish()
                } catch {
                    outer.finish(throwing: error)
                }
            }
            outer.onTermination = { _ in
                pump.cancel()
                // The kernel cancelled the Run: stop the provider request instead of letting it run.
                Task { await session.cancel(requestID: requestID) }
            }
        }
    }

    /// Names one in-flight call and asks the host to interrupt it. The host forwards the id to the
    /// plugin's `cancel`, so a running provider request can actually stop.
    /// Liveness check used by supervision and by the cancellation test: if this returns promptly
    /// while an invocation is running, the host is not blocked by that invocation.
    public func ping(timeout: Duration = .seconds(1)) async -> Bool {
        guard let process, state == .running else { return false }
        var request = HostRequest(id: nil, method: .ping)
        request.id = nil
        return (try? await process.send(request, timeout: timeout))?.ok ?? false
    }

    public func cancel(requestID: String, timeout: Duration = .seconds(1)) async {
        guard let process, state == .running else { return }
        var request = HostRequest(id: nil, method: .cancel)
        request.requestID = requestID
        _ = try? await process.send(request, timeout: timeout)
    }

    /// Stop, dispose, close the pipe and wait for the process to actually go away; a host that will
    /// not exit is terminated. Nothing here leaves a background process behind.
    public func disable() async {
        guard let process else {
            state = .disabled
            return
        }
        if state == .running || state == .failed {
            var stop = HostRequest(id: nil, method: .stop)
            stop.id = nil
            if process.isRunning {
                _ = try? await process.send(stop, timeout: timeout)
            }
        }
        process.terminate()
        process.waitForExit(upTo: .seconds(2))
        processIdentifier = nil
        self.process = nil
        capabilities = []
        providers = []
        state = .disabled
    }

    private func send(_ request: HostRequest, process: PluginProcess, timeout: Duration? = nil) async throws -> HostReply {
        do {
            return try await process.send(request, timeout: timeout ?? self.timeout)
        } catch let error as PluginProcess.PluginProcessError {
            // A missed deadline or a caller cancellation is one call's problem; a dead host is the
            // session's. Only the latter changes the state, so a timeout does not masquerade as a
            // crashed plugin.
            if case .exited = error {
                state = .failed
            } else if let requestID = request.requestID {
                // Do not leave the plugin computing a result nobody will read.
                await cancel(requestID: requestID)
            }
            throw SessionError.hostFailed("\(error)")
        } catch {
            state = .failed
            throw SessionError.hostFailed("\(error)")
        }
    }
}
