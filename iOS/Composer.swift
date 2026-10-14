import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// The field where you type a task or dictate one, with Send: at the bottom of Home and of Chat,
/// one and the same. Tap the mic and what you say goes into the field as it's heard; tap Stop and
/// the words stay there to edit and send (iOS/README.md, "Voice input").
struct Composer: View {
    static let maxAttachmentCount = 10
    static let maxAttachmentBytes = 25 * 1024 * 1024
    static let maxMessageBytes = 50 * 1024 * 1024
    @Environment(Phone.self) private var phone
    @Binding var text: String
    var prompt = "Type a task, like “Review oby PR #12”"
    /// The keyboard's focus, owned by the screen so it can take it after an edit or let it go.
    var typing: FocusState<Bool>.Binding
    /// Sends the field; true when it has dictated words, so Oby may speak its reply.
    let onSend: (_ spoken: Bool, _ attachmentIDs: [String]) -> Void
    @State private var selection: TextSelection?
    /// The field has dictated words in it: cleared, it's typed again.
    @State private var dictated = false
    /// What dictation last put in the field. The field holding anything else means someone
    /// typed or it was filled from elsewhere, and dictation stops there.
    @State private var written: String?
    @State private var photos: [PhotosPickerItem] = []
    @State private var importingFiles = false
    @State private var capturingPhoto = false
    @State private var previewURL: URL?
    @State private var attachmentProblem: String?
    @State private var uploading = false

    private var sendable: Bool { ChatThread.words(text) != nil }

    private var attachments: [PhoneAttachmentDraft] { phone.attachmentDrafts }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if phone.voice.active || phone.voice.finishing {
                Text(phone.voice.finishing ? "Writing down…" : phone.voice.listening ? "Listening…" : "Getting ready…")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            }
            if let problem = phone.voice.problem {
                Text(problem).font(.footnote).foregroundStyle(.red).padding(.horizontal, 12)
            }
            if let attachmentProblem {
                HStack(spacing: 8) {
                    Text(attachmentProblem).font(.footnote).foregroundStyle(.red)
                    if !attachments.isEmpty {
                        Button("Retry upload") { Task { await send() } }.font(.footnote.weight(.semibold))
                    }
                }.padding(.horizontal, 12)
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { item in
                            HStack(spacing: 6) {
                                Button { preview(item) } label: {
                                    HStack(spacing: 6) {
                                        if let image = UIImage(data: item.data) {
                                            Image(uiImage: image).resizable().scaledToFill().frame(width: 24, height: 24).clipShape(RoundedRectangle(cornerRadius: 4))
                                        } else {
                                            Image(systemName: item.name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc")
                                        }
                                        Text(item.name).lineLimit(1).frame(maxWidth: 120)
                                    }
                                }.buttonStyle(.plain).accessibilityLabel("Preview \(item.name)")
                                Button { phone.attachmentDrafts.removeAll { $0.id == item.id } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }.accessibilityLabel("Remove \(item.name)")
                            }
                            .font(.caption)
                            .padding(8)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                    }.padding(.horizontal, 4)
                }
            }
            HStack(spacing: 8) {
                Menu {
                    PhotosPicker(selection: $photos, maxSelectionCount: max(1, Self.maxAttachmentCount - attachments.count), matching: .images) {
                        Label("Photos", systemImage: "photo.on.rectangle")
                    }
                    Button { capturingPhoto = true } label: { Label("Take Photo", systemImage: "camera") }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    Button { importingFiles = true } label: { Label("Files", systemImage: "folder") }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Add attachment")
                .disabled(attachments.count >= 10 || uploading)
                TextField(prompt, text: $text, selection: $selection, axis: .vertical)
                    .lineLimit(1...4)
                    .focused(typing)
                    .submitLabel(.send)
                    .onSubmit { Task { await send() } }
                    .accessibilityAddTraits(phone.voice.listening ? .updatesFrequently : [])
                DictationMic(active: phone.voice.active, listening: phone.voice.listening,
                             finishing: phone.voice.finishing, level: phone.voice.level, toggle: toggleDictation)
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(sendable ? 1 : 0.4), in: Circle())
                }
                .disabled(!sendable)
                .accessibilityLabel("Send")
                .disabled(uploading)
            }
            .padding(.leading, 18)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(Color(uiColor: .systemGroupedBackground))
        .onChange(of: text) {
            // Typed, sent or filled from elsewhere: the words heard so far stay, later ones don't come.
            if text != written, phone.voice.active || phone.voice.finishing { phone.voice.cancel() }
            if text.isEmpty { dictated = false }
        }
        .onChange(of: photos) { _, values in
            Task { await addPhotos(values); photos = [] }
        }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do {
                for source in try result.get() {
                    guard attachments.count < 10 else { break }
                    let accessed = source.startAccessingSecurityScopedResource()
                    defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: source)
                    try add(data, name: source.lastPathComponent)
                }
            } catch { attachmentProblem = error.localizedDescription }
        }
        .sheet(isPresented: $capturingPhoto) {
            CameraCapture { image in
                guard let data = image.jpegData(compressionQuality: 0.9) else { return }
                do { try add(data, name: "photo-\(attachments.count + 1).jpg") }
                catch { attachmentProblem = error.localizedDescription }
            }
            .ignoresSafeArea()
        }
        .quickLookPreview($previewURL)
    }

    private func send() async {
        guard sendable, !uploading else { return }
        guard attachments.isEmpty || phone.connection == .live else {
            attachmentProblem = "Connect to the runner before sending attachments."
            return
        }
        uploading = true
        defer { uploading = false }
        do {
            let ids = try await Self.uploadAttachmentIDs(attachments, upload: { item in
                try await phone.runner.uploadAttachment(item.data, name: item.name, source: "iphone").id
            }, uploaded: { index, id in
                if phone.attachmentDrafts.indices.contains(index), phone.attachmentDrafts[index].id == attachments[index].id {
                    phone.attachmentDrafts[index].uploadedID = id
                }
            })
            onSend(dictated, ids)
            text = ""
            phone.attachmentDrafts = []
            attachmentProblem = nil
        } catch {
            attachmentProblem = "Upload failed. Nothing was sent. \(error.localizedDescription)"
        }
    }

    @MainActor static func uploadAttachmentIDs(_ attachments: [PhoneAttachmentDraft],
                                               upload: (PhoneAttachmentDraft) async throws -> String,
                                               uploaded: (Int, String) -> Void = { _, _ in }) async throws -> [String] {
        var ids: [String] = []
        for (index, item) in attachments.enumerated() {
            if let id = item.uploadedID { ids.append(id); continue }
            let id = try await upload(item)
            uploaded(index, id)
            ids.append(id)
        }
        return ids
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        for item in items where attachments.count < Self.maxAttachmentCount {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else {
                    throw AttachmentDraftError.invalidImage
                }
                try add(jpeg, name: "photo-\(attachments.count + 1).jpg")
            } catch { attachmentProblem = error.localizedDescription }
        }
    }

    private func preview(_ item: PhoneAttachmentDraft) {
        let safeName = URL(filePath: item.name).lastPathComponent
        let file = FileManager.default.temporaryDirectory.appending(path: "oby-draft-preview-\(item.id.uuidString)-\(safeName)")
        do { try item.data.write(to: file, options: .atomic); previewURL = file }
        catch { attachmentProblem = "Couldn't preview \(item.name): \(error.localizedDescription)" }
    }

    private func add(_ data: Data, name: String) throws {
        guard data.count <= Self.maxAttachmentBytes else { throw AttachmentDraftError.tooLarge }
        guard attachments.count < Self.maxAttachmentCount else { throw AttachmentDraftError.tooMany }
        guard attachments.reduce(data.count, { $0 + $1.data.count }) <= Self.maxMessageBytes else { throw AttachmentDraftError.messageTooLarge }
        phone.attachmentDrafts.append(PhoneAttachmentDraft(name: name, data: data, uploadedID: nil))
        attachmentProblem = nil
    }

    private enum AttachmentDraftError: LocalizedError {
        case tooLarge, tooMany, messageTooLarge, invalidImage
        var errorDescription: String? {
            switch self {
            case .tooLarge: "Each file must be 25 MB or smaller."
            case .tooMany: "A message can have at most 10 files."
            case .messageTooLarge: "Attachments in one message must total 50 MB or less."
            case .invalidImage: "Oby couldn't read that photo. Choose another image."
            }
        }
    }

    /// What the field holds with `words` dictated after `prefix`: a space between, unless there's one.
    static func draft(_ prefix: String, _ words: String) -> String {
        prefix.isEmpty || prefix.last?.isWhitespace == true ? prefix + words : prefix + " " + words
    }

    /// The mic: dictation starts after what the field holds, or stops and keeps the words.
    private func toggleDictation() {
        if phone.voice.active {
            phone.voice.finish()
            return
        }
        typing.wrappedValue = false
        let prefix = text
        written = text
        phone.dictate { words in
            guard !words.isEmpty, text == written else { return }
            text = Self.draft(prefix, words)
            written = text
            dictated = true
            selection = TextSelection(insertionPoint: text.endIndex)
        }
    }
}

private struct CameraCapture: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraCapture
        init(_ parent: CameraCapture) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// The composer's mic: Dictate, or Stop with the input's level under it while it listens.
private struct DictationMic: View {
    let active: Bool
    let listening: Bool
    let finishing: Bool
    let level: Float
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 3) {
                Image(systemName: active ? "stop.fill" : "mic.fill")
                    .font(.body)
                if listening {
                    Capsule()
                        .fill(Color.red.opacity(0.5))
                        .frame(width: 6 + CGFloat(level) * 18, height: 3)
                }
            }
            .foregroundStyle(active ? Color.red : Color.primary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(finishing)
        .accessibilityLabel(active ? "Stop dictating" : "Dictate")
        .accessibilityHint(active ? "Keeps your words in the field to edit and send." : "Your words go into the field as you speak.")
    }
}
