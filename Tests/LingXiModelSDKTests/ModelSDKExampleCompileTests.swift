import Foundation
import Testing

@testable import LingXiModelSDK

/// Contract §33: every Swift snippet the model site shows must be a call against
/// the real public API. This file compiles the same expressions the page prints;
/// if the page invents an API, this test stops building and CI fails, instead of
/// the codebase being chased afterwards by a screenshot.
struct ModelSDKExampleCompileTests {

    /// The snippet in `Server/models-site/public/index.html` (SDK_EXAMPLE).
    /// `ModelCatalogWebExampleTests` checks the page still contains these calls.
    @Test("the published example compiles: load, look up, read limits, capabilities and price")
    func websiteExample() async throws {
        let fixture = Data(Self.catalogJSON.utf8)
        let catalog = try LingXiModelCatalog.decoded(from: fixture)

        // load() against a transport, exactly as the page's first line does.
        let loaded = try await LingXiModelCatalog.load(
            configuration: ModelCatalogConfiguration(
                endpoint: URL(string: "https://models.lingxifox.cn/models.json")!,
                maxAge: 0
            ),
            transport: StaticTransport(json: fixture),
            cache: ModelCatalogCache(configuration: ModelCatalogConfiguration(maxAge: 0))
        )
        #expect(loaded.revision.catalogRevision == catalog.revision.catalogRevision)

        if let model = catalog.model(provider: "deepseek", id: "deepseek-v4-flash") {
            print(model.name)                          // 显示名
            print(model.contextWindow ?? 0)            // 上下文窗口（tokens）
            print(model.maxOutputTokens ?? 0)          // 输出上限（tokens）
            print(model.capabilities.reasoning)        // 是否推理模型
            print(model.capabilities.toolCalling)      // 是否支持工具调用
            print(model.pricing.input ?? 0.0)          // 输入单价（USD / 1M tokens）
            print(model.pricing.output ?? 0.0)         // 输出单价（USD / 1M tokens）
            #expect(model.contextWindow == 1_000_000)
        } else {
            Issue.record("示例引用的模型必须在目录里真实存在")
        }

        let eligible = catalog.models(matching: ModelFilter(
            vision: true,
            minimumContextWindow: 200_000
        ))
        print("\(eligible.count) 个支持视觉、窗口 ≥ 200k 的模型")
        #expect(eligible.map(\.id) == ["deepseek-v4-flash"])

        print(catalog.revision.catalogRevision)
        print(catalog.revision.generatedAt as Any)
        #expect(catalog.revision.generatedAt != nil)
    }

    /// §30's shape of the API, kept as an executable statement of the contract.
    @Test("the documented query surface answers provider, model, capability, price and limit lookups")
    func documentedSurface() throws {
        let catalog = try LingXiModelCatalog.decoded(from: Data(Self.catalogJSON.utf8))

        let provider = try #require(catalog.provider("deepseek"))
        #expect(provider.name == "DeepSeek")
        #expect(provider.baseURL == "https://api.deepseek.com")
        #expect(provider.documentationURL == "https://api.deepseek.com/docs")
        #expect(provider.environmentVariableNames == ["DEEPSEEK_API_KEY"])
        #expect(provider.modelCount == 2)

        let model = try #require(catalog.model(provider: "deepseek", id: "deepseek-v4-flash"))
        #expect(model.limits.context == 1_000_000)
        #expect(model.limits.output == 640_000)
        #expect(model.capabilities.attachments)
        #expect(model.capabilities.structuredOutput == false)
        #expect(model.capabilities.vision)
        #expect(model.pricing.input == 0.14)
        #expect(model.status.isSelectable)

        let retired = try #require(catalog.model(provider: "deepseek", id: "deepseek-v3"))
        #expect(!retired.status.isSelectable)
        #expect(retired.releaseDate == nil)
    }

    static let catalogJSON = """
    {
      "schemaVersion": "2.0",
      "catalogRevision": "782067460721",
      "catalogHash": "sha256:78206746072103d1ab163a3891190fd5",
      "generatedAt": "2026-09-30T00:00:00Z",
      "sourceFetchedAt": "2026-09-29T23:59:00Z",
      "source": "models.dev",
      "sourceURL": "https://models.dev/api.json",
      "sourceHash": "sha256:aaaabbbbccccdddd",
      "totalProviders": 1,
      "totalModels": 2,
      "providers": {
        "deepseek": {
          "id": "deepseek",
          "name": "DeepSeek",
          "api": "https://api.deepseek.com",
          "baseURL": "https://api.deepseek.com",
          "doc": "https://api.deepseek.com/docs",
          "env": ["DEEPSEEK_API_KEY"],
          "modelCount": 2,
          "models": {
            "deepseek-v4-flash": {
              "id": "deepseek-v4-flash",
              "name": "DeepSeek V4 Flash",
              "description": "Reasoning and agentic coding",
              "family": "deepseek-flash",
              "release_date": "2026-08-07",
              "reasoning": true,
              "attachment": true,
              "tool_call": true,
              "structured_output": false,
              "modalities": { "input": ["text", "image"], "output": ["text"] },
              "limit": { "context": 1000000, "input": 640000, "output": 640000 },
              "cost": { "input": 0.14, "output": 0.28, "cache_read": 0.02 }
            },
            "deepseek-v3": {
              "id": "deepseek-v3",
              "name": "DeepSeek V3",
              "status": "deprecated",
              "modalities": { "input": ["text"], "output": ["text"] },
              "limit": { "context": 64000, "output": 8000 },
              "cost": { "input": 0.14, "output": 0.28 }
            }
          }
        }
      }
    }
    """
}

private struct StaticTransport: ModelCatalogTransport {
    let json: Data

    func respond(to request: URLRequest) async throws -> (Data, URLResponse) {
        (json, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                              headerFields: ["ETag": "\"example\""])!)
    }
}
