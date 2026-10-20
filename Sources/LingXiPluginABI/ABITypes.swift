import Foundation
@_exported import LingXiPluginABIC

/// The single version semantic that participates in any decision. Everything else that looks like a
/// version (`MinimumCoreVersion`, release notes) is a human hint and never a gate.
public enum LingXiABI {
    public static let major: UInt32 = 1
    public static let entryPointSymbol = "LingXiPlugin_Init"
}

/// Swift-side names for the C codes. The numbers are the contract; the C enumerators are the other
/// spelling of the same values.
public enum ABIStatusCode: Int32, Sendable, Codable {
    case ok = 0
    case capabilityFailed = 1
    case protocolViolation = 2
    case abiViolation = 3
    case permissionViolation = 4
    case timeout = 5
    case unresponsive = 6
    case crashed = 7
    case methodNotImplemented = 8
    case notStarted = 9
    case cancelled = 10
}

public extension LingXiStatus {
    /// A scalar status stamped with this build's struct size and ABI major. No pointers, so it is
    /// safe to hand across C, Swift and Objective-C callers alike.
    static func make(_ status: ABIStatusCode = .ok) -> LingXiStatus {
        LingXiStatus(
            structSize: UInt32(MemoryLayout<LingXiStatus>.size),
            abiMajor: LingXiABI.major,
            code: status.rawValue
        )
    }

    var statusCode: ABIStatusCode { ABIStatusCode(rawValue: code) ?? .capabilityFailed }
}

/// Every boundary call returns a status word and reports detail through an out-parameter.
public typealias LingXiPluginInitFn = @convention(c) (
    UnsafePointer<LingXiHostAPI>?, UInt32,
    UnsafeMutablePointer<UnsafePointer<LingXiPluginAPI>?>?, UnsafeMutablePointer<UInt32>?,
    UnsafeMutablePointer<LingXiStatus>?
) -> Int32

// MARK: - Boundary buffers

/// UTF-8 buffers cross the boundary as pointer plus length and are never assumed nul-terminated.
public enum LingXiBuffer {
    /// Allocates a boundary-owned copy. The receiver frees it through the exporting side's `free`.
    public static func duplicate(_ text: String) -> (UnsafeMutablePointer<UInt8>?, UInt32) {
        duplicate(Array(text.utf8))
    }

    public static func duplicate(_ bytes: [UInt8]) -> (UnsafeMutablePointer<UInt8>?, UInt32) {
        guard !bytes.isEmpty else { return (nil, 0) }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
        buffer.initialize(from: bytes, count: bytes.count)
        return (buffer, UInt32(bytes.count))
    }

    public static func release(_ pointer: UnsafeMutableRawPointer?) {
        pointer?.deallocate()
    }

    /// Copies a boundary buffer into a Swift string. A malformed sequence becomes the replacement
    /// character rather than a trap: the payload is rejected upstream if it cannot be parsed.
    public static func copyString(_ pointer: UnsafePointer<UInt8>?, length: UInt32) -> String {
        guard let pointer, length > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(length)), as: UTF8.self)
    }

    public static func copyBytes(_ pointer: UnsafePointer<UInt8>?, length: UInt32) -> [UInt8] {
        guard let pointer, length > 0 else { return [] }
        return Array(UnsafeRawBufferPointer(start: pointer, count: Int(length)))
    }
}
