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

@Test("QA-002 deadline polling releases cooperative workers so the observed task can start")
func QA_002_pollDoesNotBlockObservedTask() async {
    let recorder = InMemorySink()
    let workers = max(2, ProcessInfo.processInfo.activeProcessorCount * 2)
    let passed = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<workers {
            group.addTask {
                try? recorder.append(line: "ready")
                return await waitUntil { (try? recorder.readLines().contains("released")) == true }
            }
        }
        group.addTask {
            let allStarted = await waitUntil { (try? recorder.readLines().count) == workers }
            try? recorder.append(line: "released")
            return allStarted
        }
        var results: [Bool] = []
        for await result in group { results.append(result) }
        return results.allSatisfy { $0 }
    }
    #expect(passed)
}
