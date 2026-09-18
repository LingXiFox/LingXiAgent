import Foundation
import LingXiProtocol
import LingXiPlatform
#if os(macOS)
import Cocoa
import CoreGraphics
#endif

/// 桌面计算机交互动作批处理工具 (computer_batch)
/// 允许模型在一次轮次中一次性下发一连串动作指令（如：查找元素 -> 移动 -> 点击 -> 输入 -> 回车 -> 等待），
/// 本地由 ActionBatchExecutor 流水线连贯执行，记录毫秒级单步耗时，退出自动强安全中立化。
public struct ComputerBatchTool: ToolExecutor {
    public let definition: ToolDefinition
    private let customEnvironment: DesktopEnvironment?

    public init(environment: DesktopEnvironment? = nil) {
        self.customEnvironment = environment
        self.definition = ToolDefinition(
            id: ToolID("computer_batch"),
            name: "computer_batch",
            description: """
            Execute a sequential batch of desktop computer interaction and UI observation actions in one turn.
            CRITICAL LATENCY & USER EXPERIENCE RULES:
            1. ALWAYS specify 'target_app' (e.g. 'Safari', 'TextEdit') so the interaction scopes directly to the target application!
            2. DO NOT split tasks into multiple roundtrip turns (e.g. NEVER do turn 1: find, turn 2: inspect, turn 3: click). Combine all steps into ONE single batch!
            3. Recommended pattern: use 'element_query' inside 'type' and 'click' actions to auto-locate and operate in background without window focus stealing or occluding the user's terminal/TUI:
               {"target_app": "Safari", "actions": [{"type": "type", "element_query": "输入", "text": "测试文本"}, {"type": "click", "element_query": "检索"}]}
            4. Text-only LLMs (e.g. DeepSeek/DS-v4): Do NOT use 'screenshot' action because pixel images cannot be inspected. The system automatically inspects UI semantics via the Accessibility DOM tree!
            5. 'bring_to_front' defaults to false to preserve user terminal visibility. Set true only if explicit physical foreground visibility is strictly required.

            Supported action types in 'actions' array:
            - click: {"type": "click", "element_query": "button title or search"} or {"type": "click", "x": 100, "y": 200, "button": "left|right", "count": 1}
            - type: {"type": "type", "element_query": "input name or placeholder", "text": "content"} or {"type": "type", "text": "content", "x": 100, "y": 200}
            - key: {"type": "key", "key": "Return|Tab|Escape|Space|Backspace|...", "modifiers": ["cmd", "shift", "alt", "ctrl"]}
            - wait: {"type": "wait", "duration_ms": 500}
            - hover / move: {"type": "hover", "x": 100, "y": 200}
            - find / inspect: {"type": "find", "query": "text to locate", "role": "optional AXRole"} (Locates UI element and returns coordinates & bounds)
            - screenshot: {"type": "screenshot"} (Captures current display/target window status)
            - launchapp: {"type": "launchapp", "identifier": "Safari"}
            - activatewindow: {"type": "activatewindow", "window_id": "123"}
            """,
            inputSchema: ToolInputSchema(
                properties: [
                    "actions": ToolInputProperty(type: .array, description: "Ordered array of interaction/inspection action objects to execute in sequence"),
                    "intent_hint": ToolInputProperty(type: .string, description: "High-level user intent or goal for this action batch (e.g. 'Type query and search in Safari')"),
                    "target_app": ToolInputProperty(type: .string, description: "Target application name or bundle ID to scope interaction within (e.g. 'Safari' or 'TextEdit')"),
                    "target_window": ToolInputProperty(type: .string, description: "Target window title substring to scope interaction within"),
                    "bring_to_front": ToolInputProperty(type: .boolean, description: "Whether to raise target window to frontmost. Default is FALSE to preserve user terminal/TUI visibility"),
                    "window_relative": ToolInputProperty(type: .boolean, description: "Whether x, y coordinates are relative to the target window origin (default: true if target attached)")
                ],
                required: ["actions"]
            ),
            capability: ToolCapability([.userInteraction])
        )
    }

    public func resource(for arguments: String, profile: ExecutionProfile) throws -> String {
        "computer://batch"
    }

    public func execute(arguments: String, profile: ExecutionProfile) async throws -> String {
        let clock = ContinuousClock()
        let batchStartTime = clock.now

        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actionList = json["actions"] as? [[String: Any]] else {
            throw CoreError(code: .toolArgumentInvalid, message: "Missing or invalid 'actions' array parameter")
        }

        let intentHint = json["intent_hint"] as? String
        var targetApp = (json["target_app"] as? String) ?? (json["app"] as? String) ?? (json["app_name"] as? String)
        let targetWindow = json["target_window"] as? String
        let bringToFront = (json["bring_to_front"] as? Bool) ?? false

        // 自动从 intent_hint 或参数文本中推导目标应用，防止模型因漏传 target_app 误将前台终端自身作为目标
        let environment = self.customEnvironment ?? DesktopEnvironment.makeCurrentPlatformDefault()
        if targetApp == nil && targetWindow == nil {
            let combinedHint = "\(intentHint ?? "") \(arguments)".lowercased()
            let runningApps = (try? await environment.applications?.listRunningApplications()) ?? []
            let ignoredNames: Set<String> = ["ghostty", "terminal", "iterm2", "alacritty", "lingxiagent", "lingxitui", "cursor", "code"]
            let commonAppMappings: [String: [String]] = [
                "safari": ["safari", "safari 浏览器", "com.apple.safari"],
                "chrome": ["chrome", "google chrome", "com.google.chrome"],
                "finder": ["finder", "访达", "com.apple.finder"],
                "notes": ["notes", "备忘录", "com.apple.notes"],
                "mail": ["mail", "邮件", "com.apple.mail"]
            ]
            for (key, aliases) in commonAppMappings {
                if combinedHint.contains(key) || aliases.contains(where: { combinedHint.contains($0) }) {
                    if let app = runningApps.first(where: { a in
                        let b = a.identifier.lowercased()
                        let n = a.name.lowercased()
                        return aliases.contains(b) || aliases.contains(n) || aliases.contains(where: { b.contains($0) || n.contains($0) })
                    }) {
                        targetApp = app.name.isEmpty ? key : app.name
                        break
                    }
                }
            }
            if targetApp == nil {
                if let matchedApp = runningApps.first(where: { app in
                    let name = app.name.lowercased()
                    guard !name.isEmpty, !ignoredNames.contains(name) else { return false }
                    return combinedHint.contains(name)
                }) {
                    targetApp = matchedApp.name
                }
            }
        }

        let windowRelative = (json["window_relative"] as? Bool) ?? (targetApp != nil || targetWindow != nil)
        var stepSummaries: [String] = []

        // 1. 目标应用/窗口范围锁定 (Target Scoping & Isolation)
        var attachedWindow: WindowInfo? = nil
        if targetApp != nil || targetWindow != nil {
            let attachStart = clock.now
            if let windowBackend = environment.windows {
                attachedWindow = try await windowBackend.attachTarget(query: TargetAttachmentQuery(
                    appName: targetApp,
                    bundleID: targetApp,
                    windowTitle: targetWindow,
                    bringToFront: bringToFront
                ))
            }
            let attachMs = String(format: "%.1f", Double(attachStart.duration(to: clock.now).components.attoseconds) / 1_000_000_000_000_000.0)
            let winTitle = attachedWindow?.title ?? targetWindow ?? targetApp ?? "Unknown"
            let boundsDesc = attachedWindow.map { "bounds: (\(Int($0.bounds.origin.x)), \(Int($0.bounds.origin.y)), \(Int($0.bounds.width)), \(Int($0.bounds.height)))" } ?? "no window bounds"
            let modeDesc = bringToFront ? "Foreground focus" : "Non-disruptive background mode (TUI visibility preserved)"
            stepSummaries.append("Target Scope [\(winTitle)]: \(attachMs)ms (\(modeDesc), \(boundsDesc))")
        }

        var targetHandle: DesktopTargetHandle? = attachedWindow?.toTargetHandle(revision: 1)

        #if os(macOS)
        if let attachedWindow, bringToFront {
            await MainActor.run {
                DarwinVirtualPointerOverlay.shared.attachTargetBounds(attachedWindow.bounds)
            }
        }
        #endif

        defer {
            #if os(macOS)
            if bringToFront {
                Task { @MainActor in
                    DarwinVirtualPointerOverlay.shared.attachTargetBounds(nil)
                }
            }
            #endif
        }

        let winOriginX = (windowRelative ? attachedWindow?.bounds.origin.x : 0.0) ?? 0.0
        let winOriginY = (windowRelative ? attachedWindow?.bounds.origin.y : 0.0) ?? 0.0

        let validActionTypes: Set<String> = [
            "click", "click_element", "type", "key", "keypress", "wait", "hover", "move",
            "find", "inspect", "locate", "screenshot", "capture", "launchapp", "launch_app",
            "activatewindow", "activate_window", "drag"
        ]

        for item in actionList {
            guard let rawType = item["type"] as? String else {
                throw CoreError(code: .toolArgumentInvalid, message: "Action object missing required 'type' field")
            }
            let normType = rawType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard validActionTypes.contains(normType) else {
                throw CoreError(
                    code: .toolArgumentInvalid,
                    message: "No recognized actions found in 'actions' array or unrecognized action type '\(rawType)'. Supported action types: click, type, key, wait, hover, find, inspect, screenshot, launchapp, activatewindow."
                )
            }
        }

        struct PendingInteractionStep {
            let action: InteractionAction
            let description: String
        }

        var interactionSteps: [PendingInteractionStep] = []
        var stepIndex = 1
        var hasFailedStep = false

        for item in actionList {
            let rawType = item["type"] as! String
            let type = rawType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

            var x = (item["x"] as? NSNumber)?.doubleValue
            var y = (item["y"] as? NSNumber)?.doubleValue

            // 处理纯观察/定位动作 (find / inspect / locate)
            if type == "find" || type == "inspect" || type == "locate" {
                let inspectStart = clock.now
                let query = (item["query"] as? String) ?? (item["element_query"] as? String) ?? (item["element_name"] as? String) ?? ""
                var foundDesc = "Query '\(query)' was empty"
                var foundSuccess = false
                if !query.isEmpty, let a11y = environment.accessibility {
                    let scope: AccessibilityScope = (targetHandle != nil) ? .window(targetHandle!) : ((targetApp != nil) ? .application(bundleOrName: targetApp!) : .activeWindow)
                    
                    // 单步超时保护：最大等待 1.5 秒，杜绝 Accessibility IPC 挂死
                    let matchedNode: AccessibilityNodeSnapshot? = await withTaskGroup(of: AccessibilityNodeSnapshot?.self) { group in
                        group.addTask {
                            try? await a11y.findElement(matching: query, role: item["role"] as? String, scope: scope)
                        }
                        group.addTask {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            return nil
                        }
                        let first = await group.next() ?? nil
                        group.cancelAll()
                        return first
                    }

                    if let matchedNode, let bounds = matchedNode.bounds {
                        let cx = bounds.origin.x + bounds.width / 2.0
                        let cy = bounds.origin.y + bounds.height / 2.0
                        foundDesc = "Found '\(matchedNode.name ?? query)' (role: \(matchedNode.role)) at center (\(String(format: "%.1f", cx)), \(String(format: "%.1f", cy))), bounds: (\(Int(bounds.origin.x)), \(Int(bounds.origin.y)), \(Int(bounds.width)), \(Int(bounds.height)))"
                        foundSuccess = true
                    } else {
                        #if os(macOS)
                        if let winID = attachedWindow?.id {
                            let visionHit = await withTaskGroup(of: VisualElementSnapshot?.self) { group in
                                group.addTask {
                                    if let hit = try? await DarwinVisionOCRBackend.shared.findElement(matching: query, windowID: winID, windowBounds: attachedWindow?.bounds) {
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
                            if let visionHit {
                                let cx = visionHit.bounds.origin.x + visionHit.bounds.width / 2.0
                                let cy = visionHit.bounds.origin.y + visionHit.bounds.height / 2.0
                                foundDesc = "Found '\(visionHit.text)' via Native Vision OCR at center (\(String(format: "%.1f", cx)), \(String(format: "%.1f", cy))), bounds: (\(Int(visionHit.bounds.origin.x)), \(Int(visionHit.bounds.origin.y)), \(Int(visionHit.bounds.width)), \(Int(visionHit.bounds.height)))"
                                foundSuccess = true
                            } else {
                                foundDesc = "Element '\(query)' not found in \(targetApp ?? "target window")"
                            }
                        } else {
                            foundDesc = "Element '\(query)' not found in \(targetApp ?? "current window")"
                        }
                        #else
                        foundDesc = "Element '\(query)' not found in \(targetApp ?? "current window") accessibility tree"
                        #endif
                    }
                }
                let inspectMs = String(format: "%.1f", Double(inspectStart.duration(to: clock.now).components.attoseconds) / 1_000_000_000_000_000.0)
                let outcomeLabel = foundSuccess ? "matched" : "not found"
                stepSummaries.append("Step \(stepIndex) [Find / Inspect \"\(query)\"]: \(inspectMs)ms (\(outcomeLabel) - \(foundDesc))")
                stepIndex += 1
                continue
            }

            // 处理截屏动作 (screenshot / capture)：优先目标窗口精准捕获（不依赖前台是否遮挡），产物写入本地并生成稳定 blobRef
            if type == "screenshot" || type == "capture" {
                let shotStart = clock.now
                if let captureBackend = environment.capture {
                    do {
                        let frame: CapturedFrame
                        let targetDesc: String
                        if let handle = targetHandle {
                            frame = try await captureBackend.captureWindow(handle: handle)
                            let title = attachedWindow?.title ?? targetApp ?? "Window \(handle.windowID)"
                            targetDesc = "Target window '\(title)'"
                        } else {
                            let sources = (try? await captureBackend.availableSources()) ?? []
                            guard let mainSource = sources.first(where: { $0.isDisplay }) ?? sources.first else {
                                throw ActionExecutionError.inputInjectionFailed(reason: "No available display capture source found")
                            }
                            frame = try await captureBackend.captureFrame(source: mainSource, cropRect: nil)
                            targetDesc = "Main display"
                        }
                        let shotMs = String(format: "%.1f", Double(shotStart.duration(to: clock.now).components.attoseconds) / 1_000_000_000_000_000.0)
                        let digest = LingXiPlatform.crypto.sha256Hex(frame.data)
                        let contentRef = "content://sha256:\(digest)"
                        let contentDir = CoreStorageLayout.current.content
                        try? FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
                        try? frame.data.write(to: contentDir.appendingPathComponent("\(digest).png"))
                        stepSummaries.append("Step \(stepIndex) [Screenshot]: \(shotMs)ms (\(targetDesc) captured: \(frame.pixelWidth)x\(frame.pixelHeight) px, scale \(frame.scaleFactor), contentRef: \(contentRef))")
                    } catch {
                        let shotMs = String(format: "%.1f", Double(shotStart.duration(to: clock.now).components.attoseconds) / 1_000_000_000_000_000.0)
                        stepSummaries.append("Step \(stepIndex) [Screenshot]: FAILED (\(shotMs)ms - Screen capture failed: \(error))")
                        hasFailedStep = true
                    }
                } else {
                    stepSummaries.append("Step \(stepIndex) [Screenshot]: FAILED (Screen capture capability unsupported on current platform)")
                    hasFailedStep = true
                }
                stepIndex += 1
                continue
            }

            // 精度优化：支持通过无障碍树真实定位与后台无感直接操控 (AX Direct Manipulation)
            let elementQuery = (item["element_query"] as? String) ?? (item["element_name"] as? String)
            var matchedDesc: String? = nil
            var axDirectHandled = false
            var elementLookupFailed = false

            if let query = elementQuery, !query.isEmpty {
                let locateStart = clock.now
                if let a11y = environment.accessibility {
                    let scope: AccessibilityScope = (targetHandle != nil) ? .window(targetHandle!) : ((targetApp != nil) ? .application(bundleOrName: targetApp!) : .activeWindow)
                    if let matchedNode = try? await a11y.findElement(matching: query, role: item["role"] as? String, scope: scope) {
                        if let bounds = matchedNode.bounds {
                            x = bounds.origin.x + bounds.width / 2.0
                            y = bounds.origin.y + bounds.height / 2.0
                        }

                        // 后台无感操控：仅针对原生无障碍节点（非 VisualElement）尝试后台直接操作
                        if !bringToFront && matchedNode.role != "VisualElement" {
                            if type == "type" {
                                let text = (item["text"] as? String) ?? ""
                                if (try? await a11y.performAction(nodeID: matchedNode.id, action: .setValue(text))) != nil {
                                    let directMs = String(format: "%.1f", Double(locateStart.duration(to: clock.now).components.attoseconds) / 1_000_000_000_000_000.0)
                                    stepSummaries.append("Step \(stepIndex) [Type \"\(text)\" into '\(query)']: \(directMs)ms (Background AX direct injection - zero window occlusion)")
                                    stepIndex += 1
                                    axDirectHandled = true
                                    continue
                                }
                            } else if type == "click" || type == "click_element" {
                                if (try? await a11y.performAction(nodeID: matchedNode.id, action: .press)) != nil {
                                    let directMs = String(format: "%.1f", Double(locateStart.duration(to: clock.now).components.attoseconds) / 1_000_000_000_000_000.0)
                                    stepSummaries.append("Step \(stepIndex) [Click '\(query)']: \(directMs)ms (Background AX direct press - zero window occlusion)")
                                    stepIndex += 1
                                    axDirectHandled = true
                                    continue
                                }
                            }
                        }

                        let locateMs = String(format: "%.1f", Double(locateStart.duration(to: clock.now).components.attoseconds) / 1_000_000_000_000_000.0)
                        if let x, let y {
                            let sourceKind = (matchedNode.role == "VisualElement") ? "Native Vision OCR" : "Accessibility Tree"
                            matchedDesc = "auto-located '\(query)' via \(sourceKind) at (\(String(format: "%.1f", x)), \(String(format: "%.1f", y))) in \(locateMs)ms"
                        }
                    } else {
                        elementLookupFailed = true
                    }
                }
            } else if let rawX = x, let rawY = y, windowRelative {
                x = winOriginX + rawX
                y = winOriginY + rawY
            }

            if axDirectHandled { continue }

            // 若显式指定了 element_query 但未能在无障碍或视觉树中命中，给出当前窗口的候选文字建议，并严格标记失败
            if elementLookupFailed, let query = elementQuery {
                #if os(macOS)
                var visibleSuggestion = ""
                if let elements = try? await DarwinVisionOCRBackend.shared.recognizeElements(windowID: attachedWindow?.id, windowBounds: attachedWindow?.bounds), !elements.isEmpty {
                    let sampleList = elements.prefix(8).map { "\"\($0.text)\"" }.joined(separator: ", ")
                    visibleSuggestion = " Visible candidates in window: [\(sampleList)]"
                }
                stepSummaries.append("Step \(stepIndex) [\(type.capitalized) '\(query)']: FAILED (Element not found in accessibility or visual tree.\(visibleSuggestion))")
                #else
                stepSummaries.append("Step \(stepIndex) [\(type.capitalized) '\(query)']: FAILED (Element not found in accessibility tree)")
                #endif
                hasFailedStep = true
                stepIndex += 1
                continue
            }

            // 后台安全防误触契约（Round 4 审计 #17 & #30）：
            // 若为后台模式 (bringToFront == false) 且 AX direct 未能处理，
            // 严禁向屏幕坐标发送全局 CGEvent 硬件鼠标/拖拽/输入，杜绝击穿到桌面顶层覆盖窗口！
            if !bringToFront, (targetApp != nil || targetWindow != nil || attachedWindow != nil),
               (type == "click" || type == "click_element" || type == "type" || type == "hover" || type == "move" || type == "drag") {
                let winTitle = attachedWindow?.title ?? targetApp ?? "target window"
                stepSummaries.append("Step \(stepIndex) [\(type.capitalized)]: FAILED (foregroundRequired: Coordinate actions cannot be safely injected to background window '\(winTitle)' without risk of hitting occluding windows. Please set 'bring_to_front: true' to perform foreground actions, or use semantic 'element_query' for direct background AX manipulation.)")
                hasFailedStep = true
                stepIndex += 1
                continue
            }

            let targetPos: TargetPosition? = {
                if let x, let y {
                    return TargetPosition(x: x, y: y, space: .logicalPoint(displayID: "main"))
                }
                return nil
            }()

            switch type {
            case "click", "click_element":
                // 审计报告 #18：禁止在缺少 target 时默认点击 (0,0)（macOS 菜单栏苹果图标）
                guard let targetPos else {
                    stepSummaries.append("Step \(stepIndex) [Click]: FAILED (Missing target: click requires element_query, ref, or valid x/y coordinates. Refused to fallback to (0,0))")
                    hasFailedStep = true
                    stepIndex += 1
                    continue
                }
                let buttonStr = (item["button"] as? String)?.lowercased() ?? "left"
                let button: PointerButton = (buttonStr == "right" ? .right : (buttonStr == "middle" ? .middle : .left))
                let count = (item["count"] as? NSNumber)?.intValue ?? 1
                let target: ActionTarget = .coordinate(targetPos)
                let prim = CommonInteractionPrimitive.click(target: target, button: button, count: count)
                let coordStr = "(\(String(format: "%.1f", targetPos.x)), \(String(format: "%.1f", targetPos.y)))"
                let locNote = matchedDesc.map { " [\($0)]" } ?? ""
                interactionSteps.append(PendingInteractionStep(
                    action: .desktop(.primitive(prim)),
                    description: "Click \(buttonStr) at \(coordStr)\(locNote)"
                ))

            case "move", "hover":
                guard let targetPos else {
                    stepSummaries.append("Step \(stepIndex) [Hover]: FAILED (Missing x/y coordinates)")
                    hasFailedStep = true
                    stepIndex += 1
                    continue
                }
                let prim = CommonInteractionPrimitive.hover(target: .coordinate(targetPos))
                let coordStr = "(\(String(format: "%.1f", targetPos.x)), \(String(format: "%.1f", targetPos.y)))"
                interactionSteps.append(PendingInteractionStep(
                    action: .desktop(.primitive(prim)),
                    description: "Hover cursor to \(coordStr)"
                ))

            case "type":
                let text = (item["text"] as? String) ?? ""
                let target = targetPos.map { ActionTarget.coordinate($0) }
                let prim = CommonInteractionPrimitive.type(text: text, target: target)
                let coordDesc = targetPos.map { " at (\(String(format: "%.1f", $0.x)), \(String(format: "%.1f", $0.y)))" } ?? ""
                interactionSteps.append(PendingInteractionStep(
                    action: .desktop(.primitive(prim)),
                    description: "Type \"\(text)\"\(coordDesc)"
                ))

            case "key", "keypress":
                let key = (item["key"] as? String) ?? "Return"
                let modsArray = (item["modifiers"] as? [String]) ?? []
                var mods = KeyModifiers()
                for m in modsArray {
                    switch m.lowercased() {
                    case "cmd", "command": mods.insert(.command)
                    case "shift": mods.insert(.shift)
                    case "alt", "option": mods.insert(.alt)
                    case "ctrl", "control": mods.insert(.control)
                    default: break
                    }
                }
                let prim = CommonInteractionPrimitive.keyPress(key: key, modifiers: mods)
                let modStr = modsArray.isEmpty ? "" : "+\(modsArray.joined(separator: "+"))"
                interactionSteps.append(PendingInteractionStep(
                    action: .desktop(.primitive(prim)),
                    description: "Press key [\(key)\(modStr)]"
                ))

            case "wait":
                let ms = (item["duration_ms"] as? NSNumber)?.intValue ?? 500
                let prim = CommonInteractionPrimitive.wait(condition: .duration(milliseconds: ms))
                interactionSteps.append(PendingInteractionStep(
                    action: .desktop(.primitive(prim)),
                    description: "Wait \(ms)ms"
                ))

            case "launchapp", "launch_app":
                let identifier = (item["identifier"] as? String) ?? ""
                if !identifier.isEmpty {
                    interactionSteps.append(PendingInteractionStep(
                        action: .desktop(.launchApp(identifier: identifier)),
                        description: "Launch app '\(identifier)'"
                    ))
                } else {
                    stepSummaries.append("Step \(stepIndex) [LaunchApp]: FAILED (Missing 'identifier' parameter)")
                    hasFailedStep = true
                    stepIndex += 1
                }

            case "activatewindow", "activate_window":
                let windowID = (item["window_id"] as? String) ?? ""
                if !windowID.isEmpty {
                    interactionSteps.append(PendingInteractionStep(
                        action: .desktop(.activateWindow(windowID: windowID)),
                        description: "Activate window id '\(windowID)'"
                    ))
                } else {
                    stepSummaries.append("Step \(stepIndex) [ActivateWindow]: FAILED (Missing 'window_id' parameter)")
                    hasFailedStep = true
                    stepIndex += 1
                }

            default:
                stepSummaries.append("Step \(stepIndex) [\(type)]: FAILED (Unknown or unsupported action type '\(type)')")
                hasFailedStep = true
                stepIndex += 1
            }
        }

        // 若完全无任何可执行/可观察动作且未指定目标附加，报错并给出合法格式指引
        guard !interactionSteps.isEmpty || !stepSummaries.isEmpty else {
            throw CoreError(
                code: .toolArgumentInvalid,
                message: "No recognized actions found in 'actions' array. Supported action types: click, type, key, wait, hover, find, inspect, screenshot, launchapp, activatewindow."
            )
        }

        var executionSuccess = true
        var failureMessage: String? = nil

        // 前台坐标输入防遮挡二次确认（审计报告 #19 & #31）：
        // 在批量硬件输入执行前，重新验证 exact target window 存在、刷新 bounds 并确保置顶
        if bringToFront, let winBackend = environment.windows, let currentHandle = targetHandle {
            let windows = (try? await winBackend.listWindows()) ?? []
            if let freshWin = windows.first(where: { $0.id == String(currentHandle.windowID) }) {
                try? await winBackend.focusWindow(id: freshWin.id)
                targetHandle = freshWin.toTargetHandle(revision: currentHandle.revision + 1)
                attachedWindow = freshWin
            } else {
                stepSummaries.append("Step \(stepIndex) [Pre-Flight Validation]: FAILED (staleTarget: Target window \(currentHandle.windowID) disappeared or closed)")
                hasFailedStep = true
                interactionSteps.removeAll()
            }
        }

        if !interactionSteps.isEmpty {
            let interactionActions = interactionSteps.map(\.action)
            let batch = ActionBatch(
                actions: interactionActions,
                stopOnFailure: true,
                intentHint: intentHint
            )

            #if os(macOS)
            let (realDisplayBounds, realScaleFactor): (CoordinateRect, Double) = {
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
            }()
            #else
            let (realDisplayBounds, realScaleFactor): (CoordinateRect, Double) = (
                CoordinateRect(
                    origin: TargetPosition(x: 0, y: 0, space: .logicalPoint(displayID: "main")),
                    width: 1920,
                    height: 1080
                ),
                1.0
            )
            #endif

            let initialObservation = Observation(
                sessionID: EnvironmentSessionID(rawValue: "desktop-session"),
                version: 1,
                source: .desktop(displayID: "main", activeWindowID: attachedWindow?.id),
                elements: [:],
                viewportBounds: attachedWindow?.bounds ?? realDisplayBounds,
                displayMetrics: DisplayMetrics(
                    displayID: "main",
                    scaleFactor: realScaleFactor,
                    bounds: realDisplayBounds
                )
            )

            let executor = ActionBatchExecutor()
            let result = try await executor.execute(
                batch: batch,
                environment: environment,
                currentObservation: initialObservation,
                riskEvaluator: InteractionRiskAdvisor()
            )

            for (idx, step) in interactionSteps.enumerated() {
                let status = idx < result.completedStepCount ? "completed" : (idx == result.completedStepCount && !result.succeeded ? "failed" : "skipped")
                let msStr: String = {
                    if idx < result.stepDurationsMs.count {
                        return String(format: "%.1f", result.stepDurationsMs[idx])
                    }
                    return "0.0"
                }()
                stepSummaries.append("Step \(stepIndex) [\(step.description)]: \(msStr)ms (\(status))")
                stepIndex += 1
            }

            executionSuccess = result.succeeded
            failureMessage = result.failureReason
        }

        let totalBatchMs = String(format: "%.1f", Double(batchStartTime.duration(to: clock.now).components.attoseconds) / 1_000_000_000_000_000.0)

        // 审计报告 #19：严格区分工具调用与动作结果，有任何步骤失败则整体标记为 FAILED
        let overallSuccess = executionSuccess && !hasFailedStep
        var output = "Action Batch Execution: \(overallSuccess ? "SUCCESS" : "FAILED")\n"
        let totalActionSteps = max(interactionSteps.count, stepSummaries.count)
        output += "Completed Steps: \(overallSuccess ? totalActionSteps : 0) / \(totalActionSteps)\n"
        output += "Total Elapsed: \(totalBatchMs)ms\n"
        output += "Executed Steps: \(stepSummaries.count)\n\n"
        output += "Step Timing Breakdown:\n"
        for summary in stepSummaries {
            output += "- \(summary)\n"
        }
        if let failureMessage {
            output += "\nFailure Reason: \(failureMessage)\n"
        }
        if interactionSteps.isEmpty && !stepSummaries.isEmpty {
            output += "\n💡 PERFORMANCE NOTICE: Do NOT execute further standalone inspect turns! To avoid multi-roundtrip freezing, directly send your remaining actions ('type', 'click', 'wait') combined with 'element_query' in ONE single batch.\n"
        }
        output += "\nSummary: Desktop interaction completed safely under target attachment isolation and virtual pointer overlay."

        return output
    }
}

/// 交互动作风险建议器（审计报告 #25 规范：输出风险研判建议，不伪造 Evaluator 假控制）
public struct InteractionRiskAdvisor: InteractionRiskEvaluating {
    public init() {}
    public func evaluateRisk(
        actions: [InteractionAction],
        observation: Observation?,
        origin: String?,
        intentHint: String?
    ) async -> InteractionRiskCategory {
        .low
    }
}
