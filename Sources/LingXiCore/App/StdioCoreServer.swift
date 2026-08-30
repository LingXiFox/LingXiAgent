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

    init(endpoint: any CoreEndpoint, input: FileHandle, output: FileHandle) {
        self.endpoint = endpoint
        self.input = input
        self.output = output
    }

    public func run() async throws {
        let writer = WireWriter(output: output)
        let events = await endpoint.events()
        let eventTask = Task {
            for await event in events {
                await writer.write(.event(event))
            }
        }
        let toolOutputEvents = await endpoint.toolOutputEvents()
        let toolOutputTask = Task {
            for await chunk in toolOutputEvents {
                await writer.write(.toolOutput(chunk))
            }
        }
        defer {
            eventTask.cancel()
            toolOutputTask.cancel()
        }

        for try await line in input.bytes.lines {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONDecoder().decode(WireMessage.self, from: data)
            else { continue }
            handleMessage(message, writer: writer)
        }
    }

    private func handleMessage(_ message: WireMessage, writer: WireWriter) {
        guard case let .request(id, command) = message else { return }
        let endpoint = self.endpoint
        Task {
            if command.isDataPlane {
                // 数据面：打开通道后 chunk 由独立任务直接写出，不经过控制面。
                do {
                    let opened = try await endpoint.openDataStream(command)
                    await writer.write(.response(id: id, response: .streamOpened(opened.id)))
                    var terminalError: CoreError?
                    do {
                        for try await chunk in opened.chunks {
                            await writer.write(.chunk(chunk))
                        }
                    } catch let error as CoreError {
                        terminalError = error
                    } catch {
                        terminalError = CoreError(code: .modelStream, message: String(describing: error))
                    }
                    await writer.write(.streamEnd(opened.id, error: terminalError))
                } catch let error as CoreError {
                    await writer.write(.response(id: id, response: .error(error)))
                } catch {
                    await writer.write(.response(id: id, response: .error(CoreError(code: .provider, message: String(describing: error)))))
                }
            } else {
                do {
                    let response = try await endpoint.handle(command)
                    await writer.write(.response(id: id, response: response))
                } catch let error as CoreError {
                    await writer.write(.response(id: id, response: .error(error)))
                } catch {
                    await writer.write(.response(id: id, response: .error(CoreError(code: .transport, message: String(describing: error)))))
                }
            }
        }
    }

    func handleMessage(_ message: WireMessage) {
        handleMessage(message, writer: WireWriter(output: output))
    }
}

/// 多个请求、Stream 和控制面事件共用 stdout；actor 保证每条 JSON-line 原子有序写出。
private actor WireWriter {
    let output: FileHandle

    init(output: FileHandle) {
        self.output = output
    }

    func write(_ message: WireMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        output.write(data + Data("\n".utf8))
    }
}
