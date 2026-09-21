import Testing
import Foundation
@testable import LingXiProtocol
@testable import LingXiPlatform
@testable import LingXiCore

@Suite("IPC Peer Robustness Tests (Round 3 Phase A)")
struct IPCPeerRobustnessTests {
    private static func resolvePython() -> String {
        PortableFixture.pythonInterpreter()
    }

    @Test("StderrRingBuffer bounded storage discards oldest chunks correctly")
    func testStderrRingBufferCapacity() {
        let buffer = StderrRingBuffer(capacity: 100)
        let chunkA = Data(repeating: UInt8(ascii: "A"), count: 60)
        let chunkB = Data(repeating: UInt8(ascii: "B"), count: 60)

        buffer.append(chunkA)
        #expect(buffer.getTail().count == 60)

        buffer.append(chunkB)
        // Total 120 bytes > 100 capacity -> 20 bytes of A removed, leaving 40 of A and 60 of B
        let tail = buffer.getTail()
        #expect(tail.count == 100)
        let tailString = buffer.getTailString()
        #expect(tailString.starts(with: String(repeating: "A", count: 40)))
        #expect(tailString.hasSuffix(String(repeating: "B", count: 60)))

        buffer.clear()
        #expect(buffer.getTail().isEmpty)
    }

    @Test("Direct Stdio Pipe Roundtrip")
    func testDirectStdioPipeRoundtrip() throws {
        let script = "import sys; line = sys.stdin.readline(); sys.stdout.write('ECHO:' + line); sys.stdout.flush()"
        let proc = ManagedProcess(
            executablePath: Self.resolvePython(),
            arguments: ["-u", "-c", script]
        )
        let transport = StdioTransport(managedProcess: proc)
        try transport.connect()
        defer { transport.close() }

        try transport.write(Data("HELLO\n".utf8))
        let reply = try transport.readLine()
        #expect(String(decoding: reply ?? Data(), as: UTF8.self) == "ECHO:HELLO")
    }

    @Test("StdioTransport continuous stderr drain prevents child deadlock under heavy stderr writes")
    func testStderrDrainPreventsDeadlock() throws {
        // Run a python command that writes 128KB to stderr and then writes OK to stdout.
        // Unix pipes typically block when stderr exceeds ~64KB if not drained.
        let pythonScript = "import sys; sys.stderr.write('X' * (128 * 1024)); sys.stderr.flush(); sys.stdout.write('SUCCESS\\n'); sys.stdout.flush()"
        let proc = ManagedProcess(
            executablePath: Self.resolvePython(),
            arguments: ["-c", pythonScript],
            environment: [:]
        )
        let transport = StdioTransport(managedProcess: proc)
        try transport.connect()
        defer { transport.close() }

        // Read the result from stdout
        let line = try transport.readLine()
        #expect(line != nil)
        let resultString = String(decoding: line ?? Data(), as: UTF8.self)
        #expect(resultString == "SUCCESS")

        // Verify that stderr was drained and captured in the buffer
        let stderrTail = transport.recentStderr(maxBytes: 1024)
        #expect(stderrTail.contains("XXXX"))
        #expect(stderrTail.count == 1024)
    }

    @Test("StdioTransport readExact handles stream reads correctly")
    func testStdioTransportReadExact() throws {
        let pythonScript = "import sys; sys.stdout.write('ABCDEFGHIJ'); sys.stdout.flush()"
        let proc = ManagedProcess(
            executablePath: Self.resolvePython(),
            arguments: ["-c", pythonScript],
            environment: [:]
        )
        let transport = StdioTransport(managedProcess: proc)
        try transport.connect()
        defer { transport.close() }

        let exactData = try transport.readExact(count: 10)
        #expect(String(decoding: exactData, as: UTF8.self) == "ABCDEFGHIJ")
    }

    @Test("StdioTransport readLine handles multi-line streams with CR/LF")
    func testStdioTransportReadLine() throws {
        // Emit through the binary stream so the byte sequence is identical everywhere: on
        // Windows a text-mode sys.stdout rewrites "\n" as "\r\n", which would hand readLine a
        // second carriage return that its single trailing-CR trim cannot absorb.
        let pythonScript = "import sys; sys.stdout.buffer.write(b'Line 1\\r\\nLine 2\\nLine 3'); sys.stdout.buffer.flush()"
        let proc = ManagedProcess(
            executablePath: Self.resolvePython(),
            arguments: ["-c", pythonScript],
            environment: [:]
        )
        let transport = StdioTransport(managedProcess: proc)
        try transport.connect()
        defer { transport.close() }

        let line1 = try transport.readLine()
        #expect(String(decoding: line1 ?? Data(), as: UTF8.self) == "Line 1")

        let line2 = try transport.readLine()
        #expect(String(decoding: line2 ?? Data(), as: UTF8.self) == "Line 2")

        let line3 = try transport.readLine()
        #expect(String(decoding: line3 ?? Data(), as: UTF8.self) == "Line 3")

        let eof = try transport.readLine()
        #expect(eof == nil)
    }

    @Test("JSONRPCPeer single request roundtrip")
    func testJSONRPCPeerSingleRequest() async throws {
        let script = """
import sys, json
line = sys.stdin.readline()
msg = json.loads(line)
print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True}}), flush=True)
"""
        let proc = ManagedProcess(
            executablePath: Self.resolvePython(),
            arguments: ["-u", "-c", script]
        )
        let transport = StdioTransport(managedProcess: proc)
        let framer = LineDelimitedJSONFramer()
        let peer = JSONRPCPeer(transport: transport, framer: framer)
        try peer.start()
        defer { peer.stop() }

        let res = try await peer.request(id: 1, method: "test", timeoutSeconds: 2.0)
        let obj = try JSONSerialization.jsonObject(with: res) as? [String: Any]
        #expect(obj?["ok"] as? Bool == true)
    }

    @Test("JSONRPCPeer single reader pump accurately routes responses and preserves notifications")
    func testJSONRPCPeerRoutingAndNotifications() async throws {
        // Python mock server that echoes notifications and replies to requests with delay/interleaving
        let serverScript = """
import sys, json

for _ in range(2):
    line = sys.stdin.readline()
    if not line:
        break
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    req_id = msg.get("id")
    method = msg.get("method")

    # Whenever a request arrives, emit an interleaved notification first!
    notif = {"jsonrpc": "2.0", "method": "telemetry/event", "params": {"event": "ping", "forId": req_id}}
    print(json.dumps(notif), flush=True)

    # Then emit the response
    res = {"jsonrpc": "2.0", "id": req_id, "result": {"echoMethod": method}}
    print(json.dumps(res), flush=True)
"""
        let proc = ManagedProcess(
            executablePath: Self.resolvePython(),
            arguments: ["-u", "-c", serverScript]
        )
        let transport = StdioTransport(managedProcess: proc)
        let framer = LineDelimitedJSONFramer()
        let peer = JSONRPCPeer(transport: transport, framer: framer)

        let receivedNotifications = NotificationRecorder()
        peer.notificationHandler = { method, params in
            receivedNotifications.record(method: method, params: params)
        }

        try peer.start()
        defer { peer.stop() }

        // Send two concurrent requests
        async let req1 = peer.request(id: 101, method: "testMethodA")
        async let req2 = peer.request(id: 102, method: "testMethodB")

        let (res1, res2) = try await (req1, req2)

        let obj1 = try JSONSerialization.jsonObject(with: res1) as? [String: Any]
        #expect(obj1?["echoMethod"] as? String == "testMethodA")

        let obj2 = try JSONSerialization.jsonObject(with: res2) as? [String: Any]
        #expect(obj2?["echoMethod"] as? String == "testMethodB")

        // Wait a brief moment for all notifications to be captured
        try await Task.sleep(nanoseconds: 50_000_000)
        let notifs = receivedNotifications.get()
        #expect(notifs.count == 2)
        #expect(notifs.allSatisfy { $0 == "telemetry/event" })
    }

    @Test("JSONRPCPeer timeout triggers JSONRPCError.requestTimeout")
    func testJSONRPCPeerTimeout() async throws {
        // Python server that deliberately sleeps and never responds
        let serverScript = """
import sys, time
while True:
    line = sys.stdin.readline()
    if not line:
        break
    time.sleep(10)
"""
        let proc = ManagedProcess(
            executablePath: Self.resolvePython(),
            arguments: ["-u", "-c", serverScript]
        )
        let transport = StdioTransport(managedProcess: proc)
        let framer = LineDelimitedJSONFramer()
        let peer = JSONRPCPeer(transport: transport, framer: framer)

        try peer.start()
        defer { peer.stop() }

        var didCatchTimeout = false
        do {
            _ = try await peer.request(id: 999, method: "willTimeout", timeoutSeconds: 0.2)
        } catch let err as JSONRPCError {
            if case .requestTimeout(let id, _) = err {
                #expect(id == 999)
                didCatchTimeout = true
            }
        }
        #expect(didCatchTimeout)
    }

    @Test("JSONRPCPeer task cancellation triggers JSONRPCError.requestCancelled")
    func testJSONRPCPeerCancellation() async throws {
        let serverScript = """
import sys, time
while True:
    line = sys.stdin.readline()
    if not line:
        break
    time.sleep(10)
"""
        let proc = ManagedProcess(
            executablePath: Self.resolvePython(),
            arguments: ["-u", "-c", serverScript]
        )
        let transport = StdioTransport(managedProcess: proc)
        let framer = LineDelimitedJSONFramer()
        let peer = JSONRPCPeer(transport: transport, framer: framer)

        try peer.start()
        defer { peer.stop() }

        let task = Task {
            try await peer.request(id: 888, method: "willCancel", timeoutSeconds: 5.0)
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        var didCatchCancel = false
        do {
            _ = try await task.value
        } catch let err as JSONRPCError {
            if case .requestCancelled(let id) = err {
                #expect(id == 888)
                didCatchCancel = true
            }
        } catch {
            // Cancellation might wrap or throw CancellationError
            didCatchCancel = true
        }
        #expect(didCatchCancel)
    }

    @Test("High-frequency lifecycle stress test: start/stop JSONRPCPeer and StdioTransport 100 times without SIGILL, hang, or race")
    func testHighFrequencyStartStopStress() throws {
        let iterations = ProcessInfo.processInfo.environment["CI"] == "1" ? 20 : 100
        for _ in 1...iterations {
            let proc = ManagedProcess(
                executablePath: Self.resolvePython(),
                arguments: ["-u", "-c", "import sys; sys.stdin.readline()"]
            )
            let transport = StdioTransport(managedProcess: proc)
            let framer = LineDelimitedJSONFramer()
            let peer = JSONRPCPeer(transport: transport, framer: framer)

            try peer.start()
            peer.stop()
        }
    }
}

// Thread-safe recorder for testing
private final class NotificationRecorder: @unchecked Sendable {
    private var notifications: [String] = []
    private let lock = NSLock()

    func record(method: String, params: Data?) {
        lock.lock()
        defer { lock.unlock() }
        notifications.append(method)
    }

    func get() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return notifications
    }
}
