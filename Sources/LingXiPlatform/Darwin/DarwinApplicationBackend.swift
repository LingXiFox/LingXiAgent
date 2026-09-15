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
        await MainActor.run {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                let config = NSWorkspace.OpenConfiguration()
                var pid: Int32?
                let semaphore = DispatchSemaphore(value: 0)
                NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
                    pid = app?.processIdentifier
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 5.0)
                return pid
            }
            return nil
        }
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
