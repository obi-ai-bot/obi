import AppKit
import SwiftUI

/// Settings › Obysphere: this Mac's Oby in its Obysphere (onboarding.md section 4). The server it
/// uses; join with an invite link ("Join Deskree"), or create one (the strip's +); once in, who else
/// is in it, the team link (an admin's), asking another Oby for a review, and what other Obys asked.
// ponytail: one page until Sangam's Obysphere screens (Sidebar.tsx, SphereSettings.tsx) are ported.
struct SphereSettingsView: View {
    @State private var sphere: SphereModel
    @State private var pasted = ""
    @State private var invite: InviteLink?
    /// The owner said they trust a link's server that isn't the one Oby knows.
    @State private var trusted = false
    @State private var creating = false
    @State private var serverText = UserDefaults.standard.string(forKey: SphereModel.serverKey) ?? ""
    @State private var email: String?
    @State private var anyone = true
    @State private var copied = false
    @State private var asked: SphereModel.Member.ID?
    /// The member whose key you're about to accept, once you've compared it with them.
    @State private var comparing: SphereModel.Member?
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
                       about: "\(invite.name)'s Obys can ask yours for a review or a question. You decide what it answers."
                           + (invite.members.map { " \($0 == 1 ? "1 Oby is" : "\($0) Obys are") in it." } ?? ""))
                if let domain = invite.domain {
                    SetRow("For @\(domain) accounts", about: "Oby asks you to sign in with Google first, so \(invite.host) can check you're at \(domain).")
                }
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
                        guard let found = InviteLink(pasted) else {
                            sphere.problem = "That isn't an Obysphere invite link with a public https address."
                            return
                        }
                        trusted = false
                        // What the Sphere says of it (its name, who's in it, a Workspace limit); the link's own words if it can't say.
                        sphere.run { invite = (try? await sphere.preview(found)) ?? found }
                    }
                    .buttonStyle(.set).disabled(pasted.isEmpty)
                }
            }
            SetGroup("Create an Obysphere", footer: "You're its admin. Everyone in it can ask everyone for a review or a question; each Oby still asks its owner.") {
                SetRow("", about: SphereModel.server == nil ? "Set the server below first." : nil) {
                    Button("Create an Obysphere…") { creating = true }.buttonStyle(.set).disabled(!sphere.canCreate)
                }
            }
        }
        SetGroup("Server", footer: "Where your Obysphere lives: Deskree's for Deskree's people, or your own (obi-sphere's docs/run-your-own.md). Empty: the one this Oby came with, if any.") {
            SetRow("Address") {
                SetField("Obysphere server", text: $serverText, prompt: (Bundle.main.object(forInfoDictionaryKey: "ObySphereURL") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "https://sphere.example.com", width: 280)
                    .onSubmit(saveServer)
            }
            SetRow("") { Button("Save", action: saveServer).buttonStyle(.set).disabled(serverText == (UserDefaults.standard.string(forKey: SphereModel.serverKey) ?? "")) }
        }
        .sheet(isPresented: $creating) {
            CreateSphereSheet(feed: feed, done: { _ in
                creating = false
                Task { try? await sphere.refresh() }
            }, close: { creating = false })
        }
    }

    private func saveServer() {
        let text = serverText.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if text.isEmpty {
            UserDefaults.standard.removeObject(forKey: SphereModel.serverKey)
        } else if let url = URL(string: text), let problem = SphereServer.problem(url) {
            sphere.problem = problem
            return
        } else {
            UserDefaults.standard.set(text, forKey: SphereModel.serverKey)
        }
        serverText = text
        sphere.problem = nil
    }

    /// nspasteboard.org's marker for a secret on the clipboard.
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Its id from its name (Sangam's `slugOf`): lowercase letters, digits and single hyphens.
    static func slug(_ name: String) -> String {
        let words = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        return String(words.joined(separator: "-").prefix(30))
    }

    /// "ernesto · key ed25519:…", the fingerprint to compare with them; or, when the Obysphere shows
    /// another key for them, what to do before your Oby trusts them again.
    static func memberAbout(_ member: SphereModel.Member) -> String {
        let who = member.active ? member.owner : "\(member.owner) · removed"
        if let new = member.changedTo {
            return "\(who) · their key changed to \(new). Your Oby doesn't trust them until you compare it with \(member.owner), in person or by phone, and accept it."
        }
        return member.fingerprint.map { "\(who) · key \($0)\(member.verified ? "" : " · unverified")" } ?? who
    }

    // MARK: In one

    @ViewBuilder private var joined: some View {
        let name = sphere.name ?? sphere.membership?.sphere ?? "Obysphere"
        SetGroup(name, footer: sphere.membership?.lastError.map { "Last problem with the Obysphere: \($0)" }, problem: sphere.problem) {
            SetRow("You", about: [sphere.admin ? "Admin" : "Member", sphere.ownFingerprint.map { "your key \($0)" }].compactMap(\.self).joined(separator: " · ")) {
                SetCode(sphere.owner ?? "")
            }
            if sphere.members.isEmpty { SetRow("No one else has joined yet", quiet: true) }
            ForEach(sphere.members) { member in
                SetRow(member.name, about: Self.memberAbout(member)) {
                    if member.changedTo != nil {
                        Button("Accept new key") { comparing = member }.buttonStyle(.set)
                    } else if !member.verified && member.fingerprint != nil {
                        Button("Verify key") { comparing = member }.buttonStyle(.set)
                    } else {
                        SetCode(member.obi)
                    }
                }
            }
        }
        .confirmationDialog("Does \(comparing?.owner ?? "your teammate") read you this key?",
                            isPresented: Binding(get: { comparing != nil }, set: { if !$0 { comparing = nil } }),
                            titleVisibility: .visible) {
            Button("It matches") {
                if let member = comparing {
                    comparing = nil
                    Task { try? await sphere.acceptKey(member) }
                }
            }
            Button("Cancel", role: .cancel) { comparing = nil }
        } message: {
            Text("\(comparing?.changedTo ?? comparing?.fingerprint ?? "")\n\nCompare it with \(comparing?.owner ?? "them") in person or by phone, every character. Your Oby trusts their Oby with this key.")
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
        let domain = CreateSphereSheet.workDomain(email)
        return SetGroup("Invite", footer: domain != nil && anyone
                            ? "One link for everyone at \(domain!): \(SphereModel.server?.host() ?? "the server") has each one sign in with Google, for 30 days. A new link stops none of the old ones."
                            : "One link for your team, up to 50 people, for 7 days. Anyone who has it can join: send it only to them.") {
            if let domain {
                SetRow("Anyone with @\(domain) can join") { Toggle("Anyone with @\(domain) can join", isOn: $anyone).toggleStyle(.set) }
            }
            if let link = sphere.teamLink {
                // The secret after the # only through Copy, which conceals it.
                SetRow { SetCode(link.link.components(separatedBy: "#")[0] + "#…") } control: {
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
                Button(sphere.teamLink == nil ? "Make a link" : "Make a new link") {
                    sphere.run { _ = try await sphere.makeTeamLink(domain: anyone ? domain : nil); copied = false }
                }
                .buttonStyle(.set)
            }
        }
        .task { email = await CreateSphereSheet.ownEmail() }
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
