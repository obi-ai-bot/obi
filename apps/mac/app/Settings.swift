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
        case .sharing: SharingSettingsView(feed: feed)
        case .remote:
            if let remote = model.remote { RemoteAccessSettingsView(remote: remote) }
        case .accounts: AccountsSettingsView(store: store, feed: feed)
        case .models: ModelsSettingsView(store: store, feed: feed)
        case .connectors: ConnectorsSettingsView(store: store, feed: feed, remote: model.remote)
        case .memory: MemorySettingsView(runner: feed.runner)
        case .sphere: SphereSettingsView(feed: feed)
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
        VoiceSection(footer: "When you talk to Oby with fn, your words show as you speak and Oby answers in writing. After fn + Space, it listens again for your answer once its reply shows, until you press fn or say “stop”.")
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
    /// The launch build (`Launch`) hides a remote runner and Apple Watch without iPhone.
    @AppStorage(Launch.everythingKey) private var everything = false

    /// This Mac or a remote runner, and its URL: in the launch build, only on a Mac that already
    /// has a remote runner's address, so it can come back to This Mac. Otherwise one This Mac switch.
    private var choosesRemote: Bool { everything || !runnerURL.isEmpty }

    var body: some View {
        // Sangam's words, but "the window" where his say "the island", which is gone.
        SetGroup("Runner", footer: onThisMac
                 ? (loginItem.byScript ? "Oby’s engine on this Mac was installed with install.sh. Move it into Oby and the app keeps it running and up to date, with the same settings, jobs and token."
                                       : "Oby’s engine is the app’s login item on this Mac, and Oby follows it on 127.0.0.1.")
                 : choosesRemote ? "Oby follows the runner at this address: the window lists its jobs."
                                 : "Turn on This Mac and Oby’s engine runs here, as the app’s login item.",
                 problem: onThisMac ? loginItem.problem : nil) {
            if choosesRemote {
                SetRow("Runner") {
                    SetSegmented("Runner", selection: $onThisMac, options: [(true, "This Mac"), (false, "Remote")])
                }
            } else {
                SetRow("This Mac") { Toggle("This Mac", isOn: $onThisMac).toggleStyle(.set) }
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
            } else if choosesRemote {
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
        RoutinesSection(runner: feed.runner, changes: feed.routineChanges)
        SetGroup("Checks on this Mac") {
            SetRow("Run merge checks on this Mac", about: "When Oby’s review approves a pull request, this Mac runs its tests and builds the Mac and iPhone apps, one at a time, before Oby merges it into dev.") {
                Toggle("Run merge checks on this Mac", isOn: $runMergeChecks).toggleStyle(.set)
            }
            SetRow("Build and test agents’ work on this Mac", about: "When an agent on the runner asks, this Mac builds and tests the Mac and iPhone apps at its latest commit, before Oby’s review has read it, and the agent gets the compiler’s errors and failing tests.") {
                Toggle("Build and test agents’ work on this Mac", isOn: $runAppleChecks).toggleStyle(.set)
            }
        }
        if everything {
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
                guard everything, feed.connection == .live, let runner = feed.runner else { return }
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

/// Settings › Remote access (#285, apps/mac/app/RemoteAccess.swift), as Sangam's Remote page: the
/// Oby account first, then the switch, the hostname, the status and Forget. Signed out, the account's
/// card holds the sign-in buttons, in each provider's own colours (beyond his mock, which signs in
/// by email), only those the control plane takes; signing in turns remote access on.
struct RemoteAccessSettingsView: View {
    let remote: RemoteAccess
    @Environment(\.openSettingsPage) private var openSettings
    @State private var forgetting = false
    /// The button pressed, which shows it's working until the sign-in ends.
    @State private var signingIn: ControlPlane.Provider?

    /// Pair a device sent you here: the switch, or the sign-in, is ringed.
    private var pointed: Bool { openSettings.spotlight == .remoteAccess }

    private var accountFooter: String {
        let who = remote.workspaces.isEmpty ? "" : " For \(remote.workspaces.joined(separator: ", ")) accounts."
        return "Sign in to give this Mac an address of its own." + who
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if remote.signsInFirst {
                SetGroup("Oby account", footer: accountFooter, problem: remote.problem) {
                    VStack(spacing: 10) {
                        ForEach(remote.providers, id: \.self) { provider in
                            Button { signIn(with: provider) } label: {
                                SignInLabel(provider: provider, working: signingIn == provider)
                            }
                            .buttonStyle(SignInButtonStyle(provider: provider))
                            .disabled(remote.busy)
                        }
                    }
                    .padding(16)
                    .spotlit(pointed, id: .remoteAccess)
                }
            } else {
                SetGroup("Oby account") {
                    SetRow("Signed in with") { SetValue(remote.accountName ?? "Your Oby account") }
                }
            }
            SetGroup("Remote access", footer: "Your iPhone reaches this Mac away from home, with no port to open.",
                     problem: remote.signsInFirst ? nil : remote.problem) {
                // Ringed when Pair a device sent you, unless the sign-in above is (one spotlight id).
                if remote.signsInFirst { switchRow } else { switchRow.spotlit(pointed && !remote.on, id: .remoteAccess) }
                if let hostname = remote.hostname {
                    SetRow("Hostname") { SetValue(hostname) }
                }
                SetRow("Status") {
                    let status = remote.busy ? "Setting up…" : remote.signsInFirst ? "Not set up" : remote.status
                    SetValue(status, connected: status == "Connected")
                }
                if remote.hostname != nil {
                    SetRow("") {
                        Button("Forget This Mac", role: .destructive) { forgetting = true }
                            .buttonStyle(.set)
                            .disabled(remote.busy)
                    }
                }
            }
        }
        .task { if remote.signsInFirst { await remote.loadSignInOptions() } }
        // On, and Pair a device sent you: straight back to it, its button ringed.
        .onChange(of: remote.on) { _, on in
            if on, pointed { openSettings(.runner, spotlight: .pairDevice) }
        }
        .onDisappear { openSettings.clear(.remoteAccess) }
        // Kept beyond Sangam's mock: the hostname can't be brought back, so macOS's confirmation first.
        .confirmationDialog("Forget this Mac?", isPresented: $forgetting) {
            Button("Forget", role: .destructive) { Task { await remote.forget() } }
        } message: {
            Text("Its tunnel and hostname are removed from Oby’s control plane. Turning remote access on again makes a new hostname.")
        }
    }

    private var switchRow: some View {
        SetRow("Reach this Mac from anywhere") {
            Toggle("Reach this Mac from anywhere", isOn: Binding(get: { remote.on }, set: { on in
                if on { Task { await remote.turnOn() } } else { Task { await remote.turnOff() } }
            }))
            .toggleStyle(.set)
            .disabled(remote.busy || remote.signsInFirst)
        }
    }

    private func signIn(with provider: ControlPlane.Provider) {
        signingIn = provider
        Task {
            await remote.turnOn(with: provider)
            signingIn = nil
        }
    }
}

/// A sign-in button's face: the provider's mark and "Sign in with Google", or a spinner while it works.
private struct SignInLabel: View {
    let provider: ControlPlane.Provider
    let working: Bool

    var body: some View {
        HStack(spacing: 10) {
            if working {
                ProgressView().controlSize(.small)
            } else if provider == .google {
                Image("Brands/google").resizable().scaledToFit().frame(width: 18, height: 18)
            } else {
                Image(systemName: "apple.logo").font(.system(size: 16, weight: .medium))
            }
            Text("Sign in with \(provider.name)")
        }
        .accessibilityElement(children: .combine)
    }
}

/// The providers' own buttons, by their guidelines, in Sangam's 8-round frame: Google's white
/// button (#1F1F1F words on a #747775 line) and Apple's black one (white words, a faint white line
/// so it shows on a dark card). 40 tall, the card's width; dimmer pressed, faded when it can't be
/// pressed.
private struct SignInButtonStyle: ButtonStyle {
    let provider: ControlPlane.Provider
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    private var fill: Color { provider == .google ? .white : .black }
    private var ink: Color { provider == .google ? Color(hex: 0x1F1F1F) : .white }
    private var edge: Color {
        provider == .google ? Color(hex: 0x747775) : Color(dark: Color.white.opacity(0.22), light: .clear)
    }

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(Tokens.font(Tokens.textBase, .medium))
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity).frame(height: 40)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(edge))
            .overlay(shape.fill(Color.gray.opacity(configuration.isPressed ? 0.18 : hovering && enabled ? 0.08 : 0)))
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.5)
            .onHover { hovering = $0 }
            .animation(Tokens.fade, value: hovering)
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
    /// One of obid's accounts, asked about before it goes.
    @State private var removingRunner: Account?
    /// The tools' own logins removed here (`default`, `codex`), comma-separated: Add an account
    /// offers them back.
    @AppStorage("ObyRemovedOwnLogins") private var removedOwnLogins = ""
    private var removedOwn: Set<String> { Set(removedOwnLogins.split(separator: ",").map(String.init)) }
    /// The tool's own login for one of obid's accounts, under way in its sheet.
    @State private var signingIn: ShownAccountSignIn?
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
                    }
                    Button("Remove", role: .destructive) { removing = state.account }.buttonStyle(.set)
                }
            }
            addAccount
        }
        if places.contains(.runner) {
            // obid's own accounts, signed in on it through each tool's own login. Its accounts API is
            // loopback only (docs/runner-api.md, "obid only: accounts"): a runner elsewhere lists them here,
            // and they're added, signed in and removed on that machine.
            AccountSections(feed.local ? "Accounts on this Mac" : "Accounts on \(feed.name)", items: feed.accounts, id: \.account.id,
                            usage: \.usage, place: both ? "on \(feed.name)" : nil) { state in
                AccountUsageRow(state: state, payer: state.account.payer) { lift in
                    // The runner's "accounts" event brings the change back.
                    guard let runner = feed.runner else { throw RunnerError(message: "Set the runner's URL in Settings first.") }
                    _ = try await runner.liftReserve(state.account.id, lift)
                } buttons: {
                    if feed.local {
                        if !state.signedIn {
                            Button("Sign In") { signIn(state.account) }.buttonStyle(.set)
                        }
                        Button("Remove", role: .destructive) { removingRunner = state.account }.buttonStyle(.set)
                    }
                }
            }
            if feed.local { runnerAddAccount }
        }
    }

    /// The tool picked has an own login (Claude Code, Codex) removed here that obid doesn't list.
    private var restorable: String? {
        guard let id = Self.ownLogins[agent], removedOwn.contains(id),
              !feed.accounts.contains(where: { $0.account.id == id }) else { return nil }
        return Job.agentNames[agent] ?? agent
    }

    /// The add form (Sangam's "Add an account"): the tool, a name, who pays. `restore` names a tool
    /// whose own login can come back, beside Add Account (obid on this Mac).
    private func addForm(restore: String? = nil, _ add: @escaping () async throws -> Void) -> some View {
        SetGroup("Add an account", problem: problem) {
            SetRow("Tool", about: agent == "cursor" && !CursorFacts.separateLogins ? "\(CursorFacts.oneLogin): one Cursor account." : nil) {
                SetSelect("Tool", selection: $agent, options: [("claude", "Claude Code"), ("codex", "Codex"), ("cursor", "Cursor")])
            }
            SetRow("Name") { SetField("Account name", text: $name, prompt: "Personal") }
            SetRow("Paid by") { SetField("Paid by", text: $payer, prompt: "Wellington") }
            SetRow("") {
                Button("Add Account") {
                    Task {
                        do {
                            try await add()
                            name = ""
                            payer = ""
                            problem = nil
                        } catch { problem = error.localizedDescription }
                    }
                }
                .buttonStyle(.set)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                if let restore {
                    Button("Use \(restore)'s Own Login") {
                        Task {
                            do {
                                guard let runner = feed.runner else { throw RunnerError(message: "Oby isn't connected to its runner on this Mac yet.") }
                                let back = try await runner.restoreDefaultLogin(agent: agent)
                                removedOwnLogins = removedOwn.subtracting([back.account.id]).sorted().joined(separator: ",")
                                problem = nil
                            } catch { problem = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.set)
                }
            }
        }
    }

    /// Adds to this Mac's own accounts, which only Oby on this Mac uses.
    private var addAccount: some View {
        addForm {
            try store.add(agent: agent, name: name.trimmingCharacters(in: .whitespaces), payer: payer.trimmingCharacters(in: .whitespaces))
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

    /// Adds to obid's accounts on this Mac: obid makes its folder, and its row then offers Sign In.
    /// The tool's own login, once removed here, comes back with its own button.
    private var runnerAddAccount: some View {
        addForm(restore: restorable) {
            guard let runner = feed.runner else { throw RunnerError(message: "Oby isn't connected to its runner on this Mac yet.") }
            _ = try await runner.addAccount(agent: agent, name: name.trimmingCharacters(in: .whitespaces),
                                            payer: payer.trimmingCharacters(in: .whitespaces))
        }
        // Kept beyond Sangam's mock, which removes at once: what goes and what stays, first.
        .confirmationDialog("Remove \(removingRunner?.name ?? "this account") from Oby?",
                            isPresented: Binding(get: { removingRunner != nil }, set: { if !$0 { removingRunner = nil } }),
                            presenting: removingRunner) { account in
            Button("Remove", role: .destructive) { remove(account) }
        } message: { account in
            Text(Self.removeNote(account))
        }
        .sheet(item: $signingIn) { shown in
            AccountSignInSheet(shown: shown, feed: feed) { signingIn = nil }
        }
    }

    /// The ids obid gives each tool's own login (core/crates/obid/src/accounts.rs `implicit`).
    static let ownLogins = ["claude": "default", "codex": "codex"]

    /// What removing one of obid's accounts does, and what it leaves.
    static func removeNote(_ account: Account) -> String {
        let (tool, provider) = switch account.agent {
        case "codex": ("Codex", "OpenAI")
        case "cursor": ("Cursor", "Cursor")
        default: ("Claude Code", "Anthropic")
        }
        if ownLogins[account.agent] == account.id {
            return "Oby stops using \(tool)'s own login on this Mac; nothing of it is deleted. Bring it back here any time with Use \(tool)'s Own Login, under Add an account."
        }
        // Claude Code keeps an account's login in the Keychain on a Mac (docs/runner-api.md): obid leaves it.
        let kept = account.agent == "claude" ? " Its Keychain item for this account stays too; Keychain Access removes it." : ""
        // One obid made has eight hex digits; any other is in obid's configuration.
        let made = account.id.wholeMatch(of: /[0-9a-f]{8}/) != nil
        let back = made ? "" : " It's in obid's configuration, so it can't be added back here."
        return "Oby stops using it, and deletes the folder it made for it, if any. \(tool)'s own login on this Mac, and your account with \(provider), stay as they are: sign out there to end them.\(kept)\(back)"
    }

    private func remove(_ account: Account) {
        Task {
            do {
                guard let runner = feed.runner else { throw RunnerError(message: "Oby isn't connected to its runner on this Mac yet.") }
                try await runner.removeAccount(account.id)
                if Self.ownLogins[account.agent] == account.id {
                    removedOwnLogins = removedOwn.union([account.id]).sorted().joined(separator: ",")
                }
                problem = nil
            } catch { problem = error.localizedDescription }
        }
    }

    /// The tool's own login on obid: its page opens in the browser, and the sheet waits for it.
    private func signIn(_ account: Account) {
        Task {
            do {
                guard let runner = feed.runner else { throw RunnerError(message: "Oby isn't connected to its runner on this Mac yet.") }
                let signIn = try await runner.startAccountSignIn(account.id)
                guard signIn.opens(for: account.agent) else {
                    try? await runner.endAccountSignIn(account.id)
                    throw RunnerError(message: "\(feed.name) answered with a page that isn't \((Job.agentNames[account.agent] ?? account.agent))'s own sign-in, so Oby opened nothing.")
                }
                if let code = signIn.userCode {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
                NSWorkspace.shared.open(signIn.url)
                signingIn = ShownAccountSignIn(account: account, signIn: signIn)
                problem = nil
            } catch { problem = error.localizedDescription }
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

/// One of obid's accounts with its sign-in under way, as a sheet's item.
struct ShownAccountSignIn: Identifiable {
    let account: Account
    let signIn: AccountSignIn
    var id: String { account.id }
}

/// The tool's own login for one of obid's accounts, waiting for the person on the tool's page: the
/// code to type there (Codex, already on the clipboard), or a field for the code the page ends with
/// (Claude Code); the page again; Cancel. Oby only hands the code to the tool's login, once.
private struct AccountSignInSheet: View {
    let shown: ShownAccountSignIn
    let feed: RunnerFeed
    let close: () -> Void
    @State private var code = ""
    @State private var sending = false
    @State private var problem: String?

    private var tool: String { Job.agentNames[shown.account.agent] ?? shown.account.agent }
    private var signedIn: Bool { feed.accounts.first { $0.account.id == shown.account.id }?.signedIn == true }

    var body: some View {
        VStack(spacing: 12) {
            Text("Sign in to \(tool)").font(Tokens.font(17, .semibold)).foregroundStyle(Tokens.ink)
            if let userCode = shown.signIn.userCode {
                Text("\(tool)'s page opened in your browser. Type this code there; it's on your clipboard.")
                    .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.text).multilineTextAlignment(.center)
                Text(userCode).font(Tokens.mono(30)).foregroundStyle(Tokens.ink).textSelection(.enabled)
                    .accessibilityLabel("Code \(userCode.map(String.init).joined(separator: " "))")
            } else if shown.signIn.pasteCode {
                Text("\(tool)'s page opened in your browser. Sign in as \(shown.account.name), then paste the code it shows.")
                    .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.text).multilineTextAlignment(.center)
                SetField("Code", text: $code, prompt: "Paste the code").onSubmit(send).disabled(sending)
            } else {
                Text("\(tool)'s page opened in your browser. Sign in there as \(shown.account.name).")
                    .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.text).multilineTextAlignment(.center)
            }
            if !shown.signIn.pasteCode || sending {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for \(tool)").font(Tokens.font(13)).foregroundStyle(Tokens.muted)
                }
            }
            if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger).multilineTextAlignment(.center) }
            HStack(spacing: 8) {
                Button("Cancel", action: cancel).buttonStyle(.set).keyboardShortcut(.cancelAction)
                Button("Open the Page Again") { NSWorkspace.shared.open(shown.signIn.url) }.buttonStyle(.set)
                if shown.signIn.pasteCode {
                    Button("Sign In", action: send).buttonStyle(.set).keyboardShortcut(.defaultAction)
                        .disabled(sending || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.top, 6)
            Text("\(tool) keeps the login, in Oby's folder for \(shown.account.name). Oby never reads it; it only learns that it worked.")
                .font(Tokens.font(12)).foregroundStyle(Tokens.muted).multilineTextAlignment(.center)
        }
        .padding(26)
        .frame(width: 420)
        .background(Tokens.surface)
        // Codex and Cursor end by themselves: obid's `accounts` event says it's signed in.
        .onChange(of: signedIn) { if signedIn { close() } }
    }

    private func send() {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !sending, let runner = feed.runner else { return }
        sending = true
        Task {
            defer { sending = false }
            do {
                _ = try await runner.sendAccountCode(shown.account.id, code)
                close()
            } catch { problem = error.localizedDescription }
        }
    }

    private func cancel() {
        close()
        let id = shown.account.id
        Task { try? await feed.runner?.endAccountSignIn(id) }
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
    /// The launch build's Connectors has no Tetrix (`Launch`): then neither has this row.
    @AppStorage(Launch.everythingKey) private var everything = false

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
                        // One Tetrix for every agent (Connectors): how much its jobs used it, or where to connect it.
                        if everything, state.signedIn {
                            SetAbout(TetrixJobReport.accountLine(connected: state.tetrix == true, jobs: state.tetrixJobs, used: state.tetrixUsed, there: "in Connectors"),
                                     color: state.tetrix == true ? Tokens.muted : Tokens.needs)
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

/// A monitoring tool in a sheet's `item`.
private struct IdentifiedTool: Identifiable {
    let tool: AlertingTool
    var id: String { tool.id }
}

/// Connect… on Prometheus or Grafana (#1311): the repository its alerts are about and the label
/// that names the project, then the address and secret to paste into the tool, shown once.
struct AlertHookSheet: View {
    let tool: AlertingTool
    let repos: [String]
    /// Remote access is on, with this Mac's hostname: the alerts come through its tunnel.
    let remoteOn: Bool
    /// Nil while Remote access is hidden (`Launch`).
    let openRemote: (() -> Void)?
    let make: (_ repo: String, _ label: String) async throws -> (Runner.HookRow, String)
    /// PagerDuty's two steps: an address first, then the secret PagerDuty shows; cancelled between
    /// them, the address goes again.
    var reserve: () async throws -> ControlPlane.Hook = { throw ControlPlane.Failure(message: "Not here.", status: 0) }
    var finish: (_ address: ControlPlane.Hook, _ repo: String, _ secret: String) async throws -> Void = { _, _, _ in }
    var abandon: (_ address: ControlPlane.Hook) async -> Void = { _ in }
    let done: () -> Void
    @State private var repo = ""
    @State private var label = "service"
    @State private var made: (url: String, secret: String, label: String)?
    @State private var reserved: ControlPlane.Hook?
    @State private var pasted = ""
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect \(tool.name)").font(Tokens.font(Tokens.textLg, .semibold))
            if let made {
                Text("Paste these into \(tool.name) now: Oby shows the secret only this once, and keeps it only in obid's vault.")
                    .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(tool.steps(url: made.url, secret: made.secret, label: made.label))
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                HStack {
                    Button("Copy Address") { copy(made.url) }
                    Button("Copy Secret") { copy(made.secret) }
                    Spacer()
                    Button("Done", action: done).keyboardShortcut(.defaultAction)
                }
            } else if let reserved {
                ScrollView {
                    Text(tool.steps(url: reserved.url.absoluteString, secret: ""))
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                HStack {
                    Button("Copy Address") { copy(reserved.url.absoluteString) }
                    Spacer()
                }
                SecureField("PagerDuty's signing secret", text: $pasted)
                if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger) }
                HStack {
                    Spacer()
                    // The address goes as the sheet closes (`onDisappear`), unless Finish kept it.
                    Button("Cancel", role: .cancel, action: done).disabled(busy)
                    Button("Finish") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                try await finish(reserved, repo, pasted.trimmingCharacters(in: .whitespacesAndNewlines))
                                pasted = ""
                                self.reserved = nil
                                done()
                            } catch {
                                problem = error.localizedDescription
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || pasted.trimmingCharacters(in: .whitespacesAndNewlines).count < 32)
                }
            } else if !remoteOn {
                Text("\(tool.name)'s alerts reach this Mac through Remote access, so it needs to be on first.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel, action: done)
                    if let openRemote { Button("Open Remote Access", action: openRemote).keyboardShortcut(.defaultAction) }
                }
            } else {
                Text("Critical and error alerts become cards in your inbox; Look into it starts an investigate job in this repository, with the alert quoted for its agent.")
                    .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
                Picker("Repository", selection: $repo) {
                    Text("Choose…").tag("")
                    ForEach(repos, id: \.self) { Text($0).tag($0) }
                }
                if tool.asksLabel { TextField("Label that names the project", text: $label) }
                if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger) }
                HStack {
                    Spacer()
                    // Not while it runs: the hook it makes would be left with a secret nobody saw.
                    Button("Cancel", role: .cancel, action: done).disabled(busy)
                    Button(tool.secretFromTool ? "Continue" : "Connect") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                if tool.secretFromTool {
                                    reserved = try await reserve()
                                } else {
                                    let named = label.trimmingCharacters(in: .whitespaces)
                                    let (row, secret) = try await make(repo, named)
                                    made = (row.url, secret, named)
                                }
                                problem = nil
                            } catch {
                                problem = error.localizedDescription
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || repo.isEmpty || label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(busy)
        // However it closes (Cancel, Escape, the window), an address obid never got goes again.
        .onDisappear { if let reserved { Task { await abandon(reserved) } } }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Sentry's projects (#1127): a switch each to follow it, and the repository its errors are looked
/// into in. A project with no repository still offers its errors, with only Dismiss.
struct SentryProjectsSheet: View {
    let status: SentryStatus
    var problem: String?
    let change: (_ slug: String, _ change: Runner.SentryProjectChange) -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sentry projects").font(Tokens.font(Tokens.textLg, .semibold))
            Text("Oby reads the projects you follow every 5 minutes. A new error, or one that escalates or comes back, arrives in your inbox; Look into it starts an investigate job in the project's repository, with the stack trace and never your users' data.")
                .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
            if status.projects.isEmpty {
                Text("Sentry lists no project in \(status.org ?? "this organization").").foregroundStyle(Tokens.muted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(status.projects) { project in
                        HStack(spacing: 12) {
                            Toggle(project.name, isOn: Binding(get: { project.follow }, set: { change(project.slug, .follow($0)) }))
                                .toggleStyle(.switch)
                            Spacer()
                            Picker("Repository", selection: Binding(get: { project.repo ?? "" },
                                                                   set: { change(project.slug, .repo($0.isEmpty ? nil : $0)) })) {
                                Text("No repository").tag("")
                                ForEach(status.repos, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 240)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
            if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger) }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

/// Settings › Connectors (#498), as Sangam's SettingsView.tsx `Connectors`: a search, then Connected and
/// Available, one row per service with its brand's mark, its name and a line on it, and at the right
/// "Connected" or its button (apps/mac/app/Connectors.swift). How it's signed in is the row's tooltip;
/// Disconnect and the rest are in its context menu, so the row stays as clean as the design's.
struct ConnectorsSettingsView: View {
    let store: AccountStore
    let feed: RunnerFeed
    /// Remote access: a monitoring tool's hook is made with this Mac's key, and its alerts come
    /// through the tunnel (#1311).
    var remote: RemoteAccess? = nil
    @Environment(\.openSettingsPage) private var openSettings
    @State private var query = ""
    /// What the runner lists besides its status, once it answers, and each list it couldn't read.
    @State private var lists = Connectors.Lists()
    @State private var confirming: Connector?
    /// The plug-in whose Connect asks for Tetrix's MCP URL, and the URL typed.
    @State private var asking: String?
    /// "Another Tetrix…" asks for its MCP URL in the same field.
    @State private var askingTetrix = false
    /// The sign-in obid started, while its sheet waits for Tetrix's page.
    @State private var tetrixSignIn: ShownTetrixSignIn?
    @State private var url = ""
    @State private var busy = false
    /// What went wrong with a row's button, by the row's id, shown under that row.
    @State private var problems: [String: String] = [:]
    /// gh's sign-in under way on the runner, shown in its sheet until it signs in or is cancelled.
    @State private var gitHubSignIn: GitHubSignIn?
    /// Connect… on Slack asks for the Slack app's two tokens in these fields, cleared once sent.
    @State private var askingSlack = false
    @State private var userToken = ""
    @State private var botToken = ""
    /// The app-level token, for live channels (Socket Mode): optional.
    @State private var appToken = ""
    /// Connect… on Sentry asks for its address, the organization and a token, cleared once sent.
    @State private var askingSentry = false
    @State private var sentryURL = SentryStatus.defaultURL
    @State private var sentryOrg = ""
    @State private var sentryToken = ""
    /// Projects… on Sentry: which are followed, and where each is looked into.
    @State private var showingSentryProjects = false
    /// Connect… on a monitoring tool: its obid source, while its sheet is up.
    @State private var alerting: AlertingTool?
    /// The launch build lists only GitHub and Slack, and has no Remote access (`Launch`).
    @AppStorage(Launch.everythingKey) private var everything = false

    var body: some View {
        let groups = Connectors.groups(list, query: query)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                SearchField(text: $query, prompt: "Search connectors")
                // What the runner holds (Tetrix, GitHub, its accounts) waits for it to answer: it'd be out of date.
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
                Text("No connector matches “\(typed)”")
                    .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted).padding(.horizontal, 16).padding(.bottom, 24)
            }
        }
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
        .sheet(item: $tetrixSignIn) { shown in
            TetrixSignInSheet(server: shown.server, host: shown.signIn.host ?? "", place: feed.name, again: { openTetrixPage() }) {
                tetrixSignIn = nil
                Task { try? await feed.runner?.cancelTetrixSignIn() }
            }
            .task { await waitForTetrix() }
        }
        .alert("Another Tetrix", isPresented: $askingTetrix) {
            TextField("MCP URL", text: $url, prompt: Text("https://"))
            Button("Connect") { if let server = TetrixStatus.custom(typedURL) { signInToTetrix(server, row: "tetrix") } }
                .disabled(!TetrixStatus.isServerURL(typedURL))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its MCP server's address, starting with https://. You sign in on its own page, once, for every agent on \(feed.name).")
        }
        .alert("Connect Slack", isPresented: $askingSlack) {
            SecureField("User OAuth Token", text: $userToken, prompt: Text("xoxp-…"))
            SecureField("Bot User OAuth Token", text: $botToken, prompt: Text("xoxb-…"))
            SecureField("App-Level Token (optional)", text: $appToken, prompt: Text("xapp-…"))
            Button("Connect") { connectSlack(row: "slack") }
                .disabled(!SlackStatus.isToken(userToken, "xoxp-") || !SlackStatus.isToken(botToken, "xoxb-")
                          || (!appToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !SlackStatus.isToken(appToken, "xapp-")))
            Button("Cancel", role: .cancel) { (userToken, botToken, appToken) = ("", "", "") }
        } message: {
            Text("Your workspace's Oby app's tokens, from api.slack.com/apps › OAuth & Permissions › OAuth Tokens, and its app-level token (Basic Information) for live channels. obid checks them with Slack and keeps them in its vault; this Mac doesn't keep them.")
        }
        .alert("Connect Sentry", isPresented: $askingSentry) {
            TextField("Sentry's address", text: $sentryURL, prompt: Text(SentryStatus.defaultURL))
            TextField("Organization", text: $sentryOrg, prompt: Text("your-org"))
            SecureField("Token", text: $sentryToken, prompt: Text("sntryu_…"))
            Button("Connect") { connectSentry(row: "sentry") }
                .disabled(!SentryStatus.isURL(sentryURL) || !SentryStatus.isOrg(sentryOrg) || !SentryStatus.isToken(sentryToken))
            Button("Cancel", role: .cancel) { sentryToken = "" }
        } message: {
            Text("Sentry's address (https://sentry.io, or https://de.sentry.io in the EU), your organization's slug, and a token with only org:read, project:read and event:read (Sentry › Settings › Account › API › Personal Tokens). obid checks it only reads and keeps it in its vault; this Mac doesn't keep it.")
        }
        .sheet(item: Binding(get: { alerting.map(IdentifiedTool.init) }, set: { alerting = $0?.tool })) { shown in
            AlertHookSheet(tool: shown.tool, repos: lists.repos, remoteOn: remote?.on == true && remote?.hostname != nil,
                           openRemote: everything ? { alerting = nil; openSettings(.remote) } : nil,
                           make: { repo, label in try await makeHook(shown.tool, repo: repo, label: label) },
                           reserve: { try await reserveHook() },
                           finish: { address, repo, secret in try await finishHook(shown.tool, address, repo: repo, secret: secret) },
                           abandon: { address in await abandonHook(address) },
                           done: { alerting = nil })
        }
        .sheet(isPresented: $showingSentryProjects) {
            SentryProjectsSheet(status: lists.sentry ?? SentryStatus(), problem: problems["sentry-projects"],
                                change: { slug, change in setSentryProject(slug, change) },
                                done: { showingSentryProjects = false })
        }
        // obid signed Sentry out, or a read went wrong: the row says so; the event leaves out `repos`.
        .onChange(of: feed.sentry) { _, told in
            guard var told, lists.sentry != nil else { return }
            told.repos = lists.sentry?.repos ?? []
            lists.sentry = told
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
        #if DEBUG
        let staged = feed.stagedLists != nil
        #else
        let staged = false
        #endif
        let runner = (feed.runner == nil && !staged) || feed.connection != .live ? nil : Connectors.RunnerState(
            name: feed.name, local: feed.local, accounts: feed.accounts, github: feed.github, checks: feed.checkRuns,
            gitHubLogin: lists.gitHub, plugins: lists.plugins, connections: lists.connections, tetrix: feed.tetrix,
            slack: feed.slack, watch: feed.watch, sentry: lists.sentry, hooks: lists.hooks)
        let accounts = Connectors.accounts(mac: store.accounts, runner: runner?.accounts, local: feed.local,
                                           hasRunner: feed.runner != nil || staged)
        return Connectors.shown(Connectors.list(accounts: accounts, runner: runner), everything: everything)
    }

    private var typedURL: String { url.trimmingCharacters(in: .whitespaces) }

    /// Sangam's connector row (`.set-connector`): its mark, its name over its line; under them only what
    /// needs doing (what's wrong, or what to do where Oby has no button); at the right "Connected", its
    /// button, or "Coming soon".
    private func row(_ connector: Connector) -> some View {
        let buttons = [connector.way, connector.also, connector.more].compactMap { way -> (String, Connector.Action)? in
            if case .button(let label, let action) = way { (label, action) } else { nil }
        }
        // Connected, every button is in the context menu; otherwise the first is on the row.
        let onRow = connector.connected ? nil : buttons.first
        return SetRow {
            HStack(spacing: 12) {
                mark(connector).frame(width: 24, height: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(connector.name)
                    SetAbout(connector.about)
                    if connector.state == .broken { SetAbout(connector.how, color: Tokens.needs) }
                    if !connector.connected, case .steps(let steps) = connector.way { SetAbout(steps) }
                    if let problem = problems[connector.id] { SetAbout(problem, color: Tokens.danger) }
                }
            }
        } control: {
            if connector.connected {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(Tokens.font(12, .medium)).foregroundStyle(Tokens.muted)
                    Text("Connected").font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.text)
                }
                .accessibilityElement(children: .combine)
            } else if connector.soon {
                SetValue("Coming soon")
            } else if let button = onRow {
                Button(button.0) { perform(button.1, connector) }
                    .buttonStyle(.set)
                    .disabled(busy)
                    .accessibilityLabel("\(button.0.replacingOccurrences(of: "…", with: "")) \(connector.name)")
            } else if connector.state == .unconfirmed {
                SetValue("Not confirmed")
            }
        }
        .contentShape(Rectangle())
        .help(connector.tip)
        .contextMenu {
            ForEach(buttons.filter { $0.0 != onRow?.0 }, id: \.0) { label, action in
                Button(label) { perform(action, connector) }.disabled(busy)
            }
        }
    }

    /// The brand's own mark (Sangam's brands.tsx, in its colours), or a symbol for what has none.
    @ViewBuilder private func mark(_ connector: Connector) -> some View {
        if let brand = connector.brand {
            Image("Brands/\(brand)").resizable().scaledToFit()
        } else {
            Image(systemName: connector.symbol).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted)
        }
    }

    /// What the runner lists besides its status: obid's plug-ins, the Swift runner's connections.
    /// A list it couldn't read says why; only a 404 means it has none.
    private func load() async {
        #if DEBUG
        if let staged = feed.stagedLists {
            lists = staged
            if let slack = staged.slack { feed.slack = slack }
            if let watch = staged.watch { feed.watch = watch }
            return
        }
        #endif
        defer {
            if let status = lists.tetrix { feed.tetrix = status }
            // Read here, then kept by their events (obid signing out after a refused token); a read
            // that failed keeps what the events said.
            if let slack = lists.slack { feed.slack = slack }
            if let watch = lists.watch { feed.watch = watch }
        }
        guard feed.connection == .live, let runner = feed.runner else {
            lists = Connectors.Lists()
            return
        }
        lists = await Connectors.lists(from: runner, name: feed.name)
    }

    /// A button: what takes something away asks first; signing in or out opens Terminal.
    private func perform(_ action: Connector.Action, _ connector: Connector) {
        switch action {
        case .disablePlugin, .disconnect, .disconnectTetrix, .disconnectSlack, .disconnectSentry: confirming = connector
        case .connectSentry:
            (sentryURL, sentryOrg, sentryToken) = (lists.sentry?.url ?? SentryStatus.defaultURL, lists.sentry?.org ?? "", "")
            askingSentry = true
        case .sentryProjects:
            problems["sentry-projects"] = nil
            showingSentryProjects = true
        case .connectAlerts(let source):
            alerting = AlertingTool.all.first { $0.source == source }
        case .disconnectAlerts: confirming = connector
        case .connectSlack:
            (userToken, botToken, appToken) = ("", "", "")
            askingSlack = true
        case .setWatchLive(let live):
            guard feed.local, let runner = feed.runner else { return }
            Task {
                busy = true
                defer { busy = false }
                do {
                    feed.watch = try await runner.setWatchLive(live)
                    problems[connector.id] = nil
                } catch {
                    problems[connector.id] = error.localizedDescription
                }
            }
        case .setTellAuthors(let on):
            guard feed.local, let runner = feed.runner else { return }
            Task {
                busy = true
                defer { busy = false }
                do {
                    feed.slack = try await runner.setSlackTellAuthors(on)
                    problems[connector.id] = nil
                } catch {
                    problems[connector.id] = error.localizedDescription
                }
            }
        case .accounts: openSettings(.accounts)
        case .connectTetrix(let server): signInToTetrix(server, row: connector.id)
        case .connectOtherTetrix:
            url = ""
            askingTetrix = true
        case .reopenTetrixSignIn: reopenTetrixSignIn(row: connector.id)
        case .cancelTetrixSignIn: cancelTetrixSignIn(row: connector.id)
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
        case .disablePlugin(let id): setPlugin(id, enabled: false, row: connector.id)
        case .disconnectTetrix:
            guard feed.local, let runner = feed.runner else { return }
            Task {
                busy = true
                defer { busy = false }
                do {
                    try await runner.disconnectTetrix()
                    problems[connector.id] = nil
                    // Signed out (204): never left showing Connected when the status can't be read.
                    feed.tetrix?.connected = false
                } catch {
                    problems[connector.id] = error.localizedDescription
                }
                if let status = try? await runner.tetrix() { feed.tetrix = status }
            }
        case .disconnectSlack: disconnectSlack(row: connector.id)
        case .disconnectAlerts(let id):
            guard feed.local, let runner = feed.runner, let remote else { return }
            Task {
                busy = true
                defer { busy = false }
                do {
                    try await HookSetup.remove(id: id, plane: remote.plane, signer: try remote.signer(), obid: runner)
                    problems[connector.id] = nil
                } catch {
                    problems[connector.id] = error.localizedDescription
                }
                lists.hooks = try? await runner.hooksIfAny()
            }
        case .disconnectSentry:
            guard feed.local, let runner = feed.runner else { return }
            Task {
                busy = true
                defer { busy = false }
                do {
                    try await runner.disconnectSentry()
                    lists.sentry?.connected = false
                    problems[connector.id] = nil
                } catch {
                    problems[connector.id] = error.localizedDescription
                }
                if let status = try? await runner.sentry() { lists.sentry = status }
            }
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
        case .disablePlugin:
            return "\(feed.name) stops it and everything it started, and agents no longer get its tools."
        case .disconnect:
            return "After Touch ID, \(feed.name) forgets it and its agents can't reach it any more. Its secret stays in the runner's vault."
        case .disconnectTetrix:
            return "\(feed.local ? "obid" : feed.name) forgets its Tetrix login, and agents on every account stop getting Tetrix's tools."
        case .disconnectSlack:
            return "obid forgets its Slack login, and the watcher reads only GitHub until you connect Slack again."
        case .disconnectSentry:
            return "obid forgets its Sentry token, and Sentry's errors stop reaching your inbox until you connect it again."
        case .disconnectAlerts:
            return "Its address stops working and obid forgets its secret: \(connector.name)'s alerts stop reaching Oby until you connect it again, and set it up there again."
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

    /// obid's sign-in to `server`: Tetrix's own page opens in the browser, and the sheet waits for
    /// obid to say it's connected. Only a page on that server's host, over https, is ever opened.
    private func signInToTetrix(_ server: TetrixStatus.Server, row: String) {
        guard feed.local, let runner = feed.runner else { return }
        Task {
            busy = true
            defer { busy = false }
            do {
                let signIn = try await runner.startTetrixSignIn(server)
                guard signIn.opens else {
                    problems[row] = "\(feed.name) answered with a sign-in page that isn't https on Tetrix's sign-in server, so Oby opened nothing."
                    try? await runner.cancelTetrixSignIn()
                    return
                }
                problems[row] = nil
                tetrixSignIn = ShownTetrixSignIn(server: server, signIn: signIn)
                NSWorkspace.shared.open(signIn.url)
                if let status = try? await runner.tetrix() { feed.tetrix = status }
            } catch {
                problems[row] = error.localizedDescription
            }
        }
    }

    /// The sheet's Open Again: the page it showed, if obid still has that sign-in under way.
    private func openTetrixPage() {
        guard let shown = tetrixSignIn else { return }
        Task {
            guard let now = try? await feed.runner?.tetrix()?.signIn, now.url == shown.signIn.url, now.opens else { return }
            NSWorkspace.shared.open(now.url)
        }
    }

    /// The row's Open the Page Again, once the sheet is gone: obid's sign-in under way, after the
    /// same checks, with its sheet again.
    private func reopenTetrixSignIn(row: String) {
        guard feed.local, let runner = feed.runner else { return }
        Task {
            guard let status = try? await runner.tetrix() else { return }
            feed.tetrix = status
            guard let signIn = status.signIn, let server = status.server else { return }
            guard signIn.opens else {
                problems[row] = "\(feed.name) answered with a sign-in page that isn't https on Tetrix's sign-in server, so Oby opened nothing."
                return
            }
            problems[row] = nil
            tetrixSignIn = ShownTetrixSignIn(server: server, signIn: signIn)
            NSWorkspace.shared.open(signIn.url)
        }
    }

    /// The row's Cancel: ends obid's sign-in under way.
    private func cancelTetrixSignIn(row: String) {
        guard feed.local, let runner = feed.runner else { return }
        Task {
            busy = true
            defer { busy = false }
            do {
                try await runner.cancelTetrixSignIn()
                problems[row] = nil
            } catch {
                problems[row] = error.localizedDescription
            }
            if let status = try? await runner.tetrix() { feed.tetrix = status }
        }
    }

    /// While the sheet is up: asks every 2 seconds whether obid is connected, and closes it once it is
    /// or the sign-in ended.
    private func waitForTetrix() async {
        while tetrixSignIn != nil, !Task.isCancelled, let runner = feed.runner {
            try? await Task.sleep(for: .seconds(2))
            guard let status = try? await runner.tetrix() else { continue }
            if status.connected || status.signIn == nil {
                feed.tetrix = status
                if !status.connected { problems["tetrix"] = status.error ?? "Tetrix's sign-in ended without signing in." }
                tetrixSignIn = nil
            }
        }
    }

    /// Gives obid the two tokens typed, then forgets them here: obid checks them with Slack and says
    /// why when it doesn't take them.
    private func connectSlack(row: String) {
        let (user, bot) = (userToken.trimmingCharacters(in: .whitespacesAndNewlines), botToken.trimmingCharacters(in: .whitespacesAndNewlines))
        let app = appToken.trimmingCharacters(in: .whitespacesAndNewlines)
        (userToken, botToken, appToken) = ("", "", "")
        guard feed.local, let runner = feed.runner else { return }
        Task {
            busy = true
            defer { busy = false }
            do {
                feed.slack = try await runner.connectSlack(user: user, bot: bot, app: app.isEmpty ? nil : app)
                problems[row] = nil
            } catch {
                problems[row] = error.localizedDescription
            }
            if let watch = try? await runner.watch() { feed.watch = watch }
        }
    }

    /// Gives obid Sentry's address, the organization and the token typed, then forgets the token
    /// here: obid checks it only reads and says why when it doesn't take it. Connected, Projects… opens.
    private func connectSentry(row: String) {
        let (url, org, token) = (sentryURL.trimmingCharacters(in: .whitespacesAndNewlines),
                                 sentryOrg.trimmingCharacters(in: .whitespacesAndNewlines),
                                 sentryToken.trimmingCharacters(in: .whitespacesAndNewlines))
        sentryToken = ""
        guard feed.local, let runner = feed.runner else { return }
        Task {
            busy = true
            defer { busy = false }
            do {
                lists.sentry = try await runner.connectSentry(url: url, org: org, token: token)
                problems[row] = nil
                showingSentryProjects = true
            } catch {
                problems[row] = error.localizedDescription
            }
        }
    }

    /// Makes a monitoring tool's hook: its address at the control plane (this Mac's key), then obid's
    /// registry with a new secret, which the sheet shows once. The row then says Connected.
    private func makeHook(_ tool: AlertingTool, repo: String, label: String) async throws -> (Runner.HookRow, String) {
        guard let runner = feed.runner, let remote else { throw ControlPlane.Failure(message: "Turn on Remote access first.", status: 0) }
        let secret = HookSetup.newSecret()
        let taken = Set((lists.hooks ?? []).map(\.name))
        let name = ([tool.id] + (2...9).map { "\(tool.id)-\($0)" }).first { !taken.contains($0) } ?? "\(tool.id)-\(Int.random(in: 10...99))"
        let row = try await HookSetup.make(name: name, source: tool.source, repo: repo, secret: secret,
                                           projectLabel: label == "service" ? nil : label,
                                           plane: remote.plane, signer: try remote.signer(), obid: runner)
        lists.hooks = (try? await runner.hooksIfAny()) ?? lists.hooks
        return (row, secret)
    }

    /// PagerDuty's first step: an address at the control plane, to paste into PagerDuty.
    private func reserveHook() async throws -> ControlPlane.Hook {
        guard let remote else { throw ControlPlane.Failure(message: "Turn on Remote access first.", status: 0) }
        return try await remote.plane.createHook(try remote.signer())
    }

    /// Its second: obid keeps the hook with the secret PagerDuty showed.
    private func finishHook(_ tool: AlertingTool, _ address: ControlPlane.Hook, repo: String, secret: String) async throws {
        guard let runner = feed.runner else { throw ControlPlane.Failure(message: "obid isn't answering.", status: 0) }
        let taken = Set((lists.hooks ?? []).map(\.name))
        let name = ([tool.id] + (2...9).map { "\(tool.id)-\($0)" }).first { !taken.contains($0) } ?? "\(tool.id)-\(Int.random(in: 10...99))"
        _ = try await HookSetup.finish(address, name: name, source: tool.source, repo: repo, secret: secret, obid: runner)
        lists.hooks = (try? await runner.hooksIfAny()) ?? lists.hooks
    }

    /// Cancelled before obid kept it: the address goes, so nothing is left half made.
    private func abandonHook(_ address: ControlPlane.Hook) async {
        guard let remote, let signer = try? remote.signer() else { return }
        try? await remote.plane.removeHook(address.id, signer)
    }

    /// Follows a Sentry project or not, and where it's looked into: shown as obid answers.
    private func setSentryProject(_ slug: String, _ change: Runner.SentryProjectChange) {
        guard let runner = feed.runner else { return }
        Task {
            do {
                lists.sentry = try await runner.setSentryProject(slug, change)
                problems["sentry-projects"] = nil
            } catch {
                problems["sentry-projects"] = error.localizedDescription
            }
        }
    }

    /// obid forgets the Slack tokens: the row says Not connected at its 204, then as obid says.
    private func disconnectSlack(row: String) {
        guard feed.local, let runner = feed.runner else { return }
        Task {
            busy = true
            defer { busy = false }
            do {
                try await runner.disconnectSlack()
                feed.slack?.connected = false
                problems[row] = nil
            } catch {
                problems[row] = error.localizedDescription
            }
            if let status = try? await runner.slack() { feed.slack = status }
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
}

/// A Tetrix sign-in as a sheet's item: the server and the page opened for it.
private struct ShownTetrixSignIn: Identifiable {
    var server: TetrixStatus.Server
    var signIn: TetrixSignIn
    var id: URL { signIn.url }
}

/// obid signing in to Tetrix, waiting for the person on Tetrix's page: the host it's on, the page
/// again, Cancel.
/// Not in Sangam's design (his Knowledge modal says "Signing in…" on its button); kept as GitHub's sheet.
private struct TetrixSignInSheet: View {
    let server: TetrixStatus.Server
    /// The host of the sign-in page, so the person sees where they're signing in.
    let host: String
    let place: String
    let again: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Sign in to Tetrix").font(Tokens.font(17, .semibold)).foregroundStyle(Tokens.ink)
            Text("\(server.name)'s sign-in opened in your browser. Sign in there; every agent on every account uses it after that.")
                .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.text).multilineTextAlignment(.center)
            Text(verbatim: host).font(Tokens.mono(13)).foregroundStyle(Tokens.ink).textSelection(.enabled)
                .accessibilityLabel("Signing in at \(host)")
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for Tetrix").font(Tokens.font(13)).foregroundStyle(Tokens.muted)
            }
            HStack(spacing: 8) {
                Button("Cancel", action: cancel).buttonStyle(.set).keyboardShortcut(.cancelAction)
                Button("Open the Page Again", action: again).buttonStyle(.set)
            }
            .padding(.top, 6)
            Text("\(place == Connectors.thisMac ? "obid on this Mac" : place) keeps the login. Oby only learns that it worked.")
                .font(Tokens.font(12)).foregroundStyle(Tokens.muted).multilineTextAlignment(.center)
        }
        .padding(26)
        .frame(width: 400)
        .background(Tokens.surface)
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
    /// Opens Terminal on the tool's own login, with the account's home in the environment.
    func signIn(_ account: Account) throws {
        let script = URL(filePath: account.home ?? homes.path).appending(path: "sign-in-\(account.id).command")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.signInScript(for: account).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        guard NSWorkspace.shared.open(script) else { throw Shell.Failure(message: "Couldn't open Terminal to sign in.") }
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
