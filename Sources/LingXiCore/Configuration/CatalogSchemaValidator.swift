import Foundation
import LingXiProtocol

public enum CatalogValidationError: Error, LocalizedError, Equatable {
    case invalidSchema(String)
    case untrustedScheme(String)
    case fieldLengthExceeded(field: String, limit: Int)
    case duplicateModelID(String)
    case invalidEndpoint(String)
    case dangerousPayloadDetected(String)
    case unexpectedAuthDefinition(String)
    case missingRequiredField(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSchema(let msg): "Catalog schema validation failed: \(msg)"
        case .untrustedScheme(let scheme): "Catalog contains untrusted URL scheme: \(scheme)"
        case .fieldLengthExceeded(let field, let limit): "Field '\(field)' exceeded maximum length of \(limit)"
        case .duplicateModelID(let id): "Duplicate model ID detected: \(id)"
        case .invalidEndpoint(let ep): "Invalid endpoint format: \(ep)"
        case .dangerousPayloadDetected(let msg): "Dangerous/executable payload detected in catalog: \(msg)"
        case .unexpectedAuthDefinition(let msg): "Unexpected auth definition in catalog: \(msg)"
        case .missingRequiredField(let f): "Missing required catalog field: \(f)"
        }
    }
}

public enum CatalogSchemaValidator {
    private static let dangerousPatterns = [
        "<script", "javascript:", "eval(", "exec(", "/bin/sh", "/bin/bash", "__proto__", "\0"
    ]

    public static func validateStringField(_ value: String, name: String, maxLength: Int = 256) throws {
        if value.count > maxLength {
            throw CatalogValidationError.fieldLengthExceeded(field: name, limit: maxLength)
        }
        let lower = value.lowercased()
        for pat in dangerousPatterns {
            if lower.contains(pat) {
                throw CatalogValidationError.dangerousPayloadDetected("Field '\(name)' contains forbidden pattern '\(pat)'")
            }
        }
    }

    public static func validateURLString(_ urlString: String, name: String) throws {
        try validateStringField(urlString, name: name, maxLength: 1024)
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
            throw CatalogValidationError.invalidEndpoint("Invalid URL format for '\(name)': \(urlString)")
        }
        guard scheme == "https" || scheme == "http" else {
            throw CatalogValidationError.untrustedScheme(scheme)
        }
    }

    public static func validateUpstreamSnapshot(_ snapshot: UpstreamCatalogSnapshot) throws {
        try validateStringField(snapshot.version, name: "version", maxLength: 32)
        try validateStringField(snapshot.generatedAt, name: "generatedAt", maxLength: 64)

        for (providerID, provider) in snapshot.providers {
            try validateStringField(providerID, name: "providerID", maxLength: 64)
            try validateStringField(provider.id, name: "provider.id", maxLength: 64)
            try validateStringField(provider.name, name: "provider.name", maxLength: 128)

            var seenModelIDs = Set<String>()
            for (modelKey, model) in provider.models {
                try validateStringField(modelKey, name: "modelKey", maxLength: 128)
                try validateStringField(model.id, name: "model.id", maxLength: 128)
                try validateStringField(model.name, name: "model.name", maxLength: 128)

                if seenModelIDs.contains(model.id) {
                    throw CatalogValidationError.duplicateModelID(model.id)
                }
                seenModelIDs.insert(model.id)

                if let cw = model.contextWindow, cw <= 0 {
                    throw CatalogValidationError.invalidSchema("contextWindow must be positive for model \(model.id)")
                }
                if let mo = model.maxOutputTokens, mo <= 0 {
                    throw CatalogValidationError.invalidSchema("maxOutputTokens must be positive for model \(model.id)")
                }
            }
        }
    }
}
