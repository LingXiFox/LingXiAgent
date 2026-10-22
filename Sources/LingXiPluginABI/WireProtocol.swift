import Foundation
@_exported import LingXiSettingsProtocol

/// Methods are a closed set. An unknown method is a protocol violation the host answers with
/// `methodNotImplemented`, never a silent fallback (IPC-011).
public enum HostMethod: String, Codable, Sendable {
    case load
    case start
    case invoke
    case cancel
    case stop
    case ping
    case diagnostics
}

public struct HostRequest: Codable, Sendable {
    /// Present on every request-response; notifications carry nil (IPC-012).
    public var id: Int?
    public let method: HostMethod
    public var bundlePath: String?
    public var capability: String?
    public var payload: JSONValue?
    public var grantedPermissions: [String]?
    public var requestID: String?
    public var policy: String?

    public init(id: Int?, method: HostMethod) {
        self.id = id
        self.method = method
    }
}

public struct HostFault: Error, Codable, Sendable, Equatable {
    public let code: String
    public let domain: String
    public let message: String

    public init(code: String, domain: String, message: String) {
        self.code = code
        self.domain = domain
        self.message = message
    }
}

/// A frame with no id. Provider streams use it so events reach the caller while the invoke is still
/// running; the payload carries the requestID that routes it.
public struct HostNotification: Codable, Sendable {
    public let event: String
    public let payload: JSONValue?

    public init(event: String, payload: JSONValue?) {
        self.event = event
        self.payload = payload
    }
}

public struct HostReply: Codable, Sendable {
    public var id: Int?
    public let ok: Bool
    public var bundleID: String?
    public var abiMajor: UInt32?
    public var capabilities: [DeclaredCapability]?
    public var providers: [ProviderIdentity]?
    public var permissions: [String]?
    public var payload: JSONValue?
    public var fault: HostFault?

    public init(id: Int?, ok: Bool) {
        self.id = id
        self.ok = ok
    }
}

/// What a plugin says it can do. Decoded with no defaults anywhere: a missing field fails the load
/// rather than filling in a guess (PLG-009).
public struct DeclaredCapability: Codable, Sendable, Equatable {
    public let kind: String
    public let id: String
    public let node: String
    public let priority: Int
    public let canVeto: Bool

    public init(kind: String, id: String, node: String, priority: Int, canVeto: Bool) {
        self.kind = kind
        self.id = id
        self.node = node
        self.priority = priority
        self.canVeto = canVeto
    }
}

public enum HostWire {
    /// A frame larger than this is a protocol violation, not a buffer to grow into (IPC-006).
    public static let maxFrameBytes = 32 * 1024 * 1024

    public static func encode(_ value: some Encodable) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maxFrameBytes else {
            throw HostWireError.frameTooLarge(data.count)
        }
        return data + [UInt8(ascii: "\n")]
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maxFrameBytes else { throw HostWireError.frameTooLarge(data.count) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

public enum HostWireError: Error, Equatable {
    case frameTooLarge(Int)
    case undecodableFrame(String)
    case methodNotImplemented(String)
    case noReplyWithinDeadline(String)
    case hostExited(code: Int32, signal: Int?, stderrTail: String)
    case protocolViolation(String)
}

/// Signature tiers a Core may ask the host to enforce when loading a bundle.
public enum SignaturePolicy: String, Codable, Sendable {
    case restricted
    case permissive
    case development
}
