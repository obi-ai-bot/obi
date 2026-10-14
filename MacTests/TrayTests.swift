import Foundation
import AppKit
import Testing
@testable import Oby

@Suite(.serialized)
@MainActor
struct TrayTests {
    private func fixture() throws -> (URL, Tray, Desk) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "oby-tray-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appending(path: "staging", directoryHint: .isDirectory)
        return (folder, Tray(folder: staging), Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite"))))
    }

    private func clipboardImage() throws -> NSImage {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.systemRed, atX: 0, y: 0)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        return try #require(NSImage(data: data))
    }

    @Test func pasteImageUploadsAndShowsChip() async throws {
        let (folder, tray, desk) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([try clipboardImage()])
        tray.pasteClipboard()
        #expect(tray.items.count == 1 && tray.items[0].kind == .clipboardImage)
        let ids = try await tray.uploadIDs(using: nil, desk: desk)
        #expect(ids.count == 1 && tray.items[0].uploadedID == ids[0])
        let store = AttachmentStore(root: Workspace.root.appending(path: "attachments", directoryHint: .isDirectory), jobs: desk.store, vault: desk.vault)
        #expect(try store.content(ids[0]).0.type == "image/png")
        tray.clear()
        try store.delete(ids[0])
    }

    @Test func removeDeletesOnRunner() async throws {
        let (folder, tray, desk) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "note.txt")
        try Data("a note".utf8).write(to: source)
        tray.addFiles([source])
        let id = try #require(try await tray.uploadIDs(using: nil, desk: desk).first)
        let store = AttachmentStore(root: Workspace.root.appending(path: "attachments", directoryHint: .isDirectory), jobs: desk.store, vault: desk.vault)
        var deleted: [String] = []
        tray.deleteRemote = { value in deleted.append(value); try? store.delete(value) }
        tray.remove(try #require(tray.items.first))
        #expect(deleted == [id] && store.attachment(id) == nil && tray.items.isEmpty)
    }

    @Test func failedUploadBlocksSend() async throws {
        let (folder, tray, desk) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "note.txt")
        try Data("a note".utf8).write(to: source)
        tray.addFiles([source])
        do {
            _ = try await tray.uploadIDs(using: Runner(base: URL(string: "http://127.0.0.1:1")!), desk: desk)
            Issue.record("The runner is unreachable, but the attachment upload succeeded.")
        } catch {
            #expect(tray.items.count == 1 && tray.items[0].uploadedID == nil)
        }
    }

    @Test func uploadKeysChipsByStableIDNotIndex() async throws {
        let (folder, tray, desk) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: "first.txt")
        let second = folder.appending(path: "second.txt")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        tray.addFiles([first, second])
        let firstChip = try #require(tray.items.first)
        let secondChip = try #require(tray.items.last)
        #expect(firstChip.id != secondChip.id)
        // Remove the first chip before uploading: the survivor must keep its own identity and
        // receive the upload id (an index-based write would target the wrong slot or crash).
        tray.remove(firstChip)
        let ids = try await tray.uploadIDs(using: nil, desk: desk)
        #expect(ids.count == 1)
        #expect(tray.items.map(\.id) == [secondChip.id])
        #expect(tray.items[0].uploadedID == ids[0])
        let store = AttachmentStore(root: Workspace.root.appending(path: "attachments", directoryHint: .isDirectory), jobs: desk.store, vault: desk.vault)
        try store.delete(ids[0])
    }
}
