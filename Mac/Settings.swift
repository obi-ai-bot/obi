import AppKit
import ServiceManagement
import SwiftUI

/// Settings › General: what the iPhone's Settings has too (Shared/SettingsSections.swift), and
/// opening at login.
struct SettingsView: View {
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
            VoiceSection(speaks: $speaks, footer: "When you talk to Oby with fn, it answers out loud and, after fn + Space, listens again for your answer until you press fn or say “stop”. Typed messages are answered in writing. Pressing fn stops it mid-sentence.")
            NotificationsSection()
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { NSApp.activate() }
    }
}

/// Settings › Runner: the always-on runner and how this Mac reaches it, the checks this Mac runs
/// for it, and the Apple Watches paired with it.
struct RunnerSettingsView: View {
    let feed: RunnerFeed
    /// The always-on runner whose jobs the island lists and RunnerFeed follows; empty turns that off.
    @AppStorage("runnerURL") private var runnerURL = ""
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
                TextField("URL", text: $runnerURL, prompt: Text(Runner.defaultURL.absoluteString))
                LabeledContent("Status", value: feed.runner == nil ? "Off" : feed.connection.status(host: feed.name))
            } header: {
                Text("Runner")
            } footer: {
                Text("The runner does the work while your Mac is closed. The island lists the jobs running there too, and Oby tells you when one needs you. It answers only your Tailscale login, so this Mac needs Tailscale on. Leave it empty to turn this off.")
            }
            // As on the iPhone (Shared/PermissionsSection.swift). This Mac's own jobs don't ask yet (#134).
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
        }
        .formStyle(.grouped)
        .frame(width: 460)
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
    let feed: RunnerFeed
    @AppStorage("claude.model") private var claudeModel = AgentModels.defaults["claude.model"] ?? ""
    @AppStorage("claude.effort") private var claudeEffort = AgentModels.defaults["claude.effort"] ?? ""
    @AppStorage("codex.model") private var codexModel = AgentModels.defaults["codex.model"] ?? ""
    @AppStorage("codex.effort") private var codexEffort = AgentModels.defaults["codex.effort"] ?? ""
    /// What the signed-in Codex account offers, from its own model list.
    @State private var codexModels: [CodexModel] = []
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
            }
            Section("Codex on this Mac") {
                Picker("Model", selection: $codexModel) {
                    ForEach(codexChoices, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Effort", selection: $codexEffort) {
                    ForEach(codexEfforts, id: \.self) { Text(AgentModels.effortName($0)).tag($0) }
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

    private var codexEfforts: [String] {
        let efforts = codexChoices.first { $0.id == codexModel }?.efforts ?? []
        return efforts.contains(codexEffort) ? efforts : [codexEffort] + efforts
    }
}

extension AccountState {
    /// What Settings' usage card shows.
    var usage: Usage.Snapshot {
        Usage.Snapshot(agent: account.agent, name: account.name, label: label, fiveHour: fiveHour, sevenDay: sevenDay,
                       fiveHourResets: fiveHourResets, sevenDayResets: sevenDayResets, running: running)
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
