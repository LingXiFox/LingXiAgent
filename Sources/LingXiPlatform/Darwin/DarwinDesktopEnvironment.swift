#if os(macOS)
import Foundation
import LingXiProtocol

public extension DesktopEnvironment {
    /// 构造 macOS 原生桌面交互环境
    static func makeDarwinDefault() -> DesktopEnvironment {
        let probe = DarwinCapabilityProbe()
        return DesktopEnvironment(
            capture: DarwinCaptureBackend(),
            accessibility: DarwinAccessibilityBackend(),
            input: DarwinInputBackend(),
            windows: DarwinWindowBackend(),
            applications: DarwinApplicationBackend(),
            clipboard: DarwinClipboardBackend(),
            probe: probe
        )
    }
}
#endif
