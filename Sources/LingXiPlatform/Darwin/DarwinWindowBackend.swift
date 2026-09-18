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
            let pidNum = info[kCGWindowOwnerPID as String] as? NSNumber
            let bundleID: String? = {
                if let pid = pidNum?.int32Value, let app = NSRunningApplication(processIdentifier: pid), let bid = app.bundleIdentifier {
                    return bid
                }
                return ownerName
            }()
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
                bundleIdentifier: bundleID,
                bounds: rect,
                isMinimized: false,
                ownerPID: pidNum?.int32Value
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

            if let targetAXWindow = Self.findAXWindow(appElement: appElement, matchingWindowID: winID, fallbackBounds: targetWin.bounds, fallbackTitle: targetWin.title) {
                AXUIElementPerformAction(targetAXWindow, kAXRaiseAction as CFString)
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }

        // 5. 重新获取最新的窗口真实 Bounds
        let freshWindows = try await listWindows()
        return freshWindows.first(where: { $0.id == targetWin.id }) ?? targetWin
    }

    public func setWindowBounds(id: String, bounds: CoordinateRect) async throws {
        guard let winID = UInt32(id) else {
            throw ActionExecutionError.inputInjectionFailed(reason: "Invalid window ID: \(id)")
        }
        let options: CGWindowListOption = [.optionIncludingWindow]
        guard let infoList = CGWindowListCopyWindowInfo(options, winID) as? [[String: Any]],
              let first = infoList.first,
              let pidNum = first[kCGWindowOwnerPID as String] as? NSNumber else {
            throw ActionExecutionError.inputInjectionFailed(reason: "Window \(id) not found")
        }

        let pid = pidNum.int32Value
        let appElement = AXUIElementCreateApplication(pid)
        guard let targetAXWindow = Self.findAXWindow(appElement: appElement, matchingWindowID: winID, fallbackBounds: bounds) else {
            throw ActionExecutionError.inputInjectionFailed(reason: "Failed to locate exact target AXWindow for PID \(pid) WindowID \(winID)")
        }

        var pos = CGPoint(x: bounds.origin.x, y: bounds.origin.y)
        guard let posVal = AXValueCreate(.cgPoint, &pos) else {
            throw ActionExecutionError.inputInjectionFailed(reason: "Failed to create AXValue for position")
        }
        let posErr = AXUIElementSetAttributeValue(targetAXWindow, kAXPositionAttribute as CFString, posVal)

        var size = CGSize(width: bounds.width, height: bounds.height)
        guard let sizeVal = AXValueCreate(.cgSize, &size) else {
            throw ActionExecutionError.inputInjectionFailed(reason: "Failed to create AXValue for size")
        }
        let sizeErr = AXUIElementSetAttributeValue(targetAXWindow, kAXSizeAttribute as CFString, sizeVal)

        if posErr != .success && sizeErr != .success {
            throw ActionExecutionError.inputInjectionFailed(reason: "Failed to set window bounds: posErr=\(posErr.rawValue), sizeErr=\(sizeErr.rawValue)")
        }
    }

    /// 精确映射 CGWindowID 至对应的 AXUIElement 窗口，杜绝多窗口应用下误将动作路由给错误窗口。
    public static func findAXWindow(
        appElement: AXUIElement,
        matchingWindowID targetID: UInt32,
        fallbackBounds: CoordinateRect? = nil,
        fallbackTitle: String? = nil
    ) -> AXUIElement? {
        var windowsVal: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsVal) == .success,
              let axWindows = windowsVal as? [AXUIElement], !axWindows.isEmpty else {
            return nil
        }

        // 1. 优先通过私有但稳定的 _AXUIElementGetWindow 运行时符号获取真实 CGWindowID
        typealias AXGetWindowFunc = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        if let handle = dlopen(nil, RTLD_LAZY),
           let sym = dlsym(handle, "_AXUIElementGetWindow") {
            let getWin = unsafeBitCast(sym, to: AXGetWindowFunc.self)
            for axWin in axWindows {
                var currentID: CGWindowID = 0
                if getWin(axWin, &currentID) == .success && currentID == targetID {
                    return axWin
                }
            }
        }

        // 2. 几何与标题精准匹对 (几何容差 <= 5pt)
        if let bounds = fallbackBounds {
            for axWin in axWindows {
                var posVal: AnyObject?
                var sizeVal: AnyObject?
                var pt = CGPoint.zero
                var sz = CGSize.zero
                if AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &posVal) == .success,
                   AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &sizeVal) == .success,
                   let pos = posVal, let size = sizeVal {
                    if AXValueGetValue(pos as! AXValue, .cgPoint, &pt),
                       AXValueGetValue(size as! AXValue, .cgSize, &sz) {
                        let diffX = abs(Double(pt.x) - bounds.origin.x)
                        let diffY = abs(Double(pt.y) - bounds.origin.y)
                        let diffW = abs(Double(sz.width) - bounds.width)
                        let diffH = abs(Double(sz.height) - bounds.height)
                        if diffX < 8 && diffY < 8 && diffW < 12 && diffH < 12 {
                            return axWin
                        }
                    }
                }
            }
        }

        // 3. 标题精准匹对
        if let title = fallbackTitle, !title.isEmpty {
            for axWin in axWindows {
                var titleVal: AnyObject?
                if AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleVal) == .success,
                   let t = titleVal as? String, t == title {
                    return axWin
                }
            }
        }

        return axWindows.first
    }
}
#endif
