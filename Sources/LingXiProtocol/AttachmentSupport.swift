import Foundation

/// The one attachment rule the composer and Core still share: how much text a turn may carry.
///
/// There used to be a 40-entry extension table here, and the composer refused any file not on
/// it — a PNG among them — on the grounds that the model request only carried text. Whether a
/// model can read a file is not something a file extension answers, and not the composer's
/// call: images now travel as image parts and each provider adapter encodes them, so a
/// text-only model rejects them itself. Core fails a turn only for bytes that are neither an
/// image nor UTF-8 text (`CoreHost.resolveAttachments`).
public enum AttachmentSupport {
    /// How much attachment text one turn may carry in total.
    ///
    /// The point is a loud failure instead of a quiet one: an attachment that blows the window
    /// would otherwise be truncated by the context engine and the user would never learn the
    /// model did not read the file they sent.
    public static let maximumTurnCharacters = 400_000
}
