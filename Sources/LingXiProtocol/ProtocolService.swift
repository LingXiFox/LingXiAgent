import Foundation

// MARK: - User Input & SubmitTurn Models

public struct UserInput: Codable, Sendable, Equatable {
    public let text: String
    public let attachments: [ContentRef]

    public init(text: String, attachments: [ContentRef] = []) {
        self.text = text
        self.attachments = attachments
    }
}

public struct SubmitTurnRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let input: UserInput
    public let executionIntent: TurnExecutionIntent

    public init(sessionID: SessionID, input: UserInput, executionIntent: TurnExecutionIntent = TurnExecutionIntent()) {
        self.sessionID = sessionID
        self.input = input
        self.executionIntent = executionIntent
    }
}

public struct SubmitTurnResult: Codable, Sendable, Equatable {
    public let turnID: TurnID
    public let status: TurnStatus
    public let runID: RunID?

    public init(turnID: TurnID, status: TurnStatus, runID: RunID? = nil) {
        self.turnID = turnID
        self.status = status
        self.runID = runID
    }
}

public struct CancelTurnRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let turnID: TurnID

    public init(sessionID: SessionID, turnID: TurnID) {
        self.sessionID = sessionID
        self.turnID = turnID
    }
}

public struct CancelRunRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let runID: RunID
    public let reason: String?

    public init(sessionID: SessionID, runID: RunID, reason: String? = nil) {
        self.sessionID = sessionID
        self.runID = runID
        self.reason = reason
    }
}

public struct ResumeRunRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let runID: RunID

    public init(sessionID: SessionID, runID: RunID) {
        self.sessionID = sessionID
        self.runID = runID
    }
}

// MARK: - Session Commands & Queries

public struct CreateSessionRequest: Codable, Sendable, Equatable {
    public let workspace: String?
    public let initialModel: String?
    public let defaultMode: AgentMode
    public let defaultPermissionConfiguration: PermissionConfiguration

    public init(
        workspace: String? = nil,
        initialModel: String? = nil,
        defaultMode: AgentMode = .build,
        defaultPermissionConfiguration: PermissionConfiguration = .askWorkspace
    ) {
        self.workspace = workspace
        self.initialModel = initialModel
        self.defaultMode = defaultMode
        self.defaultPermissionConfiguration = defaultPermissionConfiguration
    }
}

public struct RenameSessionRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let title: String?

    public init(sessionID: SessionID, title: String?) {
        self.sessionID = sessionID
        self.title = title
    }
}

public struct SetSessionReasoningEffortRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let effort: ReasoningEffort

    public init(sessionID: SessionID, effort: ReasoningEffort) {
        self.sessionID = sessionID
        self.effort = effort
    }
}

public struct DeleteSessionRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID

    public init(sessionID: SessionID) {
        self.sessionID = sessionID
    }
}

public struct GetSessionRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID

    public init(sessionID: SessionID) {
        self.sessionID = sessionID
    }
}

public struct GetSessionSnapshotRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID

    public init(sessionID: SessionID) {
        self.sessionID = sessionID
    }
}

public struct ListSessionEventsRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let before: EventCursor?
    public let after: EventCursor?
    public let limit: Int

    public init(sessionID: SessionID, before: EventCursor? = nil, after: EventCursor? = nil, limit: Int = 50) {
        self.sessionID = sessionID
        self.before = before
        self.after = after
        self.limit = limit
    }
}

public struct GetTurnRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let turnID: TurnID

    public init(sessionID: SessionID, turnID: TurnID) {
        self.sessionID = sessionID
        self.turnID = turnID
    }
}

public struct ListTurnsRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let page: PageRequest

    public init(sessionID: SessionID, page: PageRequest = PageRequest()) {
        self.sessionID = sessionID
        self.page = page
    }
}

public struct GetRunRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let runID: RunID

    public init(sessionID: SessionID, runID: RunID) {
        self.sessionID = sessionID
        self.runID = runID
    }
}

public struct ListRunsRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let page: PageRequest

    public init(sessionID: SessionID, page: PageRequest = PageRequest()) {
        self.sessionID = sessionID
        self.page = page
    }
}

// MARK: - Interaction Commands & Queries

public struct ListInteractionsRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID

    public init(sessionID: SessionID) {
        self.sessionID = sessionID
    }
}

public struct ResolveInteractionRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let interactionID: InteractionID
    public let resolution: InteractionResolution

    public init(sessionID: SessionID, interactionID: InteractionID, resolution: InteractionResolution) {
        self.sessionID = sessionID
        self.interactionID = interactionID
        self.resolution = resolution
    }
}

// MARK: - Extended Domain Models for Frozen Contract

// 1. Runtime Extended
public struct EffectiveConfigurationSnapshot: Codable, Sendable, Equatable {
    public let coreVersion: String
    public let protocolVersion: ProtocolVersion
    public let defaultMode: AgentMode
    public let defaultPermission: PermissionConfiguration

    public init(
        coreVersion: String,
        protocolVersion: ProtocolVersion = .current,
        defaultMode: AgentMode = .build,
        defaultPermission: PermissionConfiguration = .askWorkspace
    ) {
        self.coreVersion = coreVersion
        self.protocolVersion = protocolVersion
        self.defaultMode = defaultMode
        self.defaultPermission = defaultPermission
    }
}

public struct UpdateTypedSettingRequest: Codable, Sendable, Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

// 2. Run Extended
public struct GetAgentTreeRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID

    public init(sessionID: SessionID) {
        self.sessionID = sessionID
    }
}

// 3. Provider Extended
public struct GetProviderRequest: Codable, Sendable, Equatable {
    public let providerID: String

    public init(providerID: String) {
        self.providerID = providerID
    }
}

public struct TestProviderRequest: Codable, Sendable, Equatable {
    public let providerID: String

    public init(providerID: String) {
        self.providerID = providerID
    }
}

public struct TestProviderResult: Codable, Sendable, Equatable {
    public let providerID: String
    public let reachable: Bool
    public let latencyMs: Double?
    public let message: String?

    public init(providerID: String, reachable: Bool, latencyMs: Double? = nil, message: String? = nil) {
        self.providerID = providerID
        self.reachable = reachable
        self.latencyMs = latencyMs
        self.message = message
    }
}

public struct ConfigureProviderRequest: Codable, Sendable, Equatable {
    public let providerID: String
    public let accountID: String
    public let displayName: String?
    public let endpointURL: String?
    public let credentialReference: CredentialRef?

    public init(providerID: String, accountID: String, displayName: String? = nil, endpointURL: String? = nil, credentialReference: CredentialRef? = nil) {
        self.providerID = providerID
        self.accountID = accountID
        self.displayName = displayName
        self.endpointURL = endpointURL
        self.credentialReference = credentialReference
    }
}

public struct RemoveProviderRequest: Codable, Sendable, Equatable {
    public let accountID: String

    public init(accountID: String) {
        self.accountID = accountID
    }
}

// 4. Model Extended
public struct SelectModelRequest: Codable, Sendable, Equatable {
    public let model: String

    public init(model: String) {
        self.model = model
    }
}

public struct ModelSelectionInfo: Codable, Sendable, Equatable {
    public let modelID: String
    public let providerID: String?

    public init(modelID: String, providerID: String? = nil) {
        self.modelID = modelID
        self.providerID = providerID
    }
}

public struct GetModelRequest: Codable, Sendable, Equatable {
    public let modelID: String

    public init(modelID: String) {
        self.modelID = modelID
    }
}

public struct GetModelCapabilitiesRequest: Codable, Sendable, Equatable {
    public let modelID: String

    public init(modelID: String) {
        self.modelID = modelID
    }
}

public struct ModelCapabilitiesInfo: Codable, Sendable, Equatable {
    public let modelID: String
    public let supportsStreaming: Bool
    public let supportsTools: Bool
    public let supportsVision: Bool
    public let maxContextTokens: Int?
    public let reasoningCapability: ReasoningCapability?

    public init(modelID: String, supportsStreaming: Bool = true, supportsTools: Bool = true, supportsVision: Bool = false, maxContextTokens: Int? = 128_000, reasoningCapability: ReasoningCapability? = nil) {
        self.modelID = modelID
        self.supportsStreaming = supportsStreaming
        self.supportsTools = supportsTools
        self.supportsVision = supportsVision
        self.maxContextTokens = maxContextTokens
        self.reasoningCapability = reasoningCapability
    }
}

public struct SetModelSelectionRequest: Codable, Sendable, Equatable {
    public let modelID: String
    public let sessionID: SessionID?

    public init(modelID: String, sessionID: SessionID? = nil) {
        self.modelID = modelID
        self.sessionID = sessionID
    }
}

// 5. Context Extended
public struct GetContextStateRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID

    public init(sessionID: SessionID) {
        self.sessionID = sessionID
    }
}

public struct CompactContextRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID

    public init(sessionID: SessionID) {
        self.sessionID = sessionID
    }
}

public struct SearchContextRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let query: String
    public let limit: Int

    public init(sessionID: SessionID, query: String, limit: Int = 10) {
        self.sessionID = sessionID
        self.query = query
        self.limit = limit
    }
}

public struct ContextSearchResultItem: Codable, Sendable, Equatable {
    public let uri: String
    public let snippet: String
    public let score: Double

    public init(uri: String, snippet: String, score: Double) {
        self.uri = uri
        self.snippet = snippet
        self.score = score
    }
}

public struct GetContextEntryRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let uri: String

    public init(sessionID: SessionID, uri: String) {
        self.sessionID = sessionID
        self.uri = uri
    }
}

public struct ContextEntryItem: Codable, Sendable, Equatable {
    public let uri: String
    public let content: String
    public let tokenCount: Int?

    public init(uri: String, content: String, tokenCount: Int? = nil) {
        self.uri = uri
        self.content = content
        self.tokenCount = tokenCount
    }
}

public struct UpdateContextPolicyRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID?
    public let maxActiveTokens: Int?
    public let autoCompactionEnabled: Bool?

    public init(sessionID: SessionID? = nil, maxActiveTokens: Int? = nil, autoCompactionEnabled: Bool? = nil) {
        self.sessionID = sessionID
        self.maxActiveTokens = maxActiveTokens
        self.autoCompactionEnabled = autoCompactionEnabled
    }
}

// 6. Extension Extended
public struct ListExtensionsRequest: Codable, Sendable, Equatable {
    public let kind: ExtensionKind?

    public init(kind: ExtensionKind? = nil) {
        self.kind = kind
    }
}

public struct GetExtensionStatusRequest: Codable, Sendable, Equatable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct GetExtensionRequest: Codable, Sendable, Equatable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct InstallExtensionRequest: Codable, Sendable, Equatable {
    public let name: String
    public let location: String

    public init(name: String, location: String) {
        self.name = name
        self.location = location
    }
}

public struct UninstallExtensionRequest: Codable, Sendable, Equatable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct EnableExtensionRequest: Codable, Sendable, Equatable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct DisableExtensionRequest: Codable, Sendable, Equatable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct ConfigureExtensionRequest: Codable, Sendable, Equatable {
    public let id: String
    public let configuration: [String: String]

    public init(id: String, configuration: [String: String]) {
        self.id = id
        self.configuration = configuration
    }
}

// 7. Workspace Extended
public struct WorkspaceSummary: Codable, Sendable, Equatable {
    public let rootPath: String
    public let isGitRepository: Bool
    public var codebaseNodes: Int?
    public var codebaseEdges: Int?
    public var indexingState: String?

    public init(rootPath: String, isGitRepository: Bool, codebaseNodes: Int? = nil, codebaseEdges: Int? = nil, indexingState: String? = nil) {
        self.rootPath = rootPath
        self.isGitRepository = isGitRepository
        self.codebaseNodes = codebaseNodes
        self.codebaseEdges = codebaseEdges
        self.indexingState = indexingState
    }
}

public struct WorkspaceDiffSummary: Codable, Sendable, Equatable {
    public let diff: String

    public init(diff: String) {
        self.diff = diff
    }
}

public struct SetWorkspaceRequest: Codable, Sendable, Equatable {
    public let workspaceRoot: String

    public init(workspaceRoot: String) {
        self.workspaceRoot = workspaceRoot
    }
}

// 8. Diagnostics Extended
public struct GetPerformanceMetricsRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID

    public init(sessionID: SessionID) {
        self.sessionID = sessionID
    }
}

public struct ProviderMetricsInfo: Codable, Sendable, Equatable {
    public let requestCount: Int
    public let errorCount: Int
    public let averageLatencyMs: Double

    public init(requestCount: Int = 0, errorCount: Int = 0, averageLatencyMs: Double = 0) {
        self.requestCount = requestCount
        self.errorCount = errorCount
        self.averageLatencyMs = averageLatencyMs
    }
}

public struct GetRunTraceRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let runID: RunID

    public init(sessionID: SessionID, runID: RunID) {
        self.sessionID = sessionID
        self.runID = runID
    }
}

public struct RunTraceInfo: Codable, Sendable, Equatable {
    public let runID: RunID
    public let sessionID: SessionID
    public let spans: [String]

    public init(runID: RunID, sessionID: SessionID, spans: [String] = []) {
        self.runID = runID
        self.sessionID = sessionID
        self.spans = spans
    }
}

// 9. Credential Extended
public struct StoreCredentialRequest: Codable, Sendable, Equatable {
    public let secret: String

    public init(secret: String) {
        self.secret = secret
    }
}

public struct DeleteCredentialRequest: Codable, Sendable, Equatable {
    public let reference: CredentialRef

    public init(reference: CredentialRef) {
        self.reference = reference
    }
}

public struct GetCredentialStatusRequest: Codable, Sendable, Equatable {
    public let reference: CredentialRef

    public init(reference: CredentialRef) {
        self.reference = reference
    }
}

public struct CredentialResult: Codable, Sendable, Equatable {
    public let reference: CredentialRef

    public init(reference: CredentialRef) {
        self.reference = reference
    }
}

public struct CredentialStatusInfo: Codable, Sendable, Equatable {
    public let reference: CredentialRef
    public let isConfigured: Bool

    public init(reference: CredentialRef, isConfigured: Bool) {
        self.reference = reference
        self.isConfigured = isConfigured
    }
}

public struct TestCredentialRequest: Codable, Sendable, Equatable {
    public let reference: CredentialRef

    public init(reference: CredentialRef) {
        self.reference = reference
    }
}

public struct TestCredentialResult: Codable, Sendable, Equatable {
    public let reference: CredentialRef
    public let isValid: Bool

    public init(reference: CredentialRef, isValid: Bool) {
        self.reference = reference
        self.isValid = isValid
    }
}

// MARK: - LingXiProtocolService Contract

/// LingXiProtocolService：冻结后的 Protocol vNext 目标服务契约。
/// CoreHost 必须实现该契约，负责 Protocol ↔ Core 映射。
public protocol LingXiProtocolService: Sendable {
    // MARK: - 1. Runtime
    func getRuntimeInfo(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeInfo>
    func getRuntimeHealth(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeHealth>
    func getRuntimeCapabilities(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeCapabilities>
    func getEffectiveConfiguration(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<EffectiveConfigurationSnapshot>
    func reloadConfiguration(envelope: CommandEnvelope<VoidResult>) async throws -> CommandReceipt<VoidResult>
    func updateTypedSetting(envelope: CommandEnvelope<UpdateTypedSettingRequest>) async throws -> CommandReceipt<VoidResult>

    // MARK: - 2. Session
    func createSession(envelope: CommandEnvelope<CreateSessionRequest>) async throws -> CommandReceipt<SessionSummary>
    func renameSession(envelope: CommandEnvelope<RenameSessionRequest>) async throws -> CommandReceipt<SessionSummary>
    func setSessionReasoningEffort(envelope: CommandEnvelope<SetSessionReasoningEffortRequest>) async throws -> CommandReceipt<SessionSummary>
    func deleteSession(envelope: CommandEnvelope<DeleteSessionRequest>) async throws -> CommandReceipt<VoidResult>
    func revertLastTurn(envelope: CommandEnvelope<RevertLastTurnRequest>) async throws -> CommandReceipt<RevertLastTurnResult>
    func getSession(envelope: QueryEnvelope<GetSessionRequest>) async throws -> ResponseEnvelope<SessionSummary>
    func listSessions(envelope: QueryEnvelope<PageRequest>) async throws -> ResponseEnvelope<Page<SessionSummary>>
    func getSessionSnapshot(envelope: QueryEnvelope<GetSessionSnapshotRequest>) async throws -> ResponseEnvelope<SessionSnapshot>

    // MARK: - 3. Turn
    func submitTurn(envelope: CommandEnvelope<SubmitTurnRequest>) async throws -> CommandReceipt<SubmitTurnResult>
    func cancelTurn(envelope: CommandEnvelope<CancelTurnRequest>) async throws -> CommandReceipt<VoidResult>
    func getTurn(envelope: QueryEnvelope<GetTurnRequest>) async throws -> ResponseEnvelope<TurnSnapshot>
    func listTurns(envelope: QueryEnvelope<ListTurnsRequest>) async throws -> ResponseEnvelope<Page<TurnSnapshot>>

    // MARK: - 4. Run
    func cancelRun(envelope: CommandEnvelope<CancelRunRequest>) async throws -> CommandReceipt<VoidResult>
    func resumeRun(envelope: CommandEnvelope<ResumeRunRequest>) async throws -> CommandReceipt<RunSnapshot>
    func getRun(envelope: QueryEnvelope<GetRunRequest>) async throws -> ResponseEnvelope<RunSnapshot>
    func listRuns(envelope: QueryEnvelope<ListRunsRequest>) async throws -> ResponseEnvelope<Page<RunSnapshot>>
    func getAgentTree(envelope: QueryEnvelope<GetAgentTreeRequest>) async throws -> ResponseEnvelope<AgentTreeNode>

    // MARK: - 5. Interaction
    func listPendingInteractions(envelope: QueryEnvelope<ListInteractionsRequest>) async throws -> ResponseEnvelope<[InteractionSnapshot]>
    func resolveInteraction(envelope: CommandEnvelope<ResolveInteractionRequest>) async throws -> CommandReceipt<VoidResult>

    // MARK: - 6. Provider
    func listProviders(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[ProviderAccountInfo]>
    func getProviderStatus(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ProviderStatus>
    func getProvider(envelope: QueryEnvelope<GetProviderRequest>) async throws -> ResponseEnvelope<ProviderAccountInfo>
    func testProvider(envelope: CommandEnvelope<TestProviderRequest>) async throws -> CommandReceipt<TestProviderResult>
    func configureProvider(envelope: CommandEnvelope<ConfigureProviderRequest>) async throws -> CommandReceipt<ProviderAccountInfo>
    func removeProvider(envelope: CommandEnvelope<RemoveProviderRequest>) async throws -> CommandReceipt<VoidResult>
    func reloadProviders(envelope: CommandEnvelope<VoidResult>) async throws -> CommandReceipt<VoidResult>

    // MARK: - 7. Model
    func listModels(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[ProviderModelInfo]>
    func getModelSelection(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ModelSelectionInfo>
    func selectModel(envelope: CommandEnvelope<SelectModelRequest>) async throws -> CommandReceipt<ModelSelectionInfo>
    func getModel(envelope: QueryEnvelope<GetModelRequest>) async throws -> ResponseEnvelope<ProviderModelInfo>
    func getModelCapabilities(envelope: QueryEnvelope<GetModelCapabilitiesRequest>) async throws -> ResponseEnvelope<ModelCapabilitiesInfo>
    func setModelSelection(envelope: CommandEnvelope<SetModelSelectionRequest>) async throws -> CommandReceipt<ModelSelectionInfo>

    // MARK: - 8. Context
    func getContextState(envelope: QueryEnvelope<GetContextStateRequest>) async throws -> ResponseEnvelope<ContextStateSnapshot>
    func getContextPolicy(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ContextCachePolicySnapshot>
    func compactContext(envelope: CommandEnvelope<CompactContextRequest>) async throws -> CommandReceipt<VoidResult>
    func searchContext(envelope: QueryEnvelope<SearchContextRequest>) async throws -> ResponseEnvelope<[ContextSearchResultItem]>
    func getContextEntry(envelope: QueryEnvelope<GetContextEntryRequest>) async throws -> ResponseEnvelope<ContextEntryItem>
    func updateContextPolicy(envelope: CommandEnvelope<UpdateContextPolicyRequest>) async throws -> CommandReceipt<ContextCachePolicySnapshot>

    // MARK: - 9. Extension
    func listExtensions(envelope: QueryEnvelope<ListExtensionsRequest>) async throws -> ResponseEnvelope<[ExtensionInfo]>
    func getExtensionStatus(envelope: QueryEnvelope<GetExtensionStatusRequest>) async throws -> ResponseEnvelope<ExtensionInfo>
    func getExtension(envelope: QueryEnvelope<GetExtensionRequest>) async throws -> ResponseEnvelope<ExtensionInfo>
    func installExtension(envelope: CommandEnvelope<InstallExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo>
    func uninstallExtension(envelope: CommandEnvelope<UninstallExtensionRequest>) async throws -> CommandReceipt<VoidResult>
    func enableExtension(envelope: CommandEnvelope<EnableExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo>
    func disableExtension(envelope: CommandEnvelope<DisableExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo>
    func reloadExtensions(envelope: CommandEnvelope<VoidResult>) async throws -> CommandReceipt<VoidResult>
    func configureExtension(envelope: CommandEnvelope<ConfigureExtensionRequest>) async throws -> CommandReceipt<ExtensionInfo>
    func executeExtensionCommand(envelope: CommandEnvelope<ExecuteExtensionCommandRequest>) async throws -> CommandReceipt<ExtensionCommandExecutionResult>

    // MARK: - 10. Workspace
    func getWorkspace(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<WorkspaceSummary>
    func setWorkspace(envelope: CommandEnvelope<SetWorkspaceRequest>) async throws -> CommandReceipt<WorkspaceSummary>
    func getWorkspaceSummary(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<WorkspaceSummary>
    func getWorkspaceDiffSummary(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<WorkspaceDiffSummary>

    // MARK: - 11. Resource / Content Data Plane & Control Plane
    func beginContentUpload(envelope: CommandEnvelope<BeginContentUploadRequest>) async throws -> CommandReceipt<BeginContentUploadResponse>
    func uploadContentChunk(uploadID: String, chunkIndex: UInt64, data: Data) async throws
    func commitContentUpload(envelope: CommandEnvelope<CommitContentUploadRequest>) async throws -> CommandReceipt<ContentRef>
    func abortContentUpload(envelope: CommandEnvelope<AbortContentUploadRequest>) async throws -> CommandReceipt<VoidResult>

    func getContentMetadata(ref: ContentRef, authorization: ContentAuthorizationContext) async throws -> ContentMetadata
    func getContent(ref: ContentRef, authorization: ContentAuthorizationContext) async throws -> Data
    func getContentRange(ref: ContentRef, offset: Int, length: Int, authorization: ContentAuthorizationContext) async throws -> Data

    // MARK: - 12. Diagnostics
    func getDiagnostics(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<RuntimeDiagnosticsBundle>
    func getPerformanceMetrics(envelope: QueryEnvelope<GetPerformanceMetricsRequest>) async throws -> ResponseEnvelope<TurnPerformanceReport?>
    func getProviderMetrics(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<ProviderMetricsInfo>
    func getRunTrace(envelope: QueryEnvelope<GetRunTraceRequest>) async throws -> ResponseEnvelope<RunTraceInfo>

    // MARK: - 13. Credential
    func listCredentials(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[CredentialRef]>
    func storeCredential(envelope: CommandEnvelope<StoreCredentialRequest>) async throws -> CommandReceipt<CredentialResult>
    func deleteCredential(envelope: CommandEnvelope<DeleteCredentialRequest>) async throws -> CommandReceipt<VoidResult>
    func getCredentialStatus(envelope: QueryEnvelope<GetCredentialStatusRequest>) async throws -> ResponseEnvelope<CredentialStatusInfo>
    func testCredential(envelope: CommandEnvelope<TestCredentialRequest>) async throws -> CommandReceipt<TestCredentialResult>

    // MARK: - 14. Task
    func createTask(envelope: CommandEnvelope<CreateTaskRequest>) async throws -> CommandReceipt<TaskSnapshot>
    func getTask(envelope: QueryEnvelope<GetTaskRequest>) async throws -> ResponseEnvelope<TaskSnapshot>
    func listTasks(envelope: QueryEnvelope<ListTasksRequest>) async throws -> ResponseEnvelope<[TaskSnapshot]>
    func pauseTask(envelope: CommandEnvelope<TaskLifecycleRequest>) async throws -> CommandReceipt<TaskSnapshot>
    func resumeTask(envelope: CommandEnvelope<TaskLifecycleRequest>) async throws -> CommandReceipt<TaskSnapshot>
    func cancelTask(envelope: CommandEnvelope<TaskLifecycleRequest>) async throws -> CommandReceipt<TaskSnapshot>
    func forkTask(envelope: CommandEnvelope<ForkTaskRequest>) async throws -> CommandReceipt<TaskSnapshot>
    func updateTaskCriteria(envelope: CommandEnvelope<UpdateTaskCriteriaRequest>) async throws -> CommandReceipt<TaskSnapshot>
    func listTaskArtifacts(envelope: QueryEnvelope<GetTaskRequest>) async throws -> ResponseEnvelope<[TaskArtifact]>
    func getTaskReport(envelope: QueryEnvelope<GetTaskRequest>) async throws -> ResponseEnvelope<TaskReport?>
    func finalizeTask(envelope: CommandEnvelope<TaskFinalizeRequest>) async throws -> CommandReceipt<TaskSnapshot>

    // MARK: - 15. Workspace Worktree
    func createWorktree(envelope: CommandEnvelope<CreateWorktreeRequest>) async throws -> CommandReceipt<WorkspaceWorktreeInfo>
    func listWorktrees(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[WorkspaceWorktreeInfo]>
    func applyWorktree(envelope: CommandEnvelope<ApplyWorktreeRequest>) async throws -> CommandReceipt<VoidResult>
    func discardWorktree(envelope: CommandEnvelope<DiscardWorktreeRequest>) async throws -> CommandReceipt<VoidResult>
    func pruneWorktrees(envelope: CommandEnvelope<PruneWorktreesRequest>) async throws -> CommandReceipt<VoidResult>

    // MARK: - 16. Agent Preset & Side Question
    func submitSideQuestion(envelope: CommandEnvelope<SubmitSideQuestionRequest>) async throws -> CommandReceipt<SideQuestionResult>
    func listAgentPresets(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[AgentPresetInfo]>
    func listAgentRuns(envelope: QueryEnvelope<GetRunRequest>) async throws -> ResponseEnvelope<[AgentRunDetail]>
    func compareMultiRuns(envelope: CommandEnvelope<MultiRunCompareRequest>) async throws -> CommandReceipt<MultiRunCompareResult>

    // MARK: - Event Streams
    func subscribeRuntimeEvents(after: EventCursor?) async -> AsyncStream<RuntimeEventEnvelope>
    func subscribeSessionEvents(sessionID: SessionID, after: EventCursor?) async throws -> AsyncStream<SessionEventEnvelope>
    func listSessionEvents(request: ListSessionEventsRequest) async throws -> [SessionEventEnvelope]

    // MARK: - High-Frequency StreamFrames
    func subscribeStreamFrames(streamID: StreamID, afterIndex: UInt64?) async throws -> AsyncStream<StreamFrame>
}

public extension LingXiProtocolService {
    func getContentMetadata(ref: ContentRef) async throws -> ContentMetadata {
        try await getContentMetadata(ref: ref, authorization: .anonymous)
    }
    func getContent(ref: ContentRef) async throws -> Data {
        try await getContent(ref: ref, authorization: .anonymous)
    }
    func getContentRange(ref: ContentRef, offset: Int, length: Int) async throws -> Data {
        try await getContentRange(ref: ref, offset: offset, length: length, authorization: .anonymous)
    }

    // Default implementations for newly added Task, Worktree, and Preset RPCs
    func createTask(envelope: CommandEnvelope<CreateTaskRequest>) async throws -> CommandReceipt<TaskSnapshot> {
        let capsule = TaskCapsule(
            sessionID: envelope.payload.sessionID,
            projectID: envelope.payload.projectID,
            objective: envelope.payload.objective,
            successCriteria: envelope.payload.successCriteria
        )
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: 1, observedThrough: [], result: TaskSnapshot(capsule: capsule))
    }

    func getTask(envelope: QueryEnvelope<GetTaskRequest>) async throws -> ResponseEnvelope<TaskSnapshot> {
        throw CoreError(code: .resourceNotFound, message: "Task \(envelope.payload.taskID) not found")
    }

    func listTasks(envelope: QueryEnvelope<ListTasksRequest>) async throws -> ResponseEnvelope<[TaskSnapshot]> {
        return ResponseEnvelope(requestID: envelope.requestID, payload: [])
    }

    func pauseTask(envelope: CommandEnvelope<TaskLifecycleRequest>) async throws -> CommandReceipt<TaskSnapshot> {
        throw CoreError(code: .unsupportedCommand, message: "pauseTask not implemented on base service")
    }

    func resumeTask(envelope: CommandEnvelope<TaskLifecycleRequest>) async throws -> CommandReceipt<TaskSnapshot> {
        throw CoreError(code: .unsupportedCommand, message: "resumeTask not implemented on base service")
    }

    func cancelTask(envelope: CommandEnvelope<TaskLifecycleRequest>) async throws -> CommandReceipt<TaskSnapshot> {
        throw CoreError(code: .unsupportedCommand, message: "cancelTask not implemented on base service")
    }

    func forkTask(envelope: CommandEnvelope<ForkTaskRequest>) async throws -> CommandReceipt<TaskSnapshot> {
        throw CoreError(code: .unsupportedCommand, message: "forkTask not implemented on base service")
    }

    func updateTaskCriteria(envelope: CommandEnvelope<UpdateTaskCriteriaRequest>) async throws -> CommandReceipt<TaskSnapshot> {
        throw CoreError(code: .unsupportedCommand, message: "updateTaskCriteria not implemented on base service")
    }

    func listTaskArtifacts(envelope: QueryEnvelope<GetTaskRequest>) async throws -> ResponseEnvelope<[TaskArtifact]> {
        return ResponseEnvelope(requestID: envelope.requestID, payload: [])
    }

    func getTaskReport(envelope: QueryEnvelope<GetTaskRequest>) async throws -> ResponseEnvelope<TaskReport?> {
        return ResponseEnvelope(requestID: envelope.requestID, payload: nil)
    }

    func finalizeTask(envelope: CommandEnvelope<TaskFinalizeRequest>) async throws -> CommandReceipt<TaskSnapshot> {
        throw CoreError(code: .unsupportedCommand, message: "finalizeTask not implemented on base service")
    }

    func createWorktree(envelope: CommandEnvelope<CreateWorktreeRequest>) async throws -> CommandReceipt<WorkspaceWorktreeInfo> {
        let info = WorkspaceWorktreeInfo(id: UUID().uuidString, branch: envelope.payload.name, path: "/tmp/\(envelope.payload.name)")
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: 1, observedThrough: [], result: info)
    }

    func listWorktrees(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[WorkspaceWorktreeInfo]> {
        return ResponseEnvelope(requestID: envelope.requestID, payload: [])
    }

    func applyWorktree(envelope: CommandEnvelope<ApplyWorktreeRequest>) async throws -> CommandReceipt<VoidResult> {
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: 1, observedThrough: [], result: VoidResult())
    }

    func discardWorktree(envelope: CommandEnvelope<DiscardWorktreeRequest>) async throws -> CommandReceipt<VoidResult> {
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: 1, observedThrough: [], result: VoidResult())
    }

    func pruneWorktrees(envelope: CommandEnvelope<PruneWorktreesRequest>) async throws -> CommandReceipt<VoidResult> {
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: 1, observedThrough: [], result: VoidResult())
    }

    func submitSideQuestion(envelope: CommandEnvelope<SubmitSideQuestionRequest>) async throws -> CommandReceipt<SideQuestionResult> {
        let result = SideQuestionResult(answer: "Processed side question: \(envelope.payload.question)", modelUsed: "side-runner")
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: 1, observedThrough: [], result: result)
    }

    func listAgentPresets(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[AgentPresetInfo]> {
        let presets = [
            AgentPresetInfo(id: "build", name: "Builder", description: "Standard autonomous building agent", mode: .build, reasoningEffort: .auto, permissionPolicy: .ask),
            AgentPresetInfo(id: "plan", name: "Planner", description: "Architecture and design planning", mode: .plan, reasoningEffort: .high, permissionPolicy: .ask),
            AgentPresetInfo(id: "explore", name: "Explorer", description: "Read-only exploration and diagnosis", mode: .explore, reasoningEffort: .low, permissionPolicy: .auto)
        ]
        return ResponseEnvelope(requestID: envelope.requestID, payload: presets)
    }

    func listAgentRuns(envelope: QueryEnvelope<GetRunRequest>) async throws -> ResponseEnvelope<[AgentRunDetail]> {
        return ResponseEnvelope(requestID: envelope.requestID, payload: [])
    }

    func compareMultiRuns(envelope: CommandEnvelope<MultiRunCompareRequest>) async throws -> CommandReceipt<MultiRunCompareResult> {
        return CommandReceipt(commandID: envelope.commandID, applied: true, revision: 1, observedThrough: [], result: MultiRunCompareResult(runs: [:]))
    }
}


