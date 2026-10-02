#if canImport(ImageIO)
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import LingXiCore

@Suite("Image payload")
struct ImagePayloadTests {
    private func jpeg(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for x in stride(from: 0, to: width, by: 7) {   // texture, so the JPEG is not trivially small
            context.setFillColor(CGColor(red: CGFloat(x % 255) / 255, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 3, height: height))
        }
        let image = try #require(context.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test("A large photo is sent at the size a vision model uses, smaller than the original")
    func largePhotoIsShrunk() throws {
        let original = try jpeg(width: 3840, height: 2452)
        let prepared = ImagePayload.prepared(original, mediaType: "image/jpeg")
        #expect(prepared.mediaType == "image/jpeg")
        #expect(prepared.data.count < original.count)
        let source = try #require(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == ImagePayload.maxPixelSize)
    }

    @Test("A small image and undecodable bytes go out untouched")
    func smallAndInvalidAreUntouched() throws {
        let small = try jpeg(width: 400, height: 300)
        #expect(ImagePayload.prepared(small, mediaType: "image/jpeg").data == small)
        let junk = Data([0xFF, 0xD8, 0x00])
        #expect(ImagePayload.prepared(junk, mediaType: "image/jpeg").data == junk)
    }
}
#endif
