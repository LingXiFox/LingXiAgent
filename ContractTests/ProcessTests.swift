import Foundation
import LingXiPluginABI
import LingXiPluginRuntime
import Testing

@Test("IPC-001 a live pipe carries a request and its reply without waiting for EOF")
func IPC_001_livePipeRoundTrip() async throws {
    let process = PluginProcess(executableURL: builtProduct("LingXiPluginHost"))
    try process.start()
    defer { process.terminate() }

    let reply = try await process.send(HostRequest(id: nil, method: .ping), timeout: .seconds(3))
    #expect(reply.ok)
}
