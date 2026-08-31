/// 客户端发给 Core 的控制面命令。
public enum ClientCommand: Sendable, Equatable {
    case ping
    case getInfo
    case getState
    case openTestStream
    case createSession
    case listSessions
    case getSession(sessionID: SessionID)
    case getProviderStatus
    case replyPermission(PermissionReply)
    case replyQuestion(QuestionReply)
    case getContext(sessionID: SessionID)
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
    /// 数据面命令：在 Session 中发起一轮对话。
    case sendMessage(sessionID: SessionID, content: String)
    case listProviderProducts
    case listProviderAccounts
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
        case getProviderStatus
        case replyPermission
        case replyQuestion
        case getContext
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
        case sendMessage
        case listProviderProducts, listProviderAccounts, storeProviderCredential, createProviderAccount, deleteProviderAccount, deleteProviderCredential
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
        case .getProviderStatus: .getProviderStatus
        case .replyPermission: .replyPermission
        case .replyQuestion: .replyQuestion
        case .getContext: .getContext
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
        case .sendMessage: .sendMessage
        case .listProviderProducts: .listProviderProducts
        case .listProviderAccounts: .listProviderAccounts
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
