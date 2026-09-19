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

    public init(managedProcess: ManagedProcess, stderrCapacity: Int = 256 * 1024) {
        self.managedProcess = managedProcess
        self.stderrBuffer = StderrRingBuffer(capacity: stderrCapacity)
    }

    /// 启动子进程并建立 Stdio 双向通信管道，同时启动后台 stderr 持续排空任务
    public func connect() throws {
        writeLock.lock()
        readLock.lock()
        defer {
            readLock.unlock()
            writeLock.unlock()
        }

        guard inputHandle == nil && outputHandle == nil else { return }

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

        // 启动后台专用线程持续 drain stderr，防止子进程写满管道死锁，且不占用 Swift 合作线程池
        let drainThread = Thread { [weak self, errH] in
            while true {
                let chunk = errH.availableData
                if chunk.isEmpty {
                    break
                }
                guard let self else { break }
                self.stderrBuffer.append(chunk)
            }
        }
        drainThread.name = "org.lingxi.stdio.stderrDrain"
        drainThread.start()
    }

    /// 线程安全地写入原始字节流（受独立的写锁保护，保证写入原子性，绝不阻塞读循环）
    public func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }

        guard managedProcess.isRunning, let handle = inputHandle else {
            throw StdioTransportError.notConnected
        }

        do {
            try handle.write(contentsOf: data)
        } catch {
            throw StdioTransportError.writeFailed
        }
    }

    /// 循环读取确切数量的字节，克服底层管道的 partial read 语义
    public func readExact(count: Int) throws -> Data {
        while true {
            readLock.lock()
            guard let handle = outputHandle else {
                readLock.unlock()
                throw StdioTransportError.notConnected
            }

            if readBuffer.count >= count {
                let result = readBuffer.prefix(count)
                readBuffer.removeFirst(count)
                readLock.unlock()
                return Data(result)
            }
            readLock.unlock()

            // 绝不在持有锁时进行阻塞系统调用
            let chunk = handle.availableData
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
            guard let handle = outputHandle else {
                readLock.unlock()
                throw StdioTransportError.notConnected
            }

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

            // 绝不在持有锁时进行阻塞系统调用
            let chunk = handle.availableData
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
        guard let handle = outputHandle else {
            readLock.unlock()
            throw StdioTransportError.notConnected
        }
        readLock.unlock()

        // 绝不在持有锁时进行阻塞系统调用
        let chunk = handle.availableData
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
        // 1. 优先销毁子进程树，使操作系统内核自动关闭管道写入端，向父进程读端注入 EOF
        managedProcess.terminate(force: true)

        // 2. 关闭父进程写端与错误流
        writeLock.lock()
        let inH = inputHandle
        inputHandle = nil
        writeLock.unlock()
        try? inH?.close()

        let errH = errorHandle
        errorHandle = nil
        try? errH?.close()

        // 3. 微秒级持锁取出读端句柄并置空，绝不发生阻塞
        readLock.lock()
        let outH = outputHandle
        outputHandle = nil
        readBuffer.removeAll()
        readLock.unlock()

        // 4. 关闭输出句柄打断阻塞中的可用数据读取
        try? outH?.close()
    }

    deinit {
        close()
    }
}
