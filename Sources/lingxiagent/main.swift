import Foundation
import LingXiCore
import LingXiProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

AuthCLI.installSignalHandlers()

let args = Array(CommandLine.arguments.dropFirst())

do {
    let output = try await AuthCLI.run(arguments: args)
    print(output)
    exit(0)
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
