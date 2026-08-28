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

    public func snapshot(for session: Session, projectPages: [ContextPage] = []) -> L1ContextSnapshot {
        let revision = (revisions[session.id] ?? 0) + 1
        revisions[session.id] = revision
        var entries: [ContextEntry] = []
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
            metrics: metrics(entries)
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

    private func metrics(_ entries: [ContextEntry]) -> ContextMetrics {
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
        return ContextMetrics(messageCount: ids.count + (policy.systemContext == nil ? 0 : 1), partCount: entries.count, characterCount: characters, sourceCounts: sourceCounts, sessionCharacterCount: sessionCharacters, projectCharacterCount: projectCharacters, projectPageCount: sourceCounts[.projectPage, default: 0])
    }
}
