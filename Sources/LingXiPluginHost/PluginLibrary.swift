import Foundation
import LingXiPluginABI

enum LibraryFailure: Error, CustomStringConvertible {
    case dlopenFailed(String)
    case missingSymbol(String)
    case initRejected(code: Int32, hostMajor: UInt32, pluginMajor: UInt32)
    case abiMismatch(host: UInt32, plugin: UInt32)
    case missingTableField(String)
    case callFailed(String)
    case unusableIdentity(String)

    var description: String {
        switch self {
        case .dlopenFailed(let why): "dlopen failed: \(why)"
        case .missingSymbol(let name): "the bundle exports no \(name) symbol"
        case .initRejected(let code, let host, let plugin):
            "LingXiPlugin_Init refused: code=\(code) hostABI=\(host) pluginABI=\(plugin)"
        case .abiMismatch(let host, let plugin): "ABI major mismatch: host \(host), plugin \(plugin)"
        case .missingTableField(let field): "the plugin function table has no \(field)"
        case .callFailed(let why): why
        case .unusableIdentity(let why): why
        }
    }
}

/// One loaded plugin inside this Host process. The function table is the only way in and out, and
/// nothing here knows what the plugin does.
final class PluginLibrary {
    let abiMajor: UInt32
    let identity: PluginIdentity

    private let handle: UnsafeMutableRawPointer
    private let table: UnsafePointer<LingXiPluginAPI>

    private init(handle: UnsafeMutableRawPointer, table: UnsafePointer<LingXiPluginAPI>, abiMajor: UInt32, identity: PluginIdentity) {
        self.handle = handle
        self.table = table
        self.abiMajor = abiMajor
        self.identity = identity
    }

    var declaredHooks: [PluginIdentity.DeclaredHook] { identity.hooks }
    var bundleID: String { identity.bundleID }

    static func open(url: URL, entryPoint: String, hostAPI: UnsafePointer<LingXiHostAPI>) throws -> PluginLibrary {
        guard let handle = dlopen(url.path, RTLD_NOW) else {
            throw LibraryFailure.dlopenFailed(dlerror().map { String(cString: $0) } ?? "unknown")
        }
        guard let symbol = dlsym(handle, entryPoint) else {
            dlclose(handle)
            throw LibraryFailure.missingSymbol(entryPoint)
        }
        let initialize = unsafeBitCast(symbol, to: LingXiPluginInitFn.self)

        var returnedAPI: UnsafePointer<LingXiPluginAPI>?
        var pluginMajor: UInt32 = 0
        var status = LingXiStatus.make()
        let code = initialize(hostAPI, LingXiABI.major, &returnedAPI, &pluginMajor, &status)

        // A refusal at Init carries a code only: the table that owns buffers does not exist yet, so
        // an owned string here could never be released.
        guard code == 0, status.statusCode == .ok, let returnedAPI else {
            dlclose(handle)
            throw LibraryFailure.initRejected(code: status.code, hostMajor: LingXiABI.major, pluginMajor: pluginMajor)
        }
        guard pluginMajor == LingXiABI.major else {
            dlclose(handle)
            throw LibraryFailure.abiMismatch(host: LingXiABI.major, plugin: pluginMajor)
        }
        guard returnedAPI.pointee.abiMajor == LingXiABI.major else {
            dlclose(handle)
            throw LibraryFailure.abiMismatch(host: LingXiABI.major, plugin: returnedAPI.pointee.abiMajor)
        }

        do {
            let identity = try HookWire.decode(PluginIdentity.self, from: describe(returnedAPI))
            return PluginLibrary(handle: handle, table: returnedAPI, abiMajor: pluginMajor, identity: identity)
        } catch {
            dlclose(handle)
            throw LibraryFailure.unusableIdentity("describe did not return a readable identity: \(error)")
        }
    }

    func start(granted: [UInt8]) throws {
        guard let start = table.pointee.start else { throw LibraryFailure.missingTableField("start") }
        var status = LingXiStatus.make()
        let code = granted.withUnsafeBufferPointer { buffer in
            start(buffer.baseAddress, UInt32(buffer.count), &status)
        }
        guard code == 0, status.statusCode == .ok else {
            throw LibraryFailure.callFailed("start refused [\(status.statusCode)]")
        }
    }

    func invoke(capability: String, requestID: String, payload: [UInt8]) throws -> [UInt8] {
        guard let invoke = table.pointee.invoke else { throw LibraryFailure.missingTableField("invoke") }
        var buffer: UnsafeMutablePointer<UInt8>?
        var length: UInt32 = 0
        var status = LingXiStatus.make()
        let code = capability.withCString { name in
            requestID.withCString { identifier in
                payload.withUnsafeBufferPointer { bytes in
                    invoke(identifier, name, bytes.baseAddress, UInt32(bytes.count), &buffer, &length, &status)
                }
            }
        }
        defer { PluginLibrary.release(table, buffer) }
        guard code == 0, status.statusCode == .ok, let buffer else {
            throw LibraryFailure.callFailed("invoke \(capability) failed [\(status.statusCode)]")
        }
        return LingXiBuffer.copyBytes(buffer, length: length)
    }

    func cancel(requestID: String) -> Int32 {
        guard let cancel = table.pointee.cancel else { return -1 }
        return requestID.withCString { cancel($0) }
    }

    func stop() { table.pointee.stop?() }
    func dispose() { table.pointee.dispose?() }

    /// Only ever called with no invocation in flight (ABI rule 6).
    func close() { dlclose(handle) }

    private static func describe(_ table: UnsafePointer<LingXiPluginAPI>) throws -> [UInt8] {
        guard let describe = table.pointee.describe else { throw LibraryFailure.missingTableField("describe") }
        var buffer: UnsafeMutablePointer<UInt8>?
        var length: UInt32 = 0
        let code = describe(&buffer, &length)
        defer { release(table, buffer) }
        guard code == 0, let buffer else { throw LibraryFailure.callFailed("describe returned code \(code)") }
        return LingXiBuffer.copyBytes(buffer, length: length)
    }

    private static func release(_ table: UnsafePointer<LingXiPluginAPI>, _ buffer: UnsafeMutablePointer<UInt8>?) {
        guard let buffer, let free = table.pointee.free else { return }
        free(UnsafeMutableRawPointer(buffer))
    }
}
