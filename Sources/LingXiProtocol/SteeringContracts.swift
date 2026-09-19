import Foundation

/// Steering generation identifier to isolate asynchronous callbacks and speculative work across interruptions.
public struct SteeringGeneration: RawRepresentable, Sendable, Codable, Hashable, Comparable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: SteeringGeneration, rhs: SteeringGeneration) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var next: SteeringGeneration {
        SteeringGeneration(rawValue + 1)
    }

    public static let initial = SteeringGeneration(1)
}

/// Observable execution state captured at safe interruption boundaries when user steering occurs.
public struct InterruptionFrame: Sendable, Codable, Equatable {
    public let frameID: UUID
    public let sessionID: SessionID
    public let runID: RunID
    public let turnID: TurnID
    public let generation: SteeringGeneration
    public let userInterruption: String
    public let partialVisibleAssistantText: String?
    public let committedMutations: [String]
    public let recentToolCalls: [String]
    public let createdAt: Date

    public init(
        frameID: UUID = UUID(),
        sessionID: SessionID,
        runID: RunID,
        turnID: TurnID,
        generation: SteeringGeneration,
        userInterruption: String,
        partialVisibleAssistantText: String? = nil,
        committedMutations: [String] = [],
        recentToolCalls: [String] = [],
        createdAt: Date = Date()
    ) {
        self.frameID = frameID
        self.sessionID = sessionID
        self.runID = runID
        self.turnID = turnID
        self.generation = generation
        self.userInterruption = userInterruption
        self.partialVisibleAssistantText = partialVisibleAssistantText
        self.committedMutations = committedMutations
        self.recentToolCalls = recentToolCalls
        self.createdAt = createdAt
    }
}

/// User steering action type.
public enum SteeringAction: Sendable, Codable, Equatable {
    case redirect(instruction: String)
    case abort
}

/// Decision outcome of an interactive steering attempt.
public enum SteeringDecision: Sendable, Codable, Equatable {
    case accepted(frame: InterruptionFrame)
    case rejected(reason: String)
}
