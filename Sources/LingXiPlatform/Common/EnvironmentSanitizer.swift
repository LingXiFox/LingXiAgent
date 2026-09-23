import Foundation
import LingXiProtocol

/// 子进程只继承运行命令所需的环境，避免把宿主机凭据传给工具。
public enum EnvironmentSanitizer {
    public static func sanitized(from environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let envPath = environment["PATH"] ?? environment["Path"] ?? environment["path"]
        #if os(Windows)
        let defaultPath = "C:\\Windows\\System32;C:\\Windows;C:\\Windows\\System32\\Wbem;C:\\Windows\\System32\\WindowsPowerShell\\v1.0"
        #else
        let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"
        #endif
        var result = [
            "PATH": envPath ?? defaultPath,
            "HOME": environment["HOME"] ?? environment["USERPROFILE"] ?? NSHomeDirectory(),
            "LANG": environment["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": environment["TMPDIR"] ?? environment["TEMP"] ?? environment["TMP"] ?? FileManager.default.temporaryDirectory.path,
        ]
        for (key, value) in environment where key.hasPrefix("LC_") || ["DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS"].contains(key) || key.hasPrefix("ALIBABA_CLOUD_") || key.hasPrefix("ALICLOUD_") {
            if key != "DEVELOPER_DIR" || FileManager.default.fileExists(atPath: value) {
                result[key] = value
            }
        }
        // The allow-list above intentionally excludes every LINGXI_* value, including test sentinels.
        for key in osBootstrapKeys {
            if let entry = environment.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                result[key] = entry.value
            }
        }
        return result
    }

    /// A child process on Windows cannot boot without knowing where the OS lives: .NET and
    /// PowerShell fail to load their providers without SystemRoot, and nothing resolves an
    /// executable or a scratch directory without PATHEXT, COMSPEC and TEMP. None of these carry
    /// credentials, so they join the minimal environment rather than being stripped with it.
    /// They are absent on POSIX, which keeps that side of the sanitizer unchanged.
    public static let osBootstrapKeys = [
        "SystemRoot", "windir", "SystemDrive", "ProgramFiles", "ProgramFiles(x86)",
        "ProgramData", "CommonProgramFiles", "CommonProgramFiles(x86)",
        "USERPROFILE", "COMSPEC", "PATHEXT", "TEMP", "TMP", "LOCALAPPDATA", "APPDATA", "PSModulePath"
    ]
}
