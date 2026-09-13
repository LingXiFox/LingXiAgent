import Foundation
import LingXiApplication
import LingXiTUI

let root = AppCompositionRoot()
let tui = ApplicationTUI()
try await root.launch(with: tui)
