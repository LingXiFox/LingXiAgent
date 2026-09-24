import Foundation
import LingXiProtocol
import LingXiPlatform

public struct GatewayTokenPayload: Codable, Sendable, Equatable {
    public let tokenID: String
    public let principal: CapabilityPrincipal
    public let grantIDs: [String]
    public let issuedAt: Date
    public let expiresAt: Date?

    public init(
        tokenID: String = UUID().uuidString,
        principal: CapabilityPrincipal,
        grantIDs: [String],
        issuedAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.tokenID = tokenID
        self.principal = principal
        self.grantIDs = grantIDs
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public struct IssuedToken: Sendable {
    private static let key: Data = LingXiPlatform.crypto.sha256(Data("LingXiGatewayTokenSecretKey-v1".utf8))

    public static func issue(payload: GatewayTokenPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payloadData = try encoder.encode(payload)
        let signature = LingXiPlatform.crypto.hmacSHA256(key: key, data: payloadData)

        let b64Payload = payloadData.base64EncodedString()
        let b64Sig = signature.base64EncodedString()
        return "lxgt.\(b64Payload).\(b64Sig)"
    }

    public static func verify(_ token: String) -> GatewayTokenPayload? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, parts[0] == "lxgt" else { return nil }

        guard let payloadData = Data(base64Encoded: String(parts[1])),
              let providedSig = Data(base64Encoded: String(parts[2])) else {
            return nil
        }

        let expectedSig = LingXiPlatform.crypto.hmacSHA256(key: key, data: payloadData)
        guard expectedSig == providedSig else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(GatewayTokenPayload.self, from: payloadData) else {
            return nil
        }

        if let expiresAt = payload.expiresAt, expiresAt < Date() {
            return nil
        }

        return payload
    }
}
