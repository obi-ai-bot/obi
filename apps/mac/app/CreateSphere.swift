import AppKit
import Synchronization
import SwiftUI
import UniformTypeIdentifiers

/// Making an Obysphere (Sangam's CreateSphereModal, the + in the icon strip): its name; its id,
/// made from the name until you change it; a logo, if you have one (else the name's first letter);
/// people to invite, if any yet; and whether anyone with an address at your org can join by its
/// link (on for a work address; not offered for a personal one). You're its admin. Create signs
/// you in with Google when this Mac has no operator token (sphere-api.md section 3.1), joins your
/// Oby, and opens a message to the people invited in Mail, for you to send.
struct CreateSphereSheet: View {
    let feed: RunnerFeed
    /// The Obysphere's id once it's made.
    let done: (String) -> Void
    let close: () -> Void
    @State private var sphere: SphereModel
    @State private var name = ""
    /// The id follows the name until it's typed in itself.
    @State private var ownSlug: String?
    @State private var image: NSImage?
    @State private var emails: [String] = []
    @State private var draft = ""
    @State private var email: String?
    @State private var anyone = true
    @State private var taken: String?
    /// The id the server said is free.
    @State private var free: String?
    @State private var creating = false

    /// `name`, `emails` and `email` start it filled in, for pictures of it (SphereScreens).
    init(feed: RunnerFeed, name: String = "", emails: [String] = [], email: String? = nil,
         done: @escaping (String) -> Void, close: @escaping () -> Void) {
        (self.feed, self.done, self.close) = (feed, done, close)
        _sphere = State(initialValue: SphereModel(feed: feed))
        (_name, _emails, _email) = (State(initialValue: name), State(initialValue: emails), State(initialValue: email))
    }

    /// Addresses anyone can have: no org behind them, so no "anyone there can join".
    static let personal: Set<String> = ["gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "icloud.com", "me.com", "yahoo.com", "proton.me", "protonmail.com"]
    static func workDomain(_ email: String?) -> String? {
        guard let domain = email?.split(separator: "@").last.map({ $0.lowercased() }), email?.contains("@") == true,
              !personal.contains(domain), !domain.hasSuffix("users.noreply.github.com") else { return nil }
        return domain
    }
    static func isEmail(_ text: String) -> Bool { text.wholeMatch(of: /[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+/) != nil }

    private var slug: String { ownSlug ?? SphereSettingsView.slug(name) }
    private var domain: String? { Self.workDomain(email) }
    private var problem: String? {
        if slug.isEmpty { return nil }
        if slug.count < 3 { return "At least 3 characters" }
        return taken == slug ? "\(slug) is taken" : nil
    }
    private var all: [String] { emails + (draft.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [draft.trimmingCharacters(in: .whitespaces)]) }
    private var ready: Bool {
        name.trimmingCharacters(in: .whitespaces).count >= 2 && !slug.isEmpty && problem == nil && all.allSatisfy(Self.isEmail) && !creating
    }
    private var host: String { SphereModel.server?.host() ?? "no server yet" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Create an Obysphere").font(Tokens.font(17, .semibold)).foregroundStyle(Tokens.ink)
                Spacer()
                IconButton(symbol: "xmark", action: close).keyboardShortcut(.cancelAction).accessibilityLabel("Close")
            }
            .padding(.top, -4).padding(.trailing, -6).padding(.bottom, 8)
            Text("Where your Oby works with other people’s. You’ll be its admin.")
                .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted).padding(.bottom, 20)

            // The logo beside the name: a click picks an image; its badge takes it out again.
            HStack(alignment: .bottom, spacing: 16) {
                Button(action: pickImage) { SphereTile(name: name.isEmpty ? "?" : name, image: image, size: 64) }
                    .buttonStyle(.plain)
                    .help(image == nil ? "Add a logo" : "Change logo")
                    .overlay(alignment: .bottomTrailing) {
                        Button { image = nil } label: {
                            Image(systemName: image == nil ? "photo.badge.plus" : "xmark").font(Tokens.font(10, .semibold))
                                .foregroundStyle(Tokens.text).frame(width: 22, height: 22)
                                .background(Color(hex: 0x2C2C2B), in: Circle()).overlay(Circle().strokeBorder(Tokens.surface, lineWidth: 2))
                        }
                        .buttonStyle(.plain).disabled(image == nil).offset(x: 6, y: 6)
                        .accessibilityLabel(image == nil ? "Add a logo" : "Remove logo")
                    }
                VStack(alignment: .leading, spacing: 8) {
                    label("Name")
                    ModalField { TextField("Name", text: $name, prompt: Text("Team or project name").foregroundStyle(Tokens.muted)) }
                        .onChange(of: name) { if name.count > 40 { name = String(name.prefix(40)) } }
                }
            }

            label("Obysphere URL").padding(.top, 20)
            ModalField(bad: problem != nil) {
                HStack(spacing: 0) {
                    TextField("Obysphere URL", text: Binding(get: { slug }, set: { ownSlug = SphereSettingsView.slug($0) }))
                        .fixedSize()
                    Text(" on \(host)").foregroundStyle(Tokens.muted).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            Group {
                if let problem { Text(problem).foregroundStyle(Tokens.danger) }
                else if free == slug { Label("Available", systemImage: "checkmark").foregroundStyle(Tokens.text) }
                else { Text("Letters, numbers and hyphens").foregroundStyle(Tokens.muted) }
            }
            .font(Tokens.font(Tokens.textSm)).padding(.top, 8)
            // Free or taken, said as it's typed: the Sphere answers 404 for an id it doesn't have, 401 (no token) for one it does.
            .task(id: slug) {
                guard slug.count >= 3, let server = SphereModel.server, (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
                do {
                    _ = try await SphereServer(base: server).call("GET", "spheres/\(slug)")
                } catch let error as RunnerError where error.status == 404 {
                    free = slug
                } catch let error as RunnerError where error.status == 401 {
                    taken = slug
                } catch {}
            }

            HStack {
                label("Invite people")
                Spacer()
                Text("Optional").font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.muted)
            }
            .padding(.top, 20)
            EmailTags(emails: $emails, draft: $draft, submit: create)
            if let domain {
                HStack(spacing: 16) {
                    Text("Anyone with @\(domain) can join").font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.text)
                    Spacer()
                    Toggle("Anyone with @\(domain) can join", isOn: $anyone).toggleStyle(.set).labelsHidden()
                }
                .padding(.top, 16)
            }

            if let problem = sphere.problem {
                Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger).padding(.top, 16)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(action: create) {
                    HStack(spacing: 6) {
                        if creating { ProgressView().controlSize(.small) }
                        Text(creating ? "Creating…" : "Create Obysphere")
                    }
                    .font(Tokens.font(Tokens.textBase, .medium)).foregroundStyle(Tokens.onInk)
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(Tokens.ink, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .opacity(ready ? 1 : 0.3)
                }
                .buttonStyle(.plain).disabled(!ready).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24)
        }
        .padding(20)
        .frame(width: 480)
        .background(Tokens.surface)
        .task { if email == nil { email = await Self.ownEmail() } }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Tokens.font(Tokens.textMd, .medium)).foregroundStyle(Tokens.item)
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url, let picked = NSImage(contentsOf: url) { image = picked }
    }

    private func create() {
        guard ready else { return }
        let invited = all
        let id = slug, name = name.trimmingCharacters(in: .whitespaces)
        creating = true
        sphere.problem = nil
        Task {
            defer { creating = false }
            do {
                try await sphere.refresh()
                let made = try await sphere.create(id: id, name: name, emails: invited, domain: anyone ? domain : nil)
                if let image { SphereTile.keep(image) }
                if let mailed = made.mailed { SphereModel.mail(mailed, to: invited) }
                done(id)
            } catch let error as RunnerError where error.status == 409 && error.message.contains("is taken") {
                taken = id
            } catch {
                sphere.problem = error.localizedDescription
            }
        }
    }

    /// The owner's email, for its domain: GitHub's primary one, else git's.
    static func ownEmail() async -> String? {
        await Agents.readIdentity()
        if let email = Agents.identity.withLock({ $0 })?.email, !email.hasSuffix("@users.noreply.github.com") { return email }
        return (try? await Shell.ok(["git", "config", "--global", "user.email"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Sangam's `.modal-field`: 44 tall, 12 round, `field` fill, a line that lights hovered or focused, red when it's wrong.
private struct ModalField<Content: View>: View {
    var bad = false
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        content
            .textFieldStyle(.plain).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.ink).autocorrectionDisabled()
            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Tokens.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(bad ? Tokens.danger.opacity(0.5) : hovering ? Tokens.fieldEdgeOn : Tokens.line))
            .onHover { hovering = $0 }
    }
}

/// Addresses typed into one field (Sangam's EmailField): each, once finished (a comma, a space or
/// Return after it, or a list pasted in), becomes a tag, red if it isn't an email, with an x to take it out.
private struct EmailTags: View {
    @Binding var emails: [String]
    @Binding var draft: String
    let submit: () -> Void

    var body: some View {
        let wrong = emails.filter { !CreateSphereSheet.isEmail($0) }
        VStack(alignment: .leading, spacing: 8) {
            ModalField(bad: !wrong.isEmpty) {
                Tags(spacing: 6) {
                    ForEach(emails, id: \.self) { email in
                        let ok = CreateSphereSheet.isEmail(email)
                        HStack(spacing: 4) {
                            Text(email)
                            Button { emails.removeAll { $0 == email } } label: { Image(systemName: "xmark").font(Tokens.font(9, .bold)) }
                                .buttonStyle(.plain).accessibilityLabel("Remove \(email)")
                        }
                        .font(Tokens.font(Tokens.textMd)).foregroundStyle(ok ? Tokens.unread : Tokens.danger)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background((ok ? Tokens.unread : Tokens.danger).opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    TextField("Invite people", text: $draft, prompt: Text(emails.isEmpty ? "Add emails, or paste a list" : "").foregroundStyle(Tokens.muted))
                        .frame(minWidth: 160)
                        .onChange(of: draft) { if draft.contains(where: { " ,;\n\t".contains($0) }) { take() } }
                        .onSubmit { if draft.trimmingCharacters(in: .whitespaces).isEmpty { submit() } else { take() } }
                        .onKeyPress(.delete) {
                            guard draft.isEmpty, !emails.isEmpty else { return .ignored }
                            emails.removeLast()
                            return .handled
                        }
                }
                .padding(.vertical, 10)
                .frame(minHeight: 76, alignment: .topLeading)
            }
            if !wrong.isEmpty {
                Text("Not an email: \(wrong.joined(separator: ", "))").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger)
            }
        }
    }

    /// What's typed into tags: split where the separators are, each address once, however it's capitalised.
    private func take() {
        for found in draft.split(whereSeparator: { " ,;\n\t".contains($0) }).map(String.init)
        where !emails.contains(where: { $0.lowercased() == found.lowercased() }) {
            emails.append(found)
        }
        draft = ""
    }
}

/// Rows of tags that wrap, left to right.
private struct Tags: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for (index, x) in row.items {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y + row.height / 2), anchor: .leading, proposal: .unspecified)
            }
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [(Int, CGFloat)], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(items: [(Int, CGFloat)], y: CGFloat, width: CGFloat, height: CGFloat)] = [([], 0, 0, 0)]
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            var row = rows.removeLast()
            if !row.items.isEmpty && row.width + spacing + size.width > width {
                rows.append(row)
                row = ([], row.y + row.height + spacing, 0, 0)
            }
            let x = row.items.isEmpty ? 0 : row.width + spacing
            row.items.append((index, x))
            row.width = x + size.width
            row.height = max(row.height, size.height)
            rows.append(row)
        }
        return rows
    }
}

/// An Obysphere's picture (Sangam's SphereTile): its logo, else its name's first letter on black.
struct SphereTile: View {
    let name: String
    var image: NSImage?
    var size: CGFloat = 26

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * (size > 40 ? 0.25 : 0.31), style: .continuous)
        ZStack {
            Color.black
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Text(name.prefix(1).uppercased()).font(Tokens.font(size * (size > 40 ? 0.44 : 0.5), .semibold)).foregroundStyle(Tokens.ink) }
        }
        .frame(width: size, height: size).clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
    }

    /// This Mac's copy of its Obysphere's logo: the Sphere keeps no images yet, so only you see it.
    // ponytail: one Obysphere per Oby (obid joins one), so one file; a logo the Sphere shares needs a spec change.
    static let file = Workspace.root.appending(path: "sphere-logo.png")
    static func keep(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: file)
    }
    static var kept: NSImage? { NSImage(contentsOf: file) }
}
