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

    /// §12 of the closure contract: an advertisement must be earned, never inherited.
    ///
    /// This assertion used to run the other way — it required `RuntimeCapabilities()` to contain
    /// every `knownFeatures` entry, which locked in "the enum has a case, therefore the Runtime
    /// serves it". Adding a feature case then silently promised it to every client. A default
    /// argument no longer exists, so a producer that does not state its set does not compile.
    @Test("RuntimeCapabilities cannot advertise a feature set it did not state")
    func capabilitiesHaveNoInheritedFeatureSet() {
        // `RuntimeCapabilities(...)` without `supportedFeatures:` must be a compile error.
        // Written as a type-level check: the only initialiser leaves the parameter required.
        let stated = RuntimeCapabilities(supportedFeatures: [.gitRPC])
        #expect(stated.supportedFeatures == [.gitRPC])
        #expect(Set(ProtocolFeature.allCases).isSuperset(of: Set(stated.supportedFeatures)))
    }

    /// A feature name with no RPC behind it is not a protocol feature, it is a guess.
    @Test("Every advertised ProtocolFeature names RPCs a client could actually call")
    func featureFlagsNameRealMethods() {
        for feature in ProtocolFeature.knownFeatures {
            #expect(!feature.requiredMethods.isEmpty,
                    "\(feature.rawValue) 被广播却没有任何对应的 RPC method，§12 禁止这种声明")
            for method in feature.requiredMethods {
                #expect(method.contains("."), "\(feature.rawValue) 的 \(method) 不像 method 名")
            }
        }
    }

    @Test("Feature flags that describe no RPC surface stay out of the enum")
    func noPhantomFeatures() {
        // capability.gateway / trace.stream / trace.query named Core-internal machinery with no
        // RPC, no transport dispatch and no client. Re-adding one requires wiring all three first.
        let raws = Set(ProtocolFeature.allCases.map(\.rawValue))
        for phantom in ["capability.gateway", "trace.stream", "trace.query"] {
            #expect(!raws.contains(phantom), "\(phantom) 没有 RPC 承载，不得作为协议特性广播")
        }
    }

    @Test("ExternalSpecRevision decouples vendor specs from internal protocol")
    func externalSpecRevisionDecoupled() {
        #expect(MCPSpecRevision.modern == "2024-11-05")
        #expect(ACPSpecRevision.modern == "2024-11-05")
        #expect(MCPSpecRevision.modern != ProtocolVersion.current.description)
    }
}
