import Foundation
import Testing
import LingXiProtocol
import LingXiCore
import LingXiClient

/// 通过 LingXiClient → CoreEndpoint 契约验证完整通路（进程内 Transport）。
struct CoreClientTests {
    private func makeClient() async -> CoreHost {
        let host = CoreHost()
        await host.start()
        return host
    }

    @Test func coreInfoReadable() async throws {
        let host = await makeClient()
        let info = try await LingXiClient.inProcess(endpoint: host).coreInfo()
        #expect(info.name == "LingXiCore")
        #expect(info.version == CoreHost.coreVersion)
        #expect(info.protocolVersion == CoreHost.protocolVersion)
    }

    @Test func coreStateReadable() async throws {
        let host = await makeClient()
        let state = try await LingXiClient.inProcess(endpoint: host).coreState()
        #expect(state == .ready)
    }

    @Test func pingPong() async throws {
        let host = await makeClient()
        try await LingXiClient.inProcess(endpoint: host).ping()
    }

    @Test func streamingReceivesOrderedChunks() async throws {
        let host = await makeClient()
        let client = LingXiClient.inProcess(endpoint: host)
        let stream = try await client.openTestStream()

        var texts: [String] = []
        var indexes: [Int] = []
        for try await chunk in stream {
            texts.append(chunk.text)
            indexes.append(chunk.index)
        }

        #expect(texts == ["Hello ", "LingXiAgent ", "Streaming ", "DMA"])
        #expect(indexes == Array(indexes.indices))
        #expect(texts.count > 1, "Streaming 应产出多个 chunk")
    }

    @Test func stateChangedEvents() async throws {
        // start 之前订阅，验证语义事件通路。
        let host = CoreHost()
        let events = await host.events()
        await host.start()

        var seen: [CoreState] = []
        for await event in events {
            if case let .stateChanged(state) = event {
                seen.append(state)
                if state == .ready { break }
            }
        }
        #expect(seen.contains(.ready))
    }
}
