import Foundation
import Testing
@testable import LingXiProtocol

struct WireCodableTests {
    private func roundtrip(_ message: WireMessage) throws -> WireMessage {
        let data = try JSONEncoder().encode(message)
        return try JSONDecoder().decode(WireMessage.self, from: data)
    }

    @Test func requestRoundtrip() throws {
        let commands: [ClientCommand] = [
            .ping, .getInfo, .getState, .openTestStream,
            .createSession, .listSessions,
            .getSession(sessionID: SessionID("s-1")),
            .sendMessage(sessionID: SessionID("s-1"), content: "你好，世界"),
            .getProviderStatus,
            .replyPermission(PermissionReply(permissionID: PermissionID("p-1"), decision: .allow)),
        ]
        for command in commands {
            let decoded = try roundtrip(.request(id: "7", command: command))
            #expect(decoded == .request(id: "7", command: command))
        }
    }

    @Test func responseRoundtrip() throws {
        let info = CoreInfo(name: "LingXiCore", version: "0.1.0", protocolVersion: "1")
        let status = ProviderStatus(configured: true, model: "m", baseURL: "https://x/v1", missingRequirements: [])
        let now = Date()
        let sessionInfo = SessionInfo(id: SessionID("s-1"), createdAt: now, updatedAt: now, messageCount: 2)
        let snapshot = SessionSnapshot(
            id: SessionID("s-1"),
            createdAt: now,
            updatedAt: now,
            messages: [SessionMessageSnapshot(id: MessageID("m-1"), role: .user, content: "hi", createdAt: now)]
        )
        let cases: [CoreResponse] = [
            .pong,
            .info(info),
            .state(.ready),
            .streamOpened(StreamID("s-1")),
            .providerStatus(status),
            .sessionCreated(sessionInfo),
            .sessionList([sessionInfo]),
            .sessionDetail(snapshot),
            .permissionReplyAccepted(PermissionID("p-1")),
            .error(CoreError(code: .turnAlreadyRunning, message: "已有进行中的轮次")),
        ]
        for response in cases {
            let decoded = try roundtrip(.response(id: "3", response: response))
            #expect(decoded == .response(id: "3", response: response))
        }
    }

    @Test func eventRoundtrip() throws {
        let handle = TurnHandle(sessionID: SessionID("s-1"), streamID: StreamID("t-1"))
        let result = TurnResult(
            sessionID: SessionID("s-1"),
            streamID: StreamID("t-1"),
            assistantMessageID: MessageID("m-2"),
            finishReason: .stop,
            usage: ModelUsage(inputTokens: 1, outputTokens: 2, reasoningTokens: nil, cacheReadTokens: nil, cacheWriteTokens: nil)
        )
        let failure = TurnFailure(sessionID: SessionID("s-1"), streamID: StreamID("t-1"), error: CoreError(code: .modelStream, message: "中断"))
        let events: [CoreEvent] = [
            .stateChanged(.shuttingDown),
            .sessionCreated(SessionID("s-1")),
            .turnStarted(handle),
            .turnCompleted(result),
            .turnFailed(failure),
            .toolCallCompleted(ToolCall(callID: ToolCallID("c-1"), toolID: ToolID("read_file"), arguments: #"{"path":"README.md"}"#)),
            .toolResult(ToolResult(callID: ToolCallID("c-1"), success: true, content: "LingXiAgent")),
            .permissionAsked(PermissionRequest(
                permissionID: PermissionID("p-1"), sessionID: SessionID("s-1"), toolCallID: ToolCallID("c-1"),
                toolID: ToolID("read_file"), resource: "/workspace/README.md", description: "Read README"
            )),
        ]
        for event in events {
            #expect(try roundtrip(.event(event)) == .event(event))
        }
    }

    @Test func chunkRoundtrip() throws {
        let chunk = StreamChunk(streamID: StreamID("s-1"), index: 2, text: "DMA", kind: .reasoning)
        #expect(try roundtrip(.chunk(chunk)) == .chunk(chunk))
    }

    @Test func dataPlaneFlag() {
        #expect(ClientCommand.openTestStream.isDataPlane)
        #expect(ClientCommand.sendMessage(sessionID: SessionID("s-1"), content: "hi").isDataPlane)
        #expect(!ClientCommand.ping.isDataPlane)
        #expect(!ClientCommand.createSession.isDataPlane)
        #expect(!ClientCommand.getSession(sessionID: SessionID("s-1")).isDataPlane)
    }
}
