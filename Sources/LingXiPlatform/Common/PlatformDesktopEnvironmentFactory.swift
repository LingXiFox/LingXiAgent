import Foundation
import LingXiProtocol

public final class DefaultFallbackProbe: CapabilityProbing, @unchecked Sendable {
    public init() {}

    public func probe() async -> HostCapabilitySnapshot {
        HostCapabilitySnapshot(
            capture: .unsupported(reason: "Desktop environment unsupported on this platform"),
            accessibility: .unsupported(reason: "Desktop environment unsupported on this platform"),
            input: .unsupported(reason: "Desktop environment unsupported on this platform"),
            windowManagement: .unsupported(reason: "Desktop environment unsupported on this platform"),
            applicationManagement: .unsupported(reason: "Desktop environment unsupported on this platform"),
            clipboard: .unsupported(reason: "Desktop environment unsupported on this platform")
        )
    }
}

public extension DesktopEnvironment {
    /// 获取当前宿主操作系统的默认桌面交互环境
    static func makeCurrentPlatformDefault() -> DesktopEnvironment {
        #if os(macOS)
        return DesktopEnvironment.makeDarwinDefault()
        #elseif os(Linux)
        return DesktopEnvironment.makeLinuxDefault()
        #elseif os(Windows)
        return DesktopEnvironment.makeWindowsDefault()
        #else
        return DesktopEnvironment(
            probe: DefaultFallbackProbe()
        )
        #endif
    }
}
