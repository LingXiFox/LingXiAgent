import Foundation
import LingXiProtocol
import LingXiClient

/// Runtime 全局语义事件与快照归纳器。
public enum RuntimeReducer {
    @discardableResult
    public static func reduce(
        state: inout ApplicationState,
        event: RuntimeEventEnvelope
    ) -> ApplicationChangeSet {
        var changes = ApplicationChangeSet()
        switch event.payload {
        case let .runtimeHealthChanged(health):
            state.runtimeHealth = health
            changes.statusChanged = true

        case let .runtimeCapabilitiesChanged(capabilities):
            state.runtimeCapabilities = capabilities
            changes.statusChanged = true

        case let .sessionCreated(summary):
            if let index = state.sessionCatalog.firstIndex(where: { $0.sessionID == summary.sessionID }) {
                state.sessionCatalog[index] = summary
            } else {
                state.sessionCatalog.append(summary)
            }
            changes.sessionChanged = true

        case let .sessionUpdated(summary):
            if let index = state.sessionCatalog.firstIndex(where: { $0.sessionID == summary.sessionID }) {
                state.sessionCatalog[index] = summary
            } else {
                state.sessionCatalog.append(summary)
            }
            changes.sessionChanged = true

        case let .sessionDeleted(sessionID):
            state.sessionCatalog.removeAll { $0.sessionID == sessionID }
            if state.activeSessionID == sessionID {
                state.activeSessionID = nil
                state.activeSessionState = nil
                changes.sessionChanged = true
                changes.transcriptStructureChanged = true
            }

        case .providerCatalogChanged:
            changes.providerStatusChanged = true

        case let .providerStatusChanged(pStatus):
            state.providerStatus = pStatus
            changes.providerStatusChanged = true
            changes.statusChanged = true

        case .modelCatalogChanged:
            changes.providerStatusChanged = true

        case .extensionCatalogChanged:
            changes.extensionsChanged = true

        case let .extensionStatusChanged(extStatus):
            if let index = state.extensions.firstIndex(where: { $0.id == extStatus.extensionID }) {
                let current = state.extensions[index]
                state.extensions[index] = ExtensionInfo(
                    id: current.id,
                    version: current.version,
                    kind: current.kind,
                    scope: current.scope,
                    enabled: extStatus.enabled,
                    lifecycleState: extStatus.state
                )
            }
            changes.extensionsChanged = true

        case .globalConfigurationChanged:
            changes.layoutRelevantChanged = true

        case .unknown:
            break
        }

        state.recalculateStatus()
        return changes
    }
}
