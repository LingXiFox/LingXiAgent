import Foundation
import LingXiPlatform
import LingXiProtocol

/// The executable + arguments that run a shell command string on this platform.
///
/// POSIX is easy: `sh -c "<string>"` and the shell parses the string itself. Windows is not: handing
/// the same shape to `cmd.exe /c` as a single argument loses the command. Foundation escapes embedded
/// quotes as `\"` per the Win32 argument rules, `cmd.exe` does not implement those rules, and the
/// result is the command *text* echoed on stdout with exit code 0 -- a command that never ran,
/// reported as success. Measured directly on a Windows host: `cmd /c powershell -NoProfile -Command
/// "[Console]::Out.Write('out'); exit 7"` gives `stdout="[Console]::Out.Write('out')..."`,
/// `stderr=""`, `exit=0`, and the `/d /s /c "<wrapped>"` variant fails with a path error instead.
///
/// Writing the command into a `.cmd` file and invoking it by path is the shape that behaves: same
/// probe yields `stdout="out"`, `stderr="err"`, `exit=7`. The file is left in the temporary directory
/// because cmd reads a batch file as it executes; deleting it early truncates the run.
enum ShellLaunch {
    /// ponytail: preflight literal operands, not shell evaluation; the OS sandbox still enforces dynamic paths.
    static func literalFileOperands(executable: String, arguments: [String]) -> [String] {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if ["sh", "bash", "zsh"].contains(name), let index = arguments.firstIndex(of: "-c"), arguments.indices.contains(index + 1) {
            return literalFileOperands(command: arguments[index + 1])
        }
        let fileCommands: Set<String> = ["ls", "cat", "head", "tail", "wc", "stat", "file", "readlink", "du", "cd", "cp", "mv", "rm", "mkdir", "touch", "chmod", "chown", "diff", "find"]
        guard fileCommands.contains(name) else { return [] }
        return arguments.filter { !$0.isEmpty && !$0.hasPrefix("-") && !$0.contains("$") && !$0.contains("`") }
    }

    static func literalFileOperands(command: String) -> [String] {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        func flush() {
            if !word.isEmpty { words.append(word); word = "" }
        }
        for character in command {
            if escaped {
                word.append(character)
                escaped = false
            } else if character == "\\" && quote != "'" {
                escaped = true
            } else if let currentQuote = quote {
                if character == currentQuote { quote = nil }
                else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "\n" {
                flush()
                words.append(";")
            } else if character.isWhitespace {
                flush()
            } else if ";|&<>".contains(character) {
                flush()
                words.append(String(character))
            } else {
                word.append(character)
            }
        }
        guard quote == nil, !escaped else { return [] }
        flush()
        var paths: [String] = []
        var segment: [String] = []
        var redirect = false
        for word in words + [";"] {
            if [";", "|", "&"].contains(word) {
                if let executable = segment.first {
                    paths += literalFileOperands(executable: executable, arguments: Array(segment.dropFirst()))
                }
                segment.removeAll()
                redirect = false
            } else if word == "<" || word == ">" {
                redirect = true
            } else if redirect {
                if !word.contains("$") && !word.contains("`") && word != "/dev/null" { paths.append(word) }
                redirect = false
            } else {
                segment.append(word)
            }
        }
        return paths
    }

    static func invocation(for command: String) throws -> (executable: String, arguments: [String]) {
        #if os(Windows)
        let cmd = LingXiPlatform.process.resolveExecutable(named: "cmd.exe", customSearchPaths: ["C:\\Windows\\System32"])
            ?? "C:\\Windows\\System32\\cmd.exe"
        // Measured on a Windows host, both directions: `cmd /c <string>` loses an embedded quoted
        // argument entirely -- stdout came back as the command text, exit code 0 -- and running that
        // same string from a .cmd file yields the real stdout, stderr and exit code. But the batch
        // shape is not free either: the background-command cases that pass `echo 'A' && echo 'B'`
        // (no quotes at all, which cmd handles verbatim) went blind through the batch file. So take
        // the file only where the direct form is known to corrupt the command.
        if !command.contains("\"") { return (cmd, ["/c", command]) }
        return (cmd, ["/c", try writeScript(command)])
        #else
        let sh = LingXiPlatform.process.resolveExecutable(named: "sh", customSearchPaths: ["/bin", "/usr/bin"]) ?? "/bin/sh"
        return (sh, ["-c", command])
        #endif
    }

    #if os(Windows)
    private static func writeScript(_ command: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxi-shell-\(UUID().uuidString).cmd")
        // @echo off keeps the echoed command out of stdout; `exit /b %ERRORLEVEL%` carries the status
        // of the last command out, which is what cmd does without it only by accident.
        let script = "@echo off\r\n\(command)\r\nexit /b %ERRORLEVEL%\r\n"
        guard let data = script.data(using: .utf8) else {
            throw CoreError(code: .toolArgumentInvalid, message: "命令不是有效的 UTF-8 文本")
        }
        do {
            try data.write(to: url)
        } catch {
            throw CoreError(code: .toolExecutionFailed, message: "无法写入临时命令脚本: \(error.localizedDescription)")
        }
        return url.path
    }
    #endif
}
