import Foundation
import LingXiProtocol

public actor ToolOutputArchive {
    private let persistence: SQLitePersistenceStore?

    public init(persistence: SQLitePersistenceStore?) {
        self.persistence = persistence
    }

    public func archive(_ content: String, metadata: ToolOutputMetadata) async throws -> ToolOutputMetadata {
        guard metadata.truncated, let persistence else { return metadata }
        return ToolOutputMetadata(
            truncated: true,
            totalCharacters: metadata.totalCharacters,
            totalBytes: metadata.totalBytes,
            visibleCharacters: metadata.visibleCharacters,
            visibleBytes: metadata.visibleBytes,
            outputBlobRef: try await persistence.storeToolOutput(content)
        )
    }

    /// Reads back the pre-truncation output stored by `archive`, or nil when nothing was archived.
    public func load(_ reference: String) async throws -> String? {
        guard let persistence else { return nil }
        return try await persistence.loadToolOutput(forReference: reference)
    }
}
