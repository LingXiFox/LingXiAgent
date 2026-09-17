import Foundation
import LingXiProtocol

// MARK: - Subsystem Data Structures

public struct CaptureSource: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let isDisplay: Bool

    public init(id: String, name: String, isDisplay: Bool) {
        self.id = id
        self.name = name
        self.isDisplay = isDisplay
    }
}

public struct CapturedFrame: Sendable {
    public let data: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scaleFactor: Double

    public init(data: Data, pixelWidth: Int, pixelHeight: Int, scaleFactor: Double) {
        self.data = data
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scaleFactor = scaleFactor
    }
}

public enum AccessibilityScope: Sendable, Codable, Equatable {
    case fullSystem
    case activeWindow
    case application(bundleOrName: String)
}

public enum AccessibilityAction: Sendable, Codable, Equatable {
    case press
    case focus
    case setValue(String)
}

public struct PointerInputEvent: Sendable, Codable, Equatable {
    public enum Kind: Sendable, Codable, Equatable {
        case move
        case down(button: PointerButton)
        case up(button: PointerButton)
        case click(button: PointerButton, count: Int)
        case scroll(deltaX: Double, deltaY: Double)
    }

    public let position: LogicalPoint
    public let kind: Kind

    public init(position: LogicalPoint, kind: Kind) {
        self.position = position
        self.kind = kind
    }
}

public struct KeyboardInputEvent: Sendable, Codable, Equatable {
    public enum Kind: Sendable, Codable, Equatable {
        case keyPress(key: String)
        case text(String)
        case modifiersChanged(KeyModifiers)
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }
}

public struct WindowInfo: Sendable, Codable, Equatable {
    public let id: String
    public let title: String?
    public let bundleIdentifier: String?
    public let bounds: CoordinateRect
    public let isMinimized: Bool

    public init(id: String, title: String?, bundleIdentifier: String?, bounds: CoordinateRect, isMinimized: Bool) {
        self.id = id
        self.title = title
        self.bundleIdentifier = bundleIdentifier
        self.bounds = bounds
        self.isMinimized = isMinimized
    }
}

public struct ApplicationInfo: Sendable, Codable, Equatable {
    public let identifier: String
    public let name: String
    public let processIdentifier: Int32?
    public let isActive: Bool

    public init(identifier: String, name: String, processIdentifier: Int32?, isActive: Bool) {
        self.identifier = identifier
        self.name = name
        self.processIdentifier = processIdentifier
        self.isActive = isActive
    }
}

// MARK: - Atomic Capability Protocols

public protocol CaptureBackend: Sendable {
    func availableSources() async throws -> [CaptureSource]
    func captureFrame(source: CaptureSource, cropRect: NormalizedRect?) async throws -> CapturedFrame
}

public protocol AccessibilityBackend: Sendable {
    func fetchTree(scope: AccessibilityScope) async throws -> [AccessibilityNodeSnapshot]
    func performAction(nodeID: String, action: AccessibilityAction) async throws
    func findElement(matching query: String, role: String?, scope: AccessibilityScope) async throws -> AccessibilityNodeSnapshot?
}

extension AccessibilityBackend {
    public func findElement(matching query: String, role: String? = nil, scope: AccessibilityScope = .activeWindow) async throws -> AccessibilityNodeSnapshot? {
        let tree = try await fetchTree(scope: scope)
        return tree.first { node in
            if let role, !role.isEmpty, node.role != role { return false }
            if let name = node.name, name.localizedCaseInsensitiveContains(query) { return true }
            if let val = node.value, val.localizedCaseInsensitiveContains(query) { return true }
            return false
        }
    }
}

public protocol InputBackend: Sendable {
    func injectPointer(event: PointerInputEvent) async throws
    func injectKeyboard(event: KeyboardInputEvent) async throws
    /// 强制安全契约：无论正常退出、抛错还是任务取消，必须释放所有按下的鼠标与修饰键
    func neutralize() async
}

public struct TargetAttachmentQuery: Sendable, Codable, Equatable {
    public let appName: String?
    public let bundleID: String?
    public let windowTitle: String?
    public let bringToFront: Bool

    public init(
        appName: String? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil,
        bringToFront: Bool = false
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.bringToFront = bringToFront
    }
}

public protocol WindowBackend: Sendable {
    func listWindows() async throws -> [WindowInfo]
    func focusWindow(id: String) async throws
    func setWindowBounds(id: String, bounds: CoordinateRect) async throws
    func attachTarget(query: TargetAttachmentQuery) async throws -> WindowInfo?
}

extension WindowBackend {
    public func attachTarget(query: TargetAttachmentQuery) async throws -> WindowInfo? {
        let windows = try await listWindows()
        let matched = windows.first { win in
            if let title = query.windowTitle, let winTitle = win.title, winTitle.localizedCaseInsensitiveContains(title) {
                return true
            }
            if let bundle = query.bundleID, let winBundle = win.bundleIdentifier, winBundle.localizedCaseInsensitiveContains(bundle) {
                return true
            }
            if let appName = query.appName, let winBundle = win.bundleIdentifier, winBundle.localizedCaseInsensitiveContains(appName) {
                return true
            }
            return false
        }
        if let matched {
            try await focusWindow(id: matched.id)
            return matched
        }
        return nil
    }
}

public protocol ApplicationBackend: Sendable {
    func listRunningApplications() async throws -> [ApplicationInfo]
    func launchApplication(identifier: String) async throws -> Int32?
    func terminateApplication(identifier: String) async throws
}

public protocol ClipboardBackend: Sendable {
    func readText() async throws -> String?
    func writeText(_ text: String) async throws
}

public protocol CapabilityProbing: Sendable {
    func probe() async -> HostCapabilitySnapshot
}

// MARK: - Dynamic Composite Environment

/// 动态组合式桌面环境（Composite Desktop Environment）。
/// 包含可选的原子后端集合与运行时探针，支持动态状态刷新（Dynamic Refresh & Invalidation）。
public actor DesktopEnvironment {
    public nonisolated let capture: (any CaptureBackend)?
    public nonisolated let accessibility: (any AccessibilityBackend)?
    public nonisolated let input: (any InputBackend)?
    public nonisolated let windows: (any WindowBackend)?
    public nonisolated let applications: (any ApplicationBackend)?
    public nonisolated let clipboard: (any ClipboardBackend)?
    public nonisolated let probe: any CapabilityProbing

    public private(set) var currentSnapshot: HostCapabilitySnapshot
    private var isSnapshotStale: Bool = false

    public init(
        capture: (any CaptureBackend)? = nil,
        accessibility: (any AccessibilityBackend)? = nil,
        input: (any InputBackend)? = nil,
        windows: (any WindowBackend)? = nil,
        applications: (any ApplicationBackend)? = nil,
        clipboard: (any ClipboardBackend)? = nil,
        probe: any CapabilityProbing,
        initialSnapshot: HostCapabilitySnapshot? = nil
    ) {
        self.capture = capture
        self.accessibility = accessibility
        self.input = input
        self.windows = windows
        self.applications = applications
        self.clipboard = clipboard
        self.probe = probe
        self.isSnapshotStale = (initialSnapshot == nil)
        self.currentSnapshot = initialSnapshot ?? HostCapabilitySnapshot(
            capture: .temporarilyUnavailable(reason: "Uninitialized"),
            accessibility: .temporarilyUnavailable(reason: "Uninitialized"),
            input: .temporarilyUnavailable(reason: "Uninitialized"),
            windowManagement: .temporarilyUnavailable(reason: "Uninitialized"),
            applicationManagement: .temporarilyUnavailable(reason: "Uninitialized"),
            clipboard: .temporarilyUnavailable(reason: "Uninitialized")
        )
    }

    /// 标记当前能力快照陈旧，强制下次 preflight 时重新 probe
    public func invalidateCapabilities() {
        self.isSnapshotStale = true
    }

    /// 动态刷新宿主能力快照
    @discardableResult
    public func refreshCapabilities() async -> HostCapabilitySnapshot {
        let updated = await probe.probe()
        self.currentSnapshot = updated
        self.isSnapshotStale = false
        return updated
    }

    /// 动作执行前的前置检查：若快照已失效，自动重新刷新
    public func preflightSnapshot() async -> HostCapabilitySnapshot {
        if isSnapshotStale {
            return await refreshCapabilities()
        }
        return currentSnapshot
    }
}
