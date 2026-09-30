import Testing
import Foundation
@testable import LingXiProtocol
@testable import LingXiPlatform
@testable import LingXiCore

@Suite("BrowserSessionManager & Tools Tests")
struct BrowserSessionManagerTests {

    @Test("BrowserNavigateTool and BrowserActTool definition and validation")
    func testBrowserToolsDefinitionAndValidation() async throws {
        let navTool = BrowserNavigateTool()
        #expect(navTool.definition.id.rawValue == "browser_navigate")
        #expect(navTool.definition.inputSchema.required.contains("url"))
        #expect(navTool.definition.capability.kinds.contains(.networkAccess))
        #expect(navTool.definition.capability.kinds.contains(.userInteraction))

        let actTool = BrowserActTool()
        #expect(actTool.definition.id.rawValue == "browser_act")
        #expect(actTool.definition.inputSchema.required.contains("action"))

        // 测试无效参数拦截
        await #expect(throws: CoreError.self) {
            _ = try await navTool.execute(arguments: "{}", profile: .workspace)
        }

        await #expect(throws: CoreError.self) {
            _ = try await actTool.execute(arguments: "{}", profile: .workspace)
        }
    }

    @Test("The host gets the switches it reads and no other LINGXI value")
    func childEnvironmentForwardsHostSwitches() {
        let parent = ["LINGXI_BROWSER_HOST_MODE": "mock",
                      "LINGXI_BROWSER_DISABLE_SANDBOX": "1",
                      "LINGXI_API_KEY": "sk-must-not-travel",
                      "PATH": "/usr/bin:/bin",
                      "HOME": "/root"]
        let env = BrowserHostClient.childEnvironment(mode: .real, parent: parent)
        #expect(env["LINGXI_BROWSER_DISABLE_SANDBOX"] == "1",
                "Linux 与容器里读不到这个开关就起不了 Chromium")
        #expect(env["LINGXI_BROWSER_HOST_MODE"] == "real", "模式由 Core 决定，不随父进程")
        #expect(env["LINGXI_API_KEY"] == nil)

        let empty = BrowserHostClient.childEnvironment(mode: .mock,
                                                      parent: ["LINGXI_BROWSER_DISABLE_SANDBOX": ""])
        #expect(empty["LINGXI_BROWSER_DISABLE_SANDBOX"] == nil, "空值不等于打开")
    }

    @Test("Every action browser_act advertises is one the host performs")
    func advertisedActionsExistInTheHost() async throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sidecars/browser-host/index.mjs")
        let source = try String(contentsOf: script, encoding: .utf8)
        let advertised = BrowserActTool().definition.inputSchema.properties["action"]?.enumValues ?? []
        #expect(advertised.contains("hover"), "枚举不该再退回只认点击")
        for action in advertised {
            #expect(source.contains("\"\(action)\""), "browser_act 宣传 \(action)，宿主没有实现")
        }
    }

    @Test("BrowserHostClient protocol cycle in explicit Mock mode")
    func testSidecarHandshakeAndProtocolCycleInMockMode() async throws {
        let scriptPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/LingXiAgentTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sidecars/browser-host/index.mjs").path

        guard FileManager.default.fileExists(atPath: scriptPath) else {
            Issue.record("Sidecar script not found at \(scriptPath)")
            return
        }

        let client = BrowserHostClient(scriptPath: scriptPath, mode: .mock)
        try client.start()
        defer { client.stop() }

        // 1. 验证握手
        let handshake = try await client.initialize()
        #expect(handshake.protocolVersion == "v1")
        #expect(handshake.hostVersion.contains("lingxi-browser-host"))
        #expect(handshake.mode == "mock")
        #expect(handshake.capabilities.contains("navigation"))
        #expect(handshake.capabilities.contains("dom"))

        // 2. 验证 Session 创建
        let sessionID = "test-session-\(UUID().uuidString.prefix(8))"
        let createdID = try await client.createSession(sessionID: sessionID)
        #expect(createdID == sessionID)

        // 3. 验证导航
        let navRes = try await client.navigate(sessionID: sessionID, url: "https://example.com")
        #expect(navRes.url == "https://example.com")
        #expect(navRes.version >= 1)

        // 4. 验证快照 (默认 includeScreenshot: false，screenshotBlobRef 为 nil)
        let snapObs = try await client.snapshot(sessionID: sessionID, includeScreenshot: false)
        #expect(snapObs.viewportBounds.width > 0)
        #expect(snapObs.viewportBounds.height > 0)
        #expect(snapObs.elements.count > 0)
        #expect(snapObs.screenshotBlobRef == nil)

        // 5. 验证执行动作
        try await client.performAction(
            sessionID: sessionID,
            actionType: "click",
            x: 100,
            y: 100,
            text: nil
        )

        // 6. 关闭 Session
        try await client.closeSession(sessionID: sessionID)
    }

    @Test("BrowserSessionManager workflow in explicit Mock mode")
    func testBrowserSessionManagerWorkflowInMockMode() async throws {
        let scriptPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/LingXiAgentTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sidecars/browser-host/index.mjs").path

        guard FileManager.default.fileExists(atPath: scriptPath) else {
            Issue.record("Sidecar script not found at \(scriptPath)")
            return
        }

        let manager = BrowserSessionManager(scriptPath: scriptPath, mode: .mock)
        let sessionID = "agent-browser-\(UUID().uuidString.prefix(8))"

        // 1. 导航并验证格式化摘要
        let summary = try await manager.navigate(sessionID: sessionID, url: "https://example.com")
        #expect(summary.contains("URL:"))
        #expect(summary.contains("Interactive Elements:"))
        #expect(summary.contains("ref_"))

        // 2. 使用有效 Ref 执行点击
        let actSummary = try await manager.act(
            sessionID: sessionID,
            actionType: "click",
            refString: "ref_1"
        )
        #expect(actSummary.contains("URL:"))

        // 3. 验证无效 Ref 拦截抛错
        await #expect(throws: InteractionError.self) {
            _ = try await manager.act(
                sessionID: sessionID,
                actionType: "click",
                refString: "ref_99999"
            )
        }

        // 4. 会话状态投影读出 host 真实报告的页面
        let states = await manager.sessionStates()
        #expect(states.map(\.sessionID) == [sessionID])
        #expect(states.first?.currentURL.isEmpty == false)
        #expect(states.first?.latestObservation != nil)

        // 5. 清理会话
        await manager.close(sessionID: sessionID)
        #expect(await manager.sessionStates().isEmpty)
    }
}
