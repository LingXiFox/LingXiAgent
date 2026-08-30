import CoreFoundation
import Foundation

public struct ConfigurationValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }

    public var description: String { "\(path): \(reason)" }
}

enum JSONSchemaValidator {
    static func validate(documentData: Data, schemaData: Data) throws {
        let document = try jsonObject(documentData, name: "configuration")
        let schema = try jsonObject(schemaData, name: "schema")
        guard let schema = schema as? [String: Any] else {
            throw ConfigurationValidationError(path: "$", reason: "bundled schema must be an object")
        }
        try validate(document, against: schema, path: "$")
    }

    private static func jsonObject(_ data: Data, name: String) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConfigurationValidationError(path: "$", reason: "invalid \(name) JSON: \(error.localizedDescription)")
        }
    }

    private static func validate(_ value: Any, against schema: [String: Any], path: String) throws {
        if let expectedType = schema["type"] as? String, !matches(value, type: expectedType) {
            throw ConfigurationValidationError(path: path, reason: "expected \(expectedType), found \(jsonType(of: value))")
        }

        if let allowed = schema["enum"] as? [Any], !allowed.contains(where: { jsonEqual($0, value) }) {
            throw ConfigurationValidationError(path: path, reason: "value is not in the allowed enum")
        }

        if let minimum = schema["minimum"] as? NSNumber, let number = numericValue(value), number < minimum.doubleValue {
            throw ConfigurationValidationError(path: path, reason: "must be at least \(minimum)")
        }

        if let object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            let required = schema["required"] as? [String] ?? []
            for key in required where object[key] == nil {
                throw ConfigurationValidationError(path: childPath(path, key), reason: "required property is missing")
            }
            if schema["additionalProperties"] as? Bool == false {
                for key in object.keys where properties[key] == nil {
                    throw ConfigurationValidationError(path: childPath(path, key), reason: "unknown property")
                }
            }
            for (key, child) in object {
                if let childSchema = properties[key] as? [String: Any] {
                    try validate(child, against: childSchema, path: childPath(path, key))
                }
            }
        }

        if let array = value as? [Any], let itemSchema = schema["items"] as? [String: Any] {
            for (index, child) in array.enumerated() {
                try validate(child, against: itemSchema, path: "\(path)[\(index)]")
            }
        }
    }

    private static func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "string": return value is String
        case "boolean": return isBoolean(value)
        case "integer":
            guard let number = numericValue(value) else { return false }
            return number.rounded(.towardZero) == number
        case "number": return numericValue(value) != nil
        default: return false
        }
    }

    private static func numericValue(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        return number.doubleValue
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func jsonType(of value: Any) -> String {
        if value is [String: Any] { return "object" }
        if value is [Any] { return "array" }
        if value is String { return "string" }
        if isBoolean(value) { return "boolean" }
        if numericValue(value) != nil { return "number" }
        return "null"
    }

    private static func jsonEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case let (left as String, right as String): return left == right
        case let (left as Bool, right as Bool): return left == right
        case let (left as NSNumber, right as NSNumber):
            return !isBoolean(left) && !isBoolean(right) && left.doubleValue == right.doubleValue
        default: return false
        }
    }

    private static func childPath(_ path: String, _ key: String) -> String {
        key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            ? "\(path).\(key)"
            : "\(path)[\(String(reflecting: key))]"
    }
}

enum ConfigurationDecoder {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            throw ConfigurationValidationError(path: path(context.codingPath + [key]), reason: "required property is missing")
        } catch let DecodingError.typeMismatch(_, context) {
            throw ConfigurationValidationError(path: path(context.codingPath), reason: context.debugDescription)
        } catch let DecodingError.valueNotFound(_, context) {
            throw ConfigurationValidationError(path: path(context.codingPath), reason: context.debugDescription)
        } catch let DecodingError.dataCorrupted(context) {
            throw ConfigurationValidationError(path: path(context.codingPath), reason: context.debugDescription)
        } catch {
            throw ConfigurationValidationError(path: "$", reason: error.localizedDescription)
        }
    }

    private static func path(_ codingPath: [any CodingKey]) -> String {
        codingPath.reduce("$") { result, key in
            key.intValue.map { "\(result)[\($0)]" } ?? "\(result).\(key.stringValue)"
        }
    }
}
