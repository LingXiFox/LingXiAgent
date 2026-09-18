#if os(macOS)
import Cocoa
import ApplicationServices
import LingXiProtocol

public final class DarwinAccessibilityBackend: AccessibilityBackend, @unchecked Sendable {
    public init() {}

    private func checkAccessibilityPermission() throws {
        guard AXIsProcessTrusted() else {
            throw SystemAuthorizationError.denied(
                subsystem: "accessibility",
                guidance: "Grant Accessibility permission in System Settings -> Privacy & Security -> Accessibility"
            )
        }
    }

    private var elementCache: [String: AXUIElement] = [:]
    private let cacheLock = NSLock()

    public func fetchTree(scope: AccessibilityScope) async throws -> [AccessibilityNodeSnapshot] {
        try checkAccessibilityPermission()

        return await MainActor.run {
            guard let app = resolveTargetApplication(scope: scope) else {
                return []
            }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var snapshots: [AccessibilityNodeSnapshot] = []
            var newCache: [String: AXUIElement] = [:]
            var visitedCount = 0
            let maxNodes = 1500

            func traverse(element: AXUIElement, depth: Int) {
                guard depth <= 35, visitedCount < maxNodes else { return }
                visitedCount += 1

                let role = copyStringAttribute(element: element, attribute: kAXRoleAttribute) ?? "AXUnknown"
                let title = copyStringAttribute(element: element, attribute: kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let desc = copyStringAttribute(element: element, attribute: kAXDescriptionAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let val = copyStringAttribute(element: element, attribute: kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let placeholder = copyStringAttribute(element: element, attribute: "AXPlaceholderValue")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let domId = copyStringAttribute(element: element, attribute: "AXDOMIdentifier")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let identifier = copyStringAttribute(element: element, attribute: "AXIdentifier")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let roleDesc = copyStringAttribute(element: element, attribute: "AXRoleDescription")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let help = copyStringAttribute(element: element, attribute: "AXHelp")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let bounds = copyBounds(element: element)

                // 探测节点支持的操作列表（动态 Action 探测，应对 WebKit 内自定义 button/click 元素）
                var supportedActions: Set<String> = []
                var actionsArray: CFArray?
                if AXUIElementCopyActionNames(element, &actionsArray) == .success,
                   let acts = actionsArray as? [String] {
                    supportedActions = Set(acts)
                }

                // 针对复合可交互容器（如 AXButton、AXLink、AXGroup、AXTextField），若自身没有文本，提取子节点的静态文字
                var childTextSummary: String? = nil
                var subChildren: AnyObject?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &subChildren) == .success,
                   let childList = subChildren as? [AXUIElement] {
                    var textParts: [String] = []
                    for sub in childList.prefix(8) {
                        if let t = copyStringAttribute(element: sub, attribute: kAXValueAttribute) ??
                                   copyStringAttribute(element: sub, attribute: kAXTitleAttribute) ??
                                   copyStringAttribute(element: sub, attribute: kAXDescriptionAttribute),
                           !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            textParts.append(t.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }
                    if !textParts.isEmpty {
                        childTextSummary = textParts.joined(separator: " ")
                    }
                }

                // 综合命名：优先非空 title -> placeholder -> domId -> childText -> desc -> help -> roleDesc
                let primaryName: String? = {
                    if let title, !title.isEmpty { return title }
                    if let placeholder, !placeholder.isEmpty { return placeholder }
                    if let domId, !domId.isEmpty { return domId }
                    if let childTextSummary, !childTextSummary.isEmpty { return childTextSummary }
                    if let desc, !desc.isEmpty { return desc }
                    if let help, !help.isEmpty { return help }
                    if let roleDesc, !roleDesc.isEmpty { return roleDesc }
                    return nil
                }()

                // 构建复合元数据便于多维度检索（如按 search-input、placeholder 等模糊匹配）
                var metaTokens: [String] = []
                if let title, !title.isEmpty { metaTokens.append(title) }
                if let placeholder, !placeholder.isEmpty { metaTokens.append(placeholder) }
                if let domId, !domId.isEmpty { metaTokens.append(domId) }
                if let childTextSummary, !childTextSummary.isEmpty { metaTokens.append(childTextSummary) }
                if let identifier, !identifier.isEmpty { metaTokens.append(identifier) }
                if let desc, !desc.isEmpty { metaTokens.append(desc) }
                if let help, !help.isEmpty { metaTokens.append(help) }
                if let roleDesc, !roleDesc.isEmpty { metaTokens.append(roleDesc) }
                let compositeSearchText = metaTokens.joined(separator: " ")

                let prefix: String
                switch scope {
                case .window(let target):
                    prefix = "w\(target.windowID)_r\(target.revision)"
                case .application(let appName):
                    prefix = "app_\(appName.prefix(8))"
                case .activeWindow:
                    prefix = "active"
                case .fullSystem:
                    prefix = "sys"
                }
                let nodeId = "\(prefix)_node_\(visitedCount)"
                let finalName = (primaryName?.isEmpty ?? true) ? (compositeSearchText.isEmpty ? nil : compositeSearchText) : primaryName

                let isInteractable = isElementInteractable(role: role, supportedActions: supportedActions, hasDomId: domId != nil)

                let snapshot = AccessibilityNodeSnapshot(
                    id: nodeId,
                    role: role,
                    name: finalName,
                    value: val,
                    isInteractable: isInteractable,
                    bounds: bounds
                )
                snapshots.append(snapshot)
                newCache[nodeId] = element

                // 遍历子节点
                if let children = subChildren as? [AXUIElement] {
                    for child in children {
                        traverse(element: child, depth: depth + 1)
                        if visitedCount >= maxNodes { break }
                    }
                }
            }

            // 若 scope 为指定窗口，则精确锁定目标 AXWindow 根节点；否则优先遍历应用各窗口
            if case .window(let target) = scope,
               let targetWin = DarwinWindowBackend.findAXWindow(appElement: appElement, matchingWindowID: target.windowID, fallbackBounds: target.bounds) {
                traverse(element: targetWin, depth: 0)
            } else {
                var windowsValue: AnyObject?
                if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                   let windows = windowsValue as? [AXUIElement], !windows.isEmpty {
                    for win in windows {
                        traverse(element: win, depth: 0)
                        if visitedCount >= maxNodes { break }
                    }
                } else {
                    traverse(element: appElement, depth: 0)
                }
            }

            cacheLock.withLock {
                for (k, v) in newCache {
                    self.elementCache[k] = v
                }
                if self.elementCache.count > 5000 {
                    self.elementCache = newCache
                }
            }

            return snapshots
        }
    }

    public func findElement(
        matching query: String,
        role: String? = nil,
        scope: AccessibilityScope = .activeWindow
    ) async throws -> AccessibilityNodeSnapshot? {
        let tree = try await fetchTree(scope: scope)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        func roleMatches(nodeRole: String, requestedRole: String?) -> Bool {
            guard let requestedRole, !requestedRole.isEmpty else { return true }
            let req = requestedRole.lowercased().replacingOccurrences(of: "ax", with: "")
            let actual = nodeRole.lowercased().replacingOccurrences(of: "ax", with: "")
            if req == actual { return true }

            // 输入类控件模糊匹配
            let inputRoles: Set<String> = ["input", "textfield", "text", "search", "searchfield", "searchbox", "combobox", "textarea", "query"]
            let actualInputRoles: Set<String> = ["textfield", "textarea", "searchfield", "combobox"]
            if inputRoles.contains(req) && actualInputRoles.contains(actual) {
                return true
            }

            // 按钮/点击类控件模糊匹配
            let buttonRoles: Set<String> = ["button", "btn", "submit", "press"]
            let actualButtonRoles: Set<String> = ["button", "link", "menuitem", "tab", "group"]
            if buttonRoles.contains(req) && actualButtonRoles.contains(actual) {
                return true
            }

            // 链接类
            let linkRoles: Set<String> = ["link", "url", "a"]
            if linkRoles.contains(req) && (actual == "link" || actual == "group") {
                return true
            }

            return false
        }

        // 1. 精准或包含匹配
        if let directHit = tree.first(where: { node in
            guard roleMatches(nodeRole: node.role, requestedRole: role) else { return false }
            if let name = node.name, name.localizedCaseInsensitiveContains(trimmedQuery) { return true }
            if let val = node.value, val.localizedCaseInsensitiveContains(trimmedQuery) { return true }
            return false
        }) {
            return directHit
        }

        // 2. 语义分词容差匹配（例如用户搜 "检索" 命中 "执行检索" 或搜 "search" 命中 "search-input"）
        let tokens = trimmedQuery.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).filter { !$0.isEmpty }
        if !tokens.isEmpty {
            if let tokenHit = tree.first(where: { node in
                guard roleMatches(nodeRole: node.role, requestedRole: role) else { return false }
                let text = "\(node.name ?? "") \(node.value ?? "") \(node.role)".lowercased()
                return tokens.contains(where: { token in text.contains(token) })
            }) {
                return tokenHit
            }
        }

        // 3. 端侧本地 Vision OCR 智能兜底（针对没有辅助功能树的 App、自绘 Canvas 或 Web 复杂组件）
        if let visionHit = try? await DarwinVisionOCRBackend.shared.findElement(matching: trimmedQuery) {
            return AccessibilityNodeSnapshot(
                id: visionHit.element.id,
                role: "VisualElement",
                name: visionHit.element.text,
                value: nil,
                isInteractable: true,
                bounds: visionHit.element.bounds
            )
        }

        return nil
    }

    public func performAction(nodeID: String, action: AccessibilityAction) async throws {
        try checkAccessibilityPermission()

        let elem = cacheLock.withLock {
            elementCache[nodeID]
        }

        guard let element = elem else {
            throw InteractionError.actionExecution(.inputInjectionFailed(reason: "Accessibility node '\(nodeID)' not found"))
        }

        switch action {
        case .press:
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if result != .success {
                let fallbackResult = AXUIElementPerformAction(element, "AXConfirm" as CFString)
                if fallbackResult != .success {
                    // 若直接对子节点执行 press 失败（如命中了 AXStaticText 或普通容器），向上递归 5 层查找第一个支持 press/confirm 的祖先（如 AXButton / AXLink）
                    var currentElement = element
                    var ancestorPressed = false
                    for _ in 0..<5 {
                        var parentVal: AnyObject?
                        if AXUIElementCopyAttributeValue(currentElement, kAXParentAttribute as CFString, &parentVal) == .success,
                           let parent = parentVal, CFGetTypeID(parent) == AXUIElementGetTypeID() {
                            let parentElem = parent as! AXUIElement
                            currentElement = parentElem
                            if AXUIElementPerformAction(parentElem, kAXPressAction as CFString) == .success ||
                               AXUIElementPerformAction(parentElem, "AXConfirm" as CFString) == .success {
                                ancestorPressed = true
                                break
                            }
                        } else {
                            break
                        }
                    }
                    if !ancestorPressed {
                        throw InteractionError.actionExecution(.inputInjectionFailed(reason: "AXPressAction returned \(result.rawValue)"))
                    }
                }
            }
        case .focus:
            _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        case .setValue(let val):
            // 关键：在向 WebKit/文本框设置值前，必须先置为 focused，否则后台输入会被 WebKit DOM 丢弃
            _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, val as CFTypeRef)
            if result != .success {
                throw InteractionError.actionExecution(.inputInjectionFailed(reason: "AXSetValue returned \(result.rawValue)"))
            }
        }
    }

    // MARK: - Helpers

    /// 智能解析目标宿主应用程序（支持中英文别名、Bundle 后缀、模糊匹配及非终端前台识别）
    private func resolveTargetApplication(scope: AccessibilityScope) -> NSRunningApplication? {
        let runningApps = NSWorkspace.shared.runningApplications
        let terminalBundleSubstrings: Set<String> = [
            "terminal", "ghostty", "iterm", "alacritty", "kitty", "vscode", "vscodium", "cursor"
        ]

        func isTerminalApp(_ app: NSRunningApplication) -> Bool {
            let bundle = (app.bundleIdentifier ?? "").lowercased()
            let name = (app.localizedName ?? "").lowercased()
            return terminalBundleSubstrings.contains(where: { bundle.contains($0) || name.contains($0) })
        }

        switch scope {
        case .window(let target):
            if target.ownerPID > 0, let app = NSRunningApplication(processIdentifier: target.ownerPID) {
                return app
            }
            if let bundle = target.bundleIdentifier {
                if let app = runningApps.first(where: { $0.bundleIdentifier == bundle }) {
                    return app
                }
            }
            return NSWorkspace.shared.frontmostApplication

        case .fullSystem, .activeWindow:
            let front = NSWorkspace.shared.frontmostApplication
            if let front, !isTerminalApp(front) {
                return front
            }
            // 若当前前台是运行 Agent 自身的终端，自动寻找顶层可见的真实宿主应用（优先 Safari、Chrome、访达等活跃窗口）
            let nonTerminalApps = runningApps.filter { app in
                guard app.activationPolicy == .regular, !isTerminalApp(app) else { return false }
                return true
            }
            return nonTerminalApps.first ?? front

        case .application(let bundleOrName):
            let lower = bundleOrName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            // 1. 精确匹配 bundleIdentifier 或 localizedName
            if let exact = runningApps.first(where: {
                $0.bundleIdentifier?.lowercased() == lower ||
                $0.localizedName?.lowercased() == lower
            }) {
                return exact
            }

            // 2. 常见核心系统应用别名匹配表（解决中文系统下 "Safari 浏览器"、"访达" 等差异）
            let aliases: [String: [String]] = [
                "safari": ["com.apple.safari", "safari", "safari 浏览器"],
                "chrome": ["com.google.chrome", "google chrome", "chrome"],
                "finder": ["com.apple.finder", "finder", "访达"],
                "notes": ["com.apple.notes", "notes", "备忘录"],
                "settings": ["com.apple.systempreferences", "system settings", "系统设置", "系统偏好设置"],
                "mail": ["com.apple.mail", "mail", "邮件"]
            ]

            for (key, aliasList) in aliases {
                if lower == key || aliasList.contains(lower) {
                    if let matched = runningApps.first(where: { app in
                        let b = (app.bundleIdentifier ?? "").lowercased()
                        let n = (app.localizedName ?? "").lowercased()
                        return aliasList.contains(b) || aliasList.contains(n) || aliasList.contains(where: { b.contains($0) || n.contains($0) })
                    }) {
                        return matched
                    }
                }
            }

            // 3. 子串模糊匹配
            return runningApps.first(where: { app in
                let b = (app.bundleIdentifier ?? "").lowercased()
                let n = (app.localizedName ?? "").lowercased()
                return b.contains(lower) || n.contains(lower)
            })
        }
    }

    private func copyStringAttribute(element: AXUIElement, attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func copyBounds(element: AXUIElement) -> CoordinateRect? {
        var posVal: AnyObject?
        var sizeVal: AnyObject?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posVal) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeVal) == .success,
              let pos = posVal, CFGetTypeID(pos) == AXValueGetTypeID(),
              let size = sizeVal, CFGetTypeID(size) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        var cgSize = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &cgSize)

        return CoordinateRect(
            origin: TargetPosition(x: point.x, y: point.y, space: .logicalPoint(displayID: "main")),
            width: cgSize.width,
            height: cgSize.height
        )
    }

    private func isElementInteractable(role: String, supportedActions: Set<String> = [], hasDomId: Bool = false) -> Bool {
        let interactableRoles: Set<String> = [
            "AXButton",
            "AXRadioButton",
            "AXCheckBox",
            "AXTextField",
            "AXTextArea",
            "AXSearchField",
            "AXComboBox",
            "AXPopUpButton",
            "AXMenuButton",
            "AXMenuItem",
            "AXTab",
            "AXLink",
            "AXSlider",
            "AXWebArea"
        ]
        if interactableRoles.contains(role) { return true }
        if supportedActions.contains(kAXPressAction as String) ||
           supportedActions.contains("AXConfirm") ||
           supportedActions.contains("AXShowMenu") {
            return true
        }
        if hasDomId && (role == "AXGroup" || role == "AXImage" || role == "AXStaticText") {
            return true
        }
        return false
    }
}
#endif
