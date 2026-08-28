import LingXiCore
import LingXiProtocol

let host = try CoreHost()
await host.start()
let server = StdioCoreServer(endpoint: host)
try await server.run()
await host.shutdown()
