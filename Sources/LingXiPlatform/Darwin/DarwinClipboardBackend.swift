#if os(macOS)
import Cocoa
import LingXiProtocol

public final class DarwinClipboardBackend: ClipboardBackend, @unchecked Sendable {
    public init() {}

    public func readText() async throws -> String? {
        await MainActor.run {
            NSPasteboard.general.string(forType: .string)
        }
    }

    public func writeText(_ text: String) async throws {
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
}
#endif
