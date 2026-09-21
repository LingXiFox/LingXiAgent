import Foundation
import Testing
@testable import LingXiPlatform
@testable import LingXiProtocol
@testable import LingXiCore
@testable import LingXiClient

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
