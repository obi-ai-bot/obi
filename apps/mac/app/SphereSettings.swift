import AppKit
import SwiftUI

/// Settings › Obysphere: this Mac's Oby in its Obysphere (onboarding.md section 4). Join with an
/// invite link ("Join Deskree"), or create one on the operator's Mac; once in, who else is in it,
/// invite links (an admin's), asking another Oby for a review, and what other Obys asked.
// ponytail: one page until Sangam's Obysphere screens (Sidebar.tsx, SphereSettings.tsx) are ported.
struct SphereSettingsView: View {
    @State private var sphere: SphereModel
    @State private var pasted = ""
    @State private var invite: InviteLink?
    /// The owner said they trust a link's server that isn't the one Oby knows.
    @State private var trusted = false
    @State private var newName = ""
    @State private var person = ""
    @State private var link: InviteLink?
    @State private var copied = false
    @State private var asked: SphereModel.Member.ID?
    @State private var job: Job.ID?
    @State private var sent: String?
    private let feed: RunnerFeed

    init(feed: RunnerFeed) {
        self.feed = feed
        _sphere = State(initialValue: SphereModel(feed: feed))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if sphere.joined { joined } else { notJoined }
        }
        .disabled(sphere.busy)
        // While the page is open: the membership, the members and what waits, every 20 seconds.
        .task {
            while !Task.isCancelled {
                do { try await sphere.refresh() } catch { sphere.problem = error.localizedDescription }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    // MARK: Not in one yet

    @ViewBuilder private var notJoined: some View {
        if let invite {
            // "Join Deskree" (onboarding.md section 4).
            // The name and who sent it are only what the link says; the server is what joining trusts.
            SetGroup("Join \(invite.name)", problem: sphere.problem) {
                SetRow(invite.by.isEmpty ? "The link says you're invited." : "The link says \(invite.by) invited you.",
                       about: "\(invite.name)'s Obys can ask yours for a review or a question. You decide what it answers.")
                SetRow("Server") { SetCode(invite.host).textSelection(.enabled) }
                if let warning = invite.warning {
                    SetRow(about: warning) {
                        Toggle("I trust \(invite.host)", isOn: $trusted).toggleStyle(.checkbox)
                    }
                }
                SetRow("") {
                    HStack {
                        Button("Not now") { self.invite = nil }.buttonStyle(.set)
                        Button("Join \(invite.name)") { sphere.run { try await sphere.join(invite) } }
                            .buttonStyle(.set).disabled(invite.warning != nil && !trusted)
                    }
                }
            }
        } else {
            SetGroup("Join an Obysphere", footer: "Paste the invite link someone in it sent you.", problem: sphere.problem) {
                SetRow("Invite link") { SetField("Invite link", text: $pasted, prompt: "https://…/join#…", width: 320) }
                SetRow("") {
                    Button("Open") {
                        if let found = InviteLink(pasted) { invite = found; trusted = false; sphere.problem = nil }
                        else { sphere.problem = "That isn't an Obysphere invite link with a public https address." }
                    }
                    .buttonStyle(.set).disabled(pasted.isEmpty)
                }
            }
            if sphere.canCreate {
                SetGroup("Create an Obysphere", footer: "You're its admin. Everyone in it can ask everyone for a review or a question; each Oby still asks its owner.") {
                    SetRow("Name") { SetField("Obysphere name", text: $newName, prompt: "Deskree") }
                    SetRow("") {
                        Button("Create \(newName.isEmpty ? "Obysphere" : newName)") {
                            let name = newName.trimmingCharacters(in: .whitespaces)
                            sphere.run { try await sphere.create(id: Self.slug(name), name: name) }
                        }
                        .buttonStyle(.set).disabled(Self.slug(newName).count < 3)
                    }
                }
            }
        }
    }

    /// nspasteboard.org's marker for a secret on the clipboard.
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Its id from its name (Sangam's `slugOf`): lowercase letters, digits and single hyphens.
    static func slug(_ name: String) -> String {
        let words = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        return String(words.joined(separator: "-").prefix(30))
    }

    // MARK: In one

    @ViewBuilder private var joined: some View {
        let name = sphere.name ?? sphere.membership?.sphere ?? "Obysphere"
        SetGroup(name, footer: sphere.membership?.lastError.map { "Last problem with the Obysphere: \($0)" }, problem: sphere.problem) {
            SetRow("You", about: sphere.admin ? "Admin" : "Member") { SetCode(sphere.owner ?? "") }
            if sphere.members.isEmpty { SetRow("No one else has joined yet", quiet: true) }
            ForEach(sphere.members) { member in
                SetRow(member.name, about: member.active ? member.owner : "\(member.owner) · removed") { SetCode(member.obi) }
            }
        }
        if !sphere.requests.isEmpty {
            SetGroup("Asked of your Oby") {
                ForEach(sphere.requests) { request in requestRow(request) }
            }
        }
        if sphere.admin { inviting(name) }
        asking
    }

    private func inviting(_ name: String) -> some View {
        SetGroup("Invite", footer: "A link is for one person, by the name their Oby knows them by (its owner), and works once, for 7 days.") {
            SetRow("Who it's for") { SetField("Their Oby's owner", text: $person, prompt: "ernesto") }
            if let link {
                SetRow { SetCode(link.link).textSelection(.enabled) } control: {
                    Button(copied ? "Copied" : "Copy") {
                        // Concealed: clipboard managers that honour it don't keep the secret.
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.link, forType: .string)
                        NSPasteboard.general.setString("", forType: Self.concealed)
                        copied = true
                    }
                    .buttonStyle(.set)
                }
            }
            SetRow("") {
                Button("Make an invite link") {
                    let person = person.trimmingCharacters(in: .whitespaces).lowercased()
                    sphere.run { link = try await sphere.invite(person); copied = false }
                }
                .buttonStyle(.set).disabled(person.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    /// Your jobs with an open pull request whose head GitHub has: what another Oby can review.
    private var reviewable: [Job] {
        feed.jobs.filter { PublishedLink.url($0.published) != nil && $0.pullRequest?.state == .open && $0.pullRequest?.head != nil }
    }

    private var asking: some View {
        let members = sphere.members.filter { $0.active && $0.accepts.contains("review_request") }
        return SetGroup("Ask for a review", footer: sent ?? "Their Oby asks them first, then reviews the pull request at its latest commit and answers here and on the job.") {
            SetRow("Who") {
                SetSelect("Who", selection: $asked, options: [(nil, "Choose")] + members.map { (Optional($0.id), $0.name) })
            }
            SetRow("Pull request") {
                SetSelect("Pull request", selection: $job, options: [(nil, "Choose")] + reviewable.map { (Optional($0.id), $0.title ?? $0.task) })
            }
            SetRow("") {
                Button("Ask for a review") {
                    guard let member = members.first(where: { $0.id == asked }), let job = reviewable.first(where: { $0.id == job }) else { return }
                    sphere.run {
                        try await sphere.askForReview(member, of: job)
                        sent = "Asked \(member.name) to review \(job.title ?? job.task)."
                    }
                }
                .buttonStyle(.set).disabled(asked == nil || job == nil)
            }
        }
    }

    /// What another Oby asks: obid's words from typed fields, then the other Oby's own text,
    /// quoted, then the four answers.
    private func requestRow(_ request: SphereModel.Request) -> some View {
        SetRow(about: request.text) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: request.title)
                ForEach(Array(request.quoted.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: "\(line.0): “\(line.1)”").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                        .textSelection(.enabled)
                }
                HStack {
                    ForEach(Array(request.options.enumerated()), id: \.offset) { index, option in
                        Button(option) { sphere.run { try await sphere.answer(request, option) } }
                            .buttonStyle(.set)
                            .help(request.details.indices.contains(index) ? request.details[index] : option)
                    }
                }
            }
        }
    }
}
