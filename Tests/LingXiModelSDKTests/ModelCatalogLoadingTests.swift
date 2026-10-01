import Foundation
import Testing

@testable import LingXiModelSDK

private let smallDocument = """
{
  "schemaVersion": "2.0", "catalogRevision": "rev-1", "catalogHash": "sha256:rev1",
  "generatedAt": "2026-09-30T00:00:00Z", "source": "models.dev",
  "providers": { "p": { "id": "p", "name": "P", "env": ["P_API_KEY"], "models": {
    "m-1": { "id": "m-1", "name": "M1", "release_date": "2026-01-01", "limit": { "context": 1000, "output": 100 },
             "cost": { "input": 1, "output": 2 }, "brand_new_field": { "depth": [1, 2] } }
  } } }
}
"""

/// Answers whatever a test needs it to, and remembers what it was asked.
private actor StubTransport: ModelCatalogTransport {
    struct Reply {
        let status: Int
        let data: Data
        let etag: String?
        init(_ status: Int, _ body: String = smallDocument, etag: String? = "W/\"rev-1\"") {
            self.status = status
            self.data = Data(body.utf8)
            self.etag = status == 304 ? nil : etag
        }
    }

    private(set) var requests: [URLRequest] = []
    private var replies: [Reply]

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func respond(to request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let reply = replies.removeFirst()
        if reply.status == 0 {
            throw ModelCatalogError.transport("upstream unreachable")
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: reply.etag.map { ["ETag": $0] } ?? [:]
        )!
        return (reply.data, response)
    }
}

struct ModelCatalogLoadingTests {
    @Test("a fresh cache answers without touching the network")
    func freshCacheSkipsNetwork() async throws {
        let transport = StubTransport([.init(200)])
        let configuration = ModelCatalogConfiguration(maxAge: 1800)
        let cache = ModelCatalogCache(configuration: configuration)
        let first = try await LingXiModelCatalog.load(configuration: configuration, transport: transport, cache: cache)
        #expect(first.model(provider: "p", id: "m-1")?.contextWindow == 1000)
        _ = try await LingXiModelCatalog.load(configuration: configuration, transport: transport, cache: cache)
        #expect(await transport.requests.count == 1)
    }

    @Test("an expired copy is revalidated with the stored ETag")
    func etagRevalidation() async throws {
        let transport = StubTransport([.init(200), .init(304, "")])
        let configuration = ModelCatalogConfiguration(maxAge: 0)
        let cache = ModelCatalogCache(configuration: configuration)
        _ = try await LingXiModelCatalog.load(configuration: configuration, transport: transport, cache: cache)
        let second = try await LingXiModelCatalog.load(configuration: configuration, transport: transport, cache: cache)
        #expect(second.model(provider: "p", id: "m-1") != nil)
        let revalidation = await transport.requests[1].value(forHTTPHeaderField: "If-None-Match")
        #expect(revalidation == "W/\"rev-1\"")
    }

    @Test("an upstream outage answers with the last good copy")
    func offlineFallback() async throws {
        let transport = StubTransport([.init(200), .init(0)])
        let configuration = ModelCatalogConfiguration(maxAge: 0)
        let cache = ModelCatalogCache(configuration: configuration)
        _ = try await LingXiModelCatalog.load(configuration: configuration, transport: transport, cache: cache)
        let degraded = try await LingXiModelCatalog.load(configuration: configuration, transport: transport, cache: cache)
        #expect(degraded.revision.catalogRevision == "rev-1")
    }

    @Test("nothing on hand and nothing reachable is a failure, not an empty catalog")
    func noCopyAtAll() async throws {
        let transport = StubTransport([.init(0)])
        do {
            _ = try await LingXiModelCatalog.load(
                configuration: ModelCatalogConfiguration(maxAge: 0),
                transport: transport,
                cache: ModelCatalogCache(configuration: ModelCatalogConfiguration(maxAge: 0))
            )
            Issue.record("expected a failure")
        } catch let error as ModelCatalogError {
            switch error {
            case .transport, .unavailable: break
            default: Issue.record("expected a transport failure, got \(error)")
            }
        }
    }

    @Test("a non-200 answer is reported as such")
    func unexpectedStatus() async throws {
        let transport = StubTransport([.init(503, "")])
        await #expect(throws: ModelCatalogError.unexpectedStatus(503)) {
            _ = try await LingXiModelCatalog.load(
                configuration: ModelCatalogConfiguration(maxAge: 0),
                transport: transport,
                cache: ModelCatalogCache(configuration: ModelCatalogConfiguration(maxAge: 0))
            )
        }
    }

    @Test("a disk copy keeps the document as published, fields and all")
    func diskRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxi-model-sdk-\(UUID().uuidString)", isDirectory: true)
        let configuration = ModelCatalogConfiguration(
            endpoint: ModelCatalogConfiguration.defaultEndpoint,
            maxAge: 0,
            cacheDirectory: directory
        )
        let transport = StubTransport([.init(200)])
        _ = try await LingXiModelCatalog.load(configuration: configuration, transport: transport)

        // A second reader — a different process would look like this — must find
        // the same catalog on disk, including a field this SDK has never heard of.
        let cold = try await LingXiModelCatalog.load(
            configuration: configuration,
            transport: StubTransport([.init(200)]),
            cache: ModelCatalogCache(configuration: ModelCatalogConfiguration(maxAge: 1800, cacheDirectory: directory))
        )
        #expect(cold.model(provider: "p", id: "m-1")?.fields["brand_new_field"]?.objectValue?["depth"]?.arrayValue?.count == 2)
        #expect(cold.provider("p")?.environmentVariableNames == ["P_API_KEY"])
        let stored = try Data(contentsOf: directory.appendingPathComponent("models.json"))
        #expect(stored == Data(smallDocument.utf8))
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("load with no network at all still reads a bundled or cached document")
    func decodedWithoutNetwork() throws {
        let loaded = try LingXiModelCatalog.decoded(from: Data(smallDocument.utf8))
        #expect(loaded.revision.catalogRevision == "rev-1")
        #expect(loaded.provider("p")?.name == "P")
    }
}
