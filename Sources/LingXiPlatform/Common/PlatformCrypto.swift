import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// 跨平台密码学与安全散列工具 (PlatformCrypto)
/// 抹平 Darwin (CryptoKit)、Linux (Glibc/Foundation) 与 Windows (WinSDK) 的密码学差异。
/// 在具备 CryptoKit 的平台使用硬件加速实现，在无 CryptoKit 的环境中自动切换至零依赖的标准安全实现。
public enum PlatformCrypto: Sendable {

    /// 计算 Data 的 SHA256 摘要
    public static func sha256(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return Data(digest)
        #else
        return CompactSHA256.hash(data)
        #endif
    }

    /// 计算 Data 的 SHA256 摘要并转换为 64 位小写十六进制字符串
    public static func sha256Hex(_ data: Data) -> String {
        return sha256(data).map { String(format: "%02x", $0) }.joined()
    }

    /// 计算 UTF-8 字符串的 SHA256 十六进制摘要
    public static func sha256Hex(_ string: String) -> String {
        return sha256Hex(Data(string.utf8))
    }

    /// 计算 HMAC-SHA256 认证码
    public static func hmacSHA256(key: Data, data: Data) -> Data {
        #if canImport(CryptoKit)
        let symmetricKey = SymmetricKey(data: key)
        let code = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(code)
        #else
        return CompactHMACSHA256.authenticate(key: key, data: data)
        #endif
    }

    /// 跨平台 PBKDF2-HMAC-SHA256 密钥派生（标准 32 字节派生输出）
    public static func derivePBKDF2(passphrase: String, salt: Data, iterations: Int) -> Data {
        let passwordData = Data(passphrase.utf8)
        var input = salt
        input.append(contentsOf: [0, 0, 0, 1])
        var block = hmacSHA256(key: passwordData, data: input)
        var derived = [UInt8](block)
        if iterations > 1 {
            for _ in 1..<iterations {
                block = hmacSHA256(key: passwordData, data: block)
                for index in derived.indices {
                    derived[index] ^= block[index]
                }
            }
        }
        return Data(derived)
    }

    /// 跨平台 RFC 5869 HKDF-SHA256 密钥派生
    public static func deriveHKDF(secret: Data, salt: Data, info: Data, outputByteCount: Int = 32) -> Data {
        #if canImport(CryptoKit)
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: secret), salt: salt)
        let derivedKey = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: info, outputByteCount: outputByteCount)
        return derivedKey.withUnsafeBytes { Data($0) }
        #else
        // 1. Extract: PRK = HMAC-Hash(salt, IKM)
        let effectiveSalt = salt.isEmpty ? Data(repeating: 0, count: 32) : salt
        let prk = hmacSHA256(key: effectiveSalt, data: secret)

        // 2. Expand: OKM = HMAC-Hash(PRK, info || 0x01) (针对 32 字节输出)
        var expandInput = info
        expandInput.append(0x01)
        let okm = hmacSHA256(key: prk, data: expandInput)
        return okm.prefix(outputByteCount)
        #endif
    }

    /// 跨平台 AES-256-GCM 加密，返回包含 nonce+ciphertext+tag 的 combined 数据
    public static func sealAESGCM(plaintext: Data, keyData: Data, authenticating: Data) throws -> Data {
        #if canImport(CryptoKit)
        let key = SymmetricKey(data: keyData)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: authenticating)
        guard let combined = sealed.combined else {
            throw NSError(domain: "PlatformCrypto", code: -1, userInfo: [NSLocalizedDescriptionKey: "AES.GCM seal failed to produce combined data"])
        }
        return combined
        #else
        throw NSError(domain: "PlatformCrypto", code: -2, userInfo: [NSLocalizedDescriptionKey: "Hardware AES.GCM requires platform crypto provider"])
        #endif
    }

    /// 跨平台 AES-256-GCM 解密，接收 combined 数据
    public static func openAESGCM(combined: Data, keyData: Data, authenticating: Data) throws -> Data {
        #if canImport(CryptoKit)
        let key = SymmetricKey(data: keyData)
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key, authenticating: authenticating)
        #else
        throw NSError(domain: "PlatformCrypto", code: -2, userInfo: [NSLocalizedDescriptionKey: "Hardware AES.GCM requires platform crypto provider"])
        #endif
    }
}

#if !canImport(CryptoKit)
/// 零依赖标准 HMAC-SHA256 算法实现
private enum CompactHMACSHA256 {
    static func authenticate(key: Data, data: Data) -> Data {
        let blockSize = 64
        var formattedKey = key
        if formattedKey.count > blockSize {
            formattedKey = CompactSHA256.hash(formattedKey)
        }
        if formattedKey.count < blockSize {
            formattedKey.append(contentsOf: [UInt8](repeating: 0, count: blockSize - formattedKey.count))
        }

        var oKeyPad = Data(count: blockSize)
        var iKeyPad = Data(count: blockSize)
        for i in 0..<blockSize {
            oKeyPad[i] = formattedKey[i] ^ 0x5c
            iKeyPad[i] = formattedKey[i] ^ 0x36
        }

        var innerData = iKeyPad
        innerData.append(data)
        let innerHash = CompactSHA256.hash(innerData)

        var outerData = oKeyPad
        outerData.append(innerHash)
        return CompactSHA256.hash(outerData)
    }
}

/// 零外部依赖的标准 FIPS 180-4 SHA-256 纯 Swift 实现
/// 专门为无原生 CryptoKit 的 Linux / Windows 环境提供确定性兜底
private enum CompactSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func hash(_ data: Data) -> Data {
        var message = Array(data)
        let bitLength = UInt64(data.count) * 8
        message.append(0x80)
        while (message.count % 64) != 56 {
            message.append(0x00)
        }
        var bigEndianBits = bitLength.bigEndian
        withUnsafeBytes(of: &bigEndianBits) { message.append(contentsOf: $0) }

        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]

        var w = [UInt32](repeating: 0, count: 64)
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let offset = chunkStart + i * 4
                w[i] = (UInt32(message[offset]) << 24) |
                       (UInt32(message[offset + 1]) << 16) |
                       (UInt32(message[offset + 2]) << 8) |
                       UInt32(message[offset + 3])
            }
            for i in 16..<64 {
                let s0 = (w[i - 15] >> 7 | w[i - 15] << 25) ^
                         (w[i - 15] >> 18 | w[i - 15] << 14) ^
                         (w[i - 15] >> 3)
                let s1 = (w[i - 2] >> 17 | w[i - 2] << 15) ^
                         (w[i - 2] >> 19 | w[i - 2] << 13) ^
                         (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hVal = h[7]

            for i in 0..<64 {
                let s1 = (e >> 6 | e << 26) ^ (e >> 11 | e << 21) ^ (e >> 25 | e << 7)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hVal &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = (a >> 2 | a << 30) ^ (a >> 13 | a << 19) ^ (a >> 22 | a << 10)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                hVal = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hVal
        }

        var result = Data(capacity: 32)
        for value in h {
            var be = value.bigEndian
            withUnsafeBytes(of: &be) { result.append(contentsOf: $0) }
        }
        return result
    }
}
#endif
