import Foundation
import LingXiSettingsProtocol
import Testing

@Test("settings frames clip wide rows to the viewport without splitting a wide glyph")
func settingsFrameClipsWideRows() throws {
    let frame = SettingsFrame(rows: [
        SettingsRow([SettingsSpan("中文" + String(repeating: "A", count: 30)), SettingsSpan("tail")]),
    ])
    let clipped = try SettingsFrameValidator.validate(
        frame, viewport: SettingsViewport(width: 20, height: 2)
    )
    let text = clipped.rows[0].spans.map(\.text).joined()
    #expect(SettingsFrameValidator.displayWidth(text) <= 20)
    #expect(text.hasPrefix("中文"))
}

@Test("settings frames refuse raw terminal control sequences")
func settingsFrameRejectsControlCharacters() {
    let frame = SettingsFrame(rows: [
        SettingsRow([SettingsSpan("\u{1B}[31mred")]),
    ])
    #expect(throws: SettingsFrameError.controlCharacter(row: 0)) {
        try SettingsFrameValidator.validate(frame, viewport: SettingsViewport(width: 20, height: 3))
    }
}

@Test("settings frames accept theme tokens and hex colors, and reject anything else")
func settingsFrameValidatesColors() throws {
    let good = SettingsFrame(rows: [
        SettingsRow([SettingsSpan("ok", fg: "fox", bg: "#102030")]),
    ])
    _ = try SettingsFrameValidator.validate(good, viewport: SettingsViewport(width: 20, height: 3))
    let bad = SettingsFrame(rows: [
        SettingsRow([SettingsSpan("bad", fg: "31m")]),
    ])
    #expect(throws: SettingsFrameError.invalidColor("31m")) {
        try SettingsFrameValidator.validate(bad, viewport: SettingsViewport(width: 20, height: 3))
    }
}

@Test("settings frames are truncated to the viewport height")
func settingsFrameTruncatesRows() throws {
    let frame = SettingsFrame(rows: (0..<30).map { SettingsRow([SettingsSpan("row \($0)")]) })
    let clipped = try SettingsFrameValidator.validate(
        frame, viewport: SettingsViewport(width: 20, height: 5)
    )
    #expect(clipped.rows.count == 5)
}

@Test("clipping keeps multi-codepoint graphemes intact")
func settingsFrameKeepsGraphemes() throws {
    let family = "👨‍👩‍👧‍👦"
    let combining = "e\u{301}"
    let frame = SettingsFrame(rows: [
        SettingsRow([SettingsSpan(family + family + combining + combining + "tail")]),
    ])
    let clipped = try SettingsFrameValidator.validate(
        frame, viewport: SettingsViewport(width: 20, height: 2)
    )
    let text = clipped.rows[0].spans.map(\.text).joined()
    #expect(SettingsFrameValidator.displayWidth(text) <= 20)
    #expect(text.contains(family))
    #expect(!text.contains("\u{200D}\u{FE0F}"))
}

@Test("zero-width marks do not consume viewport cells")
func settingsFrameZeroWidthMarks() throws {
    let text = "a" + String(repeating: "\u{301}", count: 40) + "bcdef"
    let frame = SettingsFrame(rows: [SettingsRow([SettingsSpan(text)])])
    let clipped = try SettingsFrameValidator.validate(
        frame, viewport: SettingsViewport(width: 20, height: 2)
    )
    let result = clipped.rows[0].spans.map(\.text).joined()
    #expect(SettingsFrameValidator.displayWidth(result) <= 20)
}

@Test("a frame at the size limit is refused before it can grow host memory")
func settingsFrameSizeLimit() {
    let huge = String(repeating: "x", count: SettingsWireLimits.maxSpanBytes + 1)
    let frame = SettingsFrame(rows: [SettingsRow([SettingsSpan(huge)])])
    #expect(throws: SettingsFrameError.spanTooLarge(row: 0, bytes: huge.utf8.count)) {
        try SettingsFrameValidator.validate(frame, viewport: SettingsViewport(width: 40, height: 5))
    }
}
