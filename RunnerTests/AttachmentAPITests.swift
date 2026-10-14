import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import oby_runner

@MainActor
struct AttachmentAPITests {
    private let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

    @Test func plansRefusePaths() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "well@example.com"))
        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/v1/plans", method: .post,
                                                    headers: [.tailscaleUserLogin: "well@example.com"],
                                                    body: ByteBuffer(string: #"{"said":"look","attachments":["/home/u/.ssh/id_ed25519"]}"#)) { $0.status }
            #expect(response == .gone)
        }
        #expect(desk.jobs.isEmpty)
    }

    @Test func plansRefuseForeignOrUsedIds() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "well@example.com"))
        let headers: HTTPFields = [.tailscaleUserLogin: "well@example.com"]
        let used = try api.attachmentStore.upload(png, name: "screen.png", source: "iphone")
        try api.attachmentStore.link([used.id], toTurn: "another-turn")
        try await app.test(.router) { client in
            let unknown = try await client.execute(uri: "/v1/plans", method: .post, headers: headers,
                                                   body: ByteBuffer(string: #"{"said":"look","attachmentIds":["aaaaaaaaaaaaaaaa"]}"#)) { $0.status }
            let linked = try await client.execute(uri: "/v1/plans", method: .post, headers: headers,
                                                  body: ByteBuffer(string: #"{"said":"look","attachmentIds":["\#(used.id)"]}"#)) { $0.status }
            #expect(unknown == .unprocessableContent && linked == .unprocessableContent)
        }
    }

    @Test func dispatchCarriesAttachments() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let worktree = folder.appending(path: "worktree")
        try FileManager.default.createDirectory(at: worktree.appending(path: ".oby/inputs"), withIntermediateDirectories: true)
        let jobs = JobStore(url: folder.appending(path: "oby.sqlite"))
        let attachmentRoot = folder.appending(path: "attachments", directoryHint: .isDirectory)
        let store = AttachmentStore(root: attachmentRoot, jobs: jobs)
        let first = try store.upload(png, name: "../../screen.png", source: "iphone")
        let second = try store.upload(png, name: "diagram.png", source: "iphone")
        defer { try? store.delete(first.id); try? store.delete(second.id) }
        let body = try JSONSerialization.data(withJSONObject: ["job": [
            "repo": "deskree-inc/oby", "kind": "build", "task": "Inspect these files",
            "attachmentIds": [first.id, second.id],
        ]])
        let request = try JSONDecoder().decode(DispatchRequest.self, from: body)
        let new = try #require(request.job.new)
        var job = Job(id: "ab12cd34", request: "inspect", agent: "codex", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/build-ab12cd34", base: "dev", kind: .build, task: "Inspect these files")
        job.attachmentIDs = new.attachmentIDs
        #expect(try Attachments.copy(job, into: worktree, jobStore: jobs, attachmentRoot: attachmentRoot)?.count == 2)
        #expect(try Data(contentsOf: worktree.appending(path: ".oby/inputs/screen.png")) == png)
        #expect(try Data(contentsOf: worktree.appending(path: ".oby/inputs/diagram.png")) == png)
    }
}
