#if os(Windows)
import Foundation
import LingXiProtocol

public final class WindowsCapabilityProbe: CapabilityProbing, @unchecked Sendable {
    public init() {}

    public func probe() async -> HostCapabilitySnapshot {
        HostCapabilitySnapshot(
            capture: .available,
            accessibility: .available,
            input: .available,
            windowManagement: .available,
            applicationManagement: .available,
            clipboard: .available
        )
    }
}

public final class WindowsStubCaptureBackend: CaptureBackend, @unchecked Sendable {
    public init() {}
    public func availableSources() async throws -> [CaptureSource] { [] }
    public func captureFrame(source: CaptureSource, cropRect: NormalizedRect?) async throws -> CapturedFrame {
        throw CapabilityError.featureUnsupported(feature: "WindowsGraphicsCapture", reason: "WGC not attached")
    }
}

public final class WindowsStubAccessibilityBackend: AccessibilityBackend, @unchecked Sendable {
    public init() {}
    public func fetchTree(scope: AccessibilityScope) async throws -> [AccessibilityNodeSnapshot] { [] }
    public func performAction(nodeID: String, action: AccessibilityAction) async throws {
        throw CapabilityError.featureUnsupported(feature: "UIAutomation", reason: "UIA not attached")
    }
}

public final class WindowsStubInputBackend: InputBackend, @unchecked Sendable {
    public init() {}
    public func injectPointer(event: PointerInputEvent) async throws {
        throw CapabilityError.featureUnsupported(feature: "SendInput", reason: "Win32 SendInput not attached")
    }
    public func injectKeyboard(event: KeyboardInputEvent) async throws {
        throw CapabilityError.featureUnsupported(feature: "SendInput", reason: "Win32 SendInput not attached")
    }
    public func neutralize() async {}
}

public final class WindowsStubWindowBackend: WindowBackend, @unchecked Sendable {
    public init() {}
    public func listWindows() async throws -> [WindowInfo] { [] }
    public func focusWindow(id: String) async throws {}
    public func setWindowBounds(id: String, bounds: CoordinateRect) async throws {}
}

public final class WindowsStubApplicationBackend: ApplicationBackend, @unchecked Sendable {
    public init() {}
    public func listRunningApplications() async throws -> [ApplicationInfo] { [] }
    public func launchApplication(identifier: String) async throws -> Int32? { nil }
    public func terminateApplication(identifier: String) async throws {}
}

public final class WindowsStubClipboardBackend: ClipboardBackend, @unchecked Sendable {
    public init() {}
    public func readText() async throws -> String? { nil }
    public func writeText(_ text: String) async throws {}
}

public extension DesktopEnvironment {
    static func makeWindowsDefault() -> DesktopEnvironment {
        DesktopEnvironment(
            capture: WindowsStubCaptureBackend(),
            accessibility: WindowsStubAccessibilityBackend(),
            input: WindowsStubInputBackend(),
            windows: WindowsStubWindowBackend(),
            applications: WindowsStubApplicationBackend(),
            clipboard: WindowsStubClipboardBackend(),
            probe: WindowsCapabilityProbe()
        )
    }
}
#endif
