import SwiftUI

/// Settings › Sharing (Sangam's SettingsView.tsx `Sharing`, #808; docs/runner-api.md, "obid only:
/// sharing this Mac"): this Mac's spare time for the people in your Obysphere. Their jobs run here
/// in a sealed VM of their own, with their own AI accounts; off until you turn it on. "Share your
/// usage" and "Kept for you" come with #809.
struct SharingSettingsView: View {
    let feed: RunnerFeed
    @State private var sphere: SphereModel
    @State private var mac: RunnerSharingMac?
    @State private var problem: String?
    @State private var busy = false

    init(feed: RunnerFeed, mac: RunnerSharingMac? = nil) {
        self.feed = feed
        _sphere = State(initialValue: SphereModel(feed: feed))
        _mac = State(initialValue: mac)
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

    private func thisMac(_ mac: RunnerSharingMac) -> some View {
        let settings = mac.settings
        return SetGroup("This Mac", footer: settings.on ? Self.onFooter : Self.offFooter(team), problem: problem) {
            SetRow("Share this Mac with \(team)", about: mac.ready ? nil : "This Mac needs Oby’s VM before it can run anyone’s jobs.") {
                Toggle("Share this Mac with \(team)", isOn: Binding(get: { settings.on }, set: { on in turn(on) }))
                    .toggleStyle(.set)
                    .disabled(!mac.ready && !settings.on)
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
        SetGroup("On this Mac now", footer: Self.logFooter(team)) {
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

    /// "Claude Code on Sangam’s account · tetrix-ee · 12 min", and " · Paused" while its owner's back.
    static func about(_ guest: RunnerSharingMac.Guest, now: Date = .now) -> String {
        let agent = guest.agent == "codex" ? "Codex" : "Claude Code"
        let minutes = max(0, Int(now.timeIntervalSince(guest.started) / 60))
        let repo = guest.repo.split(separator: "/").last.map(String.init) ?? guest.repo
        let paused = guest.state == "paused" ? " · Paused" : ""
        return "\(agent) on \(RunnerMac.person(guest.fromOwner))’s account · \(repo) · \(minutes) min\(paused)"
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
            if sphere.name == nil { try? await sphere.refresh() }
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
