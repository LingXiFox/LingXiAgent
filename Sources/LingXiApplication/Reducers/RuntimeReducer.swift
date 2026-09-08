import Foundation
import LingXiProtocol
import LingXiClient

/// Runtime 全局语义事件与快照归纳器。
public enum RuntimeReducer {
    public static func reduce(
        state: inout ApplicationState,
        event: RuntimeEventEnvelope
    ) {
        switch event.payload {
        case let .runtimeHealthChanged(health):
            state.runtimeHealth = health

        case let .runtimeCapabilitiesChanged(capabilities):
            state.runtimeCapabilities = capabilities

        case let .sessionCreated(summary):
            if let index = state.sessionCatalog.firstIndex(where: { $0.sessionID == summary.sessionID }) {
                state.sessionCatalog[index] = summary
            } else {
                state.sessionCatalog.append(summary)
            }

        case let .sessionUpdated(summary):
            if let index = state.sessionCatalog.firstIndex(where: { $0.sessionID == summary.sessionID }) {
                state.sessionCatalog[index] = summary
            } else {
                state.sessionCatalog.append(summary)
            }

        case let .sessionDeleted(sessionID):
            state.sessionCatalog.removeAll { $0.sessionID == sessionID }
            if state.activeSessionID == sessionID {
                state.activeSessionID = nil
                state.activeSessionState = nil
            }

        case .providerCatalogChanged:
            break

        case let .providerStatusChanged(pStatus):
            state.providerStatus = pStatus

        case .modelCatalogChanged:
            break

        case .extensionCatalogChanged:
            break

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

        case .globalConfigurationChanged:
            break

        case .unknown:
            break
        }

        state.recalculateStatus()
    }
}
