import Foundation

/// 任务挂起原因 (WaitingReason)
public enum WaitingReason: String, Sendable, Codable, Equatable, Hashable {
    case approvalPending
    case budgetExhausted
    case dependencyUnmet
    case externalSignal
    case rateLimited
    case humanInputRequired
    case reservedVerifier
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = WaitingReason(rawValue: raw) ?? .unknown
    }
}
