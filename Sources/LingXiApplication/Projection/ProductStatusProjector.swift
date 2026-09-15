import Foundation
import LingXiProtocol
import LingXiClient

/// 统一产品状态计算器：由底层事实严格投影高层产品状态。
public enum ProductStatusProjector {
    public static func projectStatus(
        connectionState: ConnectionState,
        activeInteraction: InteractionSnapshot?,
        pendingInteractions: [InteractionSnapshot],
        providerRequestState: ProviderRequestState?,
        activeSubagentsCount: Int,
        hasRunningTools: Bool,
        hasActiveThinking: Bool,
        isPaging: Bool,
        hasActiveError: Bool
    ) -> ProductRuntimeStatus {
        if activeInteraction != nil || !pendingInteractions.isEmpty {
            return .actionRequired
        }

        if activeSubagentsCount > 0 {
            return .runningSubagents
        }

        if hasActiveThinking || providerRequestState == .streaming {
            return .thinking
        }

        if hasRunningTools {
            return .runningTool
        }

        switch connectionState.status {
        case .disconnected, .failed:
            return .disconnected
        case .reconnecting, .handshaking, .connecting:
            return .reconnecting
        case .connected:
            break
        }

        if providerRequestState == .rateLimited {
            return .rateLimited
        }

        if providerRequestState == .scheduled
            || providerRequestState == .waitingForRateBudget
            || providerRequestState == .requesting
            || providerRequestState == .retryScheduled {
            return .waitingForProvider
        }

        if isPaging {
            return .paging
        }

        if hasActiveError {
            return .error
        }

        return .ready
    }
}
