#if os(macOS)
import Cocoa
import CoreGraphics
import LingXiProtocol

public final class DarwinWindowBackend: WindowBackend, @unchecked Sendable {
    public init() {}

    public func listWindows() async throws -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var results: [WindowInfo] = []
        for info in infoList {
            guard let windowIDNum = info[kCGWindowNumber as String] as? NSNumber else { continue }
            let windowID = windowIDNum.stringValue
            let title = info[kCGWindowName as String] as? String
            let ownerName = info[kCGWindowOwnerName as String] as? String
            let boundsDict = info[kCGWindowBounds as String] as? [String: Any] ?? [:]

            let x = (boundsDict["X"] as? NSNumber)?.doubleValue ?? 0
            let y = (boundsDict["Y"] as? NSNumber)?.doubleValue ?? 0
            let width = (boundsDict["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (boundsDict["Height"] as? NSNumber)?.doubleValue ?? 0

            let rect = CoordinateRect(
                origin: TargetPosition(x: x, y: y, space: .logicalPoint(displayID: "main")),
                width: width,
                height: height
            )

            results.append(WindowInfo(
                id: windowID,
                title: title,
                bundleIdentifier: ownerName,
                bounds: rect,
                isMinimized: false
            ))
        }

        return results
    }

    public func focusWindow(id: String) async throws {
        let options: CGWindowListOption = [.optionIncludingWindow]
        guard let winID = UInt32(id),
              let infoList = CGWindowListCopyWindowInfo(options, winID) as? [[String: Any]],
              let first = infoList.first,
              let pidNum = first[kCGWindowOwnerPID as String] as? NSNumber else {
            return
        }

        let pid = pidNum.int32Value
        await MainActor.run {
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.activate(options: .activateIgnoringOtherApps)
                if let bundle = app.bundleIdentifier {
                    let script = NSAppleScript(source: "tell application id \"\(bundle)\" to activate")
                    var err: NSDictionary?
                    script?.executeAndReturnError(&err)
                }
            }
        }
    }

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

        guard let targetWin = matched else {
            return nil
        }

        // 1. 通过 CGWindowList 获取所属 PID
        guard let winID = UInt32(targetWin.id) else {
            try await focusWindow(id: targetWin.id)
            return targetWin
        }

        let options: CGWindowListOption = [.optionIncludingWindow]
        let infoList = CGWindowListCopyWindowInfo(options, winID) as? [[String: Any]]
        let pid = (infoList?.first?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value

        // 2. 仅当明确指定 bringToFront 时才进行前台置顶焦点切换；默认保持当前终端在前台，绝不遮挡用户
        if query.bringToFront, let pid {
            await MainActor.run {
                if let app = NSRunningApplication(processIdentifier: pid) {
                    app.activate(options: .activateIgnoringOtherApps)
                    if let bundle = app.bundleIdentifier {
                        let script = NSAppleScript(source: "tell application id \"\(bundle)\" to activate")
                        var err: NSDictionary?
                        script?.executeAndReturnError(&err)
                    }
                }
            }

            // 原生无障碍层置顶与 Raise：确保窗口提升到本层最前
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

            var windowsVal: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsVal) == .success,
               let axWindows = windowsVal as? [AXUIElement], let frontWin = axWindows.first {
                AXUIElementPerformAction(frontWin, kAXRaiseAction as CFString)
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }

        // 5. 重新获取最新的窗口真实 Bounds
        let freshWindows = try await listWindows()
        return freshWindows.first(where: { $0.id == targetWin.id }) ?? targetWin
    }

    public func setWindowBounds(id: String, bounds: CoordinateRect) async throws {
        // 在 macOS 原生无障碍下，窗口 bounds 可通过 AXUIElement 修改
        // 若无足够权限，此接口静默忽略或在 Phase 2 原型中占位
    }
}
#endif
