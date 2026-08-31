import Foundation
import LingXiProtocol

/// L1 来源描述的是模型工作集的语义，不是任何 Provider 的角色类型。
public enum ContextSource: String, Sendable, Equatable, Hashable {
    case system
    case userMessage
    case assistantMessage
    case toolCall
    case toolResult
    case projectPage
    case derivedPage
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
}

/// 一次 inference 实际可见的不可变 L1 工作集。
public struct L1ContextSnapshot: Sendable, Equatable {
    public let sessionID: SessionID
    public let revision: UInt64
    public let entries: [ContextEntry]
    public let metrics: ContextMetrics

    public func modelMessages() -> [ModelMessage] {
        var result: [ModelMessage] = []
        var currentID: MessageID?
        var currentRole: ModelRole?
        var parts: [ModelContentPart] = []

        func appendCurrent() {
            if let currentRole { result.append(ModelMessage(role: currentRole, parts: parts)) }
        }

        for entry in entries {
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
        }
    }
}

/// L1 初始策略：保留已完成 Session 的有序结构化历史，明确排除 reasoning 与 transient stream。
public struct L1ContextPolicy: Sendable {
    public let systemContext: String?

    public init(systemContext: String? = nil) {
        self.systemContext = systemContext?.isEmpty == true ? nil : systemContext
    }
}

/// Context Engine 是 Session history 与当前模型工作集之间的正式边界。
public actor L1ContextEngine {
    private let policy: L1ContextPolicy
    private var revisions: [SessionID: UInt64] = [:]
    private var latest: [SessionID: L1ContextSnapshot] = [:]

    public init(policy: L1ContextPolicy = L1ContextPolicy()) {
        self.policy = policy
    }

    public func snapshot(for session: Session, projectPages: [ContextPage] = [], activeEntries: [ContextEntry]? = nil, estimatedTokens: Int = 0, mandatoryTokens: Int = 0, liveToolBatchCount: Int = 0, compactionGeneration: Int = 0) -> L1ContextSnapshot {
        let revision = (revisions[session.id] ?? 0) + 1
        revisions[session.id] = revision
        var entries = activeEntries ?? []
        if activeEntries == nil {
        if let system = policy.systemContext {
            entries.append(ContextEntry(messageID: nil, role: .system, source: .system, part: .text(system)))
        }
        for message in session.messages {
            for part in message.parts {
                entries.append(ContextEntry(
                    messageID: message.id,
                    role: contextRole(message.role),
                    source: source(message.role, part),
                    part: part
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
        let snapshot = L1ContextSnapshot(
            sessionID: session.id,
            revision: revision,
            entries: entries,
            metrics: metrics(entries, estimatedTokens: estimatedTokens, mandatoryTokens: mandatoryTokens, liveToolBatchCount: liveToolBatchCount, compactionGeneration: compactionGeneration)
        )
        latest[session.id] = snapshot
        return snapshot
    }

    public func latestSnapshot(for sessionID: SessionID) -> L1ContextSnapshot? {
        latest[sessionID]
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
        case .text:
            switch role {
            case .user: .userMessage
            case .assistant, .tool: .assistantMessage
            }
        }
    }

    public func entries(for session: Session, projectPages: [ContextPage] = []) -> [ContextEntry] {
        var entries: [ContextEntry] = []
        if let system = policy.systemContext { entries.append(ContextEntry(messageID: nil, role: .system, source: .system, part: .text(system))) }
        for message in session.messages { for part in message.parts { entries.append(ContextEntry(messageID: message.id, role: contextRole(message.role), source: source(message.role, part), part: part)) } }
        let toolContents = Set(session.messages.flatMap { $0.parts.compactMap { if case let .toolResult(result) = $0 { result.content } else { nil } } })
        var seen = Set<String>()
        for page in projectPages where seen.insert("\(page.path)|\(page.hash)").inserted && !toolContents.contains(page.content) {
            entries.append(ContextEntry(messageID: MessageID("project:\(page.id)"), role: .system, source: .projectPage, part: .text("[Project context: \(page.path):\(page.startLine)-\(page.endLine)]\n\(page.content)"), page: page))
        }
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

    private func metrics(_ entries: [ContextEntry], estimatedTokens: Int, mandatoryTokens: Int, liveToolBatchCount: Int, compactionGeneration: Int) -> ContextMetrics {
        var sourceCounts: [ContextSource: Int] = [:]
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
            }
            let count: Int
            switch entry.part {
            case let .text(text): count = entry.page?.characterCount ?? text.count
            case let .toolCall(call): count = call.arguments.count
            case let .toolResult(result): count = result.content.count + (result.error?.message.count ?? 0)
            }
            if entry.source == .projectPage { projectCharacters += count } else { sessionCharacters += count }
        }
        let projectTokens = max(0, (projectCharacters + 2) / 3)
        let derivedCharacters = entries.filter { $0.source == .derivedPage }.reduce(0) { $0 + Self.characterCount(of: $1.part) }
        let derivedTokens = max(0, (derivedCharacters + 2) / 3)
        return ContextMetrics(messageCount: ids.count + (policy.systemContext == nil ? 0 : 1), partCount: entries.count, characterCount: characters, sourceCounts: sourceCounts, sessionCharacterCount: sessionCharacters, projectCharacterCount: projectCharacters, projectPageCount: sourceCounts[.projectPage, default: 0], estimatedTokens: estimatedTokens, derivedPageCount: sourceCounts[.derivedPage, default: 0], mandatoryTokens: mandatoryTokens, recentSessionTokens: max(0, estimatedTokens - projectTokens - derivedTokens - mandatoryTokens), projectTokens: projectTokens, derivedTokens: derivedTokens, liveToolBatchCount: liveToolBatchCount, compactionGeneration: compactionGeneration)
    }

    private static func characterCount(of part: SessionMessagePart) -> Int {
        switch part { case let .text(text): text.count; case let .toolCall(call): call.arguments.count; case let .toolResult(result): result.content.count + (result.error?.message.count ?? 0) }
    }
}
