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
