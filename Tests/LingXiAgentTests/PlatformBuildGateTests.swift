import Foundation
import Testing
#if canImport(Glibc)
import Glibc
#endif
@testable import LingXiPlatform
@testable import LingXiProtocol
@testable import LingXiCore
@testable import LingXiClient

/// A value written by a task that might never run to completion.
private final class Verdict<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@Suite("Platform Build Gate & Cross-Platform Integrity Tests (Round 2 Phase A)")
struct PlatformBuildGateTests {

    @Test("PlatformCrypto SHA256 produces exact FIPS 180-4 standard digests")
    func platformCryptoSHA256Correctness() {
        let emptyDigest = LingXiPlatform.crypto.sha256Hex("")
        #expect(emptyDigest == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        let foxDigest = LingXiPlatform.crypto.sha256Hex("LingXiAgent")
        #expect(foxDigest.count == 64)

        // Verify Data and String overloads consistency
        let dataDigest = LingXiPlatform.crypto.sha256Hex(Data("LingXiAgent".utf8))
        #expect(foxDigest == dataDigest)
    }

    @Test("PlatformCrypto HKDF, PBKDF2, and AES-GCM encrypt and decrypt roundtrip")
    func platformCryptoVaultPrimitives() throws {
        let passphrase = "CyberFoxSecretMasterPassword-2026"
        let salt = Data("RandomSaltForTesting-16Bytes!".utf8)
        let key = LingXiPlatform.crypto.derivePBKDF2(passphrase: passphrase, salt: salt, iterations: 1000)
        #expect(key.count == 32)

        let plaintext = Data("Confidential API Key: sk-lingxi-production-token-v2".utf8)
        let aad = Data("Associated Metadata".utf8)

        let sealed = try LingXiPlatform.crypto.sealAESGCM(plaintext: plaintext, keyData: key, authenticating: aad)
        #expect(!sealed.isEmpty)

        let opened = try LingXiPlatform.crypto.openAESGCM(combined: sealed, keyData: key, authenticating: aad)
        #expect(opened == plaintext)

        let hkdfDerived = LingXiPlatform.crypto.deriveHKDF(secret: key, salt: salt, info: Data("Subkey".utf8), outputByteCount: 32)
        #expect(hkdfDerived.count == 32)
    }

    @Test("AsyncLineReader splits streams across chunk boundaries with CRLF support")
    func asyncLineReaderDecodesLinesCorrectly() async throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("line_reader_test_\(UUID().uuidString).txt")
        let content = "line1\nline2\r\nline3\nlast_line_without_newline"
        try content.write(to: tempFile, atomically: false, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let handle = try FileHandle(forReadingFrom: tempFile)
        defer { try? handle.close() }

        var lines: [String] = []
        // Test with tiny buffer size to force multi-chunk boundary reassembly
        for try await line in LingXiPlatform.lineReader.lines(from: handle, bufferSize: 4) {
            lines.append(line)
        }

        #expect(lines == ["line1", "line2", "line3", "last_line_without_newline"])
    }

    // MARK: - Pipe readers

    /// Marks both ends close-on-exec before anything is spawned.
    ///
    /// Only the descriptor a child is *told* to use survives exec, so a pipe created here would
    /// otherwise be inherited by a child some other suite spawns concurrently -- and while that
    /// unrelated process holds the write end, the EOF these tests wait for is unobservable. It showed
    /// up as a 20s timeout only when several suites ran at once, never in isolation.
    private static func makeCloseOnExec(_ pipe: Pipe) {
        #if !os(Windows)
        for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
            _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        #endif
    }

    /// One shared sink, so the fixture children do not each add two descriptors of their own to a
    /// count that is supposed to say something about the pipes.
    private static let nullHandle = FileHandle.nullDevice

    /// Launches a fixture child with its stdout on a pipe the caller keeps alive.
    private static func spawn(_ fixture: (command: String, arguments: [String]), stdout: Pipe) throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: fixture.command)
        child.arguments = fixture.arguments
        child.environment = EnvironmentSanitizer.sanitized()
        child.standardInput = Self.nullHandle
        child.standardOutput = stdout
        child.standardError = Self.nullHandle
        try child.run()
        return child
    }

    private static func drain(_ pipe: Pipe) async -> (returned: Bool, lines: [String]) {
        let done = DispatchSemaphore(value: 0)
        let verdict = Verdict<[String]>()
        let reader = Task {
            var collected: [String] = []
            do {
                for try await line in LingXiPlatform.lineReader.lines(from: pipe.fileHandleForReading) {
                    collected.append(line)
                }
            } catch {
                verdict.set(collected + ["<read threw: \(error)>"])
                done.signal()
                return
            }
            verdict.set(collected)
            done.signal()
        }
        let returned = await Self.settled(done, seconds: 20)
        if !returned { reader.cancel() }
        return (returned, verdict.value ?? [])
    }

    /// Waits off the cooperative pool: a reader that never returns has to cost a failed expectation,
    /// not the chunk it sits in.
    private static func settled(_ done: DispatchSemaphore, seconds: Double) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Thread { continuation.resume(returning: done.wait(timeout: .now() + seconds) == .success) }.start()
        }
    }

    @Test("A pipe whose writer already exited still delivers its bytes and its EOF")
    func readerDeliversTheOutputOfAChildThatAlreadyExited() async throws {
        // The ordering is the defect: `waitUntilExit()` before anything reads the pipe makes it a
        // fact rather than a race that readiness exists before the reader attaches. Linux lost
        // exactly this, because its `FileHandle.readabilityHandler` is a dispatch source and a
        // source created after the descriptor turned readable is never delivered there -- so the
        // bytes and the EOF both went unseen and the consumer awaited forever. An already-exited
        // stdio server is not exotic: `mcp status` against `/bin/echo` is that shape.
        let pipe = Pipe()
        Self.makeCloseOnExec(pipe)
        let child = try Self.spawn(PortableFixture.python("print(\"alpha\"); print(\"beta\"); print(\"gamma\")"), stdout: pipe)
        try? pipe.fileHandleForWriting.close()
        child.waitUntilExit()

        let (returned, lines) = await Self.drain(pipe)
        try? pipe.fileHandleForReading.close()

        #expect(returned, "the reader never returned for a child that had already exited: neither its buffered bytes nor the EOF was delivered")
        #expect(lines == ["alpha", "beta", "gamma"])
    }

    @Test("Cancelling the consumer of a silent live pipe returns instead of parking forever")
    func cancellingTheConsumerReleasesThePipeReader() async throws {
        let pipe = Pipe()
        Self.makeCloseOnExec(pipe)
        let child = try Self.spawn(PortableFixture.sleep(30), stdout: pipe)
        try? pipe.fileHandleForWriting.close()

        let done = DispatchSemaphore(value: 0)
        let reader = Task {
            do {
                for try await _ in LingXiPlatform.lineReader.dataChunks(from: pipe.fileHandleForReading) {}
            } catch {}
            done.signal()
        }
        try await Task.sleep(for: .milliseconds(600))
        reader.cancel()

        let returned = await Self.settled(done, seconds: 10)
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
        try? pipe.fileHandleForReading.close()

        #expect(returned, "a cancelled consumer left the pipe reader parked: nothing can interrupt it while the child keeps the write end open")
    }

    #if !os(Windows)
    @Test("Each spawn-and-drain cycle gives back the descriptors it took")
    func repeatedPipeDrainsDoNotLeakDescriptors() async throws {
        func descriptorsOpen() -> Int {
            (0..<1024).reduce(0) { count, fd in
                count + (fcntl(Int32(fd), F_GETFD) != -1 ? 1 : 0)
            }
        }
        func cycle() async throws {
            let pipe = Pipe()
        Self.makeCloseOnExec(pipe)
            let child = try Self.spawn(PortableFixture.python("print(\"one\"); print(\"two\")"), stdout: pipe)
            try? pipe.fileHandleForWriting.close()
            child.waitUntilExit()
            let (returned, lines) = await Self.drain(pipe)
            try? pipe.fileHandleForReading.close()
            #expect(returned && lines == ["one", "two"])
        }

        // The first children open descriptors of their own lazily (a shared cache, not a per-cycle
        // leak), so sampling before them would report a slope that no fix can remove.
        for _ in 0..<2 { try await cycle() }
        let before = descriptorsOpen()
        for _ in 0..<10 { try await cycle() }
        let after = descriptorsOpen()

        // The bound is a leak signature, not bookkeeping: a cycle that kept its pipe would add two
        // descriptors and reach 20 here. Sibling suites in the same process open and close
        // descriptors of their own while this measures, so anything tighter than half a leak's worth
        // measures the neighbours. Measured on CI at 6 over 10 cycles.
        #expect(after - before <= 10, "10 spawn-and-drain cycles retained \(after - before) descriptors")
    }
    #endif

    @Test("PlatformLoopbackServer allocates ephemeral port and respects timeoutSeconds without hanging")
    func platformLoopbackServerTimeout() async throws {
        let server = try PlatformLoopbackServer(preferredPort: 0)
        #expect(server.port > 0)
        defer { server.closeServer() }

        let start = Date()
        do {
            // Test with a tiny 0.15s timeout
            _ = try await server.waitForCallback(expectedState: "test-state", timeoutSeconds: 0.15)
            Issue.record("Expected timeout error, but call succeeded")
        } catch let error as CoreError {
            let elapsed = Date().timeIntervalSince(start)
            #expect(error.code == .commandTimedOut)
            // Ceiling only guards that poll() is the thing returning, so a lower bound is
            // monotone-safe under a saturated runner. The old `< 10.0` upper bound merely
            // measured scheduler latency: a genuine hang never returns at all and is caught
            // by the CI step timeout instead.
            #expect(elapsed >= 0.10)
        }
    }

    @Test("Zero CryptoKit imports inside LingXiCore architecture boundary")
    func codebaseArchitectureStrictZeroCryptoKitInCore() throws {
        let coreDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/LingXiAgentTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Sources/LingXiCore")

        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(at: coreDir, includingPropertiesForKeys: [.isRegularFileKey])
        var violations: [String] = []

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "import CryptoKit" || trimmed.hasPrefix("import CryptoKit ") {
                    violations.append("\(fileURL.lastPathComponent): \(trimmed)")
                }
            }
        }

        #expect(violations.isEmpty, "LingXiCore must not import CryptoKit directly! Found violations: \(violations)")
    }
}
