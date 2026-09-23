import Foundation
import Testing
import LingXiProtocol

struct ProtocolVersionContractTests {

    @Test("ProtocolVersion current is explicitly 1.1")
    func currentProtocolVersionIsOneOne() {
        #expect(ProtocolVersion.current == ProtocolVersion(major: 1, minor: 1))
        #expect(ProtocolVersion.current.major == 1)
        #expect(ProtocolVersion.current.minor == 1)
        #expect(ProtocolVersion.current.description == "1.1")
    }

    @Test("ProtocolVersion compatibility check follows major version semantics")
    func compatibilitySemantics() {
        let v1_0 = ProtocolVersion(major: 1, minor: 0)
        let v1_1 = ProtocolVersion(major: 1, minor: 1)
        let v2_0 = ProtocolVersion(major: 2, minor: 0)

        #expect(v1_1.isCompatible(with: v1_0))
        #expect(v1_0.isCompatible(with: v1_1))
        #expect(!v1_1.isCompatible(with: v2_0))
    }

    @Test("All declared ProtocolFeature flags have non-empty unique string identifiers")
    func protocolFeatureFlagsAreValid() {
        var seen = Set<String>()
        for feature in ProtocolFeature.allCases {
            #expect(!feature.rawValue.isEmpty)
            #expect(seen.insert(feature.rawValue).inserted, "Duplicate feature flag: \(feature.rawValue)")
        }
        #expect(ProtocolFeature.allCases.count >= 7)
    }

    @Test("RuntimeCapabilities defaults contain all core ProtocolFeature flags")
    func runtimeCapabilitiesFeatureDefaults() {
        let caps = RuntimeCapabilities()
        for feature in ProtocolFeature.knownFeatures {
            #expect(caps.supportedFeatures.contains(feature), "Missing default feature in RuntimeCapabilities: \(feature.rawValue)")
        }
    }

    @Test("ExternalSpecRevision decouples vendor specs from internal protocol")
    func externalSpecRevisionDecoupled() {
        #expect(MCPSpecRevision.modern == "2024-11-05")
        #expect(ACPSpecRevision.modern == "2024-11-05")
        #expect(MCPSpecRevision.modern != ProtocolVersion.current.description)
    }
}
