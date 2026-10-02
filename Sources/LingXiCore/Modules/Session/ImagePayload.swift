import Foundation
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

/// Shrinks an attached image to what a vision model actually looks at before it goes on the wire.
///
/// A phone photo is 2–8 MB and 4000+ px on the long edge; providers scale it down anyway —
/// Anthropic to 1568 px on the long edge, OpenAI's high detail to 768 px on the short one —
/// so 1568 px loses nothing either model would have looked at. Sending the original turned a
/// one-line question about a 2.2 MB JPEG into a 9.5 s wait for the first response byte — about
/// 3 MB of base64 uploaded to the upstream before the model saw anything. This is transport,
/// not a gate: nothing is refused, and whether the model understands the image is still the
/// provider's call. HEIC, which providers do not accept, comes out as JPEG.
enum ImagePayload {
    static let maxPixelSize = 1568

    /// The bytes and media type to send. Falls back to the original when the platform cannot
    /// decode it (no ImageIO) or re-encoding would not make it smaller.
    static func prepared(_ data: Data, mediaType: String) -> (data: Data, mediaType: String) {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (data, mediaType)
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let isHEIF = mediaType == "image/heic" || mediaType == "image/heif"
        guard max(width, height) > maxPixelSize || isHEIF || data.count > 1_500_000 else {
            return (data, mediaType)
        }
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary) else { return (data, mediaType) }

        // PNG keeps transparency and sharp UI screenshots; everything else becomes JPEG.
        let keepPNG = mediaType == "image/png"
        let type = keepPNG ? UTType.png : UTType.jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return (data, mediaType)
        }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0,
              output.length < data.count || isHEIF else { return (data, mediaType) }
        return (output as Data, keepPNG ? "image/png" : "image/jpeg")
        #else
        return (data, mediaType)
        #endif
    }
}
