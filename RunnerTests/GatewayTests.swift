import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import ObyEngine
@testable import oby_runner

/// The LAN gateway (#284, Runner/Gateway.swift): pairing that works once and expires, device
/// tokens, the route allowlist, the runner's own token on every forwarded request, and what
/// never leaves the Mac in an answer.
@MainActor
struct GatewayTests {
    let runnerToken = String(repeating: "ab", count: 32)

    @Test func pairingSecretAndCodeWorkOnceAndExpire() throws {
        let pairing = Pairing(random: { Data(repeating: 7, count: 32) })
        let now = Date(timeIntervalSince1970: 1_000)
        let invitation = pairing.makeInvitation(url: URL(string: "http://mac.local:8810")!, name: "My Mac", hostname: "oby.example", now: now)
        let linkData = try #require(invitation.link.data(using: .utf8))
        let link = try JSONDecoder().decode(Link.self, from: linkData)
        #expect(link == Link(name: "My Mac", hostname: "oby.example"))

        let redeemed = try pairing.redeem(invitation.code, now: now.addingTimeInterval(119))
        #expect(redeemed.token != invitation.secret)
        #expect(redeemed.digest == Pairing.digest(redeemed.token))
        // A typed code learns the Mac's link from the answer, as the QR code carries it.
        #expect(redeemed.name == "My Mac" && redeemed.hostname == "oby.example")
        #expect(throws: APIError.self) { try pairing.redeem(invitation.secret, now: now) }

        let next = pairing.makeInvitation(url: URL(string: "http://mac.local:8810")!, now: now)
        #expect(throws: APIError.self) { try pairing.redeem(next.code, now: now.addingTimeInterval(120.1)) }
    }

    @Test func wrongPairingCredentialsExhaustTheInvitation() throws {
        let pairing = Pairing(random: { Data(repeating: 9, count: 32) })
        let now = Date(timeIntervalSince1970: 2_000)
        let invitation = pairing.makeInvitation(url: URL(string: "http://mac.local:8810")!, now: now)

        for _ in 0..<Pairing.maximumAttempts {
            #expect(throws: APIError.self) { try pairing.redeem("000000", now: now) }
        }
        #expect(throws: APIError.self) { try pairing.redeem(invitation.code, now: now) }
    }

    @Test func gatewayTokenNamesPersistAndTokensCanBeRevoked() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "devices.json")
        let devices = Devices(file: file)
        let pairing = Pairing(random: { Data(repeating: 4, count: 32) })
        let now = Date(timeIntervalSince1970: 3_000)
        let invitation = pairing.makeInvitation(url: URL(string: "http://mac.local:8810")!, now: now)
        let redeemed = try pairing.redeem(invitation.code, now: now)
        _ = try devices.addGatewayToken(digest: redeemed.digest, name: "Alice's iPhone", now: now)
        let saved = try #require(devices.gatewayTokens().first)
        #expect(saved.token.name == "Alice's iPhone", "the paired device name is persisted")
        #expect(Devices(file: file).acceptsGatewayToken(redeemed.token, now: now), "a token survives a Devices restart")
        #expect(!devices.acceptsGatewayToken(redeemed.token, now: now.addingTimeInterval(Devices.GatewayToken.lifetime + 1)), "expired tokens are rejected")

        try devices.revokeGatewayToken(saved.token.id)
        #expect(!devices.acceptsGatewayToken(redeemed.token), "revoked tokens are rejected")
    }

    /// Exactly what the iPhone uses (Shared/Runner.swift) is open; the Mac's own and the runner's
    /// pairing endpoints are not.
    @Test func gatewayRoutesDefaultToDeny() {
        let phone: [(HTTPRequest.Method, String)] = [
            (.get, "/v1/status"), (.get, "/v1/events"), (.get, "/v1/conversation"), (.post, "/v1/conversation/stop"),
            (.post, "/v1/plans"), (.post, "/v1/plans/cancel"), (.get, "/v1/jobs"), (.post, "/v1/jobs"), (.get, "/v1/jobs/abc"),
            (.get, "/v1/jobs/abc/wait"), (.post, "/v1/jobs/abc/stop"), (.post, "/v1/stop-all"), (.post, "/v1/jobs/abc/dismiss"),
            (.post, "/v1/jobs/abc/move"), (.post, "/v1/jobs/abc/start"), (.post, "/v1/jobs/abc/start-when"), (.post, "/v1/jobs/abc/mode"),
            (.post, "/v1/jobs/abc/permission"), (.post, "/v1/jobs/abc/messages"), (.get, "/v1/jobs/abc/publish"), (.post, "/v1/jobs/abc/publish"),
            (.post, "/v1/clear"), (.get, "/v1/inbox"), (.post, "/v1/inbox/abc/answer"), (.get, "/v1/failures"), (.get, "/v1/failures/abc"),
            (.post, "/v1/failures/abc/fix"), (.post, "/v1/accounts/work/reserve"), (.get, "/v1/settings/models"), (.put, "/v1/settings/models"),
            (.get, "/v1/settings/models/options"), (.get, "/v1/settings/jobs"), (.get, "/v1/settings/permissions"), (.put, "/v1/settings/permissions"),
            (.get, "/v1/permissions/rules"), (.delete, "/v1/permissions/rules/abc"), (.post, "/v1/devices"), (.post, "/v1/activities"),
            (.post, "/v1/notifications"), (.get, "/v1/watches"), (.post, "/v1/watches"), (.delete, "/v1/watches/abc"),
        ]
        for (method, path) in phone { #expect(GatewayRoutes.allows(method: method, path: path), Comment(rawValue: "\(method) \(path)")) }
        let closed: [(HTTPRequest.Method, String)] = [
            (.get, "/v1/connections"), (.post, "/v1/connections"), (.get, "/v1/checks/next"), (.get, "/v1/checks/abc/bundle"),
            (.post, "/v1/agent/apple-check"), (.post, "/v1/agent/mcp/abc"), (.post, "/v1/speech"), (.put, "/v1/settings/jobs"),
            (.post, "/v1/pairing/invite"), (.get, "/v1/pairing/devices"), (.delete, "/v1/pairing/devices/abc"),
            (.get, "/v1/status/extra"), (.delete, "/v1/jobs/abc"), (.get, "/v1"), (.get, "/"),
        ]
        for (method, path) in closed { #expect(!GatewayRoutes.allows(method: method, path: path), Comment(rawValue: "\(method) \(path)")) }
    }

    @Test func gatewayRouterRequiresTokensAndHidesUnlistedRoutes() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gateway = Gateway(devices: Devices(file: folder.appending(path: "devices.json")))
        let invitation = gateway.pairing.makeInvitation(url: URL(string: "http://mac.local:8810")!)
        let redeemed = try gateway.redeem(invitation.code)
        let app = Application(router: gateway.router())

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/status", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
            try await client.execute(uri: "/v1/connections", method: .get) { response in
                #expect(response.status == .notFound)
            }
            // Pairing's own endpoints live on the loopback API: a paired phone can't mint an
            // invitation or revoke another device through the gateway.
            for (uri, method) in [("/v1/pairing/invite", HTTPRequest.Method.post), ("/v1/pairing/devices", .get), ("/v1/pairing/devices/abc", .delete)] {
                try await client.execute(uri: uri, method: method, headers: [.authorization: "Bearer \(redeemed.token)"]) { response in
                    #expect(response.status == .notFound, Comment(rawValue: uri))
                }
            }
        }
    }

    /// The Mac app makes invitations and manages paired devices on the runner's loopback API,
    /// behind its own token (Engine/LocalRunner.swift): nothing reaching the gateway can, and
    /// nothing on the Mac reads a file for it. A tailnet runner, with no gateway, has no such endpoints.
    @Test func pairingIsMadeOnTheLoopbackAPIWithTheRunnersToken() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let devices = Devices(file: folder.appending(path: "devices.json"))
        let api = API(desk: desk, devices: devices)
        let gateway = Gateway(devices: devices, pairing: api.pairing)
        let app = Application(router: api.router(access: .local(token: runnerToken)))
        let bearer: HTTPFields = [.authorization: "Bearer \(runnerToken)", .contentType: "application/json"]
        let invite = ByteBuffer(string: #"{"url":"https://oby-abc.tetrix.pro","name":"My Mac","hostname":"oby-abc.tetrix.pro"}"#)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "pairing-admin").path))

        try await app.test(.router) { @MainActor client in
            try await client.execute(uri: "/v1/pairing/invite", method: .post, headers: [.contentType: "application/json"], body: invite) { response in
                #expect(response.status == .unauthorized)
            }
            var code = ""
            try await client.execute(uri: "/v1/pairing/invite", method: .post, headers: bearer, body: invite) { response in
                #expect(response.status == .ok)
                let invitation = try JSONDecoder().decode(TestInvitation.self, from: Data(response.body.readableBytesView))
                #expect(invitation.code.count == 6 && invitation.code.allSatisfy(\.isNumber))
                #expect(invitation.secret.count >= 32 && invitation.url == "https://oby-abc.tetrix.pro")
                #expect(invitation.hostname == "oby-abc.tetrix.pro" && invitation.name == "My Mac")
                code = invitation.code
            }
            // The gateway redeems what the API made.
            let redeemed = try gateway.redeem(code, name: "Alice's iPhone")
            #expect(redeemed.name == "My Mac" && redeemed.hostname == "oby-abc.tetrix.pro")
            var id = ""
            try await client.execute(uri: "/v1/pairing/devices", method: .get, headers: bearer) { response in
                #expect(response.status == .ok)
                let listed = try JSONDecoder().decode([TestGatewayDevice].self, from: Data(response.body.readableBytesView))
                id = try #require(listed.first?.id)
                #expect(listed.count == 1 && listed.first?.name == "Alice's iPhone")
                #expect(!String(decoding: response.body.readableBytesView, as: UTF8.self).contains(redeemed.digest), "never a token's digest")
            }
            try await client.execute(uri: "/v1/pairing/devices/\(id)", method: .delete) { response in
                #expect(response.status == .unauthorized)
            }
            try await client.execute(uri: "/v1/pairing/devices/\(id)", method: .delete, headers: bearer) { response in
                #expect(response.status == .noContent)
            }
            #expect(devices.gatewayTokens().isEmpty)
            #expect(!devices.acceptsGatewayToken(redeemed.token))
        }

        let tailnet = Application(router: api.router(access: .tailnet(owner: "well@example.com")))
        try await tailnet.test(.router) { client in
            try await client.execute(uri: "/v1/pairing/invite", method: .post, headers: [.tailscaleUserLogin: "well@example.com", .contentType: "application/json"], body: invite) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    /// A Mac runner answers only its own keychain token: the gateway sends it on every forwarded
    /// request, so a paired phone's call reaches the real API. Without it, every call is 401.
    @Test func gatewayForwardsTheRunnersTokenToTheMacRunner() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let devices = Devices(file: folder.appending(path: "devices.json"))
        let api = API(desk: desk, devices: devices)
        let runner = Application(router: api.router(access: .local(token: runnerToken)))

        try await runner.test(.live) { @MainActor server in
            let port = try #require(server.port)
            let upstream = URL(string: "http://localhost:\(port)")!
            let vault = Vault(store: FileVault(folder: folder.appending(path: "vault")))
            let gateway = Gateway(devices: devices, pairing: api.pairing, upstream: upstream, upstreamToken: runnerToken, vault: vault)
            let invitation = api.pairing.makeInvitation(url: upstream)
            let redeemed = try gateway.redeem(invitation.code)
            let device: HTTPFields = [.authorization: "Bearer \(redeemed.token)"]
            try await Application(router: gateway.router()).test(.router) { client in
                try await client.execute(uri: "/v1/status", method: .get, headers: device) { response in
                    #expect(response.status == .ok)
                    let status = try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]
                    #expect(status?["runner"] != nil)
                }
                try await client.execute(uri: "/v1/jobs?limit=5", method: .get, headers: device) { response in
                    #expect(response.status == .ok)
                    #expect(String(decoding: response.body.readableBytesView, as: UTF8.self) == "[]")
                }
                // The device token is never the runner's: the runner's gate refuses a request that only carries it.
                try await client.execute(uri: "/v1/status", method: .get, headers: [.authorization: "Bearer \(runnerToken)"]) { response in
                    #expect(response.status == .unauthorized)
                }
            }
            let forgetful = Gateway(devices: devices, pairing: api.pairing, upstream: upstream, vault: vault)
            try await Application(router: forgetful.router()).test(.router) { client in
                try await client.execute(uri: "/v1/status", method: .get, headers: device) { response in
                    #expect(response.status == .unauthorized, "without the runner's token the Mac runner answers no one")
                }
            }
        }
    }

    @Test func gatewayRouterRedactsSecretsInFiniteAndSSEResponses() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let planted = "gw-fake-1"
        let vault = Vault(store: FileVault(folder: folder.appending(path: "vault")))
        try vault.add(planted, as: "gateway-test")
        let upstream = Router()
        upstream.get("v1/status") { _, _ in
            Response(status: .ok, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(string: #"{"value":"gw-fake-1"}"#)))
        }
        upstream.get("v1/events") { _, _ in
            Response(status: .ok, headers: [.contentType: "text/event-stream"], body: ResponseBody(byteBuffer: ByteBuffer(string: "data: {\"value\":\"\(planted)\"}\n\n")))
        }
        let fake = Application(router: upstream)

        try await fake.test(.live) { @MainActor server in
            let port = try #require(server.port)
            let devices = Devices(file: folder.appending(path: "devices.json"))
            let gateway = Gateway(devices: devices, upstream: URL(string: "http://localhost:\(port)")!, vault: vault)
            let invitation = gateway.pairing.makeInvitation(url: URL(string: "http://mac.local:8810")!)
            let redeemed = try gateway.redeem(invitation.code)
            let app = Application(router: gateway.router())
            try await app.test(.router) { client in
                for path in ["/v1/status", "/v1/events"] {
                    try await client.execute(uri: path, method: .get,
                                             headers: [.authorization: "Bearer \(redeemed.token)"]) { response in
                        let body = String(decoding: response.body.readableBytesView, as: UTF8.self)
                        #expect(response.status == .ok)
                        #expect(!body.contains(planted))
                        #expect(body.contains("[vault: gateway-test]"))
                    }
                }
            }
        }
    }

    /// An agent's session id and the accounts' homes never leave in an answer or an event: the
    /// session is null, the path is a marker, and the rest of the JSON is as it was.
    @Test func gatewayScrubsSessionIDsAndAccountHomes() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = "/Users/alice/Library/Application Support/Oby/accounts/work"
        let session = "e6a24229-1bd5-48c4-85c5-43b33d433775"
        let job = #"{"id":"j1","session":"\#(session)","step":"Signed in at \#(home)/.codex","account":{"id":"work","home":"\#(home)"}}"#
        let upstream = Router()
        upstream.get("v1/jobs") { _, _ in
            Response(status: .ok, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(string: "[\(job)]")))
        }
        upstream.get("v1/events") { _, _ in
            Response(status: .ok, headers: [.contentType: "text/event-stream"],
                     body: ResponseBody(byteBuffer: ByteBuffer(string: "event: job\ndata: \(job)\n\nevent: step\ndata: \"in \(home)\"\n\n")))
        }
        let fake = Application(router: upstream)

        try await fake.test(.live) { @MainActor server in
            let port = try #require(server.port)
            let vault = Vault(store: FileVault(folder: folder.appending(path: "vault")))
            let gateway = Gateway(devices: Devices(file: folder.appending(path: "devices.json")), upstream: URL(string: "http://localhost:\(port)")!,
                                  homes: { [home] }, vault: vault)
            let invitation = gateway.pairing.makeInvitation(url: URL(string: "http://mac.local:8810")!)
            let redeemed = try gateway.redeem(invitation.code)
            let app = Application(router: gateway.router())
            try await app.test(.router) { client in
                try await client.execute(uri: "/v1/jobs", method: .get, headers: [.authorization: "Bearer \(redeemed.token)"]) { response in
                    #expect(response.status == .ok)
                    let body = String(decoding: response.body.readableBytesView, as: UTF8.self)
                    #expect(!body.contains(session) && !body.contains(home), Comment(rawValue: body))
                    let jobs = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]])
                    #expect(jobs.first?["id"] as? String == "j1")
                    #expect(jobs.first?["session"] is NSNull)
                    #expect(jobs.first?["step"] as? String == "Signed in at [home]/.codex")
                    #expect((jobs.first?["account"] as? [String: Any])?["home"] as? String == "[home]")
                }
                try await client.execute(uri: "/v1/events", method: .get, headers: [.authorization: "Bearer \(redeemed.token)"]) { response in
                    #expect(response.status == .ok)
                    let body = String(decoding: response.body.readableBytesView, as: UTF8.self)
                    #expect(!body.contains(session) && !body.contains(home), Comment(rawValue: body))
                    #expect(body.hasPrefix("event: job\ndata: {") && body.contains("\"session\":null") && body.contains("\"id\":\"j1\""))
                    #expect(body.hasSuffix("\n\nevent: step\ndata: \"in [home]\"\n\n"))
                }
            }
        }
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

private struct Link: Decodable, Equatable {
    var name: String
    var hostname: String
}

private struct TestGatewayDevice: Decodable {
    var id: String
    var name: String
}

private struct TestInvitation: Decodable {
    var url: String
    var name: String
    var hostname: String
    var secret: String
    var code: String
}
