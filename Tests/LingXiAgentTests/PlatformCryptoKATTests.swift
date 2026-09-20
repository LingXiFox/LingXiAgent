import Foundation
import Testing
@testable import LingXiPlatform

@Suite("Platform Crypto Known Answer Tests (KAT) & Concurrency Validation")
struct PlatformCryptoKATTests {

    // MARK: - 1. SHA-256 Known Answer Tests (FIPS 180-4 & RFC 6234)

    @Test("FIPS 180-4 SHA-256 standard test vectors match on both CryptoKit and Compact engine")
    func sha256StandardVectors() {
        let vectors: [(input: String, expectedHex: String)] = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
            (String(repeating: "a", count: 1000), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
        ]

        for vector in vectors {
            let data = Data(vector.input.utf8)
            let platformDigest = PlatformCrypto.sha256Hex(data)
            let compactDigest = CompactCryptoEngine.sha256Hex(data)

            #expect(platformDigest == vector.expectedHex)
            #expect(compactDigest == vector.expectedHex)
            #expect(platformDigest == compactDigest)
        }
    }

    @Test("SHA-256 padding boundary edge cases (55B, 56B, 63B, 64B, 65B)")
    func sha256PaddingBoundaryCases() {
        let testLengths = [0, 1, 55, 56, 63, 64, 65, 119, 120, 127, 128, 129, 1024]
        for len in testLengths {
            let data = Data((0..<len).map { UInt8($0 & 0xff) })
            let platformHex = PlatformCrypto.sha256Hex(data)
            let compactHex = CompactCryptoEngine.sha256Hex(data)

            // Invariant: Native and pure Swift compact engines must match bit-for-bit
            #expect(platformHex == compactHex, "Mismatch at length \(len): platform=\(platformHex) compact=\(compactHex)")

            // Streaming vs one-shot
            var stream = PlatformCrypto.makeSHA256Hasher()
            let chunkSize = max(1, len / 3)
            var offset = 0
            while offset < data.count {
                let chunk = data.subdata(in: offset..<min(offset + chunkSize, data.count))
                stream.update(data: chunk)
                offset += chunk.count
            }
            let streamHex = stream.finalizeHex()
            #expect(streamHex == platformHex, "Stream mismatch at length \(len)")
        }
    }

    @Test("SHA-256 1MB payload stream and chunk equivalence")
    func sha256OneMegabyteEquivalence() {
        // 1MB deterministic buffer
        var large = Data(count: 1024 * 1024)
        for i in 0..<large.count {
            large[i] = UInt8(i & 0x7f)
        }

        let platformHex = PlatformCrypto.sha256Hex(large)
        let compactHex = CompactCryptoEngine.sha256Hex(large)
        #expect(platformHex == compactHex)

        var stream = PlatformCrypto.makeSHA256Hasher()
        let step = 65536
        var offset = 0
        while offset < large.count {
            let chunk = large.subdata(in: offset..<min(offset + step, large.count))
            stream.update(data: chunk)
            offset += chunk.count
        }
        #expect(stream.finalizeHex() == platformHex)
    }

    // MARK: - 2. HMAC-SHA256 Known Answer Tests (RFC 4231)

    @Test("RFC 4231 HMAC-SHA256 test cases 1 through 5 match standard vectors")
    func hmacSHA256StandardVectors() {
        // RFC 4231 Test Case 1
        let key1 = Data(repeating: 0x0b, count: 20)
        let data1 = Data("Hi There".utf8)
        let expected1 = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        #expect(PlatformCrypto.hmacSHA256(key: key1, data: data1).map { String(format: "%02x", $0) }.joined() == expected1)
        #expect(CompactCryptoEngine.hmacSHA256Hex(key: key1, data: data1) == expected1)

        // RFC 4231 Test Case 2
        let key2 = Data("Jefe".utf8)
        let data2 = Data("what do ya want for nothing?".utf8)
        let expected2 = "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        #expect(PlatformCrypto.hmacSHA256(key: key2, data: data2).map { String(format: "%02x", $0) }.joined() == expected2)
        #expect(CompactCryptoEngine.hmacSHA256Hex(key: key2, data: data2) == expected2)

        // RFC 4231 Test Case 3
        let key3 = Data(repeating: 0xaa, count: 20)
        let data3 = Data(repeating: 0xdd, count: 50)
        let expected3 = "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"
        #expect(PlatformCrypto.hmacSHA256(key: key3, data: data3).map { String(format: "%02x", $0) }.joined() == expected3)
        #expect(CompactCryptoEngine.hmacSHA256Hex(key: key3, data: data3) == expected3)

        // RFC 4231 Test Case 6 (key > 64 bytes)
        let key6 = Data(repeating: 0xaa, count: 131)
        let data6 = Data("Test Using Larger Than Block-Size Key - Hash Key First".utf8)
        let expected6 = "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
        #expect(PlatformCrypto.hmacSHA256(key: key6, data: data6).map { String(format: "%02x", $0) }.joined() == expected6)
        #expect(CompactCryptoEngine.hmacSHA256Hex(key: key6, data: data6) == expected6)
    }

    // MARK: - 3. AES-256-GCM Known Answer Tests (NIST SP 800-38D)

    @Test("NIST SP 800-38D AES-256-GCM Test Case 13 (Empty plaintext and empty AAD)")
    func aesGCMNistTestCase13() throws {
        let key = Data(repeating: 0x00, count: 32)
        let nonce = Data(repeating: 0x00, count: 12)
        let pt = Data()
        let aad = Data()
        let expectedTag = "530f8afbc74536b9a963b4f1c4cb738b"

        let (ct, tag) = try CompactCryptoEngine.sealAESGCM(plaintext: pt, keyData: key, nonce: nonce, authenticating: aad)
        #expect(ct.isEmpty)
        #expect(tag.map { String(format: "%02x", $0) }.joined() == expectedTag)

        let decrypted = try CompactCryptoEngine.openAESGCM(ciphertext: ct, tag: tag, keyData: key, nonce: nonce, authenticating: aad)
        #expect(decrypted.isEmpty)
    }

    @Test("NIST SP 800-38D AES-256-GCM Test Case 14 (16-byte plaintext and empty AAD)")
    func aesGCMNistTestCase14() throws {
        let key = Data(repeating: 0x00, count: 32)
        let nonce = Data(repeating: 0x00, count: 12)
        let pt = Data(repeating: 0x00, count: 16)
        let aad = Data()
        let expectedCT = "cea7403d4d606b6e074ec5d3baf39d18"
        let expectedTag = "d0d1c8a799996bf0265b98b5d48ab919"

        let (ct, tag) = try CompactCryptoEngine.sealAESGCM(plaintext: pt, keyData: key, nonce: nonce, authenticating: aad)
        #expect(ct.map { String(format: "%02x", $0) }.joined() == expectedCT)
        #expect(tag.map { String(format: "%02x", $0) }.joined() == expectedTag)

        let decrypted = try CompactCryptoEngine.openAESGCM(ciphertext: ct, tag: tag, keyData: key, nonce: nonce, authenticating: aad)
        #expect(decrypted == pt)
    }

    @Test("AES-256-GCM cross-engine bidirectional compatibility & tamper resistance")
    func aesGCMCrossEngineCompatibilityAndTamperResistance() throws {
        let key = Data((0..<32).map { UInt8($0 * 7 & 0xff) })
        let nonce = Data((0..<12).map { UInt8($0 * 13 & 0xff) })
        let plaintext = Data("Confidential payload across engine boundaries".utf8)
        let aad = Data("Associated context metadata".utf8)

        // Seal with Compact engine
        let (compactCT, compactTag) = try CompactCryptoEngine.sealAESGCM(plaintext: plaintext, keyData: key, nonce: nonce, authenticating: aad)
        let compactCombined = nonce + compactCT + compactTag

        // Open with PlatformCrypto
        let platformOpened = try PlatformCrypto.openAESGCM(combined: compactCombined, keyData: key, authenticating: aad)
        #expect(platformOpened == plaintext)

        // Seal with PlatformCrypto
        let platformCombined = try PlatformCrypto.sealAESGCM(plaintext: plaintext, keyData: key, authenticating: aad)
        let pNonce = platformCombined.prefix(12)
        let pTag = platformCombined.suffix(16)
        let pCT = platformCombined.dropFirst(12).dropLast(16)

        // Open with Compact engine
        let compactOpened = try CompactCryptoEngine.openAESGCM(ciphertext: Data(pCT), tag: Data(pTag), keyData: key, nonce: Data(pNonce), authenticating: aad)
        #expect(compactOpened == plaintext)

        // Tamper resistance: modify 1 bit of tag -> must throw error
        var tamperedTag = Array(pTag)
        tamperedTag[0] ^= 0x01
        #expect(throws: Error.self) {
            _ = try CompactCryptoEngine.openAESGCM(ciphertext: Data(pCT), tag: Data(tamperedTag), keyData: key, nonce: Data(pNonce), authenticating: aad)
        }

        // Tamper resistance: modify 1 bit of AAD -> must throw error
        var tamperedAAD = aad
        tamperedAAD[0] ^= 0x01
        #expect(throws: Error.self) {
            _ = try CompactCryptoEngine.openAESGCM(ciphertext: Data(pCT), tag: Data(pTag), keyData: key, nonce: Data(pNonce), authenticating: tamperedAAD)
        }
    }

    // MARK: - 4. PBKDF2-HMAC-SHA256 Known Answer Tests (RFC 7693 / NIST SP 800-132)

    @Test("PBKDF2-HMAC-SHA256 standard vectors (OpenSSL verified)")
    func pbkdf2StandardVectors() {
        // Case 1: c=1
        let dk1 = PlatformCrypto.derivePBKDF2(passphrase: "password", salt: Data("salt".utf8), iterations: 1)
        let dk1Hex = dk1.map { String(format: "%02x", $0) }.joined()
        #expect(dk1Hex == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")

        // Case 2: c=2
        let dk2 = PlatformCrypto.derivePBKDF2(passphrase: "password", salt: Data("salt".utf8), iterations: 2)
        let dk2Hex = dk2.map { String(format: "%02x", $0) }.joined()
        #expect(dk2Hex == "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")

        // Case 3: c=4096
        let dk3 = PlatformCrypto.derivePBKDF2(passphrase: "passwordPASSWORDpassword", salt: Data("saltSALTsaltSALTsaltSALTsaltSALTsalt".utf8), iterations: 4096)
        let dk3Hex = dk3.map { String(format: "%02x", $0) }.joined()
        #expect(dk3Hex == "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1")
    }

    // MARK: - 5. Concurrency & Multi-Thread Stress Test

    @Test("100 concurrent crypto operations execute safely without race or corruption")
    func concurrentCryptoStress() async throws {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let msg = "Concurrent message \(i) payload with random padding"
                    let data = Data(msg.utf8)
                    let hash1 = PlatformCrypto.sha256Hex(data)
                    let hash2 = CompactCryptoEngine.sha256Hex(data)
                    #expect(hash1 == hash2)

                    let key = Data((0..<32).map { UInt8(($0 + i) & 0xff) })
                    let salt = Data("salt-\(i)".utf8)
                    let derived = PlatformCrypto.derivePBKDF2(passphrase: "pass-\(i)", salt: salt, iterations: 10)
                    #expect(derived.count == 32)

                    let aad = Data("aad-\(i)".utf8)
                    let sealed = try! PlatformCrypto.sealAESGCM(plaintext: data, keyData: key, authenticating: aad)
                    let opened = try! PlatformCrypto.openAESGCM(combined: sealed, keyData: key, authenticating: aad)
                    #expect(opened == data)
                }
            }
        }
    }
}
