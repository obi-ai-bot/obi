import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The runner's API (docs/runner-api.md). Over the tailnet it sends no token: `tailscale serve`
/// adds the owner's `Tailscale-User-Login`. obid on this machine answers only its own token, so
/// a runner on a loopback address gets the one in obid's home (`api-token`), read as the Mac app
/// reads it, and never a runner anywhere else.
struct RunnerAPI: Sendable {
    /// One request to the runner: the method, the path and its JSON body, and what it answered.
    typealias Send = @Sendable (_ method: String, _ path: String, _ body: Data?) async throws -> (status: Int, body: Data)

    struct Failure: Error, Equatable {
        var status: Int
        var message: String
    }

    var base: String
    var send: Send

    /// The Mac app's bundle id and its Settings › Runner key (apps/mac/app/Settings.swift).
    static let macApp = "com.deskree.oby"
    static let defaultURL = "https://tetrix-lab.tail8de49b.ts.net:8443"
    static let localURL = "http://127.0.0.1:7777"

    /// Where obid keeps its token: the Mac app's runner home on a Mac, `~/.local/share/obid`
    /// elsewhere (docs/install.md, "The token, and how the apps find obid").
    static var obidHomes: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appending(path: "Library/Application Support/Oby/Runner"), home.appending(path: ".local/share/obid")]
    }

    /// Where the runner is: `OBY_RUNNER_URL`, else the address Oby's Settings on this Mac use,
    /// else obid on this machine when its token is there, else tetrix-lab's.
    static func url(environment: [String: String] = ProcessInfo.processInfo.environment,
                    settings: String? = UserDefaults(suiteName: macApp)?.string(forKey: "runnerURL"),
                    localObid: Bool = token(for: localURL, homes: obidHomes) != nil) -> String {
        let given = [environment["OBY_RUNNER_URL"], settings].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        var url = given ?? (localObid ? localURL : defaultURL)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    static func http(_ base: String) -> RunnerAPI {
        let token = token(for: base, homes: obidHomes)
        return RunnerAPI(base: base) { method, path, body in
            guard let url = URL(string: base + path) else { throw Failure(status: 0, message: "\(base) isn't a URL: set OBY_RUNNER_URL.") }
            let (data, response) = try await URLSession.shared.data(for: request(url, method: method, body: body, token: token))
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
    }

    /// One request, with `token` as `Authorization: Bearer` when there is one.
    static func request(_ url: URL, method: String, body: Data?, token: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // A plan takes up to 20 seconds, the Lead a little more.
        request.timeoutInterval = 90
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// obid's token for `base`: only when `base` is this machine (`127.0.0.1`, `localhost`,
    /// `[::1]`), from the first of `homes` with a usable `api-token`.
    static func token(for base: String, homes: [URL]) -> String? {
        guard let host = URL(string: base)?.host(), ["127.0.0.1", "localhost", "::1"].contains(host) else { return nil }
        return homes.lazy.compactMap(obidToken).first
    }

    /// A bounded read of a regular, owner-only file, as the Mac app reads it
    /// (Engine/LocalRunner.swift `obidToken`). O_NOFOLLOW and fstat check the file actually
    /// opened; O_NONBLOCK keeps a FIFO at that name from hanging.
    // ponytail: a copy of LocalRunner.obidToken, since oby-mcp doesn't link ObyEngine; one shared
    // target if a third copy appears.
    static func obidToken(in home: URL) -> String? {
        let fd = open(home.appending(path: "api-token").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              let data = try? file.read(upToCount: 4097), data.count <= 4096 else { return nil }
        var bytes = Array(data)
        while bytes.last == 10 || bytes.last == 13 { bytes.removeLast() }
        guard bytes.count >= 32, bytes.allSatisfy({ (33...126).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// One call: the runner's JSON, or a `Failure` with its one-line error.
    func call(_ method: String, _ path: String, _ body: JSON? = nil) async throws -> JSON {
        let answer: (status: Int, body: Data)
        do {
            answer = try await send(method, path, body?.data)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(status: 0, message: "Couldn't reach Oby's runner at \(base): \(error.localizedDescription). Is Tailscale up on this machine?")
        }
        guard (200..<300).contains(answer.status) else {
            let said = (try? JSON.parse(answer.body))?["error"]?.string
            throw Failure(status: answer.status, message: said ?? "The runner answered \(answer.status).")
        }
        do {
            return try JSON.parse(answer.body)
        } catch {
            throw Failure(status: answer.status, message: "The runner said something oby-mcp doesn't understand.")
        }
    }

    /// A path segment from a job's or an item's id, so an id can't reach another endpoint.
    static func segment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? id
    }
}
