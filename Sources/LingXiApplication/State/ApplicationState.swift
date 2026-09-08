import Foundation
import LingXiProtocol
import LingXiClient

/// 整个应用程序的全局产品级状态（唯一对外消费接口）。
/// Frontend 只需消费 ApplicationState，严禁自行拼接底层细节。
public struct ApplicationState: Sendable, Equatable {
    // MARK: - 1. Connection & Runtime
    public var connectionState: ConnectionState
    public var runtimeHealth: RuntimeHealth?
    public var runtimeCapabilities: RuntimeCapabilities?
    public var runtimeInfo: RuntimeInfo?

    // MARK: - 2. Sessions
    public var sessionCatalog: [SessionSummary]
    public var activeSessionID: SessionID?
    public var activeSessionState: SessionViewState?
    public var activeInteraction: InteractionSnapshot? {
        activeSessionState?.activeInteraction
    }

    public var activeTurnPermissionConfiguration: PermissionConfiguration? {
        if let session = activeSessionState {
            if let turnID = session.activeTurnID {
                return session.turns[turnID]?.executionIntent.permissionConfiguration ?? session.permissionConfiguration
            }
            return nextTurnPermission ?? session.permissionConfiguration
        }
        return nextTurnPermission
    }

    // MARK: - 3. Provider & Model
    public var providers: [ProviderAccountInfo]
    public var providerStatus: ProviderStatus?
    public var models: [ProviderModelInfo]
    public var currentModelID: ModelID?
    public var selectedModel: ModelSelectionInfo?

    // MARK: - 4. Extensions
    public var extensions: [ExtensionInfo]

    public var activeMCPCount: Int {
        extensions.filter { $0.kind == .mcp && $0.enabled }.count
    }

    public var activeSkillCount: Int {
        extensions.filter { $0.kind == .skill && $0.enabled }.count
    }

    // MARK: - 5. Workspace & Diagnostics
    public var currentWorkspace: WorkspaceSummary?
    public var workspaceDiff: WorkspaceDiffSummary?
    public var latestDiagnostics: RuntimeDiagnosticsBundle?
    public var workflows: [WorkflowSnapshot]

    // MARK: - 6. Next Turn Intent
    public var nextTurnMode: AgentMode?
    public var nextTurnPermission: PermissionConfiguration?
    public var nextTurnReasoningEffort: ReasoningEffort?

    /// 当前生效的推理思考等级
    public var effectiveReasoningEffort: ReasoningEffort {
        activeSessionState?.reasoningEffort ?? nextTurnReasoningEffort ?? .auto
    }

    // MARK: - 7. Global Product Status
    public var hasActiveError: Bool
    public var status: ProductRuntimeStatus

    public init(
        connectionState: ConnectionState = .disconnected,
        runtimeHealth: RuntimeHealth? = nil,
        runtimeCapabilities: RuntimeCapabilities? = nil,
        runtimeInfo: RuntimeInfo? = nil,
        sessionCatalog: [SessionSummary] = [],
        activeSessionID: SessionID? = nil,
        activeSessionState: SessionViewState? = nil,
        providers: [ProviderAccountInfo] = [],
        providerStatus: ProviderStatus? = nil,
        models: [ProviderModelInfo] = [],
        currentModelID: ModelID? = nil,
        selectedModel: ModelSelectionInfo? = nil,
        extensions: [ExtensionInfo] = [],
        currentWorkspace: WorkspaceSummary? = nil,
        workspaceDiff: WorkspaceDiffSummary? = nil,
        latestDiagnostics: RuntimeDiagnosticsBundle? = nil,
        workflows: [WorkflowSnapshot] = [],
        nextTurnMode: AgentMode? = nil,
        nextTurnPermission: PermissionConfiguration? = nil,
        nextTurnReasoningEffort: ReasoningEffort? = nil,
        hasActiveError: Bool = false,
        status: ProductRuntimeStatus = .disconnected
    ) {
        self.connectionState = connectionState
        self.runtimeHealth = runtimeHealth
        self.runtimeCapabilities = runtimeCapabilities
        self.runtimeInfo = runtimeInfo
        self.sessionCatalog = sessionCatalog
        self.activeSessionID = activeSessionID
        self.activeSessionState = activeSessionState
        self.providers = providers
        self.providerStatus = providerStatus
        self.models = models
        self.currentModelID = currentModelID
        self.selectedModel = selectedModel
        self.extensions = extensions
        self.currentWorkspace = currentWorkspace
        self.workspaceDiff = workspaceDiff
        self.latestDiagnostics = latestDiagnostics
        self.workflows = workflows
        self.nextTurnMode = nextTurnMode
        self.nextTurnPermission = nextTurnPermission
        self.nextTurnReasoningEffort = nextTurnReasoningEffort
        self.hasActiveError = hasActiveError
        self.status = status
    }

    /// 重新计算顶层 ProductRuntimeStatus
    public mutating func recalculateStatus() {
        if let sessionState = activeSessionState {
            self.status = sessionState.status
        } else {
            switch connectionState.status {
            case .disconnected, .failed:
                self.status = .disconnected
            case .reconnecting, .handshaking, .connecting:
                self.status = .reconnecting
            case .connected:
                self.status = hasActiveError ? .error : .ready
            }
        }
    }
}
