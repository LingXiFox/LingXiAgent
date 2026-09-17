#if os(macOS)
import Cocoa
import LingXiProtocol

public final class DarwinApplicationBackend: ApplicationBackend, @unchecked Sendable {
    public init() {}

    public func listRunningApplications() async throws -> [ApplicationInfo] {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard let bundleID = app.bundleIdentifier ?? app.localizedName else { return nil }
                return ApplicationInfo(
                    identifier: bundleID,
                    name: app.localizedName ?? bundleID,
                    processIdentifier: app.processIdentifier,
                    isActive: app.isActive
                )
            }
        }
    }

    public func launchApplication(identifier: String) async throws -> Int32? {
        let appURL = await MainActor.run {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        }
        guard let appURL else { return nil }
        let config = NSWorkspace.OpenConfiguration()
        let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        return app.processIdentifier
    }

    public func terminateApplication(identifier: String) async throws {
        await MainActor.run {
            let apps = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == identifier || $0.localizedName == identifier
            }
            for app in apps {
                app.terminate()
            }
        }
    }
}
#endif
