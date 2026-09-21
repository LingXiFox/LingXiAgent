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
        // ping waits between attempts and fires the first one immediately.
        return (cmd, ["/c", "ping -n \(seconds + 1) 127.0.0.1 >nul"])
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

    /// Absolute path of a usable `git`, which Windows installs under a different root.
    static func git() -> String {
        LingXiPlatform.process.resolveExecutable(
            named: "git",
            customSearchPaths: ["/usr/bin", "/bin", "/usr/local/bin"]
        ) ?? "/usr/bin/git"
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
