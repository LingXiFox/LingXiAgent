import Foundation

public enum ArtifactKind: String, Sendable, Codable, CaseIterable {
    case diff = "diff"
    case testResult = "testResult"
    case reviewVerdict = "reviewVerdict"
    case filePatch = "filePatch"
    case diagram = "diagram"
    case spec = "spec"
    case report = "report"
    case file = "file"
    case generic = "generic"
}

/// 任务产出物 (TaskArtifact)
public struct TaskArtifact: Sendable, Codable, Equatable, Hashable {
    public let ordinal: Int
    public let kind: String // 'testResult' | 'diff' | 'reviewVerdict' | 'filePatch' | 'diagram' | 'spec' | 'report' | 'file' | 'generic'
    public let ref: String
    public var version: Int
    public var parentVersion: Int?
    public let metadata: [String: String]
    public let createdAt: Date

    public var artifactKind: ArtifactKind {
        ArtifactKind(rawValue: kind) ?? .generic
    }

    public init(
        ordinal: Int,
        artifactKind: ArtifactKind,
        ref: String,
        version: Int = 1,
        parentVersion: Int? = nil,
        metadata: [String: String] = [:],
        createdAt: Date = .now
    ) {
        self.ordinal = ordinal
        self.kind = artifactKind.rawValue
        self.ref = ref
        self.version = version
        self.parentVersion = parentVersion
        self.metadata = metadata
        self.createdAt = createdAt
    }

    public init(
        ordinal: Int,
        kind: String = "generic",
        ref: String,
        version: Int = 1,
        parentVersion: Int? = nil,
        metadata: [String: String] = [:],
        createdAt: Date = .now
    ) {
        self.ordinal = ordinal
        self.kind = kind
        self.ref = ref
        self.version = version
        self.parentVersion = parentVersion
        self.metadata = metadata
        self.createdAt = createdAt
    }
}

