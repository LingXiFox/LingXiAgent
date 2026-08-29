import Foundation
import LingXiProtocol

/// Bounds model-visible evidence while preserving complete output in BlobStore when available.
public struct ToolOutputPolicy: Sendable {
    public let maximumCharacters: Int
    public let maximumLines: Int

    public init(maximumCharacters: Int = 16 * 1024, maximumLines: Int = 400) {
        self.maximumCharacters = max(1, maximumCharacters)
        self.maximumLines = max(1, maximumLines)
    }

    public func excerpt(_ text: String) -> (content: String, metadata: ToolOutputMetadata) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.prefix(maximumLines).joined(separator: "\n")
        let content = String(kept.prefix(maximumCharacters))
        return (content, ToolOutputMetadata(truncated: content.utf8.count < text.utf8.count, totalCharacters: text.count, totalBytes: text.utf8.count, visibleCharacters: content.count, visibleBytes: content.utf8.count))
    }
}
