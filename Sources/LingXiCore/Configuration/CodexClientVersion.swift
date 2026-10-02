import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LingXiProtocol

/// The Codex CLI version LingXi presents to the ChatGPT backend, kept current from upstream releases.
///
/// The backend gates on this value rather than reporting the gate. `GET /backend-api/codex/models`
/// filters its list against `client_version` per model, and a version that has fallen behind simply
/// returns fewer models with nothing in the response saying anything was withheld. Measured against a
/// real account: `0.154.0` listed 7 models, `0.159.3` listed 10 — the three extras being
/// `gpt-6.1-sol`, `gpt-6-sol` and `gpt-6-luna`. A hand-maintained constant therefore rots quietly, so
/// it is fetched instead.
///
/// Reading stays synchronous because the value is consumed while building a request
/// (`ClientFingerprint.userAgent`, the models URL); a refresh is asynchronous and opportunistic. An
/// un-refreshed process uses ``floor``, which is a version known to work, never an empty or zero
/// version.
public enum CodexClientVersion {
    /// Used until a fetch succeeds, and whenever one fails. Keep this a version that has been
    /// observed to work; it is the floor, not the target.
    public static let floor = "0.159.3"

    /// Upstream releases land every few days; a day is fresh enough without spending a request per
    /// launch, and the unauthenticated GitHub API allows 60/hour per address.
    static let ttl: TimeInterval = 24 * 3600

    static let releasesURL = URL(string: "https://api.github.com/repos/openai/codex/releases/latest")!

    /// How long to wait before retrying after a fetch that failed or learned nothing. A transient
    /// GitHub outage or a rate-limit hit must not cost a full TTL of the newest models.
    static let retryInterval: TimeInterval = 15 * 60

    /// Turns a release tag into a client version.
    ///
    /// Tags carry a `rust-v` prefix and the release list is full of `-alpha.N` prereleases; claiming a
    /// prerelease version would put LingXi behind a protocol shape it has not implemented.
    static func version(fromTag tag: String) -> String? {
        let stripped = tag.hasPrefix("rust-v") ? String(tag.dropFirst(6))
            : tag.hasPrefix("v") ? String(tag.dropFirst(1)) : tag
        let parts = stripped.split(separator: ".").map(String.init)
        guard parts.count == 3,
              stripped.allSatisfy({ $0.isNumber || $0 == "." }),
              parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return stripped
    }

    /// Picks the version to claim: an explicit override, then the last fetched release, then the floor.
    /// The highest wins, so a fetch that returns something older than the floor cannot regress a
    /// working configuration.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["CODEX_CLI_VERSION"], !override.isEmpty { return override }
        return Store.shared.resolved()
    }

    /// Fetches the latest release if the cached value is stale or absent. Never throws: a failed
    /// refresh leaves the previous value, whatever that was.
    @discardableResult
    public static func refresh(
        httpClient: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async -> String {
        if Store.shared.isFresh { return current() }
        var request = URLRequest(url: releasesURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(ProductVersion.userAgent) (model discovery)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response): (Data, URLResponse)
            if let httpClient {
                (data, response) = try await httpClient(request)
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["prerelease"] as? Bool != true,
                  let tag = json["tag_name"] as? String,
                  let fetched = version(fromTag: tag) else {
                Store.shared.retryAfterFailure()
                return current()
            }
            Store.shared.store(fetched)
            FileHandle.standardError.write(Data("[CORE] codex client version: \(tag) -> \(fetched)\n".utf8))
        } catch {
            // Offline, rate-limited, or GitHub moved. The floor is a working version, so nothing
            // downstream has to handle this.
            Store.shared.retryAfterFailure()
        }
        return current()
    }

    /// Test seam: forget what was fetched so a case can assert the floor path.
    static func resetForTesting() { Store.shared.reset() }

    /// Numeric per component, so `0.9.0` does not beat `0.159.3` as a string comparison would.
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let l = lhs.split(separator: ".").compactMap { Int($0) }
        let r = rhs.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(l.count, r.count) {
            let a = index < l.count ? l[index] : 0
            let b = index < r.count ? r[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    /// A lock rather than an actor because `current()` is called from synchronous request building.
    private final class Store: @unchecked Sendable {
        static let shared = Store()
        private let lock = NSLock()
        private var value: String?
        private var nextCheck = Date.distantPast

        var isFresh: Bool {
            lock.lock(); defer { lock.unlock() }
            return Date() < nextCheck
        }

        func resolved() -> String {
            lock.lock(); defer { lock.unlock() }
            guard let value else { return floor }
            return CodexClientVersion.compare(value, floor) >= 0 ? value : floor
        }

        func store(_ fetched: String) {
            lock.lock(); defer { lock.unlock() }
            value = fetched
            nextCheck = Date().addingTimeInterval(ttl)
        }

        /// A failed fetch keeps whatever was known and asks again soon rather than after a full TTL.
        func retryAfterFailure() {
            lock.lock(); defer { lock.unlock() }
            nextCheck = Date().addingTimeInterval(retryInterval)
        }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            value = nil
            nextCheck = Date.distantPast
        }
    }
}
