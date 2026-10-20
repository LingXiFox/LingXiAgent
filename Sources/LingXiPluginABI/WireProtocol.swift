import Foundation

/// Arbitrary JSON across the Core-Host line, kept as a value tree because the payload of a hook
/// invocation is decided by the kernel seam, not by this protocol.
public enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON") }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONValue(data: JSONEncoder().encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }
}


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

public struct HostReply: Codable, Sendable {
    public var id: Int?
    public let ok: Bool
    public var bundleID: String?
    public var abiMajor: UInt32?
    public var capabilities: [DeclaredCapability]?
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
