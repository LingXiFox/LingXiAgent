import Foundation
import LingXiProtocol

/// Typed client for the Developer Debug Mode surface.
///
/// A struct with only a `let` transport, like every other domain client: `LingXiClientVNext` is
/// `Sendable` and holds these as immutable properties, so a mutable cache here would either break
/// that or force locking into a type that has no business owning it. Callers that need to avoid
/// re-probing cache the result themselves.
public struct DebugDomainClient: Sendable {
    /// Whether this Core has an Observatory, independent of whether the mode is switched on.
    ///
    /// `debug.*` carries no `ProtocolFeature` advertisement, so the only honest way to find out is
    /// to ask and read what comes back. The three outcomes are genuinely different and are not
    /// collapsed here: an old Core answers "unknown method", a current Core with the mode off
    /// answers "not enabled", and only the third case can produce data.
    public enum Availability: Sendable, Equatable {
        case unsupported
        case disabled
        case enabled(DebugObservatoryStatus)
        /// The question could not be answered. Distinct from `.unsupported`, because a dropped
        /// connection reported as a version skew would send an operator to upgrade Core instead of
        /// reconnect to it.
        case unknown

        public var isPresent: Bool {
            switch self {
            case .disabled, .enabled: return true
            case .unsupported, .unknown: return false
            }
        }
    }

    private let transport: any ClientTransport

    public init(transport: any ClientTransport) {
        self.transport = transport
    }

    public func status() async throws -> DebugObservatoryStatus {
        let resp = try await transport.debugStatus(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    /// Probes once and classifies. Never throws: an unsupported Core is a result, not an error.
    public func probe() async -> Availability {
        do {
            let status = try await status()
            return status.enabled ? .enabled(status) : .disabled
        } catch let error as CoreError where error.code == .unsupportedCommand {
            return .unsupported
        } catch {
            return .unknown
        }
    }

    /// Turns the mode on or off. The returned status is Core's authoritative post-change state, so
    /// a caller renders from this rather than from what it asked for.
    public func setEnabled(_ enabled: Bool) async throws -> DebugObservatoryStatus {
        let receipt = try await transport.debugModeUpdate(
            envelope: CommandEnvelope(payload: UpdateDebugModeRequest(action: .setEnabled, enabled: enabled))
        )
        guard let status = receipt.result else {
            throw CoreError(code: .transport, message: "debug.mode.update 未回带权威状态，无法确认模式已切换。")
        }
        return status
    }

    public func startRecording(runName: String? = nil) async throws -> DebugObservatoryStatus {
        try await updateDebug(action: .startRecording, runName: runName)
    }

    public func stopRecording() async throws -> DebugObservatoryStatus {
        try await updateDebug(action: .stopRecording)
    }

    /// Discards live telemetry. The on-disk archive is untouched; `export` is the archive door.
    public func clear() async throws -> DebugObservatoryStatus {
        try await updateDebug(action: .clear)
    }

    public func export(to destinationPath: String, runName: String? = nil) async throws -> DebugObservatoryStatus {
        try await updateDebug(action: .export, runName: runName, destinationPath: destinationPath)
    }

    public func snapshot(sessionID: SessionID, topN: Int = 10) async throws -> RuntimeObservatorySnapshot {
        let req = GetObservatoryRequest(sessionID: sessionID, topN: topN)
        let resp = try await transport.debugSnapshot(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    /// One page of telemetry, oldest first, resuming from `afterSequence`.
    public func events(sessionID: SessionID? = nil, afterSequence: UInt64? = nil,
                       categories: [String]? = nil, limit: Int = 500) async throws -> DebugEventPage {
        let req = GetObservatoryEventsRequest(sessionID: sessionID, afterSequence: afterSequence,
                                              categories: categories, limit: limit)
        let resp = try await transport.debugEvents(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    private func updateDebug(action: UpdateDebugModeRequest.Action, runName: String? = nil,
                             destinationPath: String? = nil) async throws -> DebugObservatoryStatus {
        let receipt = try await transport.debugModeUpdate(
            envelope: CommandEnvelope(payload: UpdateDebugModeRequest(
                action: action, runName: runName, destinationPath: destinationPath))
        )
        guard let status = receipt.result else {
            throw CoreError(code: .transport, message: "debug.mode.update 未回带权威状态。")
        }
        return status
    }
}
