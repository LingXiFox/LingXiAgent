#if os(macOS)
import Foundation
import Darwin

/// Same-user local IPC only. This transport has no Core or model dependencies.
public final class GUIAutomationSocket: @unchecked Sendable {
    private let descriptor: Int32
    private let path: String
    private let lock = NSLock()
    private var closed = false

    public static var socketPath: String { "/tmp/lingxi-gui-\(getuid())/automation.sock" }

    public init(path: String = GUIAutomationSocket.socketPath,
                handler: @escaping @Sendable (Data) async -> Data) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw POSIXError(.EACCES)
        }
        var address = try Self.address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0, errno == EADDRINUSE, lstat(path, &info) == 0,
           info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK,
           Self.isStale(path), unlink(path) == 0 {
            // Rebind the same descriptor; never displace a live GUI.
            result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            Darwin.close(fd); unlink(path); throw POSIXError(.EIO)
        }
        self.descriptor = fd
        self.path = path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while self?.lock.withLock({ self?.closed ?? true }) == false {
                let peer = accept(fd, nil, nil)
                if peer < 0 { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        var uid: uid_t = 0
                        var gid: gid_t = 0
                        guard getpeereid(peer, &uid, &gid) == 0, uid == getuid() else {
                            Darwin.close(peer); return
                        }
                        let request = try Self.readLine(peer)
                        Task {
                            let response = await handler(request)
                            try? Self.writeLine(response, peer)
                            Darwin.close(peer)
                        }
                    } catch { Darwin.close(peer) }
                }
            }
        }
    }

    public func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            unlink(path)
        }
    }

    deinit { close() }

    public static func request(_ request: Data, path: String = socketPath) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let peer = socket(AF_UNIX, SOCK_STREAM, 0)
                    guard peer >= 0 else { throw POSIXError(.EIO) }
                    defer { Darwin.close(peer) }
                    var address = try address(path)
                    let connected = withUnsafePointer(to: &address) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            connect(peer, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                        }
                    }
                    guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    var uid: uid_t = 0
                    var gid: gid_t = 0
                    guard getpeereid(peer, &uid, &gid) == 0, uid == getuid() else { throw POSIXError(.EACCES) }
                    try writeLine(request, peer)
                    continuation.resume(returning: try readLine(peer))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: Array(path.utf8) + [0])
        }
        return address
    }

    private static func isStale(_ path: String) -> Bool {
        let peer = socket(AF_UNIX, SOCK_STREAM, 0)
        guard peer >= 0 else { return false }
        defer { Darwin.close(peer) }
        guard var address = try? address(path) else { return false }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(peer, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) != 0 && errno == ECONNREFUSED
            }
        }
    }

    private static func writeLine(_ data: Data, _ fd: Int32) throws {
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let payload = data + Data([10])
        try payload.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
    }

    private static func readLine(_ fd: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while result.count < 4 * 1024 * 1024 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { throw POSIXError(.ECONNRESET) }
            if let end = buffer.prefix(count).firstIndex(of: 10) {
                result.append(contentsOf: buffer[..<end]); return result
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        throw POSIXError(.EMSGSIZE)
    }
}
#endif
