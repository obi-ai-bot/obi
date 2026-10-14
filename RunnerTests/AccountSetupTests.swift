import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import oby_runner

@MainActor
struct AccountSetupTests {
    @Test func ownerCreatesAnIsolatedProfileAndCanRetryItsLogin() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AccountStore(root: folder)
        store.setLabel("Existing login", for: "default")
        let desk = Desk(accounts: store, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "owner@example.com"))
        let owner: HTTPFields = [.tailscaleUserLogin: "owner@example.com"]
        try await app.test(.router) { client in
            let login = try await client.execute(uri: "/v1/accounts", method: .post, headers: owner,
                                                body: ByteBuffer(string: #"{"agent":"claude","name":" Daniel Claude ","payer":"Daniel"}"#)) { response in
                #expect(response.status == .created)
                return try JSONDecoder().decode(AccountLogin.self, from: Data(response.body.readableBytesView))
            }
            #expect(login.account.name == "Daniel Claude")
            #expect(login.account.agent == "claude")
            #expect(login.account.home == folder.appending(path: "accounts/\(login.account.id)").path)
            await MainActor.run {
                #expect(store.state(login.account.id)?.signedIn == false)
                #expect(store.state("default")?.signedIn == true)
                #expect(AccountStore(root: folder).accounts.map(\.account) == store.accounts.map(\.account))
            }
            try await client.execute(uri: "/v1/accounts/\(login.account.id)/sign-in", method: .post, headers: owner) { response in
                #expect(response.status == .ok)
                let retry = try JSONDecoder().decode(AccountLogin.self, from: Data(response.body.readableBytesView))
                #expect(retry.account == login.account && retry.path == login.path)
            }
            try await client.execute(uri: "/v1/accounts/missing/sign-in", method: .post, headers: owner) { response in
                #expect(response.status == .notFound)
            }
            let stand = Shell.Stand(run: { args, _ in
                if args.contains("status") {
                    return Shell.Output(status: 0, out: Data(#"{"loggedIn":true,"subscriptionType":"max","email":"daniel@example.com"}"#.utf8), err: "")
                }
                return Shell.Output(status: 0, out: Data(), err: "")
            })
            try await Shell.$stand.withValue(stand) {
                try await client.execute(uri: "/v1/accounts/refresh", method: .post, headers: owner) { response in
                    #expect(response.status == .ok)
                    #expect(String(decoding: response.body.readableBytesView, as: UTF8.self).contains("daniel@example.com"))
                }
            }
            await MainActor.run {
                #expect(store.state(login.account.id)?.signedIn == true)
                #expect(AccountStore.route(store.accounts.filter { $0.account.id == login.account.id }, agent: "claude")?.id == login.account.id)
            }
            try await client.execute(uri: "/v1/status", method: .get, headers: owner) { response in
                let text = String(decoding: response.body.readableBytesView, as: UTF8.self)
                #expect(text.contains("Daniel Claude"))
                #expect(!text.contains(folder.path)) // Paths appear only in owner-requested login metadata.
            }
        }
    }

    @Test func addingNeverOverwritesAnUnreadableAccountList() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "accounts.json")
        let broken = Data(#"[{"id":"keep-me","agent":"claude","name":"Old format"}]"#.utf8)
        try broken.write(to: file)
        let store = AccountStore(root: folder)
        #expect(throws: (any Error).self) { try store.add(agent: "claude", name: "Daniel Claude", payer: "") }
        #expect(try Data(contentsOf: file) == broken)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "accounts").path))
    }

    @Test func invalidRequestsAndNonOwnersCannotCreateProfilesOrGetLoginMetadata() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AccountStore(root: folder)
        let desk = Desk(accounts: store, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let app = Application(router: API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json"))).router(owner: "owner@example.com"))
        try await app.test(.router) { client in
            let owner: HTTPFields = [.tailscaleUserLogin: "owner@example.com"]
            for body in [#"{"agent":"shell","name":"X","payer":""}"#, #"{"agent":"claude","name":"  ","payer":""}"#,
                         #"{"agent":"claude","name":"X","payer":""}"#.replacingOccurrences(of: "\"X\"", with: "\"" + String(repeating: "a", count: 101) + "\"")] {
                try await client.execute(uri: "/v1/accounts", method: .post, headers: owner, body: ByteBuffer(string: body)) { response in
                    #expect(response.status == .unprocessableContent)
                }
            }
            for path in ["/v1/accounts", "/v1/accounts/default/sign-in", "/v1/accounts/refresh"] {
                for headers: HTTPFields in [[:], [.tailscaleUserLogin: "other@example.com"], [.authorization: "Bearer agent-token"]] {
                    try await client.execute(uri: path, method: .post, headers: headers, body: ByteBuffer(string: #"{"agent":"claude","name":"X","payer":""}"#)) { response in
                        #expect(response.status == .unauthorized)
                    }
                }
            }
            #expect(await store.accounts.count == 1)
            #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "accounts.json").path))
        }
    }
}
