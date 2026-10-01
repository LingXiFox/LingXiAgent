import Foundation

/// ProtocolVersion 定义主次版本。
/// Major 不兼容则拒绝连接；Minor 差异进行 capability negotiation。
public struct ProtocolVersion: Codable, Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// 当前契约版本：v1.1
    public static let current = ProtocolVersion(major: 1, minor: 1)

    public var description: String {
        "\(major).\(minor)"
    }

    public static func < (lhs: ProtocolVersion, rhs: ProtocolVersion) -> Bool {
        if lhs.major == rhs.major {
            return lhs.minor < rhs.minor
        }
        return lhs.major < rhs.major
    }

    public func isCompatible(with clientVersion: ProtocolVersion) -> Bool {
        return self.major == clientVersion.major
    }
}

/// Protocol capability feature flags for negotiation between Core and Clients.
///
/// A feature names a promise: "send me these RPCs and I will answer". It is therefore not a
/// place to record that some Core type exists. `capability.gateway`, `trace.stream` and
/// `trace.query` used to live here with no RPC behind any of them, which made "the enum has a
/// case" indistinguishable from "the Runtime serves it" — exactly what §12 of the closure
/// contract forbids. An internal-only subsystem stays internal-only (§21 category C) until an
/// RPC, a transport dispatch and an implementation all exist.
public enum ProtocolFeature: String, Codable, Sendable, CaseIterable {
    case taskPause = "task.pause"
    case taskResume = "task.resume"
    case taskFork = "task.fork"
    case workspaceFork = "workspace.fork"
    /// Git RPC namespace：`git.status/diff/log/show/branch` + `git.add/restore/checkout/switch/commit`。
    /// 契约第十七节要求 RPC 存在与 feature 广播必须同时成立，不允许只声明一半。
    case gitRPC = "git.rpc"
    /// 远程同步 RPC：`git.fetch` / `git.pull` / `git.push`。
    /// 单独一个 feature 是因为远程写需要 `repositoryRemoteWrite`，本地已授权不代表远程可写。
    case gitRemoteSync = "git.remote.sync"
    case unknown = "unknown"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = ProtocolFeature(rawValue: raw) ?? .unknown
    }

    /// The wire methods a Runtime must dispatch for this advertisement to be true.
    /// `RuntimeCapabilitiesContractTests` fails if any advertised feature has an unwired method.
    public var requiredMethods: [String] {
        switch self {
        case .taskPause:      return ["task.pause"]
        case .taskResume:     return ["task.resume"]
        case .taskFork:       return ["task.fork"]
        case .workspaceFork:  return ["worktree.create", "worktree.list", "worktree.apply",
                                      "worktree.discard", "worktree.prune"]
        case .gitRPC:         return ["git.status", "git.diff", "git.log", "git.show", "git.branch",
                                      "git.add", "git.restore", "git.checkout", "git.switch", "git.commit"]
        case .gitRemoteSync:  return ["git.fetch", "git.pull", "git.push"]
        case .unknown:        return []
        }
    }

    /// Known active protocol features excluding fallback unknown case.
    ///
    /// This is the set the protocol *recognises*, not the set a Runtime serves. Producers must
    /// state what they wire; nothing defaults to this.
    public static var knownFeatures: [ProtocolFeature] {
        allCases.filter { $0 != .unknown }
    }
}

/// 跨两端统一的协议常量 (Audit Round 10 Phase C)
public enum ProtocolConstants {
    /// 统一 VNext JSON-lines frame 大小上限 (32MB)
    public static let maxFrameBytes: Int = 32 * 1024 * 1024
}
