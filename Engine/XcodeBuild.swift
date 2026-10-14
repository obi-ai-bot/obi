import Foundation

/// The Xcode Cloud TestFlight workflow is configured in App Store Connect to start only for
/// `oby-build/` tags. Oby creates those tags as part of its normal, secret-scanned publish path.
nonisolated enum XcodeBuild {
    static let prefix = "oby-build/"
    static let interval: Duration = .seconds(2 * 60 * 60)
    static let paths = ["apps/ios/app/", "apps/ios/tests/", "apps/shared/", "apps/watch/", "apps/ios/live-activity/", "character/", "apps/icon/", "apps/Oby.xcodeproj"]

    static func includes(_ path: String) -> Bool {
        paths.contains { candidate in
            let directory = candidate.hasSuffix("/") ? String(candidate.dropLast()) : candidate
            return path == directory || path.hasPrefix(candidate.hasSuffix("/") ? candidate : candidate + "/")
        }
    }

    /// Read dev and its tags from the runner's clone, and return the next tag only when Apple-facing
    /// files changed since the last build tag.
    static func candidate(repo: String, clone: URL, at date: Date = .now) async throws -> (tag: String?, head: String, reason: String?) {
        try await Shell.ok(["git", "-C", clone.path, "fetch", "--quiet", "origin", "dev", "--tags"])
        let head = try await Shell.ok(["git", "-C", clone.path, "rev-parse", "refs/remotes/origin/dev"])
        let tags = try await Shell.ok(["git", "-C", clone.path, "tag", "--list", "oby-build/*"])
        let previous = tags.split(whereSeparator: \.isNewline).map(String.init).sorted().last
        let changed: String
        if let previous {
            changed = try await Shell.ok(["git", "-C", clone.path, "diff", "--name-only", "\(previous)..refs/remotes/origin/dev"])
        } else {
            changed = try await Shell.ok(["git", "-C", clone.path, "ls-tree", "-r", "--name-only", "refs/remotes/origin/dev"])
        }
        guard !changed.isEmpty else { throw Shell.Failure(message: "Couldn't compare dev with the last Xcode Cloud build.") }
        guard changed.split(whereSeparator: \.isNewline).contains(where: { includes(String($0)) }) else {
            return (nil, head, "No iPhone, Watch, shared, character, icon, or Xcode project files changed since the last build.")
        }
        let day = String(tagName(at: date, sequence: 1).dropFirst(prefix.count).dropLast(2))
        let sequence = tags.split(whereSeparator: \.isNewline).compactMap { value -> Int? in
            guard value.hasPrefix(prefix + day + ".") else { return nil }
            return Int(value.dropFirst((prefix + day + ".").count))
        }.max().map { $0 + 1 } ?? 1
        return (tagName(at: date, sequence: sequence), head, nil)
    }

    static func tagName(at date: Date, sequence: Int, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        return "\(prefix)\(day).\(sequence)"
    }

    /// Create a lightweight tag through the runner's GitHub identity. The caller supplies the
    /// already-read dev head; this never pushes a branch or changes a local checkout.
    static func create(repo: String, tag: String, head: String) async throws {
        guard repo.wholeMatch(of: /[A-Za-z0-9-]+\/[A-Za-z0-9._-]+/) != nil, !repo.contains(".."),
              tag.hasPrefix(prefix), tag.dropFirst(prefix.count).wholeMatch(of: /\d{4}-\d{2}-\d{2}\.\d+/) != nil,
              head.wholeMatch(of: /[a-fA-F0-9]{40,64}/) != nil else {
            throw Shell.Failure(message: "Invalid Xcode Cloud build tag.")
        }
        try await Shell.ok(["gh", "api", "-X", "POST", "repos/\(repo)/git/refs", "-f", "ref=refs/tags/\(tag)", "-f", "sha=\(head)"], as: .app)
    }
}
