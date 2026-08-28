import Foundation
import LingXiClient
import LingXiProtocol

// LingXiAgent Reference TUI。
// 验证通路：LingXiTUI → LingXiClient → LingXiProtocol → Core。
// TUI 不知道 Core 内部实现，只使用 LingXiClient 与 LingXiProtocol。

func runTUI() async {
    let client: LingXiClient
    do {
        client = try LingXiClient.stdioCore()
    } catch {
        FileHandle.standardError.write(Data("无法启动 LingXiCoreHost: \(error)\n".utf8))
        return
    }
    defer { Task { await client.close() } }

    do {
        let state = try await client.coreState()
        if state == .ready {
            print("Core Ready")
        } else {
            FileHandle.standardError.write(Data("Core 状态异常: \(state.rawValue)\n".utf8))
            return
        }

        let info = try await client.coreInfo()
        print("Core Version: \(info.version)")

        try await client.ping()
        print("Ping: Pong")

        // Streaming DMA：逐块到达、逐块显示，不等待完整字符串。
        print("Streaming:")
        let stream = try await client.openTestStream()
        for try await chunk in stream {
            print(chunk.text, terminator: "")
            fflush(stdout)
        }
        print()

        await client.close()
    } catch {
        FileHandle.standardError.write(Data("TUI 错误: \(error)\n".utf8))
    }
}

await runTUI()
