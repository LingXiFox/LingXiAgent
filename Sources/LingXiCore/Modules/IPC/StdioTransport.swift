import Foundation

public enum StdioTransportError: Error, Sendable, Equatable {
    case notConnected
    case closed
    case readFailed
    case writeFailed
}

/// 纯粹的 Stdio 字节流双向传输层。
/// 仅负责 FileHandle 的线程安全读写、数据缓冲与管道关闭，不涉及任何高层分包协议。
public final class StdioTransport: @unchecked Sendable {
    private let managedProcess: ManagedProcess
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private let lock = NSLock()

    public init(managedProcess: ManagedProcess) {
        self.managedProcess = managedProcess
    }

    /// 启动子进程并建立 Stdio 双向通信管道
    public func connect() throws {
        lock.lock()
        defer { lock.unlock() }

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
        self.errorHandle = errPipe.fileHandleForReading
    }

    /// 线程安全地写入原始字节流
    public func write(_ data: Data) throws {
        lock.lock()
        guard managedProcess.isRunning, let handle = inputHandle else {
            lock.unlock()
            throw StdioTransportError.notConnected
        }
        let localHandle = handle
        lock.unlock()

        do {
            try localHandle.write(contentsOf: data)
        } catch {
            throw StdioTransportError.writeFailed
        }
    }

    /// 从标准输出读取指定长度的数据（若 EOF 或未连接则返回空或抛错）
    public func readExact(count: Int) throws -> Data {
        lock.lock()
        guard let handle = outputHandle else {
            lock.unlock()
            throw StdioTransportError.notConnected
        }
        let localHandle = handle
        lock.unlock()

        let data = localHandle.readData(ofLength: count)
        guard data.count == count else {
            throw StdioTransportError.readFailed
        }
        return data
    }

    /// 从标准输出读取 1 个字节
    public func readByte() throws -> UInt8? {
        lock.lock()
        guard let handle = outputHandle else {
            lock.unlock()
            throw StdioTransportError.notConnected
        }
        let localHandle = handle
        lock.unlock()

        let data = localHandle.readData(ofLength: 1)
        return data.first
    }

    /// 关闭管道并终止子进程
    public func close() {
        lock.lock()
        let inH = inputHandle
        let outH = outputHandle
        let errH = errorHandle
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        lock.unlock()

        try? inH?.close()
        try? outH?.close()
        try? errH?.close()

        managedProcess.terminate(force: true)
    }

    deinit {
        close()
    }
}
