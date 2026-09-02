/// 客户端发给 Core 的控制面命令。
public enum ClientCommand: Sendable, Equatable {
    case ping
    case getInfo
    case getState
    case openTestStream
    case createSession
    case listSessions
    case getSession(sessionID: SessionID)
    case renameSession(sessionID: SessionID, title: String?)
    case getProviderStatus
    case getDiagnostics
    case replyPermission(PermissionReply)
    case replyQuestion(QuestionReply)
    case getContext(sessionID: SessionID)
    case getContextProjection(sessionID: SessionID)
    case getPerformance(sessionID: SessionID)
    case getPermissionConfiguration
    case setPermissionConfiguration(PermissionConfiguration)
    case getProjectCache
    case compactSession(sessionID: SessionID)
    case listChildSessions(parentSessionID: SessionID)
    case listAgentRuns(sessionID: SessionID)
    case getAgentRun(runID: AgentRunID)
    case getAgentTree(rootSessionID: SessionID)
    case getSubagentResult(runID: AgentRunID)
    case cancelAgentRun(runID: AgentRunID)
    case listExtensions(kind: ExtensionKind?)
    case getWorkspaceDiff
    /// 数据面命令：在 Session 中发起一轮对话。
    case sendMessage(sessionID: SessionID, content: String)
    case listProviderProducts
    case listProviderAccounts
    case listProviderModels
    case selectProviderModel(model: String)
    case storeProviderCredential(ProviderCredentialWriteRequest)
    case createProviderAccount(ProviderAccountCreateRequest)
    case deleteProviderAccount(accountID: String, deleteUnusedCredential: Bool)
    case deleteProviderCredential(CredentialRef)
}

extension ClientCommand {
    /// 命令种类，用于控制面路由与 wire 编码。
    public enum Kind: String, Codable, Sendable {
        case ping
        case getInfo
        case getState
        case openTestStream
        case createSession
        case listSessions
        case getSession
        case renameSession
        case getProviderStatus
        case getDiagnostics
        case replyPermission
        case replyQuestion
        case getContext
        case getContextProjection
        case getPerformance
        case getPermissionConfiguration
        case setPermissionConfiguration
        case getProjectCache
        case compactSession
        case listChildSessions
        case listAgentRuns
        case getAgentRun
        case getAgentTree
        case getSubagentResult
        case cancelAgentRun
        case listExtensions
        case getWorkspaceDiff
        case sendMessage
        case listProviderProducts, listProviderAccounts, listProviderModels, selectProviderModel, storeProviderCredential, createProviderAccount, deleteProviderAccount, deleteProviderCredential
    }

    public var kind: Kind {
        switch self {
        case .ping: .ping
        case .getInfo: .getInfo
        case .getState: .getState
        case .openTestStream: .openTestStream
        case .createSession: .createSession
        case .listSessions: .listSessions
        case .getSession: .getSession
        case .renameSession: .renameSession
        case .getProviderStatus: .getProviderStatus
        case .getDiagnostics: .getDiagnostics
        case .replyPermission: .replyPermission
        case .replyQuestion: .replyQuestion
        case .getContext: .getContext
        case .getContextProjection: .getContextProjection
        case .getPerformance: .getPerformance
        case .getPermissionConfiguration: .getPermissionConfiguration
        case .setPermissionConfiguration: .setPermissionConfiguration
        case .getProjectCache: .getProjectCache
        case .compactSession: .compactSession
        case .listChildSessions: .listChildSessions
        case .listAgentRuns: .listAgentRuns
        case .getAgentRun: .getAgentRun
        case .getAgentTree: .getAgentTree
        case .getSubagentResult: .getSubagentResult
        case .cancelAgentRun: .cancelAgentRun
        case .listExtensions: .listExtensions
        case .getWorkspaceDiff: .getWorkspaceDiff
        case .sendMessage: .sendMessage
        case .listProviderProducts: .listProviderProducts
        case .listProviderAccounts: .listProviderAccounts
        case .listProviderModels: .listProviderModels
        case .selectProviderModel: .selectProviderModel
        case .storeProviderCredential: .storeProviderCredential
        case .createProviderAccount: .createProviderAccount
        case .deleteProviderAccount: .deleteProviderAccount
        case .deleteProviderCredential: .deleteProviderCredential
        }
    }

    /// 数据面命令：由连接层路由到 Streaming DMA 通路，而非控制面。
    public var isDataPlane: Bool {
        switch self {
        case .openTestStream, .sendMessage: true
        default: false
        }
    }
}
