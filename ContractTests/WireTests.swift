import Foundation
import LingXiPluginABI
import Testing

@Test("PLG-012 a load request encodes to one JSON line and decodes back")
func PLG_012_loadFrameRoundTrips() throws {
    var request = HostRequest(id: 2, method: .load)
    request.bundlePath = "/tmp/example.lxap"
    request.policy = "development"
    let data = try JSONEncoder().encode(request)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"method\":\"load\""))
    let decoded = try JSONDecoder().decode(HostRequest.self, from: data)
    #expect(decoded.method == .load)
    #expect(decoded.bundlePath == "/tmp/example.lxap")
}
