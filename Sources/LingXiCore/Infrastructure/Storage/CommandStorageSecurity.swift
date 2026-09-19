import Foundation
import LingXiProtocol
import LingXiPlatform

/// CommandStorageSecurity: Provides validation and secure filename mapping for external CommandID.
/// Invariant: Prevents path traversal attacks (e.g. "../../escape"), avoids filesystem NAME_MAX limits,
/// and guarantees deterministic 1-to-1 mapping into safe storage keys.
public enum CommandStorageSecurity {
    public static let maxCommandIDLength = 256

    /// Validates whether a CommandID is structurally safe.
    /// Rejects empty IDs, excessive length (>256), and path traversal sequences ('..', '/', '\\', '\0').
    public static func validate(_ commandID: CommandID) throws {
        let raw = commandID.rawValue
        if raw.isEmpty {
            throw RuntimeError(category: .validation, code: "emptyCommandID", message: "CommandID cannot be empty", retryability: .none, source: .client)
        }
        if raw.count > maxCommandIDLength {
            throw RuntimeError(category: .validation, code: "commandIDTooLong", message: "CommandID exceeds maximum length of \(maxCommandIDLength)", retryability: .none, source: .client)
        }
        if raw.contains("/") || raw.contains("\\") || raw.contains("..") || raw.contains("\0") {
            throw RuntimeError(category: .validation, code: "pathTraversalRejected", message: "CommandID contains illegal path characters", retryability: .none, source: .client)
        }
    }

    /// Determines if a CommandID passes security validation without throwing.
    public static func isValid(_ commandID: CommandID) -> Bool {
        (try? validate(commandID)) != nil
    }

    /// Derives a secure, fixed-length (64-char hex) filename component from CommandID using SHA-256.
    /// This ensures zero directory traversal risk and keeps filenames well within NAME_MAX constraints.
    public static func safeStorageKey(for commandID: CommandID) -> String {
        PlatformCrypto.sha256Hex(commandID.rawValue)
    }

    /// Derives a secure fingerprint from encodable payload to prevent cross-intent collision under identical CommandID.
    public static func fingerprint<T: Encodable>(_ payload: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(payload) {
            return PlatformCrypto.sha256Hex(data)
        }
        return "unhashed"
    }
}

