import Foundation

/// Sentry, connected once on obid (docs/runner-api.md, "obid only: Sentry", #1127) with a token that
/// only reads, pasted once here and kept in obid's vault. The Mac only learns the organization, its
/// projects and which ones are followed and where they're looked into; it never keeps the token.
nonisolated struct SentryStatus: Decodable, Equatable, Sendable {
    /// What it does, on its Connectors row.
    static let about = "Errors in your projects"
    /// Sentry's own address, filled in for the owner.
    static let defaultURL = "https://sentry.io"

    struct Project: Decodable, Equatable, Sendable, Identifiable {
        var slug: String
        var name: String
        var follow: Bool
        /// One of obid's repositories: where its errors are looked into.
        var repo: String?
        var id: String { slug }
    }

    var connected = false
    var url: String?
    var org: String?
    var projects: [Project] = []
    /// obid's repositories, the ones a project may be mapped to.
    var repos: [String] = []
    /// Why obid was signed out, or the last read's problem, in its words.
    var error: String?

    private enum Keys: String, CodingKey { case connected, url, org, projects, repos, error }

    init(connected: Bool = false, url: String? = nil, org: String? = nil, projects: [Project] = [], repos: [String] = [], error: String? = nil) {
        (self.connected, self.url, self.org, self.projects, self.repos, self.error) = (connected, url, org, projects, repos, error)
    }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        connected = (try? keys.decodeIfPresent(Bool.self, forKey: .connected)) ?? false
        url = try? keys.decodeIfPresent(String.self, forKey: .url)
        org = try? keys.decodeIfPresent(String.self, forKey: .org)
        projects = (try? keys.decodeIfPresent([Project].self, forKey: .projects)) ?? []
        repos = (try? keys.decodeIfPresent([String].self, forKey: .repos)) ?? []
        error = try? keys.decodeIfPresent(String.self, forKey: .error)
    }

    /// The row's tooltip: what's followed, or what connecting takes.
    var how: String {
        if connected {
            let followed = projects.filter(\.follow)
            let which = followed.isEmpty ? "No project followed yet: pick them in Projects…."
                : "Following " + followed.map { project in project.repo.map { "\(project.name) (\($0))" } ?? "\(project.name) (no repository yet)" }.joined(separator: ", ") + "."
            return "Connected to \(org ?? "your organization") with a token that only reads. \(which)" + (error.map { " \($0)" } ?? "")
        }
        return error ?? "You paste a Sentry token with only org:read, project:read and event:read once (Settings › Account › API › Personal Tokens). obid keeps it in its vault."
    }

    /// Whether `text` could be an organization's slug: lower-case letters, digits, `-` and `_`.
    static func isOrg(_ text: String) -> Bool {
        let org = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...100).contains(org.count) && org.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_").contains($0) }
    }

    /// Whether `text` could be Sentry's address: https with a host, nothing after it.
    static func isURL(_ text: String) -> Bool {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: typed), url.scheme == "https", let host = url.host(), !host.isEmpty else { return false }
        return url.user() == nil && url.query() == nil && url.fragment() == nil && ["", "/"].contains(url.path())
    }

    /// Whether `text` could be a token: printable ASCII, no space.
    static func isToken(_ text: String) -> Bool {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (20...512).contains(token.count) && token.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }
}

#if os(macOS)
extension Runner {
    /// obid's Sentry, or nil from a runner that doesn't have one (404).
    func sentry() async throws -> SentryStatus? {
        do {
            return try await call("GET", "v1/sentry")
        } catch let error as RunnerError where error.status == 404 {
            return nil
        }
    }

    /// Gives obid Sentry's address, the organization and a token: it checks the token only reads
    /// and keeps it in its vault.
    func connectSentry(url: String, org: String, token: String) async throws -> SentryStatus {
        struct Body: Encodable { var url: String; var org: String; var token: String }
        return try await call("PUT", "v1/sentry", body: Body(url: url, org: org, token: token))
    }

    /// obid forgets the Sentry token: no more offers from Sentry until it's pasted again.
    func disconnectSentry() async throws {
        try await send("DELETE", "v1/sentry")
    }

    /// One change to a project: follow it or not, or map it to one of obid's repositories (nil: none).
    /// Only that field is sent, so a change made meanwhile isn't undone by a stale value.
    enum SentryProjectChange: Sendable {
        case follow(Bool)
        case repo(String?)
    }

    func setSentryProject(_ slug: String, _ change: SentryProjectChange) async throws -> SentryStatus {
        struct Body: Encodable {
            var change: SentryProjectChange
            func encode(to encoder: any Encoder) throws {
                var keys = encoder.container(keyedBy: Keys.self)
                switch change {
                case .follow(let follow): try keys.encode(follow, forKey: .follow)
                case .repo(let repo): try keys.encode(repo, forKey: .repo)
                }
            }
            enum Keys: String, CodingKey { case follow, repo }
        }
        let path = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        return try await call("PATCH", "v1/sentry/projects/\(path)", body: Body(change: change))
    }
}
#endif
