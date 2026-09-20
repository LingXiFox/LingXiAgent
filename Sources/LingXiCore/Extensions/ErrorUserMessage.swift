import Foundation

public extension Error {
    /// Message suitable for terminal output.
    ///
    /// `localizedDescription` routes every Swift error through NSError bridging, so an error
    /// that only adopts `CustomStringConvertible` collapses to
    /// "The operation could not be completed. (LingXiCore.ConfigurationValidationError error 1.)"
    /// and its actual diagnosis is lost. Errors that do implement `LocalizedError` (CoreError,
    /// for example) are not `CustomStringConvertible` and keep their existing prose.
    var userMessage: String {
        if let descriptive = self as? CustomStringConvertible {
            return String(describing: descriptive)
        }
        return localizedDescription
    }
}
