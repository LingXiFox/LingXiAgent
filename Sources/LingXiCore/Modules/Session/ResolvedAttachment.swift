import Foundation
import LingXiProtocol

/// An attachment whose bytes Core has already read out of the content store.
///
/// Core resolves refs to text at its own edge rather than handing a store handle to the turn
/// runtime: `SessionRuntime` assembles context, it does not do file I/O. The text is what the
/// model sees, so a ref that cannot be decoded as text is an error here, not something to skip —
/// silently dropping it would send a turn that looks like it has attachments but does not.
public struct ResolvedAttachment: Sendable, Equatable {
    public let filename: String
    public let mediaType: String
    public let text: String
    public let ref: ContentRef

    public init(filename: String, mediaType: String, text: String, ref: ContentRef) {
        self.filename = filename
        self.mediaType = mediaType
        self.text = text
        self.ref = ref
    }
}
