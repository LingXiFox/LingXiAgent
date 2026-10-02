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
    /// Set for `image/*` attachments: the bytes go to the provider as an image part, and
    /// `text` is empty. Whether the model can read them is decided provider-side.
    public let imageData: Data?
    /// Set for a local file the user attached by path. The model is told the path; only an
    /// image's bytes are read, because a model cannot open an image through a text tool.
    public let path: String?
    /// Provider file ids for this image, keyed by `ResolvedModelEndpoint.fileReferenceKey`.
    /// The run uses the one for its own endpoint, if any; otherwise the bytes go inline.
    public let remoteRefs: [String: String]
    public let ref: ContentRef?

    public init(filename: String, mediaType: String, text: String, imageData: Data? = nil,
                path: String? = nil, remoteRefs: [String: String] = [:], ref: ContentRef?) {
        self.filename = filename
        self.mediaType = mediaType
        self.text = text
        self.imageData = imageData
        self.path = path
        self.remoteRefs = remoteRefs
        self.ref = ref
    }
}
