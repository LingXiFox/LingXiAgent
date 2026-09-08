import Foundation
import LingXiProtocol
import LingXiClient

/// 根归纳器：统合 Runtime、Session、Stream 以及状态投影。
public enum RootReducer {
    public static func reduce(
        state: inout ApplicationState,
        action: ApplicationAction
    ) {
        switch action {
        case let ._connectionStateChanged(connectionState):
            state.connectionState = connectionState
            state.activeSessionState?.recalculateStatus(connectionState: connectionState)
            state.recalculateStatus()

        case let ._runtimeEventReceived(event):
            RuntimeReducer.reduce(state: &state, event: event)

        case let ._sessionEventReceived(event):
            if state.activeSessionID == event.causal.sessionID, state.activeSessionState != nil {
                SessionReducer.reduce(
                    state: &state.activeSessionState!,
                    event: event,
                    connectionState: state.connectionState
                )
                state.recalculateStatus()
            }

        case let ._streamFrameReceived(frame):
            if state.activeSessionID == frame.owner.sessionID, state.activeSessionState != nil {
                SessionReducer.reduceStreamFrame(
                    state: &state.activeSessionState!,
                    frame: frame,
                    connectionState: state.connectionState
                )
                state.recalculateStatus()
            }

        case let ._snapshotResynced(snapshot):
            if state.activeSessionID == snapshot.sessionID {
                if state.activeSessionState == nil {
                    state.activeSessionState = SessionViewState(sessionID: snapshot.sessionID)
                }
                SessionReducer.reduceSnapshot(
                    state: &state.activeSessionState!,
                    snapshot: snapshot,
                    connectionState: state.connectionState
                )
                state.recalculateStatus()
            }

        case let ._runtimeInfoResynced(info):
            state.runtimeInfo = info
            state.recalculateStatus()

        case let ._runtimeHealthResynced(health):
            state.runtimeHealth = health
            state.recalculateStatus()

        case let ._runtimeCapabilitiesResynced(caps):
            state.runtimeCapabilities = caps
            state.recalculateStatus()

        default:
            break
        }
    }
}
