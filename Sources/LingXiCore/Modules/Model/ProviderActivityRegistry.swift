import Foundation
import LingXiProtocol

public actor ProviderActivityRegistry {
    public static let shared = ProviderActivityRegistry()

    private var activities: [String: ProviderActivitySnapshot] = [:] // providerRequestID -> snapshot
    private var cancelledRequestIDs: Set<String> = []
    private var cancelledRunIDs: Set<AgentRunID> = []

    public init() {}

    @discardableResult
    public func record(
        sessionID: SessionID,
        runID: AgentRunID?,
        providerRequestID: String,
        state: ProviderActivityState,
        model: String? = nil
    ) -> ProviderActivitySnapshot {
        let effectiveState: ProviderActivityState
        if let runID, cancelledRunIDs.contains(runID) {
            effectiveState = .cancelled
        } else if cancelledRequestIDs.contains(providerRequestID) && !state.isTerminal {
            effectiveState = .cancelled
        } else {
            effectiveState = state
        }
        let snapshot = ProviderActivitySnapshot(
            sessionID: sessionID,
            runID: runID,
            providerRequestID: providerRequestID,
            state: effectiveState,
            model: model,
            updatedAt: .now
        )
        activities[providerRequestID] = snapshot
        return snapshot
    }

    @discardableResult
    public func cancel(providerRequestID: String) -> ProviderActivitySnapshot? {
        guard !providerRequestID.isEmpty else { return nil }
        cancelledRequestIDs.insert(providerRequestID)
        guard var snapshot = activities[providerRequestID] else { return nil }
        snapshot = ProviderActivitySnapshot(
            sessionID: snapshot.sessionID,
            runID: snapshot.runID,
            providerRequestID: snapshot.providerRequestID,
            state: .cancelled,
            model: snapshot.model,
            updatedAt: .now
        )
        activities[providerRequestID] = snapshot
        return snapshot
    }

    @discardableResult
    public func cancelRun(_ runID: AgentRunID) -> [ProviderActivitySnapshot] {
        cancelledRunIDs.insert(runID)
        var updated: [ProviderActivitySnapshot] = []
        for (id, snapshot) in activities where snapshot.runID == runID && !snapshot.state.isTerminal {
            if !id.isEmpty {
                cancelledRequestIDs.insert(id)
            }
            let newSnapshot = ProviderActivitySnapshot(
                sessionID: snapshot.sessionID,
                runID: snapshot.runID,
                providerRequestID: snapshot.providerRequestID,
                state: .cancelled,
                model: snapshot.model,
                updatedAt: .now
            )
            activities[id] = newSnapshot
            updated.append(newSnapshot)
        }
        return updated
    }

    public func isCancelled(providerRequestID: String, runID: AgentRunID?) -> Bool {
        if !providerRequestID.isEmpty && cancelledRequestIDs.contains(providerRequestID) { return true }
        if let runID, cancelledRunIDs.contains(runID) { return true }
        return false
    }

    public func isRunCancelled(_ runID: AgentRunID) -> Bool {
        cancelledRunIDs.contains(runID)
    }

    public func activeActivities(for sessionID: SessionID) -> [ProviderActivitySnapshot] {
        activities.values.filter { $0.sessionID == sessionID && !$0.state.isTerminal }
    }

    public func latestActivity(for runID: AgentRunID) -> ProviderActivitySnapshot? {
        activities.values.filter { $0.runID == runID }.max(by: { $0.updatedAt < $1.updatedAt })
    }

    public func reset() {
        activities.removeAll()
        cancelledRequestIDs.removeAll()
        cancelledRunIDs.removeAll()
    }
}
