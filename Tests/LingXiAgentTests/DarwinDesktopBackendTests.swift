import Testing
import Foundation
@testable import LingXiProtocol
@testable import LingXiPlatform
@testable import LingXiCore

#if os(macOS)
import ApplicationServices
@Suite("macOS Darwin Desktop Backend Tests")
struct DarwinDesktopBackendTests {

    @Test("DarwinCapabilityProbe dynamically probes system TCC and subsystems")
    func testDarwinCapabilityProbe() async throws {
        let probe = DarwinCapabilityProbe()
        let snapshot = await probe.probe()

        // 验证返回的能力状态合法
        switch snapshot.capture {
        case .available, .requiresAuthorization, .partial, .temporarilyUnavailable, .unsupported:
            break
        }

        switch snapshot.accessibility {
        case .available, .requiresAuthorization, .partial, .temporarilyUnavailable, .unsupported:
            break
        }

        #expect(snapshot.windowManagement == .available)
        #expect(snapshot.applicationManagement == .available)
        #expect(snapshot.clipboard == .available)
    }

    @Test("DesktopEnvironment dynamically manages capabilities and stale states")
    func testDesktopEnvironmentManagement() async throws {
        let env = DesktopEnvironment.makeDarwinDefault()

        #expect(env.capture != nil)
        #expect(env.accessibility != nil)
        #expect(env.input != nil)
        #expect(env.windows != nil)
        #expect(env.applications != nil)
        #expect(env.clipboard != nil)

        // 初始快照预检
        let snapshot1 = await env.refreshCapabilities()
        #expect(snapshot1.windowManagement == .available)

        // 触发状态失效
        await env.invalidateCapabilities()

        // preflight 应当感知失效并自动刷新
        let snapshot2 = await env.preflightSnapshot()
        #expect(snapshot2.windowManagement == .available)
    }

    @Test("DarwinInputBackend satisfies safe neutralization contract")
    func testDarwinInputBackendNeutralization() async throws {
        let input = DarwinInputBackend()
        // 验证 neutralize 不抛错且平稳执行
        await input.neutralize()
    }

    @Test("DarwinClipboardBackend writes and reads plain text faithfully")
    func testDarwinClipboardReadWrite() async throws {
        let clipboard = DarwinClipboardBackend()
        let original = try? await clipboard.readText()

        let testContent = "lingxi-test-\(UUID().uuidString)"
        try await clipboard.writeText(testContent)

        let readBack = try await clipboard.readText()
        #expect(readBack == testContent)

        // 恢复原始剪贴板
        if let original {
            try? await clipboard.writeText(original)
        }
    }

    @Test("DarwinWindowBackend lists visible windows with coordinate bounds")
    func testDarwinWindowListing() async throws {
        let windows = DarwinWindowBackend()
        let list = try await windows.listWindows()
        // 在 GUI 环境下通常有窗口存在；在 headless CI 环境下可能为空，但不应抛错
        for win in list {
            #expect(!win.id.isEmpty)
            #expect(win.bounds.width >= 0)
            #expect(win.bounds.height >= 0)
        }
    }

    @Test("Live Computer Use demonstration on macOS desktop")
    func testLiveComputerUseDemonstration() async throws {
        guard ProcessInfo.processInfo.environment["LINGXI_RUN_LIVE_DESKTOP"] == "1" else {
            return
        }
        let env = DesktopEnvironment.makeCurrentPlatformDefault()
        let snapshot = await env.refreshCapabilities()

        print("\n🦊 [Computer Use] === macOS 宿主环境实时探针 ===")
        print("📸 Capture (屏幕捕获): \(snapshot.capture)")
        print("♿️ Accessibility (无障碍): \(snapshot.accessibility)")
        print("⌨️ Input (事件注入): \(snapshot.input)")
        print("🪟 Windows (窗口管理): \(snapshot.windowManagement)")
        print("📱 Apps (应用管理): \(snapshot.applicationManagement)")
        print("📋 Clipboard (剪贴板): \(snapshot.clipboard)")

        // 1. 枚举前台活跃窗口
        if let windowsBackend = env.windows {
            let windows = try await windowsBackend.listWindows()
            print("🪟 找到当前可见窗口数: \(windows.count)")
            for win in windows.prefix(5) {
                print("   - 窗口 ID: \(win.id), 应用: \(win.bundleIdentifier ?? "未知"), 标题: \"\(win.title ?? "")\", 区域: (\(Int(win.bounds.origin.x)), \(Int(win.bounds.origin.y)), \(Int(win.bounds.width))x\(Int(win.bounds.height)))")
            }
        }

        // 2. 屏幕捕获与保存真实帧
        if let captureBackend = env.capture, case .available = snapshot.capture {
            let sources = try await captureBackend.availableSources()
            if let mainDisplay = sources.first(where: { $0.isDisplay }) {
                print("📸 正在捕获主屏幕真实画面: \(mainDisplay.name)...")
                if let frame = try? await captureBackend.captureFrame(source: mainDisplay, cropRect: NormalizedRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)) {
                    let tempArtifact = FileManager.default.temporaryDirectory.appendingPathComponent("live_mac_screen_capture_\(UUID().uuidString).png")
                    defer { try? FileManager.default.removeItem(at: tempArtifact) }
                    try? frame.data.write(to: tempArtifact)
                    print("✅ 真实屏幕捕获并落盘成功！尺寸: \(frame.pixelWidth)x\(frame.pixelHeight), 大小: \(frame.data.count) bytes")
                    print("🖼️ 临时截图路径: \(tempArtifact.path)")
                } else {
                    print("ℹ️ 屏幕捕获受系统权限或安全限制保护，平稳降级跳过。")
                }
            }
        }

        // 3. 鼠标交互慢动作演练：大范围轨迹游弋与醒目点击波纹
        if let inputBackend = env.input {
            if case .available = snapshot.input {
                let trackPoints = [
                    (x: 450.0, y: 300.0, name: "左侧起点"),
                    (x: 850.0, y: 300.0, name: "右上游弋"),
                    (x: 650.0, y: 550.0, name: "下方俯冲"),
                    (x: 650.0, y: 380.0, name: "屏幕中心核心点")
                ]

                print("🖱️ [慢动作模式启动] 正在以优雅缓动轨迹游弋，让主人看清楚虚拟小狐狸光标...")
                for pt in trackPoints {
                    print("   -> 移动至: \(pt.name) (\(Int(pt.x)), \(Int(pt.y)))")
                    try await inputBackend.injectPointer(event: PointerInputEvent(
                        position: LogicalPoint(x: pt.x, y: pt.y),
                        kind: .move
                    ))
                    // 慢动作悬停：每次移动后停留 600ms 供主人看清
                    try? await Task.sleep(nanoseconds: 600_000_000)
                }

                // 在中心点模拟第一次左键点击（橙青扩散大光圈）
                print("💥 在核心位置触发第 1 次左键点击涟漪！")
                try await inputBackend.injectPointer(event: PointerInputEvent(
                    position: LogicalPoint(x: 650.0, y: 380.0),
                    kind: .click(button: .left, count: 1)
                ))
                try? await Task.sleep(nanoseconds: 600_000_000)

                // 触发第 2 次右键点击（紫色扩散大光圈）
                print("💥 在核心位置触发第 2 次右键点击涟漪！")
                try await inputBackend.injectPointer(event: PointerInputEvent(
                    position: LogicalPoint(x: 650.0, y: 380.0),
                    kind: .click(button: .right, count: 1)
                ))

                // 原地静候 2.5 秒，让主人尽情看清小狐狸虚拟光标的细节与悬浮效果！
                print("✨ 动作完成！光标在屏幕中央保持停留 2.5 秒供主人观赏...")
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
            // 退出保护：按键强中立化 + 平滑淡出
            await inputBackend.neutralize()
            print("🛡️ [安全中立化] 已释放全部按键状态，虚拟光标优雅淡出。")
        }
    }

    @Test("Find Untitled document and type Antigravity Computer Use via ComputerBatchTool with Target Attachment")
    func testTypeIntoUntitledDocument() async throws {
        guard ProcessInfo.processInfo.environment["LINGXI_RUN_LIVE_DESKTOP"] == "1" else {
            return
        }
        let env = DesktopEnvironment.makeCurrentPlatformDefault()
        guard let windowsBackend = env.windows else { return }

        let windows = try await windowsBackend.listWindows()
        let hasUntitled = windows.contains {
            let title = $0.title ?? ""
            let app = $0.bundleIdentifier ?? ""
            return title.contains("未命名") || title.contains("Untitled") || app.contains("TextEdit") || app.contains("文本编辑")
        }

        if !hasUntitled {
            print("🚀 主动唤醒并拉起「文本编辑」新建未命名文档供演练...")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", "tell application \"TextEdit\" to activate", "-e", "tell application \"TextEdit\" to make new document"]
            try? proc.run()
            proc.waitUntilExit()
            try? await Task.sleep(nanoseconds: 800_000_000)
        }

        print("\n🎯 [Target Attachment] 正在劫持并锁定「未命名」文本窗口...")

        let payload = """
        {
            "intent_hint": "Safely type multiple Antigravity Computer Use lines into Untitled document in background",
            "target_app": "TextEdit",
            "target_window": "未命名",
            "bring_to_front": false,
            "window_relative": true,
            "actions": [
                {
                    "type": "move",
                    "x": 200,
                    "y": 150
                },
                {
                    "type": "click",
                    "button": "left",
                    "count": 1,
                    "x": 200,
                    "y": 150
                },
                {
                    "type": "wait",
                    "duration_ms": 100
                },
                {
                    "type": "type",
                    "text": "Antigravity Computer Use"
                },
                {
                    "type": "key",
                    "key": "Return"
                },
                {
                    "type": "type",
                    "text": "Antigravity Computer Use"
                },
                {
                    "type": "key",
                    "key": "Return"
                },
                {
                    "type": "type",
                    "text": "Antigravity Computer UseAntigravity Computer Use"
                },
                {
                    "type": "key",
                    "key": "Return"
                }
            ]
        }
        """

        let tool = ComputerBatchTool()
        let result = try await tool.execute(arguments: payload, profile: .workspace)
        print("🎉 [执行结果]:\n\(result)")
    }

    @Test("Live Browser Use demonstration with Target Attachment and Semantic Element Precision")
    func testLiveBrowserUseDemonstration() async throws {
        guard ProcessInfo.processInfo.environment["LINGXI_RUN_LIVE_DESKTOP"] == "1" else {
            return
        }
        let env = DesktopEnvironment.makeCurrentPlatformDefault()
        guard let windowsBackend = env.windows else { return }

        // 1. 自动劫持锁定包含 Browser Demo 的 Safari 窗口
        let query = TargetAttachmentQuery(appName: "Safari", windowTitle: "LingXiAgent")
        guard let targetWin = try await windowsBackend.attachTarget(query: query) else {
            print("⚠️ 未找到演示浏览器窗口，跳过浏览器演练。")
            return
        }

        print("\n🌐 [Browser Use 劫持成功] 锁定目标窗口: \"\(targetWin.title ?? "")\", App: \(targetWin.bundleIdentifier ?? "")")
        print("📐 真实物理 Bounds: (\(Int(targetWin.bounds.origin.x)), \(Int(targetWin.bounds.origin.y)), \(Int(targetWin.bounds.width))x\(Int(targetWin.bounds.height)))")

        // 2. 检索真实可交互控件节点（使用原生无障碍树定位真实的几何 Bounds）
        var inputCenter = LogicalPoint(x: 894.5, y: 689.5)
        var buttonCenter = LogicalPoint(x: 1164.0, y: 689.5)

        if let a11y = env.accessibility {
            if let buttonNode = try? await a11y.findElement(matching: "执行检索", role: "AXButton", scope: .application(bundleOrName: "Safari")),
               let bBounds = buttonNode.bounds {
                buttonCenter = LogicalPoint(x: bBounds.origin.x + bBounds.width / 2.0, y: bBounds.origin.y + bBounds.height / 2.0)
                print("🎯 [AXUIElement 精度定位成功] 找到真实「执行检索」按钮 Bounds: (\(Int(bBounds.origin.x)), \(Int(bBounds.origin.y)), \(Int(bBounds.width))x\(Int(bBounds.height))) -> 中心点: (\(Int(buttonCenter.x)), \(Int(buttonCenter.y)))")
            }

            if let inputNode = try? await a11y.findElement(matching: "等待灵狐光标输入", role: nil, scope: .application(bundleOrName: "Safari")),
               let iBounds = inputNode.bounds {
                inputCenter = LogicalPoint(x: iBounds.origin.x + iBounds.width / 2.0, y: iBounds.origin.y + iBounds.height / 2.0)
                print("🎯 [AXUIElement 精度定位成功] 找到真实输入框 Bounds: (\(Int(iBounds.origin.x)), \(Int(iBounds.origin.y)), \(Int(iBounds.width))x\(Int(iBounds.height))) -> 中心点: (\(Int(inputCenter.x)), \(Int(inputCenter.y)))")
            }
        }

        // 3. 构造使用真实中心点与 Target Attachment 的 ComputerBatchTool 指令
        let payload = """
        {
            "intent_hint": "Safely attach Safari demo window and accurately click button at exact geometry center",
            "target_app": "Safari",
            "target_window": "LingXiAgent",
            "window_relative": false,
            "actions": [
                {
                    "type": "move",
                    "x": \(inputCenter.x),
                    "y": \(inputCenter.y)
                },
                {
                    "type": "click",
                    "button": "left",
                    "count": 1,
                    "x": \(inputCenter.x),
                    "y": \(inputCenter.y)
                },
                {
                    "type": "wait",
                    "duration_ms": 400
                },
                {
                    "type": "type",
                    "text": "Antigravity Computer Use"
                },
                {
                    "type": "wait",
                    "duration_ms": 500
                },
                {
                    "type": "move",
                    "x": \(buttonCenter.x),
                    "y": \(buttonCenter.y)
                },
                {
                    "type": "wait",
                    "duration_ms": 500
                },
                {
                    "type": "click",
                    "button": "left",
                    "count": 1,
                    "x": \(buttonCenter.x),
                    "y": \(buttonCenter.y)
                },
                {
                    "type": "wait",
                    "duration_ms": 2000
                }
            ]
        }
        """

        let tool = ComputerBatchTool()
        let result = try await tool.execute(arguments: payload, profile: .workspace)
        print("🎉 [Browser Use 交互完成]:\n\(result)")
    }

    @Test("Target Attachment and Element Precision querying mechanism")
    func testTargetAttachmentAndElementPrecision() async throws {
        let env = DesktopEnvironment.makeCurrentPlatformDefault()
        guard let windowsBackend = env.windows else { return }

        // 验证对当前前台窗口或常见系统应用的 attachTarget 行为
        let windows = try await windowsBackend.listWindows()
        if let firstWin = windows.first(where: { !($0.title ?? "").isEmpty }) {
            let query = TargetAttachmentQuery(windowTitle: firstWin.title)
            let attached = try await windowsBackend.attachTarget(query: query)
            #expect(attached != nil)
            if let attached {
                #expect(attached.bounds.width >= 0)
                #expect(attached.bounds.height >= 0)
            }
        }

        // 验证 AccessibilityBackend 的 findElement
        if let a11y = env.accessibility {
            let snapshot = try? await a11y.findElement(matching: "窗口", role: nil, scope: .activeWindow)
            // 无论系统是否存在匹配控件，都不应崩溃或抛出未知异常
            _ = snapshot
        }
    }

    @Test("DarwinVisionOCRBackend extracts visible text and screen logical coordinates")
    func testVisionOCRBackendRecognitionAndFallback() async throws {
        let ocr = DarwinVisionOCRBackend.shared
        // 捕获屏幕文字
        let elements: [VisualElementSnapshot]
        do {
            elements = try await ocr.recognizeElements()
        } catch {
            // 在无屏幕录制权限或 headless CI 环境下，屏幕捕获可能被拒或失败，这是正常环境预期，不应阻断门禁
            print("🦊 [Vision OCR] 屏幕捕获不可用或缺乏 TCC 权限: \(error)")
            return
        }
        print("🦊 [Vision OCR] 屏幕识别到 \(elements.count) 个可见文本元素")
        for el in elements.prefix(5) {
            print("   - 文字: \"\(el.text)\", 置信度: \(el.confidence), 坐标: (\(Int(el.bounds.origin.x)), \(Int(el.bounds.origin.y)), \(Int(el.bounds.width))x\(Int(el.bounds.height)))")
            #expect(!el.text.isEmpty)
            #expect(el.bounds.width >= 0)
            #expect(el.bounds.height >= 0)
        }

        // 测试 findElement 容差匹配
        if let first = elements.first {
            let query = first.text
            let hit = try await ocr.findElement(matching: query)
            if let hit {
                #expect(hit.center.x >= 0)
                #expect(hit.center.y >= 0)
            }
        }
    }

    @Test("AccessibilityBackend resolves applications by English/Chinese aliases gracefully")
    func testSmartApplicationResolutionAndChildTextRollup() async throws {
        guard AXIsProcessTrusted() else {
            // CI 或非 GUI 环境缺乏系统辅助功能权限，正常跳过
            return
        }
        let a11y = DarwinAccessibilityBackend()
        
        // 验证系统别名匹配（无论传入英文 "Finder" 或中文 "访达"，都不应抛出无法处理的异常）
        let finderTree = try? await a11y.fetchTree(scope: .application(bundleOrName: "Finder"))
        #expect(finderTree != nil)

        let safariTree = try? await a11y.fetchTree(scope: .application(bundleOrName: "Safari"))
        #expect(safariTree != nil)
    }
}
#endif
