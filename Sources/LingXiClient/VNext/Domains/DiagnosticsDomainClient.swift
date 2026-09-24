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

    public func getBackgroundTasks() async throws -> [BackgroundTaskSnapshot] {
        let bundle = try await getBundle()
        return bundle.backgroundTasks ?? []
    }

    public func queryTrace(request: TraceQueryRequest) async throws -> Page<RuntimeTraceEvent> {
        let bundle = try await getBundle()
        var filtered = bundle.trace
        if let taskID = request.taskID {
            filtered = filtered.filter { $0.taskID == taskID }
        }
        if let sessionID = request.sessionID {
            filtered = filtered.filter { $0.sessionID == sessionID }
        }
        if let kind = request.kind {
            filtered = filtered.filter { $0.kind == kind }
        }
        if let from = request.fromTimestamp {
            filtered = filtered.filter { $0.timestamp >= from }
        }
        if let to = request.toTimestamp {
            filtered = filtered.filter { $0.timestamp <= to }
        }
        let limit = request.limit ?? 100
        let items = Array(filtered.prefix(limit))
        return Page(items: items, nextCursor: nil, hasMore: filtered.count > limit)
    }

    public func tailTrace(limit: Int = 100) async throws -> [RuntimeTraceEvent] {
        let bundle = try await getBundle()
        return Array(bundle.trace.suffix(limit))
    }
}
