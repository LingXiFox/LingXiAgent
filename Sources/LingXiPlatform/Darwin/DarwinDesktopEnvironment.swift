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

import Cocoa

public final class DarwinDesktopHelperAdapter: PlatformDesktopHelperProtocol, @unchecked Sendable {
    public init() {}

    public func attachTargetBounds(_ bounds: CoordinateRect?) async {
        await MainActor.run {
            DarwinVirtualPointerOverlay.shared.attachTargetBounds(bounds)
        }
    }

    public func findVisualElement(matching query: String, windowID: String?, windowBounds: CoordinateRect?) async throws -> VisualElementSnapshot? {
        guard let windowID else { return nil }
        let visionHit = await withTaskGroup(of: VisualElementSnapshot?.self) { group in
            group.addTask {
                if let hit = try? await DarwinVisionOCRBackend.shared.findElement(matching: query, windowID: windowID, windowBounds: windowBounds) {
                    return hit.element
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return visionHit
    }

    public func recognizeVisualCandidates(windowID: String?, windowBounds: CoordinateRect?, limit: Int) async throws -> [String] {
        guard let elements = try? await DarwinVisionOCRBackend.shared.recognizeElements(windowID: windowID, windowBounds: windowBounds) else {
            return []
        }
        return elements.prefix(limit).map { $0.text }
    }

    public func mainDisplayGeometry() -> (bounds: CoordinateRect, scaleFactor: Double) {
        if let mainScreen = NSScreen.main {
            let frame = mainScreen.frame
            let scale = Double(mainScreen.backingScaleFactor)
            return (
                CoordinateRect(
                    origin: TargetPosition(x: frame.origin.x, y: frame.origin.y, space: .logicalPoint(displayID: "main")),
                    width: frame.width,
                    height: frame.height
                ),
                scale
            )
        }
        return (
            CoordinateRect(
                origin: TargetPosition(x: 0, y: 0, space: .logicalPoint(displayID: "main")),
                width: 1920,
                height: 1080
            ),
            2.0
        )
    }
}
#endif

