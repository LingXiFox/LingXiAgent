import Foundation

/// Hard limits for plugin-owned settings frames. A frame is a terminal-sized value, not a document:
/// exceeding these limits is a protocol violation, never a reason to grow the host's buffers.
public enum SettingsWireLimits {
    public static let maxWidth = 120
    public static let maxHeight = 40
    public static let maxRows = 40
    public static let maxSpansPerRow = 128
    public static let maxSpanBytes = 4096
    public static let maxFrameBytes = 256 * 1024
    public static let maxConfigBytes = 64 * 1024
    public static let minInvocationIntervalMilliseconds = 20
}

/// The viewport the host lends to a plugin. The plugin never sees the physical terminal.
public struct SettingsViewport: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let focus: Bool
    /// Token-to-color map (`fox`, `dim`, ...). Plugins may also use `#RRGGBB` directly.
    public let theme: [String: String]?

    public init(width: Int, height: Int, focus: Bool = true, theme: [String: String]? = nil) {
        self.width = width
        self.height = height
        self.focus = focus
        self.theme = theme
    }

    public var clamped: SettingsViewport {
        SettingsViewport(
            width: min(max(width, 20), SettingsWireLimits.maxWidth),
            height: min(max(height, 4), SettingsWireLimits.maxHeight),
            focus: focus,
            theme: theme
        )
    }
}

public struct SettingsSpan: Codable, Sendable, Equatable {
    public let text: String
    public let fg: String?
    public let bg: String?
    public let bold: Bool?
    public let italic: Bool?
    public let underline: Bool?

    public init(
        _ text: String, fg: String? = nil, bg: String? = nil,
        bold: Bool? = nil, italic: Bool? = nil, underline: Bool? = nil
    ) {
        self.text = text
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.italic = italic
        self.underline = underline
    }
}

public struct SettingsRow: Codable, Sendable, Equatable {
    public let spans: [SettingsSpan]

    public init(_ spans: [SettingsSpan] = []) {
        self.spans = spans
    }
}

public struct SettingsFrame: Codable, Sendable, Equatable {
    public let rows: [SettingsRow]

    public init(rows: [SettingsRow]) {
        self.rows = rows
    }
}

public enum SettingsFrameError: Error, Equatable, CustomStringConvertible, Sendable {
    case tooManySpans(row: Int, count: Int)
    case spanTooLarge(row: Int, bytes: Int)
    case controlCharacter(row: Int)
    case invalidColor(String)
    case frameTooLarge(bytes: Int)

    public var description: String {
        switch self {
        case .tooManySpans(let row, let count):
            "row \(row) has \(count) spans; the limit is \(SettingsWireLimits.maxSpansPerRow)"
        case .spanTooLarge(let row, let bytes):
            "row \(row) has a span of \(bytes) bytes; the limit is \(SettingsWireLimits.maxSpanBytes)"
        case .controlCharacter(let row):
            "row \(row) contains a control character; raw terminal sequences are forbidden"
        case .invalidColor(let value):
            "color \(value) is neither #RRGGBB nor a theme token"
        case .frameTooLarge(let bytes):
            "frame is \(bytes) bytes; the limit is \(SettingsWireLimits.maxFrameBytes)"
        }
    }
}

/// Validates a plugin frame and clips it to the viewport. Clipping is deliberate: an over-wide row
/// is a layout bug, not a reason to spill cells over the host chrome. Control characters and
/// oversized structures are refused outright because they could forge terminal state.
public enum SettingsFrameValidator {
    public static let themeTokens: Set<String> = [
        "charcoal", "charcoalRaised", "overlay", "selection", "cream", "fox", "dim",
        "muted", "error", "success", "link", "string", "number", "type",
    ]

    public static func validate(_ frame: SettingsFrame, viewport: SettingsViewport) throws -> SettingsFrame {
        let encoded = (try? JSONEncoder().encode(frame)) ?? Data()
        guard encoded.count <= SettingsWireLimits.maxFrameBytes else {
            throw SettingsFrameError.frameTooLarge(bytes: encoded.count)
        }
        let width = viewport.clamped.width
        let height = min(viewport.clamped.height, SettingsWireLimits.maxRows)
        var rows: [SettingsRow] = []
        for (rowIndex, row) in frame.rows.prefix(height).enumerated() {
            guard row.spans.count <= SettingsWireLimits.maxSpansPerRow else {
                throw SettingsFrameError.tooManySpans(row: rowIndex, count: row.spans.count)
            }
            var remaining = width
            var spans: [SettingsSpan] = []
            for span in row.spans {
                guard span.text.utf8.count <= SettingsWireLimits.maxSpanBytes else {
                    throw SettingsFrameError.spanTooLarge(row: rowIndex, bytes: span.text.utf8.count)
                }
                guard !containsControlCharacter(span.text) else {
                    throw SettingsFrameError.controlCharacter(row: rowIndex)
                }
                for color in [span.fg, span.bg].compactMap({ $0 }) where !isAllowedColor(color) {
                    throw SettingsFrameError.invalidColor(color)
                }
                guard remaining > 0 else { break }
                let clipped = clip(span.text, to: remaining)
                guard !clipped.isEmpty else { continue }
                remaining -= displayWidth(clipped)
                spans.append(SettingsSpan(
                    clipped, fg: span.fg, bg: span.bg,
                    bold: span.bold, italic: span.italic, underline: span.underline
                ))
            }
            rows.append(SettingsRow(spans))
        }
        return SettingsFrame(rows: rows)
    }

    public static func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    public static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF,
             0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    private static func containsControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (scalar.value < 0x20 && scalar.value != 0x09) || scalar.value == 0x7F
                || (0x80...0x9F).contains(scalar.value)
        }
    }

    private static func isAllowedColor(_ value: String) -> Bool {
        if themeTokens.contains(value) { return true }
        guard value.count == 7, value.first == "#" else { return false }
        return value.dropFirst().allSatisfy { $0.isHexDigit }
    }

    private static func clip(_ text: String, to width: Int) -> String {
        var used = 0
        var result = ""
        for character in text {
            let scalarWidth = character.unicodeScalars.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
            if used + scalarWidth > width { break }
            used += scalarWidth
            result.append(character)
        }
        return result
    }
}

/// Credential state is status-only. A settings frame can never contain a secret because no secret
/// ever enters this type.
public struct SettingsCredentialStatus: Codable, Sendable, Equatable {
    public let providerID: String
    public let label: String
    public let configured: Bool
    public let source: String

    public init(providerID: String, label: String, configured: Bool, source: String) {
        self.providerID = providerID
        self.label = label
        self.configured = configured
        self.source = source
    }
}

public struct SettingsCommand: Codable, Sendable, Equatable {
    /// `credential.update` / `credential.remove`: the host runs its trusted secure-input flow.
    public let type: String
    public let providerID: String?

    public init(type: String, providerID: String? = nil) {
        self.type = type
        self.providerID = providerID
    }
}

/// The logical operations of a settings session. They travel as one invoke capability; the C ABI
/// table is unchanged.
public struct SettingsInvocation: Codable, Sendable, Equatable {
    public enum Op: String, Codable, Sendable {
        case open
        case input
        case resize
        case prepareSave
        case commit
        case apply
        case cancel
    }

    public let op: Op
    public let sessionID: String?
    public let viewport: SettingsViewport?
    public let config: JSONValue?
    public let input: SettingsInput?
    public let credentials: [SettingsCredentialStatus]?

    public init(
        op: Op, sessionID: String? = nil, viewport: SettingsViewport? = nil,
        config: JSONValue? = nil, input: SettingsInput? = nil,
        credentials: [SettingsCredentialStatus]? = nil
    ) {
        self.op = op
        self.sessionID = sessionID
        self.viewport = viewport
        self.config = config
        self.input = input
        self.credentials = credentials
    }
}

public struct SettingsInput: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case key
        case paste
        case mouse
        case resize
        case credential
    }

    public let kind: Kind
    /// `up`, `down`, `left`, `right`, `tab`, `enter`, `backspace`, `delete`, `escape`, `char`.
    public let key: String?
    public let char: String?
    public let text: String?
    public let row: Int?
    public let column: Int?
    public let delta: Int?
    public let width: Int?
    public let height: Int?

    public init(
        kind: Kind, key: String? = nil, char: String? = nil, text: String? = nil,
        row: Int? = nil, column: Int? = nil, delta: Int? = nil,
        width: Int? = nil, height: Int? = nil
    ) {
        self.kind = kind
        self.key = key
        self.char = char
        self.text = text
        self.row = row
        self.column = column
        self.delta = delta
        self.width = width
        self.height = height
    }
}

/// What a plugin returns for one settings operation.
public struct SettingsResponse: Codable, Sendable, Equatable {
    public let frame: SettingsFrame?
    public let title: String?
    public let command: SettingsCommand?
    /// Candidate configuration for `prepareSave`; ignored for every other operation.
    public let config: JSONValue?
    public let ok: Bool?
    public let error: String?

    public init(
        frame: SettingsFrame? = nil, title: String? = nil,
        command: SettingsCommand? = nil, config: JSONValue? = nil,
        ok: Bool? = nil, error: String? = nil
    ) {
        self.frame = frame
        self.title = title
        self.command = command
        self.config = config
        self.ok = ok
        self.error = error
    }
}

/// The host's snapshot of an open settings session, shared by Core and TUI.
public struct SettingsSnapshot: Codable, Sendable, Equatable {
    public let sessionID: String
    public let bundleID: String
    public let title: String
    public let version: String
    public let status: String?
    public let viewport: SettingsViewport
    public let frame: SettingsFrame
    /// Optional host action requested by the plugin (credential update/remove).
    public let command: SettingsCommand?

    public init(
        sessionID: String, bundleID: String, title: String, version: String,
        status: String?, viewport: SettingsViewport, frame: SettingsFrame,
        command: SettingsCommand? = nil
    ) {
        self.sessionID = sessionID
        self.bundleID = bundleID
        self.title = title
        self.version = version
        self.status = status
        self.viewport = viewport
        self.frame = frame
        self.command = command
    }
}
