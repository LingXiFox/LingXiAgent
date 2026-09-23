import Foundation
import LingXiApplication
import LingXiTUI

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
