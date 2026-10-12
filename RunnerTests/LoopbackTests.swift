import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import oby_runner

/// The runner on a Mac (#283): it answers only on 127.0.0.1, only requests whose `Host` is a
/// loopback name, and only with its own token.
@MainActor
struct LoopbackTests {
    let token = String(repeating: "ab", count: 32)
    var access: Access { .local(token: token) }

    func request(_ path: String = "/v1/status", host: String?, headers: HTTPFields = [:]) -> Request {
        Request(head: HTTPRequest(method: .get, scheme: "http", authority: host, path: path, headerFields: headers),
                body: .init(buffer: ByteBuffer()))
    }

    var bearer: HTTPFields { [.authorization: "Bearer \(token)"] }

    func refusal(_ request: Request, _ access: Access) -> APIError? {
        do {
            try Gate<BasicRequestContext>.admit(request, access: access)
            return nil
        } catch let error as APIError {
            return error
        } catch {
            Issue.record("not an APIError: \(error)")
            return nil
        }
    }

    @Test func refusesEveryHostThatIsntLoopback() {
        let hosts: [String?] = ["evil.example", "evil.example:7777", "tetrix-lab.tail8de49b.ts.net:8443", "127.0.0.1.evil.example",
                                "localhost.evil.example", "[::2]", "[::1]:x", "127.0.0.1:x", "", "   ", nil]
        for host in hosts {
            let error = refusal(request(host: host, headers: bearer), access)
            #expect(error?.status == .forbidden, "\(host ?? "nil")")
            #expect(error?.message == "This runner answers only on 127.0.0.1.")
        }
        // Before the token is read: a wrong host with no token is 403, not 401.
        #expect(refusal(request(host: "evil.example"), access)?.status == .forbidden)
        // Even an agent's own path: nothing is let in from another name.
        #expect(refusal(request("/v1/agent/apple-check", host: "evil.example"), access)?.status == .forbidden)
    }

    @Test func letsLoopbackHostsInWithTheToken() {
        for host in ["127.0.0.1", "127.0.0.1:7777", "localhost", "localhost:7777", "LOCALHOST", "[::1]", "[::1]:7777", " 127.0.0.1 "] {
            #expect(refusal(request(host: host, headers: bearer), access) == nil, Comment(rawValue: host))
        }
    }

    @Test func refusesWithoutTheToken() {
        let wrong: [HTTPFields] = [
            [:],
            [.authorization: "Bearer "],
            [.authorization: "Bearer " + String(repeating: "cd", count: 32)],
            [.authorization: "Bearer " + String(token.dropLast())],
            [.authorization: token],
            [.authorization: "Basic \(token)"],
            [.tailscaleUserLogin: "well@example.com"],
        ]
        for headers in wrong {
            let error = refusal(request(host: "127.0.0.1:7777", headers: headers), access)
            #expect(error?.status == .unauthorized, "\(headers)")
            #expect(error?.message == "This runner answers only Oby on this Mac.")
        }
    }

    /// `oby-check apple` from an agent's sandbox carries its job's token, not the runner's: the gate
    /// lets it through on a loopback host, and the handler checks the job's token.
    @Test func agentRequestsCarryTheirOwnToken() {
        #expect(refusal(request("/v1/agent/apple-check", host: "127.0.0.1:7777"), access) == nil)
    }

    /// On the tailnet nothing changes: the login decides, whatever `Host` says.
    @Test func theTailnetGateReadsTheLoginNotTheHost() {
        let tailnet = Access.tailnet(owner: "well@example.com")
        #expect(refusal(request(host: "evil.example", headers: [.tailscaleUserLogin: "well@example.com"]), tailnet) == nil)
        #expect(refusal(request(host: "127.0.0.1", headers: bearer), tailnet)?.status == .unauthorized)
        #expect(refusal(request(host: nil, headers: [.tailscaleUserLogin: "well@example.com"]), tailnet) == nil)
    }

    /// Every endpoint sits behind the gate: `/v1/status` answers with the token and refuses without.
    @Test func theRouterIsBehindTheGate() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(access: access))
        // The test client asks as `localhost`.
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/status", method: .get, headers: bearer) { response in
                #expect(response.status == .ok)
                #expect(object(Data(response.body.readableBytesView))["runner"] != nil)
            }
            for headers in [HTTPFields(), [.tailscaleUserLogin: "well@example.com"], [.authorization: "Bearer nope"]] {
                for uri in ["/v1/status", "/v1/jobs", "/v1/nowhere"] {
                    try await client.execute(uri: uri, method: .get, headers: headers) { response in
                        #expect(response.status == .unauthorized)
                        #expect(object(Data(response.body.readableBytesView))["error"] as? String == "This runner answers only Oby on this Mac.")
                    }
                }
            }
        }
    }
}

/// The runner's own token and home on a Mac (Engine/LocalRunner.swift).
struct LocalRunnerTests {
    @Test func loopbackNames() {
        for host in ["127.0.0.1", "127.0.0.1:7777", "localhost", "Localhost:1", "[::1]", "[::1]:7777"] {
            #expect(LocalRunner.isLoopback(host: host), Comment(rawValue: host))
        }
        for host in ["evil.example", "127.0.0.2", "127.0.0.1:", "127.0.0.1:7777:1", "[::1", "::1", "0.0.0.0", "localhost.", "", nil] {
            #expect(!LocalRunner.isLoopback(host: host), Comment(rawValue: host ?? "nil"))
        }
    }

    @Test func makesATokenOnceAndKeepsIt() throws {
        let home = try temporaryFolder().appending(path: "Runner")
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        #expect(LocalRunner.token(in: home) == nil)
        let token = try LocalRunner.makeToken(in: home)
        #expect(LocalRunner.isToken(token))
        #expect(try LocalRunner.makeToken(in: home) == token)
        #expect(LocalRunner.token(in: home) == token)
        let file = home.appending(path: LocalRunner.tokenFile)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try String(contentsOf: file, encoding: .utf8) == token + "\n")
        // A file that isn't a token is replaced; two runners' tokens differ.
        try "not a token".write(to: file, atomically: true, encoding: .utf8)
        #expect(LocalRunner.token(in: home) == nil)
        let fresh = try LocalRunner.makeToken(in: home)
        #expect(LocalRunner.isToken(fresh))
        #expect(fresh != token)
    }

    @Test func readsTheBearerToken() {
        let token = String(repeating: "0f", count: 32)
        #expect(Gate<BasicRequestContext>.bearer("Bearer \(token)") == token)
        #expect(Gate<BasicRequestContext>.bearer("Bearer \(token)  ") == token)
        #expect(Gate<BasicRequestContext>.bearer("Bearer ") == nil)
        #expect(Gate<BasicRequestContext>.bearer("bearer \(token)") == nil)
        #expect(Gate<BasicRequestContext>.bearer(token) == nil)
        #expect(Gate<BasicRequestContext>.bearer(nil) == nil)
    }

    @Test func comparesTokensWhole() {
        let token = String(repeating: "ab", count: 32)
        #expect(LocalRunner.same(token, as: token))
        #expect(!LocalRunner.same(String(token.dropLast()), as: token))
        #expect(!LocalRunner.same(token + "a", as: token))
        #expect(!LocalRunner.same(String(repeating: "ba", count: 32), as: token))
        #expect(!LocalRunner.same("", as: token))
    }

    /// Where a Mac runner keeps its files, apart from the app's own folder.
    @Test func homeIsInsideTheAppsFolderButNotIt() {
        let app = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Oby")
        #expect(LocalRunner.home.path.hasPrefix(app.path + "/"))
        #expect(LocalRunner.home.lastPathComponent == "Runner")
        #expect(LocalRunner.url.absoluteString == "http://127.0.0.1:7777")
    }
}
