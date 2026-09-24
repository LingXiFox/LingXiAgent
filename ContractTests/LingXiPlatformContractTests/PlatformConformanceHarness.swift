import Foundation
import Testing
import LingXiPlatform

@Suite("Platform Conformance Harness (P23)")
struct PlatformConformanceHarness {

    // MARK: - Process Contract Conformance

    @Test("Platform process protocol conforms to required process management semantics")
    func testProcessProtocolConformance() throws {
        let process = LingXiPlatform.process
        let cwd = process.currentWorkingDirectory()
        #expect(!cwd.isEmpty)

        // Executable resolution should find standard system tools
        #if os(Windows)
        let resolved = process.resolveExecutable(named: "cmd", customSearchPaths: nil)
        #else
        let resolved = process.resolveExecutable(named: "sh", customSearchPaths: nil)
        #endif
        #expect(resolved != nil)
    }

    // MARK: - File Contract Conformance

    @Test("Platform file protocol conforms to basic file lifecycle operations")
    func testFileProtocolConformance() throws {
        let file = LingXiPlatform.file
        let tempDir = try file.makeTemporaryDirectory(prefix: "lingxi-conformance-test")
        defer { try? file.remove(at: tempDir) }

        #expect(file.exists(at: tempDir))

        let testFile = (tempDir as NSString).appendingPathComponent("sample.txt")
        let sampleData = Data("hello platform contract".utf8)

        try file.writeAtomic(contents: sampleData, to: testFile)
        #expect(file.exists(at: testFile))

        let readBack = try file.readFile(at: testFile, limit: nil)
        #expect(readBack == sampleData)

        let meta = try file.metadata(at: testFile)
        #expect(!meta.isDirectory)
        #expect(meta.size == Int64(sampleData.count))

        let appendData = Data(" - appended".utf8)
        try file.append(contents: appendData, to: testFile)
        let fullRead = try file.readFile(at: testFile, limit: nil)
        #expect(fullRead == Data("hello platform contract - appended".utf8))

        let listing = try file.listDirectory(at: tempDir, recursive: false, maxResults: nil)
        #expect(listing.contains("sample.txt"))
    }

    // MARK: - Network Contract Conformance

    @Test("Platform network protocol conforms to loopback allocation and reachability")
    func testNetworkProtocolConformance() async throws {
        let network = LingXiPlatform.network
        let server = try network.listenTCP(port: 0)
        #expect(server.port > 0)
        server.close()

        let addresses = network.interfaceAddresses()
        #expect(!addresses.isEmpty)
    }

    // MARK: - IPC Contract Conformance

    @Test("Platform IPC protocol conforms to naming and deadline semantics")
    func testIPCProtocolConformance() async throws {
        let ipc = LingXiPlatform.ipc
        let pipeName = ipc.namedPipe(name: "test-pipe")
        #expect(!pipeName.isEmpty)

        let socketPath = ipc.unixDomainSocket(path: "/tmp/lingxi.sock")
        #expect(!socketPath.isEmpty)

        // Deadline should succeed when within time limit
        let value = try await ipc.deadline(1.0) {
            return 42
        }
        #expect(value == 42)

        // Socket pair creation
        let pair = try ipc.spawnSocketPair()
        #if !os(Windows)
        #expect(pair.channelA.fileDescriptor >= 0)
        #expect(pair.channelB.fileDescriptor >= 0)
        #endif
    }

    // MARK: - Async I/O Contract Conformance

    @Test("Platform AsyncIO protocol conforms to submit and completion dispatch")
    func testAsyncIOProtocolConformance() async throws {
        let asyncIO = LingXiPlatform.asyncIO
        var completed = false
        for await completion in asyncIO.submit({ 100 }) {
            switch completion.value {
            case .success(let val):
                #expect(val == 100)
                completed = true
            case .failure:
                Issue.record("Async IO operation failed unexpectedly")
            }
        }
        #expect(completed)
    }

    // MARK: - Platform Debt Manifest Verification

    @Test("PLATFORM-DEBT.json is present, valid JSON, and every debt entry has reason, owner, and targetVersion")
    func testPlatformDebtManifestValidation() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LingXiPlatformContractTests
            .deletingLastPathComponent() // ContractTests
            .deletingLastPathComponent() // Repo Root
        let debtFile = repoRoot.appendingPathComponent("Docs/PLATFORM-DEBT.json")
        #expect(FileManager.default.fileExists(atPath: debtFile.path), "Docs/PLATFORM-DEBT.json must exist")

        let data = try Data(contentsOf: debtFile)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let debts = json["debts"] as? [[String: Any]] else {
            Issue.record("Failed to parse Docs/PLATFORM-DEBT.json as { debts: [...] }")
            return
        }

        #expect(!debts.isEmpty, "Platform debt manifest must register known platform debts")

        for debt in debts {
            guard let cap = debt["capability"] as? String, !cap.isEmpty,
                  let plat = debt["platform"] as? String, !plat.isEmpty,
                  let status = debt["status"] as? String, !status.isEmpty,
                  let reason = debt["reason"] as? String, !reason.isEmpty,
                  let owner = debt["owner"] as? String, !owner.isEmpty,
                  let targetVer = debt["targetVersion"] as? String, !targetVer.isEmpty else {
                Issue.record("Debt entry missing required fields: \(debt)")
                continue
            }
            #expect(["unsupported", "partial", "deprecated"].contains(status), "Invalid status in debt entry: \(status)")
        }
    }
}
