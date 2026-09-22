import Foundation
import LingXiPlatform

/// Platform-specialised stand-ins for the POSIX utilities test fixtures spawn.
///
/// Windows has no `/bin/sh`, `/bin/echo` or `/usr/bin/true`, so a fixture that needs a real
/// child process states the behaviour it depends on and receives this platform's native
/// equivalent. Command strings that only ever live inside configuration and are never
/// launched keep their POSIX-looking value on purpose.
enum PortableFixture {
    #if os(Windows) || canImport(WinSDK)
    private static var cmd: String {
        LingXiPlatform.process.resolveExecutable(named: "cmd.exe", customSearchPaths: nil)
            ?? #"C:\Windows\System32\cmd.exe"#
    }
    #endif

    /// A child that exits successfully without writing anything.
    static func exitSuccess() -> (command: String, arguments: [String]) {
        #if os(Windows) || canImport(WinSDK)
        return (cmd, ["/c", "exit 0"])
        #else
        return ("/usr/bin/true", [])
        #endif
    }

    /// A child that stays silent and alive for about `seconds`, then exits.
    static func sleep(_ seconds: Int) -> (command: String, arguments: [String]) {
        #if os(Windows) || canImport(WinSDK)
        let shell = LingXiPlatform.process.resolveExecutable(named: "powershell.exe", customSearchPaths: nil)
            ?? #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#
        return (shell, ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds \(seconds)"])
        #else
        return ("/bin/sleep", ["\(seconds)"])
        #endif
    }

    /// A child that writes a single line to stdout and exits.
    static func emitLine(_ text: String) -> (command: String, arguments: [String]) {
        #if os(Windows) || canImport(WinSDK)
        return (cmd, ["/c", "echo \(text)"])
        #else
        return ("/bin/echo", [text])
        #endif
    }

    /// Runs `commandLine` through the platform's shell, for fixtures that script one.
    static func shell(_ commandLine: String) -> (command: String, arguments: [String]) {
        #if os(Windows) || canImport(WinSDK)
        return (cmd, ["/c", commandLine])
        #else
        return ("/bin/sh", ["-c", commandLine])
        #endif
    }

    /// A shell command string that stays busy for about `seconds`, for fixtures that hand the
    /// command to the shell or background tools instead of exec'ing a program themselves. `sleep`
    /// does not exist on Windows, so such a command exits at once and the task under test was
    /// never running.
    static func sleepCommand(_ seconds: Int) -> String {
        #if os(Windows) || canImport(WinSDK)
        return "ping -n \(seconds + 1) 127.0.0.1 >nul"
        #else
        return "sleep \(seconds)"
        #endif
    }

    /// Re-read a value produced by background work until it is large enough, or give up.
    ///
    /// A fixed sleep is a guess about host speed: it wastes time when the write already landed
    /// and loses the race when the runner is loaded, which is how a telemetry assertion ended up
    /// indexing an empty array and aborting the whole test process. Observing the value instead
    /// keeps the assertion honest — it still fails, but with the count it actually saw.
    static func eventually<T: Collection>(
        deadlineMs: Int = 5_000,
        _ read: () async -> T,
        enough: (T) -> Bool
    ) async throws -> T {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(deadlineMs)
        var value = await read()
        while !enough(value), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            value = await read()
        }
        return value
    }

    /// Absolute path of a usable `git`, which Windows installs under a different root.
    static func git() -> String {
        LingXiPlatform.process.resolveExecutable(
            named: "git",
            customSearchPaths: ["/usr/bin", "/bin", "/usr/local/bin"]
        ) ?? "/usr/bin/git"
    }

    /// Interpreter for fixtures that script a protocol rather than a shell one-liner.
    ///
    /// Resolving by name is not enough on Windows: a zero-byte `python.exe` app-execution alias
    /// sits on PATH ahead of any real install, launches, prints a Store suggestion and exits.
    /// A fixture served by that stub reads as a transport that never answers, so a candidate is
    /// only chosen once it has actually executed a statement.
    static func pythonInterpreter() -> String {
        #if os(Windows) || canImport(WinSDK)
        let names = ["python.exe", "python"]
        let paths: [String]? = nil
        let fallback = "python.exe"
        #else
        let names = ["python3", "python"]
        let paths: [String]? = ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"]
        let fallback = "/usr/bin/python3"
        #endif
        var tried: [String] = []
        for name in names {
            guard let found = LingXiPlatform.process.resolveExecutable(named: name, customSearchPaths: paths) else {
                tried.append("\(name): not on PATH")
                continue
            }
            if interpreterRuns(found) { return found }
            tried.append("\(found): launched but did not execute the probe")
        }
        print("PortableFixture: no usable Python interpreter ([\(tried.joined(separator: ", "))]); falling back to \(fallback)")
        return fallback
    }

    /// Ask an interpreter to run one statement and look for the result on disk.
    ///
    /// The output goes to a file rather than a pipe so that a stub which never writes anything
    /// cannot leave this call blocked on an end that never arrives.
    private static func interpreterRuns(_ interpreter: String) -> Bool {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxi-python-probe-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        guard let sink = try? FileHandle(forWritingTo: marker) else { return false }
        defer { try? FileManager.default.removeItem(at: marker) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = ["-c", "import sys; sys.stdout.write('probe')"]
        process.standardOutput = sink
        process.standardError = sink
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        try? sink.close()
        guard process.terminationStatus == 0 else { return false }
        return (try? String(contentsOf: marker, encoding: .utf8))?.contains("probe") ?? false
    }

    static func python(_ script: String) -> (command: String, arguments: [String]) {
        #if os(Windows) || canImport(WinSDK)
        let tempDir = FileManager.default.temporaryDirectory
        let scriptFile = tempDir.appendingPathComponent("lingxi-fixture-\(UUID().uuidString).py")
        try? script.write(to: scriptFile, atomically: false, encoding: .utf8)
        return (pythonInterpreter(), [scriptFile.path])
        #else
        return (pythonInterpreter(), ["-c", script])
        #endif
    }

    #if os(Windows) || canImport(WinSDK)
    /// A child that reads one line from stdin and writes it back verbatim.
    ///
    /// cmd.exe cannot express this directly: `%value%` is expanded while the line is
    /// parsed, before `set /p` has assigned it, so a cmd form needs delayed expansion and
    /// still appends a newline. PowerShell reads and writes exactly.
    static func echoStdinLine() -> (command: String, arguments: [String]) {
        let shell = LingXiPlatform.process.resolveExecutable(named: "powershell.exe", customSearchPaths: nil)
            ?? #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#
        return (shell, ["-NoProfile", "-NonInteractive", "-Command",
                        "$v = [Console]::In.ReadLine(); if ($null -ne $v) { [Console]::Out.Write($v) }"])
    }
    #else
    static func echoStdinLine() -> (command: String, arguments: [String]) {
        ("/bin/sh", ["-c", #"read value; printf '%s' "$value""#])
    }
    #endif
}
