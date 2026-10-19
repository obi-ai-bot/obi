import AppKit
import ServiceManagement
import SwiftUI

/// A Settings page over Home (Sangam's SettingsView.tsx `SettingsPage`): its title over its groups of
/// cards, in a column as wide as a kind of work's, opened from the side panel's Settings list, the
/// account menu and ⌘,. Esc goes back, as from any page. The pages are made of Sangam's Settings
/// components (apps/shared/SettingsComponents.swift); the sections the iPhone shares draw as cards here.
struct SettingsPane: View {
    let model: IslandModel
    let page: SettingsPage
    @Environment(\.openSettingsPage) private var openSettings

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(page.label).font(Tokens.font(28, .semibold)).foregroundStyle(Tokens.ink)
                        .padding(.bottom, 16).accessibilityAddTraits(.isHeader)
                    content
                }
                .frame(maxWidth: Tokens.column, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Tokens.gutter).padding(.top, 16).padding(.bottom, 32)
            }
            // The setting another page sent you to, in sight once the page has drawn.
            .task(id: openSettings.spotlight) {
                guard let spotlight = openSettings.spotlight else { return }
                try? await Task.sleep(for: .milliseconds(200))
                withAnimation(Tokens.warm) { proxy.scrollTo(spotlight, anchor: .center) }
            }
        }
        .environment(\.settingsCards, true)
        .takesKeys()
    }

    @ViewBuilder private var content: some View {
        let feed = model.feed, store = model.desk.accounts
        switch page {
        case .general: GeneralSettingsView(desk: model.desk)
        case .runner: RunnerSettingsView(feed: feed, availability: model.availability, remote: model.remote)
        case .remote:
            if let remote = model.remote { RemoteAccessSettingsView(remote: remote) }
        case .accounts: AccountsSettingsView(store: store, feed: feed)
        case .models: ModelsSettingsView(store: store, feed: feed)
        case .connectors: ConnectorsSettingsView(store: store, feed: feed)
        case .vault: VaultSettingsView(vault: model.vault ?? .shared)
        case .about: AboutSettingsView(updater: model.updater)
        }
    }
}

/// Settings › General: what the iPhone's Settings has too (apps/shared/SettingsSections.swift),
/// opening at login, and how much this Mac's own jobs ask.
struct GeneralSettingsView: View {
    /// This Mac's desk: Settings › Permissions' default for the jobs it runs itself (#134). The
    /// runner's is in Settings › Runner.
    let desk: Desk
    @State private var mode = PermissionMode.bypass
    /// The rules Always allow (or a deny) saved on this Mac, read when Settings opens.
    @State private var rules: [PermissionRule] = []
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var problem: String?
    /// Oby reads its reply out loud when you talked to it (apps/mac/app/Speech.swift).
    @AppStorage(Speaker.setting) private var speaks = true

    var body: some View {
        SetGroup(problem: problem) {
            SetRow("Open at login") { Toggle("Open at login", isOn: $openAtLogin).toggleStyle(.set) }
        }
        .onAppear {
            mode = desk.defaultMode
            rules = desk.permissionRules
        }
        .onChange(of: openAtLogin) { _, on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                problem = nil
            } catch {
                problem = error.localizedDescription
                openAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
        SetGroup("Permissions on this Mac", footer: "How much the jobs this Mac runs itself ask. Each job’s Mode menu changes it while it runs. Always allow saves a rule, so it doesn’t ask again; remove the rule to be asked again. The runner’s jobs follow Runner › Permissions.") {
            SetRow("Default mode", about: RunnerMode(mode.rawValue)?.help) {
                SetSelect("Default mode", selection: $mode,
                          options: RunnerMode.local.map { (PermissionMode(rawValue: $0.rawValue) ?? .bypass, $0.label) })
            }
            if rules.isEmpty {
                SetRow("No saved rules", quiet: true)
            }
            ForEach(rules) { rule in
                SetRow(about: "\(rule.decision == .deny ? "Denied" : "Allowed") · \(rule.repo)") {
                    SetCode(rule.rule)
                } control: {
                    Button("Remove", role: .destructive) { forget(rule) }
                        .buttonStyle(.set)
                        .accessibilityLabel("Remove \(rule.rule)")
                }
            }
        }
        .onChange(of: mode) { _, chosen in if desk.defaultMode != chosen { desk.defaultMode = chosen } }
        VoiceSection(speaks: $speaks, footer: "When you talk to Oby with fn, it answers out loud and, after fn + Space, listens again for your answer until you press fn or say “stop”. Typed messages are answered in writing. Pressing fn stops it mid-sentence.")
        NotificationsSection()
    }

    private func forget(_ rule: PermissionRule) {
        do {
            try desk.forgetRule(rule.id)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        rules = desk.permissionRules
    }
}

/// Settings › Runner: the always-on runner and how this Mac reaches it, the checks this Mac runs
/// for it, and the Apple Watches paired with it.
struct RunnerSettingsView: View {
    let feed: RunnerFeed
    let availability: MacAvailability
    let remote: RemoteAccess?
    /// The always-on runner whose jobs the window lists and RunnerFeed follows; empty turns that off.
    @AppStorage("runnerURL") private var runnerURL = ""
    /// "This Mac" (#283): the runner is Oby's login item on this Mac, and Oby follows it on 127.0.0.1.
    @AppStorage(RunnerFeed.thisMacKey) private var onThisMac = false
    /// The login item, registered with "This Mac" and unregistered with a remote runner (apps/mac/app/LoginItem.swift).
    @State private var loginItem = RunnerLoginItem()
    /// Asking before install.sh's obid is moved into Oby.
    @State private var confirmingMove = false
    /// Merge checks on this Mac (apps/mac/app/MacChecks.swift).
    @AppStorage(MacChecks.setting) private var runMergeChecks = true
    /// Apple checks agents ask for (Engine/AppleChecks.swift).
    @AppStorage(MacChecks.appleSetting) private var runAppleChecks = true
    @State private var watches: [PairedWatch] = []
    @State private var watchProblem: String?

    var body: some View {
        // Sangam's words, but "the window" where his say "the island", which is gone.
        SetGroup("Runner", footer: onThisMac
                 ? (loginItem.byScript ? "Oby’s engine on this Mac was installed with install.sh. Move it into Oby and the app keeps it running and up to date, with the same settings, jobs and token."
                                       : "Oby’s engine is the app’s login item on this Mac, and Oby follows it on 127.0.0.1.")
                 : "Oby follows the runner at this address: the window lists its jobs.",
                 problem: onThisMac ? loginItem.problem : nil) {
            SetRow("Runner") {
                SetSegmented("Runner", selection: $onThisMac, options: [(true, "This Mac"), (false, "Remote")])
            }
            if onThisMac {
                SetRow("Login item") {
                    SetValue(loginItem.line)
                    if loginItem.needsApproval {
                        Button("Open Login Items Settings") { RunnerLoginItem.openSettings() }.buttonStyle(.set)
                    }
                    if loginItem.byScript {
                        Button("Move into Oby…") { confirmingMove = true }.buttonStyle(.set)
                    }
                }
            } else {
                SetRow("URL") { SetField("Runner URL", text: $runnerURL, prompt: "http://tetrix-lab:8790") }
            }
            SetRow("Status") {
                SetValue(feed.runner == nil && !feed.local ? "Off" : feed.connection == .live ? "Connected" : feed.connection.status(host: feed.name),
                         connected: feed.connection == .live)
            }
            if let cleanup = feed.cleanup {
                SetRow("Job worktrees") { SetValue(ByteCountFormatter.string(fromByteCount: cleanup.bytes, countStyle: .file)) }
                SetRow("Last cleanup") { SetValue(cleanup.lastRun.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never") }
            }
        }
        .onChange(of: onThisMac) { _, on in
            if on { loginItem.register() } else { loginItem.unregister() }
        }
        .confirmationDialog("Move Oby’s engine into the app?", isPresented: $confirmingMove) {
            Button("Move into Oby") { loginItem.moveFromScript() }
        } message: {
            Text("Oby stops the obid install.sh set up and starts the one inside the app, with the same configuration, jobs and token. Running jobs pick up where they were.")
        }
        SetGroup("This Mac", footer: "On power, Oby prevents idle sleep while This Mac is enabled and this setting is on. A running job always keeps this Mac awake.") {
            SetRow("Keep my Mac available") {
                Toggle("Keep my Mac available", isOn: Binding(get: { availability.keepAvailable }, set: availability.setKeepAvailable)).toggleStyle(.set)
            }
            SetRow("Availability") { SetValue(availability.label) }
        }
        // As on the iPhone (apps/shared/PermissionsSection.swift). This Mac's own jobs' default is in General.
        PermissionsSection(runner: feed.runner, defaultMode: feed.defaultMode, setDefault: feed.setDefaultMode)
        SetGroup("Checks on this Mac") {
            SetRow("Run merge checks on this Mac", about: "When Oby’s review approves a pull request, this Mac runs its tests and builds the Mac and iPhone apps, one at a time, before Oby merges it into dev.") {
                Toggle("Run merge checks on this Mac", isOn: $runMergeChecks).toggleStyle(.set)
            }
            SetRow("Build and test agents’ work on this Mac", about: "When an agent on the runner asks, this Mac builds and tests the Mac and iPhone apps at its latest commit, before Oby’s review has read it, and the agent gets the compiler’s errors and failing tests.") {
                Toggle("Build and test agents’ work on this Mac", isOn: $runAppleChecks).toggleStyle(.set)
            }
        }
        SetGroup("Apple Watch without iPhone", footer: "Away from your iPhone, a paired watch reaches the runner through your Cloudflare Tunnel. Pair one in Oby’s Settings on your iPhone, with Oby open on the watch: pairing asks for Face ID.",
                 problem: watchProblem) {
            if watches.isEmpty {
                SetRow("None yet", quiet: true)
            }
            ForEach(watches) { watch in
                SetRow(watch.name) {
                    SetValue("Paired")
                    Button("Remove", role: .destructive) { remove(watch) }.buttonStyle(.set)
                }
            }
        }
        SetGroup("Publishing", footer: "Oby opens a pull request by itself once a job’s check passes and the secret scan is clean. When that failed, publish by hand here or on your iPhone: this Mac’s key, like the iPhone’s, signs only after Touch ID. Oby merges only into dev, once its review approves and your Mac’s checks pass.") {
            SetRow("Publishing key") { SetValue(feed.runner == nil ? "Off" : feed.device.status) }
            // The runner's own line (pairing is closed: how to open it), then Try again.
            if feed.runner != nil, let problem = feed.device.problem {
                SetRow {
                    SetAbout(problem, color: Tokens.needs)
                } control: {
                    Button("Try again") { feed.register() }.buttonStyle(.set)
                }
            }
        }
        PairingView(feed: feed, remote: remote)
            .onAppear { loginItem.refresh() }
            // Back from approving the login item in System Settings.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in loginItem.refresh() }
            // Once the runner answers, and again after it comes back.
            .task(id: feed.connection) {
                guard feed.connection == .live, let runner = feed.runner else { return }
                // A runner older than the Watch API has no list: then there's nothing to show.
                watches = (try? await runner.watches()) ?? []
            }
    }

    private func remove(_ watch: PairedWatch) {
        guard let runner = feed.runner else { return }
        Task {
            do {
                try await runner.removeWatch(watch.id)
                watches.removeAll { $0.id == watch.id }
                watchProblem = nil
            } catch {
                watchProblem = error.localizedDescription
            }
        }
    }
}

/// Settings › Remote access: reach this Mac from anywhere (#285, apps/mac/app/RemoteAccess.swift). Sign in
/// to Oby's control plane with a code by email, then turn it on: this Mac gets a hostname of its
/// own and runs its tunnel. The iPhone connects to the hostname when it's away from home.
struct RemoteAccessSettingsView: View {
    let remote: RemoteAccess
    @Environment(\.openSettingsPage) private var openSettings
    @State private var email = ""
    @State private var code = ""
    @State private var forgetting = false

    private var signedIn: Bool { remote.step == .signedIn || remote.step == .on }
    /// Pair a device sent you here: the next thing to do is ringed (the email, the code, then the switch).
    private var pointed: Bool { openSettings.spotlight == .remoteAccess }

    var body: some View {
        SetGroup("Oby account", footer: "Remote access goes through Oby’s control plane, which signs you in with a code by email and gives this Mac a hostname of its own.",
                 problem: signedIn ? nil : remote.problem) {
            switch remote.step {
            case .signedOut:
                SetRow("Email") { SetField("Email", text: $email, prompt: "you@example.com").onSubmit(sendCode) }
                    .spotlit(pointed, id: .remoteAccess)
                SetRow("") {
                    Button("Send Code") { sendCode() }
                        .buttonStyle(.set)
                        .disabled(remote.busy || email.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            case .codeSent(let to):
                SetRow("Code", about: "A six-digit code went to \(to). It works for ten minutes.") {
                    SetField("Code", text: $code, prompt: "123456").onSubmit(verify)
                }
                .spotlit(pointed, id: .remoteAccess)
                SetRow("") {
                    Button("Use Another Email") { remote.useAnotherEmail() }
                        .buttonStyle(.set)
                        .disabled(remote.busy)
                    Button("Sign In") { verify() }
                        .buttonStyle(.set)
                        .disabled(remote.busy || code.trimmingCharacters(in: .whitespaces).count != 6)
                }
            case .signedIn, .on:
                SetRow("Signed in as") { SetValue(remote.email ?? "") }
            }
        }
        // On, and Pair a device sent you: straight back to it, its button ringed.
        .onChange(of: remote.step) { _, step in
            if step == .on, pointed { openSettings(.runner, spotlight: .pairDevice) }
        }
        .onDisappear { openSettings.clear(.remoteAccess) }
        if signedIn {
            SetGroup("Remote access", footer: "On, this Mac runs its Cloudflare Tunnel outbound, with no port to open: away from home, your iPhone reaches the gateway, and nothing else, at the hostname. Off keeps the hostname for next time. Forget removes this Mac from your account, and the hostname stops answering.",
                     problem: remote.problem) {
                SetRow("Reach this Mac from anywhere") {
                    Toggle("Reach this Mac from anywhere", isOn: Binding(get: { remote.step == .on }, set: { on in
                        if on { Task { await remote.turnOn() } } else { remote.turnOff() }
                    }))
                    .toggleStyle(.set)
                    .disabled(remote.busy)
                }
                .spotlit(pointed && remote.step != .on, id: .remoteAccess)
                if let hostname = remote.hostname {
                    SetRow("Hostname") { SetValue(hostname) }
                }
                SetRow("Status") {
                    let status = remote.busy ? "Setting up…" : remote.status
                    SetValue(status, connected: status == "Connected")
                }
                SetRow("") {
                    Button("Forget This Mac", role: .destructive) { forgetting = true }
                        .buttonStyle(.set)
                        .disabled(remote.busy)
                }
            }
            // Kept beyond Sangam's mock: the hostname can't be brought back, so macOS's confirmation first.
            .confirmationDialog("Forget this Mac?", isPresented: $forgetting) {
                Button("Forget", role: .destructive) { Task { await remote.forget() } }
            } message: {
                Text("Its tunnel and hostname are removed from your Oby account, and this Mac signs out. Turning remote access on again makes a new hostname.")
            }
        }
    }

    private func sendCode() {
        Task { await remote.requestCode(email) }
    }

    private func verify() {
        Task {
            await remote.verify(code)
            if remote.step == .signedIn { code = "" }
        }
    }
}

/// Sangam's look for the reserve switch (apps/shared/Usage.swift's `ReserveSwitch`): the switch and its
/// words as a line under the account's meter, then what it does, and what went wrong.
private struct ReserveLine: View {
    let snapshot: Usage.Snapshot
    let on: Bool
    var lift: @MainActor @Sendable (Bool) async throws -> Void
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Toggle(Usage.liftText, isOn: Binding(get: { on }, set: { on in
                    Task {
                        problem = nil
                        do { try await lift(on) } catch { problem = error.localizedDescription }
                    }
                }))
                .toggleStyle(.set)
                Text(Usage.liftText).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.text)
            }
            .padding(.top, 4)
            SetAbout(Usage.liftNote(snapshot))
            if let problem { SetAbout(problem, color: Tokens.danger) }
        }
    }
}

/// Where Settings › Accounts lists accounts from (docs/mac-design.md C1), as one list: with obid on
/// this Mac (Settings › Runner › This Mac) only obid's, which it plans and runs every job on; with a
/// remote runner this Mac's own and the runner's; with none, this Mac's.
nonisolated enum AccountPlaces: Equatable, Sendable {
    case mac, runner

    static func of(local: Bool, runner: Bool) -> [AccountPlaces] {
        local ? [.runner] : runner ? [.mac, .runner] : [.mac]
    }
}

/// Settings › Accounts: the logins Oby spreads jobs across, who pays for each, and how much of its week
/// each has used, as Sangam's usage rows, from where jobs run (`AccountPlaces`).
struct AccountsSettingsView: View {
    let store: AccountStore
    let feed: RunnerFeed
    @State private var agent = "claude"
    @State private var name = ""
    @State private var payer = ""
    @State private var removing: Account?
    @State private var problem: String?

    private var places: [AccountPlaces] { AccountPlaces.of(local: feed.local, runner: feed.runner != nil) }

    var body: some View {
        let both = places.count > 1
        if places.contains(.mac) {
            AccountSections("Accounts on this Mac", items: store.accounts, id: \.account.id, usage: \.usage,
                            place: both ? "on this Mac" : nil) { state in
                AccountUsageRow(state: state, payer: state.account.payer) { lift in _ = store.liftReserve(state.account.id, lift) } buttons: {
                    if !state.signedIn {
                        Button("Sign In") { attempt { try store.signIn(state.account) } }.buttonStyle(.set)
                    } else if state.tetrix == false {
                        Button("Sign In to Tetrix") { attempt { try store.signIn(state.account, tetrix: true) } }.buttonStyle(.set)
                    }
                    Button("Remove", role: .destructive) { removing = state.account }.buttonStyle(.set)
                }
            }
            addAccount
        }
        if places.contains(.runner) {
            // obid's own accounts, signed in on it through each tool's own login. Adding, signing in and
            // removing them come with obid's accounts API (docs/mac-design.md A2, A3): their buttons go
            // in this row's `buttons`, and the add form after this list.
            AccountSections(feed.local ? "Accounts on this Mac" : "Accounts on \(feed.name)", items: feed.accounts, id: \.account.id,
                            usage: \.usage, place: both ? "on \(feed.name)" : nil) { state in
                AccountUsageRow(state: state) { lift in
                    // The runner's "accounts" event brings the change back.
                    guard let runner = feed.runner else { throw RunnerError(message: "Set the runner's URL in Settings first.") }
                    _ = try await runner.liftReserve(state.account.id, lift)
                } buttons: {}
            }
        }
    }

    /// Adds to this Mac's own accounts, which only Oby on this Mac uses.
    private var addAccount: some View {
        SetGroup("Add an account", problem: problem) {
            SetRow("Tool", about: agent == "cursor" && !CursorFacts.separateLogins ? "\(CursorFacts.oneLogin): one Cursor account." : nil) {
                SetSelect("Tool", selection: $agent, options: [("claude", "Claude Code"), ("codex", "Codex"), ("cursor", "Cursor")])
            }
            SetRow("Name") { SetField("Account name", text: $name, prompt: "Personal") }
            SetRow("Paid by") { SetField("Paid by", text: $payer, prompt: "Wellington") }
            SetRow("") {
                Button("Add Account") {
                    attempt {
                        try store.add(agent: agent, name: name.trimmingCharacters(in: .whitespaces), payer: payer.trimmingCharacters(in: .whitespaces))
                        name = ""
                        payer = ""
                    }
                }
                .buttonStyle(.set)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task { await store.refresh() }
        // Kept beyond Sangam's mock: removing deletes the account's settings folder and its login, so
        // macOS's confirmation first.
        .confirmationDialog("Remove \(removing?.name ?? "this account")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { account in
            Button("Remove", role: .destructive) { attempt { try store.remove(account) } }
        } message: { account in
            Text(account.home == nil ? "Its login stays in the tool's own settings." : "Oby deletes this account's settings folder, with its login. This can’t be undone.")
        }
        // Back from signing in, in Terminal.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refresh() }
        }
    }

    private func attempt(_ action: () throws -> Void) {
        do {
            try action()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// One account as Sangam's usage row (`.set-usage`, docs/mac-design.md B2): its tool's mark, its name,
/// who pays and when its week resets, a meter of its week; the 5-hour window past 80%, its reserve,
/// "Full until" and Tetrix as lines under it; "N% used" and its buttons at the top right.
struct AccountUsageRow<Buttons: View>: View {
    let state: AccountState
    /// Who pays for it: this Mac's accounts know; obid's don't say yet.
    var payer = ""
    var lift: @MainActor @Sendable (Bool) async throws -> Void
    @ViewBuilder var buttons: Buttons

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let usage = state.usage, now = context.date
            SetRow(controlOnTop: true) {
                HStack(alignment: .top, spacing: 16) {
                    AgentMark(agent: state.account.agent).font(Tokens.font(13)).foregroundStyle(Tokens.muted)
                        .frame(width: 16).padding(.top, 2).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.account.name)
                        SetAbout(Usage.about(usage, payer: payer, now: now))
                        if let week = Usage.week(usage, now: now) {
                            SetMeter(used: week * 100).padding(.top, 4)
                        }
                        if let line = Usage.fiveHourLine(usage, now: now) {
                            SetAbout(line, color: SetMeter.fill(used: (usage.fiveHour ?? 0) * 100))
                        }
                        if usage.reserved(at: now) {
                            SetAbout(Usage.reservedText, color: Tokens.needs)
                        } else if usage.inReserve(at: now), let until = usage.liftedUntil(at: now) {
                            SetAbout(Usage.liftedText(until))
                        }
                        if usage.signedIn, usage.inReserve(at: now) {
                            ReserveLine(snapshot: usage, on: usage.liftedUntil(at: now) != nil) { try await lift($0) }
                        }
                        // A job of its hit the limit: no job goes to it until then.
                        if state.isFull(at: now), let until = state.fullUntil {
                            SetAbout("Full until \(Limits.clock(until))", color: Tokens.needs)
                        }
                        if state.signedIn {
                            SetAbout(Usage.tetrix(state.tetrix, jobs: state.tetrixJobs, used: state.tetrixUsed),
                                     color: state.tetrix == false ? Tokens.needs : Tokens.muted)
                        }
                    }
                }
            } control: {
                if let used = Usage.usedText(usage, now: now) { SetValue(used) }
                buttons
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Usage.spoken(usage, now: now))
        }
    }
}

/// Settings › Connectors (#498): everything Oby is connected to, on this Mac and on the runner,
/// each with how it's signed in and how to disconnect it, then what needs attention, what isn't
/// confirmed and what's set up but not connected, with a search over all of it
/// (apps/mac/app/Connectors.swift).
struct ConnectorsSettingsView: View {
    let store: AccountStore
    let feed: RunnerFeed
    @State private var query = ""
    /// What the runner lists besides its status, once it answers, and each list it couldn't read.
    @State private var lists = Connectors.Lists()
    @State private var confirming: Connector?
    /// The plug-in whose Connect asks for Tetrix's MCP URL, and the URL typed.
    @State private var asking: String?
    @State private var url = ""
    @State private var busy = false
    /// What went wrong with a row's button, by the row's id, shown under that row.
    @State private var problems: [String: String] = [:]
    /// gh's sign-in under way on the runner, shown in its sheet until it signs in or is cancelled.
    @State private var gitHubSignIn: GitHubSignIn?

    var body: some View {
        let groups = Connectors.groups(list, query: query)
        VStack(alignment: .leading, spacing: 8) {
            SearchField(text: $query, prompt: "Search connectors")
            // The runner's rows are left out while it doesn't answer: they'd be out of date.
            if feed.runner != nil, let note = Connectors.waiting(for: feed.name, feed.connection) {
                SetAbout(note, color: Tokens.needs).padding(.horizontal, 16)
            }
            ForEach(lists.problems, id: \.self) { problem in
                SetAbout(problem, color: Tokens.danger).padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 24)
        ForEach(groups, id: \.title) { group in
            SetGroup(group.title) { ForEach(group.items, content: row) }
        }
        if groups.isEmpty {
            let typed = query.trimmingCharacters(in: .whitespaces)
            Text(typed.isEmpty ? "Nothing is set up yet." : "No connector matches “\(typed)”")
                .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted).padding(.horizontal, 16).padding(.bottom, 24)
        }
        SetAbout("Each tool and Tetrix sign in through their own login: Oby never reads or shows it. Agents reach the runner's connections through Oby, never seeing their secrets.")
            .padding(.horizontal, 16)
        .task { await store.refresh() }
        // Back from signing in or out, in Terminal.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refresh() }
        }
        // Once the runner answers, and again after it comes back or Settings › Runner changes it.
        .task(id: feed.connection) { await load() }
        .confirmationDialog("Disconnect \(confirming?.name ?? "it")?",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { connector in
            Button("Disconnect", role: .destructive) { disconnect(connector) }
        } message: { connector in
            Text(warning(connector))
        }
        .sheet(item: Binding(get: { gitHubSignIn.map(IdentifiedSignIn.init) }, set: { gitHubSignIn = $0?.signIn })) { shown in
            GitHubSignInSheet(signIn: shown.signIn, place: feed.name) {
                gitHubSignIn = nil
                Task { try? await feed.runner?.endGitHubSignIn() }
            }
            .task { await waitForGitHub() }
        }
        .alert("Connect Tetrix", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            TextField("MCP URL", text: $url, prompt: Text("https://"))
            Button("Connect") {
                if let id = asking { setPlugin(id, enabled: true, config: ["url": typedURL], row: "plugin-\(id)") }
            }
            .disabled(!Connectors.isURL(typedURL))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Tetrix MCP server's address, starting with https://. Agents get its tools on \(feed.name); its login stays Tetrix's own.")
        }
    }

    /// This Mac's accounts, and what the runner said about itself while it answers.
    private var list: [Connector] {
        let runner = feed.runner == nil || feed.connection != .live ? nil : Connectors.RunnerState(
            name: feed.name, local: feed.local, accounts: feed.accounts, github: feed.github, checks: feed.checkRuns,
            gitHubLogin: lists.gitHub, plugins: lists.plugins, connections: lists.connections)
        return Connectors.list(mac: store.accounts, runner: runner)
    }

    private var typedURL: String { url.trimmingCharacters(in: .whitespaces) }

    /// Sangam's connector row: its mark, its name with what it does and where, how it's signed in;
    /// at the right whether it's connected and its button.
    private func row(_ connector: Connector) -> some View {
        SetRow(controlOnTop: true) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: connector.symbol)
                    .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted)
                    .frame(width: 20)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(connector.name)
                    SetAbout("\(connector.about) · \(connector.place)")
                    SetAbout(connector.how, color: connector.state == .broken ? Tokens.needs : Tokens.muted)
                    if case .steps(let steps) = connector.way {
                        SetAbout(steps)
                    }
                    if let problem = problems[connector.id] {
                        SetAbout(problem, color: Tokens.danger)
                    }
                }
            }
        } control: {
            switch connector.state {
            case .connected:
                Label("Connected", systemImage: "checkmark").font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.text)
            case .broken:
                Label("Not working", systemImage: "exclamationmark.triangle").font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.needs)
            case .unconfirmed:
                SetValue("Not confirmed")
            case .available: EmptyView()
            }
            if case .button(let label, let action) = connector.way {
                Button(label) { perform(action, connector) }
                    .buttonStyle(.set)
                    .disabled(busy)
                    .accessibilityLabel("\(label.replacingOccurrences(of: "…", with: "")) \(connector.name), \(connector.place)")
            }
        }
    }

    /// What the runner lists besides its status: obid's plug-ins, the Swift runner's connections.
    /// A list it couldn't read says why; only a 404 means it has none.
    private func load() async {
        guard feed.connection == .live, let runner = feed.runner else {
            lists = Connectors.Lists()
            return
        }
        lists = await Connectors.lists(from: runner, name: feed.name)
    }

    /// A button: what takes something away asks first; signing in or out opens Terminal.
    private func perform(_ action: Connector.Action, _ connector: Connector) {
        switch action {
        case .removeAccount, .disablePlugin, .disconnect: confirming = connector
        case .signIn(let account): attempt(connector.id) { try store.signIn(account) }
        case .signInTetrix(let account): attempt(connector.id) { try store.signIn(account, tetrix: true) }
        case .signOutTetrix(let account): attempt(connector.id) { try store.signOutOfTetrix(account) }
        case .signInGitHub: signInToGitHub(row: connector.id)
        case .enablePlugin(let id, let needsURL):
            if needsURL {
                url = ""
                asking = id
            } else {
                setPlugin(id, enabled: true, row: connector.id)
            }
        }
    }

    private func disconnect(_ connector: Connector) {
        guard case .button(_, let action) = connector.way else { return }
        switch action {
        case .removeAccount(let account): attempt(connector.id) { try store.remove(account) }
        case .disablePlugin(let id): setPlugin(id, enabled: false, row: connector.id)
        case .disconnect(let name):
            guard let runner = feed.runner else { return }
            Task {
                busy = true
                defer { busy = false }
                do {
                    try await feed.device.disconnect(name, with: runner)
                    problems[connector.id] = nil
                } catch {
                    problems[connector.id] = error.localizedDescription
                }
                lists = await Connectors.lists(from: runner, name: feed.name)
            }
        default: break
        }
    }

    /// What disconnecting does, said before it's done.
    private func warning(_ connector: Connector) -> String {
        guard case .button(_, let action) = connector.way else { return "" }
        switch action {
        case .removeAccount(let account):
            return account.home == nil ? "Oby stops using it. Its login stays in \(Usage.tool(account.agent))'s own settings."
                                       : "Oby removes this account and deletes its settings folder, with its login."
        case .disablePlugin:
            return "\(feed.name) stops it and everything it started, and agents no longer get its tools."
        case .disconnect:
            return "After Touch ID, \(feed.name) forgets it and its agents can't reach it any more. Its secret stays in the runner's vault."
        default:
            return ""
        }
    }

    /// Turns a plug-in on or off on the runner, then shows what it answered on its row.
    private func setPlugin(_ id: String, enabled: Bool, config: [String: String]? = nil, row: String) {
        guard let runner = feed.runner else { return }
        Task {
            busy = true
            defer { busy = false }
            do {
                let plugin = try await runner.setPlugin(id, enabled: enabled, config: config)
                lists.plugins = lists.plugins?.map { $0.id == plugin.id ? plugin : $0 }
                problems[row] = nil
            } catch {
                problems[row] = error.localizedDescription
            }
        }
    }

    /// gh's own sign-in on the runner: GitHub's device page opens in the browser with its code on
    /// the clipboard, and the sheet waits for GitHub. Oby never sees the login.
    private func signInToGitHub(row: String) {
        guard let runner = feed.runner else { return }
        Task {
            busy = true
            defer { busy = false }
            do {
                let signIn = try await runner.startGitHubSignIn()
                guard signIn.isGitHubs else {
                    problems[row] = "\(feed.name) answered with something other than GitHub's sign-in page and code, so Oby opened nothing."
                    try? await runner.endGitHubSignIn()
                    return
                }
                problems[row] = nil
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(signIn.userCode, forType: .string)
                gitHubSignIn = signIn
                NSWorkspace.shared.open(GitHubSignIn.devicePage)
            } catch {
                problems[row] = error.localizedDescription
            }
        }
    }

    /// While the sheet is up: asks every 2 seconds whether gh is signed in, and closes it once it is.
    private func waitForGitHub() async {
        while gitHubSignIn != nil, !Task.isCancelled, let runner = feed.runner {
            try? await Task.sleep(for: .seconds(2))
            guard let login = try? await runner.gitHubLogin() else { continue }
            if login.signedIn || login.signIn == nil {
                lists.gitHub = login
                if !login.signedIn { problems["github"] = "GitHub's sign-in ended without signing in." }
                gitHubSignIn = nil
            }
        }
    }

    /// Runs a row's button, keeping what went wrong under that row.
    private func attempt(_ row: String, _ action: () throws -> Void) {
        do {
            try action()
            problems[row] = nil
        } catch {
            problems[row] = error.localizedDescription
        }
    }
}

/// A GitHub sign-in as a sheet's item.
private struct IdentifiedSignIn: Identifiable {
    var signIn: GitHubSignIn
    var id: String { signIn.userCode }
}

/// gh's sign-in, waiting for the person on GitHub's page (docs/onboarding.md, Mac 5): the code to
/// type there, already on the clipboard; the page again; Cancel.
private struct GitHubSignInSheet: View {
    let signIn: GitHubSignIn
    let place: String
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Sign in to GitHub").font(Tokens.font(17, .semibold)).foregroundStyle(Tokens.ink)
            Text("GitHub's page opened in your browser. Type this code there; it's on your clipboard.")
                .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.text).multilineTextAlignment(.center)
            Text(signIn.userCode).font(Tokens.mono(30)).foregroundStyle(Tokens.ink).textSelection(.enabled)
                .accessibilityLabel("Code \(signIn.userCode.map(String.init).joined(separator: " "))")
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for GitHub").font(Tokens.font(13)).foregroundStyle(Tokens.muted)
            }
            HStack(spacing: 8) {
                Button("Cancel", action: cancel).buttonStyle(.set).keyboardShortcut(.cancelAction)
                Button("Open the Page Again") { NSWorkspace.shared.open(GitHubSignIn.devicePage) }.buttonStyle(.set)
            }
            .padding(.top, 6)
            Text("GitHub's CLI on \(place == Connectors.thisMac ? "this Mac" : place) keeps the login. Oby only learns that it worked.")
                .font(Tokens.font(12)).foregroundStyle(Tokens.muted).multilineTextAlignment(.center)
        }
        .padding(26)
        .frame(width: 400)
        .background(Tokens.surface)
    }
}

/// A search over a page's rows (Sangam's `.archive-search`): 40 tall, 12 round, a 1-point line that
/// lights up hovered or focused, the magnifier muted.
struct SearchField: View {
    @Binding var text: String
    var prompt: String
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted).accessibilityHidden(true)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(Tokens.muted))
                .textFieldStyle(.plain).labelsHidden()
                .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.ink)
                .focused($focused)
        }
        .padding(.horizontal, 14).frame(height: 40)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering || focused ? Tokens.fieldEdgeOn : Tokens.line))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Tokens.fade, value: hovering || focused)
    }
}

/// Settings › Vault: the secrets Oby keeps in the keychain, by name. Never their values: a value
/// is typed once, into a secure field that empties when it's saved.
struct VaultSettingsView: View {
    let vault: Vault
    @State private var names: [String] = []
    @State private var name = ""
    @State private var value = ""
    @State private var removing: String?
    @State private var problem: String?

    var body: some View {
        SetGroup("Secrets") {
            if names.isEmpty {
                SetRow("No secrets yet", quiet: true)
            }
            ForEach(names, id: \.self) { name in
                SetRow {
                    SetCode(name)
                } control: {
                    Button("Remove", role: .destructive) { removing = name }
                        .buttonStyle(.set)
                        .accessibilityLabel("Remove \(name)")
                }
            }
        }
        .onAppear { attempt {} }
        // Kept beyond Sangam's mock: a secret can't be brought back, so macOS's confirmation first.
        .confirmationDialog("Remove “\(removing ?? "this secret")”?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { name in
            Button("Remove", role: .destructive) { attempt { try vault.remove(name) } }
        } message: { _ in
            Text("Oby deletes it from the keychain. This can’t be undone.")
        }
        SetGroup("Add a secret", footer: "Oby uses a secret only in its own calls, for a connection you made. No agent sees it, and the secret scan stops anything outgoing that holds it, plain or encoded.",
                 problem: problem) {
            SetRow("Name") { SetField("Secret name", text: $name, prompt: "staging-api-key") }
            SetRow("Value") { SetField("Secret value", text: $value, prompt: "Typed once, never shown again", secret: true) }
            SetRow("") {
                Button("Add Secret") {
                    attempt {
                        try vault.add(value, as: name.trimmingCharacters(in: .whitespaces))
                        name = ""
                        value = ""
                    }
                }
                .buttonStyle(.set)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || value.isEmpty)
            }
        }
    }

    /// Runs `action`, then lists the names again.
    private func attempt(_ action: () throws -> Void) {
        do {
            try action()
            names = try vault.names()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Settings › Models: which model and effort Claude Code and Codex jobs use, on this Mac and on the
/// runner (as the iPhone sets them, apps/shared/SettingsSections.swift).
struct ModelsSettingsView: View {
    let store: AccountStore
    let feed: RunnerFeed
    @AppStorage("claude.model") private var claudeModel = AgentModels.defaults["claude.model"] ?? ""
    @AppStorage("claude.effort") private var claudeEffort = AgentModels.defaults["claude.effort"] ?? ""
    @AppStorage("claude.complexEffort") private var claudeComplexEffort = AgentModels.defaults["claude.complexEffort"] ?? ""
    @AppStorage("codex.model") private var codexModel = AgentModels.defaults["codex.model"] ?? ""
    @AppStorage("codex.effort") private var codexEffort = AgentModels.defaults["codex.effort"] ?? ""
    @AppStorage("codex.complexEffort") private var codexComplexEffort = AgentModels.defaults["codex.complexEffort"] ?? ""
    @AppStorage("cursor.model") private var cursorModel = AgentModels.defaults["cursor.model"] ?? "auto"
    /// What the signed-in Codex account offers, from its own model list.
    @State private var codexModels: [CodexModel] = []
    /// What the signed-in Cursor account offers (`cursor-agent models`); Cursor has no effort.
    @State private var cursorModels: [CursorModel] = []
    /// What the runner offers, once it has answered.
    @State private var runnerOptions: ModelOptions?
    /// Whether the runner serves its models: obid doesn't yet (no `/v1/settings/models` routes), and
    /// then the page is this Mac's own models, as before.
    @State private var runnerServesModels = true
    @State private var problem: String?

    var body: some View {
        // With obid on this Mac it runs every job: its models are the only ones (docs/mac-design.md C2).
        if feed.local && runnerServesModels {
            // In a stack that's always there: the sections are empty until the options arrive, and a
            // task on an empty view never runs.
            VStack(alignment: .leading, spacing: 0) {
                if runnerOptions == nil || feed.models == nil {
                    SetGroup(problem: problem) { SetRow("Waiting for the runner on this Mac…", quiet: true) }
                } else {
                    RunnerModelsSections(options: runnerOptions, models: feed.models, save: feed.setModels, place: "on this Mac",
                                         footer: "New jobs on this Mac use these. Oby’s brain stays on Haiku: it plans and answers in the conversation, so it should be quick.")
                }
            }
            .task(id: feed.connection) { await loadOptions() }
        } else {
            mine
            if feed.runner != nil {
                RunnerModelsSections(options: runnerOptions, models: feed.models, save: feed.setModels, place: "on \(feed.name)")
            }
        }
    }

    /// This Mac's own models, for the jobs its desk runs.
    @ViewBuilder private var mine: some View {
        let efforts = AgentModels.claudeEfforts.map { ($0, AgentModels.effortName($0)) }
        SetGroup("Claude Code on this Mac") {
            SetRow("Model") { SetSelect("Claude Code model", selection: $claudeModel, options: AgentModels.claude) }
            SetRow("Effort") { SetSelect("Claude Code effort", selection: $claudeEffort, options: efforts) }
            SetRow("Complex job effort") { SetSelect("Claude Code complex job effort", selection: $claudeComplexEffort, options: efforts) }
        }
        SetGroup("Codex on this Mac") {
            SetRow("Model") { SetSelect("Codex model", selection: $codexModel, options: codexChoices.map { ($0.id, $0.name) }) }
            SetRow("Effort") { SetSelect("Codex effort", selection: $codexEffort, options: codexEfforts.map { ($0, AgentModels.effortName($0)) }) }
            SetRow("Complex job effort") {
                SetSelect("Codex complex job effort", selection: $codexComplexEffort, options: codexEfforts.map { ($0, AgentModels.effortName($0)) })
            }
        }
        SetGroup("Cursor on this Mac", footer: "New jobs on this Mac use these. Oby’s brain stays on Haiku: it plans and answers in the conversation, so it should be quick.",
                 problem: problem) {
            SetRow("Model") { SetSelect("Cursor model", selection: $cursorModel, options: cursorChoices.map { ($0.id, $0.name) }) }
        }
        .task { codexModels = (try? await CodexAgent.models(home: nil)) ?? [] }
        .task {
            // Jobs run on Oby's own Cursor account: its model list, when one is signed in.
            guard let account = store.accounts.first(where: { $0.account.agent == "cursor" && $0.signedIn }) else { return }
            cursorModels = await CursorModels.list(home: account.account.home)
        }
        // Once the runner answers, and again after it comes back or its URL changes.
        .task(id: feed.connection) { await loadOptions() }
    }

    /// What the runner offers, once it answers.
    private func loadOptions() async {
        #if DEBUG
        if let staged = feed.stagedOptions { runnerOptions = staged; return }
        #endif
        guard feed.connection == .live, let runner = feed.runner else { return }
        do {
            runnerOptions = try await runner.modelOptions()
            problem = nil
        } catch {
            runnerServesModels = Self.servesModels(after: error)
            problem = runnerServesModels ? error.localizedDescription : nil
        }
    }

    /// A 404 says the runner has no models to set (obid today): nothing wrong to show.
    nonisolated static func servesModels(after error: any Error) -> Bool {
        (error as? RunnerError)?.status != 404
    }

    /// The account's models, plus the chosen one while the list loads (or if the plan dropped it).
    private var codexChoices: [CodexModel] {
        codexModels.contains { $0.id == codexModel } ? codexModels
            : [CodexModel(id: codexModel, name: codexModel, efforts: AgentModels.claudeEfforts)] + codexModels
    }

    /// Cursor's models, with Auto first (Cursor picks) and the chosen one while the list loads.
    private var cursorChoices: [CursorModel] {
        var choices = [CursorModel(id: "auto", name: "Auto")] + cursorModels.filter { $0.id != "auto" }
        if !choices.contains(where: { $0.id == cursorModel }) { choices.append(CursorModel(id: cursorModel, name: cursorModel)) }
        return choices
    }

    private var codexEfforts: [String] {
        let efforts = codexChoices.first { $0.id == codexModel }?.efforts ?? []
        return efforts.contains(codexEffort) ? efforts : [codexEffort] + efforts
    }
}

extension AccountState {
    /// What Settings' usage card shows.
    var usage: Usage.Snapshot {
        Usage.Snapshot(agent: account.agent, name: account.name, label: label, fiveHour: fiveHour, sevenDay: sevenDay,
                       fiveHourResets: fiveHourResets, sevenDayResets: sevenDayResets, running: running,
                       reserveLiftedUntil: reserveLifted, runnerSignedIn: runnerSignedIn)
    }
}

extension AccountStore {
    /// Opens Terminal on the tool's own login, with the account's home in the environment; with
    /// `tetrix`, on the tool's own login to its Tetrix MCP server (Engine/TetrixUse.swift).
    func signIn(_ account: Account, tetrix: Bool = false) throws {
        let script = URL(filePath: account.home ?? homes.path).appending(path: "sign-in-\(tetrix ? "tetrix-" : "")\(account.id).command")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (tetrix ? TetrixUse.signInScript(for: account) : Self.signInScript(for: account)).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        guard NSWorkspace.shared.open(script) else { throw Shell.Failure(message: "Couldn't open Terminal to sign in.") }
    }

    /// Opens Terminal on the tool's own sign-out from its Tetrix MCP server, with the account's
    /// home in the environment (`Connectors.tetrixSignOutScript`).
    func signOutOfTetrix(_ account: Account) throws {
        let script = URL(filePath: account.home ?? homes.path).appending(path: "sign-out-tetrix-\(account.id).command")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let text = Connectors.tetrixSignOutScript(for: account) else {
            throw Shell.Failure(message: "Oby can't sign \(Usage.tool(account.agent)) out of Tetrix.")
        }
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        guard NSWorkspace.shared.open(script) else { throw Shell.Failure(message: "Couldn't open Terminal to sign out.") }
    }
}

extension View {
    /// The setting another Settings page sent you to (`SettingsSpotlight`): a blue ring (the new dot's blue) that
    /// breathes, still with Reduce Motion, and the id the page scrolls to.
    func spotlit(_ on: Bool, id: SettingsSpotlight) -> some View {
        modifier(Spotlit(on: on)).id(id)
    }
}

private struct Spotlit: ViewModifier {
    let on: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if on {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Tokens.unread, lineWidth: 2)
                        .opacity(reduceMotion || bright ? 1 : 0.35)
                        .padding(2)
                        .allowsHitTesting(false)
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { bright = true }
                        }
                        .onDisappear { bright = false }
                        .transition(.opacity)
                }
            }
            .animation(Tokens.warm, value: on)
    }
}
