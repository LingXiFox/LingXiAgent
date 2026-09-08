import Foundation
import LingXiProtocol

public struct DiagnosticsDomainClient: Sendable {
    private let transport: any ClientTransport

    public init(transport: any ClientTransport) {
        self.transport = transport
    }

    public func getBundle() async throws -> RuntimeDiagnosticsBundle {
        let resp = try await transport.getDiagnostics(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    public func getPerformanceMetrics(sessionID: SessionID) async throws -> TurnPerformanceReport? {
        let req = GetPerformanceMetricsRequest(sessionID: sessionID)
        let resp = try await transport.getPerformanceMetrics(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }

    public func getProviderMetrics() async throws -> ProviderMetricsInfo {
        let resp = try await transport.getProviderMetrics(envelope: QueryEnvelope(payload: VoidResult()))
        return resp.payload
    }

    public func getRunTrace(sessionID: SessionID, runID: RunID) async throws -> RunTraceInfo {
        let req = GetRunTraceRequest(sessionID: sessionID, runID: runID)
        let resp = try await transport.getRunTrace(envelope: QueryEnvelope(payload: req))
        return resp.payload
    }
}
