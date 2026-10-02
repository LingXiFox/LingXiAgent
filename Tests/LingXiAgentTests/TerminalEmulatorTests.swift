#if canImport(SwiftUI)
import Foundation
import Testing
@testable import LingXiFrontendKit

@Suite("Terminal emulator")
struct TerminalEmulatorTests {
    @Test("Carriage return and line feed move the cursor like a terminal, not a transcript")
    func crlfAndOverwrite() {
        let screen = TerminalEmulator(columns: 20, rows: 4)
        screen.feed("hello\r\nworld\rW")
        #expect(screen.screenText.hasPrefix("hello\nWorld"))
        #expect(screen.cursorX == 1 && screen.cursorY == 1)
    }

    @Test("SGR colours land on cells instead of leaking as escape text")
    func colours() {
        let screen = TerminalEmulator(columns: 20, rows: 2)
        screen.feed("\u{1B}[1;31mred\u{1B}[0m \u{1B}[38;5;208mo\u{1B}[38;2;1;2;3mx")
        #expect(screen.screenText.hasPrefix("red ox"))
        #expect(screen.grid[0][0].attributes.foreground == .indexed(1))
        #expect(screen.grid[0][0].attributes.bold)
        #expect(screen.grid[0][3].attributes == TerminalAttributes())
        #expect(screen.grid[0][4].attributes.foreground == .indexed(208))
        #expect(screen.grid[0][5].attributes.foreground == .rgb(1, 2, 3))
    }

    @Test("Cursor addressing and erase redraw a line in place (what a prompt or progress bar does)")
    func eraseInLine() {
        let screen = TerminalEmulator(columns: 20, rows: 3)
        screen.feed("progress 10%")
        screen.feed("\r\u{1B}[Kprogress 99%")
        screen.feed("\u{1B}[3;5Hz")
        #expect(screen.screenText == "progress 99%\n\n    z")
    }

    @Test("Full-screen programs use the alternate screen and give the shell its screen back")
    func alternateScreen() {
        let screen = TerminalEmulator(columns: 10, rows: 3)
        screen.feed("$ vim\r\n")
        screen.feed("\u{1B}[?1049h\u{1B}[2J\u{1B}[Hediting")
        #expect(screen.usingAlternateScreen)
        #expect(screen.screenText.hasPrefix("editing"))
        screen.feed("\u{1B}[?1049l")
        #expect(!screen.usingAlternateScreen)
        #expect(screen.screenText.hasPrefix("$ vim"))
    }

    @Test("Output past the last row scrolls into history")
    func scrollback() {
        let screen = TerminalEmulator(columns: 10, rows: 2)
        screen.feed("a\r\nb\r\nc")
        #expect(screen.screenText == "b\nc")
        #expect(screen.scrollback.map(TerminalEmulator.text) == ["a"])
    }

    @Test("zsh's partial-line mark is erased when the shell and the screen agree on width")
    func zshPromptSP() {
        let screen = TerminalEmulator(columns: 50, rows: 5)
        screen.feed("\u{1B}[1m\u{1B}[7m%\u{1B}[27m\u{1B}[1m\u{1B}[0m" + String(repeating: " ", count: 49)
                    + "\r \r\r\u{1B}[0m\u{1B}[27m\u{1B}[24m\u{1B}[J\r\nprompt")
        #expect(!screen.screenText.contains("%"))
        #expect(screen.screenText.hasPrefix("\nprompt"))
    }

    @Test("Wide characters take two cells")
    func wideCharacters() {
        let screen = TerminalEmulator(columns: 10, rows: 1)
        screen.feed("中a")
        #expect(screen.cursorX == 3)
        #expect(screen.grid[0][1].character.isEmpty)
    }

    @Test("A cursor-position query is answered down the PTY")
    func deviceStatusReport() {
        let screen = TerminalEmulator(columns: 10, rows: 5)
        var replies: [String] = []
        screen.respond = { replies.append($0) }
        screen.feed("\u{1B}[3;4H\u{1B}[6n")
        #expect(replies == ["\u{1B}[3;4R"])
    }

    @Test("A UTF-8 sequence split across two reads is not mangled")
    func splitUTF8() {
        let screen = TerminalEmulator(columns: 10, rows: 1)
        let bytes = Array("好".utf8)
        screen.feed(Data(bytes.prefix(2)))
        screen.feed(Data(bytes.suffix(1)))
        #expect(screen.grid[0][0].character == "好")
    }
}
#endif
