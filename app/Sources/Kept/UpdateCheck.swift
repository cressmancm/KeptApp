import Foundation

/// Whether a newer Kept is out, from the latest release on GitHub.
///
/// It only tells. The link opens the release page, the user downloads the
/// zip and opens it, and the copy that opens moves itself to Applications,
/// replacing this one (AppLocation). Gatekeeper checks the download's
/// notarization, so nothing here has to vouch for a file.
///
/// The request carries nothing about the user or the library: it's a plain
/// GET of a public URL, on an ephemeral session with no cookies or cache.
enum UpdateCheck {
    static let latestReleaseAPI =
        URL(string: "https://api.github.com/repos/cressmancm/KeptApp/releases/latest")!

    /// Once a day. A failed check tries again an hour later.
    static let interval: TimeInterval = 86_400
    static let retryAfterFailure: TimeInterval = 3_600

    struct Release: Equatable, Sendable {
        /// "1.2", from the tag "v1.2".
        let version: String
        /// The release's page, built here from the version rather than taken
        /// from the response, so the button can only ever open Kept's own
        /// releases on GitHub.
        var pageURL: URL {
            URL(string: "https://github.com/cressmancm/KeptApp/releases/tag/v\(version)")!
        }
    }

    /// The latest published release, or nil when GitHub couldn't be reached
    /// or answered with something that isn't one.
    static func fetchLatest() async -> Release? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = [
            "Accept": "application/vnd.github+json",
            // GitHub refuses requests without one.
            "User-Agent": "Kept/\(Config.appVersion)",
        ]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: latestReleaseAPI),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return release(fromJSON: data)
    }

    /// Reads `tag_name` from GitHub's answer. GitHub's "latest" already
    /// leaves out drafts and pre-releases.
    static func release(fromJSON data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = object["tag_name"] as? String,
            let version = version(fromTag: tag)
        else { return nil }
        return Release(version: version)
    }

    /// "v1.2" or "1.2.3" → "1.2" or "1.2.3". Anything else — a suffix, a
    /// path, more than three parts — is nil, so a release tagged some other
    /// way is ignored rather than guessed at.
    static func version(fromTag tag: String) -> String? {
        let bare = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard let parts = numbers(bare), (1...3).contains(parts.count) else { return nil }
        return bare
    }

    /// Compared part by part, so 1.10 is newer than 1.9 and 1.1 equals 1.1.0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = numbers(candidate), let old = numbers(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    static func isDue(checkedAt: Date?, now: Date = .now) -> Bool {
        guard let checkedAt else { return true }
        return now.timeIntervalSince(checkedAt) >= interval
    }

    private static func numbers(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
            parts.allSatisfy({ part in
                !part.isEmpty && part.count <= 4 && part.allSatisfy { ("0"..."9").contains($0) }
            })
        else { return nil }
        let values = parts.compactMap { Int($0) }
        return values.count == parts.count ? values : nil
    }
}
