import SwiftUI
#if os(macOS) || os(iOS)
import QuickLook
#endif
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS) || os(iOS)
/// A turn's runner-owned files: a compact row with downloadable thumbnails and Quick Look previews.
struct AttachmentStrip: View {
    let attachments: [AttachmentRef]
    let loadThumbnail: (String) async throws -> Data
    let loadContent: (String) async throws -> Data
    @State private var thumbnails: [String: Data] = [:]
    @State private var previewURL: URL?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                ForEach(Array(attachments.prefix(4))) { attachment in
                    Button { Task { await preview(attachment) } } label: {
                        VStack(spacing: 3) {
                            if let data = thumbnails[attachment.id], let image = image(data) {
                                image.resizable().scaledToFill().frame(width: 58, height: 48).clipped()
                            } else {
                                Image(systemName: icon(attachment))
                                    .font(.title3).frame(width: 58, height: 48)
                            }
                            Text(label(attachment)).font(.caption2).lineLimit(1).frame(width: 64)
                        }
                        .padding(4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Preview \(attachment.name)")
                }
                if attachments.count > 4 {
                    Text("+\(attachments.count - 4)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
        }
        .task {
            for attachment in attachments.prefix(4) where attachment.type.hasPrefix("image/") {
                if thumbnails[attachment.id] == nil, let data = try? await loadThumbnail(attachment.id) {
                    thumbnails[attachment.id] = data
                }
            }
        }
        .quickLookPreview($previewURL)
    }

    private func preview(_ attachment: AttachmentRef) async {
        do {
            let data = try await loadContent(attachment.id)
            let safeName = URL(filePath: attachment.name).lastPathComponent
            let file = FileManager.default.temporaryDirectory.appending(path: "oby-preview-\(attachment.id)-\(safeName)")
            try data.write(to: file, options: .atomic)
            previewURL = file
            problem = nil
        } catch {
            problem = "Couldn't open \(attachment.name): \(error.localizedDescription)"
        }
    }

    private func icon(_ attachment: AttachmentRef) -> String {
        attachment.type == "application/pdf" ? "doc.richtext" : "doc"
    }

    private func label(_ attachment: AttachmentRef) -> String {
        if attachment.type == "application/pdf", let pages = attachment.pages { return "PDF · \(pages) pages" }
        return attachment.name
    }

    private func image(_ data: Data) -> Image? {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #endif
    }
}
#endif
