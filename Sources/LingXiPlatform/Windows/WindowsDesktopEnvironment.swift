#if os(Windows)
import Foundation
import LingXiProtocol

public final class WindowsCapabilityProbe: CapabilityProbing, @unchecked Sendable {
    public init() {}

    public func probe() async -> HostCapabilitySnapshot {
        HostCapabilitySnapshot(
            capture: .unsupported(reason: "WindowsGraphicsCapture stub: native Win32/WGC capture not yet implemented"),
            accessibility: .unsupported(reason: "UIAutomation stub: native UIA backend not yet implemented"),
            input: .unsupported(reason: "SendInput stub: native Win32 input injection not yet implemented"),
            windowManagement: .unsupported(reason: "EnumWindows stub: native Win32 window management not yet implemented"),
            applicationManagement: .unsupported(reason: "Process stub: native Win32 application management not yet implemented"),
            clipboard: .unsupported(reason: "Win32 Clipboard stub: clipboard management not yet implemented")
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
    public func focusWindow(id: String) async throws {
        throw CapabilityError.featureUnsupported(feature: "WindowsWindowManagement", reason: "Win32 focusWindow not implemented")
    }
    public func setWindowBounds(id: String, bounds: CoordinateRect) async throws {
        throw CapabilityError.featureUnsupported(feature: "WindowsWindowManagement", reason: "Win32 setWindowBounds not implemented")
    }
}

public final class WindowsStubApplicationBackend: ApplicationBackend, @unchecked Sendable {
    public init() {}
    public func listRunningApplications() async throws -> [ApplicationInfo] { [] }
    public func launchApplication(identifier: String) async throws -> Int32? {
        throw CapabilityError.featureUnsupported(feature: "WindowsApplicationManagement", reason: "Win32 launchApplication not implemented")
    }
    public func terminateApplication(identifier: String) async throws {
        throw CapabilityError.featureUnsupported(feature: "WindowsApplicationManagement", reason: "Win32 terminateApplication not implemented")
    }
}

public final class WindowsStubClipboardBackend: ClipboardBackend, @unchecked Sendable {
    public init() {}
    public func readText() async throws -> String? { nil }
    public func writeText(_ text: String) async throws {
        throw CapabilityError.featureUnsupported(feature: "WindowsClipboard", reason: "Win32 clipboard not implemented")
    }
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
