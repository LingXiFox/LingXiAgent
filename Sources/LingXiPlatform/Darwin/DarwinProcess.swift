#if canImport(Darwin)
import Darwin
import Foundation

public final class DarwinProcessAdapter: PlatformProcessProtocol, @unchecked Sendable {
    public init() {}

    public func currentExecutablePath() -> URL? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let path = buffer.withUnsafeBufferPointer { ptr in
            ptr.baseAddress.map { String(cString: $0) } ?? ""
        }
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    public func resolveExecutable(named name: String, customSearchPaths: [String]?) -> String? {
        let defaultPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var searchPaths = customSearchPaths ?? []
        searchPaths.append(contentsOf: defaultPaths)
        return ExecutableFinder.findExecutable(named: name, customSearchPaths: searchPaths)
    }

    public func terminateProcessTree(pid: Int32, force: Bool) {
        guard pid > 1 else { return }
        let sig = force ? SIGKILL : SIGTERM
        // 尝试向进程组发送信号以清理子进程树
        let pgid = getpgid(pid)
        if pgid > 0 {
            _ = Darwin.kill(-pgid, sig)
        }
        _ = Darwin.kill(pid, sig)
    }

    public func nonblockingDrain(handle: FileHandle, chunkSize: Int = 64 * 1024) -> Data {
        handle.readabilityHandler = nil
        let fd = handle.fileDescriptor
        guard fd >= 0 else { return Data() }
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        var accumulated = Data()
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let bytesRead = Darwin.read(fd, &chunk, chunk.count)
            if bytesRead > 0 {
                accumulated.append(contentsOf: chunk[0..<bytesRead])
            } else {
                break
            }
        }
        return accumulated
    }
}
#endif
