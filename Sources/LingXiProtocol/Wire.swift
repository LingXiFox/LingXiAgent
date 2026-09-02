/// stdio JSON-lines 通道上的消息信封。
/// 每条消息标注所属 plane：控制面（request/response/event）与数据面（chunk/streamEnd）。
/// 两条 plane 共用同一物理通道但逻辑独立，数据面 chunk 不进入控制面事件流。
public enum WireMessage: Sendable, Equatable {
    case request(id: String, command: ClientCommand)
    case response(id: String, response: CoreResponse)
    case event(CoreEvent)
    case chunk(StreamChunk)
    case toolOutput(ToolOutputChunk)
    case streamEnd(StreamID, error: CoreError? = nil)
}

extension WireMessage: Codable {
    private enum Kind: String, Codable {
        case request, response, event, chunk, toolOutput, streamEnd
    }

    private enum CodingKeys: String, CodingKey {
        case kind, id, command, response, event, chunk, toolOutput, streamID, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .request:
            self = .request(
                id: try container.decode(String.self, forKey: .id),
                command: try container.decode(ClientCommand.self, forKey: .command)
            )
        case .response:
            self = .response(
                id: try container.decode(String.self, forKey: .id),
                response: try container.decode(CoreResponse.self, forKey: .response)
            )
        case .event:
            self = .event(try container.decode(CoreEvent.self, forKey: .event))
        case .chunk:
            self = .chunk(try container.decode(StreamChunk.self, forKey: .chunk))
        case .toolOutput:
            self = .toolOutput(try container.decode(ToolOutputChunk.self, forKey: .toolOutput))
        case .streamEnd:
            self = .streamEnd(
                try container.decode(StreamID.self, forKey: .streamID),
                error: try container.decodeIfPresent(CoreError.self, forKey: .error)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .request(id, command):
            try container.encode(Kind.request, forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(command, forKey: .command)
        case let .response(id, response):
            try container.encode(Kind.response, forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(response, forKey: .response)
        case let .event(event):
            try container.encode(Kind.event, forKey: .kind)
            try container.encode(event, forKey: .event)
        case let .chunk(chunk):
            try container.encode(Kind.chunk, forKey: .kind)
            try container.encode(chunk, forKey: .chunk)
        case let .toolOutput(chunk):
            try container.encode(Kind.toolOutput, forKey: .kind)
            try container.encode(chunk, forKey: .toolOutput)
        case let .streamEnd(streamID, error):
            try container.encode(Kind.streamEnd, forKey: .kind)
            try container.encode(streamID, forKey: .streamID)
            try container.encodeIfPresent(error, forKey: .error)
        }
    }
}

extension ClientCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, sessionID, content, title, model, permissionReply, questionReply, permissionConfiguration, runID, providerCredential, providerAccount, accountID, deleteUnusedCredential, credential, extensionKind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .ping: self = .ping
        case .getInfo: self = .getInfo
        case .getState: self = .getState
        case .openTestStream: self = .openTestStream
        case .createSession: self = .createSession
        case .listSessions: self = .listSessions
        case .getSession:
            self = .getSession(sessionID: try container.decode(SessionID.self, forKey: .sessionID))
        case .renameSession:
            self = .renameSession(sessionID: try container.decode(SessionID.self, forKey: .sessionID), title: try container.decodeIfPresent(String.self, forKey: .title))
        case .getContext:
            self = .getContext(sessionID: try container.decode(SessionID.self, forKey: .sessionID))
        case .getContextProjection:
            self = .getContextProjection(sessionID: try container.decode(SessionID.self, forKey: .sessionID))
        case .getPerformance:
            self = .getPerformance(sessionID: try container.decode(SessionID.self, forKey: .sessionID))
        case .getProviderStatus: self = .getProviderStatus
        case .getDiagnostics: self = .getDiagnostics
        case .getPermissionConfiguration: self = .getPermissionConfiguration
        case .setPermissionConfiguration:
            self = .setPermissionConfiguration(try container.decode(PermissionConfiguration.self, forKey: .permissionConfiguration))
        case .getProjectCache: self = .getProjectCache
        case .compactSession: self = .compactSession(sessionID: try container.decode(SessionID.self, forKey: .sessionID))
        case .listChildSessions: self = .listChildSessions(parentSessionID: try container.decode(SessionID.self, forKey: .sessionID))
        case .listAgentRuns: self = .listAgentRuns(sessionID: try container.decode(SessionID.self, forKey: .sessionID))
        case .getAgentRun: self = .getAgentRun(runID: try container.decode(AgentRunID.self, forKey: .runID))
        case .getAgentTree: self = .getAgentTree(rootSessionID: try container.decode(SessionID.self, forKey: .sessionID))
        case .getSubagentResult: self = .getSubagentResult(runID: try container.decode(AgentRunID.self, forKey: .runID))
        case .cancelAgentRun: self = .cancelAgentRun(runID: try container.decode(AgentRunID.self, forKey: .runID))
        case .listExtensions:
            self = .listExtensions(kind: try container.decodeIfPresent(ExtensionKind.self, forKey: .extensionKind))
        case .getWorkspaceDiff: self = .getWorkspaceDiff
        case .replyPermission:
            self = .replyPermission(try container.decode(PermissionReply.self, forKey: .permissionReply))
        case .replyQuestion:
            self = .replyQuestion(try container.decode(QuestionReply.self, forKey: .questionReply))
        case .sendMessage:
            self = .sendMessage(
                sessionID: try container.decode(SessionID.self, forKey: .sessionID),
                content: try container.decode(String.self, forKey: .content)
            )
        case .listProviderProducts: self = .listProviderProducts
        case .listProviderAccounts: self = .listProviderAccounts
        case .listProviderModels: self = .listProviderModels
        case .selectProviderModel: self = .selectProviderModel(model: try container.decode(String.self, forKey: .model))
        case .storeProviderCredential: self = .storeProviderCredential(try container.decode(ProviderCredentialWriteRequest.self, forKey: .providerCredential))
        case .createProviderAccount: self = .createProviderAccount(try container.decode(ProviderAccountCreateRequest.self, forKey: .providerAccount))
        case .deleteProviderAccount: self = .deleteProviderAccount(accountID: try container.decode(String.self, forKey: .accountID), deleteUnusedCredential: try container.decode(Bool.self, forKey: .deleteUnusedCredential))
        case .deleteProviderCredential: self = .deleteProviderCredential(try container.decode(CredentialRef.self, forKey: .credential))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        switch self {
        case let .getSession(sessionID):
            try container.encode(sessionID, forKey: .sessionID)
        case let .renameSession(sessionID, title):
            try container.encode(sessionID, forKey: .sessionID)
            try container.encodeIfPresent(title, forKey: .title)
        case let .getContext(sessionID), let .getPerformance(sessionID), let .compactSession(sessionID):
            try container.encode(sessionID, forKey: .sessionID)
        case let .getContextProjection(sessionID):
            try container.encode(sessionID, forKey: .sessionID)
        case let .listChildSessions(sessionID), let .listAgentRuns(sessionID), let .getAgentTree(sessionID):
            try container.encode(sessionID, forKey: .sessionID)
        case let .getAgentRun(runID), let .getSubagentResult(runID), let .cancelAgentRun(runID):
            try container.encode(runID, forKey: .runID)
        case let .sendMessage(sessionID, content):
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(content, forKey: .content)
        case let .selectProviderModel(model):
            try container.encode(model, forKey: .model)
        case let .listExtensions(kind):
            try container.encodeIfPresent(kind, forKey: .extensionKind)
        case let .replyPermission(reply):
            try container.encode(reply, forKey: .permissionReply)
        case let .replyQuestion(reply):
            try container.encode(reply, forKey: .questionReply)
        case let .setPermissionConfiguration(configuration):
            try container.encode(configuration, forKey: .permissionConfiguration)
        case let .storeProviderCredential(request): try container.encode(request, forKey: .providerCredential)
        case let .createProviderAccount(request): try container.encode(request, forKey: .providerAccount)
        case let .deleteProviderAccount(accountID, deleteUnusedCredential):
            try container.encode(accountID, forKey: .accountID)
            try container.encode(deleteUnusedCredential, forKey: .deleteUnusedCredential)
        case let .deleteProviderCredential(reference): try container.encode(reference, forKey: .credential)
        default:
            break
        }
    }
}

extension CoreResponse: Codable {
    private enum TypeKey: String, Codable {
        case pong, info, state, streamOpened, providerStatus, diagnostics, providerProducts, providerAccounts, providerModels, providerModelSelected, providerAccount, providerCredential, providerDisconnected, extensions, workspaceDiff
        case sessionCreated, sessionList, sessionDetail, sessionRenamed, permissionReplyAccepted, questionReplyAccepted, context, contextProjection, performance, permissionConfiguration, projectCache, compactSession, childSessionList, agentRunList, agentRun, agentTree, subagentResult, agentRunCancelled, error
    }

    private enum CodingKeys: String, CodingKey {
        case type, info, state, streamID, providerStatus, diagnostics, providerProducts, providerAccounts, providerModels, providerModelSelected, providerAccount, providerCredential, providerDisconnected, extensions, workspaceDiff, session, sessions, permissionID, questionID, context, contextProjection, performance, permissionConfiguration, projectCache, compactSession, agentRuns, agentRun, agentTree, subagentResult, runID, title, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(TypeKey.self, forKey: .type) {
        case .pong:
            self = .pong
        case .info:
            self = .info(try container.decode(CoreInfo.self, forKey: .info))
        case .state:
            self = .state(try container.decode(CoreState.self, forKey: .state))
        case .streamOpened:
            self = .streamOpened(try container.decode(StreamID.self, forKey: .streamID))
        case .providerStatus:
            self = .providerStatus(try container.decode(ProviderStatus.self, forKey: .providerStatus))
        case .diagnostics:
            self = .diagnostics(try container.decode(RuntimeDiagnosticsBundle.self, forKey: .diagnostics))
        case .providerProducts:
            self = .providerProducts(try container.decode([ProviderProductSummary].self, forKey: .providerProducts))
        case .providerAccounts:
            self = .providerAccounts(try container.decode([ProviderAccountInfo].self, forKey: .providerAccounts))
        case .providerModels:
            self = .providerModels(try container.decode([ProviderModelInfo].self, forKey: .providerModels))
        case .providerModelSelected:
            self = .providerModelSelected(try container.decode(ProviderStatus.self, forKey: .providerModelSelected))
        case .providerAccount:
            self = .providerAccount(try container.decode(ProviderAccountInfo.self, forKey: .providerAccount))
        case .providerCredential:
            self = .providerCredential(try container.decode(ProviderCredentialResult.self, forKey: .providerCredential))
        case .providerDisconnected:
            self = .providerDisconnected(try container.decode(ProviderDisconnectResult.self, forKey: .providerDisconnected))
        case .extensions:
            self = .extensions(try container.decode([ExtensionInfo].self, forKey: .extensions))
        case .workspaceDiff:
            self = .workspaceDiff(try container.decode(String.self, forKey: .workspaceDiff))
        case .sessionCreated:
            self = .sessionCreated(try container.decode(SessionInfo.self, forKey: .session))
        case .sessionList:
            self = .sessionList(try container.decode([SessionInfo].self, forKey: .sessions))
        case .sessionDetail:
            self = .sessionDetail(try container.decode(SessionSnapshot.self, forKey: .session))
        case .sessionRenamed:
            self = .sessionRenamed(try container.decode(SessionInfo.self, forKey: .session))
        case .permissionReplyAccepted:
            self = .permissionReplyAccepted(try container.decode(PermissionID.self, forKey: .permissionID))
        case .questionReplyAccepted:
            self = .questionReplyAccepted(try container.decode(QuestionID.self, forKey: .questionID))
        case .context:
            self = .context(try container.decodeIfPresent(ContextDebugSnapshot.self, forKey: .context))
        case .contextProjection:
            self = .contextProjection(try container.decodeIfPresent(ContextCacheProjection.self, forKey: .contextProjection))
        case .performance:
            self = .performance(try container.decodeIfPresent(TurnPerformanceReport.self, forKey: .performance))
        case .permissionConfiguration:
            self = .permissionConfiguration(try container.decode(PermissionConfiguration.self, forKey: .permissionConfiguration))
        case .projectCache:
            self = .projectCache(try container.decode(ProjectCacheDebugSnapshot.self, forKey: .projectCache))
        case .compactSession:
            self = .compactSession(try container.decode(CompactSessionResponse.self, forKey: .compactSession))
        case .childSessionList:
            self = .childSessionList(try container.decode([SessionInfo].self, forKey: .sessions))
        case .agentRunList:
            self = .agentRunList(try container.decode([AgentRunInfo].self, forKey: .agentRuns))
        case .agentRun:
            self = .agentRun(try container.decode(AgentRunInfo.self, forKey: .agentRun))
        case .agentTree:
            self = .agentTree(try container.decode(AgentTreeNode.self, forKey: .agentTree))
        case .subagentResult:
            self = .subagentResult(try container.decode(SubagentResult.self, forKey: .subagentResult))
        case .agentRunCancelled:
            self = .agentRunCancelled(try container.decode(AgentRunID.self, forKey: .runID))
        case .error:
            self = .error(try container.decode(CoreError.self, forKey: .error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kindKey, forKey: .type)
        switch self {
        case .pong:
            break
        case let .info(info):
            try container.encode(info, forKey: .info)
        case let .state(state):
            try container.encode(state, forKey: .state)
        case let .streamOpened(streamID):
            try container.encode(streamID, forKey: .streamID)
        case let .providerStatus(status):
            try container.encode(status, forKey: .providerStatus)
        case let .diagnostics(bundle):
            try container.encode(bundle, forKey: .diagnostics)
        case let .providerProducts(products): try container.encode(products, forKey: .providerProducts)
        case let .providerAccounts(accounts): try container.encode(accounts, forKey: .providerAccounts)
        case let .providerModelSelected(status): try container.encode(status, forKey: .providerModelSelected)
        case let .providerModels(models): try container.encode(models, forKey: .providerModels)
        case let .providerAccount(account): try container.encode(account, forKey: .providerAccount)
        case let .providerCredential(credential): try container.encode(credential, forKey: .providerCredential)
        case let .providerDisconnected(result): try container.encode(result, forKey: .providerDisconnected)
        case let .extensions(values): try container.encode(values, forKey: .extensions)
        case let .workspaceDiff(diff): try container.encode(diff, forKey: .workspaceDiff)
        case let .sessionCreated(info):
            try container.encode(info, forKey: .session)
        case let .sessionList(infos):
            try container.encode(infos, forKey: .sessions)
        case let .sessionDetail(snapshot):
            try container.encode(snapshot, forKey: .session)
        case let .sessionRenamed(info):
            try container.encode(info, forKey: .session)
        case let .permissionReplyAccepted(permissionID):
            try container.encode(permissionID, forKey: .permissionID)
        case let .questionReplyAccepted(questionID):
            try container.encode(questionID, forKey: .questionID)
        case let .context(snapshot):
            try container.encodeIfPresent(snapshot, forKey: .context)
        case let .contextProjection(projection):
            try container.encodeIfPresent(projection, forKey: .contextProjection)
        case let .performance(report):
            try container.encodeIfPresent(report, forKey: .performance)
        case let .permissionConfiguration(configuration):
            try container.encode(configuration, forKey: .permissionConfiguration)
        case let .projectCache(snapshot):
            try container.encode(snapshot, forKey: .projectCache)
        case let .compactSession(response):
            try container.encode(response, forKey: .compactSession)
        case let .childSessionList(sessions):
            try container.encode(sessions, forKey: .sessions)
        case let .agentRunList(runs):
            try container.encode(runs, forKey: .agentRuns)
        case let .agentRun(run):
            try container.encode(run, forKey: .agentRun)
        case let .agentTree(tree):
            try container.encode(tree, forKey: .agentTree)
        case let .subagentResult(result):
            try container.encode(result, forKey: .subagentResult)
        case let .agentRunCancelled(runID):
            try container.encode(runID, forKey: .runID)
        case let .error(error):
            try container.encode(error, forKey: .error)
        }
    }

    private var kindKey: TypeKey {
        switch self {
        case .pong: .pong
        case .info: .info
        case .state: .state
        case .streamOpened: .streamOpened
        case .providerStatus: .providerStatus
        case .diagnostics: .diagnostics
        case .providerProducts: .providerProducts
        case .providerAccounts: .providerAccounts
        case .providerModels: .providerModels
        case .providerModelSelected: .providerModelSelected
        case .providerAccount: .providerAccount
        case .providerCredential: .providerCredential
        case .providerDisconnected: .providerDisconnected
        case .extensions: .extensions
        case .workspaceDiff: .workspaceDiff
        case .sessionCreated: .sessionCreated
        case .sessionList: .sessionList
        case .sessionDetail: .sessionDetail
        case .sessionRenamed: .sessionRenamed
        case .permissionReplyAccepted: .permissionReplyAccepted
        case .questionReplyAccepted: .questionReplyAccepted
        case .context: .context
        case .contextProjection: .contextProjection
        case .performance: .performance
        case .permissionConfiguration: .permissionConfiguration
        case .projectCache: .projectCache
        case .compactSession: .compactSession
        case .childSessionList: .childSessionList
        case .agentRunList: .agentRunList
        case .agentRun: .agentRun
        case .agentTree: .agentTree
        case .subagentResult: .subagentResult
        case .agentRunCancelled: .agentRunCancelled
        case .error: .error
        }
    }
}

extension CoreError: Codable {
    private enum CodingKeys: String, CodingKey {
        case code, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = Code(rawValue: try container.decode(String.self, forKey: .code)) ?? .transport
        message = try container.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code.rawValue, forKey: .code)
        try container.encode(message, forKey: .message)
    }
}

extension CoreEvent: Codable {
    private enum TypeKey: String, Codable {
        case stateChanged, sessionCreated, turnStarted, turnCompleted, turnFailed
        case toolCallCompleted, toolResult, permissionAsked, questionAsked, childSessionCreated, subagentSpawned, agentRunQueued, agentRunStarted, agentRunStatusChanged, agentRunCompleted, agentRunFailed, agentRunCancelled, subagentResultAvailable, questionEscalated
    }

    private enum CodingKeys: String, CodingKey {
        case type, state, sessionID, handle, result, failure, toolCall, toolResult, permissionRequest, questionRequest, session, agentRun, subagentResult
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(TypeKey.self, forKey: .type) {
        case .stateChanged:
            self = .stateChanged(try container.decode(CoreState.self, forKey: .state))
        case .sessionCreated:
            self = .sessionCreated(try container.decode(SessionID.self, forKey: .sessionID))
        case .turnStarted:
            self = .turnStarted(try container.decode(TurnHandle.self, forKey: .handle))
        case .turnCompleted:
            self = .turnCompleted(try container.decode(TurnResult.self, forKey: .result))
        case .turnFailed:
            self = .turnFailed(try container.decode(TurnFailure.self, forKey: .failure))
        case .toolCallCompleted:
            self = .toolCallCompleted(try container.decode(ToolCall.self, forKey: .toolCall))
        case .toolResult:
            self = .toolResult(try container.decode(ToolResult.self, forKey: .toolResult))
        case .permissionAsked:
            self = .permissionAsked(try container.decode(PermissionRequest.self, forKey: .permissionRequest))
        case .questionAsked:
            self = .questionAsked(try container.decode(QuestionRequest.self, forKey: .questionRequest))
        case .childSessionCreated:
            self = .childSessionCreated(try container.decode(SessionInfo.self, forKey: .session))
        case .subagentSpawned:
            self = .subagentSpawned(try container.decode(AgentRunInfo.self, forKey: .agentRun))
        case .agentRunQueued:
            self = .agentRunQueued(try container.decode(AgentRunInfo.self, forKey: .agentRun))
        case .agentRunStarted:
            self = .agentRunStarted(try container.decode(AgentRunInfo.self, forKey: .agentRun))
        case .agentRunStatusChanged:
            self = .agentRunStatusChanged(try container.decode(AgentRunInfo.self, forKey: .agentRun))
        case .agentRunCompleted:
            self = .agentRunCompleted(try container.decode(AgentRunInfo.self, forKey: .agentRun))
        case .agentRunFailed:
            self = .agentRunFailed(try container.decode(AgentRunInfo.self, forKey: .agentRun))
        case .agentRunCancelled:
            self = .agentRunCancelled(try container.decode(AgentRunInfo.self, forKey: .agentRun))
        case .subagentResultAvailable:
            self = .subagentResultAvailable(try container.decode(SubagentResult.self, forKey: .subagentResult))
        case .questionEscalated:
            self = .questionEscalated(try container.decode(QuestionRequest.self, forKey: .questionRequest))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .stateChanged(state):
            try container.encode(TypeKey.stateChanged, forKey: .type)
            try container.encode(state, forKey: .state)
        case let .sessionCreated(sessionID):
            try container.encode(TypeKey.sessionCreated, forKey: .type)
            try container.encode(sessionID, forKey: .sessionID)
        case let .turnStarted(handle):
            try container.encode(TypeKey.turnStarted, forKey: .type)
            try container.encode(handle, forKey: .handle)
        case let .turnCompleted(result):
            try container.encode(TypeKey.turnCompleted, forKey: .type)
            try container.encode(result, forKey: .result)
        case let .turnFailed(failure):
            try container.encode(TypeKey.turnFailed, forKey: .type)
            try container.encode(failure, forKey: .failure)
        case let .toolCallCompleted(call):
            try container.encode(TypeKey.toolCallCompleted, forKey: .type)
            try container.encode(call, forKey: .toolCall)
        case let .toolResult(result):
            try container.encode(TypeKey.toolResult, forKey: .type)
            try container.encode(result, forKey: .toolResult)
        case let .permissionAsked(request):
            try container.encode(TypeKey.permissionAsked, forKey: .type)
            try container.encode(request, forKey: .permissionRequest)
        case let .questionAsked(request):
            try container.encode(TypeKey.questionAsked, forKey: .type)
            try container.encode(request, forKey: .questionRequest)
        case let .childSessionCreated(session):
            try container.encode(TypeKey.childSessionCreated, forKey: .type)
            try container.encode(session, forKey: .session)
        case let .subagentSpawned(run):
            try container.encode(TypeKey.subagentSpawned, forKey: .type)
            try container.encode(run, forKey: .agentRun)
        case let .agentRunQueued(run):
            try container.encode(TypeKey.agentRunQueued, forKey: .type)
            try container.encode(run, forKey: .agentRun)
        case let .agentRunStarted(run):
            try container.encode(TypeKey.agentRunStarted, forKey: .type)
            try container.encode(run, forKey: .agentRun)
        case let .agentRunStatusChanged(run):
            try container.encode(TypeKey.agentRunStatusChanged, forKey: .type)
            try container.encode(run, forKey: .agentRun)
        case let .agentRunCompleted(run):
            try container.encode(TypeKey.agentRunCompleted, forKey: .type)
            try container.encode(run, forKey: .agentRun)
        case let .agentRunFailed(run):
            try container.encode(TypeKey.agentRunFailed, forKey: .type)
            try container.encode(run, forKey: .agentRun)
        case let .agentRunCancelled(run):
            try container.encode(TypeKey.agentRunCancelled, forKey: .type)
            try container.encode(run, forKey: .agentRun)
        case let .subagentResultAvailable(result):
            try container.encode(TypeKey.subagentResultAvailable, forKey: .type)
            try container.encode(result, forKey: .subagentResult)
        case let .questionEscalated(request):
            try container.encode(TypeKey.questionEscalated, forKey: .type)
            try container.encode(request, forKey: .questionRequest)
        }
    }
}
