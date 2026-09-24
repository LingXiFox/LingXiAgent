import Foundation

/// 任务产出物 (TaskArtifact)
public struct TaskArtifact: Sendable, Codable, Equatable, Hashable {
    public let ordinal: Int
    public let kind: String // 'testResult' | 'diff' | 'reviewVerdict' | 'file' | 'generic'
    public let ref: String
    public let metadata: [String: String]
    public let createdAt: Date

    public init(
        ordinal: Int,
        kind: String = "generic",
        ref: String,
        metadata: [String: String] = [:],
        createdAt: Date = .now
    ) {
        self.ordinal = ordinal
        self.kind = kind
        self.ref = ref
        self.metadata = metadata
        self.createdAt = createdAt
    }
}
