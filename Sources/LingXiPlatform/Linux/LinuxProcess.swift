#if os(Linux) || canImport(Glibc)
#if canImport(Glibc)
import Glibc
#endif
import Foundation

public final class LinuxProcessAdapter: PlatformProcessProtocol, @unchecked Sendable {
    public init() {}

    public func currentExecutablePath() -> URL? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = readlink("/proc/self/exe", &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        buffer[count] = 0
        let path = String(cString: buffer)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    public func resolveExecutable(named name: String, customSearchPaths: [String]?) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let defaultPaths = [
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/local/sbin",
            "/usr/sbin",
            "/sbin"
        ]
        var searchPaths = customSearchPaths ?? []
        searchPaths.append(contentsOf: defaultPaths)
        return ExecutableFinder.findExecutable(named: name, customSearchPaths: searchPaths)
    }

    public func terminateProcessTree(pid: Int32, force: Bool) {
        guard pid > 1 else { return }
        let sig = force ? SIGKILL : SIGTERM
        let pgid = getpgid(pid)
        if pgid > 0 {
            _ = kill(-pgid, sig)
        }
        _ = kill(pid, sig)
    }

    public func nonblockingDrain(handle: FileHandle, chunkSize: Int = 64 * 1024) -> Data {
        handle.readabilityHandler = nil
        let fd = handle.fileDescriptor
        guard fd >= 0 else { return Data() }
        #if canImport(Glibc)
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        var accumulated = Data()
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let bytesRead = read(fd, &chunk, chunk.count)
            if bytesRead > 0 {
                accumulated.append(contentsOf: chunk[0..<bytesRead])
            } else {
                break
            }
        }
        return accumulated
        #else
        return handle.availableData
        #endif
    }
}
#endif
