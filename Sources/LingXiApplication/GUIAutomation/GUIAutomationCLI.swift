import Foundation
import LingXiPlatform

/// GUI commands know only the GUI IPC transport, never a Core client or submit API.
public enum GUIAutomationCLI {
    public static func parse(_ arguments: [String]) throws -> GUIAutomationRequest {
        guard let action = arguments.first.flatMap(GUIAutomationRequest.Action.init(rawValue:)) else {
            throw CLIError("Usage: lingxiagent gui send <text> | batch <tasks.json> | cancel | resume | status | trace")
        }
        var pause = false
        var source: SubmissionSource = .cli
        var values: [String] = []
        var literal = false
        for argument in arguments.dropFirst() {
            if literal { values.append(argument) }
            else if argument == "--" { literal = true }
            else if argument == "--pause-before-send" { pause = true }
            else if argument == "--benchmark" { source = .benchmark }
            else if argument.hasPrefix("--") { throw CLIError("Unknown GUI option: \(argument)") }
            else { values.append(argument) }
        }
        let tasks: [GUIAutomationTask]
        switch action {
        case .send:
            guard !values.isEmpty else { throw CLIError("gui send requires text") }
            tasks = [GUIAutomationTask(text: values.joined(separator: " "))]
        case .batch:
            guard values.count == 1, let path = values.first else { throw CLIError("gui batch requires one JSON task file") }
            tasks = try JSONDecoder().decode([GUIAutomationTask].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard !tasks.isEmpty, Set(tasks.map(\.id)).count == tasks.count else {
                throw CLIError("Batch task IDs must be unique and the batch must not be empty")
            }
        default:
            guard values.isEmpty else { throw CLIError("Unexpected GUI command arguments") }
            tasks = []
        }
        return GUIAutomationRequest(action: action, tasks: tasks, source: source, pauseBeforeSend: pause)
    }

    public static func run(arguments: [String]) async throws -> GUIAutomationResponse {
        let request = try parse(arguments)
        #if os(macOS)
        let data = try await GUIAutomationSocket.request(JSONEncoder().encode(request))
        return try JSONDecoder().decode(GUIAutomationResponse.self, from: data)
        #else
        throw CLIError("GUI automation requires the running macOS GUI")
        #endif
    }

    public struct CLIError: Error, LocalizedError {
        let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
