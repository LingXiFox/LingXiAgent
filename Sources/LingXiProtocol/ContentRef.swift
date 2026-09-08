import Foundation

/// ContentRef：对大内容、附件、RawToolResult、Shell、Diff、诊断的不可变、授权引用。
public struct ContentRef: Codable, Sendable, Hashable, Equatable {
    public let id: ContentID
    public let mediaType: String?
    public let byteCount: Int?
    public let tokenEstimate: Int?
    public let digest: String?

    public init(
        id: ContentID,
        mediaType: String? = nil,
        byteCount: Int? = nil,
        tokenEstimate: Int? = nil,
        digest: String? = nil
    ) {
        self.id = id
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.tokenEstimate = tokenEstimate
        self.digest = digest
    }
}

/// ContentAuthorizationScope 定义资源内容的访问作用域边界。
public enum ContentAuthorizationScope: Codable, Sendable, Hashable, Equatable {
    case global
    case session(SessionID)
    case principal(String)
    case workspace(String)
    case custom(String)

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let value = try container.decodeIfPresent(String.self, forKey: .value)
        switch kind {
        case "global": self = .global
        case "session": self = .session(SessionID(value ?? ""))
        case "principal": self = .principal(value ?? "")
        case "workspace": self = .workspace(value ?? "")
        default: self = .custom(value ?? kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .global:
            try container.encode("global", forKey: .kind)
        case let .session(id):
            try container.encode("session", forKey: .kind)
            try container.encode(id.rawValue, forKey: .value)
        case let .principal(p):
            try container.encode("principal", forKey: .kind)
            try container.encode(p, forKey: .value)
        case let .workspace(w):
            try container.encode("workspace", forKey: .kind)
            try container.encode(w, forKey: .value)
        case let .custom(c):
            try container.encode("custom", forKey: .kind)
            try container.encode(c, forKey: .value)
        }
    }
}

/// ContentAuthorizationContext 定义访问 ContentRef 时的鉴权上下文。
/// 关键安全边界：该上下文必须由 Transport/Connection Context 注入，不得信任远程调用方直接传入的可信标志。
public struct ContentAuthorizationContext: Codable, Sendable, Equatable {
    public let sessionID: SessionID?
    public let principal: String?
    public let workspaceID: String?
    public let isSystemAdmin: Bool

    public init(sessionID: SessionID? = nil, principal: String? = nil, workspaceID: String? = nil, isSystemAdmin: Bool = false) {
        self.sessionID = sessionID
        self.principal = principal
        self.workspaceID = workspaceID
        self.isSystemAdmin = isSystemAdmin
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, principal, workspaceID, isSystemAdmin
    }

    /// 当从不信任的外部传输层/JSON 解码时，强制将 isSystemAdmin 置为 false，杜绝伪造管理员提权。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let sessionStr = try? container.decode(String.self, forKey: .sessionID) {
            self.sessionID = SessionID(sessionStr)
        } else {
            self.sessionID = try container.decodeIfPresent(SessionID.self, forKey: .sessionID)
        }
        self.principal = try container.decodeIfPresent(String.self, forKey: .principal)
        self.workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        // 关键安全不变量：Public protocol 反序列化一律强制为普通非特权身份
        self.isSystemAdmin = false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(principal, forKey: .principal)
        try container.encodeIfPresent(workspaceID, forKey: .workspaceID)
        try container.encode(isSystemAdmin, forKey: .isSystemAdmin)
    }

    /// 服务端内部受信构造方法（无法通过网络反序列化伪造）
    public static func trusted(sessionID: SessionID? = nil, principal: String? = nil, workspaceID: String? = nil, isSystemAdmin: Bool = false) -> ContentAuthorizationContext {
        ContentAuthorizationContext(sessionID: sessionID, principal: principal, workspaceID: workspaceID, isSystemAdmin: isSystemAdmin)
    }

    public static let system = ContentAuthorizationContext(sessionID: nil, principal: nil, workspaceID: nil, isSystemAdmin: true)
    public static let anonymous = ContentAuthorizationContext()

    public func isAuthorized(for scope: ContentAuthorizationScope) -> Bool {
        if isSystemAdmin { return true }
        switch scope {
        case .global:
            return true
        case let .session(requiredSessionID):
            return sessionID == requiredSessionID
        case let .principal(requiredPrincipal):
            return principal == requiredPrincipal
        case let .workspace(requiredWorkspaceID):
            return workspaceID == requiredWorkspaceID
        case .custom:
            return false
        }
    }
}

/// 资源的元数据信息。
public struct ContentMetadata: Codable, Sendable, Equatable {
    public let ref: ContentRef
    public let createdAt: Date
    public let filename: String?
    public let scope: ContentAuthorizationScope

    public init(
        ref: ContentRef,
        createdAt: Date = Date(),
        filename: String? = nil,
        scope: ContentAuthorizationScope = .global
    ) {
        self.ref = ref
        self.createdAt = createdAt
        self.filename = filename
        self.scope = scope
    }
}

// MARK: - Content Upload Control Plane

public struct BeginContentUploadRequest: Codable, Sendable, Equatable {
    public let filename: String?
    public let proposedMediaType: String?
    public let expectedByteCount: Int?
    public let scope: ContentAuthorizationScope

    public init(
        filename: String? = nil,
        proposedMediaType: String? = nil,
        expectedByteCount: Int? = nil,
        scope: ContentAuthorizationScope = .global
    ) {
        self.filename = filename
        self.proposedMediaType = proposedMediaType
        self.expectedByteCount = expectedByteCount
        self.scope = scope
    }
}

public struct BeginContentUploadResponse: Codable, Sendable, Equatable {
    public let uploadID: String

    public init(uploadID: String) {
        self.uploadID = uploadID
    }
}

public struct CommitContentUploadRequest: Codable, Sendable, Equatable {
    public let uploadID: String
    public let expectedDigest: String?

    public init(uploadID: String, expectedDigest: String? = nil) {
        self.uploadID = uploadID
        self.expectedDigest = expectedDigest
    }
}

public struct AbortContentUploadRequest: Codable, Sendable, Equatable {
    public let uploadID: String

    public init(uploadID: String) {
        self.uploadID = uploadID
    }
}
