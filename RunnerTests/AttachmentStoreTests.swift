import Foundation
import Testing
@testable import ObyEngine

struct AttachmentStoreTests {
    private func fixture() throws -> (URL, JobStore, AttachmentStore) {
        let folder = try temporaryFolder()
        let jobs = JobStore(url: folder.appending(path: "oby.sqlite"))
        return (folder, jobs, AttachmentStore(root: folder.appending(path: "attachments"), jobs: jobs, vault: Vault(store: FileVault(folder: folder.appending(path: "vault")))))
    }

    @Test func uploadSniffsTypeAndStoresByOpaqueId() throws {
        let (folder, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let value = try store.upload(data, name: "../../etc/passwd.png", source: "iphone")
        #expect(AttachmentStore.validID(value.id))
        #expect(value.type == "image/png")
        #expect(value.name == "passwd.png")
        #expect(try Data(contentsOf: store.root.appending(path: value.id)) == data)
        #expect(FileManager.default.fileExists(atPath: store.root.appending(path: "passwd.png").path) == false)
    }

    @Test func textWithAVaultSecretIsStoredRedacted() throws {
        let (folder, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try store.vault.add("ACME_KEY_value_123456", as: "ACME_KEY")
        let value = try store.upload(Data("key=ACME_KEY_value_123456".utf8), name: "settings.txt", source: "mac")
        let contents = try String(contentsOf: store.root.appending(path: value.id), encoding: .utf8)
        #expect(value.secretHit)
        #expect(!contents.contains("ACME_KEY_value_123456"))
        #expect(contents.contains("[vault: ACME_KEY]"))
    }

    @Test func binaryWithAVaultSecretIsRefused() throws {
        let (folder, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try store.vault.add("ACME_KEY_value_123456", as: "ACME_KEY")
        let bytes = Data([0, 1] + Array("ACME_KEY_value_123456".utf8))
        #expect(throws: AttachmentStoreError.self) {
            _ = try store.upload(bytes, name: "data.bin", source: "mac")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
    }

    @Test func oversizeIsRefusedWhole() throws {
        let (folder, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: AttachmentStoreError.self) {
            _ = try store.upload(Data(repeating: 1, count: 26 * 1024 * 1024), name: "large.bin", source: "mac")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
    }

    @Test func survivesRestart() throws {
        let (folder, jobs, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let value = try store.upload(Data("hello".utf8), name: "hello.txt", source: "iphone")
        #expect(value.sha256 == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        let reopened = JobStore(url: folder.appending(path: "oby.sqlite"))
        #expect(reopened.attachment(value.id) == value)
        #expect(try AttachmentStore(root: store.root, jobs: reopened).content(value.id).1 == Data("hello".utf8))
        _ = jobs
    }

    @Test func unsentUploadsCanBeDeletedButLinkedUploadsCannot() throws {
        let (folder, jobs, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let value = try store.upload(Data("hello".utf8), name: "hello.txt", source: "iphone")
        try store.delete(value.id)
        #expect(store.attachment(value.id) == nil)

        let linked = try store.upload(Data("again".utf8), name: "again.txt", source: "iphone")
        try store.link([linked.id], toJob: "job12345")
        #expect(throws: AttachmentStoreError.self) { try store.delete(linked.id) }
        #expect(jobs.attachment(linked.id)?.jobs == ["job12345"])
    }

    @Test func unsentAreDeletedAfterADay() throws {
        let (folder, jobs, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var value = try store.upload(Data("hello".utf8), name: "hello.txt", source: "iphone")
        value.created = .distantPast
        jobs.save(value)
        store.cleanup(now: .now, liveTurns: [], liveJobs: [])
        #expect(store.attachment(value.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.root.appending(path: value.id).path))
    }

    @Test func linkedAreKeptWithTheirTurn() throws {
        let (folder, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let value = try store.upload(Data("hello".utf8), name: "hello.txt", source: "iphone")
        try store.link([value.id], toTurn: "turn-1")
        store.cleanup(now: .now.addingTimeInterval(48 * 60 * 60), liveTurns: ["turn-1"], liveJobs: [])
        #expect(store.attachment(value.id)?.turn == "turn-1")
        #expect(try store.content(value.id).1 == Data("hello".utf8))
    }
}
