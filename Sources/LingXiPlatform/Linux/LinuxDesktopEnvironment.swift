#if os(Linux)
import Foundation
import LingXiProtocol

public final class LinuxCapabilityProbe: CapabilityProbing, @unchecked Sendable {
    public init() {}

    public func probe() async -> HostCapabilitySnapshot {
        let env = ProcessInfo.processInfo.environment
        let hasX11 = env["DISPLAY"] != nil
        let hasWayland = env["WAYLAND_DISPLAY"] != nil
        let isHeadless = !hasX11 && !hasWayland

        if isHeadless {
            let reason = "Headless Linux environment: Neither DISPLAY nor WAYLAND_DISPLAY is set"
            return HostCapabilitySnapshot(
                capture: .unsupported(reason: reason),
                accessibility: .unsupported(reason: reason),
                input: .unsupported(reason: reason),
                windowManagement: .unsupported(reason: reason),
                applicationManagement: .available,
                clipboard: .unsupported(reason: reason)
            )
        }

        let desktopType = hasWayland ? "Wayland" : "X11"
        return HostCapabilitySnapshot(
            capture: .temporarilyUnavailable(reason: "\(desktopType) ScreenCapture requires Portal/PipeWire daemon"),
            accessibility: .temporarilyUnavailable(reason: "AT-SPI2 accessibility daemon not connected"),
            input: .temporarilyUnavailable(reason: "\(desktopType) input injection requires libei / XTest"),
            windowManagement: .available,
            applicationManagement: .available,
            clipboard: .available
        )
    }
}

public final class LinuxStubCaptureBackend: CaptureBackend, @unchecked Sendable {
    public init() {}
    public func availableSources() async throws -> [CaptureSource] { [] }
    public func captureFrame(source: CaptureSource, cropRect: NormalizedRect?) async throws -> CapturedFrame {
        throw CapabilityError.daemonUnavailable(daemon: "PipeWire / XDG Desktop Portal")
    }
}

public final class LinuxStubAccessibilityBackend: AccessibilityBackend, @unchecked Sendable {
    public init() {}
    public func fetchTree(scope: AccessibilityScope) async throws -> [AccessibilityNodeSnapshot] { [] }
    public func performAction(nodeID: String, action: AccessibilityAction) async throws {
        throw CapabilityError.daemonUnavailable(daemon: "AT-SPI2")
    }
}

public final class LinuxStubInputBackend: InputBackend, @unchecked Sendable {
    public init() {}
    public func injectPointer(event: PointerInputEvent) async throws {
        throw CapabilityError.featureUnsupported(feature: "LinuxInputInjection", reason: "EIS / XTest backend not attached")
    }
    public func injectKeyboard(event: KeyboardInputEvent) async throws {
        throw CapabilityError.featureUnsupported(feature: "LinuxInputInjection", reason: "EIS / XTest backend not attached")
    }
    public func neutralize() async {}
}

public final class LinuxStubWindowBackend: WindowBackend, @unchecked Sendable {
    public init() {}
    public func listWindows() async throws -> [WindowInfo] { [] }
    public func focusWindow(id: String) async throws {}
    public func setWindowBounds(id: String, bounds: CoordinateRect) async throws {}
}

public final class LinuxStubApplicationBackend: ApplicationBackend, @unchecked Sendable {
    public init() {}
    public func listRunningApplications() async throws -> [ApplicationInfo] { [] }
    public func launchApplication(identifier: String) async throws -> Int32? { nil }
    public func terminateApplication(identifier: String) async throws {}
}

public final class LinuxStubClipboardBackend: ClipboardBackend, @unchecked Sendable {
    public init() {}
    public func readText() async throws -> String? { nil }
    public func writeText(_ text: String) async throws {}
}

public extension DesktopEnvironment {
    static func makeLinuxDefault() -> DesktopEnvironment {
        DesktopEnvironment(
            capture: LinuxStubCaptureBackend(),
            accessibility: LinuxStubAccessibilityBackend(),
            input: LinuxStubInputBackend(),
            windows: LinuxStubWindowBackend(),
            applications: LinuxStubApplicationBackend(),
            clipboard: LinuxStubClipboardBackend(),
            probe: LinuxCapabilityProbe()
        )
    }
}
#endif
