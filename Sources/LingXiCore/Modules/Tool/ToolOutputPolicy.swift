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

/// An output bound a tool declares for itself, replacing the generic policy for that tool's
/// output only. A tool that already limits what it emits by an explicit caller-supplied range
/// must not then be cut again by a bound it does not control, or the range it reported becomes
/// untrue: the caller asked for N bytes, received N bytes, and the runtime silently ate the tail.
public struct ToolOutputContract: Sendable, Equatable {
    public let maximumCharacters: Int
    public let maximumLines: Int

    public init(maximumCharacters: Int, maximumLines: Int) {
        self.maximumCharacters = max(1, maximumCharacters)
        self.maximumLines = max(1, maximumLines)
    }

    /// The same bound expressed as a policy, so the runtime keeps a single excerpting path.
    public var policy: ToolOutputPolicy { ToolOutputPolicy(maximumCharacters: maximumCharacters, maximumLines: maximumLines) }
}

/// Markers that identify a recall transport result. Both forms are already budgeted by the
/// recall contract, so no further projection may slice them.
public enum RecallOutput {
    /// A byte range the model asked for, header included.
    public static let slice = "[Context Object Slice:"
    /// Acknowledgement that a whole occurrence was granted; carries no payload by design, so the
    /// occurrence can be delivered exactly once instead of twice.
    public static let occurrence = "[Context Object Occurrence:"

    public static func isBoundedTransport(_ content: String) -> Bool {
        content.hasPrefix(slice) || content.hasPrefix(occurrence)
    }
}
