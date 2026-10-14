import AppKit
import ServiceManagement
import SwiftUI

/// Settings › General: what the iPhone's Settings has too (Shared/SettingsSections.swift),
/// opening at login, and how much this Mac's own jobs ask.
struct SettingsView: View {
    /// This Mac's desk: Settings › Permissions' default for the jobs it runs itself (#134). The
    /// runner's is in Settings › Runner.
    let desk: Desk
    @State private var mode = PermissionMode.bypass
    /// The rules Always allow (or a deny) saved on this Mac, read when Settings opens.
    @State private var rules: [PermissionRule] = []
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var problem: String?
    /// Oby reads its reply out loud when you talked to it (Mac/Speech.swift).
    @AppStorage(Speaker.setting) private var speaks = true

    var body: some View {
        Form {
            Toggle("Open at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        problem = nil
                    } catch {
                        problem = error.localizedDescription
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            Section {
                Picker("Default mode", selection: $mode) {
                    ForEach(RunnerMode.allCases) { choice in
                        Text(choice.label).tag(PermissionMode(rawValue: choice.rawValue) ?? .bypass)
                    }
                }
                .onChange(of: mode) { _, chosen in if desk.defaultMode != chosen { desk.defaultMode = chosen } }
                if let help = RunnerMode(mode.rawValue)?.help {
                    Text(help).font(.footnote).foregroundStyle(.secondary)
                }
                if rules.isEmpty {
                    Text("No saved rules").foregroundStyle(.secondary)
                }
                ForEach(rules) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.rule).font(.body.monospaced())
                            Text("\(rule.decision == .deny ? "Denied" : "Allowed") · \(rule.repo)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { forget(rule) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(rule.rule)")
                    }
                }
            } header: {
                Text("Permissions on this Mac")
            } footer: {
                Text("How much the jobs this Mac runs itself ask. Each job's Mode menu changes it while it runs. Always allow saves a rule, so it doesn't ask again; remove the rule to be asked again. The runner's jobs follow Settings › Runner.")
            }
            VoiceSection(speaks: $speaks, footer: "When you talk to Oby with fn, it answers out loud and, after fn + Space, listens again for your answer until you press fn or say “stop”. Typed messages are answered in writing. Pressing fn stops it mid-sentence.")
            NotificationsSection()
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            NSApp.activate()
            mode = desk.defaultMode
            rules = desk.permissionRules
        }
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
    let remote: RemoteAccess
    /// The always-on runner whose jobs the island lists and RunnerFeed follows; empty turns that off.
    @AppStorage("runnerURL") private var runnerURL = ""
    /// "This Mac" (#283): the runner is Oby's login item on this Mac, and Oby follows it on 127.0.0.1.
    @AppStorage(RunnerFeed.thisMacKey) private var onThisMac = false
    /// The login item, registered with "This Mac" and unregistered with a remote runner (Mac/LoginItem.swift).
    @State private var loginItem = RunnerLoginItem()
    /// Merge checks on this Mac (Mac/MacChecks.swift).
    @AppStorage(MacChecks.setting) private var runMergeChecks = true
    /// Apple checks agents ask for (Engine/AppleChecks.swift).
    @AppStorage(MacChecks.appleSetting) private var runAppleChecks = true
    @State private var watches: [PairedWatch] = []
    @State private var removing: PairedWatch?
    @State private var watchProblem: String?

    var body: some View {
        Form {
            Section {
                Picker("Runner", selection: $onThisMac) {
                    Text("This Mac").tag(true)
                    Text("Remote").tag(false)
                }
                .pickerStyle(.segmented)
                .onChange(of: onThisMac) { _, on in
                    if on { loginItem.register() } else { loginItem.unregister() }
                }
                if onThisMac {
                    LabeledContent("Login item", value: loginItem.line)
                    if loginItem.needsApproval {
                        Button("Open Login Items Settings") { RunnerLoginItem.openSettings() }
                    }
                    if let problem = loginItem.problem {
                        Text(problem).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                } else {
                    TextField("URL", text: $runnerURL, prompt: Text(Runner.defaultURL.absoluteString))
                }
                LabeledContent("Status", value: feed.runner == nil && !feed.local ? "Off" : feed.connection.status(host: feed.name))
                if let cleanup = feed.cleanup {
                    LabeledContent("Job worktrees", value: ByteCountFormatter.string(fromByteCount: cleanup.bytes, countStyle: .file))
                    LabeledContent("Last cleanup", value: cleanup.lastRun.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                }
            } header: {
                Text("Runner")
            } footer: {
                Text(onThisMac
                     ? "Oby's runner runs on this Mac as a login item: it starts when you log in and keeps working while Oby's window is closed. Oby plans and runs every job there, on 127.0.0.1, and lists them in the island and the window. Your iPhone and Apple Watch reach it through the gateway."
                     : "The runner does the work while your Mac is closed. The island lists the jobs running there too, and Oby tells you when one needs you. It answers only your Tailscale login, so this Mac needs Tailscale on. Leave it empty to turn this off.")
            }
            Section {
                Toggle("Keep my Mac available", isOn: Binding(get: { availability.keepAvailable }, set: availability.setKeepAvailable))
                LabeledContent("Availability", value: availability.label)
                Link("Recommend Wake for network access", destination: URL(string: "x-apple.systempreferences:com.apple.energysaver")!)
            } header: {
                Text("This Mac")
            } footer: {
                Text("On power, Oby prevents idle sleep while This Mac is enabled and this setting is on. A running job always keeps this Mac awake.")
            }
            // As on the iPhone (Shared/PermissionsSection.swift). This Mac's own jobs' default is in General.
            PermissionsSection(runner: feed.runner, defaultMode: feed.defaultMode, setDefault: feed.setDefaultMode)
            Section("Checks on this Mac") {
                Toggle("Run merge checks on this Mac", isOn: $runMergeChecks)
                Text("When Oby's review approves a pull request, this Mac runs its tests and builds the Mac and iPhone apps, one at a time, before Oby merges it into dev.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Build and test agents' work on this Mac", isOn: $runAppleChecks)
                Text("When an agent on the runner asks (oby-check apple), this Mac builds and tests the Mac and iPhone apps at its latest commit, before Oby's review has read it, and the agent gets the compiler's errors and failing tests.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if watches.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                }
                ForEach(watches) { watch in
                    HStack {
                        LabeledContent(watch.name, value: "Paired")
                        Button("Remove", role: .destructive) { removing = watch }
                    }
                }
                if let watchProblem { Text(watchProblem).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Apple Watch without iPhone")
            } footer: {
                Text("Away from your iPhone, a paired watch reaches the runner through your Cloudflare Tunnel. Pair one in Oby's Settings on your iPhone, with Oby open on the watch: pairing asks for Face ID.")
            }
            Section {
                LabeledContent("Publishing key", value: feed.runner == nil ? "Off" : feed.device.status)
                // The runner's own line (pairing is closed: how to open it), then Try again.
                if feed.runner != nil, let problem = feed.device.problem {
                    Text(problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    Button("Try again") { feed.register() }
                }
            } footer: {
                Text("Oby opens a pull request by itself once a job's check passes and the secret scan is clean. When that failed, publish by hand here or on your iPhone: this Mac's key, like the iPhone's, signs only after Touch ID, and the runner learns it once, while pairing is open on it. Oby merges only into dev, once its review approves and your Mac's checks pass.")
            }
            PairingView(feed: feed, remote: remote)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { loginItem.refresh() }
        // Back from approving the login item in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in loginItem.refresh() }
        // Once the runner answers, and again after it comes back.
        .task(id: feed.connection) {
            guard feed.connection == .live, let runner = feed.runner else { return }
            // A runner older than the Watch API has no list: then there's nothing to show.
            watches = (try? await runner.watches()) ?? []
        }
        .confirmationDialog("Remove \(removing?.name ?? "this watch")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { watch in
            Button("Remove", role: .destructive) { remove(watch) }
        } message: { _ in
            Text("The runner forgets it: away from your iPhone, it reaches the runner again once you pair it on your iPhone.")
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

/// Settings › Remote access: reach this Mac from anywhere (#285, Mac/RemoteAccess.swift). Sign in
/// to Oby's control plane with a code by email, then turn it on: this Mac gets a hostname of its
/// own and runs its tunnel. The iPhone connects to the hostname when it's away from home.
struct RemoteAccessSettingsView: View {
    let remote: RemoteAccess
    @State private var email = ""
    @State private var code = ""
    @State private var forgetting = false

    var body: some View {
        Form {
            Section {
                switch remote.step {
                case .signedOut:
                    TextField("Email", text: $email, prompt: Text("you@example.com"))
                        .onSubmit(sendCode)
                    Button("Send Code") { sendCode() }
                        .disabled(remote.busy || email.trimmingCharacters(in: .whitespaces).isEmpty)
                case .codeSent(let to):
                    Text("A six-digit code went to \(to). It works for ten minutes.")
                    TextField("Code", text: $code, prompt: Text("123456"))
                        .onSubmit(verify)
                    HStack {
                        Button("Sign In") { verify() }
                            .disabled(remote.busy || code.trimmingCharacters(in: .whitespaces).count != 6)
                        Button("Use Another Email") { remote.useAnotherEmail() }
                            .disabled(remote.busy)
                    }
                case .signedIn, .on:
                    LabeledContent("Signed in as", value: remote.email ?? "")
                }
            } header: {
                Text("Oby account")
            } footer: {
                Text("Remote access goes through Oby's control plane (oby-control.tetrix.pro), which signs you in with a code by email and gives this Mac a hostname of its own.")
            }
            if remote.step == .signedIn || remote.step == .on {
                Section {
                    Toggle("Reach this Mac from anywhere", isOn: Binding(get: { remote.step == .on }, set: { on in
                        if on { Task { await remote.turnOn() } } else { remote.turnOff() }
                    }))
                    .disabled(remote.busy)
                    if let hostname = remote.hostname {
                        LabeledContent("Hostname", value: hostname).textSelection(.enabled)
                    }
                    LabeledContent("Status", value: remote.busy ? "Setting up…" : remote.status)
                    Button("Forget This Mac", role: .destructive) { forgetting = true }
                        .disabled(remote.busy)
                } header: {
                    Text("Remote access")
                } footer: {
                    Text("On, this Mac runs its Cloudflare Tunnel outbound, with no port to open: away from home, your iPhone reaches the gateway, and nothing else, at the hostname. Pair the iPhone to hand it the hostname. Off keeps the hostname for next time. Forget removes this Mac from your account, and the hostname stops answering.")
                }
            }
            if let problem = remote.problem {
                Text(problem).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .confirmationDialog("Forget this Mac?", isPresented: $forgetting) {
            Button("Forget", role: .destructive) { Task { await remote.forget() } }
        } message: {
            Text("Its tunnel and hostname are removed from your Oby account, and this Mac signs out. Turning remote access on again makes a new hostname.")
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

/// Settings › Accounts: the logins Oby spreads jobs across, who pays for each, and how much each has
/// used, on this Mac and on the runner, as the iPhone shows them (Shared/SettingsSections.swift).
struct AccountsSettingsView: View {
    let store: AccountStore
    let feed: RunnerFeed
    @State private var agent = "claude"
    @State private var name = ""
    @State private var payer = ""
    @State private var removing: Account?
    @State private var problem: String?

    var body: some View {
        Form {
            AccountSections("Accounts on this Mac", items: store.accounts, id: \.account.id, usage: \.usage,
                            place: "on this Mac", row: row)
            Section("Add an account") {
                Picker("Tool", selection: $agent) {
                    Text("Claude Code").tag("claude")
                    Text("Codex").tag("codex")
                    Text("Cursor").tag("cursor")
                }
                if agent == "cursor", !CursorFacts.separateLogins {
                    // Why a second one is refused.
                    Text("\(CursorFacts.oneLogin): one Cursor account.").font(.caption).foregroundStyle(.secondary)
                }
                TextField("Name", text: $name, prompt: Text("Personal"))
                TextField("Paid by", text: $payer, prompt: Text("Wellington"))
                Button("Add Account") {
                    attempt {
                        try store.add(agent: agent, name: name.trimmingCharacters(in: .whitespaces), payer: payer.trimmingCharacters(in: .whitespaces))
                        name = ""
                        payer = ""
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            if feed.runner != nil {
                AccountSections("Accounts on \(feed.name)", items: feed.accounts, id: \.account.id, usage: \.usage,
                                place: "on \(feed.name)") { state in
                    VStack(alignment: .leading, spacing: 4) {
                        UsageCard(snapshot: state.usage)
                        // The runner's "accounts" event brings the change back.
                        ReserveSwitch(snapshot: state.usage) { lift in
                            guard let runner = feed.runner else { throw RunnerError(message: "Set the runner's URL in Settings first.") }
                            _ = try await runner.liftReserve(state.account.id, lift)
                        }
                        if state.signedIn {
                            Text(Usage.tetrix(state.tetrix, jobs: state.tetrixJobs, used: state.tetrixUsed))
                                .font(.caption).foregroundStyle(state.tetrix == false ? Color.orange : Color.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .task { await store.refresh() }
        // Back from signing in, in Terminal.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refresh() }
        }
        .confirmationDialog("Remove \(removing?.name ?? "this account")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { account in
            Button("Remove", role: .destructive) { attempt { try store.remove(account) } }
        } message: { account in
            Text(account.home == nil ? "Its login stays in the tool's own settings." : "Oby deletes this account's settings folder.")
        }
    }

    /// The account's usage card, who pays for it, and its buttons.
    private func row(_ state: AccountState) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                UsageCard(snapshot: state.usage)
                ReserveSwitch(snapshot: state.usage) { lift in _ = store.liftReserve(state.account.id, lift) }
                // A job of its hit the limit: no job goes to it until then.
                if state.isFull(), let until = state.fullUntil {
                    Text("Full until \(Limits.clock(until))").font(.caption).foregroundStyle(.orange)
                }
                if !state.account.payer.isEmpty {
                    Text("Paid by \(state.account.payer)").font(.caption).foregroundStyle(.secondary)
                }
                if state.signedIn {
                    Text(Usage.tetrix(state.tetrix, jobs: state.tetrixJobs, used: state.tetrixUsed))
                        .font(.caption).foregroundStyle(state.tetrix == false ? Color.orange : Color.secondary)
                }
            }
            VStack(alignment: .trailing, spacing: 6) {
                if !state.signedIn {
                    Button("Sign In") { attempt { try store.signIn(state.account) } }
                } else if state.tetrix == false {
                    Button("Sign In to Tetrix") { attempt { try store.signIn(state.account, tetrix: true) } }
                }
                Button("Remove", role: .destructive) { removing = state.account }
            }
            .padding(.top, 4)
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
        Form {
            Section("Secrets") {
                if names.isEmpty {
                    Text("No secrets yet.").foregroundStyle(.secondary)
                }
                ForEach(names, id: \.self) { name in
                    HStack {
                        Label(name, systemImage: "key")
                        Spacer()
                        Button("Remove", role: .destructive) { removing = name }
                    }
                }
            }
            Section("Add a secret") {
                TextField("Name", text: $name, prompt: Text("staging-api-key"))
                SecureField("Value", text: $value)
                Button("Add Secret") {
                    attempt {
                        try vault.add(value, as: name.trimmingCharacters(in: .whitespaces))
                        name = ""
                        value = ""
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || value.isEmpty)
            }
            Text("Oby uses a secret only in its own calls, for a connection you made. No agent sees it, and the secret scan stops anything outgoing that holds it, plain or encoded.")
                .font(.caption).foregroundStyle(.secondary)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { attempt {} }
        .confirmationDialog("Remove \(removing ?? "this secret")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { name in
            Button("Remove", role: .destructive) { attempt { try vault.remove(name) } }
        } message: { _ in
            Text("Oby deletes it from the keychain.")
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
/// runner (as the iPhone sets them, Shared/SettingsSections.swift).
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
    @State private var problem: String?

    var body: some View {
        Form {
            Section("Claude Code on this Mac") {
                Picker("Model", selection: $claudeModel) {
                    ForEach(AgentModels.claude, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Effort", selection: $claudeEffort) {
                    ForEach(AgentModels.claudeEfforts, id: \.self) { Text(AgentModels.effortName($0)).tag($0) }
                }
                Picker("Complex job effort", selection: $claudeComplexEffort) {
                    ForEach(AgentModels.claudeEfforts, id: \.self) { Text(AgentModels.effortName($0)).tag($0) }
                }
            }
            Section("Codex on this Mac") {
                Picker("Model", selection: $codexModel) {
                    ForEach(codexChoices, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Effort", selection: $codexEffort) {
                    ForEach(codexEfforts, id: \.self) { Text(AgentModels.effortName($0)).tag($0) }
                }
                Picker("Complex job effort", selection: $codexComplexEffort) {
                    ForEach(codexEfforts, id: \.self) { Text(AgentModels.effortName($0)).tag($0) }
                }
            }
            Section("Cursor on this Mac") {
                Picker("Model", selection: $cursorModel) {
                    ForEach(cursorChoices, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            Text("New jobs on this Mac use these. Oby's brain stays on Haiku: it plans and answers in the conversation, so it should be quick.")
                .font(.caption).foregroundStyle(.secondary)
            if feed.runner != nil {
                RunnerModelsSections(options: runnerOptions, models: feed.models, save: feed.setModels, place: "on \(feed.name)")
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .task { codexModels = (try? await CodexAgent.models(home: nil)) ?? [] }
        .task {
            // Jobs run on Oby's own Cursor account: its model list, when one is signed in.
            guard let account = store.accounts.first(where: { $0.account.agent == "cursor" && $0.signedIn }) else { return }
            cursorModels = await CursorModels.list(home: account.account.home)
        }
        // Once the runner answers, and again after it comes back or its URL changes.
        .task(id: feed.connection) {
            guard feed.connection == .live, let runner = feed.runner else { return }
            do {
                runnerOptions = try await runner.modelOptions()
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
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
                       reserveLiftedUntil: reserveLifted)
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
}

/// Settings › Assistants: add the bundled `oby-mcp` to Claude Code or Codex (#385). Points at
/// Contents/Helpers/oby-mcp, never a copy, so Sparkle keeps it current with the app.
struct AssistantsSettingsView: View {
    private enum Target: String, Identifiable {
        case claude, codex
        var id: String { rawValue }
        var title: String { self == .claude ? "Claude Code" : "Codex" }
        var argv: [String] { self == .claude ? MCPHelper.claudeAdd() : MCPHelper.codexAdd() }
    }

    @State private var confirming: Target?
    @State private var busy = false
    @State private var note: String?
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Bundled path", value: MCPHelper.path)
                if !MCPHelper.isPresent {
                    Text("Not in this build of Oby").foregroundStyle(.secondary)
                }
            } header: {
                Text("oby-mcp")
            } footer: {
                Text("Sparkle updates it with the app. Point Claude Code and Codex at this path, never a copy. Rebuilding by hand: rm the old binary before copying, then codesign -s - -f on the new one (a plain cp over a signed binary is killed on launch).")
            }
            Section("Claude Code") {
                Button("Add to Claude Code") { confirming = .claude }
                    .disabled(!MCPHelper.isPresent || busy)
            }
            Section("Codex") {
                Button("Add to Codex") { confirming = .codex }
                    .disabled(!MCPHelper.isPresent || busy)
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .confirmationDialog("Add \(confirming?.title ?? "")?", isPresented: Binding(
            get: { confirming != nil },
            set: { if !$0 { confirming = nil } }
        )) {
            Button("Add") {
                guard let target = confirming else { return }
                confirming = nil
                Task { await add(target) }
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text(confirming.map { MCPHelper.shellLine($0.argv) } ?? "")
        }
    }

    private func add(_ target: Target) async {
        busy = true
        note = nil
        problem = nil
        defer { busy = false }
        let argv = target.argv
        do {
            let result = try await Shell.run(argv, timeout: 30)
            if result.status == 0 {
                note = "Added to \(target.title)."
            } else {
                let said = [result.err, result.text].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "exit \(result.status)"
                problem = "Couldn't add to \(target.title): \(said)"
            }
        } catch {
            problem = "Couldn't add to \(target.title): \(error.localizedDescription). Is \(argv[0]) on your PATH?"
        }
    }
}
