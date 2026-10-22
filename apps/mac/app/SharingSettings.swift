import SwiftUI

/// Settings › Sharing (Sangam's SettingsView.tsx `Sharing`, #808; docs/runner-api.md, "obid only:
/// sharing this Mac"): this Mac's spare time for the people in your Obysphere. Their jobs run here
/// in a sealed VM of their own, with their own AI accounts; off until you turn it on. Share your
/// usage gives someone a share of a company API account's month, and Kept for you says why the
/// other accounts aren't shared (#809, docs/runner-api.md, "obid only: sharing your usage").
struct SharingSettingsView: View {
    let feed: RunnerFeed
    @State private var sphere: SphereModel
    @State private var mac: RunnerSharingMac?
    @State private var grants: RunnerGrants?
    @State private var problem: String?
    @State private var busy = false
    @State private var renewed = false

    init(feed: RunnerFeed, mac: RunnerSharingMac? = nil, grants: RunnerGrants? = nil) {
        self.feed = feed
        _sphere = State(initialValue: SphereModel(feed: feed))
        _mac = State(initialValue: mac)
        _grants = State(initialValue: grants)
    }

    /// "Deskree": the Obysphere's name, as Sangam's words have it.
    private var team: String { sphere.name ?? "your Obysphere" }

    static let onFooter = "Their jobs run in a sealed box on this Mac, with their own AI accounts: they can’t see your files, logins, Keychain or network, and their logins never come here. When you’re back, their jobs pause, and after 10 minutes go back to their Obys with their notes."
    static func offFooter(_ team: String) -> String { "Let people in \(team) run jobs on this Mac while you’re not using it, with their own AI accounts." }
    static func logFooter(_ team: String) -> String { "Every job someone runs here is in \(team)’s signed log, with who ran it and for how long." }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let mac {
                thisMac(mac)
                if mac.settings.on { onThisMac(mac) }
                if let grants {
                    shareYourUsage(grants, mac: mac)
                    keptForYou(grants)
                }
            } else {
                SetGroup(problem: problem) {
                    SetRow(feed.runner == nil ? "Set the runner's address first." : "This runner doesn't share its Mac.", quiet: true)
                }
            }
        }
        .disabled(busy)
        // While the page is open: what runs here, every 5 seconds.
        .task(id: feed.runner?.base.absoluteString ?? "") {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: This Mac

    /// What the VM's image needs before this Mac can run anyone's jobs: nothing once it's here;
    /// while obid fetches it, how far it got.
    static func imageAbout(_ mac: RunnerSharingMac) -> String? {
        if mac.ready { return nil }
        guard let image = mac.image else { return "This Mac needs Oby’s VM before it can run anyone’s jobs." }
        let size = { (bytes: Int64?) in ByteCountFormatter.string(fromByteCount: bytes ?? 0, countStyle: .file) }
        switch image.state {
        case "fetching": return "Getting the VM’s image: \(size(image.done)) of \(size(image.total))."
        case "failed": return image.error ?? "The VM’s image couldn’t be fetched."
        // No size: obid knows no image (obi-vm isn't in this build).
        default: return (image.total ?? 0) > 0 ? "Turning it on gets the VM’s image first (\(size(image.total)))." : "The VM isn’t bundled in this build of Oby."
        }
    }

    private func thisMac(_ mac: RunnerSharingMac) -> some View {
        let settings = mac.settings
        return SetGroup("This Mac", footer: settings.on ? Self.onFooter : Self.offFooter(team), problem: problem) {
            SetRow("Share this Mac with \(team)", about: Self.imageAbout(mac)) {
                HStack(spacing: 8) {
                    // Fetching the VM's image failed: once more, as turning sharing on does.
                    if settings.on && mac.image?.state == "failed" {
                        Button("Try again") { turn(true) }.buttonStyle(.set)
                    }
                    Toggle("Share this Mac with \(team)", isOn: Binding(get: { settings.on }, set: { on in turn(on) }))
                        .toggleStyle(.set)
                        .disabled(!mac.ready && !settings.on && mac.image == nil)
                }
            }
            if settings.on {
                SetRow("When", about: "Away: no keyboard or mouse for 10 minutes. Never on battery, in Low Power Mode or when it’s hot.") {
                    SetSelect("When", selection: binding(\.when, Self.when, Self.whenList), options: [
                        ("away", "When I’m away"), ("nights", "Nights and weekends"), ("both", "Away, nights and weekends"),
                    ])
                }
                SetRow("Who") {
                    SetSelect("Who", selection: binding(\.who, Self.who, Self.whoValue), options: [
                        ("ask", "Everyone, ask me first"), ("everyone", "Everyone in \(team)"), ("chosen", "Only people I choose"),
                    ])
                }
                if settings.who == "people" {
                    ForEach(sphere.members.filter(\.active)) { member in
                        SetRow(RunnerMac.person(member.owner)) {
                            Toggle("Share with \(RunnerMac.person(member.owner))", isOn: Binding(
                                get: { settings.people.contains(member.owner) },
                                set: { on in change { $0.people = on ? $0.people + [member.owner] : $0.people.filter { $0 != member.owner } } }))
                                .toggleStyle(.set)
                        }
                    }
                    // Chosen, not in the Obysphere yet: offered nothing until they join.
                    ForEach((mac.waiting ?? []).filter { p in !sphere.members.contains { $0.active && $0.owner == p } }, id: \.self) { person in
                        SetRow(RunnerMac.person(person), about: "Waiting to join") {
                            Toggle("Share with \(RunnerMac.person(person))", isOn: Binding(
                                get: { settings.people.contains(person) },
                                set: { on in change { $0.people = on ? $0.people + [person] : $0.people.filter { $0 != person } } }))
                                .toggleStyle(.set)
                        }
                    }
                }
                SetRow("Jobs at once") {
                    SetSelect("Jobs at once", selection: binding(\.jobsAtOnce, { $0 }, { $0 }), options: [(1, "1"), (2, "2"), (3, "3")])
                }
                SetRow("Each job gets") {
                    SetSelect("Each job gets", selection: binding(\.size, { $0 }, { $0 }), options: [
                        ("small", "4 cores · 8 GB · 30 GB of disk"), ("large", "6 cores · 12 GB · 60 GB of disk"),
                    ])
                }
                SetRow("Work") {
                    SetSelect("Work", selection: binding(\.work, { $0 }, { $0 }), options: [
                        ("any", "Any job in \(team)’s repositories"), ("reviews", "Reviews and checks only"),
                    ])
                }
            }
        }
    }

    // MARK: On this Mac now

    private func onThisMac(_ mac: RunnerSharingMac) -> some View {
        SetGroup("On this Mac now", footer: Self.logFooter(team) + (mac.week.map { " " + Self.weekLine($0) } ?? "")) {
            if mac.jobs.isEmpty {
                SetRow("Nobody right now", quiet: true)
            }
            ForEach(mac.jobs) { guest in
                SetRow(about: Self.about(guest)) {
                    Text(verbatim: "\(RunnerMac.person(guest.fromOwner)) · \(guest.title)")
                } control: {
                    Button("Stop", role: .destructive) { stop(guest.id) }
                        .buttonStyle(.set)
                        .accessibilityLabel("Stop \(RunnerMac.person(guest.fromOwner))’s job")
                }
            }
            if mac.jobs.count > 1 {
                SetRow("") { Button("Stop All", role: .destructive) { stop(nil) }.buttonStyle(.set) }
            }
        }
    }

    /// "This week: 3 jobs, 2 h 10 min." (#810), from obid's own log of what ran here.
    static func weekLine(_ week: RunnerSharingMac.Week) -> String {
        guard week.jobs > 0 else { return "None this week." }
        let minutes = week.wallSeconds / 60
        let time = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        return "This week: \(week.jobs) job\(week.jobs == 1 ? "" : "s"), \(time)."
    }

    /// "Claude Code on Sangam’s account · tetrix-ee · 12 min", and " · Paused" while its owner's back.
    static func about(_ guest: RunnerSharingMac.Guest, now: Date = .now) -> String {
        let agent = guest.agent == "codex" ? "Codex" : "Claude Code"
        let minutes = max(0, Int(now.timeIntervalSince(guest.started) / 60))
        let repo = guest.repo.split(separator: "/").last.map(String.init) ?? guest.repo
        let paused = guest.state == "paused" ? " · Paused" : ""
        return "\(agent) on \(RunnerMac.person(guest.fromOwner))’s account · \(repo) · \(minutes) min\(paused)"
    }

    // MARK: Share your usage, Kept for you

    static func usageFooter(_ team: String) -> String {
        "Only an account \(team) pays by use can be shared. A shared job runs on this Mac, on that account: they get the results and the pull request, and its key never leaves this Mac. Once their share is used, Oby takes no more of their jobs on it and finishes the one running."
    }
    static let shares = [10, 20, 30, 50, 75, 100]
    // ponytail: preset months; a field when someone's month isn't one of these.
    static let budgets = [100, 200, 400, 1000, 2000, 5000, 10000]

    private func shareYourUsage(_ grants: RunnerGrants, mac: RunnerSharingMac) -> some View {
        let shareable = grants.accounts.filter { $0.why == nil }
        let members = sphere.members.filter(\.active).map(\.owner).filter { $0 != sphere.membership?.owner }
        return SetGroup("Share your usage", footer: Self.usageFooter(team)) {
            if shareable.isEmpty { SetRow("No account \(team) pays by use", quiet: true) }
            ForEach(shareable) { account in
                let grant = grants.grants.first { $0.account == account.id }
                let who = grant?.who ?? "nobody"
                // Sangam's row: the tool's mark, the account, what was used, and the meter under it.
                SetRow(controlOnTop: true) {
                    HStack(alignment: .top, spacing: 10) {
                        AgentMark(agent: account.agent).font(Tokens.font(13)).frame(width: 16).foregroundStyle(Tokens.muted).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(Usage.tool(account.agent)) · \(account.name)")
                            SetAbout(Self.usageAbout(grant, key: grants.key, macOn: mac.settings.on))
                            if let grant, who != "nobody" { SetMeter(used: Self.usedPercent(grant) * 100 / Double(max(grant.share + grant.extra, 1))) }
                        }
                    }
                } control: {
                    VStack(alignment: .trailing, spacing: 8) {
                        SetSelect("Share \(account.name) with", selection: Binding(get: { who }, set: { share(account, who: $0, grant) }),
                                  options: Self.whoOptions(members: members, who: who))
                        if let grant, who != "nobody" {
                            SetSelect("How much of its month", selection: Binding(get: { grant.share }, set: { share(account, share: $0, grant) }),
                                      options: Self.shares.map { ($0, "\($0)% of its month") })
                            SetSelect("Its month", selection: Binding(get: { grant.budgetCents / 100 }, set: { share(account, budget: $0, grant) }),
                                      options: Self.budgets.map { ($0, "$\($0) a month") })
                        }
                    }
                }
            }
        }
    }

    private func keptForYou(_ grants: RunnerGrants) -> some View {
        let kept = grants.accounts.filter { $0.why != nil }
        return Group {
            if !kept.isEmpty {
                SetGroup("Kept for you") {
                    ForEach(kept) { account in
                        SetRow {
                            HStack(alignment: .top, spacing: 10) {
                                AgentMark(agent: account.agent).font(Tokens.font(13)).frame(width: 16).foregroundStyle(Tokens.muted).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(Usage.tool(account.agent)) · \(account.name)")
                                    if let why = account.why { SetAbout(why) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Nobody, Everyone, then each member by name; the one it's shared with even when they've left.
    static func whoOptions(members: [String], who: String) -> [(String, String)] {
        let people = members.contains(who) || ["nobody", "everyone"].contains(who) ? members : members + [who]
        return [("nobody", "Nobody"), ("everyone", "Everyone")] + people.map { ($0, RunnerMac.person($0)) }
    }

    /// What a share's teammates used this month, in percent of its month: one person's, or
    /// everyone's together.
    static func usedPercent(_ grant: RunnerGrants.Grant, owner: String? = nil) -> Double {
        let theirs = grant.usedCents.filter { grant.who == "everyone" ? $0.key != owner : $0.key == grant.who }.values.reduce(0, +)
        return Double(theirs) * 100 / Double(max(grant.budgetCents, 1))
    }

    /// "Not shared", or "Sangam used 9% of 30% this month" (Sangam's words), and what the share
    /// still needs: the key in the vault, this Mac shared.
    static func usageAbout(_ grant: RunnerGrants.Grant?, key: Bool, macOn: Bool) -> String {
        guard let grant, grant.who != "nobody" else { return "Not shared" }
        let whom = grant.who == "everyone" ? "Everyone" : RunnerMac.person(grant.who)
        var line = "\(whom) used \(Int(usedPercent(grant).rounded()))% of \(grant.share + grant.extra)% this month"
        if !(grant.keyInVault ?? key) { line += ". Put its key in Oby’s vault as \(grant.keyName ?? "anthropic-api-key") to share it" }
        if !macOn { line += ". Their jobs run on this Mac: share this Mac too" }
        return line
    }

    private func share(_ account: RunnerGrants.Account, who: String? = nil, share: Int? = nil, budget: Int? = nil, _ grant: RunnerGrants.Grant?) {
        let who = who ?? grant?.who ?? "nobody"
        busy = true
        Task {
            defer { busy = false }
            do {
                guard let runner = feed.runner else { return }
                // A first share re-signs the card and delegation, so this Oby may offer one (send:share_offer).
                if grant.map({ $0.who == "nobody" }) ?? true, who != "nobody" { try await sphere.renew(sharing: true) }
                _ = try await runner.setGrant(account: account.id, who: who, share: share ?? grant?.share ?? 20,
                                              budgetCents: (budget ?? (grant?.budgetCents ?? 40000) / 100) * 100, resetsDay: grant?.resetsDay ?? 1)
                self.grants = try await runner.sharingGrants()
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    // MARK: Settings as Sangam's menus have them

    /// obid's `when` as the menu's one choice, and back.
    static func when(_ list: [String]) -> String {
        switch (list.contains("away"), list.contains("schedule")) {
        case (true, true): "both"
        case (false, true): "nights"
        default: "away"
        }
    }
    static func whenList(_ value: String) -> [String] {
        switch value {
        case "both": ["away", "schedule"]
        case "nights": ["schedule"]
        default: ["away"]
        }
    }
    static func who(_ value: String) -> String { value == "people" ? "chosen" : value }
    static func whoValue(_ choice: String) -> String { choice == "chosen" ? "people" : choice }

    private func binding<Value, Shown: Hashable>(_ path: WritableKeyPath<RunnerSharingMac.Settings, Value>,
                                                 _ shown: @escaping (Value) -> Shown, _ kept: @escaping (Shown) -> Value) -> Binding<Shown> {
        Binding(get: { shown(mac?.settings[keyPath: path] ?? kept(shown(RunnerSharingMac.Settings.off[keyPath: path]))) },
                set: { value in change { $0[keyPath: path] = kept(value) } })
    }

    // MARK: Talking to obid

    private func load() async {
        guard let runner = feed.runner else { return }
        do {
            mac = try await runner.sharingMac()
            grants = try await runner.sharingGrants()
            if sphere.name == nil { try? await sphere.refresh() }
            // So teammates can share their usage with you, the card takes share_offer: added the
            // first time this page opens (a Sphere from before it refuses it, and nothing changes).
            if mac != nil, sphere.membership != nil, (try? await runner.sharedWithMe())?.takesShares == false, !renewed {
                renewed = true
                try? await sphere.renew(sharing: true)
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    private func change(_ edit: (inout RunnerSharingMac.Settings) -> Void) {
        guard var settings = mac?.settings else { return }
        edit(&settings)
        save(settings)
    }

    /// On: first a card that takes teammates' jobs, and a delegation that may send one, signed
    /// here with the owner key; then sharing on. Off: obid stops every job here at once.
    private func turn(_ on: Bool) {
        guard var settings = mac?.settings else { return }
        settings.on = on
        busy = true
        Task {
            defer { busy = false }
            do {
                if on { try await sphere.renew(sharing: true) }
                guard let runner = feed.runner else { return }
                mac = try await runner.setSharingMac(settings)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func save(_ settings: RunnerSharingMac.Settings) {
        Task {
            do {
                guard let runner = feed.runner else { return }
                mac = try await runner.setSharingMac(settings)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func stop(_ job: String?) {
        Task {
            do {
                try await feed.runner?.stopGuests(job)
                await load()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

extension RunnerSharingMac.Settings {
    /// Off, with the defaults the owner accepted on 2026-10-20 for when it's turned on.
    static let off = RunnerSharingMac.Settings(on: false, when: ["away"], who: "ask", people: [], allowed: [], jobsAtOnce: 1,
                                               size: "small", work: "any", maxMinutes: 120)
}
