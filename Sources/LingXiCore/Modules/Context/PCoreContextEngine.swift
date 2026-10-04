import Foundation
import LingXiProtocol

/// P-Core has exactly three frozen regions; indexes and query caches are retrieval helpers.
///
/// - `stablePrefix`: 当前 Session 中长期稳定的内容（system / 约束 / 核心目标 / 稳定工作状态）。
/// - `growingContext`: 正在增长、当前阶段被模型直接需要的内容（消息、Tool Call/Result、观察）。
///   ContextCompaction 只从这里移出对象。
/// - `eCoreIndex`: E-Core 索引投影 —— 已 page-out 对象的轻量 metadata / object reference。
///   按定义不得携带完整 payload；今天仍内联内容的条目由 store 收敛那一步改造。
public enum PCoreRegion: String, Sendable, Equatable, Hashable, CaseIterable {
    case stablePrefix
    case growingContext
    case eCoreIndex
}

extension ContextSource {
    public var pCoreRegion: PCoreRegion {
        switch self {
        case .system:
            return .stablePrefix
        // An attachment travels with the turn that introduced it, so it is growing context —
        // never the stable prefix, which is shared across turns and would keep a one-off file
        // in every subsequent request.
        case .userMessage, .assistantMessage, .toolCall, .toolResult, .observation, .attachment:
            return .growingContext
        case .projectPage, .derivedPage:
            return .eCoreIndex
        }
    }
}

/// PCore 来源描述的是模型工作集的语义，不是任何 Provider 的角色类型。
public enum ContextSource: String, Sendable, Equatable, Hashable {
    case system
    case userMessage
    case assistantMessage
    case toolCall
    case toolResult
    /// Bytes the user attached to a turn, read out of the content store by Core.
    case attachment
    case projectPage
    case derivedPage
    case observation
}

public enum ContextRole: Sendable, Equatable {
    case system
    case user
    case assistant
    case tool
}

public struct ContextEntry: Sendable, Equatable {
    public let messageID: MessageID?
    public let role: ContextRole
    public let source: ContextSource
    public let part: SessionMessagePart
    public let page: ContextPage?

    public init(messageID: MessageID?, role: ContextRole, source: ContextSource, part: SessionMessagePart, page: ContextPage? = nil) {
        self.messageID = messageID
        self.role = role
        self.source = source
        self.part = part
        self.page = page
    }
}

public struct ContextMetrics: Sendable, Equatable {
    public let messageCount: Int
    public let partCount: Int
    public let characterCount: Int
    public let sourceCounts: [ContextSource: Int]
    public let sessionCharacterCount: Int
    public let projectCharacterCount: Int
    public let projectPageCount: Int
    public let estimatedTokens: Int
    public let derivedPageCount: Int
    public let mandatoryTokens: Int
    public let recentSessionTokens: Int
    public let projectTokens: Int
    public let derivedTokens: Int
    public let liveToolBatchCount: Int
    public let compactionGeneration: Int

    /// P-Core 三分区各自的 token 占用。`projectTokens`/`derivedTokens` 是收敛前的历史口径，
    /// 分区口径以这三个字段为准。
    public let stablePrefixTokens: Int
    public let growingContextTokens: Int
    public let eCoreIndexTokens: Int

    /// 水位比较用的量：当前 P-Core 实际占用（三分区之和的度量口径即 estimatedTokens）。
    public var currentPCoreTokens: Int { estimatedTokens }
}

/// 一次 inference 实际可见的不可变 PCore 工作集。
public struct PCoreSnapshot: Sendable, Equatable {
    public let sessionID: SessionID
    public let revision: UInt64
    public let entries: [ContextEntry]
    public let metrics: ContextMetrics

    public func modelMessages() -> [ModelMessage] {
        var result: [ModelMessage] = []
        var currentID: MessageID?
        var currentRole: ModelRole?
        var parts: [ModelContentPart] = []

        let renderedEntries = entries.flatMap { entry -> [ContextEntry] in
            guard entry.messageID == nil, entry.source == .system, case let .text(content) = entry.part,
                  content.hasPrefix("Environment facts:\n"), let separator = content.range(of: "\n\n") else {
                return [entry]
            }
            let facts = String(content[..<separator.lowerBound])
            let instructions = String(content[separator.upperBound...])
            let instructionBlocks = instructions.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            var fragments = instructionBlocks.isEmpty ? [instructions] : instructionBlocks
            if entries.first?.messageID == nil {
                fragments.append(facts)
            } else {
                fragments.insert(facts, at: 0)
            }
            return fragments.map { ContextEntry(messageID: nil, role: .system, source: .system, part: .text($0)) }
        }

        func appendCurrent() {
            if let currentRole { result.append(ModelMessage(role: currentRole, parts: parts)) }
        }

        for entry in renderedEntries {
            let role = Self.modelRole(entry.role)
            if currentID != entry.messageID || currentRole != role {
                appendCurrent()
                currentID = entry.messageID
                currentRole = role
                parts = []
            }
            parts.append(Self.modelPart(entry.part))
        }
        appendCurrent()
        return result
    }

    private static func modelRole(_ role: ContextRole) -> ModelRole {
        switch role {
        case .system: .system
        case .user: .user
        case .assistant: .assistant
        case .tool: .tool
        }
    }

    private static func modelPart(_ part: SessionMessagePart) -> ModelContentPart {
        switch part {
        case let .text(text): .text(text)
        case let .toolCall(call): .toolCall(call)
        case let .toolResult(result): .toolResult(result)
        case let .observation(id): .text("[Observation: \(id.description)]")
        }
    }
}

/// PCore 初始策略：保留已完成 Session 的有序结构化历史，明确排除 reasoning 与 transient stream。
public struct PCorePolicy: Sendable {
    public let systemContext: String?

    public init(systemContext: String? = nil) {
        self.systemContext = systemContext?.isEmpty == true ? nil : systemContext
    }
}

/// Context Engine 是 Session history 与当前模型工作集之间的正式边界。
public actor PCoreContextEngine {
    private let policy: PCorePolicy
    private var revisions: [SessionID: UInt64] = [:]
    private var latest: [SessionID: PCoreSnapshot] = [:]

    public init(policy: PCorePolicy = PCorePolicy()) {
        self.policy = policy
    }

    public func snapshot(for session: Session, projectPages: [ContextPage] = [], activeEntries: [ContextEntry]? = nil, systemContext: String? = nil, estimatedTokens: Int = 0, mandatoryTokens: Int = 0, liveToolBatchCount: Int = 0, compactionGeneration: Int = 0) -> PCoreSnapshot {
        let revision = (revisions[session.id] ?? 0) + 1
        revisions[session.id] = revision
        var entries = activeEntries ?? []
        if activeEntries == nil {
        if let system = systemContext ?? policy.systemContext {
            entries.append(ContextEntry(messageID: nil, role: .system, source: .system, part: .text(system)))
        }
        for message in session.messages {
            for part in message.parts {
                let projectedPart: SessionMessagePart
                switch part {
                case let .toolResult(result):
                    projectedPart = .toolResult(ModelToolResultProjection.projectToolResult(result))
                default:
                    projectedPart = part
                }
                entries.append(ContextEntry(
                    messageID: message.id,
                    role: contextRole(message.role),
                    source: source(message.role, part),
                    part: projectedPart
                ))
            }
        }
        }
        let toolContents = Set(session.messages.flatMap { message in
            message.parts.compactMap { if case let .toolResult(result) = $0 { result.content } else { nil } }
        })
        var seenPages = Set<String>()
        for page in projectPages where seenPages.insert("\(page.path)|\(page.hash)").inserted && !toolContents.contains(page.content) {
            entries.append(ContextEntry(messageID: MessageID("project:\(page.id)"), role: .system, source: .projectPage, part: .text("[Project context: \(page.path):\(page.startLine)-\(page.endLine)]\n\(page.content)"), page: page))
        }
        let snapshot = PCoreSnapshot(
            sessionID: session.id,
            revision: revision,
            entries: entries,
            metrics: metrics(entries, estimatedTokens: estimatedTokens, mandatoryTokens: mandatoryTokens, liveToolBatchCount: liveToolBatchCount, compactionGeneration: compactionGeneration, hasSystemContext: (systemContext ?? policy.systemContext) != nil)
        )
        latest[session.id] = snapshot
        return snapshot
    }

    public func latestSnapshot(for sessionID: SessionID) -> PCoreSnapshot? {
        latest[sessionID]
    }

    public func reset(for sessionID: SessionID) {
        latest.removeValue(forKey: sessionID)
    }

    private func contextRole(_ role: MessageRole) -> ContextRole {
        switch role {
        case .user: .user
        case .assistant: .assistant
        case .tool: .tool
        }
    }

    private func source(_ role: MessageRole, _ part: SessionMessagePart) -> ContextSource {
        switch part {
        case .toolCall: .toolCall
        case .toolResult: .toolResult
        case .observation: .observation
        case .text:
            switch role {
            case .user: .userMessage
            case .assistant, .tool: .assistantMessage
            }
        }
    }

    public func entries(for session: Session, projectPages: [ContextPage] = [], systemContext: String? = nil, systemContextAtBeginning: Bool = true) -> [ContextEntry] {
        var entries: [ContextEntry] = []
        let systemEntry = (systemContext ?? policy.systemContext).map { ContextEntry(messageID: nil, role: .system, source: .system, part: .text($0)) }
        if systemContextAtBeginning, let systemEntry { entries.append(systemEntry) }
        for message in session.messages {
            for part in message.parts {
                let projectedPart: SessionMessagePart
                switch part {
                case let .toolResult(result):
                    projectedPart = .toolResult(ModelToolResultProjection.projectToolResult(result))
                default:
                    projectedPart = part
                }
                entries.append(ContextEntry(messageID: message.id, role: contextRole(message.role), source: source(message.role, part), part: projectedPart))
            }
        }
        let toolContents = Set(session.messages.flatMap { $0.parts.compactMap { if case let .toolResult(result) = $0 { result.content } else { nil } } })
        var seen = Set<String>()
        for page in projectPages where seen.insert("\(page.path)|\(page.hash)").inserted && !toolContents.contains(page.content) {
            entries.append(ContextEntry(messageID: MessageID("project:\(page.id)"), role: .system, source: .projectPage, part: .text("[Project context: \(page.path):\(page.startLine)-\(page.endLine)]\n\(page.content)"), page: page))
        }
        if !systemContextAtBeginning, let systemEntry { entries.append(systemEntry) }
        return entries
    }

    public func initialMandatoryTokens(task: String, estimator: any TokenEstimator = ConservativeTokenEstimator()) -> Int {
        var tokens = 0
        if let system = policy.systemContext, !system.isEmpty {
            tokens += estimator.estimate(text: system) + 4
        }
        tokens += estimator.estimate(text: task) + 4
        return tokens
    }

    private func metrics(_ entries: [ContextEntry], estimatedTokens: Int, mandatoryTokens: Int, liveToolBatchCount: Int, compactionGeneration: Int, hasSystemContext: Bool) -> ContextMetrics {
        var sourceCounts: [ContextSource: Int] = [:]
        var regionCharacters: [PCoreRegion: Int] = [:]
        var ids = Set<MessageID>()
        var characters = 0
        var sessionCharacters = 0
        var projectCharacters = 0
        for entry in entries {
            sourceCounts[entry.source, default: 0] += 1
            if let id = entry.messageID { ids.insert(id) }
            switch entry.part {
            case let .text(text): characters += text.count
            case let .toolCall(call): characters += call.arguments.count
            case let .toolResult(result):
                characters += result.content.count + (result.error?.message.count ?? 0)
            case let .observation(id):
                characters += id.description.count
            }
            let count: Int
            switch entry.part {
            case let .text(text): count = entry.page?.characterCount ?? text.count
            case let .toolCall(call): count = call.arguments.count
            case let .toolResult(result): count = result.content.count + (result.error?.message.count ?? 0)
            case let .observation(id): count = id.description.count
            }
            if entry.source == .projectPage { projectCharacters += count } else { sessionCharacters += count }
            regionCharacters[entry.source.pCoreRegion, default: 0] += count
        }
        let projectTokens = max(0, (projectCharacters + 2) / 3)
        let derivedCharacters = entries.filter { $0.source == .derivedPage }.reduce(0) { $0 + Self.characterCount(of: $1.part) }
        let derivedTokens = max(0, (derivedCharacters + 2) / 3)
        let effectiveTokens = estimatedTokens > 0 ? estimatedTokens : ConservativeTokenEstimator().estimate(entries: entries)
        return ContextMetrics(messageCount: ids.count + (hasSystemContext ? 1 : 0), partCount: entries.count, characterCount: characters, sourceCounts: sourceCounts, sessionCharacterCount: sessionCharacters, projectCharacterCount: projectCharacters, projectPageCount: sourceCounts[.projectPage, default: 0], estimatedTokens: effectiveTokens, derivedPageCount: sourceCounts[.derivedPage, default: 0], mandatoryTokens: mandatoryTokens, recentSessionTokens: max(0, effectiveTokens - projectTokens - derivedTokens - mandatoryTokens), projectTokens: projectTokens, derivedTokens: derivedTokens, liveToolBatchCount: liveToolBatchCount, compactionGeneration: compactionGeneration,
            stablePrefixTokens: max(0, (regionCharacters[.stablePrefix, default: 0] + 2) / 3),
            growingContextTokens: max(0, (regionCharacters[.growingContext, default: 0] + 2) / 3),
            eCoreIndexTokens: max(0, (regionCharacters[.eCoreIndex, default: 0] + 2) / 3))
    }

    private static func characterCount(of part: SessionMessagePart) -> Int {
        switch part {
        case let .text(text): text.count
        case let .toolCall(call): call.arguments.count
        case let .toolResult(result): result.content.count + (result.error?.message.count ?? 0)
        case let .observation(id): id.description.count
        }
    }
}
