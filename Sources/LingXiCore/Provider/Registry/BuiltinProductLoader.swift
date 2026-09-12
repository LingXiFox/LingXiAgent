import Foundation

/// Loader for built-in provider product specifications and protocol bindings.
public final class BuiltinProductLoader: Sendable {
    public static let shared = BuiltinProductLoader()

    public init() {}

    /// Loads all 27 built-in provider products combined with their protocol bindings.
    public func loadResolvedProducts() -> [String: ResolvedProviderProduct] {
        var productSpecs = loadProductsFromBundle()
        let staticProducts = BuiltinStaticCatalog.loadStaticProducts()
        for (id, spec) in staticProducts where productSpecs[id] == nil {
            productSpecs[id] = spec
        }

        var bindingsByProduct = loadBindingsFromBundle()
        let staticBindings = BuiltinStaticCatalog.loadStaticBindings()
        for binding in staticBindings {
            var map = bindingsByProduct[binding.productID] ?? [:]
            if map[binding.protocol] == nil {
                map[binding.protocol] = binding
                bindingsByProduct[binding.productID] = map
            }
        }

        var resolved: [String: ResolvedProviderProduct] = [:]
        for (id, spec) in productSpecs {
            let bindings = bindingsByProduct[id] ?? [:]
            resolved[id] = ResolvedProviderProduct(spec: spec, bindings: bindings)
        }
        return resolved
    }

    private func loadProductsFromBundle() -> [String: ProviderProductSpec] {
        var products: [String: ProviderProductSpec] = [:]
        guard let resourceURL = Bundle.module.resourceURL else {
            return products
        }

        let candidates = [
            resourceURL.appendingPathComponent("Provider/Products"),
            resourceURL.appendingPathComponent("Products"),
            resourceURL
        ]

        let fileManager = FileManager.default
        let decoder = JSONDecoder()

        for dir in candidates {
            guard fileManager.fileExists(atPath: dir.path) else { continue }
            guard let enumerator = fileManager.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "json" {
                guard let data = try? Data(contentsOf: fileURL),
                      let spec = try? decoder.decode(ProviderProductSpec.self, from: data) else {
                    continue
                }
                products[spec.id] = spec
            }
        }
        return products
    }

    private func loadBindingsFromBundle() -> [String: [String: ProviderProtocolBindingSpec]] {
        var bindings: [String: [String: ProviderProtocolBindingSpec]] = [:]
        guard let resourceURL = Bundle.module.resourceURL else {
            return bindings
        }

        let candidates = [
            resourceURL.appendingPathComponent("Provider/Protocols"),
            resourceURL.appendingPathComponent("Protocols"),
            resourceURL
        ]

        let fileManager = FileManager.default
        let decoder = JSONDecoder()

        for dir in candidates {
            guard fileManager.fileExists(atPath: dir.path) else { continue }
            guard let enumerator = fileManager.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "json" {
                guard let data = try? Data(contentsOf: fileURL),
                      let spec = try? decoder.decode(ProviderProtocolBindingSpec.self, from: data) else {
                    continue
                }
                var map = bindings[spec.productID] ?? [:]
                map[spec.protocol] = spec
                bindings[spec.productID] = map
            }
        }
        return bindings
    }
}
