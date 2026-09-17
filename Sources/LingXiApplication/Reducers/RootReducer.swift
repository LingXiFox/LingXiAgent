import Foundation
import LingXiProtocol
import LingXiClient

/// 根归纳器：统合 Runtime、Session、Stream 以及状态投影。
public enum RootReducer {
    @discardableResult
    public static func reduce(
        state: inout ApplicationState,
        action: ApplicationAction
    ) -> ApplicationChangeSet {
        var changes = ApplicationChangeSet()

        switch action {
        case let ._connectionStateChanged(connectionState):
            state.connectionState = connectionState
            state.activeSessionState?.recalculateStatus(connectionState: connectionState)
            state.recalculateStatus()
            changes.statusChanged = true
            changes.providerStatusChanged = true

        case let ._runtimeEventReceived(event):
            let c = RuntimeReducer.reduce(state: &state, event: event)
            changes.merge(with: c)

        case let ._sessionEventReceived(event):
            if state.activeSessionID == event.causal.sessionID, state.activeSessionState != nil {
                let c = SessionReducer.reduce(
                    state: &state.activeSessionState!,
                    event: event,
                    connectionState: state.connectionState
                )
                state.recalculateStatus()
                changes.merge(with: c)
            }

        case let ._streamFrameReceived(frame):
            if state.activeSessionID == frame.owner.sessionID, state.activeSessionState != nil {
                let c = SessionReducer.reduceStreamFrame(
                    state: &state.activeSessionState!,
                    frame: frame,
                    connectionState: state.connectionState
                )
                state.recalculateStatus()
                changes.merge(with: c)
            }

        case let ._snapshotResynced(snapshot):
            if state.activeSessionID == snapshot.sessionID {
                if state.activeSessionState == nil {
                    state.activeSessionState = SessionViewState(sessionID: snapshot.sessionID)
                }
                let c = SessionReducer.reduceSnapshot(
                    state: &state.activeSessionState!,
                    snapshot: snapshot,
                    connectionState: state.connectionState
                )
                state.recalculateStatus()
                changes.merge(with: c)
            }

        case let ._runtimeInfoResynced(info):
            state.runtimeInfo = info
            state.recalculateStatus()
            changes.statusChanged = true

        case let ._runtimeHealthResynced(health):
            state.runtimeHealth = health
            state.recalculateStatus()
            changes.statusChanged = true

        case let ._runtimeCapabilitiesResynced(caps):
            state.runtimeCapabilities = caps
            state.recalculateStatus()
            changes.statusChanged = true

        default:
            break
        }

        return changes
    }
}
