import Foundation
import LingXiApplication
import LingXiTUI

// The interface needs a controlling terminal; reading its help or version does not. Handling
// those two here is what keeps `LingXiTUI --help | less`, a piped build check, and the packaged
// artifact smoke working instead of failing on the terminal requirement.
switch CLIParser.parse(arguments: Array(CommandLine.arguments.dropFirst())) {
case .help:
    print(CLIParser.renderHelp())
    exit(0)
case .version:
    print("LingXiTUI version \(CLIParser.version) (\(CLIParser.releaseName))")
    exit(0)
default:
    break
}

let root = AppCompositionRoot()
let tui = ApplicationTUI()
do {
    try await root.launch(with: tui)
    exit(0)
} catch {
    let message: String
    if let posix = error as? POSIXError, posix.code == .EIO || posix.code == .ENOTTY {
        message = "LingXiTUI requires an interactive controlling terminal (TTY)."
    } else {
        message = error.localizedDescription
    }
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    exit(1)
}
