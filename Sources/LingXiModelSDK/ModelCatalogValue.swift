import Foundation

/// A JSON value from the published catalog that the SDK does not model itself.
///
/// The catalog mirrors its upstream, which keeps adding fields. Dropping them
/// silently would make the published metadata unrecoverable for a consumer that
/// knows about a field the SDK does not, so anything unrecognised is retained
/// verbatim here and stays readable through this type.
public enum ModelCatalogValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null
    case object([String: ModelCatalogValue])
    case array([ModelCatalogValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ModelCatalogValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ModelCatalogValue].self))
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        guard case let .number(value) = self else { return nil }
        let rounded = value.rounded()
        return rounded == value ? Int(exactly: rounded) : nil
    }

    public var doubleValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case let .boolean(value) = self { return value }
        return nil
    }

    public var objectValue: [String: ModelCatalogValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var arrayValue: [ModelCatalogValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    /// String array of an object field, used for `modalities`.
    public var stringArrayValue: [String]? {
        arrayValue?.compactMap(\.stringValue)
    }
}
