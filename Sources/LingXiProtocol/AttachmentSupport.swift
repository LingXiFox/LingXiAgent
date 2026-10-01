import Foundation

/// Which attachments this Runtime can actually put in front of a model.
///
/// The rule lives here, in one place, because two parties have to agree on it: the composer
/// decides what it lets the user attach, and Core decides what it materialises into the turn.
/// If they each kept their own list, the composer would accept a file Core then quietly
/// dropped — which is the fabricated-success shape §0 of the closure contract forbids.
///
/// What is supported is bounded by the model request itself: `ModelContentPart` has no image
/// case, so a turn can only carry text. Anything that decodes as UTF-8 is therefore deliverable
/// and a PNG is not — not because the upload fails (it does not; the bytes go to Core's content
/// store and come back as a `ContentRef`), but because nothing downstream could read them.
/// Widening this set means adding the content part *and* the provider encodings, not a line here.
public enum AttachmentSupport {

    /// Recognised text attachments, keyed by lowercase extension.
    ///
    /// Extension rather than content sniffing: `UTType` is Apple-only and this package builds
    /// for Linux and Windows too, and Core's content store labels an upload from the filename
    /// anyway — deciding by a different rule would let a file pass the composer and then be
    /// dropped over a media-type mismatch.
    public static let textMediaTypes: [String: String] = [
        "txt": "text/plain", "log": "text/plain", "ini": "text/plain", "env": "text/plain",
        "csv": "text/csv", "tsv": "text/tab-separated-values",
        "md": "text/markdown", "markdown": "text/markdown",
        "html": "text/html", "htm": "text/html", "css": "text/css", "scss": "text/x-scss",
        "xml": "text/xml", "yaml": "application/yaml", "yml": "application/yaml",
        "toml": "application/toml", "json": "application/json", "jsonc": "application/json",
        "js": "text/javascript", "mjs": "text/javascript", "cjs": "text/javascript",
        "jsx": "text/javascript", "ts": "text/typescript", "tsx": "text/typescript",
        "swift": "text/x-swift", "py": "text/x-python", "rb": "text/x-ruby",
        "go": "text/x-go", "rs": "text/x-rust", "java": "text/x-java", "kt": "text/x-kotlin",
        "c": "text/x-c", "h": "text/x-c", "cc": "text/x-c++", "cpp": "text/x-c++",
        "hpp": "text/x-c++", "m": "text/x-objective-c", "mm": "text/x-objective-c",
        "sh": "application/x-sh", "bash": "application/x-sh", "zsh": "application/x-sh",
        "sql": "text/x-sql", "proto": "text/x-protobuf", "graphql": "text/x-graphql",
    ]

    /// How much attachment text one turn may carry in total.
    ///
    /// The point is a loud failure instead of a quiet one: an attachment that blows the window
    /// would otherwise be truncated by the context engine and the user would never learn the
    /// model did not read the file they sent.
    public static let maximumTurnCharacters = 400_000

    /// The media type reported for a picked file, or nil when this Runtime cannot carry it.
    public static func mediaType(for url: URL) -> String? {
        textMediaTypes[url.pathExtension.lowercased()]
    }

    /// True when a `ContentRef` already produced by an upload names something carryable.
    public static func isText(mediaType: String?) -> Bool {
        guard let lowered = mediaType?.lowercased() else { return false }
        if textMediaTypes.values.contains(lowered) { return true }
        return lowered.hasPrefix("text/")
    }

    /// Why a file was refused, phrased for a person rather than a log.
    public static func unsupportedReason(for url: URL) -> String {
        "「\(url.lastPathComponent)」不是本 Runtime 能交给模型的内容："
        + "模型请求目前只携带文本，图片或二进制文件还不支持。"
    }
}
