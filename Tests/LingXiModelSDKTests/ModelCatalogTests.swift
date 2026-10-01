import Foundation
import Testing

@testable import LingXiModelSDK

/// A published catalog with one dated model and one legacy v1 document.
private let v2Document = """
{
  "schemaVersion": "2.0",
  "catalogRevision": "a1b2c3d4e5f6",
  "catalogHash": "sha256:1111222233334444",
  "generatedAt": "2026-09-30T00:00:00Z",
  "sourceFetchedAt": "2026-09-29T23:59:00Z",
  "source": "models.dev",
  "sourceURL": "https://models.dev/api.json",
  "sourceHash": "sha256:aaaabbbbccccdddd",
  "totalProviders": 2,
  "totalModels": 4,
  "providers": {
    "openai": {
      "id": "openai",
      "name": "OpenAI",
      "env": ["OPENAI_API_KEY"],
      "doc": "https://platform.openai.com/docs/models",
      "api": "https://api.openai.com/v1",
      "models": {
        "gpt-5-nano": {
          "id": "gpt-5-nano",
          "name": "GPT-5 Nano",
          "family": "gpt-nano",
          "description": "Tiny GPT-5 lane",
          "release_date": "2025-08-07",
          "last_updated": "2025-08-07",
          "reasoning": true,
          "reasoning_options": [{ "type": "effort", "values": ["minimal", "low", "medium", "high"] }],
          "tool_call": true,
          "structured_output": true,
          "attachment": true,
          "temperature": false,
          "open_weights": false,
          "modalities": { "input": ["text", "image"], "output": ["text"] },
          "limit": { "context": 400000, "input": 272000, "output": 128000 },
          "cost": { "input": 0.05, "output": 0.4, "cache_read": 0.005 },
          "experimental": { "warmup": true }
        },
        "gpt-5-mini": {
          "id": "gpt-5-mini",
          "name": "GPT-5 Mini",
          "family": "gpt-mini",
          "release_date": "2026-01-15",
          "reasoning": true,
          "tool_call": true,
          "modalities": { "input": ["text"], "output": ["text"] },
          "limit": { "context": 200000, "output": 64000 },
          "cost": { "input": 0.25, "output": 2.0 }
        }
      }
    },
    "deepseek": {
      "id": "deepseek",
      "name": "DeepSeek",
      "env": ["DEEPSEEK_API_KEY"],
      "models": {
        "deepseek-v4": {
          "id": "deepseek-v4",
          "name": "DeepSeek V4",
          "family": "deepseek",
          "release_date": "2026-03-01",
          "tool_call": true,
          "modalities": { "input": ["text"], "output": ["text"] },
          "limit": { "context": 128000, "output": 8000 },
          "cost": { "input": 0.14, "output": 0.28 }
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

private func catalog(_ json: String) throws -> LingXiModelCatalog {
    try LingXiModelCatalog.decoded(from: Data(json.utf8))
}

struct ModelCatalogDecodingTests {
    @Test("the published envelope is read as schema version, revision and provenance")
    func envelope() throws {
        let revision = try catalog(v2Document).revision
        #expect(revision.schemaVersion == "2.0")
        #expect(revision.catalogRevision == "a1b2c3d4e5f6")
        #expect(revision.catalogHash == "sha256:1111222233334444")
        #expect(revision.source == "models.dev")
        #expect(revision.sourceHash == "sha256:aaaabbbbccccdddd")
        #expect(revision.generatedAt != nil)
        #expect(revision.sourceFetchedAt != nil)
        #expect(revision.totalProviders == 2)
        #expect(try catalog(v2Document).totalModels == 4)
    }

    @Test("typed accessors answer limits, capabilities and price from one model")
    func typedAccessors() throws {
        let model = try catalog(v2Document).model(provider: "openai", id: "gpt-5-nano")
        #expect(model?.name == "GPT-5 Nano")
        #expect(model?.contextWindow == 400_000)
        #expect(model?.maxOutputTokens == 128_000)
        #expect(model?.capabilities.reasoning == true)
        #expect(model?.capabilities.reasoningEfforts == ["minimal", "low", "medium", "high"])
        #expect(model?.capabilities.toolCalling == true)
        #expect(model?.capabilities.structuredOutput == true)
        #expect(model?.capabilities.vision == true)
        #expect(model?.capabilities.audioInput == false)
        #expect(model?.capabilities.supportsTemperature == false)
        #expect(model?.pricing.input == 0.05)
        #expect(model?.pricing.output == 0.4)
        #expect(model?.pricing.cacheRead == 0.005)
        #expect(model?.pricing.inputAudio == nil)
        #expect(model?.qualifiedID == "openai/gpt-5-nano")
    }

    @Test("a field the SDK does not model is retained, not silently dropped")
    func unknownFieldsSurvive() throws {
        let model = try catalog(v2Document).model(provider: "openai", id: "gpt-5-nano")
        #expect(model?.fields["experimental"]?.objectValue?["warmup"]?.boolValue == true)
        // The provider's own upstream `api` field is kept even though the SDK
        // exposes it under its own name.
        let provider = try catalog(v2Document).provider("openai")
        #expect(provider?.fields["api"]?.stringValue == "https://api.openai.com/v1")
        #expect(provider?.environmentVariableNames == ["OPENAI_API_KEY"])
    }

    @Test("absent metadata stays nil instead of becoming zero or false")
    func missingValuesStayUnknown() throws {
        let provider = try catalog(v2Document).provider("deepseek")
        #expect(provider?.baseURL == nil)
        #expect(provider?.documentationURL == nil)
        let model = try catalog(v2Document).model(provider: "deepseek", id: "deepseek-v4")
        #expect(model?.lastUpdated == nil)
        #expect(model?.knowledgeCutoff == nil)
        #expect(model?.capabilities.structuredOutput == false)
        #expect(model?.capabilities.supportsTemperature == nil)
        #expect(try catalog(v2Document).model(provider: "openai", id: "gpt-5-mini")?.limits.input == nil)
    }

    @Test("a v1 document is still readable under its own field names")
    func legacyDocument() throws {
        let legacy = """
        {
          "version": "1.0",
          "updatedAt": "2026-09-12T08:11:58Z",
          "totalProviders": 1,
          "totalModels": 1,
          "providers": {
            "ollama": {
              "id": "ollama", "name": "Ollama", "baseURL": "http://localhost:11434",
              "swiftDriver": "ollamaNative", "env": [],
              "models": { "llama": { "id": "llama", "name": "Llama", "limit": { "context": 8192, "output": 2048 } } }
            }
          }
        }
        """
        let loaded = try catalog(legacy)
        #expect(loaded.revision.schemaVersion == "1.0")
        #expect(loaded.revision.generatedAt != nil)
        #expect(loaded.model(provider: "ollama", id: "llama")?.contextWindow == 8192)
        // A runtime guess in an old publication is data, never an answer.
        #expect(loaded.provider("ollama")?.baseURL == "http://localhost:11434")
    }

    @Test("a schema this SDK cannot interpret is refused, not half-read")
    func unsupportedSchema() {
        let future = v2Document.replacingOccurrences(of: "\"schemaVersion\": \"2.0\"", with: "\"schemaVersion\": \"3.0\"")
        #expect(throws: ModelCatalogError.unsupportedSchemaVersion("3.0")) {
            _ = try catalog(future)
        }
    }

    @Test("a structurally broken document raises instead of yielding an empty catalog")
    func brokenDocument() {
        #expect(throws: ModelCatalogError.self) { _ = try catalog(#"{"schemaVersion":"2.0","providers":{}}"#) }
        #expect(throws: ModelCatalogError.self) { _ = try catalog(#"{"schemaVersion":"2.0"}"#) }
        #expect(throws: ModelCatalogError.self) { _ = try catalog("not json at all") }
    }

    @Test("one malformed entry costs that entry, not the catalog")
    func malformedEntry() throws {
        let mixed = """
        {
          "schemaVersion": "2.0", "catalogRevision": "r1",
          "providers": { "p": { "id": "p", "name": "P", "models": {
            "good": { "id": "good", "name": "Good", "limit": { "context": 100, "output": 10 } },
            "bad": "not-an-object",
            "": { "name": "No identity at all" }
          } } }
        }
        """
        let loaded = try catalog(mixed)
        #expect(loaded.model(provider: "p", id: "good") != nil)
        #expect(loaded.model(provider: "p", id: "bad") == nil)
        // An entry with neither a key nor an id has no identity to select it by.
        #expect(loaded.provider("p")?.models.map(\.id) == ["good"])
    }

    /// The object key is the model's identity, so an entry that disagrees with it
    /// is still reachable under the key the catalog publishes it by.
    @Test("a model entry is reachable under its published key")
    func keyIsTheIdentity() throws {
        let mismatched = """
        {
          "schemaVersion": "2.0", "catalogRevision": "r1",
          "providers": { "p": { "id": "p", "name": "P", "models": {
            "published-under-this-key": { "id": "somewhere-else", "name": "N", "limit": { "context": 10 } }
          } } }
        }
        """
        let loaded = try catalog(mismatched)
        #expect(loaded.model(provider: "p", id: "published-under-this-key")?.name == "N")
        #expect(loaded.model(provider: "p", id: "somewhere-else") == nil)
    }
}

struct ModelCatalogOrderingTests {
    @Test("providers sort by display name with id as the stable tie-break")
    func providerOrder() throws {
        let names = try catalog(v2Document).sortedProviders().map(\.name)
        #expect(names == ["DeepSeek", "OpenAI"])
    }

    @Test("an explicit featured list ranks first; nothing is featured by default")
    func featuredOrder() throws {
        #expect(try catalog(v2Document).sortedProviders().map(\.id) == ["deepseek", "openai"])
        #expect(try catalog(v2Document).sortedProviders(featured: ["openai"]).map(\.id) == ["openai", "deepseek"])
        #expect(
            try catalog(v2Document).sortedProviders(featured: ["openai", "deepseek"]).map(\.id) == ["openai", "deepseek"],
            "featured order is the caller's order, not alphabetical"
        )
    }

    @Test("models sort newest first, then family, then id — never by insertion order")
    func modelOrder() throws {
        let ids = try catalog(v2Document).models(provider: "openai").map(\.id)
        #expect(ids == ["gpt-5-mini", "gpt-5-nano"])
        let deepseek = try catalog(v2Document).models(provider: "deepseek").map(\.id)
        // Undated entries never displace dated ones.
        #expect(deepseek == ["deepseek-v4", "deepseek-v3"])
    }

    @Test("the same catalog always renders the same order")
    func deterministic() throws {
        let first = try catalog(v2Document).allModels.map(\.qualifiedID)
        let second = try catalog(v2Document).allModels.map(\.qualifiedID)
        #expect(first == second)
        #expect(first.count == 4)
    }
}

struct ModelCatalogQueryTests {
    @Test("lookup answers by provider, by bare id and by qualified id")
    func lookups() throws {
        let loaded = try catalog(v2Document)
        #expect(loaded.model(provider: "OpenAI", id: "GPT-5-Nano")?.family == "gpt-nano")
        #expect(loaded.model(id: "openai/gpt-5-nano") != nil)
        #expect(loaded.model(id: "gpt-5-nano")?.providerID == "openai")
        #expect(loaded.model(provider: "anthropic", id: "gpt-5-nano") == nil)
        #expect(loaded.provider("nope") == nil)
    }

    @Test("filtering answers from published metadata only")
    func filters() throws {
        let loaded = try catalog(v2Document)
        #expect(loaded.models(matching: ModelFilter(reasoning: true)).map(\.id) == ["gpt-5-mini", "gpt-5-nano"])
        #expect(loaded.models(matching: ModelFilter(vision: true)).map(\.id) == ["gpt-5-nano"])
        #expect(loaded.models(matching: ModelFilter(minimumContextWindow: 200_000)).count == 2)
        // Deprecated is withheld by default, and available on request.
        #expect(loaded.models(matching: ModelFilter(providerID: "deepseek")).map(\.id) == ["deepseek-v4"])
        #expect(loaded.models(matching: ModelFilter(providerID: "deepseek", includeDeprecated: true)).count == 2)
        #expect(loaded.model(provider: "deepseek", id: "deepseek-v3")?.status == .deprecated)
        #expect(loaded.model(provider: "deepseek", id: "deepseek-v3")?.status.isSelectable == false)
    }

    @Test("search matches model id, name and provider")
    func search() throws {
        let loaded = try catalog(v2Document)
        #expect(!loaded.search("nano").isEmpty)
        #expect(loaded.search("nano").first?.id == "gpt-5-nano")
        #expect(loaded.search("deepseek").count == 2)
        #expect(loaded.search("zzz-nothing").isEmpty)
        #expect(loaded.search("gpt", limit: 1).count == 1)
    }
}
