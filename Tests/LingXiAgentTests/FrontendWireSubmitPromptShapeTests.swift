import Foundation
import Testing
import LingXiProtocol
import LingXiApplication

/// The browser-facing wire shape, kept honest in both directions.
///
/// Wiring the Mac GUI's attachments added a second labelled payload to
/// `FrontendCommand.submitPrompt`. Synthesized `Codable` makes every labelled payload mandatory,
/// so a non-optional field would have made the shipped WebUI client's `{submitPrompt:{text:…}}`
/// body fail to decode — a regression the closure work itself introduced. The payload is
/// therefore optional, and both shapes are asserted here.
@Suite("Frontend wire submitPrompt shapes", .serialized)
struct FrontendWireSubmitPromptShapeTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func decoder() -> JSONDecoder { FrontendWire.makeDecoder() }

    /// Exactly what `Sources/LingXiWebUI/Assets/js/state.js` posts today.
    private static let legacyBody = Data(#"{"submitPrompt":{"text":"hi from the browser"}}"#.utf8)

    private static let modernBody = Data(
        #"{"submitPrompt":{"text":"with a file","attachments":[]}}"#.utf8)

    @Test("the legacy browser payload, with no attachments key, still decodes")
    func legacyShapeDecodes() throws {
        let decoded = try Self.decoder().decode(FrontendCommand.self, from: Self.legacyBody)
        // Value comparison rather than destructuring: arriving here at all is the proof that a
        // missing key decoded instead of throwing.
        let expected = FrontendCommand.submitPrompt(text: "hi from the browser", attachments: nil)
        #expect(decoded == expected)
    }

    @Test("the modern payload with an explicit attachment list decodes")
    func modernShapeDecodes() throws {
        let decoded = try Self.decoder().decode(FrontendCommand.self, from: Self.modernBody)
        let expected = FrontendCommand.submitPrompt(text: "with a file", attachments: [])
        #expect(decoded == expected)
    }

    @Test("a payload carrying a real reference survives the round trip")
    func attachmentRefsRoundTrip() throws {
        let ref = ContentRef(id: ContentID("content-7"), mediaType: "text/markdown", byteCount: 2048)
        let command = FrontendCommand.submitPrompt(text: "read this", attachments: [ref])
        let encoded = try FrontendWire.makeEncoder().encode(command)
        let decoded = try Self.decoder().decode(FrontendCommand.self, from: encoded)
        #expect(decoded == command, "附件引用在编码-解码之间失真，等于附件没有送出去")
    }

    /// The other half of the guarantee: an absent field must normalise to "no attachments" before
    /// it reaches the store, so `handleSubmitPrompt` never has to know the wire was optional.
    /// Asserted against the source because pattern-matching a case that declares a default
    /// associated value parses as a constructor call rather than a pattern.
    @Test("the mapper normalises nil to an empty list")
    func mapperNormalisesNil() throws {
        let path = "Sources/LingXiApplication/Frontend/FrontendWire.swift"
        let text = try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
        #expect(text.contains("attachments: attachments ?? []"),
                "FrontendWire 必须把 nil 归一成空列表，否则 nil 会一路带到 UserInput")
    }
}
