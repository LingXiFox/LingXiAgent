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
        let nonce = LingXiPlatform.secureStorage.generateSecureRandomBytes(count: 12)
        let (cipher, tag) = try CompactAESGCM.seal(
            plaintext: Array(plaintext),
            key: Array(keyData),
            nonce: Array(nonce),
            aad: Array(authenticating)
        )
        return nonce + Data(cipher) + Data(tag)
        #endif
    }

    /// 跨平台 AES-256-GCM 解密，接收 combined 数据
    public static func openAESGCM(combined: Data, keyData: Data, authenticating: Data) throws -> Data {
        #if canImport(CryptoKit)
        let key = SymmetricKey(data: keyData)
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key, authenticating: authenticating)
        #else
        guard combined.count >= 28 else {
            throw NSError(domain: "PlatformCrypto", code: -3, userInfo: [NSLocalizedDescriptionKey: "Combined AES-GCM data too short"])
        }
        let nonce = Array(combined.prefix(12))
        let tag = Array(combined.suffix(16))
        let ciphertext = Array(combined.dropFirst(12).dropLast(16))
        let plain = try CompactAESGCM.open(
            ciphertext: ciphertext,
            tag: tag,
            key: Array(keyData),
            nonce: nonce,
            aad: Array(authenticating)
        )
        return Data(plain)
        #endif
    }

    /// 创建流式 SHA-256 增量哈希器，抹平平台差异，实现增量流式 Hash 计算
    public static func makeSHA256Hasher() -> PlatformSHA256Hasher {
        PlatformSHA256Hasher()
    }
}

/// 跨平台流式 SHA-256 哈希器
public struct PlatformSHA256Hasher: Sendable {
    #if canImport(CryptoKit)
    private var hasher: CryptoKit.SHA256
    #else
    private var state: CompactSHA256StreamState
    #endif

    public init() {
        #if canImport(CryptoKit)
        self.hasher = CryptoKit.SHA256()
        #else
        self.state = CompactSHA256StreamState()
        #endif
    }

    public mutating func update(data: Data) {
        #if canImport(CryptoKit)
        hasher.update(data: data)
        #else
        state.update(data: data)
        #endif
    }

    public mutating func finalizeData() -> Data {
        #if canImport(CryptoKit)
        let digest = hasher.finalize()
        return Data(digest)
        #else
        return state.finalize()
        #endif
    }

    public mutating func finalizeHex() -> String {
        return finalizeData().map { String(format: "%02x", $0) }.joined()
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

/// 零外部依赖的标准 FIPS 180-4 SHA-256 流式状态机
struct CompactSHA256StreamState: Sendable {
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

    private var h: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]
    private var buffer = [UInt8]()
    private var totalBytes: UInt64 = 0

    init() {
        buffer.reserveCapacity(64)
    }

    mutating func update(data: Data) {
        totalBytes &+= UInt64(data.count)
        var offset = 0
        let count = data.count
        data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            if !buffer.isEmpty {
                let needed = 64 - buffer.count
                let toTake = min(needed, count)
                buffer.append(contentsOf: UnsafeBufferPointer(start: ptr, count: toTake))
                offset += toTake
                if buffer.count == 64 {
                    processChunk(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            while offset + 64 <= count {
                let chunk = Array(UnsafeBufferPointer(start: ptr + offset, count: 64))
                processChunk(chunk)
                offset += 64
            }
            if offset < count {
                buffer.append(contentsOf: UnsafeBufferPointer(start: ptr + offset, count: count - offset))
            }
        }
    }

    private mutating func processChunk(_ chunk: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let off = i * 4
            w[i] = (UInt32(chunk[off]) << 24) |
                   (UInt32(chunk[off + 1]) << 16) |
                   (UInt32(chunk[off + 2]) << 8) |
                   UInt32(chunk[off + 3])
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
            let temp1 = hVal &+ s1 &+ ch &+ Self.k[i] &+ w[i]
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

    mutating func finalize() -> Data {
        let bitLength = totalBytes * 8
        buffer.append(0x80)
        while (buffer.count % 64) != 56 {
            buffer.append(0x00)
            if buffer.count == 64 {
                processChunk(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        var bigEndianBits = bitLength.bigEndian
        withUnsafeBytes(of: &bigEndianBits) { buffer.append(contentsOf: $0) }
        processChunk(buffer)

        var result = Data(capacity: 32)
        for value in h {
            var be = value.bigEndian
            withUnsafeBytes(of: &be) { result.append(contentsOf: $0) }
        }
        return result
    }
}

/// 零外部依赖的标准 FIPS 180-4 SHA-256 纯 Swift 实现
/// 专门为无原生 CryptoKit 的 Linux / Windows 环境提供确定性兜底
private enum CompactSHA256 {
    static func hash(_ data: Data) -> Data {
        var state = CompactSHA256StreamState()
        state.update(data: data)
        return state.finalize()
    }
}

/// 零外部依赖的标准 AES-256 算法实现（用于非 Darwin 平台 AES-GCM 核心构建）
struct CompactAES256Standard: Sendable {
    private static let sbox: [UInt8] = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16
    ]

    private static let rcon: [UInt8] = [
        0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40,
        0x80, 0x1B, 0x36, 0x6C, 0xD8, 0xAB, 0x4D, 0x9A,
        0x2F, 0x5E, 0xBC, 0x63, 0xC6, 0x97, 0x35, 0x6A,
        0xD4, 0xB3, 0x7D, 0xFA, 0xEF, 0xC5, 0x91, 0x39
    ]

    private let keyMatrices: [[[UInt8]]]

    init(key: [UInt8]) {
        precondition(key.count == 32)
        var keyColumns: [[UInt8]] = []
        keyColumns.reserveCapacity(60)
        for i in 0..<8 {
            let col: [UInt8] = [key[i * 4], key[i * 4 + 1], key[i * 4 + 2], key[i * 4 + 3]]
            keyColumns.append(col)
        }
        var rconIdx = 1
        while keyColumns.count < 60 {
            var word = keyColumns.last!
            if keyColumns.count % 8 == 0 {
                let first = word.removeFirst()
                word.append(first)
                word = word.map { Self.sbox[Int($0)] }
                word[0] ^= Self.rcon[rconIdx]
                rconIdx += 1
            } else if keyColumns.count % 8 == 4 {
                word = word.map { Self.sbox[Int($0)] }
            }
            let prevCol = keyColumns[keyColumns.count - 8]
            for j in 0..<4 {
                word[j] ^= prevCol[j]
            }
            keyColumns.append(word)
        }

        var matrices: [[[UInt8]]] = []
        for i in 0..<15 {
            let mat = Array(keyColumns[i*4 ..< (i+1)*4])
            matrices.append(mat)
        }
        self.keyMatrices = matrices
    }

    private static func xtime(_ a: UInt8) -> UInt8 {
        ((a << 1) ^ ((a & 0x80) != 0 ? 0x1b : 0x00))
    }

    func encryptBlock(_ input: [UInt8]) -> [UInt8] {
        var s: [[UInt8]] = []
        s.reserveCapacity(4)
        for i in 0..<4 {
            let col: [UInt8] = [input[i * 4], input[i * 4 + 1], input[i * 4 + 2], input[i * 4 + 3]]
            s.append(col)
        }

        for i in 0..<4 {
            for j in 0..<4 { s[i][j] ^= keyMatrices[0][i][j] }
        }

        for r in 1...13 {
            for i in 0..<4 {
                for j in 0..<4 { s[i][j] = Self.sbox[Int(s[i][j])] }
            }
            let t1 = s[0][1]; s[0][1] = s[1][1]; s[1][1] = s[2][1]; s[2][1] = s[3][1]; s[3][1] = t1
            let t2 = s[0][2]; let t2b = s[1][2]; s[0][2] = s[2][2]; s[1][2] = s[3][2]; s[2][2] = t2; s[3][2] = t2b
            let t3 = s[3][3]; s[3][3] = s[2][3]; s[2][3] = s[1][3]; s[1][3] = s[0][3]; s[0][3] = t3
            for i in 0..<4 {
                let a0 = s[i][0], a1 = s[i][1], a2 = s[i][2], a3 = s[i][3]
                let t = a0 ^ a1 ^ a2 ^ a3
                s[i][0] ^= t ^ Self.xtime(a0 ^ a1)
                s[i][1] ^= t ^ Self.xtime(a1 ^ a2)
                s[i][2] ^= t ^ Self.xtime(a2 ^ a3)
                s[i][3] ^= t ^ Self.xtime(a3 ^ a0)
            }
            for i in 0..<4 {
                for j in 0..<4 { s[i][j] ^= keyMatrices[r][i][j] }
            }
        }

        for i in 0..<4 {
            for j in 0..<4 { s[i][j] = Self.sbox[Int(s[i][j])] }
        }
        let t1 = s[0][1]; s[0][1] = s[1][1]; s[1][1] = s[2][1]; s[2][1] = s[3][1]; s[3][1] = t1
        let t2 = s[0][2]; let t2b = s[1][2]; s[0][2] = s[2][2]; s[1][2] = s[3][2]; s[2][2] = t2; s[3][2] = t2b
        let t3 = s[3][3]; s[3][3] = s[2][3]; s[2][3] = s[1][3]; s[1][3] = s[0][3]; s[0][3] = t3

        for i in 0..<4 {
            for j in 0..<4 { s[i][j] ^= keyMatrices[14][i][j] }
        }

        var out = [UInt8](repeating: 0, count: 16)
        for i in 0..<4 {
            for j in 0..<4 {
                out[i*4 + j] = s[i][j]
            }
        }
        return out
    }
}

/// 零外部依赖的标准 NIST SP 800-38D AES-256-GCM 算法实现
enum CompactAESGCM {
    private static func shiftRightBlock(_ v: inout [UInt8]) {
        var carry: UInt8 = 0
        for i in 0..<16 {
            let nextCarry = v[i] & 0x01
            v[i] = (v[i] >> 1) | (carry << 7)
            carry = nextCarry
        }
    }

    private static func gfMult(_ x: [UInt8], _ y: [UInt8]) -> [UInt8] {
        var z = [UInt8](repeating: 0, count: 16)
        var v = y
        for i in 0..<16 {
            for j in 0..<8 {
                if (x[i] & (1 << (7 - j))) != 0 {
                    for k in 0..<16 { z[k] ^= v[k] }
                }
                if (v[15] & 0x01) != 0 {
                    shiftRightBlock(&v)
                    v[0] ^= 0xe1
                } else {
                    shiftRightBlock(&v)
                }
            }
        }
        return z
    }

    private static func computeGHASH(h: [UInt8], aad: [UInt8], ciphertext: [UInt8]) -> [UInt8] {
        var y = [UInt8](repeating: 0, count: 16)

        var offset = 0
        while offset < aad.count {
            let end = min(offset + 16, aad.count)
            for i in 0..<(end - offset) {
                y[i] ^= aad[offset + i]
            }
            y = gfMult(y, h)
            offset += 16
        }

        offset = 0
        while offset < ciphertext.count {
            let end = min(offset + 16, ciphertext.count)
            for i in 0..<(end - offset) {
                y[i] ^= ciphertext[offset + i]
            }
            y = gfMult(y, h)
            offset += 16
        }

        var lenBlock = [UInt8](repeating: 0, count: 16)
        let aadBits = UInt64(aad.count * 8).bigEndian
        let cBits = UInt64(ciphertext.count * 8).bigEndian
        withUnsafeBytes(of: aadBits) { lenBlock.replaceSubrange(0..<8, with: $0) }
        withUnsafeBytes(of: cBits) { lenBlock.replaceSubrange(8..<16, with: $0) }

        for i in 0..<16 { y[i] ^= lenBlock[i] }
        y = gfMult(y, h)
        return y
    }

    static func seal(plaintext: [UInt8], key: [UInt8], nonce: [UInt8], aad: [UInt8]) throws -> (ciphertext: [UInt8], tag: [UInt8]) {
        precondition(key.count == 32)
        precondition(nonce.count == 12)
        let aes = CompactAES256Standard(key: key)
        let h = aes.encryptBlock([UInt8](repeating: 0, count: 16))

        let j0 = nonce + [0, 0, 0, 1]
        let s = aes.encryptBlock(j0)

        var ciphertext = [UInt8](repeating: 0, count: plaintext.count)
        var counter = j0
        var offset = 0
        while offset < plaintext.count {
            var carry: UInt32 = 1
            for k in (12..<16).reversed() {
                let sum = UInt32(counter[k]) + carry
                counter[k] = UInt8(sum & 0xff)
                carry = sum >> 8
            }
            let keystream = aes.encryptBlock(counter)
            let blockSize = min(16, plaintext.count - offset)
            for b in 0..<blockSize {
                ciphertext[offset + b] = plaintext[offset + b] ^ keystream[b]
            }
            offset += blockSize
        }

        let g = computeGHASH(h: h, aad: aad, ciphertext: ciphertext)
        var tag = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { tag[i] = g[i] ^ s[i] }

        return (ciphertext, tag)
    }

    static func open(ciphertext: [UInt8], tag: [UInt8], key: [UInt8], nonce: [UInt8], aad: [UInt8]) throws -> [UInt8] {
        precondition(key.count == 32)
        precondition(nonce.count == 12)
        precondition(tag.count == 16)
        let aes = CompactAES256Standard(key: key)
        let h = aes.encryptBlock([UInt8](repeating: 0, count: 16))

        let j0 = nonce + [0, 0, 0, 1]
        let s = aes.encryptBlock(j0)

        let g = computeGHASH(h: h, aad: aad, ciphertext: ciphertext)
        var expectedTag = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { expectedTag[i] = g[i] ^ s[i] }

        var diff: UInt8 = 0
        for i in 0..<16 { diff |= tag[i] ^ expectedTag[i] }
        guard diff == 0 else {
            throw NSError(domain: "PlatformCrypto", code: -3, userInfo: [NSLocalizedDescriptionKey: "Authentication tag mismatch"])
        }

        var plaintext = [UInt8](repeating: 0, count: ciphertext.count)
        var counter = j0
        var offset = 0
        while offset < ciphertext.count {
            var carry: UInt32 = 1
            for k in (12..<16).reversed() {
                let sum = UInt32(counter[k]) + carry
                counter[k] = UInt8(sum & 0xff)
                carry = sum >> 8
            }
            let keystream = aes.encryptBlock(counter)
            let blockSize = min(16, ciphertext.count - offset)
            for b in 0..<blockSize {
                plaintext[offset + b] = ciphertext[offset + b] ^ keystream[b]
            }
            offset += blockSize
        }
        return plaintext
    }
}
#endif
