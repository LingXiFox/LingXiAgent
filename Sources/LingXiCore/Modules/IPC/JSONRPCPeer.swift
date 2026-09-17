import Foundation

public enum JSONRPCError: Error, Sendable, Equatable {
    case connectionClosed
    case invalidMessage
    case remoteError(code: Int, message: String)
    case requestFailed(String)
    case requestTimeout(id: Int, timeoutSeconds: Double)
    case requestCancelled(id: Int)
}

/// JSON-RPC 2.0 端点对等端（Peer）。
/// 组合底层的 Stdio 传输流与指定的消息分帧器，基于单一异步 Reader Pump 流水线，
/// 保证多请求并发响应路由、Notification 分发以及超时与取消机制。
public final class JSONRPCPeer: @unchecked Sendable {
    private let transport: StdioTransport
    private let framer: any MessageFramer
    private let lock = NSLock()

    // 正在等待响应的请求 Continuation 注册表
    private var pendingRequests: [Int: CheckedContinuation<Data, any Error>] = [:]

    private var isStarted = false

    // 外部通知处理回调
    public var notificationHandler: (@Sendable (String, Data?) -> Void)?

    // 外部服务端反向请求处理回调 (id, method, params) -> resultData
    public var serverRequestHandler: (@Sendable (Int, String, Data?) async throws -> Data)?

    public init(transport: StdioTransport, framer: any MessageFramer) {
        self.transport = transport
        self.framer = framer
    }

    deinit {
        stop()
    }

    /// 启动底层连接并开始后台 Reader Pump（基于专用系统线程，不阻塞 Swift 并发线程池）
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isStarted else { return }

        try transport.connect()
        isStarted = true

        let thread = Thread { [weak self] in
            self?.runReaderPumpLoop()
        }
        thread.name = "org.lingxi.ipc.jsonrpcPump"
        thread.start()
    }

    /// 注册等待中的请求 continuation，如果未启动则返回 false
    @discardableResult
    private func registerPending(id: Int, continuation: CheckedContinuation<Data, any Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isStarted else { return false }
        pendingRequests[id] = continuation
        return true
    }

    /// 根据 ID 移除并返回对应的 continuation
    private func removePending(id: Int) -> CheckedContinuation<Data, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        return pendingRequests.removeValue(forKey: id)
    }

    /// 排空并返回所有等待中的 continuation，同时标记停止
    private func drainAllPending() -> [CheckedContinuation<Data, any Error>] {
        lock.lock()
        defer { lock.unlock() }
        let all = Array(pendingRequests.values)
        pendingRequests.removeAll()
        isStarted = false
        return all
    }

    /// 停止 Peer，终止 Reader Pump 并取消所有等待中的请求
    public func stop() {
        lock.lock()
        isStarted = false
        lock.unlock()

        transport.close()

        let pendings = drainAllPending()
        for continuation in pendings {
            continuation.resume(throwing: JSONRPCError.connectionClosed)
        }
    }

    /// 发送单向通知（Notification，不带 ID）
    public func notify(method: String, parameters: Data? = nil) throws {
        let paramObj: Any = {
            if let parameters, let obj = try? JSONSerialization.jsonObject(with: parameters) {
                return obj
            }
            return [String: Any]()
        }()
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": paramObj
        ]
        let payload = try JSONSerialization.data(withJSONObject: message)
        let framed = framer.frame(payload: payload)
        try transport.write(framed)
    }

    /// 异步发送请求并等待响应（支持超时与 Task 取消，响应由统一 Reader Pump 路由）
    public func request(
        id: Int,
        method: String,
        parameters: Data? = nil,
        timeoutSeconds: Double = 30.0
    ) async throws -> Data {
        let paramObj: Any = {
            if let parameters, let obj = try? JSONSerialization.jsonObject(with: parameters) {
                return obj
            }
            return [String: Any]()
        }()
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": paramObj
        ]
        let payload = try JSONSerialization.data(withJSONObject: message)
        let framed = framer.frame(payload: payload)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                guard self.registerPending(id: id, continuation: continuation) else {
                    continuation.resume(throwing: JSONRPCError.connectionClosed)
                    return
                }

                do {
                    try self.transport.write(framed)
                } catch {
                    let removed = self.removePending(id: id)
                    removed?.resume(throwing: error)
                    return
                }

                if timeoutSeconds > 0 {
                    Task.detached { [weak self, id, timeoutSeconds] in
                        try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                        guard let self else { return }
                        let pending = self.removePending(id: id)
                        pending?.resume(throwing: JSONRPCError.requestTimeout(id: id, timeoutSeconds: timeoutSeconds))
                    }
                }
            }
        } onCancel: { [weak self, id] in
            guard let self else { return }
            let pending = self.removePending(id: id)
            pending?.resume(throwing: JSONRPCError.requestCancelled(id: id))
        }
    }

    /// 同步适配请求方法（用于兼容原有同步调用方，例如 GenericProcessLSPTransport）
    public func requestSync(
        id: Int,
        method: String,
        parameters: Data? = nil,
        timeoutSeconds: Double = 30.0
    ) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var capturedResult: Result<Data, any Error>?

        Task {
            do {
                let data = try await self.request(id: id, method: method, parameters: parameters, timeoutSeconds: timeoutSeconds)
                capturedResult = .success(data)
            } catch {
                capturedResult = .failure(error)
            }
            semaphore.signal()
        }

        let timeoutResult = semaphore.wait(timeout: .now() + timeoutSeconds)
        if timeoutResult == .timedOut {
            let pending = self.removePending(id: id)
            pending?.resume(throwing: JSONRPCError.requestTimeout(id: id, timeoutSeconds: timeoutSeconds))
            throw JSONRPCError.requestTimeout(id: id, timeoutSeconds: timeoutSeconds)
        }

        guard let result = capturedResult else {
            throw JSONRPCError.requestFailed("No response received")
        }

        switch result {
        case .success(let data):
            return data
        case .failure(let err):
            throw err
        }
    }

    /// 核心 Reader Pump：在后台专用守护线程中单源消费 Stdio 数据流，分发 Response、Notification 和 Server Request
    private func runReaderPumpLoop() {
        while true {
            lock.lock()
            let running = isStarted
            lock.unlock()
            guard running else { break }

            let payload: Data?
            do {
                payload = try framer.readNextPayload(from: transport)
            } catch {
                break
            }

            guard let payload else {
                break
            }

            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                continue
            }

            // 1. 判断是否为 Response (包含 id，且没有 method)
            if let respID = (object["id"] as? NSNumber)?.intValue, object["method"] == nil {
                guard let pending = removePending(id: respID) else {
                    continue
                }

                if let errorObj = object["error"] as? [String: Any] {
                    let code = (errorObj["code"] as? NSNumber)?.intValue ?? -1
                    let msg = (errorObj["message"] as? String) ?? "Unknown remote error"
                    pending.resume(throwing: JSONRPCError.remoteError(code: code, message: msg))
                } else if let result = object["result"] {
                    if let resultData = try? JSONSerialization.data(withJSONObject: result) {
                        pending.resume(returning: resultData)
                    } else {
                        pending.resume(returning: Data("null".utf8))
                    }
                } else {
                    pending.resume(returning: Data("null".utf8))
                }
                continue
            }

            // 2. 判断是否为 Notification (包含 method，无 id)
            if let method = object["method"] as? String, object["id"] == nil {
                let paramsData: Data? = {
                    if let params = object["params"],
                       let d = try? JSONSerialization.data(withJSONObject: params) {
                        return d
                    }
                    return nil
                }()
                notificationHandler?(method, paramsData)
                continue
            }

            // 3. 判断是否为 Server Request (同时包含 id 和 method)
            if let reqID = (object["id"] as? NSNumber)?.intValue, let method = object["method"] as? String {
                let paramsData: Data? = {
                    if let params = object["params"],
                       let d = try? JSONSerialization.data(withJSONObject: params) {
                        return d
                    }
                    return nil
                }()

                if let handler = serverRequestHandler {
                    Task { [weak self, reqID, method, paramsData] in
                        guard let self else { return }
                        do {
                            let resultData = try await handler(reqID, method, paramsData)
                            let resultObj = (try? JSONSerialization.jsonObject(with: resultData)) ?? NSNull()
                            let response: [String: Any] = [
                                "jsonrpc": "2.0",
                                "id": reqID,
                                "result": resultObj
                            ]
                            if let resPayload = try? JSONSerialization.data(withJSONObject: response) {
                                let framed = self.framer.frame(payload: resPayload)
                                try? self.transport.write(framed)
                            }
                        } catch {
                            let response: [String: Any] = [
                                "jsonrpc": "2.0",
                                "id": reqID,
                                "error": [
                                    "code": -32603,
                                    "message": error.localizedDescription
                                ]
                            ]
                            if let resPayload = try? JSONSerialization.data(withJSONObject: response) {
                                let framed = self.framer.frame(payload: resPayload)
                                try? self.transport.write(framed)
                            }
                        }
                    }
                }
                continue
            }
        }

        // Reader Pump 退出（流关闭或出错），唤醒并拒绝所有未完成请求
        let remaining = drainAllPending()
        for continuation in remaining {
            continuation.resume(throwing: JSONRPCError.connectionClosed)
        }
    }
}

