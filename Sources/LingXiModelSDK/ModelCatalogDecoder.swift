import Foundation

/// Turns the published JSON into ``LingXiModelCatalog``.
///
/// This is the only place in the repository that knows the document layout, so a
/// schema change lands here and nowhere else. Fields the SDK does not model are
/// carried through rather than dropped, and a single malformed entry is skipped
/// instead of failing the whole catalog — one bad upstream record must not cost
/// a consumer the other eight thousand.
enum ModelCatalogDecoder {
    /// Schema major versions this SDK can read.
    static let supportedMajorVersions: Set<String> = ["1", "2"]

    struct Wire {
        let value: [String: ModelCatalogValue]

        init(_ value: ModelCatalogValue) throws {
            guard case .object(let fields) = value else {
                throw ModelCatalogError.invalidCatalog("文档根节点不是对象")
            }
            self.value = fields
        }

        func object(_ key: String) -> [String: ModelCatalogValue]? { value[key]?.objectValue }
        func string(_ key: String) -> String? { value[key]?.stringValue }
        func int(_ key: String) -> Int? { value[key]?.intValue }
    }

    static func decode(_ data: Data) throws -> LingXiModelCatalog {
        let root: Wire
        do {
            root = try Wire(ModelCatalogValue(jsonData: data))
        } catch let error as ModelCatalogError {
            throw error
        } catch {
            throw ModelCatalogError.invalidCatalog("JSON 无法解析：\(error)")
        }

        guard let providersObject = root.object("providers"), !providersObject.isEmpty else {
            throw ModelCatalogError.invalidCatalog("providers 缺失或为空")
        }

        let schemaVersion = root.string("schemaVersion") ?? root.string("version") ?? "1.0"
        let major = schemaVersion.split(separator: ".").first.map(String.init) ?? schemaVersion
        guard supportedMajorVersions.contains(major) else {
            throw ModelCatalogError.unsupportedSchemaVersion(schemaVersion)
        }
        // `updatedAt` is the v1 name for the generation timestamp.
        let generatedAt = timestamp(root.string("generatedAt") ?? root.string("updatedAt"))

        var providers: [CatalogProvider] = []
        providers.reserveCapacity(providersObject.count)
        for (key, rawProvider) in providersObject {
            guard case .object(let fields) = rawProvider else { continue }
            guard let provider = provider(id: key, fields: fields) else { continue }
            providers.append(provider)
        }
        guard !providers.isEmpty else {
            throw ModelCatalogError.invalidCatalog("没有任何可用的 provider 条目")
        }

        let revision = LingXiModelCatalog.Revision(
            schemaVersion: schemaVersion,
            catalogRevision: root.string("catalogRevision") ?? root.string("catalogHash") ?? generatedAt.map(isoString) ?? "",
            catalogHash: root.string("catalogHash"),
            source: root.string("source"),
            sourceURL: root.string("sourceURL"),
            sourceHash: root.string("sourceHash"),
            generatedAt: generatedAt,
            sourceFetchedAt: timestamp(root.string("sourceFetchedAt")),
            totalProviders: root.int("totalProviders") ?? providers.count,
            totalModels: root.int("totalModels") ?? providers.reduce(0) { $0 + $1.modelCount }
        )
        return LingXiModelCatalog(revision: revision, providers: providers)
    }

    // MARK: - Provider

    private static func provider(id: String, fields: [String: ModelCatalogValue]) -> CatalogProvider? {
        let modelsObject = fields["models"]?.objectValue ?? [:]
        var models: [CatalogModel] = []
        models.reserveCapacity(modelsObject.count)
        for (modelKey, rawModel) in modelsObject {
            guard case .object(let modelFields) = rawModel else { continue }
            if let model = model(providerID: id, key: modelKey, fields: modelFields) {
                models.append(model)
            }
        }
        // A provider with no id and no models carries nothing a consumer can use.
        guard !models.isEmpty || fields["id"] != nil else { return nil }
        return CatalogProvider(
            id: fields["id"]?.stringValue ?? id,
            name: fields["name"]?.stringValue ?? id,
            baseURL: nonEmpty(fields["baseURL"]?.stringValue),
            documentationURL: nonEmpty(fields["doc"]?.stringValue),
            environmentVariableNames: fields["env"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            models: models,
            fields: fields
        )
    }

    // MARK: - Model

    private static func model(providerID: String, key: String, fields: [String: ModelCatalogValue]) -> CatalogModel? {
        // The object key is how the catalog publishes the model, so it is the
        // identity a lookup answers to; the entry's own `id` fills in only when
        // the key is unusable.
        let id = nonEmpty(key) ?? nonEmpty(fields["id"]?.stringValue) ?? ""
        guard !id.isEmpty else { return nil }
        let limits = fields["limit"]?.objectValue ?? [:]
        let cost = fields["cost"]?.objectValue ?? [:]
        let modalities = fields["modalities"]?.objectValue ?? [:]
        let inputModalities = modalities["input"]?.stringArrayValue ?? []
        let outputModalities = modalities["output"]?.stringArrayValue ?? []
        let efforts = (fields["reasoning_options"]?.arrayValue ?? []).flatMap { option in
            option.objectValue?["values"]?.stringArrayValue ?? []
        }
        return CatalogModel(
            id: id,
            providerID: providerID,
            name: fields["name"]?.stringValue ?? id,
            family: nonEmpty(fields["family"]?.stringValue),
            overview: nonEmpty(fields["description"]?.stringValue),
            releaseDate: nonEmpty(fields["release_date"]?.stringValue),
            lastUpdated: nonEmpty(fields["last_updated"]?.stringValue),
            knowledgeCutoff: nonEmpty(fields["knowledge"]?.stringValue),
            canonicalModelID: nonEmpty(fields["canonical_model_id"]?.stringValue),
            status: CatalogModelStatus(lenient: fields["status"]?.stringValue),
            limits: ModelLimits(
                context: limits["context"]?.intValue,
                input: limits["input"]?.intValue,
                output: limits["output"]?.intValue
            ),
            capabilities: ModelCapabilities(
                reasoning: fields["reasoning"]?.boolValue ?? false,
                reasoningEfforts: efforts,
                toolCalling: fields["tool_call"]?.boolValue ?? false,
                structuredOutput: fields["structured_output"]?.boolValue ?? false,
                attachments: fields["attachment"]?.boolValue ?? false,
                vision: ModelCapabilities.contains(inputModalities, "image") || fields["attachment"]?.boolValue == true,
                audioInput: ModelCapabilities.contains(inputModalities, "audio"),
                audioOutput: ModelCapabilities.contains(outputModalities, "audio"),
                inputModalities: inputModalities,
                outputModalities: outputModalities,
                openWeights: fields["open_weights"]?.boolValue ?? false,
                supportsTemperature: fields["temperature"]?.boolValue
            ),
            pricing: ModelPricing(
                input: cost["input"]?.doubleValue,
                output: cost["output"]?.doubleValue,
                cacheRead: cost["cache_read"]?.doubleValue,
                cacheWrite: cost["cache_write"]?.doubleValue,
                reasoning: cost["reasoning"]?.doubleValue,
                inputAudio: cost["input_audio"]?.doubleValue,
                outputAudio: cost["output_audio"]?.doubleValue
            ),
            fields: fields
        )
    }

    // MARK: - Values

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static let dateFormatters: [ISO8601DateFormatter] = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFraction, plain]
    }()

    /// Accepts a full timestamp and a bare `YYYY-MM-DD` date; a value the SDK
    /// cannot read becomes `nil` rather than a wrong date.
    static func timestamp(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        if text.count == 10 {
            var components = DateComponents()
            components.year = Int(text.prefix(4))
            components.month = Int(text.dropFirst(5).prefix(2))
            components.day = Int(text.suffix(2))
            return Calendar.current.date(from: components)
        }
        return nil
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

extension ModelCatalogValue {
    /// Reads a JSON document into the value tree this SDK carries.
    init(jsonData data: Data) throws {
        self = try JSONDecoder().decode(ModelCatalogValue.self, from: data)
    }
}
