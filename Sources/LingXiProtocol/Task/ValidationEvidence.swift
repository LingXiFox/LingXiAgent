import Foundation

/// 任务校验与断言凭证
public struct ValidationEvidence: Sendable, Codable, Equatable, Hashable {
    public let evidenceID: String
    public let verdict: String // 'passed' | 'failed' | 'inconclusive'
    public let details: String
    public let recordedAt: Date

    public init(
        evidenceID: String = UUID().uuidString,
        verdict: String,
        details: String,
        recordedAt: Date = .now
    ) {
        self.evidenceID = evidenceID
        self.verdict = verdict
        self.details = details
        self.recordedAt = recordedAt
    }
}
