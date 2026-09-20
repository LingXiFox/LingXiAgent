import Foundation

public enum StdioTransportError: Error, Sendable, Equatable {
    case notConnected
    case closed
    case readFailed
    case writeFailed
    case streamClosed
}

/// 有界环形缓冲区，用于保存子进程最近的 stderr 输出，防止 pipe 写满死锁，并保留诊断线索。
public final class StderrRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private var buffer: Data
    private let lock = NSLock()

    public init(capacity: Int = 256 * 1024) {
        self.capacity = capacity
        self.buffer = Data()
        self.buffer.reserveCapacity(capacity)
    }

    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        if buffer.count + data.count <= capacity {
            buffer.append(data)
        } else if data.count >= capacity {
            buffer = data.suffix(capacity)
        } else {
            let overflow = (buffer.count + data.count) - capacity
            buffer.removeFirst(overflow)
            buffer.append(data)
        }
    }

    public func getTail(maxBytes: Int = 32 * 1024) -> Data {
        lock.lock()
        defer { lock.unlock() }
        let length = min(buffer.count, maxBytes)
        return Data(buffer.suffix(length))
    }

    public func getTailString(maxBytes: Int = 32 * 1024) -> String {
        let data = getTail(maxBytes: maxBytes)
        return String(decoding: data, as: UTF8.self)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
    }
}

/// 纯粹的 Stdio 字节流双向传输层。
/// 负责 FileHandle 的线程安全读写、数据缓冲、stderr 后台有界排空与管道关闭。
public final class StdioTransport: @unchecked Sendable {
    private let managedProcess: ManagedProcess
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    public let stderrBuffer: StderrRingBuffer
    private var readBuffer: Data = Data()
    private let writeLock = NSLock()
    private let readLock = NSLock()
    private let readStateLock = NSCondition()
    private var isClosed = false
    private var activeReaders: Int = 0
    private var isDrainActive = false

    public init(managedProcess: ManagedProcess, stderrCapacity: Int = 256 * 1024) {
        self.managedProcess = managedProcess
        self.stderrBuffer = StderrRingBuffer(capacity: stderrCapacity)
    }

    /// 启动子进程并建立 Stdio 双向通信管道，同时启动后台 stderr 持续排空任务
    public func connect() throws {
        readStateLock.lock()
        defer { readStateLock.unlock() }

        guard inputHandle == nil && outputHandle == nil && !isClosed else { return }

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        try managedProcess.launch(
            inputPipe: inPipe,
            outputPipe: outPipe,
            errorPipe: errPipe
        )

        self.inputHandle = inPipe.fileHandleForWriting
        self.outputHandle = outPipe.fileHandleForReading
        let errH = errPipe.fileHandleForReading
        self.errorHandle = errH

        // 启动后台专用线程持续 drain stderr，拥有 errorHandle 读取所有权
        self.isDrainActive = true
        let drainThread = Thread { [weak self, errH] in
            while true {
                let chunk = errH.availableData
                if chunk.isEmpty {
                    break
                }
                guard let self else { break }
                self.stderrBuffer.append(chunk)
            }
            self?.signalDrainFinished()
        }
        drainThread.name = "org.lingxi.stdio.stderrDrain"
        drainThread.start()
    }

    private func signalDrainFinished() {
        readStateLock.lock()
        defer { readStateLock.unlock() }
        isDrainActive = false
        readStateLock.broadcast()
    }

    /// 线程安全地写入原始字节流（受独立的写锁保护，保证写入原子性，绝不阻塞读循环）
    public func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }

        readStateLock.lock()
        let closed = isClosed
        readStateLock.unlock()

        guard !closed, managedProcess.isRunning, let handle = inputHandle else {
            throw StdioTransportError.notConnected
        }

        do {
            try handle.write(contentsOf: data)
        } catch {
            throw StdioTransportError.writeFailed
        }
    }

    private func beginRead() throws -> FileHandle {
        readStateLock.lock()
        defer { readStateLock.unlock() }
        if isClosed {
            throw StdioTransportError.closed
        }
        guard let handle = outputHandle else {
            throw StdioTransportError.notConnected
        }
        activeReaders += 1
        return handle
    }

    private func endRead() {
        readStateLock.lock()
        defer { readStateLock.unlock() }
        activeReaders -= 1
        if activeReaders == 0 {
            readStateLock.broadcast()
        }
    }

    /// 循环读取确切数量的字节，克服底层管道的 partial read 语义
    public func readExact(count: Int) throws -> Data {
        while true {
            readLock.lock()
            if readBuffer.count >= count {
                let result = readBuffer.prefix(count)
                readBuffer.removeFirst(count)
                readLock.unlock()
                return Data(result)
            }
            readLock.unlock()

            let handle = try beginRead()
            let chunk: Data
            do {
                chunk = handle.availableData
            }
            endRead()

            if chunk.isEmpty {
                readLock.lock()
                defer { readLock.unlock() }
                if readBuffer.count == count {
                    let result = readBuffer
                    readBuffer.removeAll()
                    return Data(result)
                }
                throw StdioTransportError.streamClosed
            }

            readLock.lock()
            readBuffer.append(chunk)
            readLock.unlock()
        }
    }

    /// 高效读取整行（基于换行符 \n），优先使用内存缓冲区，单次批量系统调用
    public func readLine(maxBytes: Int = 10 * 1024 * 1024) throws -> Data? {
        let newlineByte = UInt8(ascii: "\n")
        let crByte = UInt8(ascii: "\r")

        while true {
            readLock.lock()
            if let newlineIndex = readBuffer.firstIndex(of: newlineByte) {
                var lineData = Data(readBuffer[..<newlineIndex])
                readBuffer.removeSubrange(..<readBuffer.index(after: newlineIndex))
                readLock.unlock()
                if lineData.last == crByte {
                    lineData.removeLast()
                }
                return lineData
            }

            if readBuffer.count > maxBytes {
                readLock.unlock()
                throw StdioTransportError.readFailed
            }
            readLock.unlock()

            let handle = try beginRead()
            let chunk: Data
            do {
                chunk = handle.availableData
            }
            endRead()

            if chunk.isEmpty {
                readLock.lock()
                defer { readLock.unlock() }
                if readBuffer.isEmpty {
                    return nil
                } else {
                    var remaining = readBuffer
                    readBuffer.removeAll()
                    if remaining.last == newlineByte {
                        remaining.removeLast()
                    }
                    if remaining.last == crByte {
                        remaining.removeLast()
                    }
                    return remaining
                }
            }

            readLock.lock()
            readBuffer.append(chunk)
            readLock.unlock()
        }
    }

    /// 从内部缓冲高效获取下一个单字节（纯内存操作，缓冲为空时读取可用数据）
    public func readByte() throws -> UInt8? {
        readLock.lock()
        if !readBuffer.isEmpty {
            let b = readBuffer.removeFirst()
            readLock.unlock()
            return b
        }
        readLock.unlock()

        let handle = try beginRead()
        let chunk: Data
        do {
            chunk = handle.availableData
        }
        endRead()

        if chunk.isEmpty {
            return nil
        }

        readLock.lock()
        defer { readLock.unlock() }
        readBuffer.append(chunk)
        return readBuffer.removeFirst()
    }

    /// 获取最近的 stderr 输出字符串（供报错与诊断使用）
    public func recentStderr(maxBytes: Int = 32 * 1024) -> String {
        stderrBuffer.getTailString(maxBytes: maxBytes)
    }

    /// 关闭管道并终止子进程（先终止子进程使内核自动发送管道 EOF，解除阻塞并防止死锁）
    public func close() {
        readStateLock.lock()
        guard !isClosed else {
            readStateLock.unlock()
            return
        }
        isClosed = true
        readStateLock.unlock()

        // 1. 优先销毁子进程树，使操作系统内核自动关闭管道写入端，向父进程读端注入 EOF
        managedProcess.terminate(force: true)

        // 2. 关闭父进程写端
        writeLock.lock()
        let inH = inputHandle
        inputHandle = nil
        writeLock.unlock()
        try? inH?.close()

        // 3. 等待正在读取 availableData 的 reader 与 stderr drainer 读到 EOF 并完成退出，杜绝跨线程并发 close 句柄崩溃
        readStateLock.lock()
        let deadline = Date().addingTimeInterval(0.5)
        while (activeReaders > 0 || isDrainActive) && Date() < deadline {
            readStateLock.wait(until: deadline)
        }

        let canCloseSafely = (activeReaders == 0 && !isDrainActive)

        readLock.lock()
        let outH = outputHandle
        outputHandle = nil
        readBuffer.removeAll()
        readLock.unlock()

        let errH = errorHandle
        errorHandle = nil
        readStateLock.unlock()

        // 4. 仅当所有 reader 与 drain worker 均已退出阻塞读时，才在父进程关闭 handle，杜绝跨线程并发 close 引发 SIGILL
        if canCloseSafely {
            try? outH?.close()
            try? errH?.close()
        }
    }

    deinit {
        close()
    }
}
