import Foundation
import Testing
import LingXiProtocol
@testable import LingXiCore

struct ACPServerTests {

    @Test func acpRequestAndResponseSerializationCompliesWithJSONRPC2() throws {
        // 1. 请求反序列化
        let reqJSON = """
        {
            "jsonrpc": "2.0",
            "id": 42,
            "method": "initialize",
            "params": {
                "clientInfo": { "name": "zed", "version": "0.145.0" }
            }
        }
        """.data(using: .utf8)!

        let req = try JSONDecoder().decode(ACPRequest.self, from: reqJSON)
        #expect(req.jsonrpc == "2.0")
        #expect(req.id == .integer(42))
        #expect(req.method == "initialize")
        #expect(req.params != nil)

        // 2. 响应序列化
        let res = ACPInitializeResult(
            agentInfo: ACPAgentInfo(name: "LingXiAgent", version: "1.0.0"),
            capabilities: ACPAgentCapabilities(modes: ["default", "code"]),
            protocolVersion: "2024-11-05"
        )
        let resp = try ACPResponse(id: req.id, resultPayload: res)
        let encoded = try JSONEncoder().encode(resp)
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(text.contains("\"jsonrpc\":\"2.0\""))
        #expect(text.contains("\"id\":42"))
        #expect(text.contains("LingXiAgent"))
    }

    @Test func acpServerHandlesInitializeAndSessionNewWithPipe() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let coreHost = try CoreHost(dataRoot: tmpDir)
        await coreHost.start()

        let server = LingXiACPServer(service: coreHost)

        // 1. 测试 initialize
        let initParams = ACPInitializeParams(clientInfo: ACPClientInfo(name: "zed", version: "0.150.0"))
        let initReq = try ACPRequest(
            id: .integer(1),
            method: "initialize",
            paramsPayload: initParams
        )

        let outPipe = Pipe()
        await server.handleRequest(initReq, output: outPipe.fileHandleForWriting)

        let outData = outPipe.fileHandleForReading.availableData
        let outStr = String(decoding: outData, as: UTF8.self)
        #expect(outStr.contains("\"id\":1"))
        #expect(outStr.contains("LingXiAgent"))

        // 2. 测试 session/new
        let newParams = ACPSessionNewParams(cwd: tmpDir.path)
        let newReq = try ACPRequest(
            id: .string("req-2"),
            method: "session/new",
            paramsPayload: newParams
        )
        let newPipe = Pipe()
        await server.handleRequest(newReq, output: newPipe.fileHandleForWriting)
        let newOutData = newPipe.fileHandleForReading.availableData
        let newOutStr = String(decoding: newOutData, as: UTF8.self)

        #expect(newOutStr.contains("\"id\":\"req-2\""))
        #expect(newOutStr.contains("sessionId"))

        // 3. 测试未知方法错误
        let invalidReq = ACPRequest(
            id: .integer(3),
            method: "unknown/method"
        )
        let errPipe = Pipe()
        await server.handleRequest(invalidReq, output: errPipe.fileHandleForWriting)
        let errOutData = errPipe.fileHandleForReading.availableData
        let errOutStr = String(decoding: errOutData, as: UTF8.self)

        #expect(errOutStr.contains("-32601"))
        await coreHost.shutdown()
    }
}
