import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The runner's API (docs/runner-api.md) over the tailnet. Like the apps, it sends no token:
/// `tailscale serve` adds the owner's `Tailscale-User-Login`.
struct RunnerAPI: Sendable {
    /// One request to the runner: the method, the path and its JSON body, and what it answered.
    typealias Send = @Sendable (_ method: String, _ path: String, _ body: Data?) async throws -> (status: Int, body: Data)

    struct Failure: Error, Equatable {
        var status: Int
        var message: String
    }

    var base: String
    var send: Send

    /// The Mac app's bundle id and its Settings › Runner key (Mac/Settings.swift).
    static let macApp = "com.deskree.oby"
    static let defaultURL = "https://tetrix-lab.tail8de49b.ts.net:8443"

    /// Where the runner is: `OBY_RUNNER_URL`, else the address Oby's Settings on this Mac use,
    /// else tetrix-lab's.
    static func url(environment: [String: String] = ProcessInfo.processInfo.environment,
                    settings: String? = UserDefaults(suiteName: macApp)?.string(forKey: "runnerURL")) -> String {
        let given = [environment["OBY_RUNNER_URL"], settings].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        var url = given ?? defaultURL
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    static func http(_ base: String) -> RunnerAPI {
        RunnerAPI(base: base) { method, path, body in
            guard let url = URL(string: base + path) else { throw Failure(status: 0, message: "\(base) isn't a URL: set OBY_RUNNER_URL.") }
            var request = URLRequest(url: url)
            request.httpMethod = method
            // A plan takes up to 20 seconds, the Lead a little more.
            request.timeoutInterval = 90
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
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
