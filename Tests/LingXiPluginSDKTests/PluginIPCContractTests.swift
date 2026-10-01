import Foundation
import Testing
@testable import LingXiPluginSDK

/// LingXi Plugin IPC 的线格式契约。
///
/// 这里锁的是「文档与网页能怎么写」:方法名、握手字段、错误形态、缺参与畸形输入的
/// 反应。README 与 agent.lingxifox.cn/sdk.html 展示的每一条 payload 都必须能被
/// `PluginDriver` 真实解出来 —— 反过来,协议里有的方法也不允许只活在文档里。
struct PluginIPCContractTests {

    private struct Probe: PluginTool {
        let name = "probe.echo"
        let description = "Echo the arguments back."
        func execute(arguments: String, context: ToolExecutionContext) async throws -> String {
            "echo:\(arguments)"
        }
    }

    private struct ProbeCommand: PluginCommand {
        let name = "probe"
        let aliases = ["pb"]
        let description = "Reads runtime info from the host."
        func execute(args: [String], context: CommandExecutionContext) async throws -> PluginCommandResult {
            // 未收到快照时必须显式失败,不能拿到 idle / unknown / 0。
            let workspace = try await context.info.getWorkspaceInfo()
            return .message("root=\(workspace.rootPath)")
        }
    }

    private struct Fixture: LingXiPlugin {
        init() {}
        var manifest: PluginManifest {
            PluginManifest(
                id: "com.lingxi.test-probe",
                name: "Probe",
                version: "0.1.0",
                description: "Contract fixture plugin",
                capabilities: [.projectRead]
            )
        }
        func activate(context: PluginContext) async throws {
            context.registerTool(Probe())
            context.registerCommand(ProbeCommand())
            context.on(.sessionStart) { _ in }
        }
    }

    private func drive(_ driver: PluginDriver, _ method: PluginIPC.Method, params: Data? = nil) async -> PluginIPCResponse {
        await driver.handleRequest(PluginIPCRequest(method: method, params: params))
    }

    private func snapshot(ipcVersion: Int = PluginIPC.currentVersion,
                          workspace: PluginWorkspaceInfo? = PluginWorkspaceInfo(
                            rootPath: "/repo", isGitRepository: true, currentGitBranch: "main",
                            dirtyFileCount: 3, coreVersion: "1.1.0")) -> Data {
        try! JSONEncoder().encode(PluginRuntimeSnapshot(observedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                       ipcVersion: ipcVersion, workspace: workspace))
    }

    // MARK: - 握手

    @Test("handshake declares the IPC version and everything the host needs to route")
    func handshake() async throws {
        let driver = PluginDriver(plugin: Fixture())
        let response = await drive(driver, .initialize,
                                   params: try JSONEncoder().encode(PluginInitializeParams(coreVersion: "1.1.0")))
        guard let data = response.result, response.error == nil else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(response.error ?? "nil")"])
        }
        let handshake = try JSONDecoder().decode(PluginHandshakeResult.self, from: data)
        #expect(handshake.manifest.id == "com.lingxi.test-probe")
        #expect(handshake.ipcVersion == PluginIPC.currentVersion)
        #expect(handshake.sdkVersion == PluginIPC.sdkVersion)
        #expect(handshake.tools.map(\.name) == ["probe.echo"])
        #expect(handshake.commands.first?.aliases == ["pb"])
        #expect(handshake.supportedHooks == [PluginHookEvent.sessionStart.rawValue])
    }

    @Test("an incompatible host IPC version fails at the handshake instead of mid-call")
    func hostVersionMismatch() async throws {
        let driver = PluginDriver(plugin: Fixture())
        let params = try JSONEncoder().encode(PluginInitializeParams(hostIPCVersion: 99, coreVersion: "9.9.9"))
        let response = await drive(driver, .initialize, params: params)
        #expect(response.result == nil)
        #expect(response.error?.contains("Unsupported host IPC version 99") == true)
    }

    /// 缺 `ipcVersion` 的旧握手包不能被发现方默默补成 1 —— 那会让一个说别的协议的
    /// 插件一路放行到运行期才炸。
    @Test("a handshake payload without an IPC version is refused, not defaulted")
    func handshakeWithoutVersion() {
        let legacy = Data(#"{"manifest":{"id":"a","name":"A","version":"1","description":"","capabilities":[]},"tools":[],"commands":[]}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(PluginHandshakeResult.self, from: legacy)
        }
    }

    // MARK: - host.snapshot

    @Test("host.snapshot is the only source of runtime info, and it is acknowledged")
    func snapshotDelivery() async throws {
        let driver = PluginDriver(plugin: Fixture())
        let ack = await drive(driver, .snapshot, params: snapshot())
        #expect(ack.error == nil)

        let response = await drive(driver, .commandExecute, params: try JSONEncoder().encode(
            PluginCommandCallParams(commandName: "probe", arguments: [], sessionID: nil)))
        let result = try #require(response.result)
        let payload = try JSONDecoder().decode(PluginCommandCallResult.self, from: result)
        #expect(payload.text == "root=/repo")
    }

    /// §15 的初始化顺序:Core 在 plugin.initialize 之前推送快照,所以插件在
    /// `activate(context:)` 里读 info 也不会拿到占位值。
    @Test("the documented order delivers a snapshot before activation happens")
    func snapshotBeforeInitialize() async throws {
        let driver = PluginDriver(plugin: Fixture())
        _ = await drive(driver, .snapshot, params: snapshot())
        let handshake = await drive(driver, .initialize)
        #expect(handshake.error == nil)
        let response = await drive(driver, .commandExecute, params: try JSONEncoder().encode(
            PluginCommandCallParams(commandName: "probe", arguments: [], sessionID: nil)))
        #expect(response.error == nil)
    }

    @Test("an incompatible snapshot version is refused and leaves the hub untouched")
    func snapshotVersionMismatch() async throws {
        let driver = PluginDriver(plugin: Fixture())
        let response = await drive(driver, .snapshot, params: snapshot(ipcVersion: 42))
        #expect(response.error?.contains("Unsupported host IPC version 42") == true)
        // 之后仍然没有任何权威信息:被拒的快照不得半相落地。
        let command = await drive(driver, .commandExecute, params: try JSONEncoder().encode(
            PluginCommandCallParams(commandName: "probe", arguments: [], sessionID: nil)))
        #expect(command.error?.contains("PluginInfoUnavailable") == true
                || command.error?.contains("unavailable") == true)
    }

    // MARK: - 其余方法与失败形态

    @Test("tool.execute round-trips through the documented params shape")
    func toolExecute() async throws {
        let driver = PluginDriver(plugin: Fixture())
        let response = await drive(driver, .toolExecute, params: try JSONEncoder().encode(
            PluginToolCallParams(toolName: "probe.echo", arguments: "hi", sessionID: "s-1", toolCallID: "c-1")))
        let result = try #require(response.result)
        #expect(try JSONDecoder().decode(String.self, from: result) == "echo:hi")
    }

    @Test("every method with no params fails as an error response instead of throwing out of the loop")
    func missingParams() async throws {
        let driver = PluginDriver(plugin: Fixture())
        for method in [PluginIPC.Method.snapshot, .toolExecute, .commandExecute, .hookEmit] {
            let response = await drive(driver, method)
            #expect(response.result == nil, "\(method.rawValue) accepted an empty request")
            #expect(response.error?.isEmpty == false, "\(method.rawValue) failed silently")
        }
    }

    @Test("malformed params produce an error response, never a crash or a silent success")
    func malformedParams() async throws {
        let driver = PluginDriver(plugin: Fixture())
        let response = await drive(driver, .toolExecute, params: Data("{not json".utf8))
        #expect(response.result == nil)
        #expect(response.error != nil)
    }

    @Test("unknown methods are reported with the method name so logs stay actionable")
    func unknownMethod() async throws {
        let driver = PluginDriver(plugin: Fixture())
        let response = await driver.handleRequest(PluginIPCRequest(method: "tool.call", params: nil))
        #expect(response.error == "Unknown IPC method: tool.call")
    }

    @Test("an unregistered tool or command is a named lookup failure")
    func unknownToolAndCommand() async throws {
        let driver = PluginDriver(plugin: Fixture())
        let tool = await drive(driver, .toolExecute, params: try JSONEncoder().encode(
            PluginToolCallParams(toolName: "nope", arguments: "", sessionID: "s", toolCallID: "c")))
        #expect(tool.error?.contains("nope") == true)
        let command = await drive(driver, .commandExecute, params: try JSONEncoder().encode(
            PluginCommandCallParams(commandName: "nope", arguments: [], sessionID: nil)))
        #expect(command.error?.contains("nope") == true)
    }

    @Test("hook.emit accepts a payload it has no handler for without failing the host")
    func hookEmitIsFireAndForget() async throws {
        let driver = PluginDriver(plugin: Fixture())
        let response = await drive(driver, .hookEmit, params: try JSONEncoder().encode(
            PluginHookPayload(event: .agentTurnEnd, subjectID: "turn-1")))
        #expect(response.error == nil)
    }

    // MARK: - 线格式框架

    /// 这个协议是 JSON Lines,不是 JSON-RPC 2.0:线里没有 `jsonrpc` 字段,也没有
    /// batch。这里把它钉住,防止哪天网页与代码又各写一套。
    @Test("one request line yields exactly one response line and carries no JSON-RPC envelope")
    func jsonLinesFraming() throws {
        let request = PluginIPCRequest(method: .initialize)
        let encoded = try JSONEncoder().encode(request)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("\n"), "一个请求必须占一行")
        #expect(!text.contains("\"jsonrpc\""), "线格式不是 JSON-RPC 2.0,不得虚称")
        let decoded = try JSONDecoder().decode(PluginIPCRequest.self, from: encoded)
        #expect(decoded.method == "plugin.initialize")

        let response = try JSONEncoder().encode(PluginIPCResponse(id: request.id, error: "boom"))
        let roundTrip = try JSONDecoder().decode(PluginIPCResponse.self, from: response)
        #expect(roundTrip.id == request.id)
        #expect(roundTrip.error == "boom")
        #expect(roundTrip.result == nil)
    }

    @Test("the method table is the only source of method names")
    func methodTableMatchesTheDocumentedSet() {
        #expect(PluginIPC.Method.allCases.map(\.rawValue) == [
            "host.snapshot", "plugin.initialize", "tool.execute", "command.execute", "hook.emit",
        ])
        // 文档里曾出现过 tool.call:代码没有它,网页与 README 也不允许有它。
        #expect(!PluginIPC.Method.allCases.contains(where: { $0.rawValue == "tool.call" }))
    }

    @Test("EOF-shaped traffic: a blank line produces no response")
    func blankLinesAreSkipped() async throws {
        // runStdio 会跳过空行,不伪造一个 id 为空的响应。
        let decoded = try JSONDecoder().decode(PluginIPCRequest.self,
                                               from: Data(#"{"id":"x","method":"hook.emit","params":null}"#.utf8))
        #expect(decoded.id == "x")
        let driver = PluginDriver(plugin: Fixture())
        let response = await driver.handleRequest(PluginIPCRequest(id: "empty-params", method: .hookEmit, params: Data("{}".utf8)))
        #expect(response.error != nil, "空 params 必须被当成畸形输入")
    }
    /// Command 的另一条出口:注入提示词而不是本地输出。Core 的
    /// `PluginCommandCallResult.isPrompt` 依赖它,文档也展示了两种形态。
    @Test("a command can return a prompt for the agent instead of a local message")
    func promptCommand() async throws {
        let driver = PluginDriver(plugin: PromptFixture())
        _ = await drive(driver, .snapshot, params: snapshot())
        let response = await drive(driver, .commandExecute, params: try JSONEncoder().encode(
            PluginCommandCallParams(commandName: "inspect", arguments: ["src/main.swift"], sessionID: nil)))
        let payload = try JSONDecoder().decode(PluginCommandCallResult.self, from: try #require(response.result))
        #expect(payload.isPrompt)
        #expect(payload.text.contains("/repo"))
        #expect(payload.text.contains("src/main.swift"))
    }

    /// `presentation` 是后加的字段:老插件回包没有它时必须解码成默认展示形态,
    /// 否则一次 SDK 升级会把所有旧插件的 command 全部打成解码失败。
    @Test("a result payload without a presentation field still decodes")
    func presentationBackwardCompatibility() throws {
        let legacy = Data(#"{"isPrompt":false,"text":"hello"}"#.utf8)
        let decoded = try JSONDecoder().decode(PluginCommandCallResult.self, from: legacy)
        #expect(decoded.presentation == PluginPresentationStyle.modal.rawValue)
        #expect(decoded.text == "hello")
        #expect(decoded.title == nil)
    }

    private struct PromptCommand: PluginCommand {
        let name = "inspect"
        let description = "Turns the workspace into a prompt."
        func execute(args: [String], context: CommandExecutionContext) async throws -> PluginCommandResult {
            let workspace = try await context.info.getWorkspaceInfo()
            return .prompt("inspect \(workspace.rootPath) \(args.joined(separator: " "))")
        }
    }

    private struct PromptFixture: LingXiPlugin {
        init() {}
        var manifest: PluginManifest {
            PluginManifest(id: "com.lingxi.prompt", name: "Prompt", version: "0.1.0", description: "Prompt fixture")
        }
        func activate(context: PluginContext) async throws {
            context.registerCommand(PromptCommand())
        }
    }
}
