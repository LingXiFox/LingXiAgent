import Foundation
import Testing
@testable import LingXiCore

struct SSEDecoderTests {
    @Test func splitsAcrossArbitraryChunks() {
        // 一条 JSON 行被拆进三个网络块，必须缓冲到完整行才输出。
        var decoder = SSEDecoder()
        #expect(decoder.feed(Data("data: {\"a".utf8)) == [])
        // \n\n 中间的空行也是一行（SSE event 分隔）。
        #expect(decoder.feed(Data("\":1}\n\ndata:".utf8)) == ["data: {\"a\":1}", ""])
        #expect(decoder.feed(Data(" [DONE]\n".utf8)) == ["data: [DONE]"])
        #expect(decoder.flushPending() == [])
    }

    @Test func handlesCRLF() {
        var decoder = SSEDecoder()
        let lines = decoder.feed(Data("a\r\nb\r\nc\n".utf8))
        #expect(lines == ["a", "b", "c"])
    }

    @Test func byteByByte() {
        var decoder = SSEDecoder()
        let payload = Data("data: x\n".utf8)
        var lines: [String] = []
        for byte in payload {
            lines.append(contentsOf: decoder.feed(Data([byte])))
        }
        #expect(lines == ["data: x"])
    }

    @Test func pendingTailWithoutNewline() {
        var decoder = SSEDecoder()
        #expect(decoder.feed(Data("tail".utf8)) == [])
        #expect(decoder.flushPending() == ["tail"])
    }
}
