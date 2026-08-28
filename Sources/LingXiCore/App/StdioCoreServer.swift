import Foundation
import LingXiProtocol

/// 把 CoreEndpoint 暴露为 stdio JSON-lines 服务。
/// 请求在控制面处理；openTestStream 按数据面路由，
/// chunk 由独立任务直接写出，不经过控制面事件。
public struct StdioCoreServer: Sendable {
    private let endpoint: any CoreEndpoint
    private let input: FileHandle
    private let output: FileHandle

    public init(endpoint: any CoreEndpoint) {
        self.endpoint = endpoint
        self.input = .standardInput
        self.output = .standardOutput
    }

    public func run() async throws {
        let write = makeWriter()
        for try await line in input.bytes.lines {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONDecoder().decode(WireMessage.self, from: data)
            else { continue }
            handleMessage(message, write: write)
        }
    }

    private func handleMessage(_ message: WireMessage, write: @escaping @Sendable (WireMessage) -> Void) {
        guard case let .request(id, command) = message else { return }
        let endpoint = self.endpoint
        Task {
            if command.isDataPlane {
                do {
                    let opened = try await endpoint.openTestStream()
                    write(.response(id: id, response: .streamOpened(opened.id)))
                    // 数据面 pump：独立于控制面，chunk 直接流出。
                    do {
                        for try await chunk in opened.chunks {
                            write(.chunk(chunk))
                        }
                    } catch let error as CoreError {
                        write(.response(id: id, response: .error(error)))
                    } catch {
                        write(.response(id: id, response: .error(CoreError(code: .transport, message: String(describing: error)))))
                    }
                    write(.streamEnd(opened.id))
                } catch let error as CoreError {
                    write(.response(id: id, response: .error(error)))
                } catch {
                    write(.response(id: id, response: .error(CoreError(code: .transport, message: String(describing: error)))))
                }
            } else {
                do {
                    let response = try await endpoint.handle(command)
                    write(.response(id: id, response: response))
                } catch let error as CoreError {
                    write(.response(id: id, response: .error(error)))
                } catch {
                    write(.response(id: id, response: .error(CoreError(code: .transport, message: String(describing: error)))))
                }
            }
        }
    }

    private func makeWriter() -> @Sendable (WireMessage) -> Void {
        let output = self.output
        let newline = Data("\n".utf8)
        return { message in
            guard let data = try? JSONEncoder().encode(message) else { return }
            output.write(data)
            output.write(newline)
        }
    }
}
