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
    /// Stop means "leave nothing queued behind this run". Terminalizing a running Run advances the
    /// session queue, and a promoted Turn is already running and can no longer be cancelled by
    /// `turn.cancel`; the caller that wants a full stop has to say so here so Core drains the queue
    /// first. Absent means false, so an older peer keeps the per-run cancel behaviour.
    public let cancelQueuedTurns: Bool?

    public init(sessionID: SessionID, runID: RunID, reason: String? = nil, cancelQueuedTurns: Bool? = nil) {
        self.sessionID = sessionID
        self.runID = runID
        self.reason = reason
        self.cancelQueuedTurns = cancelQueuedTurns
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

/// Branches a session: a new session in the same workspace that starts with a copy of the
/// source's full history. The source is untouched; a session with a run in flight is refused,
/// because a copy taken mid-run would carry half a turn.
public struct ForkSessionRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let title: String?

    public init(sessionID: SessionID, title: String? = nil) {
        self.sessionID = sessionID
        self.title = title
    }
}

/// Asks Core to get a local file ready for a later turn, the moment the user picks it.
public struct PrepareAttachmentRequest: Codable, Sendable, Equatable {
    public let path: String
    /// When the user picked the file, for the latency trace.
    public let selectedAt: Date?
    /// Also upload it to the active provider when that provider has a Files API.
    public let upload: Bool

    public init(path: String, selectedAt: Date? = nil, upload: Bool = false) {
        self.path = path
        self.selectedAt = selectedAt
        self.upload = upload
    }
}

/// Where a picked file stands. A turn refers to the file by path; this only reports progress.
public struct AttachmentPreparation: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case preprocessing, uploading, ready, failed }

    public let path: String
    public let filename: String
    public let state: State
    public let sha256: String?
    public let mediaType: String?
    public let originalBytes: Int
    /// Size actually sent inline for an image; nil for a file sent by path only.
    public let preparedBytes: Int?
    /// The active provider already holds the file; a send will reference it, not re-upload it.
    public let providerFileReady: Bool
    /// The active provider has a Files API, so an upload ahead of the send is worth doing.
    public let providerSupportsFiles: Bool
    public let fromCache: Bool
    public let preprocessMilliseconds: Int?
    public let detail: String?

    public init(path: String, filename: String, state: State, sha256: String?, mediaType: String?,
                originalBytes: Int, preparedBytes: Int?, providerFileReady: Bool, providerSupportsFiles: Bool,
                fromCache: Bool, preprocessMilliseconds: Int?, detail: String?) {
        self.path = path
        self.filename = filename
        self.state = state
        self.sha256 = sha256
        self.mediaType = mediaType
        self.originalBytes = originalBytes
        self.preparedBytes = preparedBytes
        self.providerFileReady = providerFileReady
        self.providerSupportsFiles = providerSupportsFiles
        self.fromCache = fromCache
        self.preprocessMilliseconds = preprocessMilliseconds
        self.detail = detail
    }
}

/// Session-lifetime goal anchor. Volatile by design: never persisted, cleared with the session.
public struct SetSessionGoalRequest: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let goal: String?
    /// Non-nil pauses or resumes the existing goal and leaves its text alone; `goal` is then
    /// ignored. Nil (and absent on the wire) keeps the original meaning: set, edit or clear.
    public let paused: Bool?

    public init(sessionID: SessionID, goal: String?, paused: Bool? = nil) {
        self.sessionID = sessionID
        self.goal = goal
        self.paused = paused
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
    /// Git 真值由 Core 计算并投影，前端不允许自己 shell 一次。
    /// nil 一律表示「未知」，不表示「没有」；只有 isGitRepository 为 true 时才可能非 nil。
    public var gitBranch: String?
    /// 工作树顶层（`git rev-parse --show-toplevel`），可能与 workspace root 不同。
    public var worktreeRoot: String?
    /// `.git` 是文件而非目录：当前 checkout 是一个 linked worktree。
    public var isLinkedWorktree: Bool
    /// [Deprecated] 兼容周期内等于 `dirtyPathCount`，两者不得具有不同用户语义（契约第二十二节）。
    /// GUI 从本轮起只读 `dirtyPathCount`。
    public var changedFileCount: Int?
    public var isDirty: Bool?
    /// 存在 Git 工作区变化的唯一文件路径数：tracked 变更 + 未跟踪文件 + 冲突，含 staged 与 unstaged 去重，不含 ignored。
    public var dirtyPathCount: Int?
    /// porcelain records 解析出的 tracked 变更路径数。
    public var trackedChangeCount: Int?
    /// `-uall` 展开后的未跟踪文件数，不是目录数。
    public var untrackedFileCount: Int?
    public var conflictedFileCount: Int?

    public init(
        rootPath: String,
        isGitRepository: Bool,
        codebaseNodes: Int? = nil,
        codebaseEdges: Int? = nil,
        indexingState: String? = nil,
        gitBranch: String? = nil,
        worktreeRoot: String? = nil,
        isLinkedWorktree: Bool = false,
        changedFileCount: Int? = nil,
        isDirty: Bool? = nil,
        dirtyPathCount: Int? = nil,
        trackedChangeCount: Int? = nil,
        untrackedFileCount: Int? = nil,
        conflictedFileCount: Int? = nil
    ) {
        self.rootPath = rootPath
        self.isGitRepository = isGitRepository
        self.codebaseNodes = codebaseNodes
        self.codebaseEdges = codebaseEdges
        self.indexingState = indexingState
        self.gitBranch = gitBranch
        self.worktreeRoot = worktreeRoot
        self.isLinkedWorktree = isLinkedWorktree
        self.changedFileCount = changedFileCount
        self.isDirty = isDirty
        self.dirtyPathCount = dirtyPathCount
        self.trackedChangeCount = trackedChangeCount
        self.untrackedFileCount = untrackedFileCount
        self.conflictedFileCount = conflictedFileCount
    }
}

/// Git RPC 的结构化读参数。契约第十四节：RPC 只接受结构化参数，
/// 由 Core handler 转成现有 `GitAction` argv；不存在 `git.exec(rawArguments)`，
/// 也不接受 `-C` / `--git-dir` / `--work-tree`。
public struct GitQueryRequest: Codable, Sendable, Equatable {
    public var paths: [String]
    public var reference: String?
    public var limit: Int?
    /// 工作区内相对目录；只在仓库内部生效。
    public var workingDirectory: String?

    public init(paths: [String] = [], reference: String? = nil, limit: Int? = nil, workingDirectory: String? = nil) {
        self.paths = paths
        self.reference = reference
        self.limit = limit
        self.workingDirectory = workingDirectory
    }
}

/// Git RPC 的结构化写参数，并携带契约第十六节要求的调用身份。
public struct GitMutationRequest: Codable, Sendable, Equatable {
    /// 发起方 Session。Agent 发起时是真实 Session；GUI 发起时是当前 GUI Session（可为 nil）。
    public var sessionID: SessionID?
    /// Agent 发起时是真实 Tool Call ID；GUI 主动点击必须使用 `"gui:" + UUID`，不得复用 Agent 的 ID。
    public var toolCallID: String
    public var paths: [String]
    public var reference: String?
    public var branch: String?
    public var message: String?
    /// 远程同步目标。fetch/pull 缺省退回当前 upstream 的 remote（再退回 origin）；
    /// push 不退回 —— 没有 upstream 时必须显式给出 remote 与 branch（契约第四节）。
    public var remote: String?
    /// `fetch --prune`：只由结构化开关控制。
    public var prune: Bool
    /// `push -u`：建立 upstream。第一版 push 只有安全形态。
    public var setUpstream: Bool
    /// `switch -c` / `checkout -b` / `branch -d -f` 之类的显式变体，仍然是结构化开关而非裸 flag。
    public var createBranch: Bool
    /// 高风险覆盖（restore 丢弃、checkout/switch 覆盖、branch 强删）。GUI 需额外确认。
    public var force: Bool
    /// 只撤销暂存区（`restore --staged`），不丢弃工作区内容。
    public var stagedOnly: Bool
    /// `add -A`：暂存整个工作区。
    public var all: Bool
    public var workingDirectory: String?

    public init(
        sessionID: SessionID? = nil,
        toolCallID: String,
        paths: [String] = [],
        reference: String? = nil,
        branch: String? = nil,
        message: String? = nil,
        remote: String? = nil,
        prune: Bool = false,
        setUpstream: Bool = false,
        createBranch: Bool = false,
        force: Bool = false,
        stagedOnly: Bool = false,
        all: Bool = false,
        workingDirectory: String? = nil
    ) {
        self.sessionID = sessionID
        self.toolCallID = toolCallID
        self.paths = paths
        self.reference = reference
        self.branch = branch
        self.message = message
        self.remote = remote
        self.prune = prune
        self.setUpstream = setUpstream
        self.createBranch = createBranch
        self.force = force
        self.stagedOnly = stagedOnly
        self.all = all
        self.workingDirectory = workingDirectory
    }
}

/// diff 的比较范围。三个都是 git 的原生范围概念，不是 shell 参数形状。
/// 定义在协议层：Core 的 argv 构造与前端请求共用同一个枚举，不允许两边各写一份。
public enum GitDiffScope: String, Codable, Sendable, Equatable, CaseIterable {
    /// 工作区 vs 索引（未暂存改动）。
    case worktree
    /// 索引 vs HEAD（已暂存改动）。
    case staged
    /// 工作区+索引 vs HEAD（全部未提交改动）。
    case head

    /// 未跟踪文件属于工作区状态，因此只有工作区口径的 diff 才带它们；已暂存口径不带。
    public var includesUntrackedFiles: Bool { self != .staged }
}

/// 单个文件的 Git 状态与行变化。
///
/// status 与 diff 共用这一个形状：契约第九节要求行数由 `git.diff` 的结构化响应给出，
/// 不再另开一个按 shell 命令形状暴露的 `git.numstat`。
public struct GitFileChange: Codable, Sendable, Equatable {
    public var path: String
    /// 重命名/复制时的原路径。
    public var oldPath: String?
    /// 索引位（porcelain v2 的 X）；未跟踪为 "?"。
    public var indexStatus: String
    /// 工作区位（porcelain v2 的 Y）。
    public var worktreeStatus: String
    public var isUntracked: Bool
    public var isConflicted: Bool
    /// name-status 的状态字母：M/A/D/R/C/T/U/?。
    public var status: String?
    /// --numstat 的行数；二进制为 nil（binary == true）。
    public var additions: Int?
    public var deletions: Int?
    public var binary: Bool

    public init(
        path: String,
        oldPath: String? = nil,
        indexStatus: String = " ",
        worktreeStatus: String = " ",
        isUntracked: Bool = false,
        isConflicted: Bool = false,
        status: String? = nil,
        additions: Int? = nil,
        deletions: Int? = nil,
        binary: Bool = false
    ) {
        self.path = path
        self.oldPath = oldPath
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
        self.isUntracked = isUntracked
        self.isConflicted = isConflicted
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.binary = binary
    }
}

/// 远程同步的结构化参数（契约第二至四节）。仍然没有裸 argv：
/// 只有 remote / branch / prune / setUpstream 四个可控开关，禁止 force、refspec、镜像与全量 tag 推送。
public struct GitRemoteRequest: Codable, Sendable, Equatable {
    public var sessionID: SessionID?
    /// Agent 发起时为真实 Tool Call ID；GUI 点击使用 `"gui:" + UUID`。
    public var toolCallID: String
    public var remote: String?
    public var branch: String?
    public var reference: String?
    public var prune: Bool
    public var setUpstream: Bool
    public var workingDirectory: String?

    public init(
        sessionID: SessionID? = nil,
        toolCallID: String,
        remote: String? = nil,
        branch: String? = nil,
        reference: String? = nil,
        prune: Bool = false,
        setUpstream: Bool = false,
        workingDirectory: String? = nil
    ) {
        self.sessionID = sessionID
        self.toolCallID = toolCallID
        self.remote = remote
        self.branch = branch
        self.reference = reference
        self.prune = prune
        self.setUpstream = setUpstream
        self.workingDirectory = workingDirectory
    }
}

/// `git.status` 的返回值：计数一律来自 Core 解析后的 porcelain records（契约第二十二节），
/// 分支/upstream/ahead-behind 同一次调用给出，前端不再自己跑 git（契约第八节）。
public struct GitStatusResult: Codable, Sendable, Equatable {
    public var branchName: String?
    /// HEAD 的 commit SHA；未born 仓库为 "(unborn)" 原文或 nil。
    public var headSHA: String?
    public var upstreamRemote: String?
    public var upstreamBranch: String?
    /// 领先 upstream 的提交数；无 upstream 为 nil，不表示 0。
    public var ahead: Int?
    public var behind: Int?
    public var dirtyPathCount: Int
    public var trackedChangeCount: Int
    public var untrackedFileCount: Int
    public var conflictedFileCount: Int
    public var isDirty: Bool
    /// 逐文件明细：路径 + 索引位 + 工作区位 + 未跟踪/冲突标记。
    public var files: [GitFileChange]
    /// main checkout root，由 `--git-common-dir` 推导（契约第十九节）。
    public var mainCheckoutRoot: String?

    public init(
        branchName: String? = nil,
        headSHA: String? = nil,
        upstreamRemote: String? = nil,
        upstreamBranch: String? = nil,
        ahead: Int? = nil,
        behind: Int? = nil,
        dirtyPathCount: Int = 0,
        trackedChangeCount: Int = 0,
        untrackedFileCount: Int = 0,
        conflictedFileCount: Int = 0,
        isDirty: Bool = false,
        files: [GitFileChange] = [],
        mainCheckoutRoot: String? = nil
    ) {
        self.branchName = branchName
        self.headSHA = headSHA
        self.upstreamRemote = upstreamRemote
        self.upstreamBranch = upstreamBranch
        self.ahead = ahead
        self.behind = behind
        self.dirtyPathCount = dirtyPathCount
        self.trackedChangeCount = trackedChangeCount
        self.untrackedFileCount = untrackedFileCount
        self.conflictedFileCount = conflictedFileCount
        self.isDirty = isDirty
        self.files = files
        self.mainCheckoutRoot = mainCheckoutRoot
    }
}

/// `git.diff` 的请求。范围与输出形态都是结构化字段。
public struct GitDiffRequest: Codable, Sendable, Equatable {
    public var paths: [String]
    public var scope: GitDiffScope
    /// 比较基点（`<base>...HEAD`）。给定时 scope 不再参与范围选择。
    public var baseReference: String?
    /// 单个提交的改动（`<commit>^!`）。
    public var commitReference: String?
    public var includePatch: Bool
    public var includeFileStats: Bool
    /// patch 上下文行数；nil 用 Core 默认。
    public var contextLines: Int?
    public var workingDirectory: String?

    public init(
        paths: [String] = [],
        scope: GitDiffScope = .worktree,
        baseReference: String? = nil,
        commitReference: String? = nil,
        includePatch: Bool = true,
        includeFileStats: Bool = true,
        contextLines: Int? = nil,
        workingDirectory: String? = nil
    ) {
        self.paths = paths
        self.scope = scope
        self.baseReference = baseReference
        self.commitReference = commitReference
        self.includePatch = includePatch
        self.includeFileStats = includeFileStats
        self.contextLines = contextLines
        self.workingDirectory = workingDirectory
    }
}

/// `git.diff` 的返回值。只要统计时可以不要 patch。
public struct GitDiffResult: Codable, Sendable, Equatable {
    public var patch: String?
    public var files: [GitFileChange]
    /// Core 为本次结果实际执行的 argv 前缀，供 Debug / Inspector 核对。
    public var argv: [String]

    public init(patch: String? = nil, files: [GitFileChange] = [], argv: [String] = []) {
        self.patch = patch
        self.files = files
        self.argv = argv
    }
}

/// 文本型 Git 读结果（diff / log / show / branch 共用一个形状，不各造一个类型）。
public struct GitTextResult: Codable, Sendable, Equatable {
    public var text: String
    /// Core 实际执行的 argv，供 Debug / Inspector 核对参数是否被结构化转换正确。
    public var argv: [String]

    public init(text: String, argv: [String] = []) {
        self.text = text
        self.argv = argv
    }
}

/// Git 写操作结果。写操作都是 command，因此随 `CommandReceipt` 返回。
public struct GitMutationResult: Codable, Sendable, Equatable {
    public var action: String
    public var output: String
    public var risk: String
    /// mutation coordinator 的修订号：证明这次写确实经过了统一串行化路径。
    public var mutationRevision: UInt64

    public init(action: String, output: String, risk: String, mutationRevision: UInt64 = 0) {
        self.action = action
        self.output = output
        self.risk = risk
        self.mutationRevision = mutationRevision
    }
}

public struct WorkspaceDiffSummary: Codable, Sendable, Equatable {
    public let diff: String
    /// 与 `diff` 同一口径（`git diff`，未暂存）的行数统计，由 Core 用 `--numstat` 算出。
    /// 前端不得再从 diff 文本里自己数 `+`/`-`。
    public var addedLines: Int?
    public var deletedLines: Int?
    public var changedFiles: Int?

    public init(diff: String, addedLines: Int? = nil, deletedLines: Int? = nil, changedFiles: Int? = nil) {
        self.diff = diff
        self.addedLines = addedLines
        self.deletedLines = deletedLines
        self.changedFiles = changedFiles
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
    func forkSession(envelope: CommandEnvelope<ForkSessionRequest>) async throws -> CommandReceipt<SessionSummary>
    func prepareAttachment(envelope: CommandEnvelope<PrepareAttachmentRequest>) async throws -> CommandReceipt<AttachmentPreparation>
    func setSessionGoal(envelope: CommandEnvelope<SetSessionGoalRequest>) async throws -> CommandReceipt<SessionSummary>
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
    func getWorkspaceDiffSummary(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<WorkspaceDiffSummary>

    // MARK: - 10b. Git RPC（契约第十四至十七节）
    //
    // 这 10 个方法都是必选项，不给默认实现：默认实现会让 InProcess 编译通过却在其它 transport 上
    // 静默绕过 transport 层，正是契约第十八节点名的缺口。
    func gitStatus(envelope: QueryEnvelope<GitQueryRequest>) async throws -> ResponseEnvelope<GitStatusResult>
    func gitDiff(envelope: QueryEnvelope<GitDiffRequest>) async throws -> ResponseEnvelope<GitDiffResult>
    func gitLog(envelope: QueryEnvelope<GitQueryRequest>) async throws -> ResponseEnvelope<GitTextResult>
    func gitShow(envelope: QueryEnvelope<GitQueryRequest>) async throws -> ResponseEnvelope<GitTextResult>
    func gitBranch(envelope: QueryEnvelope<GitQueryRequest>) async throws -> ResponseEnvelope<GitTextResult>
    func gitAdd(envelope: CommandEnvelope<GitMutationRequest>) async throws -> CommandReceipt<GitMutationResult>
    func gitRestore(envelope: CommandEnvelope<GitMutationRequest>) async throws -> CommandReceipt<GitMutationResult>
    func gitCheckout(envelope: CommandEnvelope<GitMutationRequest>) async throws -> CommandReceipt<GitMutationResult>
    func gitSwitch(envelope: CommandEnvelope<GitMutationRequest>) async throws -> CommandReceipt<GitMutationResult>
    func gitCommit(envelope: CommandEnvelope<GitMutationRequest>) async throws -> CommandReceipt<GitMutationResult>
    func gitFetch(envelope: CommandEnvelope<GitRemoteRequest>) async throws -> CommandReceipt<GitMutationResult>
    func gitPull(envelope: CommandEnvelope<GitRemoteRequest>) async throws -> CommandReceipt<GitMutationResult>
    func gitPush(envelope: CommandEnvelope<GitRemoteRequest>) async throws -> CommandReceipt<GitMutationResult>
    func getLanguageServiceStatuses(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[LanguageServiceStatus]>

    /// What Core really knows about named tools: whether they are registered,
    /// whether the model must load them first, and whether their backend is
    /// reachable here.
    func getToolStatus(envelope: QueryEnvelope<GetToolStatusRequest>) async throws -> ResponseEnvelope<[ToolStatusEntry]>

    // MARK: - 10b. Agent Browser Session (read-only projection)
    func getBrowserSessions(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[BrowserSessionStatus]>
    func getBrowserCapture(envelope: QueryEnvelope<GetBrowserCaptureRequest>) async throws -> ResponseEnvelope<BrowserCapture>

    // MARK: - 10c. Terminal Sessions (Agent processes and user shells)
    func listTerminalSessions(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[TerminalSessionInfo]>
    func spawnTerminalSession(envelope: CommandEnvelope<SpawnTerminalSessionRequest>) async throws -> CommandReceipt<TerminalSessionInfo>
    func readTerminalSession(envelope: QueryEnvelope<ReadTerminalSessionRequest>) async throws -> ResponseEnvelope<TerminalSessionOutput>
    func writeTerminalSession(envelope: CommandEnvelope<WriteTerminalSessionRequest>) async throws -> CommandReceipt<VoidResult>
    func interruptTerminalSession(envelope: CommandEnvelope<InterruptTerminalSessionRequest>) async throws -> CommandReceipt<VoidResult>
    func closeTerminalSession(envelope: CommandEnvelope<CloseTerminalSessionRequest>) async throws -> CommandReceipt<VoidResult>

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

    // MARK: - 17. Configuration editing (providers.json / mcp.json)
    func getProviderConfiguration(envelope: QueryEnvelope<GetProviderConfigurationRequest>) async throws -> ResponseEnvelope<ProviderConfigurationDetail>
    func saveProviderConfiguration(envelope: CommandEnvelope<SaveProviderConfigurationRequest>) async throws -> CommandReceipt<ProviderConfigurationDetail>
    func deleteProviderConfiguration(envelope: CommandEnvelope<DeleteProviderConfigurationRequest>) async throws -> CommandReceipt<VoidResult>
    func testProviderDraft(envelope: CommandEnvelope<TestProviderDraftRequest>) async throws -> CommandReceipt<TestProviderResult>

    // MARK: - Provider sign-in (OAuth)
    func listProviderAuthProducts(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[ProviderAuthProduct]>

    func beginProviderAuth(envelope: CommandEnvelope<BeginProviderAuthRequest>) async throws -> CommandReceipt<ProviderAuthFlow>
    func getProviderAuthFlow(envelope: QueryEnvelope<GetProviderAuthFlowRequest>) async throws -> ResponseEnvelope<ProviderAuthFlow>
    func cancelProviderAuth(envelope: CommandEnvelope<CancelProviderAuthRequest>) async throws -> CommandReceipt<VoidResult>

    // MARK: - Provider catalog & connect

    /// Every provider Core knows about: curated registry plus the published
    /// models.lingxifox.cn index.
    func getProviderCatalog(envelope: QueryEnvelope<GetProviderCatalogRequest>) async throws -> ResponseEnvelope<[ProviderCatalogEntry]>
    func getProviderCatalogModels(envelope: QueryEnvelope<GetProviderCatalogModelsRequest>) async throws -> ResponseEnvelope<ProviderModelRoster>
    func probeProviderModels(envelope: CommandEnvelope<ProbeProviderModelsRequest>) async throws -> CommandReceipt<[String: ModelAvailability]>
    func getProviderModelAvailability(envelope: QueryEnvelope<GetProviderModelAvailabilityRequest>) async throws -> ResponseEnvelope<[String: ModelAvailability]>
    /// Models an account can reach but that are not offered for selection, keyed by product: upstream
    /// marked them `hide`/`disabled`, or the registry has them as deprecated/retired. A page that shows
    /// five models when the account reported seven is read as a broken integration unless it says so.
    func getWithheldModels(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[String: [String]]>

    /// Connects a catalog entry using the credential or endpoint its contract asks for.
    func connectProvider(envelope: CommandEnvelope<ConnectProviderRequest>) async throws -> CommandReceipt<ProviderAccountInfo>

    func listMCPServerConfigurations(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[MCPServerConfigurationDetail]>
    func saveMCPServerConfiguration(envelope: CommandEnvelope<SaveMCPServerRequest>) async throws -> CommandReceipt<MCPServerConfigurationDetail>
    func deleteMCPServerConfiguration(envelope: CommandEnvelope<DeleteMCPServerRequest>) async throws -> CommandReceipt<VoidResult>

    // MARK: - 16. Agent Preset & Side Question
    func submitSideQuestion(envelope: CommandEnvelope<SubmitSideQuestionRequest>) async throws -> CommandReceipt<SideQuestionResult>
    func listAgentPresets(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[AgentPresetInfo]>
    func listAgentRuns(envelope: QueryEnvelope<GetRunRequest>) async throws -> ResponseEnvelope<[AgentRunDetail]>
    func compareMultiRuns(envelope: CommandEnvelope<MultiRunCompareRequest>) async throws -> CommandReceipt<MultiRunCompareResult>

    // MARK: - 17. Debug Observatory (read-only bypass)
    //
    // Deliberately no default implementations, like everything else the Runtime serves. When
    // Developer Debug Mode is off these throw `unsupportedCommand` rather than answering with an
    // empty page or a zeroed snapshot: an absent Observatory and an Observatory that found nothing
    // are different facts, and collapsing them is the fabrication §11 forbids.
    func debugStatus(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<DebugObservatoryStatus>
    func debugModeUpdate(envelope: CommandEnvelope<UpdateDebugModeRequest>) async throws -> CommandReceipt<DebugObservatoryStatus>
    func debugSnapshot(envelope: QueryEnvelope<GetObservatoryRequest>) async throws -> ResponseEnvelope<RuntimeObservatorySnapshot>
    func debugEvents(envelope: QueryEnvelope<GetObservatoryEventsRequest>) async throws -> ResponseEnvelope<DebugEventPage>

    // MARK: - Event Streams
    func subscribeRuntimeEvents(after: EventCursor?) async -> AsyncStream<RuntimeEventEnvelope>
    func subscribeSessionEvents(sessionID: SessionID, after: EventCursor?) async throws -> AsyncStream<SessionEventEnvelope>
    func listSessionEvents(request: ListSessionEventsRequest) async throws -> [SessionEventEnvelope]

    // MARK: - High-Frequency StreamFrames
    func subscribeStreamFrames(streamID: StreamID, afterIndex: UInt64?) async throws -> AsyncStream<StreamFrame>
}

public extension LingXiProtocolService {
    /// Genuinely optional content-plane conveniences. These are not defaults for a
    /// requirement — they are 1-argument overloads of the authorized form.
    ///
    /// Everything the Runtime actually serves deliberately has NO default here. A
    /// default would let a conformer that forgot an RPC keep compiling and answer
    /// with `applied: true`, `[]` or a made-up object, which is the failure mode
    /// §11 of the closure contract removes outright.

    func getContentMetadata(ref: ContentRef) async throws -> ContentMetadata {
        try await getContentMetadata(ref: ref, authorization: .anonymous)
    }
    func getContent(ref: ContentRef) async throws -> Data {
        try await getContent(ref: ref, authorization: .anonymous)
    }
    func getContentRange(ref: ContentRef, offset: Int, length: Int) async throws -> Data {
        try await getContentRange(ref: ref, offset: offset, length: length, authorization: .anonymous)
    }
    func listAgentPresets(envelope: QueryEnvelope<VoidResult>) async throws -> ResponseEnvelope<[AgentPresetInfo]> {
        // no production implementation behind this RPC; §11.3 forbids inventing a roster
        throw CoreError(code: .unsupportedCommand, message: "该 Runtime 不提供 Agent Preset 目录。")
    }
    func listAgentRuns(envelope: QueryEnvelope<GetRunRequest>) async throws -> ResponseEnvelope<[AgentRunDetail]> {
        // no production implementation; an empty list would read as "no runs" rather than "unsupported"
        throw CoreError(code: .unsupportedCommand, message: "该 Runtime 不提供 Run 列表查询。")
    }
    func compareMultiRuns(envelope: CommandEnvelope<MultiRunCompareRequest>) async throws -> CommandReceipt<MultiRunCompareResult> {
        // no production implementation; applied=true with an empty comparison is a fabricated success
        throw CoreError(code: .unsupportedCommand, message: "该 Runtime 不支持多 Run 对比。")
    }
}


