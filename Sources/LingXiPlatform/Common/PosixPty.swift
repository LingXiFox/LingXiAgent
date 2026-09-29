import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// POSIX pseudo-terminal backend.
///
/// Uses `posix_openpt`/`grantpt`/`unlockpt`/`ptsname` instead of `openpty` so the
/// same code runs on macOS and Linux without linking libutil. The child is
/// spawned into its own session, which is what lets an interrupt reach everything
/// the user started rather than only the shell.
#if canImport(Darwin) || canImport(Glibc)
public final class PosixPtyAdapter: PlatformPtyProtocol, @unchecked Sendable {
    public init() {}

    public func spawn(command: [String], cwd: URL, environment: [String: String],
                      columns: Int, rows: Int) throws -> any PtyHandle {
        guard let executable = command.first, !executable.isEmpty else {
            throw PtyError.allocationFailed("伪终端需要命令")
        }
        let master = posix_openpt(Int32(O_RDWR | O_NOCTTY))
        guard master >= 0 else {
            throw PtyError.allocationFailed("posix_openpt: \(String(cString: strerror(errno)))")
        }
        guard grantpt(master) == 0, unlockpt(master) == 0,
              let slaveName = ptsname(master) else {
            closeDescriptor(master)
            throw PtyError.allocationFailed("无法取得从终端: \(String(cString: strerror(errno)))")
        }
        let slave = open(slaveName, Int32(O_RDWR))
        guard slave >= 0 else {
            closeDescriptor(master)
            throw PtyError.allocationFailed("无法打开从终端: \(String(cString: strerror(errno)))")
        }

        var window = winsize(ws_row: UInt16(max(1, rows)), ws_col: UInt16(max(1, columns)),
                             ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, UInt(TIOCSWINSZ), &window)

        // On Darwin and glibc these are opaque pointer typedefs with no usable
        // Swift initialiser: declare them as optionals and let the C calls fill
        // them in.
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, slave, 0)
        posix_spawn_file_actions_adddup2(&actions, slave, 1)
        posix_spawn_file_actions_adddup2(&actions, slave, 2)
        posix_spawn_file_actions_addclose(&actions, slave)
        posix_spawnattr_init(&attributes)
        // A new session makes the child a process-group leader, so a signal can be
        // delivered to the whole pipeline it starts.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        var argumentBlock: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) }
        argumentBlock.append(nil)
        var environmentBlock: [UnsafeMutablePointer<CChar>?] = environment
            .sorted { $0.key < $1.key }
            .map { strdup("\($0)=\($1)") }
        environmentBlock.append(nil)
        defer {
            for pointer in argumentBlock where pointer != nil { free(pointer) }
            for pointer in environmentBlock where pointer != nil { free(pointer) }
        }

        var pid: pid_t = 0
        let status = argumentBlock.withUnsafeMutableBufferPointer { argv in
            environmentBlock.withUnsafeMutableBufferPointer { envp in
                executable.withCString { name in
                    posix_spawnp(&pid, name, &actions, &attributes, argv.baseAddress, envp.baseAddress)
                }
            }
        }
        closeDescriptor(slave)
        guard status == 0 else {
            closeDescriptor(master)
            throw PtyError.spawnFailed("无法启动 \(executable): \(String(cString: strerror(status)))")
        }

        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        return PosixPtyHandle(masterFD: master, pid: pid)
    }
}

private func closeDescriptor(_ descriptor: Int32) {
    #if canImport(Darwin)
    Darwin.close(descriptor)
    #else
    Glibc.close(descriptor)
    #endif
}

private func writeAll(_ descriptor: Int32, _ data: Data) {
    guard !data.isEmpty else { return }
    data.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        var sent = 0
        while sent < data.count {
            let written: Int
            #if canImport(Darwin)
            written = Darwin.write(descriptor, base + sent, data.count - sent)
            #else
            written = Glibc.write(descriptor, base + sent, data.count - sent)
            #endif
            if written <= 0 { return }
            sent += written
        }
    }
}

private func readSome(_ descriptor: Int32) -> Data? {
    var buffer = [UInt8](repeating: 0, count: 8_192)
    let count: Int
    #if canImport(Darwin)
    count = Darwin.read(descriptor, &buffer, buffer.count)
    #else
    count = Glibc.read(descriptor, &buffer, buffer.count)
    #endif
    if count > 0 { return Data(buffer[0..<count]) }
    return nil
}

/// One master descriptor bound to one child process. All calls come from the
/// actor that owns the session, so the state needs no additional locking.
private final class PosixPtyHandle: PtyHandle, @unchecked Sendable {
    private var master: Int32
    private var pending = Data()
    private(set) var exitStatus: Int32?
    let pid: Int32

    init(masterFD: Int32, pid: Int32) {
        self.master = masterFD
        self.pid = pid
    }

    /// Everything produced since the last call; nil once the child is gone and
    /// nothing is left to read.
    func drain() -> Data? {
        guard master >= 0 else { return nil }
        var chunk = Data()
        while true {
            guard let piece = readSome(master) else { break }
            chunk.append(piece)
            if chunk.count >= 512 * 1_024 { break }   // a slow reader must not grow memory
        }
        reapIfNeeded()
        pending.append(chunk)
        if pending.isEmpty { return isClosed() ? nil : Data() }
        let ready = pending
        pending = Data()
        return ready
    }

    func write(_ data: Data) {
        guard master >= 0 else { return }
        writeAll(master, data)
    }

    func resize(columns: Int, rows: Int) {
        guard master >= 0 else { return }
        var window = winsize(ws_row: UInt16(max(1, rows)), ws_col: UInt16(max(1, columns)),
                             ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, UInt(TIOCSWINSZ), &window)
    }

    func interrupt() { signalGroup(SIGINT) }

    func terminate() {
        signalGroup(SIGTERM)
        for _ in 0..<10 {
            reapIfNeeded()
            if exitStatus != nil { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard exitStatus == nil else { return }
        signalGroup(SIGKILL)
        // A killed child is reaped here: waiting on it without blocking keeps the
        // exit status truthful instead of leaving a zombie and a guess.
        var status: Int32 = 0
        if waitpid(pid, &status, 0) == pid { exitStatus = status }
    }

    func isClosed() -> Bool { exitStatus != nil }

    func exitCode() -> Int32? {
        guard let raw = exitStatus else { return nil }
        if exitStatus.map(Self.wasSignaled) == true { return 128 + (raw & 0x7f) }
        return (raw >> 8) & 0xff
    }

    private static func wasSignaled(_ status: Int32) -> Bool { (status & 0x7f) != 0 }

    func close() {
        if master >= 0 { closeDescriptor(master) }
        master = -1
    }

    private func signalGroup(_ signal: Int32) {
        if kill(-pid, signal) != 0 { _ = kill(pid, signal) }
    }

    private func reapIfNeeded() {
        guard exitStatus == nil else { return }
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { exitStatus = status }
    }
}
#else
/// Windows has no POSIX pty; a ConPTY backend would be its own work item.
public struct UnsupportedPtyAdapter: PlatformPtyProtocol {
    public init() {}

    public func spawn(command: [String], cwd: URL, environment: [String: String],
                      columns: Int, rows: Int) throws -> any PtyHandle {
        throw PtyError.unsupported("该平台没有伪终端后端")
    }
}
#endif
