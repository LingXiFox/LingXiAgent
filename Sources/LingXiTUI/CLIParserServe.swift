import Foundation
import LingXiApplication

extension CLIParser {
    /// `lingxiagent serve` flags. Kept beside the parser so every frontend shares one
    /// flag grammar instead of the web entry point inventing its own.
    static func parseServeOptions(_ arguments: [String]) -> WebUIServeOptions {
        var options = WebUIServeOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let (flag, inlineValue) = splitFlag(argument)
            func value() -> String? {
                if let inlineValue { return inlineValue }
                index += 1
                return index < arguments.count ? arguments[index] : nil
            }

            switch flag {
            case "--port", "-p":
                if let raw = value(), let port = UInt16(raw) { options.port = port }
            case "--host":
                if let host = value(), !host.isEmpty { options.host = host }
            case "--listen":
                // `--listen 0.0.0.0:8080` is the form people reach for; split it out.
                if let spec = value() {
                    let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
                    if parts.count == 2, let port = UInt16(parts[1]) {
                        options.host = String(parts[0])
                        options.port = port
                    } else {
                        options.host = spec
                    }
                }
            case "--no-browser", "--no-open":
                options.openBrowser = false
            case "--open-browser":
                options.openBrowser = true
            case "--core-path":
                options.corePath = value()
            case "--cwd", "--workdir", "--workspace":
                options.workingDirectory = value()
            case "--resume", "-r":
                options.resumeSessionID = value()
            case "-y", "--yolo", "--yolo-mode":
                options.isYoloMode = true
            case "--allow-remote":
                options.allowRemote = true
            case "--token":
                options.accessToken = value()
            case "--insecure-disable-browser-guard":
                options.disableBrowserGuard = true
            case "--assets":
                options.assetDirectory = value()
            case "--idle-shutdown":
                if let raw = value(), let seconds = Double(raw) { options.idleShutdownSeconds = seconds }
            default:
                break
            }
            index += 1
        }
        return options
    }

    private static func splitFlag(_ argument: String) -> (String, String?) {
        guard let separator = argument.firstIndex(of: "=") else { return (argument, nil) }
        return (String(argument[..<separator]), String(argument[argument.index(after: separator)...]))
    }
}
