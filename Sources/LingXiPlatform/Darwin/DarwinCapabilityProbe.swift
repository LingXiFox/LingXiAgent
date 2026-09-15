#if os(macOS)
import Cocoa
import ApplicationServices
import CoreGraphics
import LingXiProtocol

public final class DarwinCapabilityProbe: CapabilityProbing, @unchecked Sendable {
    public init() {}

    public func probe() async -> HostCapabilitySnapshot {
        // 1. Accessibility 检查 (TCC)
        let axTrusted = AXIsProcessTrusted()
        let axStatus: CapabilityAvailability = axTrusted
            ? .available
            : .requiresAuthorization(subsystem: "macOS Accessibility (System Settings -> Privacy & Security -> Accessibility)")

        // 2. 屏幕录制权限检查 (Screen Recording TCC)
        let captureStatus: CapabilityAvailability
        if #available(macOS 10.15, *) {
            if CGPreflightScreenCaptureAccess() {
                captureStatus = .available
            } else {
                captureStatus = .requiresAuthorization(subsystem: "macOS Screen Recording (System Settings -> Privacy & Security -> Screen Recording)")
            }
        } else {
            captureStatus = .available
        }

        // 3. 输入注入：依赖 Accessibility 权限
        let inputStatus: CapabilityAvailability = axTrusted
            ? .available
            : .requiresAuthorization(subsystem: "macOS Accessibility (Input Event Injection)")

        // 4. 窗口管理与应用管理
        let windowStatus: CapabilityAvailability = .available
        let appStatus: CapabilityAvailability = .available

        // 5. 剪贴板
        let clipboardStatus: CapabilityAvailability = .available

        return HostCapabilitySnapshot(
            capture: captureStatus,
            accessibility: axStatus,
            input: inputStatus,
            windowManagement: windowStatus,
            applicationManagement: appStatus,
            clipboard: clipboardStatus
        )
    }
}
#endif
