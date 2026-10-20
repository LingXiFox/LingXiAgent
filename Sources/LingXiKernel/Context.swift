public enum ContextSegment: String, Sendable, Codable {
    case immutableInstructions
    case history
    case currentUser
    case derivedPage

    /// Only immutable instructions may occupy the model's instruction channel; retrieval, recall and
    /// plugin hook output are data (CTX-001).
    public var isPrivileged: Bool { self == .immutableInstructions }

    /// Mandatory entries are never evicted; if they alone exceed the hard limit the run must stop
    /// with a budget error instead of dropping them (CTX-008).
    public var isMandatory: Bool { self == .immutableInstructions || self == .currentUser }

    /// Lower is dropped first when the plan needs room.
    public var evictionPriority: Int {
        switch self {
        case .derivedPage: 0
        case .history: 1
        case .currentUser: 2
        case .immutableInstructions: 3
        }
    }
}

public enum MessageRole: String, Sendable, Codable {
    case system
    case user
    case assistant
    case tool
}

public enum ContextPayload: Sendable, Codable {
    case text(String)
    case toolCall(requests: [ToolCall])
    /// A tool-call turn may also carry assistant text. Both parts are one history entry so the
    /// request keeps a single assistant message with the calls (LOOP-024).
    case assistantMessage(text: String, requests: [ToolCall])
    case toolResult(outcomes: [ToolOutcome])

    public var toolCalls: [ToolCall] {
        switch self {
        case .toolCall(let calls), .assistantMessage(_, let calls): calls
        default: []
        }
    }

    public var toolOutcomes: [ToolOutcome] {
        if case .toolResult(let outcomes) = self { outcomes } else { [] }
    }
}

public struct ContextEntry: Sendable, Codable, Identifiable {
    public let id: EntryID
    public let segment: ContextSegment
    public let role: MessageRole
    public let payload: ContextPayload
    /// Entries sharing a unit are one causal batch: an assistant call list and its result list must
    /// be evicted together or the pairing invariant breaks (CTX-009).
    public let unit: String?

    public init(id: EntryID, segment: ContextSegment, role: MessageRole, payload: ContextPayload, unit: String? = nil) {
        self.id = id
        self.segment = segment
        self.role = role
        self.payload = payload
        self.unit = unit
    }

    public var renderedText: String {
        switch payload {
        case .text(let text): return text
        case .toolCall(let calls): return calls.map { "\($0.callID.rawValue):\($0.toolName):\($0.argumentsJSON)" }.joined(separator: "\n")
        case .assistantMessage(let text, let calls):
            let renderedCalls = calls.map { "\($0.callID.rawValue):\($0.toolName):\($0.argumentsJSON)" }.joined(separator: "\n")
            return renderedCalls.isEmpty ? text : text + "\n" + renderedCalls
        case .toolResult(let outcomes): return outcomes.map { "\($0.callID.rawValue):\($0.content)" }.joined(separator: "\n")
        }
    }
}

public enum ContextValidationError: Error, Equatable {
    case privilegedEntryNotFirst(index: Int)
    /// Non-privileged content must never reach the model's instruction channel through `role.system`
    /// (CTX-001, CTX-018).
    case nonPrivilegedSystemRole(index: Int)
    case multiplePrivilegedEntries
    case orphanToolResult(ToolCallID)
    case unconsumedToolCall(ToolCallID)
    case duplicateToolCallID(ToolCallID)
    case toolResultNotAdjacent(ToolCallID)
    case splitCausalBatch(String)
}

/// Runs before a request leaves the kernel. Orphan results, calls without results, duplicate call
/// ids, non-adjacent tool messages and half-evicted batches are protocol violations and must never
/// reach a provider (CTX-014, CTX-003).
public enum ContextRequestValidator {
    public static func validate(_ entries: [ContextEntry], placement: ToolResultPlacement) throws {
        var privilegedCount = 0
        var seenCallIDs: Set<ToolCallID> = []
        var pending: [ToolCallID] = []
        var openUnit: String?
        var openCallIndex: Int?

        for (index, entry) in entries.enumerated() {
            if entry.segment.isPrivileged {
                privilegedCount += 1
                guard index == 0 else { throw ContextValidationError.privilegedEntryNotFirst(index: index) }
            }
            if entry.role == .system, !entry.segment.isPrivileged {
                throw ContextValidationError.nonPrivilegedSystemRole(index: index)
            }

            let calls = entry.payload.toolCalls
            let outcomes = entry.payload.toolOutcomes

            for call in calls {
                guard seenCallIDs.insert(call.callID).inserted else {
                    throw ContextValidationError.duplicateToolCallID(call.callID)
                }
                pending.append(call.callID)
            }

            if !outcomes.isEmpty {
                for outcome in outcomes {
                    guard pending.contains(outcome.callID) else {
                        throw ContextValidationError.orphanToolResult(outcome.callID)
                    }
                    pending.removeAll { $0 == outcome.callID }
                }
                if let unit = openUnit, entry.unit != unit {
                    throw ContextValidationError.splitCausalBatch(unit)
                }
                if placement == .immediatelyAfterCall, let callIndex = openCallIndex {
                    guard index == callIndex + 1 else {
                        throw ContextValidationError.toolResultNotAdjacent(outcomes[0].callID)
                    }
                }
                openUnit = nil
                openCallIndex = nil
            }

            if !calls.isEmpty {
                openUnit = entry.unit
                openCallIndex = index
            }
        }

        guard privilegedCount <= 1 else { throw ContextValidationError.multiplePrivilegedEntries }
        if let firstUnconsumed = pending.first {
            throw ContextValidationError.unconsumedToolCall(firstUnconsumed)
        }
    }
}
